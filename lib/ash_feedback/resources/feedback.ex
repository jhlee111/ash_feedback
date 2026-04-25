defmodule AshFeedback.Resources.Feedback do
  @moduledoc """
  Ash resource definition mirroring the `phoenix_replay_feedbacks`
  table owned by `phoenix_replay`'s migration.

  Because an Ash resource's postgres repo + domain must be concrete
  at compile time, this module is a `__using__` macro: the host
  defines a thin concrete resource that wires its own `:repo`,
  `:domain`, and — optionally — the `:assignee_resource` used by
  the triage `belongs_to` relationships.

  ## Usage

      defmodule MyApp.Feedback do
        use Ash.Domain

        resources do
          resource MyApp.Feedback.Entry
        end
      end

      defmodule MyApp.Feedback.Entry do
        use AshFeedback.Resources.Feedback,
          domain: MyApp.Feedback,
          repo: MyApp.Repo,
          assignee_resource: MyApp.Accounts.User
      end

  The generated resource:

    * uses `AshPostgres.DataLayer`, table `"phoenix_replay_feedbacks"`,
      with `migrate? false` — the migration belongs to
      `phoenix_replay` (`mix phoenix_replay.install` for the base
      schema + `mix phoenix_replay.upgrade_triage` for the Phase 5a
      triage columns).
    * uses plain `uuid_primary_key :id` to match the existing
      `binary_id` column.
    * defines `:submit`, `:read`, `:list`, and the Phase 5a triage
      transition actions (`:acknowledge`, `:assign`, `:verify`,
      `:resolve`, `:dismiss`) + the generic action
      `:promote_verified_to_resolved` used by the deploy pipeline.

  The `:assignee_resource` option is optional. When omitted, the
  `assignee`, `verified_by`, and `resolved_by` relationships are
  skipped (useful for library tests that don't need a user model).

  See `AshFeedback.Storage` for the companion `PhoenixReplay.Storage`
  adapter that routes ingest submissions through this resource.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    # Optional — only consulted by AshStorage's per-resource service
    # config (`config :otp_app, MyApp.Feedback.Entry, storage: [...]`).
    # Without it, AshStorage falls back to the per-entity `:service`
    # entry-option on `has_one_attached`, which the macro doesn't emit.
    # Audio-disabled hosts can leave it nil.
    otp_app = Keyword.get(opts, :otp_app)
    assignee_resource = Keyword.get(opts, :assignee_resource)
    # Host's User primary-key Ash type. Defaults to `:uuid` short-name
    # so bare-Ash hosts still work. Hosts using AshPrefixedId MUST pass
    # the concrete ObjectId type (e.g. `GsNet.Accounts.User.ObjectId`)
    # otherwise the :assignee belongs_to filter cannot round-trip the
    # prefixed string at load time.
    assignee_attribute_type = Keyword.get(opts, :assignee_attribute_type, :uuid)
    pubsub_module = Keyword.get(opts, :pubsub)
    paper_trail_actor = Keyword.get(opts, :paper_trail_actor)
    _ = Keyword.get(opts, :prefix, "fbk")
    # ADR-0001: AshStorage blob + attachment resources for audio narration.
    # Both required when `audio_enabled` is true at compile time. Host
    # defines its own BlobResource + AttachmentResource (see AshStorage's
    # docs); we route the section-level `storage do …` declaration to
    # them so a single `has_one_attached :audio_clip` entity wires up.
    audio_blob_resource = Keyword.get(opts, :audio_blob_resource)
    audio_attachment_resource = Keyword.get(opts, :audio_attachment_resource)

    notifiers =
      if pubsub_module do
        [Ash.Notifier.PubSub]
      else
        []
      end

    # ADR-0001: audio narration. Compile-time gate so disabled hosts
    # don't carry the AshStorage extension surface or any audio FK
    # column. `Code.ensure_loaded?` guards against the case where a
    # host flips the flag without adding the optional dep to mix.exs.
    #
    # `Application.get_env/3` is used (not `compile_env`) because
    # `compile_env` cannot be called from inside a `defmacro` body.
    # The value is still resolved at the host's compile time — when
    # this `__using__/1` expansion runs against the host's `use
    # AshFeedback.Resources.Feedback`. The trade-off vs `compile_env`
    # is no automatic Mix recompile-on-flag-change; hosts that flip
    # the flag must `mix compile --force` (or just `touch` the
    # resource file). Acceptable for an install-time decision.
    audio_enabled? =
      Application.get_env(:ash_feedback, :audio_enabled, false) and
        Code.ensure_loaded?(AshStorage)

    if audio_enabled? and
         (is_nil(audio_blob_resource) or is_nil(audio_attachment_resource)) do
      raise ArgumentError, """
      AshFeedback audio narration is enabled (config :ash_feedback,
      audio_enabled: true) but `:audio_blob_resource` and/or
      `:audio_attachment_resource` were not passed to
      `use AshFeedback.Resources.Feedback`.

      Define an AshStorage BlobResource + AttachmentResource pair in
      your host (see `AshStorage` docs and the reference shapes under
      `dev/resources/{blob,attachment}.ex` in the ash_storage repo)
      and pass both:

          use AshFeedback.Resources.Feedback,
            domain: MyApp.Feedback,
            repo: MyApp.Repo,
            audio_blob_resource: MyApp.Storage.Blob,
            audio_attachment_resource: MyApp.Storage.Attachment

      Or set `config :ash_feedback, audio_enabled: false` to disable
      audio narration.
      """
    end

    extensions =
      [AshStateMachine, AshPaperTrail.Resource] ++
        if(audio_enabled?, do: [AshStorage], else: [])

    use_opts =
      [
        domain: domain,
        data_layer: AshPostgres.DataLayer,
        extensions: extensions,
        notifiers: notifiers
      ]
      |> then(fn opts -> if otp_app, do: Keyword.put(opts, :otp_app, otp_app), else: opts end)

    quote location: :keep do
      use Ash.Resource, unquote(use_opts)

      require Ash.Query
      require Ash.Expr

      postgres do
        table "phoenix_replay_feedbacks"
        repo unquote(repo)
        migrate? false
      end

      paper_trail do
        primary_key_type :uuid
        change_tracking_mode :changes_only
        store_action_name? true

        # FK attributes are ignored: AshPaperTrail serializes diffs as
        # JSONB, and host-provided AshPrefixedId types (e.g.
        # GsNet.Accounts.User.ObjectId) don't have a JSON-safe
        # dump_to_embedded path. State transitions already capture the
        # "who-did-what" via :status + the changes blob without the
        # FK column, so we lose nothing meaningful by ignoring them.
        ignore_attributes [
          :inserted_at,
          :updated_at,
          :events_s3_key,
          :identity,
          :metadata,
          :assignee_id,
          :verified_by_id,
          :resolved_by_id,
          :related_to_id
        ]

        attributes_as_attributes [:status, :reported_on_env]

        unquote(
          case paper_trail_actor do
            {module, opts} when is_list(opts) ->
              quote do
                belongs_to_actor(:user, unquote(module), unquote(opts))
              end

            module when is_atom(module) and not is_nil(module) ->
              quote do
                belongs_to_actor(:user, unquote(module))
              end

            _ ->
              nil
          end
        )
      end

      unquote(
        if pubsub_module do
          quote do
            pub_sub do
              module Phoenix.PubSub
              name unquote(pubsub_module)
              prefix "feedback"

              # Each `publish` with a list joins segments into one
              # `prefix:a:b` topic, so a single publish can't reach
              # both a broad "status_changed" subscriber and a narrower
              # "assigned" subscriber — we duplicate the call instead.
              publish_all :create, ["created"]
              publish :acknowledge, ["status_changed"]
              publish :assign, ["status_changed"]
              publish :assign, ["assigned"]
              publish :verify, ["status_changed"]
              publish :verify, ["verified"]
              publish :resolve, ["status_changed"]
              publish :resolve, ["resolved"]
              publish :dismiss, ["status_changed"]
              publish :dismiss, ["dismissed"]
            end
          end
        end
      )

      state_machine do
        state_attribute(:status)
        initial_states([:new])
        default_initial_state(:new)

        transitions do
          transition(:acknowledge, from: :new, to: :acknowledged)
          transition(:assign, from: [:new, :acknowledged, :in_progress], to: :in_progress)
          transition(:verify, from: [:in_progress, :acknowledged], to: :verified_on_preview)
          transition(:resolve, from: :verified_on_preview, to: :resolved)

          transition(:dismiss,
            from: [:new, :acknowledged, :in_progress, :verified_on_preview],
            to: :dismissed
          )
        end
      end

      # ADR-0001 Phase 1 — audio narration attachment via AshStorage.
      # Only emitted when both the runtime opt-in
      # (`config :ash_feedback, audio_enabled: true`) and the optional
      # `:ash_storage` dep are present at compile time. `dependent:
      # :purge` on the entity makes the attachment + blob (and the
      # underlying S3 object) follow the parent feedback row's
      # lifecycle, matching ADR-0001 Question E.
      #
      # AshStorage 0.1's DSL requires `blob_resource` and
      # `attachment_resource` at the **section** level (they're shared
      # across all attachments declared on the resource). The host
      # provides both via the `:audio_blob_resource` and
      # `:audio_attachment_resource` opts.
      unquote(
        if audio_enabled? do
          quote do
            storage do
              blob_resource unquote(audio_blob_resource)
              attachment_resource unquote(audio_attachment_resource)

              has_one_attached :audio_clip, dependent: :purge
            end
          end
        end
      )

      code_interface do
        define :submit, action: :submit
        define :get_feedback, action: :read, get_by: [:id]
        define :list_feedback, action: :list
        define :acknowledge, action: :acknowledge, get_by: [:id]
        define :assign, action: :assign, get_by: [:id]
        define :verify, action: :verify, get_by: [:id]
        define :resolve, action: :resolve, get_by: [:id]
        define :dismiss, action: :dismiss, get_by: [:id]
        define :list_verified_non_preview, action: :list_verified_non_preview
        define :list_preview_blockers, action: :list_preview_blockers
        define :promote_verified_to_resolved, action: :promote_verified_to_resolved
      end

      attributes do
        uuid_primary_key :id

        attribute :session_id, :string do
          allow_nil? false
          public? true
          constraints max_length: 128
        end

        attribute :description, :string do
          public? true
          allow_nil? true
        end

        attribute :severity, AshFeedback.Types.Severity do
          public? true
          allow_nil? true
        end

        attribute :events_s3_key, :string do
          public? true
          allow_nil? true
        end

        attribute :metadata, :map do
          public? true
          default %{}
        end

        attribute :identity, :map do
          public? true
          default %{}
        end

        attribute :status, AshFeedback.Types.Status do
          public? true
          allow_nil? false
          default :new
        end

        attribute :priority, AshFeedback.Types.Priority do
          public? true
          allow_nil? true
        end

        attribute :pr_urls, {:array, :string} do
          public? true
          allow_nil? false
          default []
        end

        attribute :triage_notes, :string do
          public? true
          allow_nil? true
        end

        attribute :reported_on_env, AshFeedback.Types.Environment do
          public? true
          allow_nil? true
        end

        attribute :verified_at, :utc_datetime_usec do
          public? true
          allow_nil? true
        end

        attribute :resolved_at, :utc_datetime_usec do
          public? true
          allow_nil? true
        end

        attribute :dismissed_reason, AshFeedback.Types.DismissReason do
          public? true
          allow_nil? true
        end

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      # FK source attributes (assignee_id, verified_by_id, resolved_by_id,
      # related_to_id) are NOT declared explicitly. Each `belongs_to`
      # auto-generates its source attribute with the target's primary-key
      # type — e.g. on a host where `GsNet.Accounts.User.id` is an
      # AshPrefixedId-typed column, `assignee_id` inherits that type and
      # casts prefixed strings correctly. Declaring a raw `Ash.Type.UUID`
      # attribute here would force an unconditional raw-UUID round-trip
      # at the boundary and break the `:assignee` load.
      relationships do
        unquote(
          if assignee_resource do
            quote do
              belongs_to :assignee, unquote(assignee_resource) do
                public? true
                attribute_writable? true
                attribute_type unquote(assignee_attribute_type)
                allow_nil? true
              end

              belongs_to :verified_by, unquote(assignee_resource) do
                public? true
                attribute_writable? true
                attribute_type unquote(assignee_attribute_type)
                allow_nil? true
              end

              belongs_to :resolved_by, unquote(assignee_resource) do
                public? true
                attribute_writable? true
                attribute_type unquote(assignee_attribute_type)
                allow_nil? true
              end
            end
          end
        )

        belongs_to :related_to, __MODULE__ do
          public? true
          attribute_writable? true
          allow_nil? true
        end
      end

      identities do
        identity :unique_session_id, [:session_id]
      end

      actions do
        defaults [:read]

        create :submit do
          accept [
            :session_id,
            :description,
            :severity,
            :metadata,
            :identity,
            :events_s3_key
          ]

          upsert? true
          upsert_identity :unique_session_id

          # ADR-0001 / D2-revised: when audio is compile-time enabled, the
          # action accepts an optional blob id (minted by the prepare-upload
          # controller in `AshFeedback.Controller.AudioUploadsController`)
          # and `AshStorage.Changes.AttachBlob` wires it to the
          # `:audio_clip` `has_one_attached`. The narration start offset
          # rides on the blob's metadata map (set at prepare-time) so it
          # is intentionally NOT an action argument — see the plan's
          # Decisions log entry for Task 2b.1.
          unquote(
            if audio_enabled? do
              quote do
                argument :audio_clip_blob_id, :uuid, allow_nil?: true

                change {AshStorage.Changes.AttachBlob,
                        argument: :audio_clip_blob_id, attachment: :audio_clip}
              end
            end
          )

          change fn changeset, _ctx ->
            meta = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

            case Map.get(meta, "environment") || Map.get(meta, :environment) do
              value when is_binary(value) and byte_size(value) > 0 ->
                case AshFeedback.Types.Environment.cast_input(value, []) do
                  {:ok, env_atom} ->
                    Ash.Changeset.force_change_attribute(changeset, :reported_on_env, env_atom)

                  _ ->
                    changeset
                end

              value when is_atom(value) and not is_nil(value) ->
                Ash.Changeset.force_change_attribute(changeset, :reported_on_env, value)

              _ ->
                changeset
            end
          end
        end

        read :list do
          argument :severity, AshFeedback.Types.Severity, allow_nil?: true
          argument :limit, :integer, default: 50
          argument :offset, :integer, default: 0

          prepare fn query, _ctx ->
            severity = Ash.Query.get_argument(query, :severity)
            limit = Ash.Query.get_argument(query, :limit) || 50
            offset = Ash.Query.get_argument(query, :offset) || 0

            query =
              query
              |> Ash.Query.sort(inserted_at: :desc)
              |> Ash.Query.limit(limit)
              |> Ash.Query.offset(offset)

            case severity do
              nil -> query
              sev -> Ash.Query.filter(query, severity == ^sev)
            end
          end
        end

        # Rows to auto-resolve on preview→prod promote. Originated on
        # staging/dev/prod, verified on preview, waiting on ship.
        #
        # `^ref(:field)` is used instead of bare identifiers because
        # this DSL lives inside the library's `__using__` quote block —
        # Elixir hygiene mangles bare `status` / `reported_on_env` so
        # Ash.Expr can't resolve them to attribute refs. Atom literals
        # inside `ref/1` survive hygiene.
        read :list_verified_non_preview do
          filter expr(
                   ^ref(:status) == :verified_on_preview and
                     ^ref(:reported_on_env) != :preview
                 )

          prepare build(sort: [inserted_at: :asc])
        end

        # Open rows originated on preview — must be cleared before
        # promoting preview to prod (preview-only regressions).
        read :list_preview_blockers do
          filter expr(
                   ^ref(:status) in [:new, :acknowledged, :in_progress] and
                     ^ref(:reported_on_env) == :preview
                 )

          prepare build(sort: [inserted_at: :asc])
        end

        update :acknowledge do
          require_atomic? false
          change transition_state(:acknowledged)
        end

        update :assign do
          require_atomic? false
          accept [:assignee_id]
          change transition_state(:in_progress)
        end

        update :verify do
          require_atomic? false
          accept [:pr_urls, :verified_by_id]
          argument :note, :string, allow_nil?: true

          validate fn changeset, _ctx ->
            case Ash.Changeset.get_attribute(changeset, :pr_urls) do
              [_ | _] -> :ok
              _ -> {:error, field: :pr_urls, message: "at least one PR URL required"}
            end
          end

          change set_attribute(:verified_at, &DateTime.utc_now/0)
          change transition_state(:verified_on_preview)
        end

        update :resolve do
          require_atomic? false
          accept [:resolved_by_id]
          change set_attribute(:resolved_at, &DateTime.utc_now/0)
          change transition_state(:resolved)
        end

        update :dismiss do
          require_atomic? false
          argument :reason, AshFeedback.Types.DismissReason, allow_nil?: false

          change set_attribute(:dismissed_reason, arg(:reason))
          change transition_state(:dismissed)
        end

        action :promote_verified_to_resolved, :map do
          argument :promoted_at, :utc_datetime_usec, allow_nil?: false

          run fn input, context ->
            candidates =
              __MODULE__
              |> Ash.Query.for_read(:read)
              |> Ash.Query.filter(status: :verified_on_preview)
              |> Ash.read!(authorize?: false)
              |> Enum.reject(fn row -> row.reported_on_env == :preview end)

            records =
              Enum.map(candidates, fn row ->
                row
                |> Ash.Changeset.for_update(:resolve, %{},
                  actor: context.actor,
                  authorize?: false
                )
                |> Ash.update!(authorize?: false)
              end)

            {:ok,
             %{
               resolved_count: length(records),
               resolved_ids: Enum.map(records, & &1.id),
               promoted_at: input.arguments.promoted_at
             }}
          end
        end
      end

    end
  end
end

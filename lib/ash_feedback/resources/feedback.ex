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
    assignee_resource = Keyword.get(opts, :assignee_resource)
    pubsub_module = Keyword.get(opts, :pubsub)
    paper_trail_actor = Keyword.get(opts, :paper_trail_actor)
    _ = Keyword.get(opts, :prefix, "fbk")

    notifiers =
      if pubsub_module do
        [Ash.Notifier.PubSub]
      else
        []
      end

    quote location: :keep do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        extensions: [AshStateMachine, AshPaperTrail.Resource],
        notifiers: unquote(notifiers)

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

        ignore_attributes [
          :inserted_at,
          :updated_at,
          :events_s3_key,
          :identity,
          :metadata
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

              publish_all :create, ["created"]
              publish :acknowledge, ["status_changed"]
              publish :assign, ["status_changed", "assigned"]
              publish :verify, ["status_changed", "verified"]
              publish :resolve, ["status_changed", "resolved"]
              publish :dismiss, ["status_changed", "dismissed"]
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

      code_interface do
        define :submit, action: :submit
        define :get_feedback, action: :read, get_by: [:id]
        define :list_feedback, action: :list
        define :acknowledge, action: :acknowledge, get_by: [:id]
        define :assign, action: :assign, get_by: [:id]
        define :verify, action: :verify, get_by: [:id]
        define :resolve, action: :resolve, get_by: [:id]
        define :dismiss, action: :dismiss, get_by: [:id]
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

        attribute :assignee_id, Ash.Type.UUID, public?: true, allow_nil?: true
        attribute :verified_by_id, Ash.Type.UUID, public?: true, allow_nil?: true
        attribute :resolved_by_id, Ash.Type.UUID, public?: true, allow_nil?: true
        attribute :related_to_id, Ash.Type.UUID, public?: true, allow_nil?: true

        create_timestamp :inserted_at
        update_timestamp :updated_at
      end

      relationships do
        unquote(
          if assignee_resource do
            quote do
              belongs_to :assignee, unquote(assignee_resource) do
                public? true
                source_attribute :assignee_id
                define_attribute? false
                allow_nil? true
              end

              belongs_to :verified_by, unquote(assignee_resource) do
                public? true
                source_attribute :verified_by_id
                define_attribute? false
                allow_nil? true
              end

              belongs_to :resolved_by, unquote(assignee_resource) do
                public? true
                source_attribute :resolved_by_id
                define_attribute? false
                allow_nil? true
              end
            end
          end
        )

        belongs_to :related_to, __MODULE__ do
          public? true
          source_attribute :related_to_id
          define_attribute? false
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

        update :acknowledge do
          require_atomic? false
          change transition_state(:acknowledged)
        end

        update :assign do
          require_atomic? false
          argument :assignee_id, Ash.Type.UUID, allow_nil?: false
          change set_attribute(:assignee_id, arg(:assignee_id))
          change transition_state(:in_progress)
        end

        update :verify do
          require_atomic? false
          argument :pr_urls, {:array, :string}, allow_nil?: false
          argument :verified_by_id, Ash.Type.UUID, allow_nil?: true
          argument :note, :string, allow_nil?: true

          validate fn changeset, _ctx ->
            case Ash.Changeset.get_argument(changeset, :pr_urls) do
              [_ | _] -> :ok
              _ -> {:error, field: :pr_urls, message: "at least one PR URL required"}
            end
          end

          change set_attribute(:pr_urls, arg(:pr_urls))
          change set_attribute(:verified_by_id, arg(:verified_by_id))
          change set_attribute(:verified_at, &DateTime.utc_now/0)
          change transition_state(:verified_on_preview)
        end

        update :resolve do
          require_atomic? false
          argument :resolved_by_id, Ash.Type.UUID, allow_nil?: true

          change set_attribute(:resolved_by_id, arg(:resolved_by_id))
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

defmodule AshFeedback.Resources.Feedback do
  @moduledoc """
  Ash resource definition mirroring the `phoenix_replay_feedbacks`
  table owned by `phoenix_replay`'s migration.

  Because an Ash resource's postgres repo + domain must be concrete
  at compile time, this module is a `__using__` macro: the host
  defines a thin concrete resource that wires its own `:repo` and
  `:domain` in.

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
          repo: MyApp.Repo
      end

  The generated resource:

    * uses `AshPostgres.DataLayer`, table `"phoenix_replay_feedbacks"`,
      with `migrate? false` — the migration belongs to
      `mix phoenix_replay.install`.
    * uses plain `uuid_primary_key :id` to match the existing
      `binary_id` column owned by phoenix_replay's migration. A
      prefixed-id variant (fbk_*) can be layered on top by hosts
      that want to reset the schema; left out of MVP to avoid
      migration drift.
    * defines `:submit`, `:read`, `:list`, and `:triage`
      actions + a code interface for `submit`, `get_feedback`,
      `list_feedback`, and `triage`.

  Hosts can wrap or replace actions by defining their own action
  blocks after `use`. Policies layered on top via
  `authorizers: [...]` take effect normally.

  See `AshFeedback.Storage` for the companion `PhoenixReplay.Storage`
  adapter that routes ingest submissions through this resource.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    _ = Keyword.get(opts, :prefix, "fbk")

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer

      require Ash.Query

      postgres do
        table "phoenix_replay_feedbacks"
        repo unquote(repo)
        migrate? false
      end

      code_interface do
        define :submit, action: :submit
        define :get_feedback, action: :read, get_by: [:id]
        define :list_feedback, action: :list
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

        create_timestamp :inserted_at
        update_timestamp :updated_at
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
      end
    end
  end
end

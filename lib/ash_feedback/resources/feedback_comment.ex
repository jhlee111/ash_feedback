defmodule AshFeedback.Resources.FeedbackComment do
  @moduledoc """
  Append-only comment on a feedback row (ADR-0118).

  `use` the macro from a host module to wire the concrete repo,
  domain, parent `feedback_resource`, and `author_resource`:

      defmodule MyApp.Feedback.Comment do
        use AshFeedback.Resources.FeedbackComment,
          domain: MyApp.Feedback,
          repo: MyApp.Repo,
          feedback_resource: MyApp.Feedback.Entry,
          author_resource: MyApp.Accounts.User
      end

  ## Characteristics

    * Table: `phoenix_replay_feedback_comments`, owned by
      `phoenix_replay`'s install migration. `migrate? false`.
    * Append-only — no `:update`, no `:destroy`. Edits happen via new
      comments. Keeps the trail immutable (pairs with PaperTrail on
      the parent feedback).
    * `:create` is blocked when the parent feedback is `:resolved` or
      `:dismissed` via a `before_action` hook that fetches the parent
      and adds a changeset error.
    * `:list_by_feedback` sorts by `inserted_at: :asc`.
    * Policies are host-layered — the library ships no authorizer. Hosts
      that want scope-based policies layer AshGrant on the concrete
      resource.
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    repo = Keyword.fetch!(opts, :repo)
    feedback_resource = Keyword.fetch!(opts, :feedback_resource)
    author_resource = Keyword.fetch!(opts, :author_resource)
    # Matches the feedback resource's `:assignee_attribute_type` knob —
    # hosts using AshPrefixedId for their User resource MUST pass the
    # concrete ObjectId type (e.g. `GsNet.Accounts.User.ObjectId`);
    # the default `:uuid` short-name resolves to `AnyPrefixedId` on
    # such hosts, which round-trips a prefixed string into a raw UUID
    # and breaks the `:author` belongs_to load.
    author_attribute_type = Keyword.get(opts, :author_attribute_type, :uuid)
    pubsub_module = Keyword.get(opts, :pubsub)

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
        notifiers: unquote(notifiers)

      require Ash.Query

      postgres do
        table "phoenix_replay_feedback_comments"
        repo unquote(repo)
        migrate? false
      end

      unquote(
        if pubsub_module do
          quote do
            pub_sub do
              module Phoenix.PubSub
              name unquote(pubsub_module)
              prefix "feedback"

              publish :create, ["comment_added"]
            end
          end
        end
      )

      code_interface do
        define :create_comment, action: :create
        define :list_by_feedback, action: :list_by_feedback, args: [:feedback_id]
        define :get_comment, action: :read, get_by: [:id]
      end

      attributes do
        uuid_primary_key :id

        attribute :body, :string do
          public? true
          allow_nil? false
          constraints min_length: 1
        end

        create_timestamp :inserted_at
      end

      relationships do
        belongs_to :feedback, unquote(feedback_resource) do
          public? true
          attribute_writable? true
          allow_nil? false
        end

        belongs_to :author, unquote(author_resource) do
          public? true
          attribute_writable? true
          attribute_type unquote(author_attribute_type)
          allow_nil? false
        end
      end

      actions do
        defaults [:read]

        create :create do
          accept [:feedback_id, :author_id, :body]

          change {AshFeedback.Changes.ValidateParentFeedback, resource: unquote(feedback_resource)}
        end

        read :list_by_feedback do
          argument :feedback_id, Ash.Type.UUID, allow_nil?: false

          prepare fn query, _ctx ->
            feedback_id = Ash.Query.get_argument(query, :feedback_id)

            query
            |> Ash.Query.filter(feedback_id: feedback_id)
            |> Ash.Query.sort(inserted_at: :asc)
          end
        end
      end
    end
  end
end

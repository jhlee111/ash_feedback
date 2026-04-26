defmodule AshFeedback.Storage do
  @moduledoc """
  Implements `PhoenixReplay.Storage` by routing feedback writes + reads
  through an Ash resource (the host's concrete `AshFeedback.Resources.Feedback`
  consumer) and event-stream ops through
  `PhoenixReplay.Storage.Events` (the child table stays a plain Ecto
  schema — Ash owns the feedback row, not the replay stream).

  ## Configuration

      config :phoenix_replay,
        storage: {AshFeedback.Storage,
          resource: MyApp.Feedback.Entry,
          repo: MyApp.Repo}

  Where `MyApp.Feedback.Entry` is the resource declared as:

      defmodule MyApp.Feedback.Entry do
        use AshFeedback.Resources.Feedback,
          domain: MyApp.Feedback,
          repo: MyApp.Repo
      end

  The `:repo` option is used by the event-stream ops. The `:resource`
  option drives Ash `create` / `read` for the feedback parent row.
  Policies, `AshPaperTrail`, `AshPrefixedId`, and tenant scoping on
  the host's domain fire on every call.
  """

  @behaviour PhoenixReplay.Storage

  import AshFeedback.Helpers, only: [stringify_keys: 1]

  alias PhoenixReplay.Storage.Events

  @impl true
  def start_session(_identity, _now) do
    # Ash adapter doesn't persist anything at session start —
    # the feedback row is inserted only on submit. We still mint a
    # fresh session_id so the token carries it.
    {:ok, PhoenixReplay.SessionToken.new_session_id()}
  end

  @impl true
  def resume_session(session_id, now) do
    Events.resume(
      repo!(),
      session_id,
      PhoenixReplay.Config.session_idle_timeout_ms(),
      now
    )
  end

  @impl true
  def append_events(session_id, seq, batch) do
    Events.append(repo!(), session_id, seq, batch)
  end

  @impl true
  def submit(session_id, params, identity) do
    resource = resource!()

    attrs = %{
      session_id: session_id,
      description: Map.get(params, "description"),
      # `severity:` passes through raw; `AshFeedback.Types.Severity` is
      # an `Ash.Type.Enum`, so Ash's changeset cast translates strings
      # ("high"), atoms (:high), and surfaces invalid values as
      # changeset errors rather than swallowing them as nil.
      severity: Map.get(params, "severity"),
      metadata: Map.get(params, "metadata") || %{},
      identity: coerce_identity(identity)
    }

    attrs = maybe_forward_audio_clip_blob_id(attrs, resource, params)

    resource
    |> Ash.Changeset.for_create(:submit, attrs, authorize?: false)
    |> Ash.create()
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Sub-phase 2a's panel-addon API forwards arbitrary `extras` from the
  # browser onto the `/submit` body. The audio addon (sub-phase 2b)
  # carries `audio_clip_blob_id` there. We forward it as a `:submit`
  # action argument only when the host's resource declared the argument
  # (i.e. compiled with `audio_enabled: true`); audio-disabled hosts get
  # the extra silently dropped rather than an `Ash.Error.Invalid.NoSuchInput`.
  #
  # D2-revised: the narration start offset rides on the blob's metadata
  # map at prepare time, so this forwarder intentionally handles only
  # the blob id — see the implementation plan's Decisions log for Task 2b.1.
  defp maybe_forward_audio_clip_blob_id(attrs, resource, params) do
    blob_id =
      params
      |> Map.get("extras", %{})
      |> Map.get("audio_clip_blob_id")

    if is_binary(blob_id) and submit_accepts_audio_clip_blob_id?(resource) do
      Map.put(attrs, :audio_clip_blob_id, blob_id)
    else
      attrs
    end
  end

  defp submit_accepts_audio_clip_blob_id?(resource) do
    case Ash.Resource.Info.action(resource, :submit) do
      %{arguments: arguments} ->
        Enum.any?(arguments, &(&1.name == :audio_clip_blob_id))

      _ ->
        false
    end
  end

  @impl true
  def fetch_feedback(id, _opts) do
    resource = resource!()

    case Ash.get(resource, id, authorize?: false) do
      {:ok, record} -> {:ok, record}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_events(session_id) do
    Events.fetch(repo!(), session_id)
  end

  @impl true
  def list(filters, pagination) do
    resource = resource!()

    args = %{
      severity: Map.get(filters, :severity),
      limit: Keyword.get(pagination, :limit, 50),
      offset: Keyword.get(pagination, :offset, 0)
    }

    resource
    |> Ash.Query.for_read(:list, args, authorize?: false)
    |> Ash.read()
    |> case do
      {:ok, results} ->
        count = count_total(resource, filters)
        {:ok, %{results: results, count: count}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_total(resource, filters) do
    # Separate count query — Ash doesn't auto-attach total with page
    # offsetting unless pagination DSL is enabled. For the MVP admin UI
    # a fresh SELECT count(*) is fine.
    require Ash.Query

    query = Ash.Query.new(resource)

    query =
      case Map.get(filters, :severity) do
        nil -> query
        sev -> Ash.Query.filter(query, severity == ^sev)
      end

    case Ash.count(query, authorize?: false) do
      {:ok, n} -> n
      _ -> 0
    end
  end

  # Translates the Phoenix.Replay identity convention (atom-keyed map
  # with `:kind`/`:id`/`:attrs`) into a JSONB-friendly string-keyed map
  # for the `:identity` attribute. Stays in Storage rather than promoting
  # to an Ash type because the contract is transport-layer (the identity
  # struct's shape is owned by `PhoenixReplay.Plug.Identify`, not us);
  # an embedded resource would force the host to know our shape.
  defp coerce_identity(%{kind: kind} = identity) do
    %{
      "kind" => to_string(kind),
      "id" => Map.get(identity, :id),
      "attrs" => stringify_keys(Map.get(identity, :attrs, %{}))
    }
  end

  defp coerce_identity(_), do: %{}

  defp resource! do
    opts!() |> Keyword.fetch!(:resource)
  rescue
    _ ->
      raise ArgumentError, """
      AshFeedback.Storage requires a :resource option:

          config :phoenix_replay,
            storage: {AshFeedback.Storage,
              resource: MyApp.Feedback.Entry,
              repo: MyApp.Repo}
      """
  end

  defp repo! do
    opts!() |> Keyword.fetch!(:repo)
  rescue
    _ ->
      raise ArgumentError, """
      AshFeedback.Storage requires a :repo option for the event stream.

          config :phoenix_replay,
            storage: {AshFeedback.Storage,
              resource: MyApp.Feedback.Entry,
              repo: MyApp.Repo}
      """
  end

  defp opts! do
    case PhoenixReplay.Config.storage() do
      {__MODULE__, opts} when is_list(opts) -> opts
      _ -> []
    end
  end
end

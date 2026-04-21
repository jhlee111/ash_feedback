defmodule AshFeedback.Storage do
  @moduledoc """
  Implements `PhoenixReplay.Storage` by delegating every callback to
  code-interface functions on an Ash domain.

  ## Configuration

      config :phoenix_replay,
        storage: {AshFeedback.Storage, domain: MyApp.Feedback}

  The configured domain is expected to expose a `Feedback` resource
  (or re-export `AshFeedback.Resources.Feedback`) plus the code
  interface functions used by each callback:

    * `start_session!/2`
    * `append_events!/3`
    * `submit!/3`
    * `get_feedback!/2`
    * `list_feedback/2`

  Because writes run through Ash changesets, policies + paper trail +
  `AshPrefixedId` apply uniformly.
  """

  @behaviour PhoenixReplay.Storage

  # Implementation lands in Phase 4a.

  @impl true
  def start_session(_identity, _now), do: {:error, :not_implemented}

  @impl true
  def append_events(_session_id, _seq, _batch), do: {:error, :not_implemented}

  @impl true
  def submit(_session_id, _params, _identity), do: {:error, :not_implemented}

  @impl true
  def fetch_feedback(_id, _opts), do: {:error, :not_implemented}

  @impl true
  def fetch_events(_session_id), do: {:error, :not_implemented}

  @impl true
  def list(_filters, _pagination), do: {:error, :not_implemented}
end

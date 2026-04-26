defmodule AshFeedback.Actions.PromoteVerifiedToResolved do
  @moduledoc false
  # Run-body for the `:promote_verified_to_resolved` generic action.
  # Loads candidates via the `:list_verified_non_preview` read action
  # and resolves each via `:resolve`. Used by the deploy pipeline
  # (preview → prod promote) to clear the verified queue once the
  # underlying fixes have shipped to production.
  #
  # Returns:
  #   %{resolved_count, resolved_ids, promoted_at}
  #
  # `authorize?: false` is passed both on the read and the per-row
  # update because the deploy pipeline runs system-side; hosts that
  # need actor-scoped authorization should layer policies on the
  # concrete resource and call this action via the code interface,
  # which threads the actor through `context`.

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    candidates =
      input.resource
      |> Ash.Query.for_read(:list_verified_non_preview)
      |> Ash.read!(authorize?: false)

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

defmodule AshFeedback.Changes.ValidateParentFeedback do
  @moduledoc false
  # Used by FeedbackComment's `:create` — blocks comments on a parent
  # feedback that's already `:resolved` or `:dismissed`. Runs as a
  # `before_action` so the changeset can carry the error back to the
  # caller. Adds a `field: :feedback_id` error if the parent doesn't
  # exist.
  #
  # Requires the `:resource` opt — the concrete feedback resource
  # module to fetch the parent from. The resource is host-specific
  # (the macro's caller wires its own `feedback_resource`), so the
  # change cannot infer it from the changeset.

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :resource) do
      {:ok, mod} when is_atom(mod) and not is_nil(mod) -> {:ok, opts}
      _ -> {:error, "AshFeedback.Changes.ValidateParentFeedback requires `:resource` opt"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    resource = Keyword.fetch!(opts, :resource)

    Ash.Changeset.before_action(changeset, fn cs ->
      fid = Ash.Changeset.get_attribute(cs, :feedback_id)

      case Ash.get(resource, fid, authorize?: false) do
        {:ok, %{status: status}} when status in [:resolved, :dismissed] ->
          Ash.Changeset.add_error(cs,
            field: :feedback_id,
            message: "cannot comment on a #{status} feedback"
          )

        {:ok, _} ->
          cs

        {:error, _} ->
          Ash.Changeset.add_error(cs, field: :feedback_id, message: "not found")
      end
    end)
  end
end

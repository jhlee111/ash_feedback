defmodule AshFeedback.Validations.RequireAtLeastOnePrUrl do
  @moduledoc false
  # Used by the `:verify` action — preview-verification requires at
  # least one PR URL on file as the lineage tracker for the fix.

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :pr_urls) do
      [_ | _] -> :ok
      _ -> {:error, field: :pr_urls, message: "at least one PR URL required"}
    end
  end
end

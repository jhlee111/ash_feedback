defmodule AshFeedback.Changes.CoerceReportedOnEnv do
  @moduledoc false
  # Reads `environment` from the `:metadata` map (string OR atom key)
  # and forces it onto the `:reported_on_env` attribute. Used by the
  # `:submit` action of the Feedback resource so legacy clients that
  # stuff the environment into metadata still populate the typed
  # column.

  use Ash.Resource.Change

  alias AshFeedback.Types.Environment

  @impl true
  def change(changeset, _opts, _context) do
    meta = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

    case Map.get(meta, "environment") || Map.get(meta, :environment) do
      value when is_binary(value) and byte_size(value) > 0 ->
        case Environment.cast_input(value, []) do
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

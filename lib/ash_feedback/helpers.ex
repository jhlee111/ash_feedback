defmodule AshFeedback.Helpers do
  @moduledoc false
  # Tiny utility module shared across `Storage` + the controller layer.
  # `import`ed by call sites; not part of the public API.

  @doc """
  Converts atom keys to strings so `Map.merge/2` and JSON encoding
  work cleanly when host-provided maps may carry mixed key types.
  Non-map values pass through unchanged.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  def stringify_keys(other), do: other
end

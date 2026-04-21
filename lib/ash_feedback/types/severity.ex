defmodule AshFeedback.Types.Severity do
  @moduledoc """
  Severity `Ash.Type.Enum` used by `AshFeedback.Resources.Feedback`.

  Stub only; full `use Ash.Type.Enum` definition lands in Phase 4a.
  Values (design target):

    * `:info`     — "Info"
    * `:low`      — "Low"
    * `:medium`   — "Medium"
    * `:high`     — "High"
    * `:critical` — "Critical"

  `icon/1` and `color/1` are provided for the shared
  `EnumBadge`-style components common in Ash-based admin UIs.
  """

  # Implementation lands in Phase 4a.
end

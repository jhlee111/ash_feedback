defmodule AshFeedback.Types.Severity do
  @moduledoc """
  Severity `Ash.Type.Enum` used by `AshFeedback.Resources.Feedback`.

  Values match the client-side widget options:

    * `:info`     — "Info"     (slate)
    * `:low`      — "Low"      (green)
    * `:medium`   — "Medium"   (yellow)
    * `:high`     — "High"     (orange)
    * `:critical` — "Critical" (red)

  `icon/1` and `color/1` follow the GsNet `Ash.Type.Enum` convention
  (CLAUDE.md) so admin tables can render `<.enum_badge type={...}
  value={...}/>` without hardcoding labels.
  """

  use Ash.Type.Enum,
    values: [
      info: "Info",
      low: "Low",
      medium: "Medium",
      high: "High",
      critical: "Critical"
    ]

  @doc "Heroicon name for a severity value, or `nil` if no icon."
  def icon(:critical), do: "hero-fire"
  def icon(:high), do: "hero-exclamation-triangle"
  def icon(:medium), do: "hero-exclamation-circle"
  def icon(:low), do: "hero-information-circle"
  def icon(:info), do: "hero-information-circle"
  def icon(_), do: nil

  @doc "Tailwind color name for a severity value."
  def color(:critical), do: "red"
  def color(:high), do: "orange"
  def color(:medium), do: "yellow"
  def color(:low), do: "green"
  def color(:info), do: "slate"
  def color(_), do: "slate"
end

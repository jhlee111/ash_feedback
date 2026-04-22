defmodule AshFeedback.Types.Priority do
  @moduledoc """
  Triage priority `Ash.Type.Enum` for `AshFeedback.Resources.Feedback`.

  Distinct from `AshFeedback.Types.Severity` — severity is the
  reporter's opinion; priority is the team's.
  """

  use Ash.Type.Enum,
    values: [
      low: "Low",
      medium: "Medium",
      high: "High",
      critical: "Critical"
    ]

  @doc "Heroicon name for a priority value, or `nil` if no icon."
  def icon(:critical), do: "hero-fire"
  def icon(:high), do: "hero-exclamation-triangle"
  def icon(:medium), do: "hero-exclamation-circle"
  def icon(:low), do: "hero-information-circle"
  def icon(_), do: nil

  @doc "Tailwind color name for a priority value."
  def color(:critical), do: "red"
  def color(:high), do: "orange"
  def color(:medium), do: "yellow"
  def color(:low), do: "slate"
  def color(_), do: "slate"
end

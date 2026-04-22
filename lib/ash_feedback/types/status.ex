defmodule AshFeedback.Types.Status do
  @moduledoc """
  Triage status `Ash.Type.Enum` for `AshFeedback.Resources.Feedback`.

  The values form an AshStateMachine with transitions defined on the
  resource. See the `state_machine` block on the Feedback resource for
  the full transition graph.
  """

  use Ash.Type.Enum,
    values: [
      new: "New",
      acknowledged: "Acknowledged",
      in_progress: "In Progress",
      verified_on_preview: "Verified on Preview",
      resolved: "Resolved",
      dismissed: "Dismissed"
    ]

  @doc "Heroicon name for a status value, or `nil` if no icon."
  def icon(:new), do: "hero-inbox"
  def icon(:acknowledged), do: "hero-eye"
  def icon(:in_progress), do: "hero-arrow-path"
  def icon(:verified_on_preview), do: "hero-check-badge"
  def icon(:resolved), do: "hero-check-circle"
  def icon(:dismissed), do: "hero-x-circle"
  def icon(_), do: nil

  @doc "Tailwind color name for a status value."
  def color(:new), do: "blue"
  def color(:acknowledged), do: "slate"
  def color(:in_progress), do: "yellow"
  def color(:verified_on_preview), do: "sky"
  def color(:resolved), do: "green"
  def color(:dismissed), do: "slate"
  def color(_), do: "slate"
end

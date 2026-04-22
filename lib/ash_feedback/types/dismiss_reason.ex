defmodule AshFeedback.Types.DismissReason do
  @moduledoc """
  Required reason for the `:dismiss` transition on
  `AshFeedback.Resources.Feedback`.
  """

  use Ash.Type.Enum,
    values: [
      not_a_bug: "Not a bug",
      wontfix: "Won't fix",
      duplicate: "Duplicate",
      cannot_reproduce: "Cannot reproduce"
    ]

  def icon(_), do: nil

  def color(:not_a_bug), do: "slate"
  def color(:wontfix), do: "slate"
  def color(:duplicate), do: "slate"
  def color(:cannot_reproduce), do: "amber"
  def color(_), do: "slate"
end

defmodule AshFeedback.Types.Environment do
  @moduledoc """
  Deploy-tier enum for `reported_on_env` on `AshFeedback.Resources.Feedback`.

  Populated server-side from host metadata — not client-supplied — so
  the value is trustworthy for the deploy pipeline's promote-blocker
  logic.
  """

  use Ash.Type.Enum,
    values: [
      dev: "Dev",
      staging: "Staging",
      preview: "Preview",
      prod: "Prod"
    ]
end

defmodule AshFeedback.Test.Feedback do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_feedback, validate_config_inclusion?: false

  resources do
    resource AshFeedback.Test.TestFeedback
    resource AshFeedback.Test.TestFeedback.Version
    resource AshFeedback.Test.TestFeedbackComment
  end
end

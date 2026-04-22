defmodule AshFeedback.Test.Accounts do
  @moduledoc false
  use Ash.Domain, otp_app: :ash_feedback, validate_config_inclusion?: false

  resources do
    resource AshFeedback.Test.User
  end
end

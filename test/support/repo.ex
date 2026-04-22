defmodule AshFeedback.Test.Repo do
  @moduledoc false
  use AshPostgres.Repo,
    otp_app: :ash_feedback,
    warn_on_missing_ash_functions?: false

  def installed_extensions, do: []
end

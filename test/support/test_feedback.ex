defmodule AshFeedback.Test.TestFeedback do
  @moduledoc false
  use AshFeedback.Resources.Feedback,
    domain: AshFeedback.Test.Feedback,
    repo: AshFeedback.Test.Repo,
    assignee_resource: AshFeedback.Test.User,
    pubsub: :ash_feedback_test_pubsub
end

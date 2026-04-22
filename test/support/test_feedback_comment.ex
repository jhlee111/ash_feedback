defmodule AshFeedback.Test.TestFeedbackComment do
  @moduledoc false
  use AshFeedback.Resources.FeedbackComment,
    domain: AshFeedback.Test.Feedback,
    repo: AshFeedback.Test.Repo,
    feedback_resource: AshFeedback.Test.TestFeedback,
    author_resource: AshFeedback.Test.User
end

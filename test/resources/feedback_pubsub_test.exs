defmodule AshFeedback.Resources.FeedbackPubSubTest do
  use AshFeedback.Test.DataCase, async: false

  alias AshFeedback.Test.PubSub
  alias AshFeedback.Test.TestFeedback

  test "status_changed event is broadcast on :acknowledge" do
    PubSub.subscribe("feedback:status_changed")

    fb =
      TestFeedback.submit!(
        %{
          session_id: "pubsub-1",
          description: "t",
          severity: :low,
          metadata: %{"environment" => "dev"}
        },
        authorize?: false
      )

    {:ok, _} = TestFeedback.acknowledge(fb.id)

    assert_receive %Ash.Notifier.Notification{data: %{status: :acknowledged}}, 500
  end

  test "created event is broadcast on :submit" do
    PubSub.subscribe("feedback:created")

    _fb =
      TestFeedback.submit!(
        %{
          session_id: "pubsub-2",
          description: "t",
          severity: :low,
          metadata: %{"environment" => "dev"}
        },
        authorize?: false
      )

    assert_receive %Ash.Notifier.Notification{data: %{session_id: "pubsub-2"}}, 500
  end
end

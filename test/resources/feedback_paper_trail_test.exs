defmodule AshFeedback.Resources.FeedbackPaperTrailTest do
  use AshFeedback.Test.DataCase, async: false

  require Ash.Query

  alias AshFeedback.Test.TestFeedback

  test "verify transition creates a version row with status changes" do
    fb =
      TestFeedback.submit!(
        %{
          session_id: "pt-1",
          description: "t",
          severity: :low,
          metadata: %{"environment" => "prod"}
        },
        authorize?: false
      )

    {:ok, fb} = TestFeedback.acknowledge(fb.id)

    {:ok, fb} =
      TestFeedback.verify(fb.id, %{pr_urls: ["https://example.com/pr/42"]})

    assert fb.status == :verified_on_preview

    {:ok, versions} =
      AshFeedback.Test.TestFeedback.Version
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(version_source_id: fb.id)
      |> Ash.Query.sort(version_inserted_at: :asc)
      |> Ash.read(authorize?: false)

    # One version per state-changing action: :submit (create),
    # :acknowledge, :verify.
    assert length(versions) >= 2

    last = List.last(versions)
    assert last.version_action_name == :verify
    assert last.status == :verified_on_preview
    assert last.reported_on_env == :prod
  end
end

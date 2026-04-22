defmodule AshFeedback.Resources.FeedbackCommentTest do
  use AshFeedback.Test.DataCase, async: false

  alias AshFeedback.Test.TestFeedback
  alias AshFeedback.Test.TestFeedbackComment
  alias AshFeedback.Test.User

  describe "FeedbackComment.:create" do
    test "creates a comment attached to an active feedback" do
      fb = submit!("c-1")
      user = user!("alice@example.com")

      {:ok, comment} =
        TestFeedbackComment.create_comment(%{
          feedback_id: fb.id,
          author_id: user.id,
          body: "nice repro"
        })

      assert comment.feedback_id == fb.id
      assert comment.author_id == user.id
      assert comment.body == "nice repro"
      assert %DateTime{} = comment.inserted_at
    end

    test "rejects comments on :resolved feedback" do
      fb =
        submit!("c-resolved")
        |> transition!(:acknowledge)
        |> transition!(:verify, %{pr_urls: ["https://example.com/pr"]})
        |> transition!(:resolve)

      user = user!("alice2@example.com")

      assert {:error, _} =
               TestFeedbackComment.create_comment(%{
                 feedback_id: fb.id,
                 author_id: user.id,
                 body: "late to the party"
               })
    end

    test "rejects comments on :dismissed feedback" do
      fb =
        submit!("c-dismissed")
        |> transition!(:dismiss, %{reason: :not_a_bug})

      user = user!("alice3@example.com")

      assert {:error, _} =
               TestFeedbackComment.create_comment(%{
                 feedback_id: fb.id,
                 author_id: user.id,
                 body: "no"
               })
    end

    test ":list_by_feedback returns comments sorted by inserted_at asc" do
      fb = submit!("c-list")
      u = user!("lister@example.com")

      {:ok, _c1} =
        TestFeedbackComment.create_comment(%{
          feedback_id: fb.id,
          author_id: u.id,
          body: "first"
        })

      # tiny delay so timestamps differ
      Process.sleep(5)

      {:ok, _c2} =
        TestFeedbackComment.create_comment(%{
          feedback_id: fb.id,
          author_id: u.id,
          body: "second"
        })

      {:ok, comments} = TestFeedbackComment.list_by_feedback(fb.id)

      assert Enum.map(comments, & &1.body) == ["first", "second"]
    end
  end

  # --- helpers ---

  defp submit!(session) do
    TestFeedback.submit!(
      %{
        session_id: session,
        description: "t",
        severity: :low,
        metadata: %{"environment" => "dev"}
      },
      authorize?: false
    )
  end

  defp transition!(fb, :acknowledge) do
    {:ok, fb} = TestFeedback.acknowledge(fb.id)
    fb
  end

  defp transition!(fb, :resolve) do
    {:ok, fb} = TestFeedback.resolve(fb.id)
    fb
  end

  defp transition!(fb, :verify, args) do
    {:ok, fb} = TestFeedback.verify(fb.id, args)
    fb
  end

  defp transition!(fb, :dismiss, args) do
    {:ok, fb} = TestFeedback.dismiss(fb.id, args)
    fb
  end

  defp user!(email) do
    User
    |> Ash.Changeset.for_create(:create, %{email: email})
    |> Ash.create!(authorize?: false)
  end
end

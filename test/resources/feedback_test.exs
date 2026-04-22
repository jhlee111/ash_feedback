defmodule AshFeedback.Resources.FeedbackTest do
  use AshFeedback.Test.DataCase, async: false

  alias AshFeedback.Test.TestFeedback
  alias AshFeedback.Test.User

  describe "state machine transitions" do
    test "new → acknowledged via :acknowledge" do
      fb = submit_feedback!(session: "s1")
      assert fb.status == :new

      {:ok, fb} = TestFeedback.acknowledge(fb.id)
      assert fb.status == :acknowledged
    end

    test ":assign transitions to :in_progress + sets assignee_id" do
      user = create_user!("alice@example.com")
      fb = submit_feedback!(session: "s-assign") |> acknowledge!()

      {:ok, fb} = TestFeedback.assign(fb.id, %{assignee_id: user.id})
      assert fb.status == :in_progress
      assert fb.assignee_id == user.id
    end

    test ":verify requires at least one pr_url, stamps verified_at" do
      fb =
        submit_feedback!(session: "s-verify")
        |> acknowledge!()

      # missing pr_urls → validation error
      assert {:error, _} = TestFeedback.verify(fb.id, %{pr_urls: []})

      {:ok, fb} =
        TestFeedback.verify(fb.id, %{pr_urls: ["https://example.com/pr/1"]})

      assert fb.status == :verified_on_preview
      assert fb.pr_urls == ["https://example.com/pr/1"]
      assert %DateTime{} = fb.verified_at
    end

    test ":resolve only reachable from :verified_on_preview" do
      fb = submit_feedback!(session: "s-resolve-invalid") |> acknowledge!()

      # Can't resolve directly from :acknowledged
      assert {:error, _} = TestFeedback.resolve(fb.id)
    end

    test ":dismiss with reason works from any active state" do
      fb = submit_feedback!(session: "s-dismiss")

      {:ok, fb} = TestFeedback.dismiss(fb.id, %{reason: :not_a_bug})
      assert fb.status == :dismissed
      assert fb.dismissed_reason == :not_a_bug
    end

    test ":dismiss with unknown reason returns type error" do
      fb = submit_feedback!(session: "s-dismiss-bad")
      assert {:error, _} = TestFeedback.dismiss(fb.id, %{reason: :no_such_reason})
    end
  end

  describe "promote_verified_to_resolved" do
    test "transitions verified_on_preview rows except :preview-origin" do
      # Verified, not preview-origin → should be resolved
      f1 = verified_feedback!(session: "p1", env: :prod)
      # Verified, preview-origin → should be skipped
      f2 = verified_feedback!(session: "p2", env: :preview)
      # Not verified → should be skipped
      _f3 = submit_feedback!(session: "p3")

      {:ok, result} =
        TestFeedback.promote_verified_to_resolved(%{promoted_at: DateTime.utc_now()})

      assert result.resolved_count == 1
      assert f1.id in result.resolved_ids
      refute f2.id in result.resolved_ids

      {:ok, f1_reloaded} = TestFeedback.get_feedback(f1.id)
      assert f1_reloaded.status == :resolved
      assert %DateTime{} = f1_reloaded.resolved_at

      {:ok, f2_reloaded} = TestFeedback.get_feedback(f2.id)
      assert f2_reloaded.status == :verified_on_preview
    end
  end

  describe "reported_on_env from submit metadata" do
    test "metadata.environment is captured on :submit" do
      fb = submit_feedback!(session: "env-1", metadata: %{"environment" => "staging"})
      assert fb.reported_on_env == :staging
    end

    test "invalid environment value is ignored" do
      fb = submit_feedback!(session: "env-2", metadata: %{"environment" => "mars"})
      assert is_nil(fb.reported_on_env)
    end
  end

  # --- helpers ---

  defp submit_feedback!(opts) do
    attrs = %{
      session_id: Keyword.fetch!(opts, :session),
      description: Keyword.get(opts, :description, "test"),
      severity: Keyword.get(opts, :severity, :low),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    TestFeedback.submit!(attrs, authorize?: false)
  end

  defp acknowledge!(fb) do
    {:ok, fb} = TestFeedback.acknowledge(fb.id)
    fb
  end

  defp verified_feedback!(opts) do
    session = Keyword.fetch!(opts, :session)
    env = Keyword.get(opts, :env, :prod)

    submit_feedback!(session: session, metadata: %{"environment" => to_string(env)})
    |> acknowledge!()
    |> then(fn fb ->
      {:ok, fb} = TestFeedback.verify(fb.id, %{pr_urls: ["https://example.com/pr"]})
      fb
    end)
  end

  defp create_user!(email) do
    User
    |> Ash.Changeset.for_create(:create, %{email: email})
    |> Ash.create!(authorize?: false)
  end
end

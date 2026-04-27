defmodule Mix.Tasks.AshFeedback.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "configure_storage patcher" do
    test "sets :phoenix_replay :storage to AshFeedback.Storage on a blank project" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])

      igniter
      |> assert_has_patch("config/config.exs", """
      | config :phoenix_replay,
      """)
      |> assert_has_patch("config/config.exs", """
      | storage:
      """)
      |> assert_has_patch("config/config.exs", """
      | {AshFeedback.Storage,
      """)
      |> assert_has_patch("config/config.exs", """
      | resource: TestApp.Feedback.Entry,
      """)
      |> assert_has_patch("config/config.exs", """
      | repo: TestApp.Repo}
      """)
    end

    test "is idempotent — re-running over its own output produces no further changes" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "ash_feedback.install", [])

      assert_unchanged(second, "config/config.exs")
    end

    test "overrides an existing PhoenixReplay.Storage.Ecto :storage config" do
      igniter =
        test_project(
          app_name: :test_app,
          files: %{
            "config/config.exs" => """
            import Config

            config :phoenix_replay,
              storage: {PhoenixReplay.Storage.Ecto, repo: TestApp.Repo}
            """
          }
        )
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      content =
        igniter.rewrite
        |> Rewrite.source!("config/config.exs")
        |> Rewrite.Source.get(:content)

      assert content =~ "AshFeedback.Storage"
      assert content =~ "resource: TestApp.Feedback.Entry"
      refute content =~ "PhoenixReplay.Storage.Ecto"
    end
  end
end

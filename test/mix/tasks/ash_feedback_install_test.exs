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

  describe "domain generation patcher" do
    test "creates HostApp.Feedback domain and registers it" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      domain_path = "lib/test_app/feedback.ex"

      domain_content =
        igniter.rewrite
        |> Rewrite.source!(domain_path)
        |> Rewrite.Source.get(:content)

      assert domain_content =~ "defmodule TestApp.Feedback do"
      assert domain_content =~ "use Ash.Domain"
      assert domain_content =~ "otp_app: :test_app"
      assert domain_content =~ "resources do"
      assert domain_content =~ "resource(TestApp.Feedback.Entry)"
      assert domain_content =~ "resource(TestApp.Feedback.Entry.Version)"

      config_content =
        igniter.rewrite
        |> Rewrite.source!("config/config.exs")
        |> Rewrite.Source.get(:content)

      assert config_content =~ "ash_domains:"
      assert config_content =~ "TestApp.Feedback"
    end

    test "is idempotent on the domain module + ash_domains list" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "ash_feedback.install", [])

      assert_unchanged(second, "lib/test_app/feedback.ex")
      assert_unchanged(second, "config/config.exs")
    end
  end
end

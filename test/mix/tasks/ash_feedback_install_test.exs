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

  describe "audio storage resources" do
    test "generates Blob and Attachment modules with the expected shape" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      blob =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/storage/blob.ex")
        |> Rewrite.Source.get(:content)

      assert blob =~ "defmodule TestApp.Storage.Blob do"
      assert blob =~ "extensions: [AshStorage.BlobResource]"
      assert blob =~ ~S|table("blobs")|
      assert blob =~ "repo(TestApp.Repo)"
      assert blob =~ "blob do"

      attachment =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/storage/attachment.ex")
        |> Rewrite.Source.get(:content)

      assert attachment =~ "defmodule TestApp.Storage.Attachment do"
      assert attachment =~ "extensions: [AshStorage.AttachmentResource]"
      assert attachment =~ ~S|table("attachments")|
      assert attachment =~ "blob_resource(TestApp.Storage.Blob)"
      assert attachment =~ "belongs_to_resource(:feedback, TestApp.Feedback.Entry)"
      assert attachment =~ "reference(:feedback, on_delete: :delete)"
    end

    test "registers Blob + Attachment in the Feedback domain" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      domain =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/feedback.ex")
        |> Rewrite.Source.get(:content)

      assert domain =~ "resource(TestApp.Storage.Blob)"
      assert domain =~ "resource(TestApp.Storage.Attachment)"
    end

    test "writes a Disk service config for the Feedback.Entry resource in dev.exs" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      dev =
        igniter.rewrite
        |> Rewrite.source!("config/dev.exs")
        |> Rewrite.Source.get(:content)

      assert dev =~ "config :test_app, TestApp.Feedback.Entry"
      assert dev =~ "AshStorage.Service.Disk"
      assert dev =~ "Path.join("
      assert dev =~ ~s("tmp/uploads")
      assert dev =~ "direct_upload: true"
    end

    test "is idempotent — re-running leaves Blob, Attachment, and dev.exs alone" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "ash_feedback.install", [])

      assert_unchanged(second, "lib/test_app/storage/blob.ex")
      assert_unchanged(second, "lib/test_app/storage/attachment.ex")
      assert_unchanged(second, "config/dev.exs")
    end
  end

  describe "concrete Feedback.Entry resource" do
    test "generates Feedback.Entry with required opts; omits assignee/pubsub on a user-less project" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      entry =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/feedback/entry.ex")
        |> Rewrite.Source.get(:content)

      assert entry =~ "defmodule TestApp.Feedback.Entry do"
      assert entry =~ "use AshFeedback.Resources.Feedback"
      assert entry =~ "otp_app: :test_app"
      assert entry =~ "domain: TestApp.Feedback"
      assert entry =~ "repo: TestApp.Repo"
      assert entry =~ "audio_blob_resource: TestApp.Storage.Blob"
      assert entry =~ "audio_attachment_resource: TestApp.Storage.Attachment"

      # No User / PubSub modules in the test fixture, so those opts
      # are omitted entirely. Host adds them later by hand.
      refute entry =~ "assignee_resource:"
      refute entry =~ "pubsub:"
    end

    test "wires assignee_resource + pubsub when User and PubSub modules exist" do
      igniter =
        test_project(
          app_name: :test_app,
          files: %{
            "lib/test_app/accounts/user.ex" => """
            defmodule TestApp.Accounts.User do
              defstruct []
            end
            """,
            "lib/test_app/pubsub.ex" => """
            defmodule TestApp.PubSub do
              defstruct []
            end
            """
          }
        )
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      entry =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/feedback/entry.ex")
        |> Rewrite.Source.get(:content)

      assert entry =~ "assignee_resource: TestApp.Accounts.User"
      assert entry =~ "pubsub: TestApp.PubSub"
    end

    test "is idempotent on Feedback.Entry" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "ash_feedback.install", [])

      assert_unchanged(second, "lib/test_app/feedback/entry.ex")
    end
  end

  describe "Feedback.Comment resource" do
    test "generates Feedback.Comment and registers it in the domain" do
      igniter =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      comment =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/feedback/comment.ex")
        |> Rewrite.Source.get(:content)

      assert comment =~ "defmodule TestApp.Feedback.Comment do"
      assert comment =~ "use AshFeedback.Resources.FeedbackComment"
      assert comment =~ "domain: TestApp.Feedback"
      assert comment =~ "repo: TestApp.Repo"
      assert comment =~ "feedback_resource: TestApp.Feedback.Entry"

      domain =
        igniter.rewrite
        |> Rewrite.source!("lib/test_app/feedback.ex")
        |> Rewrite.Source.get(:content)

      assert domain =~ "resource(TestApp.Feedback.Comment)"
    end

    test "is idempotent on Feedback.Comment" do
      first =
        test_project(app_name: :test_app)
        |> Igniter.compose_task("ash_feedback.install", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "ash_feedback.install", [])

      assert_unchanged(second, "lib/test_app/feedback/comment.ex")
    end
  end
end

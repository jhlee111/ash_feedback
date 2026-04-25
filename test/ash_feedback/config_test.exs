defmodule AshFeedback.ConfigTest do
  use ExUnit.Case, async: false

  alias AshFeedback.Config

  test "feedback_resource! returns the configured resource" do
    Application.put_env(:ash_feedback, :feedback_resource, MyApp.FakeResource)
    on_exit(fn -> Application.delete_env(:ash_feedback, :feedback_resource) end)

    assert Config.feedback_resource!() == MyApp.FakeResource
  end

  test "feedback_resource! raises when not configured" do
    Application.delete_env(:ash_feedback, :feedback_resource)

    assert_raise RuntimeError, ~r/config :ash_feedback, :feedback_resource/, fn ->
      Config.feedback_resource!()
    end
  end

  test "audio_attachment_resource! returns the configured resource" do
    Application.put_env(:ash_feedback, :audio_attachment_resource, MyApp.FakeAttachment)
    on_exit(fn -> Application.delete_env(:ash_feedback, :audio_attachment_resource) end)

    assert Config.audio_attachment_resource!() == MyApp.FakeAttachment
  end

  test "audio_attachment_resource! raises with a helpful message when not configured" do
    Application.delete_env(:ash_feedback, :audio_attachment_resource)

    assert_raise RuntimeError, ~r/config :ash_feedback, :audio_attachment_resource/, fn ->
      Config.audio_attachment_resource!()
    end
  end

  test "audio_max_seconds defaults to 300" do
    Application.delete_env(:ash_feedback, :audio_max_seconds)
    assert Config.audio_max_seconds() == 300
  end

  test "audio_max_seconds returns the configured value" do
    Application.put_env(:ash_feedback, :audio_max_seconds, 60)
    on_exit(fn -> Application.delete_env(:ash_feedback, :audio_max_seconds) end)
    assert Config.audio_max_seconds() == 60
  end
end

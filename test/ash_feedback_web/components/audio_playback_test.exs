defmodule AshFeedbackWeb.Components.AudioPlaybackTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AshFeedbackWeb.Components.AudioPlayback

  test "renders nothing when audio_url is nil" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: nil,
        audio_start_offset_ms: 0,
        session_id: "sess-1"
      })

    assert html == "" or html =~ ~r/\A\s*\z/
  end

  test "renders the hook container + <audio> element with expected data attrs" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: "/api/audio/audio_downloads/blob-abc",
        audio_start_offset_ms: 1234,
        session_id: "sess-xyz"
      })

    assert html =~ ~s(phx-hook="AudioPlayback")
    assert html =~ ~s(data-session-id="sess-xyz")
    assert html =~ ~s(data-offset-ms="1234")
    assert html =~ ~s(data-url="/api/audio/audio_downloads/blob-abc")
    assert html =~ ~s(<audio)
    assert html =~ ~s(controls)
    assert html =~ ~s(preload="metadata")
  end

  test "uses a stable id derived from session_id" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: "/x",
        audio_start_offset_ms: 0,
        session_id: "sess-stable"
      })

    assert html =~ ~s(id="audio-playback-sess-stable")
  end
end

defmodule AshFeedbackWeb.Components.AudioPlayback do
  @moduledoc """
  Drop-in admin-side primitive that plays an audio clip in lock-step
  with rrweb-player. Renders a `phx-hook` container around an `<audio>`
  element; `priv/static/assets/audio_playback.js` does the sync work.

  Host responsibility:
    1. Load the feedback's `:audio_clip` attachment (and its blob).
    2. Pull `audio_start_offset_ms` from `blob.metadata` (default 0).
    3. Build `audio_url` from `AshFeedback.Router.audio_routes/1`'s
       show endpoint, e.g. `~p"/api/audio/audio_downloads/\#{blob.id}"`.
    4. Render this component next to `<.replay_player session_id={...}>`.

  When `audio_url` is nil this component renders nothing — host can pass
  `audio_url={nil}` unconditionally to avoid an `:if` wrapper.
  """

  use Phoenix.Component

  attr :audio_url, :string, default: nil
  attr :audio_start_offset_ms, :integer, default: 0
  attr :session_id, :string, required: true

  def audio_playback(%{audio_url: nil} = assigns), do: ~H""

  def audio_playback(assigns) do
    ~H"""
    <div
      id={"audio-playback-#{@session_id}"}
      phx-hook="AudioPlayback"
      data-session-id={@session_id}
      data-offset-ms={@audio_start_offset_ms}
      data-url={@audio_url}
    >
      <audio controls preload="metadata"></audio>
    </div>
    """
  end
end

# Audio Narration Guide

Voice commentary on feedback submissions, end-to-end. The reporter taps 🎙 in the widget panel, records a short clip, and submits; the audio file rides through [AshStorage](https://github.com/ash-project/ash_storage) (presigned upload to S3, MinIO, Disk, or any compatible backend) and links to the feedback row. The admin replay view plays the clip in lock-step with the rrweb cursor.

**Status**: core feature since 2026-04-26 — `:ash_storage` is a hard dep, no compile-time toggle. ADR-0001 Question B addendum captures the promotion. Cross-browser smoke verified in Chrome; Safari smoke pending.

**Driving ADRs**:
- [`0001-audio-narration-via-ash-storage.md`](../decisions/0001-audio-narration-via-ash-storage.md) — storage choice + sync-rule design (with the 2026-04-25 Question D addendum dropping start-offset and the 2026-04-26 Question B addendum promoting AshStorage to core)
- [phoenix_replay's `0005-replay-player-timeline-event-bus.md`](https://github.com/jhlee111/phoenix_replay/blob/main/docs/decisions/0005-replay-player-timeline-event-bus.md) — the JS API the admin playback subscribes to

> **Already running `mix igniter.install ash_feedback`?** The installer
> ships steps 1–5 of the **Setup** section — Blob + Attachment
> resources, the Disk service config in `dev.exs`, and the audio opts on
> the macro. You can skip to **Recording side (widget)**.

---

## When does audio actually help?

Two distinct feedback report paths exist, only one of which makes audio meaningful:

| Path | Recording mode | Trigger label | Audio? |
|---|---|---|---|
| **Quick report** | `:continuous` | "Report issue" | **No** — replay timeline predates the voice note by minutes |
| **Record and report** | `:on_demand` | "Record and report" | **Yes** — both start at the same moment, audio syncs to timeline |

The audio recorder addon enforces this — it declares `paths: ["record_and_report"]` at registration time, so the 🎙 button only appears when the user picks Record-and-report from the entry panel. On Quick-report (Path A) the addon is silently skipped. Hosts whose `allow_paths` excludes `:record_and_report` get the description-only experience automatically.

Control style (`:float` vs `:headless`) is independent — both can host either recording mode.

See [phoenix_replay's mode-aware panel-addons spec](https://github.com/jhlee111/phoenix_replay/blob/main/docs/superpowers/specs/2026-04-25-mode-aware-panel-addons.md) for the full IA framework.

---

## Setup

### 1. Confirm `ash_storage` is in your dep tree

`ash_feedback` lists `ash_storage` as a hard dependency, so it comes
transitively when you add `:ash_feedback` to `mix.exs`. No extra
deps line is needed.

(Pre-Hex; tracks `ash-project/ash_storage`'s `main` branch until it
cuts a release.)

### 2. Define your `Blob` and `Attachment` AshStorage resources

AshStorage is host-owned — you define the resources, not the
library. `mix igniter.install ash_feedback` scaffolds a minimal
Postgres-backed pair (`<HostApp>.Storage.Blob` and
`<HostApp>.Storage.Attachment`) registered in your Feedback domain.
For richer setups (custom `blob` block, AshOban triggers, alternative
auth), copy the AshStorage dev resources and adapt:

- [`dev/resources/blob.ex`](https://github.com/ash-project/ash_storage/blob/main/dev/resources/blob.ex) in the AshStorage repo
- [`dev/resources/attachment.ex`](https://github.com/ash-project/ash_storage/blob/main/dev/resources/attachment.ex)

### 3. Configure the storage service

For dev — file-backed Disk service, no external infra:

```elixir
# config/dev.exs
config :my_app, MyApp.Feedback.Entry,
  storage: [
    services: [
      default: {AshStorage.Service.Disk, root: "tmp/uploads", base_url: "http://localhost:4000"}
    ]
  ]
```

For prod — S3 (or any S3-compatible backend like MinIO):

```elixir
# config/prod.exs
config :my_app, MyApp.Feedback.Entry,
  storage: [
    services: [
      default: {AshStorage.Service.S3, bucket: "my-feedback-audio", region: "us-east-1"}
    ]
  ]
```

### 4. Configure `ash_feedback` runtime keys

```elixir
# config/config.exs
config :ash_feedback,
  feedback_resource: MyApp.Feedback.Entry,
  audio_attachment_resource: MyApp.Storage.Attachment,
  audio_max_seconds: 300,                # default
  audio_download_url_ttl_seconds: 1800   # default — 30 min, see Admin playback section
```

### 5. Pass the storage resources to the macro

```elixir
defmodule MyApp.Feedback.Entry do
  use AshFeedback.Resources.Feedback,
    otp_app: :my_app,
    domain: MyApp.Feedback,
    repo: MyApp.Repo,
    audio_blob_resource: MyApp.Storage.Blob,
    audio_attachment_resource: MyApp.Storage.Attachment
end
```

`otp_app:` is required so AshStorage's per-resource service config resolves at runtime. Both `:audio_blob_resource` and `:audio_attachment_resource` are required — the macro raises a guided `ArgumentError` if either is missing.

### 6. Codegen + migrate

```bash
mix ash.codegen audio_storage
mix ash.migrate
```

This generates the migrations for the two storage tables (Blob + Attachment).

---

## Recording side (widget)

### Browser asset wiring

In your root layout — load the recorder CSS in `<head>` and the recorder JS at the **end** of `<body>`, after the `phoenix_replay` widget element so the addon registers before the panel mounts:

```heex
<link rel="stylesheet" href={~p"/assets/ash_feedback/audio_recorder.css"} />
...
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  recording={:on_demand}
/>
<script defer src={~p"/assets/ash_feedback/audio_recorder.js"}></script>
```

Add a `Plug.Static` entry serving `ash_feedback/priv/static/assets`:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/assets/ash_feedback",
  from: {:ash_feedback, "priv/static/assets"}
```

### Router — mount the prepare + download endpoints

```elixir
# lib/my_app_web/router.ex
import AshFeedback.Router, only: [audio_routes: 1]

scope "/" do
  pipe_through :browser
  audio_routes()                       # default mount: /audio_uploads/...
  # OR custom prefix:
  # audio_routes(path: "/api/audio")   # → /api/audio/prepare + /api/audio/audio_downloads/:id
end
```

The macro mounts:
- `POST <path>/prepare` — minted by the recorder before each upload
- `GET <path>/audio_downloads/:blob_id` — admin playback endpoint (302 to a signed URL)

Both routes need to live behind whatever auth guards the feedback admin (the host pipeline).

### Browser support

- Chrome / Firefox / Edge — `audio/webm; codecs=opus` (primary)
- Safari — `audio/mp4; codecs=mp4a.40.2` (fallback)
- No supported codec → mic button disabled with a tooltip; the rest of the form remains usable
- Microphone permission denied → inline notice; the user can still submit without audio
- Length cap enforced client-side via `audio_max_seconds`

---

## Admin playback (Phase 3)

A function component drops the synced `<audio>` element next to your existing rrweb player. Host owns the data load; the component is intentionally dumb.

### 1. Render the component

In your admin feedback detail LiveView template:

```heex
<PhoenixReplay.UI.Components.replay_player
  id={"player-#{@selected.id}"}
  session_id={@selected.session_id}
  events_url={~p"/admin/feedback/events/#{@selected.session_id}"}
  height={600}
/>

<AshFeedbackWeb.Components.AudioPlayback.audio_playback
  audio_url={@audio_url}
  session_id={@selected.session_id}
/>
```

`audio_url` may be `nil` — the component renders nothing in that case, so wrapping `<:if>` is unnecessary. Audio is session-equivalent (recording starts at the rrweb session boundary), so the component takes only the URL — no offset.

> **Note**: pass `session_id` to `<.replay_player>` explicitly. Without it, the player's hook falls back to `el.id` as the timeline-bus scope and the audio component will subscribe under a different sessionId, getting zero ticks.

### 2. Load `:audio_clip` and derive the URL

```elixir
# lib/my_app_web/admin/feedback_live.ex
defp load_selected(socket, id) do
  feedback =
    MyApp.Feedback.Entry
    |> Ash.get!(id, load: [audio_clip: [:blob]])

  socket
  |> assign(:selected, feedback)
  |> assign(:audio_url, audio_url(feedback))
end

defp audio_url(%{audio_clip: %{blob: %{id: blob_id}}}),
  # Adjust the path prefix to match your `audio_routes/1` mount.
  do: "/audio_uploads/audio_downloads/" <> blob_id

defp audio_url(_), do: nil
```

### 3. Wire the JS hook into LiveSocket

```javascript
// assets/js/app.js
import "../../deps/ash_feedback/priv/static/assets/audio_playback.js";

const hooks = {
  ...(window.AshFeedback?.Hooks || {}),
  // your existing hooks...
};

const liveSocket = new LiveSocket("/live", Socket, { hooks /* ... */ });
```

The hook auto-registers on `window.AshFeedback.Hooks` when the script loads, so the spread picks it up.

### Sync rules (Phase 3 D3)

The hook subscribes to `PhoenixReplayAdmin.subscribeTimeline(sessionId, callback, {tick_hz: 10})` and reconciles the `<audio>` element on each event:

| Event from `subscribeTimeline` | Action |
|---|---|
| `play` | `audio.play()` |
| `pause` | `audio.pause()` |
| `seek` | `audio.currentTime = timecode_ms / 1000` |
| `tick` | Drift correction (>200ms) |
| `ended` | `audio.pause()` |
| **all events** | Track `detail.speed`; write to `audio.playbackRate` whenever it changes (no dedicated `:speed_changed` kind) |

`audio.play()` may be rejected by the browser's autoplay policy — the hook silently catches the rejection. The user can click the `<audio controls>` element to start manually.

### TTL

The `GET /audio_downloads/:blob_id` endpoint mints a signed URL via AshStorage and 302-redirects. Default TTL is 30 minutes (`audio_download_url_ttl_seconds`). Long enough that scrub/pause cycles on a single mount don't outrun the URL; short enough to bound token exposure. LiveView reconnect re-mounts and gets a fresh URL.

---

## Server-side test fixtures

The library's own tests use the in-memory `AshStorage.Service.Test` for round-trip coverage. Hosts running their own audio integration tests can do the same:

```elixir
setup do
  AshStorage.Service.Test.start()
  AshStorage.Service.Test.reset!()
  :ok
end
```

For TTL behavior the Test service ignores `:expires_in` — switch to `Service.Disk` with a `secret` set to actually exercise the signed-URL pathway.

---

## Decisions log

| ADR / Spec | Decision | Status |
|---|---|---|
| ADR-0001 Q-A | AshStorage as the file store | unchanged |
| ADR-0001 Q-B | AshStorage **core dep** (was optional) | superseded 2026-04-26 — see addendum |
| ADR-0001 Q-C | Inline pill recorder UX | shipped Phase 2 |
| ADR-0001 Q-D | Sync rules — single-clip-per-session, no offset | superseded 2026-04-26 — offset always 0 |
| ADR-0001 Q-E | Cascade retention via AshStorage | unchanged |
| Phase 3 D1 | `<.audio_playback>` is a dumb function component | shipped |
| Phase 3 D2 | `GET /audio_downloads/:blob_id` 302 redirect | shipped |
| Phase 3 D4 | `tick_hz: 10` (was 60) | shipped |
| Phase 5f | Igniter installer scaffolds Blob/Attachment + service | shipped 2026-04-26 |
| phoenix_replay 2026-04-25 D2 | Mode-aware panel-addon API | shipped |

---

## See also

- [`docs/guides/demo-project.md`](demo-project.md) — stand up a fresh Phoenix+Ash app and exercise the library end-to-end (audio steps included)
- [`docs/decisions/0001-audio-narration-via-ash-storage.md`](../decisions/0001-audio-narration-via-ash-storage.md) — the source ADR
- [`docs/superpowers/specs/2026-04-25-audio-narration-phase-3-design.md`](../superpowers/specs/2026-04-25-audio-narration-phase-3-design.md) — Phase 3 design notes
- [phoenix_replay's mode-aware panel-addons spec](https://github.com/jhlee111/phoenix_replay/blob/main/docs/superpowers/specs/2026-04-25-mode-aware-panel-addons.md) — the IA framework that gates audio to Path B

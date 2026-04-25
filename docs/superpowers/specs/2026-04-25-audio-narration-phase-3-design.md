# Design: Audio Narration Phase 3 — Admin Playback Synced to rrweb Timeline

**Date**: 2026-04-25
**Owners**: ash_feedback (primary)
**Driving plan**: [`ash_feedback/docs/plans/active/2026-04-24-audio-narration.md`](../../plans/active/2026-04-24-audio-narration.md) (Phase 3)
**ADR**: [`ash_feedback/docs/decisions/0001-audio-narration-via-ash-storage.md`](../../decisions/0001-audio-narration-via-ash-storage.md) — Question D revised here
**Status**: Draft — supersedes the Phase 3 sketch in the active plan; brainstorm session of 2026-04-25 produced the architectural decisions captured here.

## Context

Phases 1 + 2 shipped the recording side end-to-end: opt-in `has_one_attached :audio_clip`, a `MediaRecorder`-backed pill in the widget panel, a presigned-upload controller, and the `:submit` action accepting `audio_clip_blob_id` with `audio_start_offset_ms` persisted on the AshStorage Blob's built-in `metadata` map (per the revised D2 from Phase 2's addendum).

Phase 3 closes the loop: in an admin replay view, an `<audio>` element plays in lock-step with rrweb-player. The host renders both side-by-side; ash_feedback ships only the audio primitive.

Two facts shape the design that the original ADR-0001 Question D could not anticipate:

1. **`PhoenixReplayAdmin.subscribeTimeline` (ADR-0005 Phase 2) emits `play`, `pause`, `seek`, `ended`, `tick` — and carries `speed` as a field on every event detail, not as a dedicated `:speed_changed` kind.** The Phase-3 sync rules need to read `speed` from any incoming event rather than wait for a kind that never arrives.
2. **AshStorage exposes `Token.signed_url/4` and `Service.download/2` but no `prepare_direct_download` helper.** The download path needs a thin redirect controller to give `<audio>` something stable to point at.

## Architectural decisions

### D1 — `<.audio_playback>` is a dumb function component

ash_feedback ships a Phoenix function component at `lib/ash_feedback_web/components/audio_playback.ex` taking three attrs:

- `audio_url` (string, required) — what the `<audio>` element points at.
- `audio_start_offset_ms` (integer, default `0`) — milliseconds into the rrweb timeline where audio t=0 lives.
- `session_id` (string, required) — phoenix_replay session to subscribe to.

The host LV is responsible for: (a) loading the feedback's `:audio_clip` attachment + its blob, (b) extracting `metadata["audio_start_offset_ms"]`, (c) constructing the download URL via the route helper, (d) deciding whether to render the component at all (nil-safe — host short-circuits when no audio is attached).

**Alternatives rejected:**
- Smart LiveComponent over `feedback_id` — pulls AshStorage and authorization concerns into ash_feedback's render path, blurs the "primitive vs. UI" boundary that 5g (gated admin LV) is meant to handle separately.
- Hybrid (`%Feedback{}` + internal `Ash.load!`) — less flexible than the dumb shape and still couples the component to the resource.

### D2 — Download endpoint: `GET /:blob_id` redirects to a signed URL

A new `lib/ash_feedback/controller/audio_downloads_controller.ex` exposes `GET /audio_downloads/:blob_id`. It looks up the AshStorage Blob, mints a signed URL via `Token.signed_url/4` (Disk) or the equivalent `Service.download/2` shape (S3 presigned GET), and 302-redirects.

The `AshFeedback.Router.audio_routes/1` macro is extended to mount the show route alongside the existing prepare route — host call site stays a single line.

**TTL**: `Application.get_env(:ash_feedback, :audio_download_url_ttl_seconds, 1800)` — default 30 minutes. Long enough that scrub/pause cycles on the same mount don't outrun the URL; short enough that token leakage in browser history is bounded. Hosts override per policy.

**Authorization**: the host's existing admin pipeline guards the parent LV, and the route is mounted inside that pipeline. ash_feedback adds no new authorization layer.

**Alternatives rejected:**
- LV mount-time URL injection — fixes URL expiry to mount time; doesn't refresh on long-lived pages, debugging the resulting 401 is awful.
- Component-level JSON fetch for the URL — adds a request without buying anything over the redirect.

### D3 — Sync rules (Phase-3 follow-up to ADR-0001 Question D)

The original Question D rules pre-date the ADR-0005 implementation. They get a small revision based on what the JS actually emits:

| Event from `subscribeTimeline` | Handler |
|---|---|
| `play` | `audio.play()` if `timecode_ms ≥ offset`, else noop (offset crossing during `tick` will start it) |
| `pause` | `audio.pause()` |
| `seek` | `audio.currentTime = max(0, (timecode_ms - offset) / 1000)`; if `timecode_ms < offset` → `audio.pause()`, else if the last state event we saw was `:play` (with no subsequent `:pause` or `:ended`) → `audio.play()` |
| `tick` | Compare `audio.currentTime` to target; if drift > `200ms` set it. Auto-handles offset boundary crossing (start audio when cursor enters the playable window, pause it when scrubbing back below offset). |
| `ended` | `audio.pause()` (was missing from the original Question D) |
| **all events** | If `detail.speed` differs from last seen value, `audio.playbackRate = speed`. Speed is delivered as a field on every event — there is no `:speed_changed` kind. |

`audio.play()` may be rejected by the browser's autoplay policy if the user-gesture chain is too long. We catch the rejected promise and silently noop — the player keeps advancing, the audio stays paused, the user can resume by clicking a control. (Concrete UX for this fallback is out of scope for Phase 3.)

### D4 — `tick_hz: 10`

Plan originally said 60Hz. Lowering to ADR-0005's default of 10Hz:

- With `playbackRate` matched to the player, `<audio>` drifts <1ms per 100ms — well under the ~100ms threshold for perceptual sync.
- 60Hz means a `setInterval` firing every 16ms forever per mount; ash_feedback would become the heaviest tick consumer in the system without empirical justification.
- The component can expose a `tick_hz` attr later if a host measures real drift; defer until needed.

### D5 — Test scope: Elixir in CI, JS sync via manual smoke matrix

In `mix test`:

- Component render test: attrs map to expected DOM (`data-session-id`, `data-offset-ms`, `data-url`, hook attribute), nil-safe rendering when audio_url is missing.
- `AudioDownloadsController` unit: valid blob → 302 with a signed URL whose TTL matches config; missing blob → 404; TTL config override is honored.
- Router macro idempotency test extended to cover the show route.

JS sync logic: a 5-row manual smoke checklist (Chrome + Safari × {scrub, pause/play, speed change, pre-offset hold, ended}) committed alongside CHANGELOG. JS test infrastructure remains an open cross-repo backlog item (ADR-0001/2/3/4 share this gap — see `phoenix_replay/docs/plans/README.md` line 19); Phase 3 logs ash_feedback as another consumer rather than absorbing the infra work.

## Component breakdown

```
┌─────── ash_feedback (lib) ──────────────────────────────┐
│ • lib/ash_feedback_web/components/audio_playback.ex     │
│ • priv/static/assets/audio_playback.js (phx-hook)       │
│ • lib/ash_feedback/controller/audio_downloads_controller│
│ • AshFeedback.Router.audio_routes/1 (mount show route)  │
│ • Application config: audio_download_url_ttl_seconds    │
└─────────────────────────────────────────────────────────┘
                         consumes ▼
┌─────── phoenix_replay (lib, no changes) ────────────────┐
│ • PhoenixReplayAdmin.subscribeTimeline (ADR-0005)       │
│ • emits play | pause | seek | ended | tick              │
│ • each event detail carries .speed                      │
└─────────────────────────────────────────────────────────┘
```

Note the new `lib/ash_feedback_web/` namespace. Phase 2 deliberately kept everything under `lib/ash_feedback/controller/` to mirror phoenix_replay; for HEEx components, `lib/ash_feedback_web/components/` is the conventional Phoenix shape and the marginal extra namespace is worth it for the ergonomic `<.audio_playback>` import path. Existing controller layout stays as-is.

## Data flow on playback

1. Host admin LV's `:show` mounts → `Ash.load!(feedback, :audio_clip)` → reads `feedback.audio_clip.blob.metadata["audio_start_offset_ms"]` (default 0).
2. Template renders `<Components.replay_player>` and, when audio is attached, `<.audio_playback audio_url={~p"/api/audio/audio_downloads/#{blob_id}"} audio_start_offset_ms={offset} session_id={feedback.session_id} />`.
3. Component renders a `<div phx-hook="AudioPlayback" id="audio-playback-…" data-session-id=… data-offset-ms=… data-url=…><audio preload="metadata"></audio></div>`.
4. Hook `mounted()`: sets `<audio src>`, calls `PhoenixReplayAdmin.subscribeTimeline(sessionId, this.handleEvent, { tick_hz: 10, deliver_initial: true })`. Stores the unsubscribe fn.
5. Hook `destroyed()`: invokes the unsubscribe fn.
6. Browser GET `/api/audio/audio_downloads/:blob_id` → controller mints signed URL → 302 → `<audio>` follows redirect → byte streaming via Range requests against the signed URL.

## Phasing

Single phase; tasks are sequential within it.

1. **3.1** — `AudioDownloadsController` + router macro extension + idempotency test + config key.
2. **3.2** — `<.audio_playback>` function component + render test.
3. **3.3** — `audio_playback.js` hook + sync rules per D3 + register in widget assets bundle (or equivalent — verify Phase 2's asset wiring).
4. **3.4** — Demo wiring: load `:audio_clip` in `Admin.FeedbackLive` `:show`, render component next to `<Components.replay_player>`, smoke matrix executed in browser.
5. **3.5** — Plan + ADR updates: Phase 3 marked shipped, ADR-0001 Question D revised to reflect the actual JS contract, CHANGELOG entry, finishing-a-development-branch.

## Test plan

**Unit (`mix test`):**
- `AudioPlaybackTest` — attr → DOM mapping, nil-safe.
- `AudioDownloadsControllerTest` — 302 with signed URL, 404 on missing blob, TTL config respected.
- `RouterTest` — `audio_routes/1` mounts both prepare + show idempotently.

**Manual smoke (browser):**
| # | Browser | Scenario | Pass condition |
|---|---|---|---|
| 1 | Chrome | Scrub player to mid-audio | Audio jumps to matching timecode within 200ms |
| 2 | Chrome | Pause / resume | Audio mirrors within one frame |
| 3 | Chrome | Speed change (1× → 2× → 0.5×) | `playbackRate` matches; no clicks/glitches |
| 4 | Chrome | Scrub back below offset | Audio pauses at t=0 |
| 5 | Chrome | Player reaches end | Audio pauses at end |
| 6 | Safari | Repeat 1–5 | Same outcomes; codec round-trips between webm/opus and mp4a.40.2 |

## Risks

- **TTL overrun on long-idle pages**: 30+ min idle → first scrub after wakeup may 401. Mitigation: LV disconnect/reconnect re-mounts and delivers a fresh URL; the 30-min default covers the realistic admin attention window. If this proves painful, follow-up is mount-time URL refresh on `:play` push_event.
- **Autoplay policy rejecting `audio.play()`**: chain length from initial click can vary. Mitigation: silent catch on rejected promise; player keeps progressing; user can manually start via `<audio controls>` (we render it for that reason).
- **Codec round-trip mismatch**: Opus in WebM (Chrome's primary recording format) is not universally supported for playback across older browsers; the Safari fallback path uses `audio/mp4`. Manual smoke is the only check; a follow-up may add server-side transcoding to AAC for broader compatibility.
- **Range-request churn against signed URL**: every seek triggers a fresh Range. Disk service handles this fine; S3 presigned GET also Range-aware. No expected issue, but worth verifying in smoke once an S3 backend exists.

## Out of scope

- 5g admin LV (gated; this Phase ships only the primitive consumed by the host's own admin UI).
- JS sync logic test infrastructure (cross-repo backlog item).
- Server-side audio transcoding for cross-browser codec coverage.
- Multiple audio clips per feedback (current design is `has_one_attached`).
- Annotations / waveform visualization synced to the timeline.

## Decisions log (carry-forward)

| From | Decision | Status in Phase 3 |
|---|---|---|
| ADR-0001 Q-A | AshStorage as the file store | unchanged |
| ADR-0001 Q-B | Optional dep, opt-in compile flag | unchanged |
| ADR-0001 Q-C | Inline pill recorder UX | shipped Phase 2 |
| **ADR-0001 Q-D** | **Sync rules — revised by D3 above:** `:speed_changed` removed (read `speed` from any event), `:ended` added (pause audio), `tick_hz` lowered to 10 |
| ADR-0001 Q-E | Cascade retention via AshStorage | unchanged |
| Phase 2 D2 (revised) | offset on Blob metadata | consumed by D1 (host extracts before passing in) |

## Addendum trigger

If implementation surfaces facts that contradict the above (e.g. the `subscribeTimeline` shape changes upstream, or autoplay handling needs concrete UX), append an addendum here rather than silently revising — same convention Phase 2 used for the D2 revision.

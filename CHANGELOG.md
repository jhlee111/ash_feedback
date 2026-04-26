# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Audio addon migrated to Phase 3 pill + review slots (2026-04-25)

Migrated from the legacy single-mount on `slot: "form-top"` to a
three-mount architecture aligned with phoenix_replay ADR-0006 Phase 3:

- `pill-action` mount (`id: "ash-feedback-audio-mic"`) — renders the
  🎙 mic toggle inside the recording pill while a Path B `:active`
  session is running. Click toggles MediaRecorder; blob lands in a
  module-scope state singleton on Stop. Each fresh pill-action mount
  (= each fresh `:active` session) clears the singleton, so Re-record
  naturally resets the recording slot. Returns the new canonical
  cleanup-function shape from `mount(ctx)`; the cleanup releases
  recorder/stream/timer on pill-hide but PRESERVES the blob for
  downstream consumers.
- `review-media` mount (`id: "ash-feedback-audio-preview"`) — renders
  an `<audio controls>` preview inside the REVIEW screen so the user
  can hear their narration before Send. Empty when no recording was
  captured. Cleanup revokes the blob URL on screen leave but
  preserves the singleton's blob for upload-on-Continue.
- `form-top` mount (`id: "ash-feedback-audio-submit"`) — invisible;
  registers a `beforeSubmit` hook that uploads the singleton's blob
  via the existing `prepare → PUT/POST → blob_id` flow. Returns `{}`
  (zero extras, zero network) when the singleton is empty (Path A
  submit, Path B without mic toggle). Uses the legacy
  `{beforeSubmit}` return shape — form-top is panel-scoped and
  registers a submit hook rather than a slot-DOM-cleanup function.

The filter shifts from legacy `modes: ["on_demand"]` to the canonical
`paths: ["record_and_report"]` per phoenix_replay ADR-0006 Q-F. The
wire format is unchanged: prepare POST carries
`metadata: {audio_start_offset_ms}`; submit's extras carry
`audio_clip_blob_id`. The Feedback resource and `:submit` action are
untouched.

Lifecycle invariants:
- Pill-action mount clears `audioState` on entry → Re-record resets.
- Pill-action cleanup runs on Stop / panel close / Re-record → releases
  recorder + stream + timer + DOM, but preserves the blob.
- Review-media cleanup runs on Continue / Re-record / Cancel → revokes
  blob URL, preserves the blob.
- Form-top beforeSubmit clears `audioState` on successful upload.
- Re-record's blob discard happens via the next pill-action mount's
  `clearAudioState()`, not in the review-media cleanup.

Timeline-bus sync between the audio preview and phoenix_replay's
mini rrweb-player is **not yet implemented** — the user-side timeline
bus surface isn't exposed (admin-side `PhoenixReplayAdmin.subscribeTimeline`
is admin-LV-scoped). The companion spec D2 mentions sync as a future
enhancement; this phase ships unsynced preview.

Smoke verified on `localhost:4006` continuous demo page:
- audio_recorder.js loads with no console errors;
- pill-action mount renders the 🎙 mic toggle in the pill on Path B
  start;
- Path B without mic submits cleanly — no `/audio_uploads/prepare`
  call, no `audio_clip_blob_id` in extras;
- Phase 3 slot lifecycle holds — a probe addon on `pill-action`
  mounts on pill-show and unmounts on Stop, with no premature
  unmount on `panel.close` (Phase 3 fix verified).

Recording cycles (Rows 3 + 4 + 5 + 7 of the plan's smoke matrix —
mic toggle ON, REVIEW preview rendered, Re-record discards blob,
upload on Send) require manual mic permission and are deferred to
manual verification. JS test infrastructure (phoenix_replay F7) is
the long-term path to automating these.

**Out of scope, deferred**: timeline-bus sync between user-side
preview and the mini rrweb-player; this requires phoenix_replay to
expose a user-side bus surface (separate ADR territory).

### Audio addon scoped to Record-and-report mode (2026-04-25)

- The audio recorder addon now declares `modes: ["on_demand"]` and only mounts
  on widgets whose configured `recording` is `:on_demand` ("Record-and-report
  mode"). On `:continuous` widgets the addon is skipped — voice commentary on
  retrospective replays cannot be synced to the rrweb timeline.
- Filter is independent of control style: a `:headless` + `:on_demand` widget
  mounts the addon normally (the host drives start/stop, but recording lifecycle
  semantics are what gates audio meaningfulness).
- Button label changed from "🎙 Record voice note" to "🎙 Add voice commentary"
  for clearer intent.

Requires phoenix_replay ≥ 2026-04-25 (mode-aware panel-addon API). Older
phoenix_replay silently ignores the `modes` opt and mounts the addon everywhere
(graceful degradation — old behavior).

### Added

- Audio narration — Phase 3 (ADR-0001). Admin playback synced to the
  rrweb timeline.
  - `AshFeedbackWeb.Components.AudioPlayback.audio_playback/1` —
    drop-in function component that syncs an `<audio>` element to
    phoenix_replay's rrweb-player timeline via
    `PhoenixReplayAdmin.subscribeTimeline`.
  - `GET /audio_downloads/:blob_id` (mounted by `audio_routes/1`) —
    302-redirects to a signed URL minted by AshStorage. TTL via
    `:audio_download_url_ttl_seconds` (default 1800).
  - Sync contract revised vs. original ADR-0001 Question D: no
    `:speed_changed` event (read `speed` off any event), `:ended`
    pauses audio, `tick_hz` lowered to 10. See ADR-0001 addendum +
    Phase 3 spec.
  - Smoke verified in Chrome on `/demo/on-demand-float` (scrub /
    pause / speed / pre-offset / ended). Safari smoke deferred.

- Audio narration — Phase 2 (ADR-0001). Browser-side recorder, prepare
  endpoint, and submit-side wiring for capturing voice notes against
  feedback rows.
  - `priv/static/assets/audio_recorder.js` — pure ES (no build step).
    Self-registers via `window.PhoenixReplay.registerPanelAddon` and
    renders into the `form-top` panel slot. Codec probe selects
    `audio/webm; codecs=opus` (Chrome / Firefox) or
    `audio/mp4; codecs=mp4a.40.2` (Safari fallback). State machine:
    idle → recording → done → denied → unsupported. Cap enforcement
    fires `stop` at `audio_max_seconds`.
  - `priv/static/assets/audio_recorder.css` — minimal styling for the
    addon UI (mic / stop / preview / re-record).
  - `AshFeedback.Controller.AudioUploadsController.prepare/2` — POST
    `/audio_uploads/prepare` mints a presigned upload URL via
    `AshStorage.Operations.prepare_direct_upload/3`. An optional
    `metadata` field on the request body is passed through to the
    blob row's `metadata` map at prepare time.
  - `AshFeedback.Router.audio_routes/1` — router macro hosts mount in
    a browser-piped scope.
  - `AshFeedback.Config` — `feedback_resource!/0`,
    `audio_attachment_resource!/0`, `audio_max_seconds/0`.
  - `Feedback.submit` action gains `:audio_clip_blob_id` argument +
    `AshStorage.Changes.AttachBlob` change when audio is compile-time
    enabled. The narration start offset rides on the AshStorage Blob
    row's `metadata` map (D2-revised — see ADR-0001 implementation
    plan), so the submit-side wire format only carries the blob id
    under `extras`.
  - `AshFeedback.Storage.submit/3` reads `params["extras"]` (the
    `phoenix_replay` panel-addon channel) and forwards
    `audio_clip_blob_id` to the `:submit` action when the configured
    resource declares the argument. Audio-disabled hosts get the extra
    silently dropped instead of an `Ash.Error.Invalid.NoSuchInput`.
  - Round-trip test (`audio_round_trip_test.exs`) drives prepare →
    blob.metadata persisted → submit-with-extras → blob attached, end
    to end against `AshStorage.Service.Test`.

- Audio narration — Phase 1 (ADR-0001). Optional `:ash_storage`
  dependency wired into the `Feedback` resource macro behind a
  compile-time gate.
  - New optional dep: `{:ash_storage, "~> 0.1", optional: true}`.
  - Gate: `config :ash_feedback, audio_enabled: true` (default
    `false`) AND `Code.ensure_loaded?(AshStorage)` at compile time.
    Both must be true for the resource to extend with AshStorage.
  - When enabled, the macro emits `storage do has_one_attached
    :audio_clip do dependent :purge end end` on the host's concrete
    `Feedback` resource. Cascade-on-purge means the blob + S3 object
    follow the parent feedback row's lifecycle (ADR-0001 Question E).
  - Default behavior unchanged for hosts that don't enable audio —
    no extra extension surface, no FK column, no AshStorage dep
    pulled in.
  - Recorder JS, presigned-upload flow, and `audio_start_offset_ms`
    persistence land in Phase 2; admin playback synced to
    phoenix_replay's timeline event bus (ADR-0005) lands in Phase 3.
- Phase 0 scaffold: repo, Hex metadata, CI, module stubs. Depends on
  `phoenix_replay` via path dep during incubation.

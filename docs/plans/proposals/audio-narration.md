# Plan: Audio Narration via AshStorage

**Status**: Proposal — pending ADR-0001 acceptance
**Drafted**: 2026-04-24
**ADR**: [0001-audio-narration-via-ash-storage](../../decisions/0001-audio-narration-via-ash-storage.md)
**Depends on**: phoenix_replay ADR-0005 (timeline event bus) being
shipped on phoenix_replay's main.

## Why

ADR-0001 decides audio narration lives in ash_feedback, backed by
AshStorage for blobs and phoenix_replay's timeline event bus for
playback sync. This proposal turns those decisions into a phased
implementation plan.

## Phases

### Phase 1 — AshStorage wiring + Feedback resource attachment

**Goal**: ash_feedback declares an optional `:audio_clip`
attachment on its Feedback resource via AshStorage, gated by an
`audio_enabled` config flag and the `ash_storage` optional dep.

**Changes**

- `mix.exs`: add `{:ash_storage, "~> 0.1", optional: true}`.
- `lib/ash_feedback/feedback.ex` (or wherever the Feedback resource
  lives): inside an `if Code.ensure_loaded?(AshStorage) do` block,
  declare `has_one_attached :audio_clip`. Add an
  `:audio_start_offset_ms` attribute (`integer`, allow_nil?: true).
- New module `AshFeedback.Audio.Storage` (or extension on existing
  storage module) — expose helpers for hosts to install the
  AshStorage `blob` + `attachment` resources in their domain. Two
  shapes: a single bundled resource (`AshFeedback.Audio.Blob` /
  `Attachment`) the host can use directly, OR a config knob that
  lets the host point at their own AshStorage resources.
- Config:
  - `config :ash_feedback, audio_enabled: true | false` (default
    `false`).
  - `config :ash_feedback, audio_max_seconds: 300` (default 5min,
    OQ1 from ADR-0001).
- Migration generator updates: when audio is enabled at install
  time, scaffold the AshStorage `storage_blobs` +
  `storage_attachments` tables (composes with phoenix_replay's
  base migration).

**Tests**

- Resource compile test: with `ash_storage` available + `audio_enabled:
  true`, the Feedback resource exposes `:audio_clip` relationship.
- Without `ash_storage`: resource still compiles, no `:audio_clip`,
  no errors.
- Optional dep guard test (`Code.ensure_loaded?` path).

**DoD**

- [ ] `:audio_clip` attachment + `:audio_start_offset_ms` field
      live on the Feedback resource when audio is enabled.
- [ ] Compiles cleanly without `ash_storage` in deps.
- [ ] CHANGELOG entry under "Added — Audio narration (Phase 1)".

### Phase 2 — Recorder JS + presigned upload

**Goal**: `MediaRecorder` integration in the existing widget
panel. User clicks mic → records → on submit, the audio uploads to
S3 via AshStorage's presigned URL, and the feedback row links to
the resulting attachment.

**Changes**

- `priv/static/assets/audio_recorder.js` (new) —
  `MediaRecorder`-based recorder with:
  - Codec probe (`audio/webm; codecs=opus` or `audio/mp4` per
    OQ2).
  - Length cap enforcement (`audio_max_seconds`).
  - Permission handling: graceful degradation when the user
    denies, with an inline notice in the panel.
  - Captures `recording_started_at` (wall-clock at first chunk).
- `lib/ash_feedback_web/components/audio_recorder.ex` — Phoenix
  function component for the panel mic button + state UI
  (idle / recording / done with playback preview / error). Embeds
  the `audio_recorder.js` script tag.
- Submit flow: when the user submits feedback with a captured blob:
  1. POST to a new `audio_uploads` controller endpoint to get a
     presigned PUT URL + the `blob_id` AshStorage minted.
  2. Browser PUTs the audio bytes directly to S3.
  3. The existing `POST /submit` includes `audio_clip_blob_id`
     + `audio_start_offset_ms` in the request body.
  4. Server-side change in `AshFeedback.Storage`: pass these args
     through to the Feedback create action; AshStorage's
     `AttachBlob` change wires the attachment.
- `mix ash_feedback.install` (when 5f lands): when `audio_enabled`
  is set, the installer adds the AshStorage resource files +
  configures the S3 service.

**Tests**

- LV component test for the audio_recorder UI state machine
  (idle → recording → done → error transitions).
- Mock-storage test for the submit flow — feed a fake blob_id +
  offset, assert the Feedback row gets the attachment + offset
  persisted.
- Manual smoke: actually record, submit, fetch from S3 (or MinIO
  in dev).

**DoD**

- [ ] User can record audio in the widget panel and the file
      lands in S3 (real bucket or MinIO).
- [ ] Feedback row references the audio attachment with
      `audio_start_offset_ms` set correctly.
- [ ] Length cap enforced client-side AND server-side.
- [ ] Codec probe + Safari fallback (`audio/mp4`).
- [ ] Permission denial renders a clear error.
- [ ] CHANGELOG entry.

### Phase 3 — Admin playback synced to rrweb timeline

**Goal**: in the admin feedback detail view, an `<audio>` element
plays back in lock-step with rrweb-player. Subscribes to
phoenix_replay's `subscribeTimeline` (ADR-0005).

**Changes**

- `lib/ash_feedback_web/components/audio_playback.ex` — Phoenix
  function component rendered alongside `<.replay_player>` in the
  admin detail. Inputs: `audio_url`, `audio_start_offset_ms`,
  `session_id`.
- `priv/static/assets/audio_playback.js` — subscribes to
  `phoenix_replay:timeline` (or `PhoenixReplayAdmin.subscribeTimeline`)
  at `tick_hz: 60`. Sync rules per ADR-0001 Question D:
  - `:play` → `audio.play()` if past offset
  - `:pause` → `audio.pause()`
  - `:seek` / `:tick` → set `audio.currentTime` from the player
    timecode + offset
  - `:speed_changed` → mirror to `audio.playbackRate`
  - When `player_timecode_ms < offset`, audio stays paused at
    t=0; resumes when the cursor crosses the offset.
- The audio element's source is a presigned GET URL minted by an
  `audio_downloads` controller endpoint (same authorization as
  the rest of the admin surface — host's existing admin pipeline
  guards it).

**Tests**

- Manual smoke: replay a feedback with audio attached, scrub
  through the timeline, confirm audio stays in sync; pause/play
  → audio mirrors; speed change → audio rate matches.
- Cross-browser smoke (Chrome + Safari at minimum) — codec
  fallback path.

**DoD**

- [ ] Audio plays in sync with rrweb cursor in the admin replay
      view.
- [ ] Sync survives scrub, pause/play, speed change.
- [ ] No autoplay before the cursor crosses
      `audio_start_offset_ms`.
- [ ] CHANGELOG entry.

### Phase 4 — Documentation + integration guide

**Changes**

- `README.md`: short section on audio narration — config flag,
  AshStorage dep, browser support note.
- `docs/guides/audio-narration.md` (new): full reference —
  installation, recording UX, admin playback, S3 setup
  (incl. CORS for direct uploads), permission policies, retention.

**DoD**

- [ ] README + guide.
- [ ] CHANGELOG roll-up entry covering all four phases.

## Risks & rollback

| Risk | Mitigation |
|---|---|
| AshStorage v0.1.0 API churn | Thin adapter in ash_feedback that exposes only the surfaces we need; an upgrade touches one module. |
| Browser MediaRecorder codec drift | Probe `MediaRecorder.isTypeSupported` at runtime; fallback to `audio/mp4` for Safari; render disabled mic with tooltip if no codec works. |
| S3 CORS misconfiguration breaks direct upload | Document required CORS in the guide; surface a helpful error in the recorder UI when the upload PUT fails. |
| ADR-0005 timeline bus contract changes | Pin to the implemented contract; the bus is internal-stable per ADR-0005 Question E. |
| Microphone permission denial | UX path renders a "permission required" notice with browser-specific instructions; user can submit without audio. |

**Rollback per phase**:
- Phase 1: revert resource declaration + config keys; the host's
  `audio_enabled: false` (default) behaves as today.
- Phase 2: drop the recorder component + audio_uploads controller.
  No-audio submissions unaffected.
- Phase 3: drop the audio_playback component. Replay still works
  without audio.

## Decisions log (from ADR-0001)

- [ ] **OQ1** — 5-minute max length default.
- [ ] **OQ2** — `audio/webm; codecs=opus` primary,
      `audio/mp4` Safari fallback.
- [ ] **OQ3** — single bundled `AshFeedback.Audio` module (recorder
      + playback together).
- [ ] **OQ4** — per-host config flag + per-submission user
      affordance.

Promote to `active/` once ADR-0001 is Accepted.

## Follow-ups (separate plans)

- **Transcription** — Whisper / external service integration. New
  ADR if a host asks.
- **Voice-only feedback** — text field optional. Variation, not
  Phase 1.
- **System audio capture** — record what the user hears (stereo
  mix), not just the microphone. New ADR.

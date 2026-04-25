# Plan: Audio Narration via AshStorage

**Status**: Active — Phases 1 + 2 shipped (Phase 2 wraps 2026-04-25). Phase 3 (admin playback) pending.
**Drafted**: 2026-04-24
**Promoted**: 2026-04-24 (ADR-0001 Accepted)
**ADR**: [0001-audio-narration-via-ash-storage](../../decisions/0001-audio-narration-via-ash-storage.md)
**Implementation plan (bite-sized tasks)**: [`docs/superpowers/plans/2026-04-24-audio-narration-phase-2.md`](../../superpowers/plans/2026-04-24-audio-narration-phase-2.md)
**Spec (architectural decisions D1–D7 + addendum)**: [`docs/superpowers/specs/2026-04-24-audio-narration-phase-2-design.md`](../../superpowers/specs/2026-04-24-audio-narration-phase-2-design.md)
**Depends on**: phoenix_replay ADR-0005 (timeline event bus) shipped
on phoenix_replay's main as of 2026-04-24 (Phases 1 + 2).

## Phase 2 progress (as of 2026-04-25 — ✅ shipped)

**Sub-phase 2a — phoenix_replay panel-addon API: ✅ shipped (8/8)** — 8 commits on `~/Dev/phoenix_replay/` main from `ed94621` through `1268fce`. Adds `<div data-slot="form-top">` slot, `window.PhoenixReplay.registerPanelAddon` JS API, addon mount loop in `renderPanel`, `extras` field on `report()` + `/submit` body, `SubmitController` extras forwarding via `submit_params["extras"]`. Plus `a0e162f` — defer-script ordering fix so addons registered by later defer scripts mount on first panel render. 79 → 82 tests.

**Sub-phase 2b — ash_feedback audio addon: ✅ shipped (7/7).**

| | Status | Commit(s) |
|---|---|---|
| 2b.1 — Recon: AttachBlob metadata support | ✅ recon only — design pivoted to D2 revision (offset on **blob** metadata, not attachment) | (no commit; pivot captured in `9be325b`) |
| 2b.2 — `AshFeedback.Config` helpers | ✅ | `2c21ba2` |
| 2b.3 — `AudioUploadsController.prepare/2` | ✅ (initial + spec-review fix + tolerant error message) | `60f9ef0`, `e608f28`, `554a717` |
| 2b.4 — `AshFeedback.Router.audio_routes/1` | ✅ (initial + alias-accumulation fix) | `654ea52`, `28bee79` |
| 2b.5 — `:submit` action `audio_clip_blob_id` arg + `AttachBlob` change | ✅ (incl. macro storage-block bug fix from Phase 1) | `cd393d9`, `b0c3585`, `554a717` |
| 2b.6 — `AshFeedback.Storage` extras → `:submit` arg | ✅ | `40f0160` |
| 2b.7 — Audio recorder JS + CSS (MediaRecorder, codec probe, state machine, prepare→PUT flow) | ✅ | `63daa6f` |

29 → 37 tests across the wrap.

**Sub-phase 2c — Round-trip test: ✅ shipped** — `813261e`. Substituted Firkin/Req with `AshStorage.Service.Test` since the Firkin contract test exercises AshStorage internals more than ash_feedback's own surface.

**Sub-phase 2d — Demo wiring: ✅ shipped** — `32d7c0d` on `ash_feedback_demo`. Hosted Blob + Attachment resources, Disk-backed `AshStorage.Service`, endpoint plug for PUT/GET, recorder script tag in root layout. End-to-end smoke verified in-browser: prepare → PUT bytes → GET back → blob row carries `metadata["audio_start_offset_ms"]`. Mic-recording itself requires a human in front of a microphone; the surface around it is proven.

**Sub-phase 2e — Docs: ✅ shipped** — phoenix_replay README has the panel-addon API section, ash_feedback README has the audio narration enable / wire / browser-support section, this plan marks Phase 2 shipped. Library SHA bump in the demo (`mix.lock`) gated on the user's push approval.



## Why

ADR-0001 decides audio narration lives in ash_feedback, backed by
AshStorage for blobs and phoenix_replay's timeline event bus for
playback sync. This proposal turns those decisions into a phased
implementation plan.

## Phases

### Phase 1 — AshStorage wiring + Feedback resource hook ✅ shipped 2026-04-24 (`67fd09a`)

**Goal**: ash_feedback declares an optional `:audio_clip`
attachment on its Feedback resource via AshStorage, gated by a
**compile-time** flag plus the `ash_storage` optional dep. Default
behavior is unchanged for hosts who don't enable it.

**Refined scope (vs. original draft)**

The original draft conflated three concerns into Phase 1; the
recon against `~/Dev/ash_storage` (2026-04-24) and ash_feedback's
existing `use`-macro pattern showed the scope is naturally tighter:

- **Resource shapes**: not bundled. AshStorage's `BlobResource` /
  `AttachmentResource` are themselves `use`-style extensions, so
  the host concretizes — same pattern ash_feedback already uses
  for `Feedback`. ADR-0001 OQ3 ("single bundled module") is
  effectively reframed: ash_feedback ships the DSL hook, the host
  defines its own concrete blob/attachment resources (5f's
  installer will scaffold those).
- **`audio_start_offset_ms` attribute** moves to **Phase 2**: it's
  written when audio is recorded, so the column / metadata-key
  decision belongs with the recorder code, not the resource shape.
- **Migration scaffolding** moves to **5f** (Igniter installer) —
  no point landing migration generator hooks before the installer
  itself exists.

**Changes (Phase 1)**

- `mix.exs`: add `{:ash_storage, "~> 0.1", optional: true}`.
- `lib/ash_feedback/resources/feedback.ex` macro:
  - Read `Application.compile_env(:ash_feedback, :audio_enabled,
    false)` AND `Code.ensure_loaded?(AshStorage)` at module-eval
    time.
  - When both true: append `AshStorage` to the `extensions:` list
    on the resource AND inject a `storage do has_one_attached
    :audio_clip do dependent :purge end end` block.
  - Otherwise: zero change to the emitted resource (default-off,
    no FK column, no extension surface).
- Config: document `config :ash_feedback, audio_enabled: true`
  (default `false`) in README. `audio_max_seconds` lives with the
  recorder (Phase 2).
- README: short "Audio narration (optional)" section + pointer at
  `~/Dev/ash_storage/dev/resources/post.ex` for the host's
  blob/attachment setup until 5f scaffolds it.

**Tests**

- Existing test suite must pass with audio disabled (default).
- Compile-enabled test fixture deferred to Phase 2 — adding
  `ash_storage` to dev/test deps isn't worth the noise just to
  test "the macro injects an extension". Phase 2 brings in the
  dep for the recorder + we cover both paths there.

**DoD**

- [ ] `mix.exs` carries the optional dep.
- [ ] Resource macro injects AshStorage + `has_one_attached
      :audio_clip` when both flags are on; default behavior
      unchanged.
- [ ] `mix test` green (audio disabled).
- [ ] README + CHANGELOG entries.

### Phase 2 — Recorder JS + presigned upload ✅ shipped 2026-04-25

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

- [x] User can record audio in the widget panel and the file
      lands in S3 (real bucket or MinIO). _Disk-backed dev round-trip
      verified in the demo (sub-phase 2d). MinIO/S3 smoke deferred to
      consumers per their backend choice._
- [x] Feedback row references the audio attachment; the narration
      start offset persists on the AshStorage Blob row's metadata
      map (D2-revised — offset on blob, not attachment).
- [x] Length cap enforced client-side. _Server-side cap is the
      AshStorage `byte_size` constraint plus the host's HTTP body
      limit; not a separate library check._
- [x] Codec probe + Safari fallback (`audio/mp4`).
- [x] Permission denial renders a clear inline notice; the rest of
      the form remains usable.
- [x] CHANGELOG entry.

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

Promoted to `active/` 2026-04-24 (ADR-0001 Accepted).

## Follow-ups (separate plans)

- **Transcription** — Whisper / external service integration. New
  ADR if a host asks.
- **Voice-only feedback** — text field optional. Variation, not
  Phase 1.
- **System audio capture** — record what the user hears (stereo
  mix), not just the microphone. New ADR.

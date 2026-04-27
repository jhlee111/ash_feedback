# ADR-0001: Audio Narration via AshStorage

**Status**: Accepted — Question D **superseded** 2026-04-26 by the
audio pre-flight toggle redesign
([spec](../superpowers/specs/2026-04-26-audio-pre-flight-toggle-design.md));
Question B **superseded** 2026-04-26 by the audio core promotion
(see [Addendum 2026-04-26 — Question B revised](#addendum-2026-04-26--question-b-revised-ashstorage-promoted-to-core-dep)
below; execution tracked in [`../plans/audio-core-promotion.md`](../plans/audio-core-promotion.md)).
Audio is now session-equivalent (recording starts at the rrweb
session boundary), so offset is always 0. The
`audio_start_offset_ms` metadata key has been dropped end-to-end:
JS prepare body, `AudioUploadsController`, `AshFeedback.Storage`,
and admin playback no longer reference it; AshStorage Blob
`metadata` JSON no longer carries it for new uploads. Questions A,
C, E remain in force.
**Date**: 2026-04-24
**Depends on**: phoenix_replay ADR-0005 (Replay Player Timeline
Event Bus)

## Context

QA reproductions are stronger when the reporter can talk over them.
"Click here, then notice the count is wrong" lands harder when the
admin reviewing the recording can hear that sentence in the
reporter's voice instead of guessing intent from a 40-character
description field.

Microphone narration was originally sketched as a phoenix_replay
follow-up ADR but re-scoped on 2026-04-23: audio is a feature of
the **feedback artifact**, not of session capture. Storage,
PaperTrail, policy, retention — all of those concerns live in
ash_feedback's domain (Ash resources + Ash extensions), not in
phoenix_replay (rrweb + ingest behaviour).

Phoenix_replay just shipped two pieces that make this nearly free
for ash_feedback to ride on:

- **ADR-0001 headless API** — `window.PhoenixReplay.open()` lets
  any feedback panel orchestrate its own pre-flight (start a
  MediaRecorder, then open the panel).
- **ADR-0005 timeline event bus** — replay player broadcasts
  `phoenix_replay:timeline` events. ash_feedback's playback
  surface subscribes and syncs an `<audio>` element to the rrweb
  cursor. Phoenix_replay never imports audio semantics.

Five decisions are load-bearing.

## Question A — file storage

Three options.

1. **AshStorage** ([ash-project/ash_storage](https://github.com/ash-project/ash_storage))
   — an Ash extension for blobs + attachments. Provides an S3
   service adapter with presigned-URL direct uploads, a `blob`
   resource shape, an `attachment` resource shape, and a
   `has_one_attached` macro on host resources. Currently v0.1.0,
   actively developed by the Ash team, slated to land closer to
   ash core.
2. **Bespoke S3 plumbing** in ash_feedback — a new column on the
   feedback resource (`audio_s3_key :: String.t()`), an `ExAws`
   dependency, hand-rolled presigned URL helpers, an
   `audio_uploads` controller for the prepare step.
3. **DB-resident blob** — store the audio bytes as `bytea` /
   `large object`. Avoids S3 entirely; bloats the DB; impractical
   at any real volume.

**Decision (proposed)**: option 1 — depend on AshStorage. Three
load-bearing reasons:

- AshStorage already implements presigned-URL direct uploads
  (`AshStorage.Service.S3, presigned: true`) — the standard S3
  pattern, so the Phoenix endpoint stays out of the data path.
- Blob lifecycle (creation, attachment, deletion-on-orphan) is
  AshStorage's job, not ash_feedback's. Audio retention being
  "row-following" (Question E) maps directly to AshStorage's
  attachment cascade.
- Permissions are normal Ash policies on the blob/attachment
  resources. AshGrant integrates if the host installs it; without
  AshGrant the policies still work.

**Why not** option 2: ash_feedback would carry SDK plumbing for a
storage problem that an upstream extension solves cleanly. Same
reasoning as `ash_oban` over rolling our own Oban wrappers — a
companion extension model.

**Why not** option 3: hosts running multi-minute reproductions
would balloon their primary database with binary blobs. S3 (or
S3-compatible: MinIO, R2, B2) is the right tier.

## Question B — optional or required dependency

ash_feedback today has no audio dependency. Adding AshStorage as a
hard requirement penalizes hosts that don't want audio narration —
they pay the cost (extra resources to install, S3 credentials to
provision) for a feature they won't use.

**Decision (proposed)**: AshStorage is **optional** —
`{:ash_storage, "~> 0.1", optional: true}`. Audio narration is
gated behind `Code.ensure_loaded?(AshStorage)` at compile time and
behind a config flag (`config :ash_feedback, audio_enabled: true`)
at runtime. Hosts who don't install it get the existing
description-only feedback flow with zero impact.

**Why** the runtime flag in addition to compile-time gate: a host
might depend on AshStorage transitively for some other feature but
not want feedback narration enabled — a clean opt-in keeps the
feature off until the host explicitly turns it on.

## Question C — recording UX

Three options.

1. **Inline in the existing feedback panel** — when audio is
   enabled, the panel renders a microphone button. Click → starts
   `MediaRecorder` + opens the existing description field. User
   talks while typing (or just talks). Submit ends the recording
   and uploads in the background.
2. **Separate floating mic button** — a second toggle (alongside
   the existing widget button) that arms recording without opening
   the panel; clicking again opens the panel with audio already
   captured.
3. **Voice-only mode** — no description field; audio replaces text
   entirely.

**Decision (proposed)**: option 1. The feedback panel is already
the place users reach when they have something to say; bolting
narration inside it keeps the mental model coherent ("I'm
reporting a bug; one of the things I can do is record my voice").
Options 2 and 3 fragment the flow.

**Why not** option 2: doubling the chrome on every page is too
much for a niche feature; users who want voice-only can just leave
the description blank.

**Why not** option 3: text remains the lowest-friction submission
mode. Audio is augmentation, not replacement.

## Question D — playback alignment with the rrweb timeline

Audio narration starts at some wall-clock moment **after** the
rrweb session began (continuous mode) or roughly together with it
(on-demand mode). To play it back synchronized, the admin's player
needs to know how many milliseconds into the rrweb timeline the
audio's t=0 sits.

**Decision (proposed)**: capture
`audio_start_offset_ms = audio_recording_started_at -
first_rrweb_event_at` at recording time and store it on the
attachment. On admin playback, ash_feedback's component:

1. Subscribes to phoenix_replay's timeline bus
   (`subscribeTimeline`) at `tick_hz: 60` (smooth sync).
2. On `:play` / `:pause` / `:speed_changed` / `:seek` /
   `:tick` events, derives the corresponding audio position
   as `audio.currentTime = max(0, (player_timecode_ms -
   audio_start_offset_ms) / 1000)` and matches `audio.playbackRate`
   to the player's speed.
3. If `player_timecode_ms < audio_start_offset_ms`,
   pauses the audio; resumes when the cursor crosses the offset.

This keeps the sync logic entirely in ash_feedback — phoenix_replay
emits events, ash_feedback applies them to `<audio>`. Same pattern
generalizes to any future media (video, etc.) that ash_feedback
might attach.

## Question E — retention policy

**Decision (proposed)**: audio attachment retention follows the
parent feedback row 1:1. Deleting feedback deletes the attachment
deletes the blob. AshStorage's cascade handles this naturally when
the attachment's owning record is destroyed.

**No separate audio TTL** — if a host wants shorter retention for
audio than for the rest of the feedback row (compliance,
disk-cost), they manage that with periodic Ash policy filters.
Out of scope for this ADR.

## Out of scope

- **Transcription** — Whisper / external service integration.
  Adds a new dependency surface (provider auth, cost, async job
  pipeline) that doesn't fit in the same ADR. Possible follow-up
  ADR if a host asks.
- **Voice-only feedback** (no description). Question C decided
  inline UX; "no text" is a host-side variation that this ADR
  doesn't bake in.
- **Self-hosted S3-compatible storage** specifics (MinIO, R2, etc).
  AshStorage handles these via service config; ash_feedback
  passes through.
- **Audio editing UI** — trim, skip-silence, normalize.
  Out of band. Reporter records, submits.
- **Multi-track audio** (e.g. system audio capture alongside
  microphone). Phase 1 is microphone only.

## Consequences

### Positive

- ash_feedback gains a meaningful artifact-quality boost (voice
  context) without rolling S3 plumbing.
- Phoenix_replay stays untouched — confirms the boundary already
  drawn on 2026-04-23. Audio is purely a wrapper-layer feature.
- AshGrant-using hosts get policy-driven access control for
  free. Non-AshGrant hosts still get plain Ash policies.
- Pattern generalizes: any other time-aligned artifact (video
  clip, screenshot timeline) lands the same way — AshStorage
  attachment + ADR-0005 timeline subscription.

### Negative / risks

- **AshStorage v0.1.0** is alpha; API may shift before a stable
  release. Mitigation: thin adapter in ash_feedback that exposes
  the audio recording / playback surface; an AshStorage upgrade
  touches one module.
- **Dependency footprint**. AshStorage pulls in its own deps
  (likely `ex_aws` family for S3). Mitigation: optional dep —
  hosts who don't enable audio don't pay for the chain.
- **Browser support for MediaRecorder** — all modern browsers
  support `audio/webm; codecs=opus` (Chrome / Edge / Firefox);
  Safari prefers `audio/mp4`. Mitigation: probe
  `MediaRecorder.isTypeSupported` and pick the best codec; fall
  back to disabled mic with a tooltip if no supported codec.
- **Microphone permission UX** — a "page wants to use your
  microphone" prompt fires on the first record click. Acceptable
  — same UX as Loom / Slack / any browser app.

## Open items

- **OQ1**: max recording length cap. Lean: 5 minutes. Captures
  expected reproductions (most are under 1 min) without bloating
  worst-case blob size (~5MB at opus 24kbps mono).
- **OQ2**: blob format default. Lean: `audio/webm; codecs=opus`
  for Chrome / Edge / Firefox; `audio/mp4` for Safari fallback.
  Both play back via HTMLAudioElement on the same browsers.
- **OQ3**: should ash_feedback ship the audio recorder + admin
  playback as one extension or split? Lean: single module
  (`AshFeedback.Audio`) with the recorder JS in
  `priv/static/assets` and the admin playback component in
  `lib/`.
- **OQ4**: should audio be enable-able per-feedback (user opts in
  per submission) or per-host (admin enables it once)? Lean:
  per-host (config flag) + per-submission UI affordance — user
  sees the mic button only when host enabled the feature, and
  only records when they click it. No silent recording.

## References

- phoenix_replay ADR-0001 — headless API (`window.PhoenixReplay.open()`)
  used to orchestrate panel + MediaRecorder.
- phoenix_replay ADR-0005 — timeline event bus that admin
  playback subscribes to.
- AshStorage — [ash-project/ash_storage](https://github.com/ash-project/ash_storage),
  v0.1.0 with direct uploads.
- 2026-04-23 re-scoping note in
  phoenix_replay's `docs/plans/completed/2026-04-23-widget-trigger-ux.md`
  follow-ups list — original "audio belongs in ash_feedback"
  decision.

## Addendum 2026-04-26 — Question B revised: AshStorage promoted to core dep

Original Question B decision: AshStorage as **optional** dep, audio
gated behind compile-time + runtime flags. Reasoning at the time:
hosts that don't want audio shouldn't pay the dep cost or feature
surface.

Revised decision (2026-04-26): **AshStorage is a core dependency.**
Audio narration is treated as a defining feature of ash_feedback,
not an opt-in add-on.

Two reasons.

1. **Audio is the load-bearing differentiator** of ash_feedback over
   "a thin Ash wrapper around phoenix_replay." Voice context on QA
   reproductions is what makes the artifact qualitatively better
   than any text-only feedback flow. Burying it behind a feature
   flag understates what the library is for.

2. **Adopting AshStorage as a hard dep also signals reference
   adoption** of a new Ash core extension. ash_feedback is positioned
   as a showcase for Ash community patterns — a thin "if you
   happen to want this, opt in" relationship works against that.

What changes:

- `mix.exs`: `{:ash_storage, github: ..., branch: "main"}` (drop
  `optional: true`).
- `Setup.audio_enabled?/0` removed. The compile-time gate goes away.
- `Resources.Feedback.__using__/1` always declares
  `has_one_attached :audio_clip`; `:audio_blob_resource` and
  `:audio_attachment_resource` opts become **required**.
- `AshFeedback.Storage.submit/3` no longer needs the silent-drop
  branch for `audio_clip_blob_id`.
- `config :ash_feedback, audio_enabled: ...` retired.

What stays in force:

- Hosts still own their `Blob` + `Attachment` resources because the
  storage backend (S3 / Disk / MinIO) and bucket are host-specific
  decisions.
- Audio routes are still mounted via
  `AshFeedback.Router.audio_routes/1` — routing is host's concern.
- Question B's original load-bearing reasons (AshStorage's cascade
  semantics, Ash policies on blobs/attachments) remain unchanged.

Question A's "Why not bespoke S3 plumbing" reasoning carries over
unchanged — promotion to core only flips the dep contract, not the
storage choice.

Execution tracked in
[`../plans/audio-core-promotion.md`](../plans/audio-core-promotion.md).

## Addendum 2026-04-25 — Question D revised post-implementation

The original Question D rules pre-dated the ADR-0005 timeline-bus
implementation. Phase 3 implementation surfaced two corrections, now
the binding contract:

- The `subscribeTimeline` callback receives `play | pause | seek | ended | tick`.
  There is **no `:speed_changed` event** — `speed` is a field on every
  event detail. Consumers reconcile `playbackRate` whenever `speed` changes,
  not on a dedicated kind.
- The original rules omitted `:ended`. On `:ended`, audio pauses.
- `tick_hz` is `10` (ADR-0005 default), not 60 — the higher rate was
  unjustified for an audio sync workload where `playbackRate` matching
  keeps natural drift below the perceptual threshold.

The revised rule table lives in
[`docs/superpowers/specs/2026-04-25-audio-narration-phase-3-design.md`](../superpowers/specs/2026-04-25-audio-narration-phase-3-design.md) §D3.

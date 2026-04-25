# Design: Audio Addon — Pill + Review Slot Relocation

**Date**: 2026-04-25
**Status**: Draft — depends on phoenix_replay ADR-0006 acceptance and the
companion phoenix_replay UX spec.
**Owners**: ash_feedback (this spec), phoenix_replay (provides slots —
see companion spec).
**Upstream**:
[`~/Dev/phoenix_replay/docs/decisions/0006-unified-feedback-entry.md`](../../../../phoenix_replay/docs/decisions/0006-unified-feedback-entry.md)
+ [`~/Dev/phoenix_replay/docs/superpowers/specs/2026-04-25-unified-feedback-entry-design.md`](../../../../phoenix_replay/docs/superpowers/specs/2026-04-25-unified-feedback-entry-design.md)

## Context

ADR-0001 Phase 2 placed the audio mic UI in the panel's `form-top`
slot — the user clicked "Start reproduction", recorded their reproduction,
came back to the submit form, and toggled the mic alongside the
description textarea. The mic recorded **after** the rrweb capture
window, with `audio_start_offset_ms` capturing the gap.

phoenix_replay ADR-0006 changes the panel UX:

- The form-top slot still exists, but the submit form is now reached
  **after** the user finishes recording (Path B) or **without any
  recording context** (Path A). Path A doesn't permit audio (no
  rrweb timeline to sync with). Path B's mic must record **during**
  the rrweb session, not after — so the toggle has to live on the
  recording pill, not in the post-recording form.

- The pill gains a `pill-action` slot for in-flight controls, and the
  review step gains a `review-media` slot for media playback components.

This spec describes the audio addon's migration to the new slots and
the small recorder-side adjustments that follow.

## Architectural decisions

### D1 — Mic toggle migrates form-top → pill-action

Today's `audio_recorder.js` `register` call uses `slot: "form-top"`. New
target:

```js
window.PhoenixReplay.registerPanelAddon({
  id: "ash-feedback-audio-mic",
  slot: "pill-action",
  modes: ["on_demand"],
  mount: (ctx) => mountMicToggle(ctx),
});
```

`mountMicToggle(ctx)` renders the existing `🎙 Add voice commentary`
button (label preserved per Mode-aware spec D4). On first click, the
recorder requests mic permission and starts MediaRecorder. The button
becomes a recording-state pill (active dot + elapsed seconds) with a
second click stopping the audio (mic stays available for re-toggle
within the same Path B session).

`audio_start_offset_ms` capture is preserved: recorded as the delta
between the rrweb session's `started_at` (provided by `ctx.session`)
and the MediaRecorder's first chunk timestamp. Existing blob-metadata
write path is unchanged.

### D2 — Audio playback registers at review-media

The Phase 3 `AshFeedbackWeb.Components.AudioPlayback.audio_playback/1`
component renders the admin-side player. For the user-facing review
step (where the user previews their just-recorded audio before
sending), we ship a sibling JS-only component that:

- Subscribes to `phoenix_replay:timeline` (existing bus, ADR-0005).
- Plays back the in-memory audio blob the user just recorded (no
  upload yet — the upload happens at Send).
- Exposes the same play/pause/scrub UX as the admin player, so the
  user sees what the admin will see.

This is registered as a panel addon:

```js
window.PhoenixReplay.registerPanelAddon({
  id: "ash-feedback-audio-preview",
  slot: "review-media",
  modes: ["on_demand"],
  mount: (ctx) => mountAudioPreview(ctx),
});
```

`mountAudioPreview(ctx)` renders nothing if no audio was recorded in
this session (graceful degrade — Path B without mic is fully
supported). When audio exists, it renders the in-memory `<audio>`
element bound via `URL.createObjectURL(blob)`, with a play/pause
button and time display, subscribing to the timeline bus to follow
rrweb-player position.

### D3 — Re-record discards the audio blob

When the user clicks Re-record on the review step, phoenix_replay
unmounts the `review-media` slot. Per the upstream spec D6
mount/unmount contract, the audio addon's `mount` function returns a
cleanup function; phoenix_replay invokes it on slot disappearance.
The cleanup releases `URL.revokeObjectURL`, drops the blob
reference, and resets internal state so the next recording starts
fresh.

### D4 — Send finalizes blob upload (existing flow)

The describe step Send button triggers the existing audio upload
flow:

1. ash_feedback addon hooks `ctx.beforeSubmit` (existing hook).
2. Audio addon does its `prepare` → `PUT` flow to AshStorage (Phase 2
   2b.3 + 2b.7).
3. Audio addon adds `audio_clip_blob_id` and `audio_start_offset_ms`
   to `ctx.extras` (existing pattern, Phase 2 2b.5/2b.6).
4. phoenix_replay's submit POST carries the extras through.
5. ash_feedback's `:submit` action attaches the blob.

The only change here vs. Phase 2 is **when** the upload runs — today
it runs from the `form-top` mount; the new code runs from the
`pill-action` lifecycle but the same upload flow is invoked at the
same Send moment.

### D5 — Path A receives no audio surface

ash_feedback's audio addon is `modes: ["on_demand"]` (Path B). On a
Path A submit (Report now), the addon is never mounted on any slot,
so no mic UI appears, no audio blob is created, and no audio extras
are POSTed. This is the desired behavior (Path A's text-only
constraint per ADR-0006 Q-B).

The `form-top` slot may still be used by **other** ash_feedback
addons that have something to show in either path's submit form
(e.g., a tag picker — out of scope here). The audio addon is the
only Phase 2 consumer of `form-top` and it migrates out.

### D6 — README + guide updates

- `README.md` audio narration section: update the snippet showing the
  addon mount slot from `form-top` to `pill-action` + `review-media`.
- `docs/guides/audio-narration.md` (Phase 4 doc): update the recorder
  side section to describe the in-flight toggle UX. Path A/B
  framework prose still applies — Path B remains the only path with
  audio.

## Component breakdown

```
┌──────── ash_feedback (this spec) ──────────────────────────────┐
│ JS / addon                                                       │
│ • audio_recorder.js: register slot pill-action (mic toggle)      │
│ • audio_recorder.js: register slot review-media (preview player)  │
│ • audio_recorder.js: cleanup on unmount (Re-record path)          │
│                                                                  │
│ Submit flow                                                       │
│ • beforeSubmit hook unchanged — audio upload + extras forwarding  │
│                                                                  │
│ Resource                                                          │
│ • Feedback resource: severity field allow_nil? remains true       │
│   (phoenix_replay's show_severity controls the form, not the      │
│   resource — no resource change needed)                           │
│                                                                  │
│ Docs                                                              │
│ • README audio section: update slot strings                       │
│ • docs/guides/audio-narration.md: update recorder-side prose      │
└────────────────────────────────────────────────────────────────┘
                                hosted by ▼
┌──────── ash_feedback_demo ─────────────────────────────────────┐
│ • End-to-end smoke: Path B with audio + Re-record discards blob  │
│ • End-to-end smoke: Path B without audio (mic never toggled) →    │
│   submit succeeds with no audio_clip_blob_id                      │
└────────────────────────────────────────────────────────────────┘
```

## Phasing

Single phase, gated on phoenix_replay companion spec Phase 3 landing
(when the new slots become available).

- 1.1 — Recon: read current `audio_recorder.js` register flow + map
  Phase 2 hooks (form-top mount, beforeSubmit, prepare/PUT).
- 1.2 — Update `register` calls: `pill-action` for mic toggle,
  `review-media` for preview.
- 1.3 — Implement `mountMicToggle(ctx)` — extract from current
  `mountFormTop` and adjust to pill UI conventions (smaller, label
  changes on state).
- 1.4 — Implement `mountAudioPreview(ctx)` — wraps existing
  audio playback hook (already shipped Phase 3) but binds to in-memory
  blob instead of HTTP URL; subscribes to timeline bus identically.
- 1.5 — Cleanup contract: addon `unmount` releases blob URL + resets
  state; verified by Re-record smoke (recording 1 → review → Re-record
  → recording 2 → review shows recording 2's audio, not recording 1's).
- 1.6 — Tests: unit for the new mount functions (smoke against a
  fixture session ctx); integration test that a Path A submit never
  POSTs audio extras.
- 1.7 — Docs: README + guide updates per D6.
- 1.8 — Demo wiring (companion task in `ash_feedback_demo`).

## Test plan

**ash_feedback (`mix test`):**

- Existing audio integration tests still pass (they exercise the
  end-to-end `:submit` action with audio extras — the flow is
  unchanged at the resource/controller layer).
- New: integration test confirming a Path A `/report` submit never
  carries `audio_clip_blob_id` (the addon never mounts, so extras
  never set).
- New: integration test confirming a Path B `/submit` with audio
  carries the blob id and offset, identical to today's coverage.

**JS unit (existing harness):**

- `mountMicToggle` lifecycle: mount → click → recording → click →
  stopped (state reflected in DOM).
- `mountAudioPreview` lifecycle: blob present → render player; blob
  absent → render nothing; unmount releases `URL.revokeObjectURL`.

**Manual smoke (browser, demo host):**

- Path B without mic: record → Stop → review (no audio player) →
  Continue → Send → admin replay shows rrweb only.
- Path B with mic: record → toggle mic → speak → Stop → review shows
  audio player synced to mini rrweb-player → Continue → Send → admin
  replay (Phase 3) shows synchronized audio.
- Path B → Re-record: record + mic → Stop → Re-record → record again
  without mic → Stop → review shows no audio player (the new
  recording had no audio, the old blob was discarded).

## Risks

| Risk | Mitigation |
|---|---|
| `pill-action` slot UI is too small for the mic state visualization | Pill template owner (phoenix_replay) reserves enough space; addon falls back to icon-only if cramped |
| Audio preview player on the user side duplicates Phase 3 admin player code | Extract a shared JS module if the duplication grows; first cut accepts a small duplication for shipping speed |
| Re-record race: user clicks Re-record while audio upload in progress | Audio upload doesn't start until Send, not Stop; Re-record before Send is safe (no upload to abort) |
| Browser permission denial in `pill-action` | Inline notice within the pill ("Microphone blocked"); toggle disables; rest of Path B flow continues |
| Path B-only addon design leaves Path A users without any way to add audio context | Path A is text-only by ADR-0006 design; users who want audio pick Path B |

## Out of scope

- Resource-shape changes on Feedback (severity, audio fields stay as
  Phase 1+2 left them).
- Server-side audio uploading changes (controllers, blob lifecycle —
  all unchanged).
- Migrating other Phase 2 hooks (none exist; audio is the only
  current addon).
- Renaming the `:on_demand` mode symbol — phoenix_replay ADR-0006 Q-F
  keeps it.
- gs_net host migration — gs_net is a private workplace repo (memory
  `project_gs_net_visibility.md`); the user owns that migration.

## Decisions log (carry-forward)

| Source | Decision | Carried into |
|---|---|---|
| ADR-0001 (audio narration) | Audio lives in ash_feedback, AshStorage backed | unchanged |
| Phase 2 D2 (offset on blob metadata) | `audio_start_offset_ms` on blob, not attachment | preserved |
| Phase 3 (admin playback) | Audio playback subscribes to timeline bus | preserved (admin side); user-side preview reuses pattern |
| Mode-aware spec D4 | Label "Add voice commentary" | preserved on pill |
| phoenix_replay ADR-0006 Q-E | New slots `pill-action` + `review-media` | this spec consumes both |

## Addendum trigger

If the upstream phoenix_replay slot lifecycle differs from what this
spec assumes (e.g., mount/unmount semantics need a different shape),
append an addendum here.

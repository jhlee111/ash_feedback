# Design: Audio Pre-Flight Toggle — Single-Clip Session Model

**Date**: 2026-04-26
**Status**: Draft.
**Owners**: ash_feedback (this spec), phoenix_replay (provides
`idle-start-options` slot + `canStart` hook).
**Supersedes**: portions of
[`2026-04-25-audio-addon-pill-relocation-design.md`](2026-04-25-audio-addon-pill-relocation-design.md)
— D1 (pill-action mic toggle), D2 (audio_start_offset_ms metadata),
the multi-toggle implications of D3.

## Context

The pill-action audio addon shipped with a mid-flight mic toggle: the
user starts a Path B recording, then optionally clicks the 🎙 button
on the pill to begin capturing voice. A second click stops the audio
clip; a third click can begin a fresh clip (which silently overwrites
the first because `audioState.blob` is a single-slot singleton).

This UX leaves the user with three latent footguns:

1. **Multi-toggle ambiguity.** The UI suggests multiple clips per
   session, but only the last one survives. There is no error, no
   warning — earlier clips are dropped silently.
2. **`audio_start_offset_ms` complexity.** Because the audio clip can
   start at any point within the rrweb timeline, a separate
   metadata field carries the offset so the admin replay can sync
   audio to video. Every layer (client, prepare endpoint, blob
   metadata, replay player) has to handle it.
3. **Stop-button race.** When the user clicks the pill's Stop while
   audio is still recording, `recorder.stop()` is queued, but
   `recorder.onstop` (which writes the captured blob into the
   singleton) fires *after* the review modal has already mounted
   `review-media`. The review preview shows nothing, even though
   the underlying blob will eventually be saved and uploaded on
   Send.

The core simplification: **audio commentary is decided once,
pre-recording. If on, audio runs from the rrweb start to the rrweb
stop. Always one clip per session, always offset = 0.**

## Architectural decisions

### D1 — Voice toggle moves to a new pre-flight surface (`idle-start-options`)

phoenix_replay's `idle_start` screen gains a new slot:

```html
<section class="phx-replay-screen phx-replay-screen--idle-start" ...>
  <h2>Record your reproduction</h2>
  <p class="phx-replay-screen-lede">...</p>
  <div class="phx-replay-screen-options" data-slot="idle-start-options"></div>
  <div class="phx-replay-actions">
    <button class="phx-replay-cancel">Cancel</button>
    <button class="phx-replay-start-cta">Start recording</button>
  </div>
</section>
```

The slot is panel-scoped: it mounts when the user enters `idle-start`
(via the choose card or Re-record), unmounts when the screen leaves.
Re-record returning to `idle-start` therefore re-runs the addon's
mount, which re-reads the persisted toggle state and re-renders
fresh.

ash_feedback's audio addon registers a fourth mount (in addition to
`pill-action`, `review-media`, `form-top`) for `idle-start-options`.
That mount renders the checkbox UI and an inline error region.

### D2 — `canStart` hook gates Start with addon checks

phoenix_replay exposes a registry on the panel:

```js
panel.registerCanStart(id, fn)   // fn returns Promise<{ok: true} | {ok: false, error: string}>
panel.unregisterCanStart(id)
```

`handleStartFromPanel` runs the registered hooks (in parallel) before
calling `client.startRecording`. If any hook returns `{ok: false}`,
phoenix_replay shows the error inline beneath the options slot and
re-enables Start so the user can change their input. Hooks are pure
functions of addon state — they may call `getUserMedia` and similar
permission-gated APIs; phoenix_replay does not need to know what
they're checking.

The audio addon's hook reads `audioState.voiceEnabled`:

```js
async () => {
  if (!audioState.voiceEnabled) return { ok: true };
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    audioState._pendingStream = stream;
    return { ok: true };
  } catch (err) {
    return { ok: false, error: "Microphone blocked. Allow it in your browser, or uncheck voice commentary." };
  }
}
```

If the user changes the checkbox after a denied attempt, the addon
calls `panel.clearInlineError("idle-start-options")` and re-enables
Start (a generic API exposed alongside `canStart`).

### D3 — `pill-action` mount auto-records; mic button removed

When `pill-action` mounts (Path B's `:active` state), the audio addon
checks `audioState.voiceEnabled` and `audioState._pendingStream`:

- both present → consume the cached stream, construct
  `MediaRecorder`, call `start()`, render a passive 🎙 indicator
  (no click handler).
- voiceEnabled but no stream (rare — pre-flight succeeded then the
  user navigated, returned, and the stream died) → render a 🎙̸
  indicator with a "Mic disconnected" tooltip; rrweb continues
  silently.
- voiceEnabled false → render nothing. Slot stays empty.

The cleanup function returns a Promise that resolves after
`recorder.onstop` writes the blob into `audioState`. The pill-action
slot's `unmountSlot` call returns `Promise.all` of all addon
cleanups (D4), so `handleStop` can `await` it before opening the
review modal.

### D4 — Addon cleanup contract extends to support async returns

`unmountAddonsForSlot` becomes:

```js
function unmountAddonsForSlot(slotName) {
  const state = slotState.get(slotName);
  if (!state) return Promise.resolve();
  const promises = [];
  state.forEach((cleanup, id) => {
    if (typeof cleanup !== "function") return;
    try {
      const result = cleanup();
      if (result && typeof result.then === "function") promises.push(result);
    } catch (err) {
      console.warn(`[PhoenixReplay] addon "${id}" cleanup failed for slot "${slotName}": ${err.message}`);
    }
  });
  state.clear();
  return promises.length ? Promise.all(promises).then(() => {}) : Promise.resolve();
}
```

`panel.unmountSlot(name)` returns whatever `unmountAddonsForSlot`
returns. Existing addons that return `undefined` or a sync function
are unaffected (`Promise.all([])` resolves immediately).

`handleStop` awaits `panel.unmountSlot("pill-action")` before
opening the review modal. This is the canonical fix for the timing
race described in the Context.

### D5 — `audio_start_offset_ms` is removed end-to-end

Always-zero offset means the field carries no information. Removed
from:

- `AshFeedback.Resources.Feedback` attributes
- `AshFeedback.Storage.*` blob metadata write/read paths
- `AudioUploadsController.prepare/2` accepted metadata keys
- Client `audio_recorder.js` prepare payload
- Admin replay player audio sync logic (audio plays from t=0)
- ADR-0001 (mark the offset metadata decision as superseded)

A single Ecto migration drops the column. Dev DBs are the only
known consumers; ash_feedback is not yet published to Hex
(per workspace memory: gs_net is a private workplace repo, library
docs target eventual Hex publish but no external host is on this
schema today).

### D6 — Host configures default via `audio_default` widget attr

`PhoenixReplay.UI.Components.phoenix_replay_widget` gains:

```elixir
attr :audio_default, :atom, default: :off, values: [:on, :off],
  doc: "Initial state of the voice-commentary toggle on the idle-start screen. \
        ash_feedback's audio addon reads `data-audio-default` from the widget root \
        to decide the checkbox's initial value. `:off` (default) is privacy-friendly \
        and avoids first-time permission prompts; `:on` is suitable for QA-internal \
        portals."
```

Emitted as `data-audio-default="on"|"off"` on the widget div. ash_feedback
addon reads it during `idle-start-options` mount.

The demo's `/demo/on-demand-float` page sets `audio_default={:on}` so
manual smoke flows exercise the mic permission path on first visit.

### D7 — Re-record returns to idle-start, not directly to `:active`

`Re-record` from the review screen previously called `startAndSync`
directly, immediately swapping the review modal for the recording
pill. With pre-flight as the source of truth for voice on/off, the
button now closes the review and re-opens `idle-start`, giving the
user another chance to change the toggle (and re-grant the mic if
they want to add voice this time).

If the user wants the previous behavior ("just start over with the
same options"), they click Start again — same flow as the first
attempt. The cost is one extra click in the rare case the user just
wants to redo a recording with identical options.

## Failure modes

| Mode | Behavior |
|---|---|
| Mic permission denied | Inline red message + Start button disabled. User unchecks voice or grants permission and retries. |
| Mic stream dies between pre-flight and pill-action mount | Pill renders 🎙̸ (mic-off) indicator; rrweb continues silently. No clip captured. |
| Modal Cancel during pre-flight permission prompt | `panel.onClose` cleanup stops any cached stream tracks. |
| Stop clicked while recording | `handleStop` awaits the pill-action unmount; the audio addon's cleanup resolves after `recorder.onstop` writes the blob. Review modal opens with the audio preview populated. |
| Voice OFF entirely | No 🎙 anywhere. `review-media` mounts as a no-op. `form-top` `beforeSubmit` returns `{ extras: {} }`. Same code path as Path A. |
| Browser without `MediaRecorder` (rare) | `idle-start-options` mount renders the checkbox disabled with "Voice not supported in this browser" helper text. `voiceEnabled` stays false. |

## Out of scope

- Multiple clips per session. Confirmed in brainstorming as a
  deliberate non-goal — single-clip-per-session is the entire point
  of the redesign.
- Mid-recording mute toggle. Removed — the pre-flight decision is
  the only voice control.
- Audio-only recording (no rrweb). Path B's contract requires both;
  Path A explicitly excludes audio.
- Schema-level history of past `audio_start_offset_ms` values. Dev DB
  rows are dropped with the column.
- Migration shim for external hosts on the old schema. ash_feedback
  is not yet published; revisit when it is.

## Implementation phases (sketch — fleshed out in writing-plans)

The plan generator will likely break this into three phases, possibly
across two PRs:

1. **phoenix_replay** — `idle-start-options` slot, `canStart` hook
   registry, async-aware `unmountAddonsForSlot`, `audio_default`
   widget attr. Independent of ash_feedback; lands first.
2. **ash_feedback** — audio addon rewrite (idle-start-options mount,
   pill-action auto-record + passive indicator, async cleanup that
   awaits onstop), schema migration dropping `audio_start_offset_ms`,
   prepare endpoint cleanup, ADR-0001 supersede note.
3. **demo** — bump phoenix_replay + ash_feedback deps, set
   `audio_default={:on}` on `/demo/on-demand-float` for manual
   smoke, update brainstorm screens / ADRs as needed.

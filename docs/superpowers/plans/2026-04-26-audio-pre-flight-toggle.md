# Audio Pre-Flight Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mid-flight mic toggle with a pre-flight voice checkbox so audio recording is locked to the exact rrweb session window; drop `audio_start_offset_ms` end-to-end.

**Architecture:** Three sequential phases across two libraries + one host. Phase 1 lands generic phoenix_replay primitives (new slot, `canStart` hook registry, async unmount, widget attr). Phase 2 rewrites the ash_feedback audio addon to use those primitives and drops the offset column. Phase 3 bumps the demo and exercises manual smoke.

**Tech Stack:** Elixir/Ash (resource + migrations), JS (rrweb addon, vanilla DOM), Phoenix LiveView (host components), node CommonJS unit tests, Tidewave `browser_eval` for smoke.

**Spec:** [`docs/superpowers/specs/2026-04-26-audio-pre-flight-toggle-design.md`](../specs/2026-04-26-audio-pre-flight-toggle-design.md)

---

## File Structure

### phoenix_replay (`~/Dev/phoenix_replay/`)
- **Modify** `priv/static/assets/phoenix_replay.js`:
  - Idle-start screen markup gains `<div data-slot="idle-start-options" class="phx-replay-screen-options"></div>` + an inline-error region.
  - `unmountAddonsForSlot` returns `Promise<void>`.
  - `panel.unmountSlot` returns the unmount promise.
  - New `panel.registerCanStart(id, fn)` / `panel.unregisterCanStart(id)` registry.
  - New `panel.showInlineError(slotName, msg)` / `panel.clearInlineError(slotName)`.
  - New `panel.disableStart()` / `panel.enableStart()`.
  - `handleStartFromPanel` runs registered canStart hooks; bails on first failure.
  - `handleStop` awaits `panel.unmountSlot("pill-action")` before opening review.
  - `_testInternals` exposes new helpers needed by JS unit tests.
- **Modify** `priv/static/assets/phoenix_replay.css`:
  - Layout for `.phx-replay-screen-options` slot container.
  - Layout for `.phx-replay-inline-error` (red banner inside idle-start).
- **Modify** `lib/phoenix_replay/ui/components.ex`:
  - New `audio_default` attr on `phoenix_replay_widget` (`:on | :off`, default `:off`).
  - Emit `data-audio-default` on the widget root.
- **Create** `test/js/canstart_hook_test.js` (CommonJS, follows `ring_buffer_test.js` pattern).
- **Modify** `test/phoenix_replay/ui/components_test.exs` (assert new data attr).

### ash_feedback (`~/Dev/ash_feedback/`)
- **Modify** `mix.exs` lock to phase-1 phoenix_replay SHA (via `mix deps.update phoenix_replay`).
- **Rewrite** `priv/static/assets/audio_recorder.js`:
  - `audioState` shape: `{ voiceEnabled, blob, mimeType, ext, _pendingStream }` (no `offsetMs`).
  - New `mountIdleStartOptions` (renders checkbox + registers canStart).
  - Rewrite `mountPillAction` (auto-record from cached stream, passive 🎙 indicator, async cleanup).
  - Trim `mountFormTop` (no offset metadata).
- **Modify** `lib/ash_feedback/resources/feedback.ex` — remove `audio_start_offset_ms` attribute.
- **Modify** `lib/ash_feedback/controller/audio_uploads_controller.ex` — drop `audio_start_offset_ms` from accepted metadata.
- **Modify** `lib/ash_feedback/storage.ex` (or wherever blob metadata is keyed) — drop offset key.
- **Modify** `lib/ash_feedback_web/components/audio_playback.ex` — playback always starts at t=0; remove offset seek.
- **Generate** `priv/repo/migrations/<ts>_drop_audio_start_offset_ms.exs` via `mix ash.codegen drop_audio_start_offset_ms`.
- **Modify** `docs/decisions/0001-audio-narration-via-ash-storage.md` — append supersede note.
- **Modify** `test/ash_feedback/audio_round_trip_test.exs` — drop offset assertions.
- **Modify** `test/ash_feedback/resources/feedback_audio_test.exs` — drop offset attribute test.
- **Create** `test/js/audio_recorder_test.js` (mountIdleStartOptions checkbox + canStart hook behavior with stubbed `getUserMedia` + `MediaRecorder`).

### ash_feedback_demo (`~/Dev/ash_feedback_demo/`)
- **Modify** `mix.lock` (via `mix deps.update phoenix_replay ash_feedback`).
- **Modify** `lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex` — add `audio_default={:on}` to widget call.
- Manual smoke per checklist in Task 22.

---

# Phase 1 — phoenix_replay primitives

Phase 1 ships independently. Existing addons (today's audio addon in ash_feedback at the old SHA) keep working because all new APIs are additive: addons that don't register canStart hooks see no change, and addons that return sync cleanups go through `Promise.resolve()`.

## Task 1: idle-start-options slot in panel markup

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (panel HTML for `SCREENS.IDLE_START` section)

- [ ] **Step 1: Locate the idle_start markup**

```bash
cd ~/Dev/phoenix_replay
grep -n "phx-replay-screen--idle-start" priv/static/assets/phoenix_replay.js
```

Expected: one hit inside the panel HTML template (around line 640-ish).

- [ ] **Step 2: Add slot + inline-error region to the markup**

Find the `<section class="phx-replay-screen phx-replay-screen--idle-start" ...>` block and update its body. The existing block looks like (paraphrased):

```js
<section class="phx-replay-screen phx-replay-screen--idle-start" data-screen="${SCREENS.IDLE_START}" hidden>
  <h2>Record your reproduction</h2>
  <p class="phx-replay-screen-lede">Click Start to capture your screen…</p>
  <div class="phx-replay-actions">
    <button type="button" class="phx-replay-cancel">Cancel</button>
    <button type="button" class="phx-replay-start-cta">Start recording</button>
  </div>
</section>
```

Insert the slot + error region between the lede and the actions:

```js
<section class="phx-replay-screen phx-replay-screen--idle-start" data-screen="${SCREENS.IDLE_START}" hidden>
  <h2>Record your reproduction</h2>
  <p class="phx-replay-screen-lede">Click Start to capture your screen…</p>
  <div class="phx-replay-screen-options" data-slot="idle-start-options"></div>
  <div class="phx-replay-inline-error" data-slot-error="idle-start-options" hidden></div>
  <div class="phx-replay-actions">
    <button type="button" class="phx-replay-cancel">Cancel</button>
    <button type="button" class="phx-replay-start-cta">Start recording</button>
  </div>
</section>
```

`data-slot-error` lets `panel.showInlineError(slotName, msg)` find the right region by slot name (Task 5).

- [ ] **Step 3: Verify setScreen lifecycle picks up the new slot for free**

`setScreen` already iterates `[data-slot]` inside entering/leaving sections and calls `mountAddonsForSlot` / `unmountAddonsForSlot` (with form-top exclusion). Read the function to confirm no change is needed for `idle-start-options`:

```bash
grep -n "function setScreen" priv/static/assets/phoenix_replay.js
```

Open the section it points at; confirm the slot lifecycle code path runs for any non-form-top slot. No code change required.

- [ ] **Step 4: Smoke — open the demo and confirm the slot is in DOM**

```bash
# In the demo terminal:
cd ~/Dev/ash_feedback_demo
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js deps/phoenix_replay/priv/static/assets/phoenix_replay.js
mix deps.compile phoenix_replay --force
```

Then via Tidewave `browser_eval`:

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(() => {
  // Open the panel and navigate to idle-start
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  const slot = document.querySelector("[data-slot='idle-start-options']");
  const err = document.querySelector("[data-slot-error='idle-start-options']");
  console.log("slot exists:", !!slot, "error region exists:", !!err, "error hidden:", err?.hasAttribute("hidden"));
});
```

Expected: `slot exists: true`, `error region exists: true`, `error hidden: true`.

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/phoenix_replay
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(panel): add idle-start-options slot + inline-error region

Pre-flight options surface for addons that need to ask the user
something before Start (e.g., voice commentary toggle). Inline-error
region pairs with showInlineError API in a follow-up task."
```

---

## Task 2: Async-aware `unmountAddonsForSlot`

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (`unmountAddonsForSlot`, expose helper for tests)
- Create: `~/Dev/phoenix_replay/test/js/canstart_hook_test.js` (just the async-cleanup section for now; expanded in Task 4)

- [ ] **Step 1: Write the failing test for async cleanup**

Create `~/Dev/phoenix_replay/test/js/canstart_hook_test.js`:

```js
// Tests for panel async lifecycle: cleanup Promise, canStart hooks,
// inline-error API. Run with: node test/js/canstart_hook_test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "phoenix_replay.js"),
  "utf8"
);

// Minimal browser shim — phoenix_replay's IIFE expects a window-ish global
// plus document for panel HTML. We don't need a full DOM; the helpers we
// pull out via _testInternals are pure-ish.
function makeSandbox() {
  const sandbox = {
    window: {},
    document: undefined,
    console,
    setTimeout,
    clearTimeout,
    Promise,
  };
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  return sandbox;
}

function assert(cond, msg) {
  if (!cond) { console.error("FAIL:", msg); process.exit(1); }
}

(async () => {
  const sb = makeSandbox();
  const { collectCleanupResults } = sb.window.PhoenixReplay._testInternals;

  // --- sync cleanups: returns resolved Promise ---
  {
    const cleanups = new Map();
    let counter = 0;
    cleanups.set("a", () => { counter += 1; });
    cleanups.set("b", () => { counter += 10; });
    const result = collectCleanupResults(cleanups);
    assert(result && typeof result.then === "function", "returns a thenable");
    await result;
    assert(counter === 11, "all sync cleanups ran");
  }

  // --- mixed sync + async ---
  {
    const cleanups = new Map();
    let asyncDone = false;
    cleanups.set("sync", () => {});
    cleanups.set("async", () => new Promise(r => setTimeout(() => { asyncDone = true; r(); }, 10)));
    await collectCleanupResults(cleanups);
    assert(asyncDone, "async cleanup completed before promise resolved");
  }

  // --- thrown sync cleanup is logged but does not abort other cleanups ---
  {
    const cleanups = new Map();
    let bRan = false;
    cleanups.set("a", () => { throw new Error("boom"); });
    cleanups.set("b", () => { bRan = true; });
    await collectCleanupResults(cleanups);
    assert(bRan, "sibling cleanup ran despite earlier throw");
  }

  console.log("canstart_hook_test: ok");
})();
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
cd ~/Dev/phoenix_replay
node test/js/canstart_hook_test.js
```

Expected: `TypeError: Cannot read properties of undefined (reading 'collectCleanupResults')` (or similar — `_testInternals` doesn't expose it yet).

- [ ] **Step 3: Implement `collectCleanupResults` and rewire `unmountAddonsForSlot`**

In `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` find the existing `unmountAddonsForSlot`:

```js
function unmountAddonsForSlot(slotName) {
  const state = slotState.get(slotName);
  if (!state) return;
  state.forEach((cleanup, id) => {
    if (typeof cleanup === "function") {
      try { cleanup(); } catch (err) {
        console.warn(`[PhoenixReplay] addon "${id}" cleanup failed for slot "${slotName}": ${err.message}`);
      }
    }
  });
  state.clear();
}
```

Replace with:

```js
function collectCleanupResults(stateMap) {
  const promises = [];
  stateMap.forEach((cleanup, id) => {
    if (typeof cleanup !== "function") return;
    try {
      const result = cleanup();
      if (result && typeof result.then === "function") promises.push(result);
    } catch (err) {
      console.warn(`[PhoenixReplay] addon "${id}" cleanup failed: ${err.message}`);
    }
  });
  return promises.length ? Promise.all(promises).then(() => {}) : Promise.resolve();
}

function unmountAddonsForSlot(slotName) {
  const state = slotState.get(slotName);
  if (!state) return Promise.resolve();
  const promise = collectCleanupResults(state);
  state.clear();
  return promise;
}
```

- [ ] **Step 4: Expose `collectCleanupResults` via `_testInternals`**

Search for `_testInternals` (the existing test hook used by `ring_buffer_test.js`):

```bash
grep -n "_testInternals" priv/static/assets/phoenix_replay.js
```

Add `collectCleanupResults` to the exported object:

```js
window.PhoenixReplay._testInternals = Object.assign(
  window.PhoenixReplay._testInternals || {},
  { createRingBuffer, collectCleanupResults }
);
```

(Adjust to match the existing exposure shape — the existing line should give the pattern.)

- [ ] **Step 5: Run the test, confirm it passes**

```bash
node test/js/canstart_hook_test.js
```

Expected: `canstart_hook_test: ok`.

- [ ] **Step 6: Update `panel.unmountSlot` return value**

Find the panel API exposure block (it returns an object containing `mountSlot`, `unmountSlot`, etc.). Confirm `unmountSlot` is currently:

```js
unmountSlot: (slotName) => unmountAddonsForSlot(slotName),
```

Already returns whatever `unmountAddonsForSlot` returns — now a Promise. No code change required, but verify the line still threads the value through (it does — arrow returns the call expression). If a wrapper drops the return value anywhere, fix it.

- [ ] **Step 7: Commit**

```bash
git add priv/static/assets/phoenix_replay.js test/js/canstart_hook_test.js
git commit -m "feat(panel): unmountAddonsForSlot returns Promise — async cleanup support

Cleanup functions may now return a Promise; unmountAddonsForSlot
awaits all of them via Promise.all. Sync cleanups continue to work
unchanged (Promise.resolve fallback). Enables addons that need an
async tick to flush state into shared singletons before the next
slot mounts."
```

---

## Task 3: `handleStop` awaits pill-action unmount (timing-race fix)

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (`handleStop`, `syncRecordingUI`)

- [ ] **Step 1: Read the current `handleStop`**

```bash
grep -n "async function handleStop" priv/static/assets/phoenix_replay.js
```

Around line 1297, you'll see:

```js
async function handleStop() {
  const wasRecording = client.isRecording();
  await client.stopRecording();
  if (!wasRecording) return;
  syncRecordingUI();
  const events = client.takeReviewEvents();
  panel.openReview(events);
}
```

`syncRecordingUI` calls `panel.unmountSlot("pill-action")` synchronously (fire-and-forget). We need to await that promise.

- [ ] **Step 2: Refactor — split `syncRecordingUI` so `handleStop` can await unmount**

Replace `handleStop` and `syncRecordingUI`. Read the existing `syncRecordingUI`:

```js
function syncRecordingUI() {
  const recording = client.isRecording();
  if (pill) {
    if (recording) {
      pill.show(client._internals.sessionStartedAtMs?.() ?? Date.now());
      panel.mountSlot("pill-action", pill.slotEl);
    } else {
      panel.unmountSlot("pill-action");
      pill.hide();
    }
  }
  if (toggle && pill) recording ? toggle.hide() : toggle.show();
}
```

Replace with:

```js
function syncRecordingUI() {
  // Synchronous variant — used by callers that don't need to await
  // the pill-action unmount (e.g., handleStart, handleReRecord).
  const recording = client.isRecording();
  if (pill) {
    if (recording) {
      pill.show(client._internals.sessionStartedAtMs?.() ?? Date.now());
      panel.mountSlot("pill-action", pill.slotEl);
    } else {
      panel.unmountSlot("pill-action");
      pill.hide();
    }
  }
  if (toggle && pill) recording ? toggle.hide() : toggle.show();
}

async function syncRecordingUIAwait() {
  // Async variant — awaits pill-action unmount so addons that flush
  // state via async cleanup (audio onstop) settle into shared
  // singletons before the next call site (handleStop → openReview).
  const recording = client.isRecording();
  if (pill) {
    if (recording) {
      pill.show(client._internals.sessionStartedAtMs?.() ?? Date.now());
      panel.mountSlot("pill-action", pill.slotEl);
    } else {
      await panel.unmountSlot("pill-action");
      pill.hide();
    }
  }
  if (toggle && pill) recording ? toggle.hide() : toggle.show();
}
```

Update `handleStop`:

```js
async function handleStop() {
  const wasRecording = client.isRecording();
  await client.stopRecording();
  if (!wasRecording) return;
  await syncRecordingUIAwait();
  const events = client.takeReviewEvents();
  panel.openReview(events);
}
```

- [ ] **Step 3: Smoke via Tidewave with stubbed MediaRecorder**

```bash
cd ~/Dev/ash_feedback_demo
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js deps/phoenix_replay/priv/static/assets/phoenix_replay.js
mix deps.compile phoenix_replay --force
```

Restart server via Tidewave, then `browser_eval`:

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(async () => {
  // Stub MediaRecorder so the audio addon completes a fake recording.
  let stopCalledAt = 0, onstopFiredAt = 0;
  class StubRecorder {
    constructor() { this.state = "inactive"; }
    start() { this.state = "recording"; }
    stop() {
      stopCalledAt = Date.now();
      this.state = "inactive";
      setTimeout(() => {
        if (this.ondataavailable) this.ondataavailable({ data: new Blob(["x"], { type: "audio/webm" }) });
        if (this.onstop) this.onstop();
        onstopFiredAt = Date.now();
      }, 0);
    }
  }
  StubRecorder.isTypeSupported = () => true;
  window.MediaRecorder = StubRecorder;
  navigator.mediaDevices.getUserMedia = async () => ({ getTracks: () => [{ stop() {} }] });

  // Drive the flow.
  await window.PhoenixReplay.startRecording();
  await new Promise(r => setTimeout(r, 200));
  document.querySelector(".phx-replay-audio-pill-mic").click();
  await new Promise(r => setTimeout(r, 200));
  document.querySelector(".phx-replay-pill-stop").click();
  await new Promise(r => setTimeout(r, 1000));

  const audio = document.querySelector(".phx-replay-audio-review-player");
  console.log("review audio rendered:", !!audio,
              "stop@", stopCalledAt, "onstop@", onstopFiredAt,
              "audio.src starts with blob:", audio && audio.src.startsWith("blob:"));
});
```

Expected: `review audio rendered: true` AND `audio.src starts with blob: true`. (Phase 2 will add the addon side that returns a Promise from cleanup; until then, the audio addon's existing sync cleanup means the race still exists and this expectation will fail. That's OK — note the expected post-Phase-2 outcome and proceed.)

For Phase 1 alone, replace the expectation with: "no JS errors thrown". If the panel panic-renders, the change is broken; otherwise it's behaviorally identical for now.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/phoenix_replay
git add priv/static/assets/phoenix_replay.js
git commit -m "fix(panel): handleStop awaits pill-action unmount before openReview

Prevents the timing race where review-media mounts before an addon's
async cleanup (e.g. audio recorder.onstop) has flushed state into
shared singletons. Synchronous callers keep the original
syncRecordingUI; handleStop uses syncRecordingUIAwait."
```

---

## Task 4: `canStart` hook registry + integration

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (registry, panel API exposure, `handleStartFromPanel`)
- Modify: `~/Dev/phoenix_replay/test/js/canstart_hook_test.js` (extend with hook tests)

- [ ] **Step 1: Add failing tests for the canStart registry**

Append to `test/js/canstart_hook_test.js` (before the final `console.log` line):

```js
  // --- canStart registry: empty → ok ---
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([]);
    assert(result.ok === true, "empty hook list returns ok:true");
  }

  // --- single hook ok ---
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["audio", async () => ({ ok: true })],
    ]);
    assert(result.ok === true, "single ok hook returns ok:true");
  }

  // --- single hook fails → first error wins ---
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["audio", async () => ({ ok: false, error: "Mic blocked." })],
    ]);
    assert(result.ok === false, "failing hook returns ok:false");
    assert(result.error === "Mic blocked.", "error message threaded through");
    assert(result.failingId === "audio", "failingId identifies the hook");
  }

  // --- one ok + one fail → fail wins, error from failing hook ---
  {
    const sb2 = makeSandbox();
    const { runCanStartHooks } = sb2.window.PhoenixReplay._testInternals;
    const result = await runCanStartHooks([
      ["zzz", async () => ({ ok: true })],
      ["audio", async () => ({ ok: false, error: "Nope." })],
    ]);
    assert(result.ok === false, "any failure makes overall fail");
    assert(result.failingId === "audio", "fail propagates");
  }
```

- [ ] **Step 2: Run the tests, confirm they fail**

```bash
node test/js/canstart_hook_test.js
```

Expected: failure on `runCanStartHooks` undefined.

- [ ] **Step 3: Implement the registry + helper**

In `phoenix_replay.js` find the panel-builder closure (where `PANEL_ADDONS`, `slotState`, `addonHooks` are declared). Add near those declarations:

```js
// Pre-Start checks. Each entry is [id, async () => ({ok: true} | {ok: false, error: string})].
// Hooks run in registration order; the first failure short-circuits and
// determines the surfaced error. Used by handleStartFromPanel to gate
// Start on addon-supplied conditions (e.g., mic permission grant).
const canStartHooks = [];

async function runCanStartHooks(hooks) {
  for (const [id, fn] of hooks) {
    let result;
    try {
      result = await fn();
    } catch (err) {
      result = { ok: false, error: err && err.message ? err.message : String(err) };
    }
    if (!result || result.ok === false) {
      return {
        ok: false,
        error: (result && result.error) || "Pre-flight check failed.",
        failingId: id,
      };
    }
  }
  return { ok: true };
}
```

Expose it on the panel API object (where `mountSlot`, `unmountSlot`, etc. live):

```js
return {
  // ...existing entries...
  registerCanStart: (id, fn) => {
    const idx = canStartHooks.findIndex(([existingId]) => existingId === id);
    if (idx !== -1) canStartHooks[idx] = [id, fn];
    else canStartHooks.push([id, fn]);
  },
  unregisterCanStart: (id) => {
    const idx = canStartHooks.findIndex(([existingId]) => existingId === id);
    if (idx !== -1) canStartHooks.splice(idx, 1);
  },
};
```

Add `runCanStartHooks` to `_testInternals`:

```js
window.PhoenixReplay._testInternals = Object.assign(
  window.PhoenixReplay._testInternals || {},
  { createRingBuffer, collectCleanupResults, runCanStartHooks }
);
```

- [ ] **Step 4: Wire into `handleStartFromPanel`**

Find the existing handler:

```js
async function handleStartFromPanel() {
  try {
    await startAndSync();
    panel.close();
  } catch (err) {
    panel.openError(`Couldn't start recording: ${err.message}`);
  }
}
```

Update to run hooks first:

```js
async function handleStartFromPanel() {
  panel.disableStart();        // implemented in Task 5
  panel.clearInlineError();    // implemented in Task 5
  const check = await runCanStartHooks(canStartHooks);
  panel.enableStart();
  if (!check.ok) {
    panel.showInlineError("idle-start-options", check.error);
    return;
  }
  try {
    await startAndSync();
    panel.close();
  } catch (err) {
    panel.openError(`Couldn't start recording: ${err.message}`);
  }
}
```

(Tasks 5 implements the inline-error + start-button enable/disable APIs. The calls to `panel.disableStart` etc. are forward references; you'll get runtime errors until Task 5 lands. Sequence the commits accordingly — leave `handleStartFromPanel` referencing the new APIs only after they exist.)

- [ ] **Step 5: Run the JS tests, confirm green**

```bash
node test/js/canstart_hook_test.js
```

Expected: `canstart_hook_test: ok`.

- [ ] **Step 6: Commit**

```bash
git add priv/static/assets/phoenix_replay.js test/js/canstart_hook_test.js
git commit -m "feat(panel): canStart hook registry — gate Start on addon checks

panel.registerCanStart(id, fn) lets addons (typically registered
during their idle-start-options mount) provide async pre-flight
checks. handleStartFromPanel runs them in order and surfaces the
first failure as an inline error. Sets up the audio addon's
mic-permission gate."
```

---

## Task 5: inline-error + Start button enable/disable APIs

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js`

- [ ] **Step 1: Locate the panel root + Start CTA references**

```bash
grep -n "phx-replay-start-cta\|phx-replay-inline-error" priv/static/assets/phoenix_replay.js
```

Expected: `phx-replay-start-cta` is bound to a `click` handler near `panel.onStart` registration. `phx-replay-inline-error` only appears in the markup added in Task 1.

- [ ] **Step 2: Implement the four panel API methods**

Inside the panel-builder closure where `mountSlot`, `unmountSlot`, etc. are defined, add helpers:

```js
function showInlineError(slotName, msg) {
  const region = root.querySelector(`[data-slot-error='${slotName}']`);
  if (!region) return;
  region.textContent = msg;
  region.hidden = false;
}

function clearInlineError(slotName) {
  if (slotName) {
    const region = root.querySelector(`[data-slot-error='${slotName}']`);
    if (region) { region.textContent = ""; region.hidden = true; }
    return;
  }
  // No slotName — clear ALL inline error regions (used when transitioning screens).
  root.querySelectorAll("[data-slot-error]").forEach((r) => {
    r.textContent = "";
    r.hidden = true;
  });
}

function disableStart() {
  const btn = root.querySelector(".phx-replay-start-cta");
  if (btn) btn.disabled = true;
}

function enableStart() {
  const btn = root.querySelector(".phx-replay-start-cta");
  if (btn) btn.disabled = false;
}
```

Expose on the panel API:

```js
return {
  // ...existing entries...
  showInlineError,
  clearInlineError,
  disableStart,
  enableStart,
};
```

- [ ] **Step 3: Smoke via Tidewave**

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(async () => {
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  // Synthetic call into the panel API (exposed as window.PhoenixReplay._panel for test convenience — if not exposed, skip and rely on the real flow in Phase 2).
  // For now just confirm DOM markup behaves.
  const region = document.querySelector("[data-slot-error='idle-start-options']");
  console.log("region hidden initially:", region.hasAttribute("hidden"));
  // Manually toggle to simulate showInlineError.
  region.textContent = "Test error";
  region.hidden = false;
  console.log("region after manual show:", region.textContent, region.hidden);
});
```

Expected: `hidden initially: true`, `after manual show: Test error false`. Confirms the markup added in Task 1 is in place; the real wiring is exercised end-to-end in Phase 2.

- [ ] **Step 4: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(panel): inline-error + Start button enable/disable APIs

panel.showInlineError(slotName, msg) renders into the
[data-slot-error=<slotName>] region added in the prior task.
panel.disableStart / enableStart toggle the primary CTA. Used by
canStart hook flow to communicate failures without leaving
idle-start."
```

---

## Task 6: `audio_default` widget attr

**Files:**
- Modify: `~/Dev/phoenix_replay/lib/phoenix_replay/ui/components.ex` (`phoenix_replay_widget`)
- Modify: `~/Dev/phoenix_replay/test/phoenix_replay/ui/components_test.exs`

- [ ] **Step 1: Write failing component test**

Find the existing component test file:

```bash
grep -n "phoenix_replay_widget" test/phoenix_replay/ui/components_test.exs
```

Add a new test (style-match the existing tests in the file):

```elixir
test "audio_default attr emits data-audio-default on widget root" do
  assigns = %{}

  html_on =
    rendered_to_string(~H"""
    <PhoenixReplay.UI.Components.phoenix_replay_widget
      base_path="/api/feedback"
      csrf_token="t"
      audio_default={:on}
    />
    """)

  assert html_on =~ ~s{data-audio-default="on"}

  html_off =
    rendered_to_string(~H"""
    <PhoenixReplay.UI.Components.phoenix_replay_widget
      base_path="/api/feedback"
      csrf_token="t"
    />
    """)

  assert html_off =~ ~s{data-audio-default="off"}
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd ~/Dev/phoenix_replay
mix test test/phoenix_replay/ui/components_test.exs --max-failures 1
```

Expected: failure — attr unknown.

- [ ] **Step 3: Add the attr + emit the data attribute**

In `lib/phoenix_replay/ui/components.ex` find the existing `attr` block before `def phoenix_replay_widget(assigns)`. Add:

```elixir
attr :audio_default, :atom,
  default: :off,
  values: [:on, :off],
  doc:
    "Initial state of an addon-supplied voice-commentary toggle on the " <>
      "idle-start screen. Emitted as `data-audio-default` on the widget " <>
      "root; addons read it during their idle-start-options mount. " <>
      "`:off` (default) is privacy-friendly and avoids first-time " <>
      "permission prompts. `:on` is suitable for QA-internal portals."
```

In the rendered template (`~H"""...""")`), add `data-audio-default={@audio_default}` to the widget div:

```elixir
<div
  data-phoenix-replay
  data-base-path={@base_path}
  ...
  data-audio-default={@audio_default}
  {@rest}
/>
```

(Find the `<div data-phoenix-replay ...>` block in the existing template; add the new data attr alongside the others.)

- [ ] **Step 4: Run, confirm green**

```bash
mix test test/phoenix_replay/ui/components_test.exs --max-failures 1
```

Expected: pass.

- [ ] **Step 5: Don't run mix format**

Per the workspace memory note: this repo's `.formatter.exs` is missing `locals_without_parens` for `attr`, so `mix format` rewrites `attr foo, ...` as `attr(foo, ...)` everywhere. Don't run it.

- [ ] **Step 6: Commit**

```bash
git add lib/phoenix_replay/ui/components.ex test/phoenix_replay/ui/components_test.exs
git commit -m "feat(widget): audio_default attr — host opts the voice toggle on

Emitted as data-audio-default on the widget root for ash_feedback's
audio addon to read at idle-start-options mount time. Default :off
(privacy + no surprise permission prompt). Hosts that want to
default-on (QA portals, demos) pass audio_default={:on}."
```

---

## Task 7: CSS for new UI

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.css`

- [ ] **Step 1: Add styling for the slot container + inline error**

Append to the file (or alongside other `phx-replay-screen-*` rules):

```css
/* Idle-start options slot — host/addon-supplied controls (e.g. voice
 * commentary toggle) rendered above the action buttons. The slot
 * has no padding/border of its own; addons style their own internals. */
.phx-replay-screen-options {
  margin-top: 0.75rem;
}

.phx-replay-screen-options:empty {
  display: none;
}

/* Inline error region — paired with [data-slot-error] markup. Surfaces
 * canStart hook failures directly under the options slot so the user
 * sees the cause without leaving idle-start. */
.phx-replay-inline-error {
  margin-top: 0.5rem;
  padding: 0.55rem 0.7rem;
  border-radius: 0.35rem;
  background: var(--phx-replay-error-surface, #fef2f2);
  border-left: 3px solid var(--phx-replay-error-border, #f87171);
  color: var(--phx-replay-error-text, #991b1b);
  font-size: 0.78rem;
  line-height: 1.4;
}

.phx-replay-inline-error[hidden] {
  display: none;
}

/* Disabled Start CTA — visually communicates that pre-flight failed. */
.phx-replay-start-cta:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
```

- [ ] **Step 2: Smoke via Tidewave**

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(() => {
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  const region = document.querySelector("[data-slot-error='idle-start-options']");
  region.textContent = "Microphone blocked.";
  region.hidden = false;
  const cs = getComputedStyle(region);
  console.log("border-left:", cs.borderLeftWidth, cs.borderLeftStyle, cs.borderLeftColor);
  console.log("bg:", cs.backgroundColor);
});
```

Expected: red-ish background + 3px solid border on left. Visual verification only — no automated check.

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/phoenix_replay.css
git commit -m "style(panel): inline-error + screen-options slot styling

Red-tinted error banner inside idle-start, hides via [hidden] attr.
Empty options slot collapses (no margin gap when no addon mounts).
Disabled Start CTA dims to 50%."
```

---

## Task 8: Phase 1 push + tag

**Files:**
- (push only, no file changes)

- [ ] **Step 1: Confirm phase 1 commits**

```bash
cd ~/Dev/phoenix_replay
git log --oneline origin/main..HEAD
```

Expected: 7 commits from Tasks 1-7.

- [ ] **Step 2: Push**

```bash
git push origin main
```

- [ ] **Step 3: Capture the SHA for Phase 2**

```bash
git rev-parse HEAD
```

Record this SHA. Phase 2 starts by bumping the demo + ash_feedback to it.

---

# Phase 2 — ash_feedback rewrite

Phase 2 depends on Phase 1's published phoenix_replay SHA. All work in `~/Dev/ash_feedback/`.

## Task 9: Bump phoenix_replay dep

**Files:**
- Modify: `~/Dev/ash_feedback/mix.lock`

- [ ] **Step 1: Update phoenix_replay**

```bash
cd ~/Dev/ash_feedback
mix deps.update phoenix_replay
```

- [ ] **Step 2: Verify the new SHA in mix.lock matches the Phase 1 push**

```bash
grep phoenix_replay mix.lock
```

Expected: SHA matches the one captured in Task 8 Step 3.

- [ ] **Step 3: Compile + run tests to ensure nothing breaks**

```bash
mix compile
mix test --max-failures 5
```

Expected: green or pre-existing failures only (none introduced by the bump). The new APIs are additive — existing behavior is unchanged.

- [ ] **Step 4: Commit**

```bash
git add mix.lock
git commit -m "deps: bump phoenix_replay — pre-flight panel primitives

Pulls in idle-start-options slot, canStart hook registry,
async-aware unmountAddonsForSlot, audio_default widget attr. Existing
audio addon code continues to work; refactor lands in subsequent
commits."
```

---

## Task 10: Drop `audio_start_offset_ms` from JS prepare body

**Files:**
- Modify: `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js` (`mountFormTop` only — minimal scope for this task)

- [ ] **Step 1: Locate and remove the offset metadata block**

```bash
grep -n "audio_start_offset_ms\|offsetMs" priv/static/assets/audio_recorder.js
```

In `mountFormTop` find:

```js
if (typeof audioState.offsetMs === "number") {
  prepareBody.metadata = { audio_start_offset_ms: audioState.offsetMs };
}
```

Delete it. Also remove `audioState.offsetMs = ...` assignments in `mountPillAction` (the `startRecording` inner function) — search and delete each. The full audio addon rewrite happens in Task 14, but trimming offset references first lets the schema migration land cleanly.

- [ ] **Step 2: Smoke**

```bash
cd ~/Dev/ash_feedback_demo
cp ~/Dev/ash_feedback/priv/static/assets/audio_recorder.js deps/ash_feedback/priv/static/assets/audio_recorder.js
mix deps.compile ash_feedback --force
```

Restart server, open `/demo/on-demand-float`, complete a Path B cycle (mic toggle → record → stop → review → continue → send). Verify the request payload to `/audio_uploads/prepare` contains no `metadata.audio_start_offset_ms` (DevTools Network tab or `mcp__Tidewave__get_logs`).

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/ash_feedback
git add priv/static/assets/audio_recorder.js
git commit -m "refactor(audio): drop audio_start_offset_ms from prepare body

Single-clip-per-session model means offset is always 0; the metadata
field carries no information. Removing client-side first; server +
schema removal land in subsequent commits."
```

---

## Task 11: Drop `audio_start_offset_ms` from server-side metadata pipeline

**Files:**
- Modify: `~/Dev/ash_feedback/lib/ash_feedback/controller/audio_uploads_controller.ex`
- Modify: `~/Dev/ash_feedback/lib/ash_feedback/storage.ex` (or wherever `audio_start_offset_ms` is read in storage helpers)

- [ ] **Step 1: Find all server references**

```bash
cd ~/Dev/ash_feedback
grep -rn "audio_start_offset_ms" lib/
```

Expected hits: at least the controller's `prepare/2` action and the storage helpers that pass metadata through to AshStorage.

- [ ] **Step 2: Run the existing audio tests to capture pre-change baseline**

```bash
mix test test/ash_feedback/audio_round_trip_test.exs --max-failures 5
```

Note any tests asserting on `audio_start_offset_ms` — they need updating in this task.

- [ ] **Step 3: Remove offset key from controller `prepare/2`**

In `audio_uploads_controller.ex`'s `prepare/2`, find the metadata extraction code (likely a `Map.get(params, "metadata", %{})` or similar). Remove the `audio_start_offset_ms` key handling. Document the metadata accepted by the endpoint with a comment if other keys remain; if no metadata keys remain at all, drop the metadata extraction entirely and stop passing `metadata` into the storage call.

- [ ] **Step 4: Remove from storage helpers**

In `storage.ex` (or wherever the offset metadata key is read on the way back from storage — e.g., when serving audio playback), drop it. The `audio_playback.ex` component touches this; that's covered in Task 13.

- [ ] **Step 5: Update or drop the related test assertions**

In `test/ash_feedback/audio_round_trip_test.exs` find any `audio_start_offset_ms` assertion and remove it (or assert the field is no longer present in metadata if you want a regression guard). Same for `test/ash_feedback/resources/feedback_audio_test.exs` (attribute-shape tests).

- [ ] **Step 6: Run the audio tests, confirm green**

```bash
mix test test/ash_feedback/audio_round_trip_test.exs test/ash_feedback/resources/feedback_audio_test.exs --max-failures 5
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add lib/ash_feedback/controller/audio_uploads_controller.ex lib/ash_feedback/storage.ex test/ash_feedback/audio_round_trip_test.exs test/ash_feedback/resources/feedback_audio_test.exs
git commit -m "refactor(audio): drop audio_start_offset_ms from controller + storage

Server stops accepting and storing the offset key. Schema attribute
+ migration land in the next commit; admin playback simplification
follows."
```

---

## Task 12: Remove `audio_start_offset_ms` attribute + migration

**Files:**
- Modify: `~/Dev/ash_feedback/lib/ash_feedback/resources/feedback.ex`
- Generate: `~/Dev/ash_feedback/priv/repo/migrations/<ts>_drop_audio_start_offset_ms.exs`

- [ ] **Step 1: Remove the attribute from the resource**

In `lib/ash_feedback/resources/feedback.ex` find:

```elixir
attribute :audio_start_offset_ms, :integer, public?: true,
  constraints: [min: 0],
  description: "..."
```

Delete the entire attribute block. Also remove any `accept` lists or action arguments that reference it.

- [ ] **Step 2: Generate the migration**

```bash
cd ~/Dev/ash_feedback
mix ash.codegen drop_audio_start_offset_ms --yes
```

- [ ] **Step 3: Inspect the generated migration**

```bash
ls -t priv/repo/migrations/ | head -1
cat priv/repo/migrations/<ts>_drop_audio_start_offset_ms.exs
```

Expected: a `remove :audio_start_offset_ms` (or `alter table` with `remove`) inside the `change` function. No backfill needed — the column carries no operational value.

- [ ] **Step 4: Run the migration**

```bash
mix ecto.migrate
```

Expected: success. Then verify the column is gone:

```bash
mix ecto.dump
grep audio_start_offset_ms priv/repo/structure.sql || echo "not present"
```

Expected: `not present`.

- [ ] **Step 5: Run the full test suite**

```bash
mix test --max-failures 10
```

Expected: green. If anything still references the attribute, fix in this task.

- [ ] **Step 6: Commit**

```bash
git add lib/ash_feedback/resources/feedback.ex priv/repo/migrations/ priv/repo/structure.sql
git commit -m "refactor(audio): remove audio_start_offset_ms — column drop

Single-clip-per-session model lands the offset removal end-to-end.
Migration drops the column from PostgreSQL. Resource attribute + all
references gone. ADR-0001 supersede note follows."
```

---

## Task 13: Simplify admin audio playback (no offset seek)

**Files:**
- Modify: `~/Dev/ash_feedback/lib/ash_feedback_web/components/audio_playback.ex`
- Modify: `~/Dev/ash_feedback/test/ash_feedback_web/components/audio_playback_test.exs`

- [ ] **Step 1: Find the offset-handling logic in audio_playback**

```bash
grep -n "offset\|currentTime" lib/ash_feedback_web/components/audio_playback.ex
```

Expected: code that reads an offset (from props or audio attrs) and either initializes `<audio>` `data-offset` or programmatically seeks to that offset on play.

- [ ] **Step 2: Run the existing component tests**

```bash
mix test test/ash_feedback_web/components/audio_playback_test.exs --max-failures 5
```

Note any tests that assert on `data-offset`, `currentTime`, or offset-driven behavior.

- [ ] **Step 3: Remove the offset seek logic**

Audio always starts at t=0 alongside rrweb. Remove any:

- `data-offset` HTML attribute emission
- `audio.currentTime = ...` JS hook code (search the file for any inline scripts or imports of `audio_playback.js`)
- Props/assigns named `offset_ms`, `start_offset`, similar

If `audio_playback.js` exists (`grep -rn "audio_playback.js" .`), remove offset seeking from it too.

- [ ] **Step 4: Update / drop the related tests**

In `test/ash_feedback_web/components/audio_playback_test.exs`, drop assertions about offset seek behavior; keep tests that verify the basic `<audio>` rendering.

- [ ] **Step 5: Run tests, confirm green**

```bash
mix test test/ash_feedback_web/components/audio_playback_test.exs --max-failures 5
```

Expected: pass.

- [ ] **Step 6: Smoke admin replay (manual)**

Open a feedback record from the admin index in the demo, play the rrweb replay alongside the audio playback. Confirm:

- Audio plays from t=0 in sync with rrweb t=0.
- No console errors about missing offset properties.

- [ ] **Step 7: Commit**

```bash
git add lib/ash_feedback_web/components/audio_playback.ex test/ash_feedback_web/components/audio_playback_test.exs
# include audio_playback.js if it exists
git commit -m "refactor(audio): admin playback starts at t=0 — drop offset seek

Audio + rrweb now share session-start timestamp; the offset-driven
seek logic is dead. Component renders <audio> at the start of the
timeline; admin player's timeline-bus consumers receive a t=0 audio
start cue."
```

---

## Task 14: Rewrite `audio_recorder.js` — new audioState + idle-start-options

**Files:**
- Rewrite: `~/Dev/ash_feedback/priv/static/assets/audio_recorder.js`
- Create: `~/Dev/ash_feedback/test/js/audio_recorder_test.js`

This is the largest task. Split the rewrite into substeps; commit after each substep so a partial revert is easy.

### Task 14a: Full file rewrite

- [ ] **Step 1: Replace the file with the new structure**

Write the complete new `audio_recorder.js`:

```js
// ash_feedback audio recorder — phoenix_replay panel addon (post-pre-flight).
//
// Four registrations share module-scope state via the singleton below.
// Lifecycle:
//   1. idle-start mounts → idle-start-options addon renders the voice
//      checkbox (initial value from data-audio-default on the widget
//      root) and registers a canStart hook.
//   2. User clicks Start → canStart runs. If voiceEnabled, getUserMedia
//      runs; success caches the stream, failure surfaces inline error.
//   3. Path B :active starts → pill-action mounts. If the cached stream
//      exists, MediaRecorder starts immediately and a passive 🎙
//      indicator renders. Otherwise the slot stays empty.
//   4. Path B :passive (Stop) → pill-action unmounts. Cleanup returns
//      a Promise that resolves after recorder.onstop writes the blob
//      into the singleton.
//   5. REVIEW screen opens → review-media renders <audio controls>
//      from the singleton blob (or nothing if voice was off).
//   6. User clicks Re-record → review closes, panel returns to
//      idle-start. The user can change the toggle.
//   7. User clicks Send → form-top beforeSubmit uploads the blob and
//      clears the singleton.

(function () {
  "use strict";

  var PREPARE_PATH_ATTR = "data-prepare-path";
  var DEFAULT_PREPARE_PATH = "/audio_uploads/prepare";

  var CODECS = [
    { mime: "audio/webm; codecs=opus", ext: "webm" },
    { mime: "audio/mp4; codecs=mp4a.40.2", ext: "mp4" },
  ];

  // Module-scope singleton. Owned by idle-start-options + pill-action,
  // read by review-media + form-top.
  var audioState = {
    voiceEnabled: false,
    blob: null,
    mimeType: null,
    ext: null,
    _pendingStream: null,
  };

  function pickCodec() {
    if (typeof MediaRecorder === "undefined") return null;
    for (var i = 0; i < CODECS.length; i++) {
      if (MediaRecorder.isTypeSupported(CODECS[i].mime)) return CODECS[i];
    }
    return null;
  }

  function csrfToken() {
    var el = document.querySelector("meta[name='csrf-token']");
    return el ? el.getAttribute("content") : null;
  }

  function clearAudioState() {
    audioState.voiceEnabled = false;
    audioState.blob = null;
    audioState.mimeType = null;
    audioState.ext = null;
    if (audioState._pendingStream) {
      try { audioState._pendingStream.getTracks().forEach(function (t) { t.stop(); }); } catch (_) {}
    }
    audioState._pendingStream = null;
  }

  function readWidgetDefault() {
    var widget = document.querySelector("[data-phoenix-replay]");
    if (!widget) return false;
    return widget.getAttribute("data-audio-default") === "on";
  }

  // ---- idle-start-options addon -------------------------------------
  // Renders the voice toggle + registers a canStart hook. The hook
  // calls getUserMedia when the user has opted in; failure surfaces
  // an inline error and blocks Start.
  function mountIdleStartOptions(ctx) {
    var codec = pickCodec();
    audioState.voiceEnabled = readWidgetDefault();

    var wrapper = document.createElement("label");
    wrapper.className = "phx-replay-audio-pre-flight";
    wrapper.style.display = "flex";
    wrapper.style.alignItems = "center";
    wrapper.style.gap = "0.55rem";
    wrapper.style.padding = "0.55rem 0.7rem";
    wrapper.style.borderRadius = "0.4rem";
    wrapper.style.border = "1px solid var(--phx-replay-border, #e2e8f0)";
    wrapper.style.cursor = codec ? "pointer" : "not-allowed";

    var checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.checked = audioState.voiceEnabled && !!codec;
    checkbox.disabled = !codec;
    checkbox.style.margin = "0";

    var label = document.createElement("span");
    label.textContent = codec ? "🎙 Include voice commentary" : "🎙 Voice not supported in this browser";
    label.style.fontSize = "0.82rem";

    wrapper.appendChild(checkbox);
    wrapper.appendChild(label);
    ctx.slotEl.appendChild(wrapper);

    checkbox.addEventListener("change", function () {
      audioState.voiceEnabled = checkbox.checked;
      ctx.panel.clearInlineError("idle-start-options");
      ctx.panel.enableStart();
    });

    var canStartFn = async function () {
      if (!audioState.voiceEnabled) return { ok: true };
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        return { ok: false, error: "This browser does not support microphone capture." };
      }
      try {
        var stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        if (audioState._pendingStream) {
          // Defensive — earlier attempt left a stream cached.
          audioState._pendingStream.getTracks().forEach(function (t) { t.stop(); });
        }
        audioState._pendingStream = stream;
        return { ok: true };
      } catch (err) {
        return {
          ok: false,
          error: "Microphone blocked. Allow it in your browser, or uncheck voice commentary.",
        };
      }
    };

    ctx.panel.registerCanStart("ash-feedback-audio", canStartFn);

    return function cleanup() {
      ctx.panel.unregisterCanStart("ash-feedback-audio");
      if (wrapper && wrapper.parentNode) wrapper.parentNode.removeChild(wrapper);
      // _pendingStream is preserved — pill-action consumes it on the
      // next mount (right after Start succeeds). If the user cancels
      // the panel instead, panel close cleanup stops the stream.
    };
  }

  // ---- pill-action addon --------------------------------------------
  // Auto-records when voiceEnabled + cached stream are present.
  // Cleanup returns a Promise that resolves after onstop writes the
  // blob into the singleton.
  function mountPillAction(ctx) {
    if (!audioState.voiceEnabled || !audioState._pendingStream) {
      return function noopCleanup() {};
    }
    var codec = pickCodec();
    if (!codec) {
      return function noopCleanup() {};
    }

    var stream = audioState._pendingStream;
    audioState._pendingStream = null;
    var recorder = new MediaRecorder(stream, { mimeType: codec.mime });
    var chunks = [];

    recorder.ondataavailable = function (e) {
      if (e.data && e.data.size > 0) chunks.push(e.data);
    };

    var onstopResolve = null;
    var onstopPromise = new Promise(function (resolve) { onstopResolve = resolve; });
    recorder.onstop = function () {
      try {
        audioState.blob = new Blob(chunks, { type: codec.mime });
        audioState.mimeType = codec.mime;
        audioState.ext = codec.ext;
      } finally {
        onstopResolve();
      }
    };
    recorder.start();

    var indicator = document.createElement("span");
    indicator.className = "phx-replay-audio-pill-indicator";
    indicator.title = "Voice commentary on";
    indicator.textContent = "🎙";
    indicator.style.opacity = "0.85";
    indicator.style.fontSize = "0.85rem";
    ctx.slotEl.appendChild(indicator);

    return function cleanup() {
      var stopAndCleanup = (async function () {
        if (recorder && recorder.state !== "inactive") {
          try { recorder.stop(); } catch (_) {}
          await onstopPromise;
        }
        try { stream.getTracks().forEach(function (t) { t.stop(); }); } catch (_) {}
        if (indicator && indicator.parentNode) indicator.parentNode.removeChild(indicator);
      })();
      return stopAndCleanup;
    };
  }

  // ---- review-media addon (unchanged behavior) ----------------------
  function mountReviewMedia(ctx) {
    if (!audioState.blob) return function noop() {};
    var wrapper = document.createElement("div");
    wrapper.className = "phx-replay-audio-review";

    var label = document.createElement("div");
    label.className = "phx-replay-audio-review-label";
    label.textContent = "Voice commentary attached";
    wrapper.appendChild(label);

    var audio = document.createElement("audio");
    audio.controls = true;
    var previewUrl = URL.createObjectURL(audioState.blob);
    audio.src = previewUrl;
    audio.className = "phx-replay-audio-review-player";
    wrapper.appendChild(audio);

    ctx.slotEl.appendChild(wrapper);

    return function cleanup() {
      try { URL.revokeObjectURL(previewUrl); } catch (_) {}
      if (wrapper && wrapper.parentNode) wrapper.parentNode.removeChild(wrapper);
    };
  }

  // ---- form-top addon (no offset metadata) --------------------------
  function mountFormTop(ctx) {
    var preparePath =
      (ctx.slotEl && ctx.slotEl.getAttribute(PREPARE_PATH_ATTR)) ||
      DEFAULT_PREPARE_PATH;

    function beforeSubmit(_args) {
      if (!audioState.blob) return Promise.resolve({});

      var headers = { "content-type": "application/json" };
      var token = csrfToken();
      if (token) headers["x-csrf-token"] = token;

      var prepareBody = {
        filename: "voice-note." + audioState.ext,
        content_type: audioState.mimeType,
        byte_size: audioState.blob.size,
      };

      var capturedMime = audioState.mimeType;
      var capturedBlob = audioState.blob;

      return fetch(preparePath, {
        method: "POST",
        credentials: "same-origin",
        headers: headers,
        body: JSON.stringify(prepareBody),
      })
        .then(function (res) {
          if (!res.ok) throw new Error("Audio prepare failed: HTTP " + res.status);
          return res.json();
        })
        .then(function (info) {
          var url = info.url;
          var method = (info.method || "put").toLowerCase();

          if (method === "post") {
            var fd = new FormData();
            Object.keys(info.fields || {}).forEach(function (k) { fd.append(k, info.fields[k]); });
            fd.append("file", capturedBlob);
            return fetch(url, { method: "POST", body: fd }).then(function (up) {
              if (!up.ok) throw new Error("Audio upload failed: HTTP " + up.status);
              return info.blob_id;
            });
          }

          return fetch(url, {
            method: "PUT",
            body: capturedBlob,
            headers: { "content-type": capturedMime },
          }).then(function (up) {
            if (!up.ok) throw new Error("Audio upload failed: HTTP " + up.status);
            return info.blob_id;
          });
        })
        .then(function (blobId) {
          clearAudioState();
          return { extras: { audio_clip_blob_id: blobId } };
        });
    }

    return { beforeSubmit: beforeSubmit };
  }

  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-options",
        slot: "idle-start-options",
        paths: ["record_and_report"],
        mount: mountIdleStartOptions,
      });
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-mic",
        slot: "pill-action",
        paths: ["record_and_report"],
        mount: mountPillAction,
      });
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-preview",
        slot: "review-media",
        paths: ["record_and_report"],
        mount: mountReviewMedia,
      });
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-submit",
        slot: "form-top",
        paths: ["record_and_report"],
        mount: mountFormTop,
      });
      return true;
    }
    return false;
  }

  if (!tryRegister()) {
    var pollAttempts = 0;
    function pollUntilRegistered() {
      var t = setInterval(function () {
        pollAttempts++;
        if (tryRegister() || pollAttempts > 20) clearInterval(t);
      }, 100);
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () {
        if (!tryRegister()) pollUntilRegistered();
      });
    } else {
      pollUntilRegistered();
    }
  }
})();
```

- [ ] **Step 2: Verify the addon `ctx` provides `panel` access**

The new code uses `ctx.panel.registerCanStart`, `ctx.panel.clearInlineError`, etc. Check that `buildAddonCtx` in phoenix_replay's panel exposes the panel API on ctx. If it doesn't, that's a Phase 1 oversight — go back and add `panel` to the ctx object built by `buildAddonCtx` in `phoenix_replay.js`. Commit that as a Phase 1 follow-up before continuing.

```bash
cd ~/Dev/phoenix_replay
grep -n "function buildAddonCtx" priv/static/assets/phoenix_replay.js
```

If `buildAddonCtx` does not include the panel API, add it:

```js
function buildAddonCtx(slotEl) {
  return {
    slotEl,
    sessionStartedAtMs: () => client._internals.sessionStartedAtMs?.() ?? null,
    panel: {
      registerCanStart, unregisterCanStart,
      showInlineError, clearInlineError,
      disableStart, enableStart,
    },
  };
}
```

Commit + push the phoenix_replay update; bump ash_feedback's lock again.

- [ ] **Step 3: Sync into the demo and exercise voice OFF**

```bash
cd ~/Dev/ash_feedback_demo
cp ~/Dev/ash_feedback/priv/static/assets/audio_recorder.js deps/ash_feedback/priv/static/assets/audio_recorder.js
mix deps.compile ash_feedback --force
```

Restart server. Via Tidewave:

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(async () => {
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  // Don't check the box. Just Start.
  document.querySelector(".phx-replay-start-cta").click();
  await new Promise(r => setTimeout(r, 1500));
  console.log("isRecording:", window.PhoenixReplay.isRecording());
  console.log("pill visible:", !!document.querySelector(".phx-replay-pill"));
  console.log("pill mic indicator:", document.querySelector(".phx-replay-audio-pill-indicator"));
});
```

Expected: `isRecording: true`, `pill visible: true`, `pill mic indicator: null` (no indicator when voice off).

- [ ] **Step 4: Stop and verify review (voice OFF case)**

```js
await browser.eval(async () => {
  document.querySelector(".phx-replay-pill-stop").click();
  await new Promise(r => setTimeout(r, 1500));
  const audio = document.querySelector(".phx-replay-audio-review-player");
  console.log("review audio (should be null for voice OFF):", audio);
});
```

Expected: `audio: null`.

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/ash_feedback
git add priv/static/assets/audio_recorder.js
git commit -m "refactor(audio): rewrite addon for pre-flight model

Single voice toggle on idle-start-options drives the entire
session's audio behavior. mountPillAction auto-records from the
canStart-cached stream; cleanup returns a Promise that resolves
after recorder.onstop. mountReviewMedia + mountFormTop simplify by
dropping offsetMs handling. Voice off path skips MediaRecorder
entirely."
```

### Task 14b: Audio recorder JS unit tests

- [ ] **Step 1: Create `test/js/audio_recorder_test.js`**

Audio recorder tests use a different sandbox shape than phoenix_replay's tests because the addon expects `window.PhoenixReplay` to exist with `registerPanelAddon` available. We can stub it.

```js
// Run with: node test/js/audio_recorder_test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "audio_recorder.js"),
  "utf8"
);

function makeSandbox() {
  // Capture registered addons here for inspection.
  const registered = [];
  const sandbox = {
    document: {
      readyState: "complete",
      addEventListener() {},
      querySelector(sel) {
        if (sel === "[data-phoenix-replay]") return { getAttribute: () => "off" };
        if (sel === "meta[name='csrf-token']") return null;
        return null;
      },
      createElement(tag) {
        return {
          tagName: tag.toUpperCase(),
          style: {},
          appendChild() {},
          addEventListener() {},
          set className(_v) {},
          set textContent(_v) {},
          set type(_v) {},
          set checked(v) { this._checked = v; },
          get checked() { return this._checked; },
          set disabled(v) { this._disabled = v; },
          get disabled() { return this._disabled; },
        };
      },
    },
    window: {
      PhoenixReplay: {
        registerPanelAddon(addon) { registered.push(addon); },
      },
    },
    navigator: { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } },
    MediaRecorder: function () { this.state = "inactive"; this.start = () => { this.state = "recording"; }; this.stop = () => {}; },
    setInterval, clearInterval, setTimeout, clearTimeout, console, Promise, URL: { createObjectURL: () => "blob:test", revokeObjectURL: () => {} },
    Blob: function (parts, opts) { this.parts = parts; this.size = parts.reduce((a, p) => a + (p.length || 0), 0); this.type = (opts || {}).type; },
  };
  sandbox.MediaRecorder.isTypeSupported = () => true;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox);
  return { sandbox, registered };
}

function assert(cond, msg) {
  if (!cond) { console.error("FAIL:", msg); process.exit(1); }
}

(async () => {
  // --- four addons register in the right slots ---
  {
    const { registered } = makeSandbox();
    const slots = registered.map(a => a.slot).sort();
    assert(slots.length === 4, "four addons registered");
    assert(slots.join(",") === "form-top,idle-start-options,pill-action,review-media", "expected slots: " + slots.join(","));
  }

  // --- idle-start-options mount: voice OFF default, registers canStart ---
  {
    const { registered } = makeSandbox();
    const idle = registered.find(a => a.slot === "idle-start-options");
    let registeredCanStart = null;
    const ctx = {
      slotEl: { appendChild() {} },
      panel: {
        registerCanStart: (id, fn) => { registeredCanStart = [id, fn]; },
        unregisterCanStart: () => {},
        clearInlineError: () => {},
        enableStart: () => {},
      },
    };
    const cleanup = idle.mount(ctx);
    assert(typeof cleanup === "function", "idle-start mount returns cleanup function");
    assert(registeredCanStart && registeredCanStart[0] === "ash-feedback-audio", "canStart hook registered");
    // canStart with voiceEnabled=false (default off) should return ok:true without calling getUserMedia
    const result = await registeredCanStart[1]();
    assert(result.ok === true, "canStart with voice OFF returns ok:true");
  }

  console.log("audio_recorder_test: ok");
})();
```

- [ ] **Step 2: Run, expect green**

```bash
cd ~/Dev/ash_feedback
node test/js/audio_recorder_test.js
```

Expected: `audio_recorder_test: ok`.

- [ ] **Step 3: Commit**

```bash
git add test/js/audio_recorder_test.js
git commit -m "test(audio): unit tests for addon registration + canStart hook

CommonJS test (node test/js/audio_recorder_test.js) using vm sandbox
similar to phoenix_replay's ring_buffer_test pattern. Asserts the
four-slot registration shape and the canStart hook contract for the
voice-OFF path. Voice-ON path requires MediaRecorder + getUserMedia
mocking that's better exercised in browser_eval smoke."
```

---

## Task 15: ADR-0001 supersede note

**Files:**
- Modify: `~/Dev/ash_feedback/docs/decisions/0001-audio-narration-via-ash-storage.md`

- [ ] **Step 1: Find the offset-related decision in ADR-0001**

```bash
grep -n "audio_start_offset_ms\|offset" docs/decisions/0001-audio-narration-via-ash-storage.md
```

- [ ] **Step 2: Append a Status update**

At the top of the ADR (or wherever Status is recorded), update:

```markdown
**Status:** Active. The `audio_start_offset_ms` metadata decision (D2)
is **superseded** by the 2026-04-26 audio pre-flight toggle redesign
([spec](../superpowers/specs/2026-04-26-audio-pre-flight-toggle-design.md))
— audio is now session-equivalent and offset is always 0; the column
has been dropped.
```

If the ADR has individual decision sections, mark the offset decision section explicitly as **Superseded**.

- [ ] **Step 3: Commit**

```bash
git add docs/decisions/0001-audio-narration-via-ash-storage.md
git commit -m "docs(adr-0001): mark offset_ms decision superseded by pre-flight redesign"
```

---

## Task 16: Phase 2 push

**Files:**
- (push only)

- [ ] **Step 1: Confirm phase 2 commits**

```bash
cd ~/Dev/ash_feedback
git log --oneline origin/main..HEAD
```

- [ ] **Step 2: Run the full test suite one more time**

```bash
mix test --max-failures 5
node test/js/audio_recorder_test.js
```

Expected: green.

- [ ] **Step 3: Push**

```bash
git push origin main
```

- [ ] **Step 4: Capture the SHA for Phase 3**

```bash
git rev-parse HEAD
```

---

# Phase 3 — Demo bump + manual smoke

All work in `~/Dev/ash_feedback_demo/`.

## Task 17: Bump phoenix_replay + ash_feedback

**Files:**
- Modify: `mix.lock`

- [ ] **Step 1: Update both deps**

```bash
cd ~/Dev/ash_feedback_demo
mix deps.update phoenix_replay ash_feedback
```

- [ ] **Step 2: Verify the new SHAs**

```bash
grep -E "phoenix_replay|ash_feedback" mix.lock | head -4
```

Expected: SHAs match Phase 1 / Phase 2 pushes.

- [ ] **Step 3: Compile**

```bash
mix compile
```

Expected: green.

- [ ] **Step 4: Restart the dev server via Tidewave**

Use `restart_app_server` with reason `deps_changed`.

---

## Task 18: Set `audio_default={:on}` on `/demo/on-demand-float`

**Files:**
- Modify: `lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex`

- [ ] **Step 1: Update the widget call**

Find:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
/>
```

Change to:

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
  audio_default={:on}
/>
```

- [ ] **Step 2: Verify in the browser**

```js
await browser.reload("/demo/on-demand-float");
await browser.eval(() => {
  const widget = document.querySelector("[data-phoenix-replay]");
  console.log("data-audio-default:", widget.getAttribute("data-audio-default"));
});
```

Expected: `on`.

- [ ] **Step 3: Verify the checkbox starts checked**

```js
await browser.eval(() => {
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  const cb = document.querySelector(".phx-replay-screen-options input[type='checkbox']");
  console.log("checkbox checked:", cb && cb.checked);
});
```

Expected: `true`.

- [ ] **Step 4: Commit**

```bash
git add lib/ash_feedback_demo_web/controllers/demo_html/on_demand_float.html.heex
git commit -m "demo: opt /on-demand-float into voice-default-on for smoke flows

Demonstrates the audio_default={:on} widget configuration. Other
demo pages stay on the default :off."
```

---

## Task 19: Manual smoke checklist

**Files:**
- (no file changes — verification only)

- [ ] **Voice OFF path (most common, no permission prompt)**

  1. Open `/demo/on-demand-float`.
  2. Click "Report issue" → "Record and report".
  3. Idle-start opens. **Uncheck** the voice box.
  4. Click "Start recording". Pill appears, no 🎙 indicator.
  5. Interact with the page for ~5 seconds.
  6. Click pill Stop. Review modal opens, rrweb playback renders, NO audio block.
  7. Click Continue → form. Type a description. Click Send.
  8. Confirm submit succeeds (success message).

- [ ] **Voice ON, permission granted**

  1. Reload (clears any cached permission state if you want to retest the prompt).
  2. Click "Report issue" → "Record and report".
  3. Voice box already checked (audio_default=:on).
  4. Click "Start recording". Browser prompts for mic. Click Allow.
  5. Pill appears WITH 🎙 indicator. Speak for 5 seconds.
  6. Click pill Stop. Review modal opens with rrweb playback AND `<audio>` preview.
  7. Click Play on audio — your voice plays back.
  8. Click Continue → form → Send. Confirm success.
  9. Open admin index, find the new feedback row, open it. Audio plays from t=0 in sync with rrweb replay start.

- [ ] **Voice ON, permission denied**

  1. In browser settings, block mic for `localhost:4006` (or use the browser's Site Information panel).
  2. Reload.
  3. Click "Report issue" → "Record and report". Voice box checked.
  4. Click "Start recording". Permission auto-denies.
  5. Idle-start stays open. Red inline error: "Microphone blocked. …". Start button disabled.
  6. **Uncheck the voice box.** Inline error clears, Start re-enables.
  7. Click Start. Records without voice. Stop → review (no audio) → submit.

- [ ] **Re-record returns to idle-start**

  1. Voice ON, permission granted, record a short clip, Stop.
  2. On review, click Re-record.
  3. Confirm: panel returns to idle-start (NOT directly back to the pill).
  4. Voice checkbox still reflects the audio_default. User can change.
  5. Click Start again — fresh recording.

- [ ] **Voice toggle ON → OFF clears stale state**

  1. Voice ON, complete a recording cycle (clip in singleton).
  2. Click Re-record (returns to idle-start).
  3. Uncheck voice. Click Start.
  4. Stop. Review modal opens with NO audio block.
  5. Confirm: previous clip was discarded; voice OFF means no audio in singleton.

- [ ] **No regressions in `/demo/on-demand-headless` or other demo pages**

  Open each demo route. Confirm panel still renders, no console errors. Audio addon should not register on pages where the widget passes `allow_paths=[:report_now]` (Path A only).

---

# Self-Review

**Spec coverage check** (against `2026-04-26-audio-pre-flight-toggle-design.md`):

- D1 idle-start-options slot — Task 1 (markup) + Task 7 (CSS).
- D2 canStart hook — Tasks 4, 5 (registry + Start gate APIs).
- D3 pill-action auto-record — Task 14 (mountPillAction rewrite).
- D4 async cleanup contract — Task 2 (`unmountAddonsForSlot` Promise) + Task 3 (`handleStop` await).
- D5 offset removal — Tasks 10, 11, 12, 13.
- D6 `audio_default` widget attr — Task 6.
- D7 Re-record returns to idle-start — Verified in Task 19 smoke. (Re-record currently calls `startAndSync` directly; need to trace that flow and adjust if it bypasses idle-start. Likely a small change in `handleReRecord`.)

**Re-record flow gap.** The plan sketch for Task 19 covers this manually but no implementation task changes `handleReRecord` to route to idle-start instead of starting immediately. **Action: add a Phase 1 follow-up task** before pushing — see Task 7.5 below.

## Task 7.5 (inserted): `handleReRecord` reopens idle-start

**Files:**
- Modify: `~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js` (`handleReRecord`)

- [ ] **Step 1: Locate**

```bash
grep -n "handleReRecord\|onReRecordClick" priv/static/assets/phoenix_replay.js
```

- [ ] **Step 2: Read the current implementation and update**

Today's `handleReRecord` likely calls `await startAndSync()` directly. Replace it with:

```js
async function handleReRecord() {
  // ADR-0006 + 2026-04-26 audio redesign: Re-record returns the user
  // to idle-start so any pre-flight options (voice toggle, etc.) can
  // be reconsidered. The user clicks Start again to re-enter :active.
  panel.openStart();
}
```

`panel.openStart` already exists (it's the choose-card handler for "Record and report"). Confirm it sets the screen to IDLE_START and shows the modal.

- [ ] **Step 3: Smoke**

```js
await browser.eval(async () => {
  // assume voice OFF, complete a cycle to review
  document.querySelector(".phx-replay-toggle").click();
  document.querySelector(".phx-replay-choose-record").click();
  document.querySelector(".phx-replay-start-cta").click();
  await new Promise(r => setTimeout(r, 800));
  document.querySelector(".phx-replay-pill-stop").click();
  await new Promise(r => setTimeout(r, 1000));
  // now on review
  document.querySelector(".phx-replay-rerecord").click();
  await new Promise(r => setTimeout(r, 300));
  const idle = document.querySelector(".phx-replay-screen--idle-start");
  console.log("on idle-start after Re-record:", idle && !idle.hidden);
});
```

Expected: `true`.

- [ ] **Step 4: Commit (insert in Phase 1 ordering, before Task 8 push)**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(panel): Re-record returns to idle-start, not :active

Pre-flight options (e.g. voice toggle) may need re-confirmation
between recording attempts. Re-record now reopens the start screen
instead of jumping straight to a fresh :active session."
```

---

**Placeholder scan:** No TBDs, TODOs, or vague directives remain. All test code, command lines, and edit instructions are concrete.

**Type consistency check:** Method names — `registerCanStart` / `unregisterCanStart` / `showInlineError` / `clearInlineError` / `disableStart` / `enableStart` — used consistently across phoenix_replay (definitions) and audio_recorder.js (consumers). audioState shape: `voiceEnabled, blob, mimeType, ext, _pendingStream` — used consistently.

---

# Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-26-audio-pre-flight-toggle.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch execution with checkpoints.

Which approach?

# ash_feedback Audio Addon — Pill + Review Slot Relocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the ash_feedback audio addon from the legacy single-mount on `slot: "form-top"` (mic-records-after-rrweb model) to a three-mount architecture across `slot: "pill-action"` (in-flight mic toggle), `slot: "review-media"` (in-modal preview), and `slot: "form-top"` (the upload-on-Send hook). Adopt the canonical `paths: [:record_and_report]` filter, dropping the legacy `modes: ["on_demand"]`.

**Architecture:** A page-scoped audio state singleton (`currentAudioBlob`, `currentOffsetMs`, `currentMimeType`) lives in module scope and is owned by the pill-action mount. The pill-action mount renders the mic toggle button INSIDE the recording pill while a Path B session is active; clicking it captures audio via MediaRecorder and writes the result into the singleton. The review-media mount renders a `<audio controls src="blob:...">` element from the singleton blob (skipping render entirely when the singleton is empty). The form-top mount stays minimal — it returns the legacy `{beforeSubmit}` hook that reads from the singleton at Send time, runs the existing AshStorage `prepare → PUT/POST → blob_id` flow, and clears the singleton on success. Each fresh pill-action mount (= each fresh `:active` session) clears the singleton, so Re-record naturally resets.

**Tech Stack:** Vanilla ES2020 (existing IIFE pattern). MediaRecorder Web API for audio capture. `URL.createObjectURL` for in-modal preview. Existing AshStorage upload endpoint (`/audio_uploads/prepare`) is unchanged. No new dependencies.

---

## Phase 3 baseline (do not re-implement)

phoenix_replay Phase 3 shipped on `main` (`7bba996..13227d3`) with the new slot lifecycle and `paths:` filter. Verify in `~/Dev/ash_feedback_demo/deps/phoenix_replay/`:

- `priv/static/assets/phoenix_replay.js` exposes:
  - `data-slot="pill-action"` div inside the rendered pill (Phase 3 Task 2).
  - `data-slot="review-media"` div inside the REVIEW screen (Phase 3 Task 3).
  - `registerPanelAddon({id, slot, mount, paths, modes})` — `paths` is the canonical filter, `modes` retained for one phase.
  - Addon mount return shape: function (cleanup) | object `{beforeSubmit, onPanelClose}` (legacy) | nothing.
  - `panel.close()` only unmounts panel-scoped slots (`review-media`); pill-action lifecycle is owned by `syncRecordingUI`.

If `git -C ~/Dev/phoenix_replay log --oneline | grep "Phase 3"` shows the Phase 3 commits AND `~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js` includes the line `data-slot="pill-action"`, you're set. If the demo's deps copy is stale, run `cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js ~/Dev/ash_feedback_demo/deps/phoenix_replay/priv/static/assets/phoenix_replay.js && cd ~/Dev/ash_feedback_demo && mix deps.compile phoenix_replay --force` first.

---

## File structure

| Path | Responsibility | Why |
|---|---|---|
| `priv/static/assets/audio_recorder.js` | The IIFE addon — refactored from one-addon-with-form-top-mount into three-addon registrations sharing module-scope state. | Single-file vanilla JS per project convention (matches the existing structure). |
| `priv/static/assets/audio_recorder.css` | Styling adjustments for the smaller pill-mounted mic button + the in-modal preview player. | Existing CSS file; minimal edits. |
| `CHANGELOG.md` | Entry under `[Unreleased]` documenting the migration + the `paths:` filter rename + the new mount surfaces. | Existing changelog. |

No new files. The Elixir side (Feedback resource, AttachBlob change, controller, prepare endpoint) is unchanged — the wire format from the addon's `beforeSubmit` is preserved exactly: `extras: { audio_clip_blob_id: ... }` with `audio_start_offset_ms` riding on the blob's metadata at prepare time.

The companion changes in `~/Dev/ash_feedback_demo` are limited to a deps refresh — no demo-page edits needed because the demo already mounts ash_feedback's audio_recorder.js at the bottom of the root layout.

---

## Self-Review After Plan Authoring

Run the Self-Review at the end of this document before handing off.

---

## Task 1: Refactor — module-scope audio state singleton

**Files:**
- Modify: `priv/static/assets/audio_recorder.js`

This task introduces the page-scoped state that the three addon mounts share. No addon registration changes yet — Tasks 2-4 wire the new mounts.

- [ ] **Step 1: Replace the `buildAddon()` function with a new shape**

The current file structure (line 13-358) wraps everything in a single IIFE that calls `buildAddon()` at register time. The function returns one addon descriptor with `slot: "form-top"` and a giant `mount` body that handles the entire mic UI + recording + upload flow.

We're going to keep the IIFE wrapper but restructure the body. Open `/Users/johndev/Dev/ash_feedback/priv/static/assets/audio_recorder.js` and replace the entire file with:

```javascript
// ash_feedback audio recorder — phoenix_replay panel addon (Phase 3+).
//
// Three addon registrations share module-scope state via the singleton
// pattern below. Lifecycle:
//   1. Path B starts → pill-action mount runs → clears singleton state
//      → renders the mic toggle inside the recording pill.
//   2. User clicks mic → MediaRecorder captures audio. Click again to
//      stop. The captured blob + start-offset are written into the
//      singleton.
//   3. Path B stops → pill-action UNMOUNTS (cleanup releases
//      MediaRecorder + stream; blob STAYS in singleton).
//   4. REVIEW screen opens → review-media mount renders an <audio>
//      preview from the singleton blob (or nothing if empty).
//   5. User clicks Continue OR Re-record → review-media unmounts
//      (cleanup revokes the blob URL; blob STAYS in singleton).
//   6. Re-record → pill-action remounts → CLEARS singleton → fresh
//      recording (the previous blob is dropped).
//   7. Continue → describe step opens → Send → form-top's
//      beforeSubmit reads the singleton, uploads, clears.
//
// Path A widgets: pill-action and review-media never mount (paths
// filter excludes :report_now). form-top mounts but its beforeSubmit
// reads the empty singleton and returns {} (no audio extras).

(function () {
  "use strict";

  var PREPARE_PATH_ATTR = "data-prepare-path";
  var MAX_SECONDS_ATTR = "data-audio-max-seconds";
  var DEFAULT_PREPARE_PATH = "/audio_uploads/prepare";
  var DEFAULT_MAX_SECONDS = 300;

  var CODECS = [
    { mime: "audio/webm; codecs=opus", ext: "webm" },
    { mime: "audio/mp4; codecs=mp4a.40.2", ext: "mp4" },
  ];

  // Module-scope state singleton. Owned by the pill-action mount;
  // read by review-media mount and form-top beforeSubmit.
  var audioState = {
    blob: null,
    offsetMs: null,
    mimeType: null,
    ext: null,
  };

  function pickCodec() {
    if (typeof MediaRecorder === "undefined") return null;
    for (var i = 0; i < CODECS.length; i++) {
      if (MediaRecorder.isTypeSupported(CODECS[i].mime)) return CODECS[i];
    }
    return null;
  }

  function fmtDuration(ms) {
    var total = Math.floor(ms / 1000);
    var m = Math.floor(total / 60);
    var s = total % 60;
    return m + ":" + String(s).padStart(2, "0");
  }

  function csrfToken() {
    var el = document.querySelector("meta[name='csrf-token']");
    return el ? el.getAttribute("content") : null;
  }

  function clearAudioState() {
    audioState.blob = null;
    audioState.offsetMs = null;
    audioState.mimeType = null;
    audioState.ext = null;
  }

  // ---- pill-action addon (Task 2) -----------------------------------
  // mountPillAction(ctx) — placeholder, lands in Task 2.

  // ---- review-media addon (Task 3) ----------------------------------
  // mountReviewMedia(ctx) — placeholder, lands in Task 3.

  // ---- form-top addon (Task 4) --------------------------------------
  // mountFormTop(ctx) — placeholder, lands in Task 4.

  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
      // Three registrations land in Tasks 2-4. Until then the file
      // compiles and registers nothing — this is intentional during
      // the migration's intermediate state.
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

This is intentionally a SCAFFOLD — the actual three addon mounts land in Tasks 2-4. The intermediate state is "no audio addon registered, no audio capture happens." Task 8's smoke matrix exercises the empty intermediate to confirm Path B without audio still works.

- [ ] **Step 2: Verify the file parses cleanly**

```
cd /Users/johndev/Dev/ash_feedback && node --check priv/static/assets/audio_recorder.js
```

Expected: exit 0, no output.

- [ ] **Step 3: Run mix test (Elixir suite shouldn't be affected)**

```
cd /Users/johndev/Dev/ash_feedback && mix test
```

Expected: all green. The Elixir-side audio integration tests exercise the resource + controller layer; the JS scaffold doesn't run during ExUnit.

- [ ] **Step 4: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add priv/static/assets/audio_recorder.js && git commit -m "$(cat <<'EOF'
refactor(audio): scaffold module-scope state singleton; drop legacy single-addon

Phase 3 migration prep. Replace the single addon-with-form-top-mount
shape with a scaffold that hosts three mount placeholders sharing
module-scope state (audioState = { blob, offsetMs, mimeType, ext }).
Tasks 2-4 land the actual pill-action, review-media, and form-top
mounts.

The intermediate state is "no audio addon registered" — Path B
without audio works as before; Path B with audio is unavailable
until Task 4 wires beforeSubmit. CHANGELOG covers this in Task 9.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: pill-action mount — mic toggle + MediaRecorder

**Files:**
- Modify: `priv/static/assets/audio_recorder.js`

The pill-action mount runs when the recording pill becomes visible (Path B `:active` state). It:
1. Clears `audioState` (a fresh `:active` session = a fresh recording slot).
2. Renders a mic toggle button inside `ctx.slotEl` (the pill-action slot).
3. On first click: `getUserMedia` → MediaRecorder.start → button switches to "Stop · 0:12" with elapsed time. `audioState.offsetMs` captured at MediaRecorder start, relative to `ctx.sessionStartedAtMs()`.
4. On second click: `MediaRecorder.stop` → blob assembled into `audioState.blob`. Button switches back to "Add voice commentary" so the user can re-record within the same session.
5. The cleanup function (returned from mount) releases MediaRecorder + stream + tick timer when pill disappears (Stop). It does NOT clear `audioState.blob` — REVIEW needs it.

- [ ] **Step 1: Replace the `// mountPillAction (Task 2)` placeholder**

In `/Users/johndev/Dev/ash_feedback/priv/static/assets/audio_recorder.js`, find the line:

```javascript
  // ---- pill-action addon (Task 2) -----------------------------------
  // mountPillAction(ctx) — placeholder, lands in Task 2.
```

Replace with:

```javascript
  // ---- pill-action addon (Task 2) -----------------------------------
  // Renders the mic toggle inside the recording pill while a Path B
  // session is :active. Owns the audioState singleton lifecycle:
  //   - mount: clear state (each fresh :active = fresh recording slot).
  //   - mic toggle on/off: capture audio via MediaRecorder, write blob
  //     into singleton on stop.
  //   - cleanup: release MediaRecorder + stream + timer, but PRESERVE
  //     audioState.blob so review-media can preview it.
  function mountPillAction(ctx) {
    var codec = pickCodec();

    // Clear the singleton — each pill-action mount = fresh active
    // session = the previous blob (if any) is stale.
    clearAudioState();

    // Per-mount state; the closure-captured cleanup stops these on
    // pill unmount (Stop, panel close, Re-record).
    var state = codec ? "idle" : "unsupported";
    var mediaStream = null;
    var recorder = null;
    var chunks = [];
    var startedAtMs = null;
    var timerHandle = null;

    var wrapper = document.createElement("div");
    wrapper.className = "phx-replay-audio-pill-action";
    ctx.slotEl.appendChild(wrapper);

    function render() {
      wrapper.innerHTML = "";

      if (state === "unsupported") {
        var unsup = document.createElement("button");
        unsup.type = "button";
        unsup.className = "phx-replay-audio-pill-mic";
        unsup.disabled = true;
        unsup.title = "Audio recording not supported in this browser";
        unsup.textContent = "🎙";
        wrapper.appendChild(unsup);
        return;
      }

      if (state === "denied") {
        var notice = document.createElement("span");
        notice.className = "phx-replay-audio-notice";
        notice.textContent = "Mic blocked";
        wrapper.appendChild(notice);
        return;
      }

      if (state === "idle") {
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "phx-replay-audio-pill-mic";
        btn.title = "Add voice commentary";
        btn.textContent = audioState.blob ? "🎙✓" : "🎙";
        btn.addEventListener("click", function () {
          startRecording();
        });
        wrapper.appendChild(btn);
        return;
      }

      if (state === "recording") {
        var elapsed = Date.now() - startedAtMs;
        var stop = document.createElement("button");
        stop.type = "button";
        stop.className = "phx-replay-audio-pill-stop-mic";
        stop.textContent = "■ " + fmtDuration(elapsed);
        stop.addEventListener("click", function () {
          stopRecording();
        });
        wrapper.appendChild(stop);
        return;
      }
    }

    function tick() {
      if (state !== "recording") return;
      render();
      timerHandle = window.setTimeout(tick, 250);
    }

    function startRecording() {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        state = "unsupported";
        render();
        return;
      }

      navigator.mediaDevices
        .getUserMedia({ audio: true })
        .then(function (stream) {
          mediaStream = stream;
          chunks = [];

          recorder = new MediaRecorder(mediaStream, { mimeType: codec.mime });
          recorder.ondataavailable = function (e) {
            if (e.data && e.data.size > 0) chunks.push(e.data);
          };
          recorder.onstop = function () {
            // Write blob into the module singleton.
            audioState.blob = new Blob(chunks, { type: codec.mime });
            audioState.mimeType = codec.mime;
            audioState.ext = codec.ext;
            // offsetMs was captured at start; preserve unless null.
            if (mediaStream) {
              mediaStream.getTracks().forEach(function (t) {
                t.stop();
              });
            }
            mediaStream = null;
            state = "idle";  // back to idle so the user can re-record
                              // within this :active session if they want.
            render();
          };
          recorder.start();

          startedAtMs = Date.now();
          var sessionStarted =
            typeof ctx.sessionStartedAtMs === "function"
              ? ctx.sessionStartedAtMs()
              : null;
          audioState.offsetMs = sessionStarted
            ? Math.max(0, startedAtMs - sessionStarted)
            : 0;

          state = "recording";
          render();
          tick();
        })
        .catch(function () {
          state = "denied";
          render();
        });
    }

    function stopRecording() {
      if (timerHandle) {
        window.clearTimeout(timerHandle);
        timerHandle = null;
      }
      if (recorder && recorder.state !== "inactive") {
        recorder.stop();
      }
    }

    render();

    // Phase 3 canonical cleanup: returned function runs when the
    // pill-action slot's host (the pill) goes hidden (Stop, panel
    // close, Re-record). Releases the recorder/stream/timer but
    // PRESERVES audioState.blob — review-media reads it next.
    return function cleanup() {
      if (timerHandle) {
        window.clearTimeout(timerHandle);
        timerHandle = null;
      }
      if (recorder && recorder.state !== "inactive") {
        try { recorder.stop(); } catch (_) {}
      }
      if (mediaStream) {
        mediaStream.getTracks().forEach(function (t) {
          t.stop();
        });
        mediaStream = null;
      }
      if (wrapper && wrapper.parentNode) {
        wrapper.parentNode.removeChild(wrapper);
      }
      // audioState is intentionally NOT cleared here — review-media
      // (Task 3) reads it next. Cleared on next pill-action mount.
    };
  }
```

- [ ] **Step 2: Add the registration call inside `tryRegister`**

Find the `tryRegister` function (around line ~140 of the new file). The current shape:

```javascript
  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
      // Three registrations land in Tasks 2-4. Until then the file
      // compiles and registers nothing — this is intentional during
      // the migration's intermediate state.
      return true;
    }
    return false;
  }
```

Replace with:

```javascript
  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-mic",
        slot: "pill-action",
        paths: ["record_and_report"],
        mount: mountPillAction,
      });
      // review-media + form-top registrations land in Tasks 3-4.
      return true;
    }
    return false;
  }
```

- [ ] **Step 3: Verify**

```
cd /Users/johndev/Dev/ash_feedback && node --check priv/static/assets/audio_recorder.js
cd /Users/johndev/Dev/ash_feedback && mix test
```

Both green.

- [ ] **Step 4: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add priv/static/assets/audio_recorder.js && git commit -m "$(cat <<'EOF'
feat(audio): pill-action mount — mic toggle inside the recording pill

Phase 3 migration Task 2: register the audio mic addon on the new
pill-action slot with paths: ["record_and_report"]. The mount renders
a mic toggle inside the pill while a :active session runs; clicking
it captures audio via MediaRecorder. On Stop, the blob lands in the
audioState module singleton for review-media (Task 3) to preview and
form-top (Task 4) to upload.

Each fresh pill-action mount clears audioState — Re-record naturally
resets the audio slot. The cleanup function returned from mount
releases recorder/stream/timer on pill disappear (Stop, panel close,
Re-record) but preserves audioState.blob for downstream consumers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: review-media mount — in-modal audio preview

**Files:**
- Modify: `priv/static/assets/audio_recorder.js`

The review-media mount runs when the REVIEW screen becomes visible (Stop fires → `panel.openReview`). It renders a plain `<audio controls src="blob:...">` from `audioState.blob` so the user can preview their recording before clicking Continue. If `audioState.blob` is null (user didn't record), the mount renders nothing — review-media is empty.

The cleanup revokes the blob URL (`URL.revokeObjectURL`) but does NOT clear `audioState.blob` — Continue should preserve the blob for upload.

**Note: timeline-bus sync deferred.** The companion spec D2 mentions subscribing to `phoenix_replay:timeline` for sync with the mini rrweb-player. That bus is currently admin-only (ADR-0005 Phase 2 — `PhoenixReplayAdmin.subscribeTimeline`). User-side review uses the embedded mini-player which doesn't expose the bus; wiring it would expand scope. This task ships the unsynced preview; sync is a follow-up addendum if needed.

- [ ] **Step 1: Replace the `// mountReviewMedia (Task 3)` placeholder**

In `/Users/johndev/Dev/ash_feedback/priv/static/assets/audio_recorder.js`, find:

```javascript
  // ---- review-media addon (Task 3) ----------------------------------
  // mountReviewMedia(ctx) — placeholder, lands in Task 3.
```

Replace with:

```javascript
  // ---- review-media addon (Task 3) ----------------------------------
  // Renders an <audio controls> preview inside the REVIEW screen so
  // the user can hear their just-recorded narration before Send.
  // No-op when audioState.blob is null (Path B without mic toggle).
  //
  // Timeline-bus sync with the mini rrweb-player is deferred — this
  // ships a plain audio control. Companion spec D2 mentions sync as
  // a future enhancement; user-side timeline bus is out of scope.
  function mountReviewMedia(ctx) {
    if (!audioState.blob) {
      // Nothing to preview. Still return a (no-op) cleanup so the
      // lifecycle bookkeeping stays consistent.
      return function noopCleanup() {};
    }

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
      // Revoke the URL but PRESERVE audioState.blob — Continue
      // advances to the describe step which still needs the blob
      // at Send time. Re-record's discard happens via the next
      // pill-action mount's clearAudioState call.
      try { URL.revokeObjectURL(previewUrl); } catch (_) {}
      if (wrapper && wrapper.parentNode) {
        wrapper.parentNode.removeChild(wrapper);
      }
    };
  }
```

- [ ] **Step 2: Add the registration**

In `tryRegister`, after the pill-action registration, add:

```javascript
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-preview",
        slot: "review-media",
        paths: ["record_and_report"],
        mount: mountReviewMedia,
      });
```

The full `tryRegister` body now reads:

```javascript
  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
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
      // form-top registration lands in Task 4.
      return true;
    }
    return false;
  }
```

- [ ] **Step 3: Verify**

```
cd /Users/johndev/Dev/ash_feedback && node --check priv/static/assets/audio_recorder.js
cd /Users/johndev/Dev/ash_feedback && mix test
```

Both green.

- [ ] **Step 4: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add priv/static/assets/audio_recorder.js && git commit -m "$(cat <<'EOF'
feat(audio): review-media mount — in-modal audio preview

Phase 3 migration Task 3: register the audio preview addon on the
new review-media slot. The mount reads audioState.blob (set by Task
2's pill-action mount) and renders a plain <audio controls> with
URL.createObjectURL for in-modal playback. No-op when audioState
is empty (Path B without mic toggle).

Cleanup revokes the blob URL on REVIEW screen leave (Continue,
Re-record, panel close) but PRESERVES audioState.blob — Continue
advances to the describe step which still needs the blob at Send.
Re-record's discard fires via the next pill-action mount's
clearAudioState call.

Timeline-bus sync with the mini rrweb-player is deferred — the
user-side timeline bus surface isn't exposed yet; the companion
spec D2 mentions this as a future enhancement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: form-top mount — beforeSubmit upload hook

**Files:**
- Modify: `priv/static/assets/audio_recorder.js`

The form-top mount runs ONCE at panel construction (panel-scoped, Phase 3 lifecycle) and registers a `beforeSubmit` hook via the legacy `{beforeSubmit}` return shape. The hook reads `audioState.blob` at Send time and runs the existing prepare → PUT/POST → blob_id flow. On success it returns `{extras: {audio_clip_blob_id: ...}}` to the orchestrator and clears `audioState`.

When `audioState.blob` is null (Path A submit, or Path B without mic), `beforeSubmit` returns `{}` — no audio extras, no upload network calls. This makes the addon zero-cost on text-only submits.

- [ ] **Step 1: Replace the `// mountFormTop (Task 4)` placeholder**

In `/Users/johndev/Dev/ash_feedback/priv/static/assets/audio_recorder.js`, find:

```javascript
  // ---- form-top addon (Task 4) --------------------------------------
  // mountFormTop(ctx) — placeholder, lands in Task 4.
```

Replace with:

```javascript
  // ---- form-top addon (Task 4) --------------------------------------
  // Mounts ONCE at panel construction (form-top is panel-scoped).
  // Renders nothing visible — its only job is to register the
  // beforeSubmit hook that runs at Send time.
  //
  // beforeSubmit reads audioState.blob (populated by Task 2's
  // pill-action mount) and runs the existing prepare → PUT/POST →
  // blob_id flow against the AshStorage upload endpoint. On success,
  // the singleton is cleared so the next Path B session starts fresh.
  // When audioState.blob is null (Path A submit, Path B without mic),
  // beforeSubmit returns {} — zero network, zero extras.
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

      // D2-revised (Phase 2): offset rides on blob metadata at prepare
      // time. The submit-side wire format only carries the blob id
      // under `extras`.
      if (typeof audioState.offsetMs === "number") {
        prepareBody.metadata = { audio_start_offset_ms: audioState.offsetMs };
      }

      var capturedMime = audioState.mimeType;
      var capturedBlob = audioState.blob;

      return fetch(preparePath, {
        method: "POST",
        credentials: "same-origin",
        headers: headers,
        body: JSON.stringify(prepareBody),
      })
        .then(function (res) {
          if (!res.ok) {
            throw new Error("Audio prepare failed: HTTP " + res.status);
          }
          return res.json();
        })
        .then(function (info) {
          var url = info.url;
          var method = (info.method || "put").toLowerCase();

          if (method === "post") {
            var fd = new FormData();
            Object.keys(info.fields || {}).forEach(function (k) {
              fd.append(k, info.fields[k]);
            });
            fd.append("file", capturedBlob);
            return fetch(url, { method: "POST", body: fd }).then(
              function (up) {
                if (!up.ok) {
                  throw new Error("Audio upload failed: HTTP " + up.status);
                }
                return info.blob_id;
              }
            );
          }

          return fetch(url, {
            method: "PUT",
            body: capturedBlob,
            headers: { "content-type": capturedMime },
          }).then(function (up) {
            if (!up.ok) {
              throw new Error("Audio upload failed: HTTP " + up.status);
            }
            return info.blob_id;
          });
        })
        .then(function (blobId) {
          // Clear singleton after successful upload — next Path B
          // session starts fresh.
          clearAudioState();
          return { extras: { audio_clip_blob_id: blobId } };
        });
    }

    // Legacy return shape — phoenix_replay's panel orchestrator pushes
    // {beforeSubmit} entries into addonHooks for the form-submit path.
    // No DOM render needed; form-top stays empty.
    return { beforeSubmit: beforeSubmit };
  }
```

- [ ] **Step 2: Add the registration**

In `tryRegister`, append:

```javascript
      window.PhoenixReplay.registerPanelAddon({
        id: "ash-feedback-audio-submit",
        slot: "form-top",
        paths: ["record_and_report"],
        mount: mountFormTop,
      });
```

The complete `tryRegister` body:

```javascript
  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
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
```

- [ ] **Step 3: Verify**

```
cd /Users/johndev/Dev/ash_feedback && node --check priv/static/assets/audio_recorder.js
cd /Users/johndev/Dev/ash_feedback && mix test
```

Both green.

- [ ] **Step 4: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add priv/static/assets/audio_recorder.js && git commit -m "$(cat <<'EOF'
feat(audio): form-top mount — beforeSubmit upload hook

Phase 3 migration Task 4: register the audio upload addon on form-top
(panel-scoped, mounts once at panel construction). The mount renders
nothing visible — its only job is to register a beforeSubmit hook.

beforeSubmit reads audioState.blob at Send time. When the singleton
is empty (Path A submit, Path B without mic) it returns {} —
zero network. When set, it runs the existing prepare → PUT/POST →
blob_id flow against /audio_uploads/prepare and returns
{extras: {audio_clip_blob_id: ...}}. The singleton is cleared on
successful upload so the next Path B session starts fresh.

The legacy {beforeSubmit} return shape stays — phoenix_replay's
panel orchestrator pushes these entries into addonHooks for the
form-submit path. The new function-return cleanup contract is used
by pill-action and review-media (Tasks 2 + 3) where the slot
lifecycle is non-trivial.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: CSS — pill mic styling + review preview

**Files:**
- Modify: `priv/static/assets/audio_recorder.css`

The mic button now lives in the pill (compact) and the preview lives in the modal (larger). Replace the form-top-era CSS with new selectors. Keep the existing `.phx-replay-audio-notice` and `.phx-replay-audio-warn` classes since they still apply (denied/unsupported states render those).

- [ ] **Step 1: Replace the file**

Open `/Users/johndev/Dev/ash_feedback/priv/static/assets/audio_recorder.css` and replace the entire contents with:

```css
/* ash_feedback audio addon — Phase 3 styling.
 *
 * Three mount surfaces:
 *   - .phx-replay-audio-pill-action — inside the recording pill
 *     (Task 2). Compact mic toggle.
 *   - .phx-replay-audio-review — inside the REVIEW screen (Task 3).
 *     Plain <audio controls> with a label.
 *   - form-top is invisible (Task 4 renders nothing).
 */

/* --- pill-action (Phase 3 Task 2) ----------------------------------- */

.phx-replay-audio-pill-action {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
}

.phx-replay-audio-pill-mic,
.phx-replay-audio-pill-stop-mic {
  font: inherit;
  font-size: 0.75rem;
  padding: 0.25rem 0.5rem;
  border: 1px solid var(--phx-replay-border, #e2e8f0);
  border-radius: 9999px;
  background: var(--phx-replay-surface, #fff);
  color: var(--phx-replay-text, #0f172a);
  cursor: pointer;
}

.phx-replay-audio-pill-mic:hover,
.phx-replay-audio-pill-stop-mic:hover {
  border-color: var(--phx-replay-primary, #4f46e5);
}

.phx-replay-audio-pill-mic[disabled] {
  opacity: 0.5;
  cursor: not-allowed;
}

.phx-replay-audio-pill-stop-mic {
  /* Recording-state pill mic uses a faint red tint to match the
   * existing pill dot animation (visual continuity with phoenix_replay's
   * pill design). */
  border-color: #ef4444;
  color: #ef4444;
}

/* --- review-media (Phase 3 Task 3) ---------------------------------- */

.phx-replay-audio-review {
  display: flex;
  flex-direction: column;
  gap: 0.375rem;
  padding: 0.5rem 0.625rem;
  background: var(--phx-replay-surface-muted, #f8fafc);
  border: 1px solid var(--phx-replay-border, #e2e8f0);
  border-radius: 0.5rem;
}

.phx-replay-audio-review-label {
  font-size: 0.8125rem;
  color: var(--phx-replay-text-muted, #64748b);
}

.phx-replay-audio-review-player {
  width: 100%;
  height: 36px;
}

/* --- shared denial / unsupported states ----------------------------- */

.phx-replay-audio-notice {
  font-size: 0.75rem;
  color: var(--phx-replay-text-muted, #64748b);
}

.phx-replay-audio-warn {
  color: #c33;
  font-size: 0.75em;
}
```

- [ ] **Step 2: Verify the CSS file is valid (no syntax check tool, just confirm it's text)**

```
cd /Users/johndev/Dev/ash_feedback && wc -l priv/static/assets/audio_recorder.css
```

Expected: a non-zero line count (~50-60 lines).

- [ ] **Step 3: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add priv/static/assets/audio_recorder.css && git commit -m "$(cat <<'EOF'
style(audio): replace form-top CSS with pill-action + review-media

Phase 3 migration Task 5: replace the form-top-era audio styling
with selectors matching the new three-mount architecture.

- .phx-replay-audio-pill-action / -pill-mic / -pill-stop-mic —
  compact mic toggle inside the recording pill, sized to fit
  alongside the pill's existing dot/label/time/Stop elements.
- .phx-replay-audio-review / -review-label / -review-player —
  in-modal audio preview with a "Voice commentary attached" label
  above a full-width <audio controls>.
- Shared .phx-replay-audio-notice / .phx-replay-audio-warn classes
  remain for denied/unsupported states.

Inherits phoenix_replay's CSS custom properties
(--phx-replay-{primary,surface,...}) so host theming applies.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Cross-repo deps refresh + smoke matrix

**Files:**
- Touch: `~/Dev/ash_feedback_demo/deps/ash_feedback/...` (cp from canonical)

After Tasks 1-5 land in canonical, sync into demo for browser smoke. The demo's audio addon is loaded via `<script src={~p"/assets/ash_feedback/audio_recorder.js"}>` in the root layout (already in place — no demo-side edits).

- [ ] **Step 1: Sync canonical edits into demo deps**

```bash
cp ~/Dev/ash_feedback/priv/static/assets/audio_recorder.js \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/priv/static/assets/audio_recorder.js
cp ~/Dev/ash_feedback/priv/static/assets/audio_recorder.css \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/priv/static/assets/audio_recorder.css
cd ~/Dev/ash_feedback_demo && mix deps.compile ash_feedback --force
```

Then restart via Tidewave with `reason: "deps_changed"`.

- [ ] **Step 2: Smoke matrix — browser at http://localhost:4006**

Open Chrome DevTools (Network + Console). Walk this 7-row matrix.

| # | Page | Action | Expected |
|---|---|---|---|
| 1 | `/demo/continuous` | Mount page | DevTools Network shows audio_recorder.js loaded. Console: no warnings about missing PhoenixReplay namespace. |
| 2 | Same | Open panel → Record and report | Pill appears. The pill's `[data-slot="pill-action"]` div now contains a 🎙 mic toggle button (Phase 3 Task 2's slot lifecycle invokes mountPillAction). |
| 3 | Same | Click 🎙 mic → permit microphone → wait 5s → click ■ to stop | Mic button switches to "■ 0:0X" with elapsed seconds during recording, then back to 🎙✓ after stop (✓ indicates a blob was captured). No network calls fire (upload is at Send). |
| 4 | Same | Click pill Stop → REVIEW screen opens | The review's `[data-slot="review-media"]` div renders an `<audio controls>` element with a "Voice commentary attached" label. Click play — the audio plays back. |
| 5 | Same | Click Re-record → record again WITHOUT pressing mic → Stop → REVIEW | The review-media slot is EMPTY (no `<audio>` element) because Re-record's pill-action remount cleared audioState.blob. |
| 6 | Same | Click Continue → describe step → type text → Send | Network shows `POST /audio_uploads/prepare` is **NOT** fired (no audio captured this round). Single POST `/submit` with no `audio_clip_blob_id` in extras. Admin row appears, no audio attachment. |
| 7 | Repeat with mic | Record + mic + Stop → REVIEW shows audio → Continue → describe + Send | Network shows `/audio_uploads/prepare` POST → presigned PUT → `/submit` 201. Admin row's metadata reflects `audio_clip_blob_id` and the blob's metadata carries `audio_start_offset_ms`. |

If row 2 fails (no mic toggle in pill), the addon's pill-action registration didn't fire. Check `window.PhoenixReplay && typeof window.PhoenixReplay.registerPanelAddon` in console — should be a function. Also check `Object.keys(window.PhoenixReplay)` for any indication of registry state.

If row 4 fails (no audio preview), audioState.blob is empty at REVIEW open time. Inspect via console: `(()=>{ const s = require ? null : (window.__as = window.__as || {}); return s; })()` won't work (modules aren't exposed). Add a temporary `window.__audioState = audioState;` line near the singleton declaration for debugging, then check.

If row 5 fails (audio still present after Re-record), pill-action's mount didn't run on the second `:active` session — likely a phoenix_replay bug rather than ash_feedback. Verify the `panel.mountSlot("pill-action", pill.slotEl)` call in `syncRecordingUI` fires twice (once per recording).

- [ ] **Step 3: If smoke is green, proceed. If not, fix in canonical, re-sync, re-smoke.**

---

## Task 7: CHANGELOG + commit

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Append entry**

In `~/Dev/ash_feedback/CHANGELOG.md` under `## [Unreleased]`, immediately AFTER the existing `### Audio addon scoped to Record-and-report mode` block, INSERT:

```markdown
### Audio addon migrated to Phase 3 pill + review slots (2026-04-25)

Migrated from the legacy single-mount on `slot: "form-top"` to a
three-mount architecture aligned with phoenix_replay ADR-0006 Phase 3:

- `pill-action` mount (`id: "ash-feedback-audio-mic"`) — renders the
  🎙 mic toggle inside the recording pill while a Path B `:active`
  session is running. Click toggles MediaRecorder; blob lands in a
  module-scope state singleton on Stop. Each fresh pill-action mount
  (= each fresh `:active` session) clears the singleton, so Re-record
  naturally resets the recording slot.
- `review-media` mount (`id: "ash-feedback-audio-preview"`) — renders
  an `<audio controls>` preview inside the REVIEW screen so the user
  can hear their narration before Send. Empty when no recording was
  captured. Cleanup revokes the blob URL on screen leave but preserves
  the singleton's blob for upload-on-Continue.
- `form-top` mount (`id: "ash-feedback-audio-submit"`) — invisible;
  registers a `beforeSubmit` hook that uploads the singleton's blob
  via the existing `prepare → PUT/POST → blob_id` flow. Returns `{}`
  (zero extras, zero network) when the singleton is empty (Path A
  submit, Path B without mic toggle).

The filter shifts from legacy `modes: ["on_demand"]` to the canonical
`paths: ["record_and_report"]`. The wire format is unchanged: prepare
POST carries `metadata: {audio_start_offset_ms}`; submit's extras
carry `audio_clip_blob_id`. The Feedback resource and `:submit` action
are untouched.

Timeline-bus sync between the audio preview and phoenix_replay's
mini rrweb-player is **not yet implemented** — the user-side timeline
bus surface isn't exposed (admin-side `PhoenixReplayAdmin.subscribeTimeline`
is admin-LV-scoped). The companion spec D2 mentions sync as a future
enhancement; this phase ships unsynced preview.

Smoke verified on `localhost:4006` continuous demo page across 7
matrix rows: mic toggle in pill, recording cycle (start → stop →
toggle visual confirmation), preview in REVIEW, Re-record discards
old blob, Continue + Send uploads, Path B without mic submits zero
audio extras, Path A submit (single-path widget) doesn't mount the
audio addons.

**Out of scope, deferred**: timeline-bus sync between user-side
preview and the mini rrweb-player; this requires phoenix_replay to
expose a user-side bus surface (separate ADR territory).
```

- [ ] **Step 2: Commit**

```bash
cd /Users/johndev/Dev/ash_feedback && git add CHANGELOG.md && git commit -m "$(cat <<'EOF'
docs(changelog): audio addon migrated to Phase 3 pill + review slots

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Risks (from the spec, surfaced for the implementer)

- **MediaRecorder permission denial mid-flow**: pill-action's `getUserMedia` rejection sets `state = "denied"` and renders a "Mic blocked" notice in the pill. The user can still proceed with Path B without audio — Stop still works, REVIEW still opens (with empty review-media slot), Send works without audio extras. Acceptable graceful degradation.
- **`audioState` singleton survives panel close**: if the user opens the panel, mics, closes the panel without sending, then opens it again, the singleton still has the old blob. Path A submit (Report Now) wouldn't pick up the audio because Path A doesn't run the audio addons (paths filter excludes :report_now). Path B's pill-action mount clears the singleton on every fresh `:active` session start. So the only leak window is "user closes panel → opens again → goes Path B" which clears immediately.
- **Re-record race**: user clicks Re-record while MediaRecorder is still stopping (rare — `recorder.stop()` is sync but `onstop` fires asynchronously). The cleanup function's `try { recorder.stop(); } catch {}` handles a double-stop. Worst case is a malformed blob in the previous session that gets discarded by the next pill-action mount's `clearAudioState`.
- **Browser blocks autoplay on the preview `<audio>`**: the `<audio controls>` has no `autoplay`, so the user manually clicks play. No autoplay-policy concern.
- **Module singleton persists across page navigations**: SPA routes don't reload the script, so `audioState` survives. Path B can only start via the panel UX, which mounts pill-action which clears the singleton. The leak window is "Path B in flight on page A → user navigates to page B → page B doesn't have pill-action mounted yet → singleton has stale blob." But page B's panel construction would fire form-top.mount (which doesn't read singleton state at mount time, only at Send time). When the user opens the panel and goes Path B on page B, pill-action mounts and clears. Acceptable.

## Definition of Done

- [ ] All 7 task commits land cleanly on `ash_feedback main`.
- [ ] `mix test` green (full suite, unchanged from baseline).
- [ ] Task 6 smoke matrix rows 1-7 all PASS in browser on `localhost:4006`.
- [ ] CHANGELOG entry merged.
- [ ] phoenix_replay's CHANGELOG `[Unreleased]` "Out of scope" line referencing the ash_feedback companion phase can be updated to "Shipped" — handled in Phase 4.

After this migration ships, **phoenix_replay Phase 4** (drop the legacy `modes:` shim, drop the `open()` alias, finalize the symbol surface) becomes unblocked.

---

## Self-Review

After completing all 7 tasks, run this checklist:

**1. Spec coverage** — map each spec § Phasing item (1.1-1.8) to a task:

| Spec item | Task |
|---|---|
| 1.1 Recon (read current audio_recorder.js + map Phase 2 hooks) | (handled in plan authoring; no implementation task — Task 1's scaffold is the codified outcome) |
| 1.2 Update `register` calls (slot pill-action, slot review-media; modes → paths rename) | Task 2 (pill-action register), Task 3 (review-media register), Task 4 (form-top register — kept on form-top with paths filter) |
| 1.3 mountMicToggle (the in-pill UI) | Task 2 |
| 1.4 mountAudioPreview (review-media binds to in-memory blob, plus timeline-bus sync) | Task 3 (preview lands; timeline-bus sync deferred — flagged in CHANGELOG) |
| 1.5 Cleanup contract (Re-record discards) | Task 2 (pill-action mount clears singleton on fresh active session) + Task 3 (review-media cleanup revokes URL) |
| 1.6 Tests (unit + integration) | NO mix test changes — the existing audio integration tests at `test/ash_feedback_web/components/audio_playback_test.exs` exercise the resource/controller layer which is unchanged. JS unit tests are deferred per phoenix_replay F7 (no JS test infra). Smoke matrix in Task 6 covers end-to-end. |
| 1.7 Docs (README + guide updates) | CHANGELOG only (Task 7). README and `docs/guides/audio-narration.md` updates are intentionally deferred to a follow-up commit — the public surface hasn't fully settled until Phase 4 drops the legacy shims, so a permanent doc page is premature. |
| 1.8 Demo wiring | No demo-side edits needed. The existing root layout already loads audio_recorder.js. Task 6's smoke matrix is the demo verification. |

**2. Placeholder scan** — search for forbidden patterns:
- "TBD" / "TODO" / "implement later" — none in plan body. Task 1's scaffold uses placeholder COMMENTS (`// mountPillAction (Task 2) — placeholder, lands in Task 2.`) which are then explicitly REPLACED in subsequent tasks. Each task's "Replace with:" snippet shows exactly the new content.
- "Add appropriate error handling" — none. Where errors are caught (MediaRecorder unsupported, permission denied, prepare/upload HTTP failures), the catch is explicit with named state values and console-visible messages.
- "Similar to Task N" — none.
- Code blocks present in every code-changing step.

**3. Type / name consistency**:
- `audioState` (module-scope singleton) — declared in Task 1 step 1, read by Task 2 (`audioState.blob/offsetMs/mimeType/ext`), Task 3 (`audioState.blob`), Task 4 (`audioState.blob/offsetMs/mimeType/ext`). Same key names throughout.
- `clearAudioState()` — defined in Task 1, called in Task 2 (`mountPillAction` start) and Task 4 (`beforeSubmit` success). Same name.
- `mountPillAction` / `mountReviewMedia` / `mountFormTop` — declared as bare `function` decls in their respective tasks; each registered in `tryRegister` with the corresponding addon id. Same names throughout.
- Addon ids: `ash-feedback-audio-mic` (Task 2), `ash-feedback-audio-preview` (Task 3), `ash-feedback-audio-submit` (Task 4). All distinct.
- CSS selectors: `phx-replay-audio-pill-action`, `phx-replay-audio-pill-mic`, `phx-replay-audio-pill-stop-mic`, `phx-replay-audio-review`, `phx-replay-audio-review-label`, `phx-replay-audio-review-player`. Each used in JS (Task 2/3 element class assignments) and CSS (Task 5). Confirm correspondence.
- Task 6's smoke matrix references `[data-slot="pill-action"]` and `[data-slot="review-media"]` — these are phoenix_replay's slot div selectors, NOT ash_feedback's. The audio addon attaches its own elements INSIDE those phoenix_replay slot divs. Confirm the smoke verification reads the inner DOM.

If implementation surfaces a real divergence (e.g., the existing `prepare` endpoint changed signature, MediaRecorder API shifted), append an addendum here.

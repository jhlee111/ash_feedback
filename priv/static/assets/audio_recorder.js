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

  // ---- form-top addon (Task 4) --------------------------------------
  // mountFormTop(ctx) — placeholder, lands in Task 4.

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

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

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

    // Variant B layout — title + descriptor on the left, iOS-style
    // switch on the right. Real <input type="checkbox"> stays in the
    // tree (visually-hidden via CSS) so form semantics + keyboard a11y
    // are preserved; the visible track/thumb is sibling-styled via the
    // checkbox's :checked state.
    var wrapper = document.createElement("label");
    wrapper.className = "phx-replay-audio-pre-flight";

    var textCol = document.createElement("div");
    textCol.className = "phx-replay-audio-pre-flight-text";

    var title = document.createElement("div");
    title.className = "phx-replay-audio-pre-flight-title";
    title.textContent = "🎙 Voice commentary";

    var desc = document.createElement("div");
    desc.className = "phx-replay-audio-pre-flight-desc";
    desc.textContent = codec
      ? "Narrate what you're doing — synced to the recording timeline."
      : "Voice not supported in this browser.";

    textCol.appendChild(title);
    textCol.appendChild(desc);

    var checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.className = "phx-replay-audio-switch-input";
    checkbox.checked = audioState.voiceEnabled && !!codec;
    checkbox.disabled = !codec;

    var track = document.createElement("span");
    track.className = "phx-replay-audio-switch-track";
    track.setAttribute("aria-hidden", "true");
    var thumb = document.createElement("span");
    thumb.className = "phx-replay-audio-switch-thumb";
    track.appendChild(thumb);

    wrapper.appendChild(textCol);
    wrapper.appendChild(checkbox);
    wrapper.appendChild(track);
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
      // _pendingStream is preserved for pill-action to consume on the
      // next mount. Panel-close cleanup (separate concern) handles the
      // cancel-without-Start case.
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

  // ---- review-media addon -------------------------------------------
  // Renders the audio preview AND subscribes to phoenix_replay's
  // timeline bus so the <audio> element follows the mini-player's
  // play / pause / seek / tick events. Mirrors the admin
  // audio_playback hook's reconciler — single-clip-per-session means
  // audio + rrweb share t=0 with no offset.
  var DRIFT_THRESHOLD_MS = 200;

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

    // Subscribe to the panel mini-player's timeline. ctx.playerSessionId
    // is "phx-replay-review" — a stable id phoenix_replay registers
    // when the mini-player constructs.
    var lastSpeed = 1;
    var lastStateKind = null; // "play" | "pause" | "ended" | null
    var tryPlay = function () {
      var p = audio.play();
      if (p && typeof p.catch === "function") p.catch(function () {});
    };
    var reconcile = function (detail) {
      var kind = detail.kind;
      var targetSec = Math.max(0, (detail.timecode_ms || 0) / 1000);
      if (typeof detail.speed === "number" && detail.speed !== lastSpeed) {
        audio.playbackRate = detail.speed;
        lastSpeed = detail.speed;
      }
      switch (kind) {
        case "play":
          lastStateKind = "play";
          tryPlay();
          break;
        case "pause":
          lastStateKind = "pause";
          audio.pause();
          break;
        case "ended":
          lastStateKind = "ended";
          audio.pause();
          break;
        case "seek":
          audio.currentTime = targetSec;
          if (lastStateKind === "play") tryPlay();
          break;
        case "tick":
          var drift = Math.abs(audio.currentTime - targetSec) * 1000;
          if (drift > DRIFT_THRESHOLD_MS) audio.currentTime = targetSec;
          break;
      }
    };

    var unsubscribe = null;
    var sessionId = ctx.playerSessionId;
    var bus = window.PhoenixReplay;
    if (sessionId && bus && typeof bus.subscribeTimeline === "function") {
      unsubscribe = bus.subscribeTimeline(sessionId, reconcile, {
        tick_hz: 10,
        deliver_initial: false,
      });
    }

    return function cleanup() {
      if (typeof unsubscribe === "function") {
        try { unsubscribe(); } catch (_) {}
      }
      try { URL.revokeObjectURL(previewUrl); } catch (_) {}
      if (wrapper && wrapper.parentNode) wrapper.parentNode.removeChild(wrapper);
    };
  }

  // ---- form-top addon -----------------------------------------------
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

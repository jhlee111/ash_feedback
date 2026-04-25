// ash_feedback audio recorder — phoenix_replay panel addon.
//
// Self-registers via window.PhoenixReplay.registerPanelAddon once the
// PhoenixReplay namespace is on the page. Captures audio via
// MediaRecorder, uploads to AshStorage via the prepare endpoint + a
// presigned PUT (or POST), and returns { audio_clip_blob_id } via
// beforeSubmit.
//
// D2-revised: the narration start offset (audio_start_offset_ms) rides
// on the AshStorage Blob row's metadata map at prepare time — the
// recorder includes it in the prepare POST body's `metadata` field. The
// beforeSubmit return only carries the blob id under `extras`.
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

  function buildAddon() {
    return {
      id: "audio",
      slot: "form-top",
      mount: function (ctx) {
        var codec = pickCodec();
        var preparePath =
          (ctx.slotEl && ctx.slotEl.getAttribute(PREPARE_PATH_ATTR)) ||
          DEFAULT_PREPARE_PATH;
        var maxSecondsAttr =
          ctx.slotEl && ctx.slotEl.getAttribute(MAX_SECONDS_ATTR);
        var maxSeconds = parseInt(maxSecondsAttr || DEFAULT_MAX_SECONDS, 10);

        // State: "idle" | "recording" | "done" | "denied" | "unsupported"
        var state = codec ? "idle" : "unsupported";
        var mediaStream = null;
        var recorder = null;
        var chunks = [];
        var blob = null;
        var startedAtMs = null;
        var offsetMs = null;
        var timerHandle = null;
        var previewUrl = null;

        var wrapper = document.createElement("div");
        wrapper.className = "phx-replay-audio-addon";
        ctx.slotEl.appendChild(wrapper);

        function clearPreview() {
          if (previewUrl) {
            URL.revokeObjectURL(previewUrl);
            previewUrl = null;
          }
        }

        function render() {
          wrapper.innerHTML = "";

          if (state === "unsupported") {
            var unsup = document.createElement("button");
            unsup.type = "button";
            unsup.className = "phx-replay-audio-mic";
            unsup.disabled = true;
            unsup.title = "Audio recording not supported in this browser";
            unsup.textContent = "🎙 Voice note (unsupported)";
            wrapper.appendChild(unsup);
            return;
          }

          if (state === "denied") {
            var notice = document.createElement("div");
            notice.className = "phx-replay-audio-notice";
            notice.textContent =
              "Microphone permission denied. You can still submit without audio.";
            wrapper.appendChild(notice);
            return;
          }

          if (state === "idle") {
            var btn = document.createElement("button");
            btn.type = "button";
            btn.className = "phx-replay-audio-mic";
            btn.textContent = "🎙 Record voice note";
            btn.addEventListener("click", function () {
              startRecording();
            });
            wrapper.appendChild(btn);
            return;
          }

          if (state === "recording") {
            var elapsed = Date.now() - startedAtMs;
            var remainingMs = maxSeconds * 1000 - elapsed;
            var stop = document.createElement("button");
            stop.type = "button";
            stop.className = "phx-replay-audio-stop";
            stop.textContent = "■ Stop · " + fmtDuration(elapsed);
            stop.addEventListener("click", function () {
              stopRecording();
            });
            wrapper.appendChild(stop);

            if (remainingMs <= 30000) {
              var warn = document.createElement("span");
              warn.className = "phx-replay-audio-warn";
              warn.textContent =
                " · " + Math.max(0, Math.ceil(remainingMs / 1000)) + "s left";
              wrapper.appendChild(warn);
            }
            return;
          }

          if (state === "done") {
            clearPreview();
            previewUrl = URL.createObjectURL(blob);

            var audio = document.createElement("audio");
            audio.controls = true;
            audio.src = previewUrl;
            audio.className = "phx-replay-audio-preview";
            wrapper.appendChild(audio);

            var rerec = document.createElement("button");
            rerec.type = "button";
            rerec.className = "phx-replay-audio-rerecord";
            rerec.textContent = "✕ Re-record";
            rerec.addEventListener("click", function () {
              clearPreview();
              blob = null;
              startedAtMs = null;
              offsetMs = null;
              state = "idle";
              render();
            });
            wrapper.appendChild(rerec);
            return;
          }
        }

        function tick() {
          if (state !== "recording") return;
          var elapsed = Date.now() - startedAtMs;
          if (elapsed >= maxSeconds * 1000) {
            stopRecording();
            return;
          }
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
                blob = new Blob(chunks, { type: codec.mime });
                if (mediaStream) {
                  mediaStream.getTracks().forEach(function (t) {
                    t.stop();
                  });
                }
                mediaStream = null;
                state = "done";
                render();
              };
              recorder.start();

              startedAtMs = Date.now();
              var sessionStarted =
                typeof ctx.sessionStartedAtMs === "function"
                  ? ctx.sessionStartedAtMs()
                  : null;
              offsetMs = sessionStarted
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

        if (typeof ctx.onPanelClose === "function") {
          ctx.onPanelClose(function () {
            if (mediaStream) {
              mediaStream.getTracks().forEach(function (t) {
                t.stop();
              });
            }
            if (timerHandle) window.clearTimeout(timerHandle);
            clearPreview();
            mediaStream = null;
            recorder = null;
            chunks = [];
            blob = null;
            startedAtMs = null;
            offsetMs = null;
            state = codec ? "idle" : "unsupported";
          });
        }

        function beforeSubmit(_args) {
          if (state !== "done" || !blob) return Promise.resolve({});

          var headers = { "content-type": "application/json" };
          var token = csrfToken();
          if (token) headers["x-csrf-token"] = token;

          var prepareBody = {
            filename: "voice-note." + codec.ext,
            content_type: codec.mime,
            byte_size: blob.size,
          };

          // D2-revised: offset persists on the blob's metadata at
          // prepare time. The submit-side wire format only carries the
          // blob id under `extras`.
          if (typeof offsetMs === "number") {
            prepareBody.metadata = { audio_start_offset_ms: offsetMs };
          }

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
                fd.append("file", blob);
                return fetch(url, { method: "POST", body: fd }).then(
                  function (up) {
                    if (!up.ok) {
                      throw new Error(
                        "Audio upload failed: HTTP " + up.status
                      );
                    }
                    return info.blob_id;
                  }
                );
              }

              return fetch(url, {
                method: "PUT",
                body: blob,
                headers: { "content-type": codec.mime },
              }).then(function (up) {
                if (!up.ok) {
                  throw new Error("Audio upload failed: HTTP " + up.status);
                }
                return info.blob_id;
              });
            })
            .then(function (blobId) {
              return { extras: { audio_clip_blob_id: blobId } };
            });
        }

        render();
        return { beforeSubmit: beforeSubmit };
      },
    };
  }

  function tryRegister() {
    if (
      window.PhoenixReplay &&
      typeof window.PhoenixReplay.registerPanelAddon === "function"
    ) {
      window.PhoenixReplay.registerPanelAddon(buildAddon());
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

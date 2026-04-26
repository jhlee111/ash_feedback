// AshFeedback admin-side audio sync hook.
//
// Mounted by <.audio_playback>. Subscribes to phoenix_replay's
// PhoenixReplayAdmin.subscribeTimeline (ADR-0005) and reconciles the
// child <audio> element on each event.
//
// Single-clip-per-session model: audio shares t=0 with rrweb. There
// is no offset to seek past.
//
// Sync rules:
//   play   : audio.play()
//   pause  : audio.pause()
//   seek   : audio.currentTime = timecode_ms / 1000
//            then play if last state was :play
//   tick   : correct audio.currentTime when drift > 200ms
//   ended  : audio.pause()
//   any    : if detail.speed != lastSpeed, set audio.playbackRate = speed
//
// audio.play() may reject under autoplay policy — silently caught.

(function (global) {
  const TICK_HZ = 10;
  const DRIFT_THRESHOLD_MS = 200;

  const AudioPlayback = {
    mounted() {
      const sessionId = this.el.dataset.sessionId;
      const url = this.el.dataset.url;

      this.audio = this.el.querySelector("audio");
      this.audio.src = url;
      this.lastSpeed = 1;
      this.lastStateKind = null; // "play" | "pause" | "ended" | null

      const Admin = global.PhoenixReplayAdmin;
      if (!Admin || typeof Admin.subscribeTimeline !== "function") {
        console.warn(
          "[AshFeedback] PhoenixReplayAdmin.subscribeTimeline unavailable; " +
            "audio playback will not sync. Ensure phoenix_replay >= ADR-0005 Phase 2 is loaded."
        );
        return;
      }

      this.unsubscribe = Admin.subscribeTimeline(
        sessionId,
        (detail) => this.handleEvent(detail),
        { tick_hz: TICK_HZ, deliver_initial: true }
      );
    },

    destroyed() {
      if (typeof this.unsubscribe === "function") this.unsubscribe();
    },

    handleEvent(detail) {
      const { kind, timecode_ms, speed } = detail;

      // Speed reconciliation — every event carries .speed; no
      // dedicated :speed_changed kind exists.
      if (typeof speed === "number" && speed !== this.lastSpeed) {
        this.audio.playbackRate = speed;
        this.lastSpeed = speed;
      }

      const targetSec = Math.max(0, timecode_ms / 1000);

      switch (kind) {
        case "play": {
          this.lastStateKind = "play";
          this.tryPlay();
          break;
        }

        case "pause": {
          this.lastStateKind = "pause";
          this.audio.pause();
          break;
        }

        case "ended": {
          this.lastStateKind = "ended";
          this.audio.pause();
          break;
        }

        case "seek": {
          this.audio.currentTime = targetSec;
          if (this.lastStateKind === "play") {
            this.tryPlay();
          }
          break;
        }

        case "tick": {
          // Drift correction.
          const drift = Math.abs(this.audio.currentTime - targetSec) * 1000;
          if (drift > DRIFT_THRESHOLD_MS) this.audio.currentTime = targetSec;
          break;
        }
      }
    },

    tryPlay() {
      const p = this.audio.play();
      if (p && typeof p.catch === "function") p.catch(() => {});
    },
  };

  // Expose on the same global namespace pattern used elsewhere in this
  // library so hosts can register it with their LiveSocket.
  if (!global.AshFeedback) global.AshFeedback = {};
  if (!global.AshFeedback.Hooks) global.AshFeedback.Hooks = {};
  global.AshFeedback.Hooks.AudioPlayback = AudioPlayback;
})(window);

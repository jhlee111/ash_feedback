// Run with: node test/js/audio_recorder_test.js
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const src = fs.readFileSync(
  path.join(__dirname, "..", "..", "priv", "static", "assets", "audio_recorder.js"),
  "utf8"
);

function makeSandbox() {
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
          setAttribute() {},
          set className(_v) {},
          set textContent(_v) {},
          set type(_v) {},
          set src(_v) {},
          set controls(_v) {},
          set checked(v) { this._checked = v; },
          get checked() { return this._checked; },
          set disabled(v) { this._disabled = v; },
          get disabled() { return this._disabled; },
          get currentTime() { return 0; },
          set currentTime(_v) {},
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
    setInterval, clearInterval, setTimeout, clearTimeout, console, Promise,
    URL: { createObjectURL: () => "blob:test", revokeObjectURL: () => {} },
    Blob: function (parts, opts) {
      this.parts = parts;
      this.size = parts.reduce((a, p) => a + (p.length || 0), 0);
      this.type = (opts || {}).type;
    },
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
  // four addons register in the right slots
  {
    const { registered } = makeSandbox();
    const slots = registered.map(a => a.slot).sort();
    assert(slots.length === 4, "four addons registered");
    assert(slots.join(",") === "form-top,idle-start-options,pill-action,review-media", "expected slots: " + slots.join(","));
  }

  // idle-start-options mount: voice OFF default, registers canStart, hook returns ok:true
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
    const result = await registeredCanStart[1]();
    assert(result.ok === true, "canStart with voice OFF returns ok:true");
  }

  // form-top beforeSubmit with no blob returns extras: {}
  {
    const { registered } = makeSandbox();
    const formTop = registered.find(a => a.slot === "form-top");
    const ctx = { slotEl: { getAttribute: () => null } };
    const result = formTop.mount(ctx);
    assert(typeof result.beforeSubmit === "function", "form-top returns object with beforeSubmit");
    const submitResult = await result.beforeSubmit({});
    assert(JSON.stringify(submitResult) === "{}", "no-blob beforeSubmit returns empty extras");
  }

  // review-media without blob returns no-op cleanup
  {
    const { registered } = makeSandbox();
    const review = registered.find(a => a.slot === "review-media");
    const ctx = { slotEl: { appendChild() {} } };
    const cleanup = review.mount(ctx);
    assert(typeof cleanup === "function", "review-media returns cleanup even when blob missing");
  }

  console.log("audio_recorder_test: ok");
})();

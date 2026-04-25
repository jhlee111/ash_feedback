# Audio Narration Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a microphone button to the existing `phoenix_replay` widget panel that records audio via `MediaRecorder`, uploads it directly to storage via an `AshStorage` presigned URL, and links the resulting blob to the submitted `Feedback` row with `audio_start_offset_ms` persisted alongside.

**Architecture:** Extend `phoenix_replay` with a narrow panel-addon API (DOM slot + `registerPanelAddon` JS + `extras` pipeline through `report()` and `/submit`). `phoenix_replay` stays Ash-agnostic. `ash_feedback` ships the audio addon as the first consumer: a recorder JS file, a `prepare` controller, a router macro, and a `Feedback.submit` action update that wires `AshStorage.Changes.AttachBlob`. The host (this demo) wires the AshStorage Disk service for dev. Tests use Firkin to exercise the real S3 contract in-process.

**Tech Stack:** Phoenix 1.8.5, Ash, AshStorage, AshPostgres, Phoenix LiveView, vanilla JS (no build step), Firkin (test-time S3-compatible Plug).

---

## Working Directory Map

This plan touches three repos. Each task header lists the repo it runs in.

| Repo | Path | Role |
|---|---|---|
| `phoenix_replay` | `~/Dev/phoenix_replay/` | Panel addon API (sub-phase 2a) |
| `ash_feedback` | `~/Dev/ash_feedback/` | Audio addon (sub-phases 2b, 2c) |
| `ash_feedback_demo` | `~/Dev/ash_feedback_demo/` | Host wiring + manual smoke (sub-phase 2d) |
| Both libraries | both | Docs + library SHA bump in demo (sub-phase 2e) |

**Cross-repo dep refresh.** When library code changes, the demo picks them up via:
```bash
cd ~/Dev/ash_feedback_demo
cp -R ~/Dev/phoenix_replay/lib/. deps/phoenix_replay/lib/
cp -R ~/Dev/phoenix_replay/priv/static/assets/. deps/phoenix_replay/priv/static/assets/
cp -R ~/Dev/ash_feedback/lib/. deps/ash_feedback/lib/
cp -R ~/Dev/ash_feedback/priv/. deps/ash_feedback/priv/
mix deps.compile phoenix_replay --force
mix deps.compile ash_feedback --force
```
Restart the app server via Tidewave with `reason: "deps_changed"`.

## File Structure

### phoenix_replay (sub-phase 2a)
- Modify: `priv/static/assets/phoenix_replay.js` — DOM slot in `renderPanel()`, `registerPanelAddon` JS API, form submit orchestrator, `extras` arg in `report()`.
- Modify: `lib/phoenix_replay/controller/submit_controller.ex` — accept `extras` in POST body, forward to `Storage.Dispatch.submit/4`.
- Modify: `lib/phoenix_replay/storage.ex` (the behaviour) — extras documented as a key inside `submit_params`. **Behaviour signature stays the same** — `extras` rides inside the existing `submit_params` map under `"extras"`. No callback change.
- Modify: `lib/phoenix_replay/storage/dispatch.ex` — passthrough.
- Create: `test/phoenix_replay/widget/panel_addon_test.exs` — JSDOM-style test via the existing JS test harness (verify against the Phase 2 fixture pattern for in-Elixir DOM tests; see Task 2a.6 for harness selection).

### ash_feedback (sub-phases 2b + 2c)
- Modify: `mix.exs` — add `firkin` as a `:test`-only dep.
- Create: `lib/ash_feedback/config.ex` — single helper `feedback_resource!/0`.
- Create: `lib/ash_feedback/controller/audio_uploads_controller.ex` — `POST /audio_uploads/prepare` handler.
- Create: `lib/ash_feedback/router.ex` — `defmacro audio_routes/1`.
- Modify: `lib/ash_feedback/resources/feedback.ex` — `:submit` action gains `:audio_clip_blob_id` + `:audio_start_offset_ms` arguments and the `AshStorage.Changes.AttachBlob` change.
- Modify: `lib/ash_feedback/storage.ex` — extract `extras["audio_clip_blob_id"]` + `extras["audio_start_offset_ms"]` from `submit_params`, forward as action args.
- Create: `priv/static/assets/audio_recorder.js` — addon JS.
- Create: `test/ash_feedback/controller/audio_uploads_controller_test.exs` — controller test.
- Create: `test/support/firkin_case.ex` — Firkin setup for round-trip test.
- Create: `test/ash_feedback/audio_round_trip_test.exs` — Firkin-backed end-to-end test.
- Modify: `CHANGELOG.md`.
- Modify: `README.md` — audio recorder usage section.

### ash_feedback_demo (sub-phase 2d)
- Modify: `mix.exs` — add `ash_storage` to host deps.
- Create: `lib/ash_feedback_demo/storage/blob.ex` — host AshStorage Blob resource.
- Create: `lib/ash_feedback_demo/storage/attachment.ex` — host AshStorage Attachment resource.
- Modify: `lib/ash_feedback_demo/feedback/entry.ex` — pass `audio_attachment_resource:` to the macro.
- Modify: `config/config.exs` — `audio_enabled: true`, register the resource.
- Modify: `config/dev.exs` — `AshStorage.Service.Disk` configuration.
- Modify: `lib/ash_feedback_demo_web/endpoint.ex` — mount `AshStorage.Service.Disk.Plug` (or equivalent — verified in Task 2d.5).
- Modify: `lib/ash_feedback_demo_web/router.ex` — call `AshFeedback.Router.audio_routes/0`.
- Modify: `lib/ash_feedback_demo_web/components/layouts/root.html.heex` — add `<script>` tag.
- Modify: `.gitignore` — add `tmp/uploads/`.

### Both libraries (sub-phase 2e)
- Modify: `~/Dev/phoenix_replay/CHANGELOG.md` — panel-addon API entry.
- Modify: `~/Dev/phoenix_replay/README.md` — addon API usage section.
- Modify: `~/Dev/ash_feedback/CHANGELOG.md` — Phase 2 entry.
- Modify: `~/Dev/ash_feedback/README.md` — audio recorder section.
- Modify: `~/Dev/ash_feedback_demo/mix.lock` — bump `phoenix_replay` and `ash_feedback` SHAs after pushing library commits.

---

## Sub-phase 2a — phoenix_replay panel-addon API

**Sub-phase goal:** Phoenix_replay's widget panel exposes a slot + JS registration entrypoint + `extras` pipeline. No audio code; a stub addon proves the contract.

**Sub-phase CWD:** `~/Dev/phoenix_replay/`

### Task 2a.1: Add the panel addon DOM slot

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js:502-523` (the `<form>` HEREDOC inside `renderPanel`)

- [ ] **Step 1: Insert the slot above the severity row**

In `renderPanel`'s form HTML, change the form fragment from this (current state, lines 502–523):

```html
<form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
  <h2 id="phx-replay-title">Report an issue</h2>
  <label>
    <span>What happened?</span>
    <textarea name="description" rows="4" required placeholder="Steps to reproduce, what you expected, what actually happened"></textarea>
  </label>
  <label>
    <span>Severity</span>
    <select name="severity">
      ${cfg.severities.map(s => `<option value="${s}"${s === cfg.defaultSeverity ? " selected" : ""}>${s}</option>`).join("")}
    </select>
  </label>
  ...
```

To this — adding the slot div between the description and severity blocks:

```html
<form class="phx-replay-screen phx-replay-screen--form" data-screen="${SCREENS.FORM}">
  <h2 id="phx-replay-title">Report an issue</h2>
  <label>
    <span>What happened?</span>
    <textarea name="description" rows="4" required placeholder="Steps to reproduce, what you expected, what actually happened"></textarea>
  </label>
  <div class="phx-replay-panel-addons" data-slot="form-top"></div>
  <label>
    <span>Severity</span>
    <select name="severity">
      ${cfg.severities.map(s => `<option value="${s}"${s === cfg.defaultSeverity ? " selected" : ""}>${s}</option>`).join("")}
    </select>
  </label>
  ...
```

(The rest of the form HEREDOC stays unchanged.)

- [ ] **Step 2: Verify the existing widget tests still pass**

Run: `mix test test/phoenix_replay/widget/`
Expected: PASS — adding an empty `<div>` doesn't affect any existing assertion. If a test asserts the form's full HTML, it will fail; in that case update the fixture to include the new div and rerun.

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
# also any test fixture updates
git commit -m "feat(widget): add form-top addon slot to panel form

Empty <div data-slot=\"form-top\"> rendered between description and
severity. The registerPanelAddon JS API (next task) will mount addon
content into this slot."
```

### Task 2a.2: Implement `registerPanelAddon` and the addons registry

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — add a registry near the top of the IIFE (immediately after `const SCREENS = ...`), and the `registerPanelAddon` global export at the bottom of the IIFE alongside the existing `mount`/`unmount` exports.

- [ ] **Step 1: Add the addons registry and `registerPanelAddon` function**

Near the top of the IIFE (just after the `SCREENS` constant), add:

```js
// Panel addon registry. Each entry: { id, slot, mount }. `mount(ctx)` is
// invoked once per panel-mount; it returns optional { beforeSubmit,
// onPanelClose } hooks. The orchestrator collects beforeSubmit return
// values and merges all `extras` into the report() body.
const PANEL_ADDONS = new Map();  // id -> { id, slot, mount }
```

At the bottom of the IIFE, in the existing `window.PhoenixReplay = { ... }` export object (find the `mount` / `init` exports), add:

```js
registerPanelAddon({ id, slot, mount }) {
  if (typeof id !== "string" || id.length === 0) {
    throw new Error("[PhoenixReplay] registerPanelAddon requires a string id");
  }
  if (typeof mount !== "function") {
    throw new Error("[PhoenixReplay] registerPanelAddon requires a mount function");
  }
  PANEL_ADDONS.set(id, { id, slot: slot || "form-top", mount });
},
```

- [ ] **Step 2: Verify the file compiles (no syntax errors)**

Run: `node -c priv/static/assets/phoenix_replay.js`
Expected: no output (success). If `node -c` is unavailable, run a quick `mix test` and confirm the test harness can still load the script.

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(widget): registerPanelAddon JS API

Adds PANEL_ADDONS registry + window.PhoenixReplay.registerPanelAddon({
id, slot, mount }). No mount-time wiring yet — that lands in 2a.3."
```

### Task 2a.3: Wire addon mount into `renderPanel`

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js` — in `renderPanel`, call each registered addon's `mount(ctx)` after the panel root is appended; track returned `beforeSubmit` / `onPanelClose` callbacks; invoke `onPanelClose` callbacks from the existing `close()` function.

- [ ] **Step 1: Mount each addon and collect hooks**

Inside `renderPanel`, after the existing line `mountEl.appendChild(root);` (around line 527), add:

```js
// Mount panel addons against their slots. Each addon's mount(ctx)
// returns optional { beforeSubmit, onPanelClose } hooks; we collect
// them for the submit orchestrator and the panel close cleanup.
const slotEls = new Map();  // slot name -> DOM element
root.querySelectorAll("[data-slot]").forEach((el) => {
  slotEls.set(el.dataset.slot, el);
});

const addonHooks = [];  // [{ id, beforeSubmit?, onPanelClose? }]
const addonCloseCbs = [];

PANEL_ADDONS.forEach((addon) => {
  const slotEl = slotEls.get(addon.slot);
  if (!slotEl) {
    console.warn(`[PhoenixReplay] addon "${addon.id}" requested unknown slot "${addon.slot}"`);
    return;
  }
  try {
    const ctx = {
      slotEl,
      sessionId: () => client._internals?.sessionId?.() ?? null,
      sessionStartedAtMs: () => client._internals?.sessionStartedAtMs?.() ?? null,
      onPanelClose: (cb) => addonCloseCbs.push(cb),
      reportError: (msg) => { errorMessage.textContent = msg; setScreen(SCREENS.ERROR); showModal(); },
    };
    const hooks = addon.mount(ctx) || {};
    addonHooks.push({ id: addon.id, ...hooks });
  } catch (err) {
    console.warn(`[PhoenixReplay] addon "${addon.id}" failed to mount: ${err.message}`);
  }
});
```

- [ ] **Step 2: Invoke `onPanelClose` callbacks from `close()`**

Modify the existing `close()` function (around line 555) to call each addon close callback:

```js
function close() {
  hideModal();
  form.reset();
  status.textContent = "";
  setScreen(SCREENS.FORM);
  addonCloseCbs.forEach((cb) => {
    try { cb(); } catch (err) { console.warn(`[PhoenixReplay] addon close hook failed: ${err.message}`); }
  });
}
```

- [ ] **Step 3: Expose `addonHooks` to the form-submit orchestrator**

The form-submit handler (Task 2a.5) needs access to `addonHooks`. It's already in scope since it's defined in the same `renderPanel` closure, but make sure no other code path is referencing the same name.

- [ ] **Step 4: Verify `_internals` exposes `sessionId` and `sessionStartedAtMs`**

The recorder addon needs `sessionId` and `sessionStartedAtMs` from the client. Today's `client._internals` exposes `{ buffer }` (line 460 of `phoenix_replay.js`). Extend it.

In the IIFE that builds `client`, find where `sessionToken`, `sessionId`, and the session-start wall clock live (search for `sessionToken` and the place where `start_session` succeeds, around line 220 of the file). Add a `sessionStartedAtMs` variable initialized to `null`, set it to `Date.now()` at the same point `sessionToken` is assigned a fresh value. Then extend `_internals`:

```js
return {
  start,
  report,
  // ...
  _internals: {
    buffer,
    sessionId: () => sessionToken ? extractSessionIdFromToken(sessionToken) : null,
    sessionStartedAtMs: () => sessionStartedAtMs,
  },
};
```

If `extractSessionIdFromToken` doesn't already exist, the simpler approach is to track `sessionId` separately as a top-level variable in the IIFE (the client already does — search for `sessionId` references) and return it directly.

(Code spot-check: confirm the current shape of session-id handling before writing this step. If session_id isn't tracked client-side already, expose what's available — at minimum `sessionStartedAtMs` is necessary for the offset calculation.)

- [ ] **Step 5: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(widget): mount panel addons + onPanelClose hook

renderPanel iterates registered addons, mounts each into its slot
with a context (slotEl, sessionId, sessionStartedAtMs, onPanelClose,
reportError), and collects hook return values. close() invokes addon
close callbacks. No submit-side wiring yet."
```

### Task 2a.4: Add `extras` to `report()`

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js:363-378` (the `report` function)

- [ ] **Step 1: Update `report()` signature and POST body**

Change `report` from:

```js
async function report({ description, severity, metadata = {}, jamLink = null }) {
  await flush();

  await postJson(`${basePath}${cfg.submitPath}`, {
    description,
    severity: severity || cfg.defaultSeverity,
    metadata,
    jam_link: jamLink,
  }, {
    csrfToken,
    csrfHeader: cfg.csrfHeader,
    sessionToken,
    tokenHeader: cfg.tokenHeader,
  });
  // ... rest unchanged
}
```

To:

```js
async function report({ description, severity, metadata = {}, jamLink = null, extras = {} }) {
  await flush();

  await postJson(`${basePath}${cfg.submitPath}`, {
    description,
    severity: severity || cfg.defaultSeverity,
    metadata,
    jam_link: jamLink,
    extras,
  }, {
    csrfToken,
    csrfHeader: cfg.csrfHeader,
    sessionToken,
    tokenHeader: cfg.tokenHeader,
  });
  // ... rest unchanged
}
```

- [ ] **Step 2: Verify file compiles**

Run: `node -c priv/static/assets/phoenix_replay.js`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(widget): report() accepts extras, sends in /submit body

extras is a passthrough map populated by addon beforeSubmit hooks
(wired in 2a.5). Default {} keeps existing callers unchanged."
```

### Task 2a.5: Form submit orchestrator runs addon `beforeSubmit` hooks

**Files:**
- Modify: `priv/static/assets/phoenix_replay.js:570-585` (the existing `form.addEventListener("submit", ...)` handler)

- [ ] **Step 1: Replace the submit handler with the addon-aware version**

Change from:

```js
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const data = new FormData(form);
  status.textContent = "Sending…";
  try {
    await client.report({
      description: data.get("description"),
      severity: data.get("severity"),
      jamLink: data.get("jam_link") || null,
    });
    status.textContent = "Thanks! Your report was submitted.";
    setTimeout(close, 1200);
  } catch (err) {
    status.textContent = `Submit failed: ${err.message}`;
  }
});
```

To:

```js
form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const data = new FormData(form);
  status.textContent = "Sending…";

  // Run all addon beforeSubmit hooks in registration order, merging
  // each returned `extras` into a single map. A throw aborts the
  // submit and surfaces the error inline.
  const merged = {};
  try {
    for (const hook of addonHooks) {
      if (typeof hook.beforeSubmit !== "function") continue;
      status.textContent = `Sending… (${hook.id})`;
      const result = await hook.beforeSubmit({ formData: data });
      if (result && result.extras && typeof result.extras === "object") {
        Object.assign(merged, result.extras);
      }
    }
  } catch (err) {
    status.textContent = `Submit failed: ${err.message}`;
    return;
  }

  status.textContent = "Sending…";
  try {
    await client.report({
      description: data.get("description"),
      severity: data.get("severity"),
      jamLink: data.get("jam_link") || null,
      extras: merged,
    });
    status.textContent = "Thanks! Your report was submitted.";
    setTimeout(close, 1200);
  } catch (err) {
    status.textContent = `Submit failed: ${err.message}`;
  }
});
```

- [ ] **Step 2: Verify file compiles**

Run: `node -c priv/static/assets/phoenix_replay.js`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add priv/static/assets/phoenix_replay.js
git commit -m "feat(widget): submit orchestrator runs addon beforeSubmit

Each addon's beforeSubmit({formData}) runs in series; returned extras
merge into a single map sent via report({ extras }). A throw aborts
submit and surfaces the error inline."
```

### Task 2a.6: SubmitController forwards `extras` to Storage

**Files:**
- Modify: `lib/phoenix_replay/controller/submit_controller.ex:15-55`

- [ ] **Step 1: Add `extras` to `submit_params`**

In `create/2`, change the `submit_params` block from:

```elixir
submit_params = %{
  "description" => Map.get(params, "description"),
  "severity" => Map.get(params, "severity"),
  "metadata" => merged_metadata,
  "jam_link" => Map.get(params, "jam_link")
}
```

To:

```elixir
submit_params = %{
  "description" => Map.get(params, "description"),
  "severity" => Map.get(params, "severity"),
  "metadata" => merged_metadata,
  "jam_link" => Map.get(params, "jam_link"),
  "extras" => stringify_keys(Map.get(params, "extras") || %{})
}
```

The behaviour signature (`submit/3`) is unchanged — `extras` rides inside `submit_params` as a string-keyed map. Adapters that don't care ignore it.

- [ ] **Step 2: Add a controller test for extras passthrough**

Create or extend `test/phoenix_replay/controller/submit_controller_test.exs`. If a test already covers submit params shape, extend it; otherwise create a focused test using a stub adapter.

```elixir
test "POST /submit includes extras in submit_params", %{conn: conn, session_id: session_id} do
  Application.put_env(:phoenix_replay, :storage, {PhoenixReplay.Test.RecordingStorage, []})
  on_exit(fn -> Application.delete_env(:phoenix_replay, :storage) end)

  conn =
    conn
    |> put_req_header("x-phoenix-replay-session", session_token(session_id))
    |> post(~p"/submit", %{
      "description" => "test",
      "severity" => "low",
      "extras" => %{"audio_clip_blob_id" => "blob-123"}
    })

  assert json_response(conn, 201)
  assert {^session_id, params, _identity} = PhoenixReplay.Test.RecordingStorage.last_call()
  assert params["extras"] == %{"audio_clip_blob_id" => "blob-123"}
end
```

If `PhoenixReplay.Test.RecordingStorage` doesn't exist, create it as a small `:ets`-backed stub that implements the `PhoenixReplay.Storage` behaviour and records the most recent `submit/3` call. Path: `test/support/recording_storage.ex`. Skeleton:

```elixir
defmodule PhoenixReplay.Test.RecordingStorage do
  @moduledoc false
  @behaviour PhoenixReplay.Storage

  def start_link, do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def last_call, do: Agent.get(__MODULE__, & &1)

  @impl true
  def start_session(_, _), do: {:ok, "test-session-#{System.unique_integer([:positive])}"}

  @impl true
  def resume_session(_, _), do: {:error, :not_found}

  @impl true
  def append_events(_, _, _), do: :ok

  @impl true
  def submit(session_id, params, identity) do
    Agent.update(__MODULE__, fn _ -> {session_id, params, identity} end)
    {:ok, %{id: "fbk-test"}}
  end

  @impl true
  def fetch_feedback(_, _), do: {:error, :not_found}
  @impl true
  def fetch_events(_), do: {:ok, []}
  @impl true
  def list(_, _), do: {:ok, [], 0}
end
```

Hook it into `test/test_helper.exs` as `Code.require_file("support/recording_storage.ex", __DIR__)` and start the Agent in `setup` of any test that uses it.

- [ ] **Step 3: Run the controller test**

Run: `mix test test/phoenix_replay/controller/submit_controller_test.exs --only extras`
Expected: PASS for the new test (tag the test with `@tag :extras` if needed).

- [ ] **Step 4: Run the full phoenix_replay test suite**

Run: `mix test`
Expected: All 79 existing tests + the new test pass.

- [ ] **Step 5: Commit**

```bash
git add lib/phoenix_replay/controller/submit_controller.ex test/phoenix_replay/controller/submit_controller_test.exs test/support/recording_storage.ex
git commit -m "feat(submit): forward extras to Storage adapter

POST /submit now stringifies + forwards an extras map (default %{})
inside submit_params. Adapter behaviour signature is unchanged —
extras ride under the \"extras\" key.

RecordingStorage test stub records the most recent submit/3 call."
```

### Task 2a.7: End-to-end test of the addon API contract

**Files:**
- Create: `test/phoenix_replay/widget/panel_addon_test.exs` (Elixir test using a JSDOM-style harness, OR a Wallaby/Hound browser test if one already exists in the project — verify which is in use before writing).

- [ ] **Step 1: Identify the existing widget test harness**

Run: `ls test/phoenix_replay/widget/ && head -20 test/phoenix_replay/widget/*.exs`
Expected: see what the current widget tests use. If they're pure Elixir component-render tests against `PhoenixReplay.UI.Components`, they don't exercise JS — in that case, the addon API test will live as a manual-smoke entry in this plan and a JS unit test deferred to the JS-test-infra ADR.

If a JS test runner exists (Vitest, Jest, etc.), write the test there. Path: `test/js/panel_addon.test.js` (or wherever the harness lives).

- [ ] **Step 2 (Path A — JS harness exists): Write the addon contract test**

```js
import { describe, test, expect, beforeEach } from "vitest";
import { JSDOM } from "jsdom";

describe("registerPanelAddon", () => {
  let dom, PhoenixReplay;

  beforeEach(() => {
    dom = new JSDOM(`<!DOCTYPE html><html><body><div id="mount"></div></body></html>`);
    global.window = dom.window;
    global.document = dom.window.document;
    // Load phoenix_replay.js (path adapted to harness setup)
    require("../../priv/static/assets/phoenix_replay.js");
    PhoenixReplay = dom.window.PhoenixReplay;
  });

  test("addon mounts into form-top slot and beforeSubmit extras land in report()", async () => {
    let captured = null;
    PhoenixReplay.registerPanelAddon({
      id: "test-addon",
      slot: "form-top",
      mount(ctx) {
        ctx.slotEl.innerHTML = "<span data-test=\"addon-mounted\">x</span>";
        return {
          async beforeSubmit({ formData }) {
            return { extras: { audio_clip_blob_id: "blob-123" } };
          },
        };
      },
    });

    // Stub the network — capture the body posted to /submit
    global.fetch = async (url, init) => {
      if (url.endsWith("/submit")) {
        captured = JSON.parse(init.body);
        return { ok: true, status: 201, json: async () => ({ ok: true, id: "fbk-1" }) };
      }
      // Stub session start
      if (url.endsWith("/session")) {
        return { ok: true, status: 200, headers: { get: () => "test-token" }, json: async () => ({}) };
      }
      return { ok: true, status: 200, json: async () => ({}) };
    };

    PhoenixReplay.mount({ mount: document.getElementById("mount"), basePath: "" });
    // Open panel, fill form, submit
    document.querySelector(".phx-replay-modal-panel form").querySelector("textarea").value = "test";
    document.querySelector(".phx-replay-modal-panel form").dispatchEvent(new dom.window.Event("submit", { cancelable: true }));

    // Allow promise microtasks to settle
    await new Promise((r) => setTimeout(r, 50));

    expect(document.querySelector("[data-test=\"addon-mounted\"]")).not.toBeNull();
    expect(captured.extras).toEqual({ audio_clip_blob_id: "blob-123" });
  });
});
```

- [ ] **Step 2 (Path B — no JS harness): Defer to manual smoke**

If no JS harness exists, mark the addon contract verification as a **manual smoke** step in 2d's checklist (see Task 2d.10). Add a TODO comment in `phoenix_replay.js` near the addon registry pointing at the planned JS-test-infra ADR.

- [ ] **Step 3: Run the test (Path A)**

Run: `npm test -- panel_addon.test.js` (or whatever the harness command is).
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/  # adjust path
git commit -m "test(widget): panel addon contract test

Addon registers, mounts in form-top slot, and beforeSubmit extras
appear in /submit POST body."
```

### Task 2a.8: phoenix_replay CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add an entry under the unreleased section**

Insert at the top of `CHANGELOG.md` under whatever heading follows the "## Unreleased" header (or create the section):

```markdown
### Added

- Panel addon API: `window.PhoenixReplay.registerPanelAddon({ id, slot, mount })`
  registers a JS hook into the widget panel form. `mount(ctx)` returns
  optional `beforeSubmit` and `onPanelClose` callbacks. `beforeSubmit`
  returns `{ extras }` which is merged into the `/submit` POST body.
  First consumer: `ash_feedback`'s audio narration recorder.
- DOM slot `<div data-slot="form-top">` rendered between description
  and severity inside the panel form.
- `extras` field on `report()` and on the `/submit` POST body. The
  configured `PhoenixReplay.Storage` adapter receives extras inside
  `submit_params` under the `"extras"` key. Adapter behaviour signature
  unchanged.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): panel addon API entry"
```

---

## Sub-phase 2b — ash_feedback audio addon

**Sub-phase goal:** ash_feedback ships the audio recorder JS, the prepare controller, the router macro, and the Feedback resource action update.

**Sub-phase CWD:** `~/Dev/ash_feedback/`

### Task 2b.1: Verify `AshStorage.Changes.AttachBlob` metadata support

**Files:** read-only investigation.

- [ ] **Step 1: Search AshStorage source for metadata handling on attach**

Run:
```bash
grep -rn "metadata" ~/Dev/ash_storage/lib/ash_storage/changes/ ~/Dev/ash_storage/lib/ash_storage/operations/
grep -rn "AttachBlob" ~/Dev/ash_storage/lib/
```

Read `~/Dev/ash_storage/lib/ash_storage/changes/attach_blob.ex` end-to-end.

- [ ] **Step 2: Decide the offset persistence path**

Document the finding inline in the resource macro (Task 2b.5):

- **If** `AttachBlob` accepts a `metadata:` option that's written onto the attachment row at attach time → use that. The action gets:
  ```elixir
  change {AshStorage.Changes.AttachBlob,
          argument: :audio_clip_blob_id,
          attachment: :audio_clip,
          metadata: %{"audio_start_offset_ms" => arg(:audio_start_offset_ms)}}
  ```
- **Else** → use an `after_action` hook on `:submit` that loads the freshly-attached attachment and updates its metadata column directly via `Ash.Changeset.for_update/3` on the host's Attachment resource. Code shape:
  ```elixir
  change fn changeset, _ctx ->
    Ash.Changeset.after_action(changeset, fn _changeset, feedback ->
      offset = Ash.Changeset.get_argument(changeset, :audio_start_offset_ms)
      blob_id = Ash.Changeset.get_argument(changeset, :audio_clip_blob_id)

      cond do
        is_nil(blob_id) or is_nil(offset) ->
          {:ok, feedback}

        true ->
          feedback = Ash.load!(feedback, :audio_clip)

          attachment_resource = AshFeedback.Config.audio_attachment_resource!()

          feedback.audio_clip
          |> Ash.Changeset.for_update(:update, %{metadata: Map.put(feedback.audio_clip.metadata || %{}, "audio_start_offset_ms", offset)})
          |> Ash.update!(authorize?: false)

          {:ok, feedback}
      end
    end)
  end
  ```

  This requires `AshFeedback.Config.audio_attachment_resource!/0` (added below).

- [ ] **Step 3: Capture the decision in a one-line comment in this plan**

Append to this plan (in the Decisions log section at the end): `Task 2b.1 outcome — <chosen path>`.

No commit needed for this task.

### Task 2b.2: Add `AshFeedback.Config` helper module

**Files:**
- Create: `lib/ash_feedback/config.ex`

- [ ] **Step 1: Write the failing test**

Create `test/ash_feedback/config_test.exs`:

```elixir
defmodule AshFeedback.ConfigTest do
  use ExUnit.Case, async: false

  alias AshFeedback.Config

  test "feedback_resource! returns the configured resource" do
    Application.put_env(:ash_feedback, :feedback_resource, MyApp.FakeResource)
    on_exit(fn -> Application.delete_env(:ash_feedback, :feedback_resource) end)

    assert Config.feedback_resource!() == MyApp.FakeResource
  end

  test "feedback_resource! raises when not configured" do
    Application.delete_env(:ash_feedback, :feedback_resource)

    assert_raise RuntimeError, ~r/config :ash_feedback, :feedback_resource/, fn ->
      Config.feedback_resource!()
    end
  end

  test "audio_attachment_resource! returns the configured resource" do
    Application.put_env(:ash_feedback, :audio_attachment_resource, MyApp.FakeAttachment)
    on_exit(fn -> Application.delete_env(:ash_feedback, :audio_attachment_resource) end)

    assert Config.audio_attachment_resource!() == MyApp.FakeAttachment
  end

  test "audio_attachment_resource! raises with a helpful message when not configured" do
    Application.delete_env(:ash_feedback, :audio_attachment_resource)

    assert_raise RuntimeError, ~r/config :ash_feedback, :audio_attachment_resource/, fn ->
      Config.audio_attachment_resource!()
    end
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `mix test test/ash_feedback/config_test.exs`
Expected: FAIL — `AshFeedback.Config` does not exist.

- [ ] **Step 3: Implement the module**

Create `lib/ash_feedback/config.ex`:

```elixir
defmodule AshFeedback.Config do
  @moduledoc """
  Runtime configuration accessors for ash_feedback. Hosts set these in
  `config/config.exs`:

      config :ash_feedback,
        audio_enabled: true,
        feedback_resource: MyApp.Feedback.Entry,
        audio_attachment_resource: MyApp.Storage.Attachment

  These helpers raise with actionable error messages so misconfigured
  hosts get a clear pointer rather than a cryptic `Ash.Error.Query.NotFound`
  later.
  """

  def feedback_resource! do
    case Application.get_env(:ash_feedback, :feedback_resource) do
      nil ->
        raise """
        ash_feedback: :feedback_resource is not configured.

        Set it in your host config:

            config :ash_feedback, :feedback_resource, MyApp.Feedback.Entry

        Where `MyApp.Feedback.Entry` is the concrete resource that
        `use AshFeedback.Resources.Feedback`.
        """

      resource ->
        resource
    end
  end

  def audio_attachment_resource! do
    case Application.get_env(:ash_feedback, :audio_attachment_resource) do
      nil ->
        raise """
        ash_feedback: :audio_attachment_resource is not configured.

        Set it in your host config:

            config :ash_feedback, :audio_attachment_resource, MyApp.Storage.Attachment

        Where `MyApp.Storage.Attachment` is your AshStorage AttachmentResource.
        """

      resource ->
        resource
    end
  end

  def audio_max_seconds do
    Application.get_env(:ash_feedback, :audio_max_seconds, 300)
  end
end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/ash_feedback/config_test.exs`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ash_feedback/config.ex test/ash_feedback/config_test.exs
git commit -m "feat(config): AshFeedback.Config — feedback_resource!, audio_attachment_resource!, audio_max_seconds"
```

### Task 2b.3: AudioUploadsController.prepare/2

**Files:**
- Create: `lib/ash_feedback/controller/audio_uploads_controller.ex`
- Create: `test/ash_feedback/controller/audio_uploads_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/ash_feedback/controller/audio_uploads_controller_test.exs`:

```elixir
defmodule AshFeedback.Controller.AudioUploadsControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias AshFeedback.Controller.AudioUploadsController

  setup do
    # Configure a test resource that uses AshStorage.Service.Test
    # (in-memory). The test resource is defined in test/support/.
    Application.put_env(:ash_feedback, :audio_enabled, true)
    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.Feedback)
    Application.put_env(:ash_feedback, :audio_attachment_resource, AshFeedback.Test.Attachment)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :audio_enabled)
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:ash_feedback, :audio_attachment_resource)
    end)

    :ok
  end

  test "POST /prepare returns blob_id, url, method, fields" do
    conn =
      conn(:post, "/prepare", %{
        "filename" => "demo.webm",
        "content_type" => "audio/webm",
        "byte_size" => 12345
      })
      |> put_req_header("content-type", "application/json")

    conn = AudioUploadsController.call(conn, AudioUploadsController.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["blob_id"])
    assert is_binary(body["url"])
    assert body["method"] in ["put", "post"]
    assert is_map(body["fields"])
  end

  test "POST /prepare returns 422 on invalid input (missing filename)" do
    conn =
      conn(:post, "/prepare", %{"content_type" => "audio/webm", "byte_size" => 1})
      |> put_req_header("content-type", "application/json")

    conn = AudioUploadsController.call(conn, AudioUploadsController.init([]))

    assert conn.status == 422
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end
end
```

The test references `AshFeedback.Test.Feedback` and `AshFeedback.Test.Attachment` — these are test fixtures that get created in Task 2b.6 (resource macro update). For this task, write a minimal stub of just the test fixtures sufficient for the controller test to run. Path: `test/support/test_resources.ex`. Use `AshStorage.Service.Test` (in-memory) so no external service is needed.

- [ ] **Step 2: Run the test to confirm it fails**

Run: `mix test test/ash_feedback/controller/audio_uploads_controller_test.exs`
Expected: FAIL — `AshFeedback.Controller.AudioUploadsController` does not exist.

- [ ] **Step 3: Implement the controller**

Create `lib/ash_feedback/controller/audio_uploads_controller.ex`:

```elixir
defmodule AshFeedback.Controller.AudioUploadsController do
  @moduledoc """
  Mints presigned URLs for direct upload of audio narration blobs
  via AshStorage. POST `/prepare` returns the URL + a Blob row id;
  the client PUTs (or POSTs) bytes to that URL and submits feedback
  with `extras: { audio_clip_blob_id: <id> }`.
  """

  use Phoenix.Controller, formats: [:json]

  def prepare(conn, %{"filename" => filename} = params) do
    feedback_resource = AshFeedback.Config.feedback_resource!()
    content_type = Map.get(params, "content_type", "application/octet-stream")
    byte_size = Map.get(params, "byte_size", 0)

    case AshStorage.Operations.prepare_direct_upload(
           feedback_resource,
           :audio_clip,
           filename: filename,
           content_type: content_type,
           byte_size: byte_size
         ) do
      {:ok, %{blob: blob, url: url, method: method} = info} ->
        json(conn, %{
          blob_id: blob.id,
          url: url,
          method: to_string(method),
          fields: Map.get(info, :fields, %{})
        })

      {:error, error} ->
        conn
        |> put_status(422)
        |> json(%{error: Exception.message(error)})
    end
  end

  def prepare(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "filename is required"})
  end
end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/ash_feedback/controller/audio_uploads_controller_test.exs`
Expected: 2 tests pass. If they fail because `AshFeedback.Test.Feedback` isn't fully defined yet, write the minimal stub (an Ash resource using `AshStorage.Service.Test`) inline in `test/support/test_resources.ex`:

```elixir
defmodule AshFeedback.Test.Repo do
  use Ecto.Repo, otp_app: :ash_feedback, adapter: Ecto.Adapters.Postgres
end

defmodule AshFeedback.Test.Domain do
  use Ash.Domain
  resources do
    resource AshFeedback.Test.Blob
    resource AshFeedback.Test.Attachment
    resource AshFeedback.Test.Feedback
  end
end

# Minimal stub Blob, Attachment, and Feedback that satisfy AshStorage's
# expectations using AshStorage.Service.Test as the backend. Bring in
# patterns from ~/Dev/ash_storage/dev/resources/{blob,attachment,post}.ex
# adapted to the AshFeedback.Test namespace. See Task 2b.6 for the
# real resource macro update.
```

(Detailed test resource code lives in 2b.6 because that's where the macro change makes them work end-to-end. For 2b.3 alone, a minimal Blob + Attachment + a non-AshFeedback test Feedback that just declares `use AshStorage` and `has_one_attached :audio_clip` is sufficient.)

- [ ] **Step 5: Commit**

```bash
git add lib/ash_feedback/controller/audio_uploads_controller.ex test/ash_feedback/controller/audio_uploads_controller_test.exs test/support/test_resources.ex
git commit -m "feat(audio): AudioUploadsController.prepare/2

POST /audio_uploads/prepare returns { blob_id, url, method, fields }
via AshStorage.Operations.prepare_direct_upload. Validates required
filename arg; returns 422 on missing input or AshStorage errors."
```

### Task 2b.4: AshFeedback.Router macro

**Files:**
- Create: `lib/ash_feedback/router.ex`
- Create: `test/ash_feedback/router_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/ash_feedback/router_test.exs`:

```elixir
defmodule AshFeedback.RouterTest do
  use ExUnit.Case

  defmodule TestRouter do
    use Phoenix.Router
    require AshFeedback.Router
    AshFeedback.Router.audio_routes()
  end

  test "audio_routes/0 mounts POST /audio_uploads/prepare" do
    routes = TestRouter.__routes__()
    route = Enum.find(routes, fn r -> r.path == "/audio_uploads/prepare" end)

    assert route
    assert route.verb == :post
    assert route.plug == AshFeedback.Controller.AudioUploadsController
    assert route.plug_opts == :prepare
  end

  defmodule TestRouterCustomPath do
    use Phoenix.Router
    require AshFeedback.Router
    AshFeedback.Router.audio_routes(path: "/api/audio")
  end

  test "audio_routes(path: ...) supports a custom mount path" do
    routes = TestRouterCustomPath.__routes__()
    route = Enum.find(routes, fn r -> r.path == "/api/audio/prepare" end)

    assert route
    assert route.verb == :post
  end
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `mix test test/ash_feedback/router_test.exs`
Expected: FAIL — `AshFeedback.Router` does not exist.

- [ ] **Step 3: Implement the macro**

Create `lib/ash_feedback/router.ex`:

```elixir
defmodule AshFeedback.Router do
  @moduledoc """
  Router macros that mount ash_feedback's HTTP surface in a host's
  Phoenix router. Mirror `PhoenixReplay.Router`'s pattern: hosts
  call the macro inside their own scope after `pipe_through`.

      scope "/", MyAppWeb do
        pipe_through :browser
        AshFeedback.Router.audio_routes()
      end
  """

  defmacro audio_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/audio_uploads")

    quote bind_quoted: [path: path] do
      scope path, AshFeedback.Controller do
        post "/prepare", AudioUploadsController, :prepare
      end
    end
  end
end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/ash_feedback/router_test.exs`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ash_feedback/router.ex test/ash_feedback/router_test.exs
git commit -m "feat(router): AshFeedback.Router.audio_routes/1

Macro mounts POST /audio_uploads/prepare under the host's scope.
Optional :path keyword for a custom mount prefix."
```

### Task 2b.5: Feedback resource — `:submit` action gains audio args + AttachBlob change

**Files:**
- Modify: `lib/ash_feedback/resources/feedback.ex` — extend the `:submit` action inside the `audio_enabled?` quote block.

- [ ] **Step 1: Add audio arguments + AttachBlob change to `:submit`**

In `lib/ash_feedback/resources/feedback.ex`, wrap the audio-specific action additions in a conditional injected into the `actions` block. The current action code lives inside the outer `quote location: :keep` block. Add the audio-specific arguments + change inside an `unquote` that emits them only when `audio_enabled?` is true:

Find the `:submit` action definition (around line 386):

```elixir
create :submit do
  accept [
    :session_id,
    :description,
    :severity,
    :metadata,
    :identity,
    :events_s3_key
  ]

  upsert? true
  upsert_identity :unique_session_id

  change fn changeset, _ctx ->
    # ...existing environment coercion...
  end
end
```

Update it to conditionally add the audio arguments + change (the `:submit` definition lives inside the same outer `quote` block, so we use a nested `unquote` for the conditional):

```elixir
create :submit do
  accept [
    :session_id,
    :description,
    :severity,
    :metadata,
    :identity,
    :events_s3_key
  ]

  upsert? true
  upsert_identity :unique_session_id

  unquote(
    if audio_enabled? do
      quote do
        argument :audio_clip_blob_id, :uuid, allow_nil?: true
        argument :audio_start_offset_ms, :integer, allow_nil?: true

        change {AshStorage.Changes.AttachBlob,
                argument: :audio_clip_blob_id,
                attachment: :audio_clip}
      end
    end
  )

  change fn changeset, _ctx ->
    # ...existing environment coercion (unchanged)...
  end

  unquote(
    if audio_enabled? do
      # Persist audio_start_offset_ms onto attachment.metadata.
      # Path chosen in Task 2b.1: <fill in based on outcome>.
      #
      # Path A (AttachBlob accepts :metadata option):
      #   The argument-keyed change handles offset persistence; this
      #   block is a no-op.
      #
      # Path B (after_action hook):
      quote do
        change fn changeset, _ctx ->
          Ash.Changeset.after_action(changeset, fn _cs, feedback ->
            offset = Ash.Changeset.get_argument(changeset, :audio_start_offset_ms)
            blob_id = Ash.Changeset.get_argument(changeset, :audio_clip_blob_id)

            if is_binary(blob_id) and is_integer(offset) do
              feedback = Ash.load!(feedback, :audio_clip)

              if feedback.audio_clip do
                attachment_resource = AshFeedback.Config.audio_attachment_resource!()

                feedback.audio_clip
                |> Ash.Changeset.for_update(:update, %{
                  metadata: Map.put(feedback.audio_clip.metadata || %{}, "audio_start_offset_ms", offset)
                })
                |> Ash.update!(authorize?: false)
              end
            end

            {:ok, feedback}
          end)
        end
      end
    end
  )
end
```

The choice between Path A and Path B is wired by the Task 2b.1 outcome — replace the entire conditional block with whichever path applies.

- [ ] **Step 2: Update the existing macro test fixture (if any)**

Check `test/ash_feedback/` for an existing audio-disabled fixture (Phase 1's tests) and confirm it still compiles. Existing tests should continue to pass with audio disabled (default).

Run: `mix test`
Expected: all 17 existing tests pass.

- [ ] **Step 3: Add an audio-enabled compile fixture test**

Create or extend `test/ash_feedback/resources/feedback_audio_test.exs`:

```elixir
defmodule AshFeedback.Resources.FeedbackAudioTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:ash_feedback, :audio_enabled, true)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :audio_enabled)
      :code.purge(AshFeedback.Test.Feedback)
      :code.delete(AshFeedback.Test.Feedback)
    end)

    :ok
  end

  test "audio-enabled fixture compiles and :submit accepts audio args" do
    # The fixture is defined in test/support/test_resources.ex; reload
    # to pick up the audio_enabled? compile-time flag.
    Code.compile_file("test/support/test_resources.ex")

    action = Ash.Resource.Info.action(AshFeedback.Test.Feedback, :submit)
    arg_names = Enum.map(action.arguments, & &1.name)

    assert :audio_clip_blob_id in arg_names
    assert :audio_start_offset_ms in arg_names
  end
end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/ash_feedback/resources/feedback_audio_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ash_feedback/resources/feedback.ex test/ash_feedback/resources/feedback_audio_test.exs test/support/test_resources.ex
git commit -m "feat(audio): :submit action accepts audio args + AttachBlob

When audio_enabled? is true at compile time, the :submit create action
gains :audio_clip_blob_id + :audio_start_offset_ms arguments plus the
AshStorage.Changes.AttachBlob change wiring the blob to the audio_clip
attachment. Offset persistence path: <Task 2b.1 outcome>."
```

### Task 2b.6: AshFeedback.Storage extras handler

**Files:**
- Modify: `lib/ash_feedback/storage.ex` (the `submit/3` callback)

- [ ] **Step 1: Write the failing test**

Create or extend `test/ash_feedback/storage_test.exs`:

```elixir
test "submit/3 forwards extras audio_clip_blob_id and audio_start_offset_ms" do
  Application.put_env(:ash_feedback, :audio_enabled, true)
  Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.Feedback)
  Application.put_env(:ash_feedback, :audio_attachment_resource, AshFeedback.Test.Attachment)

  blob = create_test_blob()
  params = %{
    "description" => "test",
    "extras" => %{
      "audio_clip_blob_id" => blob.id,
      "audio_start_offset_ms" => 1234
    }
  }

  {:ok, feedback} = AshFeedback.Storage.submit("test-session", params, %{})

  feedback = Ash.load!(feedback, :audio_clip)
  assert feedback.audio_clip
  assert feedback.audio_clip.blob_id == blob.id
end
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `mix test test/ash_feedback/storage_test.exs`
Expected: FAIL — current `submit/3` doesn't extract extras.

- [ ] **Step 3: Update `submit/3` to extract and forward extras**

In `lib/ash_feedback/storage.ex`, change the `submit/3` body. Find:

```elixir
@impl true
def submit(session_id, params, identity) do
  resource = resource!()

  attrs = %{
    session_id: session_id,
    description: Map.get(params, "description"),
    severity: coerce_severity(Map.get(params, "severity")),
    metadata: Map.get(params, "metadata") || %{},
    identity: coerce_identity(identity)
  }

  resource
  |> Ash.Changeset.for_create(:submit, attrs, authorize?: false)
  |> Ash.create()
  |> case do
    {:ok, record} -> {:ok, record}
    {:error, changeset} -> {:error, changeset}
  end
end
```

Update to:

```elixir
@impl true
def submit(session_id, params, identity) do
  resource = resource!()
  extras = Map.get(params, "extras") || %{}

  attrs = %{
    session_id: session_id,
    description: Map.get(params, "description"),
    severity: coerce_severity(Map.get(params, "severity")),
    metadata: Map.get(params, "metadata") || %{},
    identity: coerce_identity(identity)
  }

  attrs =
    case Map.get(extras, "audio_clip_blob_id") do
      nil -> attrs
      blob_id -> Map.put(attrs, :audio_clip_blob_id, blob_id)
    end

  attrs =
    case Map.get(extras, "audio_start_offset_ms") do
      nil -> attrs
      offset when is_integer(offset) -> Map.put(attrs, :audio_start_offset_ms, offset)
      _ -> attrs
    end

  resource
  |> Ash.Changeset.for_create(:submit, attrs, authorize?: false)
  |> Ash.create()
  |> case do
    {:ok, record} -> {:ok, record}
    {:error, changeset} -> {:error, changeset}
  end
end
```

- [ ] **Step 4: Run the test**

Run: `mix test test/ash_feedback/storage_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full ash_feedback test suite**

Run: `mix test`
Expected: all tests pass (17 existing + new ones).

- [ ] **Step 6: Commit**

```bash
git add lib/ash_feedback/storage.ex test/ash_feedback/storage_test.exs
git commit -m "feat(audio): Storage adapter extracts audio extras

submit/3 reads audio_clip_blob_id + audio_start_offset_ms out of
params[\"extras\"] and forwards them as :submit action arguments.
Audio-disabled hosts unaffected — extras are silently dropped if the
action doesn't declare matching arguments."
```

### Task 2b.7: Audio recorder JS — addon registration + state machine

**Files:**
- Create: `priv/static/assets/audio_recorder.js`

- [ ] **Step 1: Write the recorder JS**

Create `priv/static/assets/audio_recorder.js`:

```js
// ash_feedback audio recorder — phoenix_replay panel addon.
//
// Self-registers via window.PhoenixReplay.registerPanelAddon once
// PhoenixReplay is available. Captures audio via MediaRecorder, uploads
// to AshStorage via the prepare endpoint + a presigned PUT, returns
// { audio_clip_blob_id, audio_start_offset_ms } via beforeSubmit.
(function () {
  "use strict";

  const PREPARE_PATH_ATTR = "data-prepare-path";
  const MAX_SECONDS_ATTR = "data-audio-max-seconds";
  const DEFAULT_PREPARE_PATH = "/audio_uploads/prepare";
  const DEFAULT_MAX_SECONDS = 300;

  const CODECS = [
    { mime: "audio/webm; codecs=opus", ext: "webm" },
    { mime: "audio/mp4; codecs=mp4a.40.2", ext: "mp4" },
  ];

  function pickCodec() {
    if (typeof MediaRecorder === "undefined") return null;
    for (const c of CODECS) {
      if (MediaRecorder.isTypeSupported(c.mime)) return c;
    }
    return null;
  }

  function fmtDuration(ms) {
    const total = Math.floor(ms / 1000);
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${String(s).padStart(2, "0")}`;
  }

  function csrfToken() {
    const el = document.querySelector("meta[name='csrf-token']");
    return el ? el.getAttribute("content") : null;
  }

  function buildAddon() {
    return {
      id: "audio",
      slot: "form-top",
      mount(ctx) {
        const codec = pickCodec();
        const preparePath = ctx.slotEl.getAttribute(PREPARE_PATH_ATTR) || DEFAULT_PREPARE_PATH;
        const maxSeconds = parseInt(ctx.slotEl.getAttribute(MAX_SECONDS_ATTR) || DEFAULT_MAX_SECONDS, 10);

        // State: "idle" | "recording" | "done" | "denied" | "unsupported"
        let state = codec ? "idle" : "unsupported";
        let mediaStream = null;
        let recorder = null;
        let chunks = [];
        let blob = null;
        let startedAtMs = null;
        let offsetMs = null;
        let timerHandle = null;

        const wrapper = document.createElement("div");
        wrapper.className = "phx-replay-audio-addon";
        ctx.slotEl.appendChild(wrapper);

        function render() {
          wrapper.innerHTML = "";
          if (state === "unsupported") {
            wrapper.innerHTML = `<button type="button" class="phx-replay-audio-mic" disabled title="Audio recording not supported in this browser">🎙 Voice note (unsupported)</button>`;
            return;
          }
          if (state === "denied") {
            wrapper.innerHTML = `<div class="phx-replay-audio-notice">Microphone permission denied. You can still submit without audio.</div>`;
            return;
          }
          if (state === "idle") {
            const btn = document.createElement("button");
            btn.type = "button";
            btn.className = "phx-replay-audio-mic";
            btn.textContent = "🎙 Record voice note";
            btn.addEventListener("click", () => startRecording());
            wrapper.appendChild(btn);
            return;
          }
          if (state === "recording") {
            const elapsed = Date.now() - startedAtMs;
            const remainingMs = (maxSeconds * 1000) - elapsed;
            const warn = remainingMs <= 30000 ? `<span class="phx-replay-audio-warn"> · ${Math.max(0, Math.ceil(remainingMs / 1000))}s left</span>` : "";
            wrapper.innerHTML = `<button type="button" class="phx-replay-audio-stop">■ Stop · ${fmtDuration(elapsed)}</button>${warn}`;
            wrapper.querySelector(".phx-replay-audio-stop").addEventListener("click", () => stopRecording());
            return;
          }
          if (state === "done") {
            const url = URL.createObjectURL(blob);
            const dur = blob.size > 0 ? "" : "";  // duration is shown via the audio element
            wrapper.innerHTML = `
              <audio controls src="${url}" class="phx-replay-audio-preview"></audio>
              <button type="button" class="phx-replay-audio-rerecord">✕ Re-record</button>
            `;
            wrapper.querySelector(".phx-replay-audio-rerecord").addEventListener("click", () => {
              URL.revokeObjectURL(url);
              blob = null;
              startedAtMs = null;
              offsetMs = null;
              state = "idle";
              render();
            });
            return;
          }
        }

        function tick() {
          if (state !== "recording") return;
          const elapsed = Date.now() - startedAtMs;
          if (elapsed >= maxSeconds * 1000) {
            stopRecording();
            return;
          }
          render();
          timerHandle = window.setTimeout(tick, 250);
        }

        async function startRecording() {
          try {
            mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
          } catch (err) {
            state = "denied";
            render();
            return;
          }

          chunks = [];
          recorder = new MediaRecorder(mediaStream, { mimeType: codec.mime });
          recorder.ondataavailable = (e) => {
            if (e.data && e.data.size > 0) chunks.push(e.data);
          };
          recorder.onstop = () => {
            blob = new Blob(chunks, { type: codec.mime });
            mediaStream.getTracks().forEach((t) => t.stop());
            mediaStream = null;
            state = "done";
            render();
          };
          recorder.start();

          startedAtMs = Date.now();
          const sessionStarted = ctx.sessionStartedAtMs ? ctx.sessionStartedAtMs() : null;
          offsetMs = sessionStarted ? Math.max(0, startedAtMs - sessionStarted) : 0;

          state = "recording";
          render();
          tick();
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

        ctx.onPanelClose(() => {
          if (mediaStream) mediaStream.getTracks().forEach((t) => t.stop());
          if (timerHandle) window.clearTimeout(timerHandle);
          mediaStream = null;
          recorder = null;
          chunks = [];
          blob = null;
          startedAtMs = null;
          offsetMs = null;
          state = codec ? "idle" : "unsupported";
        });

        async function beforeSubmit(_args) {
          if (state !== "done" || !blob) return {};

          // 1. Prepare
          const prepareRes = await fetch(preparePath, {
            method: "POST",
            credentials: "same-origin",
            headers: {
              "content-type": "application/json",
              ...(csrfToken() ? { "x-csrf-token": csrfToken() } : {}),
            },
            body: JSON.stringify({
              filename: `voice-note.${codec.ext}`,
              content_type: codec.mime,
              byte_size: blob.size,
            }),
          });
          if (!prepareRes.ok) {
            throw new Error(`Audio prepare failed: HTTP ${prepareRes.status}`);
          }
          const { blob_id, url, method, fields } = await prepareRes.json();

          // 2. Upload
          if (method === "post") {
            const fd = new FormData();
            for (const [k, v] of Object.entries(fields || {})) fd.append(k, v);
            fd.append("file", blob);
            const up = await fetch(url, { method: "POST", body: fd });
            if (!up.ok) throw new Error(`Audio upload failed: HTTP ${up.status}`);
          } else {
            const up = await fetch(url, {
              method: "PUT",
              body: blob,
              headers: { "content-type": codec.mime },
            });
            if (!up.ok) throw new Error(`Audio upload failed: HTTP ${up.status}`);
          }

          return {
            extras: {
              audio_clip_blob_id: blob_id,
              audio_start_offset_ms: offsetMs,
            },
          };
        }

        render();
        return { beforeSubmit };
      },
    };
  }

  function tryRegister() {
    if (window.PhoenixReplay && typeof window.PhoenixReplay.registerPanelAddon === "function") {
      window.PhoenixReplay.registerPanelAddon(buildAddon());
      return true;
    }
    return false;
  }

  if (!tryRegister()) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", () => {
        if (!tryRegister()) {
          // PhoenixReplay loaded after DOMContentLoaded — poll briefly.
          let attempts = 0;
          const t = setInterval(() => {
            attempts++;
            if (tryRegister() || attempts > 20) clearInterval(t);
          }, 100);
        }
      });
    } else {
      let attempts = 0;
      const t = setInterval(() => {
        attempts++;
        if (tryRegister() || attempts > 20) clearInterval(t);
      }, 100);
    }
  }
})();
```

- [ ] **Step 2: Verify the file syntactically loads**

Run: `node -c priv/static/assets/audio_recorder.js`
Expected: no output (success).

- [ ] **Step 3: Add a small CSS file or extend the existing one**

If `priv/static/assets/` already has a CSS file for ash_feedback (check first), append. Else create `priv/static/assets/audio_recorder.css`:

```css
.phx-replay-audio-addon { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 0; }
.phx-replay-audio-mic, .phx-replay-audio-stop, .phx-replay-audio-rerecord {
  font: inherit; padding: 0.4rem 0.7rem; border: 1px solid #888; border-radius: 4px;
  background: #fff; cursor: pointer;
}
.phx-replay-audio-mic[disabled] { opacity: 0.5; cursor: not-allowed; }
.phx-replay-audio-warn { color: #c33; font-size: 0.85em; }
.phx-replay-audio-notice { font-size: 0.85em; color: #666; }
.phx-replay-audio-preview { width: 200px; height: 32px; }
```

- [ ] **Step 4: Commit**

```bash
git add priv/static/assets/audio_recorder.js priv/static/assets/audio_recorder.css
git commit -m "feat(audio): recorder JS + CSS

Pure ES module, no build step. Self-registers via
PhoenixReplay.registerPanelAddon. Codec probe (webm/opus → mp4 fallback),
state machine (idle/recording/done/denied/unsupported), beforeSubmit
prepares + uploads to presigned URL and returns extras."
```

---

## Sub-phase 2c — Firkin round-trip test

**Sub-phase goal:** End-to-end test of the full prepare → PUT bytes → submit → verify-attached flow against an in-process S3-compatible Plug.

**Sub-phase CWD:** `~/Dev/ash_feedback/`

### Task 2c.1: Add Firkin as a test-only dep

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the dep**

In `mix.exs`'s `deps/0`, add:

```elixir
{:firkin, "~> 0.1", only: :test},
```

- [ ] **Step 2: Fetch + compile**

Run: `mix deps.get && mix deps.compile firkin`
Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps(test): add firkin for in-process S3 testing"
```

### Task 2c.2: Test support — start Firkin in a Case template

**Files:**
- Create: `test/support/firkin_case.ex`

- [ ] **Step 1: Write the case template**

Create `test/support/firkin_case.ex`:

```elixir
defmodule AshFeedback.FirkinCase do
  @moduledoc """
  Starts an in-process Firkin S3-compatible Plug on a free port for the
  duration of the test, configures AshStorage.Service.S3 to point at
  it, and exposes the URL + bucket name via test context.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import AshFeedback.FirkinCase
    end
  end

  setup_all do
    bucket = "ash-feedback-test-#{System.unique_integer([:positive])}"

    # Firkin's exact API — verify by reading firkin's docs on first run.
    # Conceptual setup:
    {:ok, _pid} = Firkin.start(backend: {Firkin.Backend.InMemory, [bucket: bucket]}, port: 0)
    port = Firkin.port()
    endpoint_url = "http://localhost:#{port}"

    Application.put_env(:ash_storage, AshFeedback.Test.Blob,
      service:
        {AshStorage.Service.S3,
         bucket: bucket,
         region: "us-east-1",
         endpoint_url: endpoint_url,
         access_key_id: "test",
         secret_access_key: "test",
         presigned: true}
    )

    on_exit(fn ->
      Application.delete_env(:ash_storage, AshFeedback.Test.Blob)
    end)

    %{firkin_url: endpoint_url, bucket: bucket}
  end
end
```

The Firkin API specifics (`Firkin.start/1` shape, `Firkin.port/0`) need to match the actual library — read `mix help firkin` or `~/Dev/ash_feedback/deps/firkin/README.md` after `mix deps.get` to confirm. If the API differs, adapt this skeleton.

- [ ] **Step 2: Hook into `test_helper.exs`**

Ensure `test/test_helper.exs` requires the support file:

```elixir
Code.require_file("support/firkin_case.ex", __DIR__)
```

- [ ] **Step 3: Commit**

```bash
git add test/support/firkin_case.ex test/test_helper.exs
git commit -m "test: AshFeedback.FirkinCase — in-process S3 for round-trip"
```

### Task 2c.3: Round-trip test

**Files:**
- Create: `test/ash_feedback/audio_round_trip_test.exs`

- [ ] **Step 1: Write the test**

Create `test/ash_feedback/audio_round_trip_test.exs`:

```elixir
defmodule AshFeedback.AudioRoundTripTest do
  use AshFeedback.FirkinCase, async: false

  setup do
    Application.put_env(:ash_feedback, :audio_enabled, true)
    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.Feedback)
    Application.put_env(:ash_feedback, :audio_attachment_resource, AshFeedback.Test.Attachment)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :audio_enabled)
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:ash_feedback, :audio_attachment_resource)
    end)

    :ok
  end

  test "prepare → PUT bytes → submit → blob attached + offset persisted", %{firkin_url: _url} do
    # 1. Prepare a direct upload via the controller path
    {:ok, %{blob: blob, url: presigned_url, method: method}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.Feedback,
        :audio_clip,
        filename: "voice.webm",
        content_type: "audio/webm; codecs=opus",
        byte_size: 12
      )

    # 2. Upload bytes to the presigned URL
    response =
      Req.request!(
        method: method,
        url: presigned_url,
        body: "fake-bytes-x",
        headers: [{"content-type", "audio/webm; codecs=opus"}]
      )

    assert response.status in 200..299

    # 3. Submit the feedback with audio extras (via the Storage adapter)
    {:ok, feedback} =
      AshFeedback.Storage.submit(
        "session-#{System.unique_integer([:positive])}",
        %{
          "description" => "test",
          "extras" => %{
            "audio_clip_blob_id" => blob.id,
            "audio_start_offset_ms" => 1234
          }
        },
        %{}
      )

    # 4. Verify the attachment + offset
    feedback = Ash.load!(feedback, audio_clip: [:metadata, :blob])
    assert feedback.audio_clip
    assert feedback.audio_clip.blob.id == blob.id
    assert feedback.audio_clip.metadata["audio_start_offset_ms"] == 1234
  end
end
```

The test uses `Req` for the HTTP PUT. If `Req` isn't already in deps, add `{:req, "~> 0.5", only: :test}` in 2c.1.

- [ ] **Step 2: Run the test**

Run: `mix test test/ash_feedback/audio_round_trip_test.exs --trace`
Expected: PASS. If it fails on the offset persistence assertion, the Task 2b.1 path may need refinement; iterate on the after_action hook or AttachBlob option until green.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: all 17 existing tests + new tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/ash_feedback/audio_round_trip_test.exs
git commit -m "test(audio): Firkin-backed round-trip

Exercises the real S3 contract: prepare_direct_upload mints a presigned
URL pointing at Firkin, the test PUTs bytes, then submits feedback with
extras and asserts the blob is attached + offset lands on attachment
metadata."
```

### Task 2c.4: ash_feedback CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the entry**

Under the unreleased / Phase 2 section:

```markdown
### Added

- Audio narration recorder (Phase 2) — `priv/static/assets/audio_recorder.js`
  registers a `phoenix_replay` panel addon. Hosts include the script tag in
  their root layout. Codec probe selects `audio/webm; codecs=opus` (primary)
  or `audio/mp4` (Safari fallback). Permission denial renders inline; the
  rest of the form remains usable.
- `POST /audio_uploads/prepare` controller + `AshFeedback.Router.audio_routes/1`
  macro for hosts to mount in their router.
- `Feedback.submit` action accepts `:audio_clip_blob_id` and
  `:audio_start_offset_ms` arguments when audio is enabled. The
  `AshStorage.Changes.AttachBlob` change wires the blob; offset persists
  on the attachment's metadata map.
- `AshFeedback.Config` — `feedback_resource!/0`, `audio_attachment_resource!/0`,
  `audio_max_seconds/0`.
- Firkin-backed round-trip test (in-process S3-compatible Plug) — exercises
  the real prepare → PUT → attach contract without docker.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): audio narration Phase 2 entry"
```

---

## Sub-phase 2d — Demo wiring + manual smoke

**Sub-phase goal:** This demo host concretizes the AshStorage Blob/Attachment resources, mounts the Disk service + plug + router macro, loads the recorder JS, and proves the round-trip in a browser.

**Sub-phase CWD:** `~/Dev/ash_feedback_demo/` (= current CWD)

### Task 2d.1: Add `ash_storage` to demo deps

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the dep**

In `deps/0`:

```elixir
{:ash_storage, github: "ash-project/ash_storage"},
```

(The `ash_storage` package is pre-Hex per memory `reference_ash_storage_state.md`; use the github source.)

- [ ] **Step 2: Fetch + compile**

Run: `mix deps.get && mix deps.compile ash_storage`
Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: ash_storage (github source)"
```

### Task 2d.2: Host AshStorage Blob + Attachment resources

**Files:**
- Create: `lib/ash_feedback_demo/storage/blob.ex`
- Create: `lib/ash_feedback_demo/storage/attachment.ex`
- Modify: `lib/ash_feedback_demo/feedback.ex` (or whatever the host's Feedback domain module is — verify path) — add the two storage resources to the domain.

- [ ] **Step 1: Read the reference shapes**

```bash
cat ~/Dev/ash_storage/dev/resources/blob.ex
cat ~/Dev/ash_storage/dev/resources/attachment.ex
```

- [ ] **Step 2: Adapt the Blob resource**

Create `lib/ash_feedback_demo/storage/blob.ex` based on the dev/resources/blob.ex pattern, adapted to:
- Module name `AshFeedbackDemo.Storage.Blob`
- Use `AshFeedbackDemo.Repo`
- Belong to `AshFeedbackDemo.Feedback` (or whatever the demo's domain is)
- Table name `ash_feedback_demo_blobs`

Code shape (adapt actual content from the reference):

```elixir
defmodule AshFeedbackDemo.Storage.Blob do
  use Ash.Resource,
    domain: AshFeedbackDemo.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.BlobResource]

  postgres do
    table "ash_feedback_demo_blobs"
    repo AshFeedbackDemo.Repo
  end

  blob do
    # service config lives in config.exs
  end

  # ... attributes, actions per the reference
end
```

- [ ] **Step 3: Adapt the Attachment resource**

Same approach for `lib/ash_feedback_demo/storage/attachment.ex`:

```elixir
defmodule AshFeedbackDemo.Storage.Attachment do
  use Ash.Resource,
    domain: AshFeedbackDemo.Feedback,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.AttachmentResource]

  postgres do
    table "ash_feedback_demo_attachments"
    repo AshFeedbackDemo.Repo
  end

  attachment do
    blob_resource AshFeedbackDemo.Storage.Blob
  end
end
```

- [ ] **Step 4: Register both in the domain**

In `lib/ash_feedback_demo/feedback.ex`:

```elixir
resources do
  resource AshFeedbackDemo.Feedback.Entry
  resource AshFeedbackDemo.Storage.Blob
  resource AshFeedbackDemo.Storage.Attachment
end
```

- [ ] **Step 5: Generate migrations**

Run: `mix ash.codegen audio_storage`
Expected: a new migration file under `priv/repo/migrations/` creating both tables.

- [ ] **Step 6: Run migrations**

Run: `mix ecto.migrate`
Expected: both tables created.

- [ ] **Step 7: Commit**

```bash
git add lib/ash_feedback_demo/storage/ lib/ash_feedback_demo/feedback.ex priv/repo/migrations/*audio_storage*
git commit -m "feat(demo): host AshStorage Blob + Attachment resources"
```

### Task 2d.3: Wire the demo's Feedback resource to the audio attachment

**Files:**
- Modify: `lib/ash_feedback_demo/feedback/entry.ex` (or wherever `use AshFeedback.Resources.Feedback` lives)

- [ ] **Step 1: Pass `audio_attachment_resource:`**

```elixir
use AshFeedback.Resources.Feedback,
  domain: AshFeedbackDemo.Feedback,
  repo: AshFeedbackDemo.Repo,
  audio_attachment_resource: AshFeedbackDemo.Storage.Attachment
```

- [ ] **Step 2: Compile to verify**

Run: `mix compile --force`
Expected: clean compile. If `audio_enabled` isn't set yet (next task), the macro skips audio injection — no error.

- [ ] **Step 3: Commit**

```bash
git add lib/ash_feedback_demo/feedback/entry.ex
git commit -m "feat(demo): pass audio_attachment_resource to Feedback macro"
```

### Task 2d.4: Enable audio + register the resource

**Files:**
- Modify: `config/config.exs`

- [ ] **Step 1: Add audio config**

```elixir
config :ash_feedback,
  audio_enabled: true,
  feedback_resource: AshFeedbackDemo.Feedback.Entry,
  audio_attachment_resource: AshFeedbackDemo.Storage.Attachment,
  audio_max_seconds: 300
```

- [ ] **Step 2: Force-compile to apply the compile-time flag**

Run: `mix compile --force`
Expected: `AshFeedbackDemo.Feedback.Entry` recompiles with the AshStorage extension and `:audio_clip` attachment.

- [ ] **Step 3: Commit**

```bash
git add config/config.exs
git commit -m "feat(demo): config :ash_feedback, audio_enabled: true"
```

### Task 2d.5: Configure Disk service + endpoint plug

**Files:**
- Modify: `config/dev.exs`
- Modify: `lib/ash_feedback_demo_web/endpoint.ex`
- Modify: `.gitignore`

- [ ] **Step 1: Add Disk service config**

In `config/dev.exs`:

```elixir
config :ash_storage, AshFeedbackDemo.Storage.Blob,
  service:
    {AshStorage.Service.Disk,
     root: Path.join(File.cwd!(), "tmp/uploads"),
     base_url: "http://localhost:4006",
     direct_upload: true}
```

- [ ] **Step 2: Mount the Disk plug in the endpoint**

Read `~/Dev/ash_storage/lib/ash_storage/service/disk.ex` to identify the actual plug module name. The plan assumes `AshStorage.Service.Disk.Plug` but verify. Once confirmed, in `lib/ash_feedback_demo_web/endpoint.ex`, before `plug AshFeedbackDemoWeb.Router`:

```elixir
plug Plug.Static,
  at: "/disk",
  from: Path.join(File.cwd!(), "tmp/uploads"),
  gzip: false  # serves stored objects on GET
```

If AshStorage's Disk service exposes a dedicated upload-handling plug (not just `Plug.Static`), use that instead. The Plug must accept PUT and write the body to disk under the same `root`.

- [ ] **Step 3: Gitignore the upload directory**

Append to `.gitignore`:

```
/tmp/uploads/
```

- [ ] **Step 4: Restart the app server (Tidewave)**

Use the Tidewave restart tool with `reason: "deps_changed"`.

- [ ] **Step 5: Commit**

```bash
git add config/dev.exs lib/ash_feedback_demo_web/endpoint.ex .gitignore
git commit -m "feat(demo): AshStorage.Service.Disk + endpoint plug"
```

### Task 2d.6: Mount audio_routes in the router

**Files:**
- Modify: `lib/ash_feedback_demo_web/router.ex`

- [ ] **Step 1: Mount the macro**

Inside the existing browser scope (find the scope that already pipes through `:browser`):

```elixir
scope "/" do
  pipe_through :browser
  AshFeedback.Router.audio_routes()
end
```

If the demo router already has nested scopes that conflict (per memory `feedback_phoenix_router_alias_accumulation.md`, alias accumulation is a known gotcha), mount it in a **separate non-aliased scope** to avoid prefix accumulation:

```elixir
scope "/" do
  pipe_through :browser
  AshFeedback.Router.audio_routes()
end
```

- [ ] **Step 2: Verify the route is registered**

Run: `mix phx.routes | grep audio_uploads`
Expected: `POST  /audio_uploads/prepare  AshFeedback.Controller.AudioUploadsController :prepare`

- [ ] **Step 3: Commit**

```bash
git add lib/ash_feedback_demo_web/router.ex
git commit -m "feat(demo): mount AshFeedback.Router.audio_routes/0"
```

### Task 2d.7: Add the recorder script tag + copy library assets

**Files:**
- Modify: `lib/ash_feedback_demo_web/components/layouts/root.html.heex`

- [ ] **Step 1: Copy library assets into deps**

```bash
cp ~/Dev/phoenix_replay/lib/phoenix_replay/controller/submit_controller.ex deps/phoenix_replay/lib/phoenix_replay/controller/
cp ~/Dev/phoenix_replay/priv/static/assets/phoenix_replay.js deps/phoenix_replay/priv/static/assets/
cp -R ~/Dev/ash_feedback/lib/. deps/ash_feedback/lib/
cp -R ~/Dev/ash_feedback/priv/. deps/ash_feedback/priv/
mix deps.compile phoenix_replay --force
mix deps.compile ash_feedback --force
```

- [ ] **Step 2: Add the script tag**

In root layout (path verified via `find lib/ash_feedback_demo_web -name "root.html.heex"`), add inside `<head>` after the existing phoenix_replay assets:

```heex
<script defer phx-track-static src={~p"/assets/ash_feedback/audio_recorder.js"}></script>
<link rel="stylesheet" href={~p"/assets/ash_feedback/audio_recorder.css"} />
```

- [ ] **Step 3: Confirm Plug.Static serves from `deps/ash_feedback/priv/static/assets/`**

Check `endpoint.ex` for an existing `Plug.Static` configuration that serves ash_feedback's priv assets at `/assets/ash_feedback`. If absent, add:

```elixir
plug Plug.Static,
  at: "/assets/ash_feedback",
  from: {:ash_feedback, "priv/static/assets"},
  gzip: false
```

- [ ] **Step 4: Restart the app server**

Use Tidewave with `reason: "deps_changed"`.

- [ ] **Step 5: Commit**

```bash
git add lib/ash_feedback_demo_web/components/layouts/root.html.heex lib/ash_feedback_demo_web/endpoint.ex
git commit -m "feat(demo): load audio_recorder.js + .css in root layout"
```

### Task 2d.8: Manual smoke checklist

**Files:** none (browser verification).

- [ ] **Step 1: Open the demo in a browser**

Navigate to the demo's main page where the phoenix_replay widget is mounted (e.g. `http://localhost:4006/`).

- [ ] **Step 2: Verify the panel shows the mic button**

Open the widget panel. Above the severity dropdown, expect: `🎙 Record voice note`.

- [ ] **Step 3: Test record → stop → submit (Chrome)**

- Click the mic button. Allow microphone permission.
- Speak for ~3 seconds. Confirm the timer ticks.
- Click `■ Stop`. Confirm the audio preview appears with `▶ M:SS · ✕ Re-record`.
- Fill description, pick a severity, click Send.
- After submit, check `tmp/uploads/` — a file should exist.
- Check the database: the most recent feedback row should have an `audio_clip` attachment, and the attachment's metadata should contain `"audio_start_offset_ms"` with an integer value.

```bash
psql ash_feedback_demo_dev -c "select id, description from phoenix_replay_feedbacks order by inserted_at desc limit 1;"
psql ash_feedback_demo_dev -c "select id, metadata from ash_feedback_demo_attachments order by inserted_at desc limit 1;"
```

- [ ] **Step 4: Test permission denial (Chrome)**

- Reload the page, open panel, click mic, click Block in the permission prompt.
- Expect inline notice: "Microphone permission denied. You can still submit without audio."
- The rest of the form remains usable. Submit without audio works.

- [ ] **Step 5: Test codec fallback (Safari)**

- Open the demo in Safari.
- Confirm the recorder works (Safari uses the mp4 codec branch).
- Round-trip: record, submit, verify file lands.

- [ ] **Step 6: Test cap enforcement (Chrome)**

- Set `audio_max_seconds: 5` in `config/dev.exs`, restart.
- Open panel, record. Stop should auto-fire at 5s.

- [ ] **Step 7: Reset cap to 300**

Restore `audio_max_seconds: 300` in `config/dev.exs`. Commit.

- [ ] **Step 8: Commit smoke results**

```bash
git add config/dev.exs
git commit -m "chore(demo): smoke verified — record/upload/submit round-trip"
```

---

## Sub-phase 2e — Docs + library SHA bump

**Sub-phase goal:** README sections in both libraries explaining usage; CHANGELOG entries finalized; library main branches updated and the demo's `mix.lock` bumped.

### Task 2e.1: phoenix_replay README addon API section

**Files:**
- Modify: `~/Dev/phoenix_replay/README.md`

- [ ] **Step 1: Add a section**

Append (or insert in the appropriate place):

```markdown
## Panel addons

The widget panel exposes a small extension API for hosts to inject
custom form content. Each addon registers a JS hook that receives a
mount context and returns optional `beforeSubmit` / `onPanelClose`
callbacks. Returned `extras` from `beforeSubmit` are merged into the
`/submit` POST body and forwarded to the configured `Storage` adapter.

### Registering an addon

```js
window.PhoenixReplay.registerPanelAddon({
  id: "my-addon",
  slot: "form-top",                         // only "form-top" today
  mount(ctx) {
    // ctx = {
    //   slotEl,                            // <div data-slot="form-top">
    //   sessionId(),                       // current session id, or null
    //   sessionStartedAtMs(),              // wall-clock at session start, or null
    //   onPanelClose(cb),                  // register cleanup
    //   reportError(message),              // surface error in panel error screen
    // }
    ctx.slotEl.innerHTML = "<button type='button'>Hi</button>";
    return {
      async beforeSubmit({ formData }) {
        return { extras: { my_key: "value" } };
      },
      onPanelClose() { /* cleanup */ },
    };
  },
});
```

The Storage adapter sees the merged extras under `submit_params["extras"]`:

```elixir
def submit(session_id, %{"extras" => %{"my_key" => v}} = _params, _identity) do
  # ...
end
```

Audio narration in `ash_feedback` is the first consumer of this API.
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/phoenix_replay
git add README.md
git commit -m "docs(readme): panel addon API section"
```

### Task 2e.2: ash_feedback README audio recorder section

**Files:**
- Modify: `~/Dev/ash_feedback/README.md`

- [ ] **Step 1: Add a section**

Append a "Audio narration" section that covers:
- Enabling: `config :ash_feedback, audio_enabled: true`, registering `feedback_resource` and `audio_attachment_resource`.
- Host requirements: `ash_storage` dep, host-defined `Blob` + `Attachment` resources, an AshStorage service configured (Disk for dev, S3 for prod).
- Mounting: `<script>` tag for `audio_recorder.js`, router macro `AshFeedback.Router.audio_routes/0`.
- Browser support: webm/opus (Chrome, Firefox), mp4 (Safari).
- Config keys: `audio_max_seconds` (default 300).
- Pointer: `~/Dev/ash_storage/dev/resources/{blob,attachment,post}.ex` for the host resource shapes (until `5f` ships an Igniter installer).

Concrete copy:

```markdown
## Audio narration (optional)

Adds a 🎙 mic button to the `phoenix_replay` widget panel that records
audio via `MediaRecorder` and links the resulting blob to the submitted
feedback row via `AshStorage`.

### Enabling

```elixir
# config/config.exs
config :ash_feedback,
  audio_enabled: true,
  feedback_resource: MyApp.Feedback.Entry,
  audio_attachment_resource: MyApp.Storage.Attachment,
  audio_max_seconds: 300  # default
```

### Host requirements

- `{:ash_storage, github: "ash-project/ash_storage"}` in your deps.
- Host-defined `Blob` + `Attachment` AshStorage resources (see
  `~/Dev/ash_storage/dev/resources/{blob,attachment}.ex` for reference
  shapes). The `5f` Igniter installer will scaffold these.
- An AshStorage service configured for the Blob resource — `Disk` for
  dev, `S3` (or compatible) for prod.

### Wiring

In your root layout:

```heex
<script defer src={~p"/assets/ash_feedback/audio_recorder.js"}></script>
<link rel="stylesheet" href={~p"/assets/ash_feedback/audio_recorder.css"} />
```

Add a `Plug.Static` entry serving `ash_feedback/priv/static/assets`:

```elixir
plug Plug.Static,
  at: "/assets/ash_feedback",
  from: {:ash_feedback, "priv/static/assets"}
```

In your router, mount the prepare endpoint inside an authenticated
browser scope:

```elixir
scope "/" do
  pipe_through :browser
  AshFeedback.Router.audio_routes()  # or audio_routes(path: "/api/audio")
end
```

### Pass the attachment resource to the macro

```elixir
use AshFeedback.Resources.Feedback,
  domain: MyApp.Feedback,
  repo: MyApp.Repo,
  audio_attachment_resource: MyApp.Storage.Attachment
```

### Browser support

- Chrome / Firefox / Edge — `audio/webm; codecs=opus` (primary).
- Safari — `audio/mp4; codecs=mp4a.40.2` (fallback).
- No support → mic button disabled with a tooltip; the rest of the form
  remains usable.
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/ash_feedback
git add README.md
git commit -m "docs(readme): audio narration section"
```

### Task 2e.3: Push library commits and bump demo mix.lock

**Files:**
- Modify: `~/Dev/ash_feedback_demo/mix.lock`

- [ ] **Step 1: Confirm with the user before pushing**

Pushing affects shared state. Do NOT push without explicit user confirmation. State:

> "Both libraries' main branches are ready to push. Phoenix_replay has N commits ahead, ash_feedback has M commits ahead. Push both to origin?"

Wait for explicit yes.

- [ ] **Step 2: Push (after confirmation)**

```bash
cd ~/Dev/phoenix_replay && git push origin main
cd ~/Dev/ash_feedback && git push origin main
```

- [ ] **Step 3: Bump demo mix.lock**

```bash
cd ~/Dev/ash_feedback_demo
mix deps.update phoenix_replay ash_feedback
```

- [ ] **Step 4: Run the demo's tests if any**

Run: `mix test`
Expected: any existing demo tests pass.

- [ ] **Step 5: Restart Tidewave + browser smoke once more**

Confirm the demo still works against the released SHAs (no longer the local cp shim).

- [ ] **Step 6: Commit the lock bump**

```bash
cd ~/Dev/ash_feedback_demo
git add mix.lock
git commit -m "deps(update): pull phoenix_replay + ash_feedback main with audio Phase 2"
```

### Task 2e.4: Mark Phase 2 shipped in the active plan

**Files:**
- Modify: `~/Dev/ash_feedback/docs/plans/active/2026-04-24-audio-narration.md`

- [ ] **Step 1: Update Phase 2 status**

Change the Phase 2 header line from current state to:

```markdown
### Phase 2 — Recorder JS + presigned upload ✅ shipped 2026-04-24 (`<sha>`)
```

Add a pointer to this plan:

```markdown
**Implementation plan:** [`docs/superpowers/plans/2026-04-24-audio-narration-phase-2.md`](../../superpowers/plans/2026-04-24-audio-narration-phase-2.md)
```

Check off all DoD items.

- [ ] **Step 2: Update the plans index**

Modify `~/Dev/ash_feedback/docs/plans/README.md` to reflect Phase 2 shipped if it tracks per-phase status.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/ash_feedback
git add docs/plans/active/2026-04-24-audio-narration.md docs/plans/README.md
git commit -m "docs(plans): mark Phase 2 shipped, link implementation plan"
```

---

## Decisions log

- **Task 2b.1 outcome (recorded 2026-04-24):** `AshStorage.Changes.AttachBlob` does NOT accept a `metadata:` option, AND AshStorage's Attachment resource has no built-in `metadata` attribute. Source: `~/Dev/ash_storage/lib/ash_storage/changes/attach_blob.ex` lines 32–37 (only `:argument` and `:attachment` validated) and `attachment_resource/transformers/setup_attachment.ex` (no metadata attribute added).

  **Design pivot to "Path B" — blob metadata:** the original spec's D2 ("offset on attachment metadata") is revised. AshStorage's Blob resource has a built-in `metadata :map` attribute, AND `AshStorage.Operations.prepare_direct_upload/3` already accepts a `:metadata` option that's written to the blob row at prepare time. So the offset rides on the **blob**, not the attachment. Effects on the plan:
  - **2b.3 (controller):** accepts an optional `"metadata"` field in the POST body and passes it through to `prepare_direct_upload(..., metadata: ...)`.
  - **2b.5 (resource action):** the `:submit` action only adds the `:audio_clip_blob_id` argument + the `AshStorage.Changes.AttachBlob` change. **No `audio_start_offset_ms` argument. No `after_action` hook.**
  - **2b.6 (Storage extras handler):** only extracts `audio_clip_blob_id` from `extras` and forwards it. **No offset handling.**
  - **2b.7 (recorder JS):** at prepare time, sends `metadata: { audio_start_offset_ms: <ms> }` in the POST body. The `beforeSubmit` return only carries `audio_clip_blob_id` in `extras`.
  - **2c.3 (round-trip test):** asserts `feedback.audio_clip.blob.metadata["audio_start_offset_ms"] == 1234`.
  - **Phase 3 (admin playback, future):** loads `feedback |> Ash.load(audio_clip: :blob)` and reads `feedback.audio_clip.blob.metadata["audio_start_offset_ms"]`.

## Self-review (executed during plan write)

- **Spec coverage:** Each architectural decision (D1–D7) maps to at least one task — D1 → 2a.1–2a.5; D2 → 2b.1, 2b.5, 2c.3; D3 → 2b.4; D4 → 2a.6, 2b.6; D5 → 2d.5; D6 → 2c.1–2c.3; D7 → 2b.7.
- **Placeholder scan:** Two flagged items — `Task 2b.1 outcome` is a deliberate verify-then-decide step (the design called this out as a known unknown); the test fixture skeleton in 2b.3 references a "minimal stub" with detail referred forward to 2b.5 — this is genuine TDD ordering, not a placeholder.
- **Type consistency:** `audio_clip_blob_id` and `audio_start_offset_ms` are spelled identically across all tasks. `AshFeedback.Controller.AudioUploadsController` plug name is consistent in the controller, the router macro, and the route assertions.
- **Scope:** All five sub-phases produce working, testable software. 2a is independently shippable (panel API with no audio).

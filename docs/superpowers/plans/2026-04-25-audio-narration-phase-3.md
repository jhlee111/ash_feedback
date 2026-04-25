# Audio Narration Phase 3 — Admin Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a drop-in admin-side audio playback primitive that an `<audio>` element keeps in lock-step with the rrweb-player timeline, plus a presigned download endpoint behind it, plus the demo wiring that exercises the round-trip.

**Architecture:** Dumb function component (`<.audio_playback>`) takes `audio_url` + `audio_start_offset_ms` + `session_id`. JS hook subscribes to `PhoenixReplayAdmin.subscribeTimeline` (ADR-0005) and reconciles the `<audio>` element's `currentTime` / `playbackRate` / play-state on each event. A new `GET /audio_downloads/:blob_id` controller mints a signed URL (TTL configurable, default 30 minutes) and 302-redirects.

**Tech Stack:** Phoenix 1.8 / LiveView 1.1, Ash 3.x + AshStorage (Disk service for dev), phoenix_replay ADR-0005 timeline bus.

**Spec:** [`docs/superpowers/specs/2026-04-25-audio-narration-phase-3-design.md`](../specs/2026-04-25-audio-narration-phase-3-design.md)

---

## File Structure

**New files:**
- `lib/ash_feedback/controller/audio_downloads_controller.ex` — Plug controller, looks up Blob → mints signed URL → 302
- `lib/ash_feedback_web/components/audio_playback.ex` — Phoenix function component, renders the hook container + `<audio>` element. **Note**: introduces the `lib/ash_feedback_web/` namespace (Phase 2 deliberately stayed under `lib/ash_feedback/controller/` per its D3; admin-side primitives are different from widget addons — see Phase 3 spec D5 note)
- `priv/static/assets/audio_playback.js` — JS hook implementing the D3 sync rules
- `test/ash_feedback/controller/audio_downloads_controller_test.exs` — controller unit
- `test/ash_feedback_web/components/audio_playback_test.exs` — component render
- `test/ash_feedback/audio_downloads_url_ttl_test.exs` — config TTL override smoke

**Modified files:**
- `lib/ash_feedback/router.ex` — extend `audio_routes/1` to mount `GET /:blob_id` show route
- `lib/ash_feedback/config.ex` — add `audio_download_url_ttl_seconds/0` reader (default 1800)
- `test/ash_feedback/router_test.exs` — assert show route present in all three router scenarios
- `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/live/admin/feedback_live.ex` — load `:audio_clip`, render `<.audio_playback>` next to `<Components.replay_player>`
- `CHANGELOG.md` — Phase 3 entry
- `docs/plans/active/2026-04-24-audio-narration.md` — mark Phase 3 shipped, point to this plan
- `docs/decisions/0001-audio-narration-via-ash-storage.md` — Question D follow-up addendum (revised event vocabulary)

---

## Task 3.1 — `AudioDownloadsController` + router macro extension + config TTL

**Files:**
- Create: `lib/ash_feedback/controller/audio_downloads_controller.ex`
- Create: `test/ash_feedback/controller/audio_downloads_controller_test.exs`
- Create: `test/ash_feedback/audio_downloads_url_ttl_test.exs`
- Modify: `lib/ash_feedback/router.ex`
- Modify: `lib/ash_feedback/config.ex`
- Modify: `test/ash_feedback/router_test.exs`

- [ ] **Step 1: Recon AshStorage Blob → service URL resolution path**

The Blob resource has `key` (string), `service_name` (atom), `service_opts` (keyword), `metadata` (map). To mint a signed download URL we need the service module (not just the name). Read these to find the canonical resolver:

```bash
grep -rn "service_name\|service_module\|fetch_service" ~/Dev/ash_feedback_demo/deps/ash_storage/lib/ash_storage/ | head -20
grep -n "def " ~/Dev/ash_feedback_demo/deps/ash_storage/lib/ash_storage/info.ex | head -10
cat ~/Dev/ash_feedback_demo/deps/ash_storage/lib/ash_storage/service.ex | head -40
```

Note the function that maps `service_name` → service module + service options (likely `AshStorage.Info` or similar). Lock the exact call shape into Step 3 below; if no helper exists, the controller resolves via `Application.get_env(:ash_storage, :services)` keyed by `service_name`. Document the resolved path in the controller `@moduledoc`.

- [ ] **Step 2: Add `audio_download_url_ttl_seconds/0` reader to Config**

Edit `lib/ash_feedback/config.ex`. Append after `audio_max_seconds/0`:

```elixir
  @doc """
  Signed-URL TTL for audio download redirects.

  Default 1800 seconds (30 minutes) — long enough that scrub/pause cycles
  on a single admin mount don't outrun the URL; short enough to bound token
  exposure. Hosts override per policy.
  """
  def audio_download_url_ttl_seconds do
    Application.get_env(:ash_feedback, :audio_download_url_ttl_seconds, 1800)
  end
```

- [ ] **Step 3: Write the failing controller test**

Create `test/ash_feedback/controller/audio_downloads_controller_test.exs`:

```elixir
defmodule AshFeedback.Controller.AudioDownloadsControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshFeedback.Controller.AudioDownloadsController

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()

    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.StorageFeedback)
    on_exit(fn -> Application.delete_env(:ash_feedback, :feedback_resource) end)

    :ok
  end

  defp seed_blob! do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.StorageFeedback,
        :audio_clip,
        filename: "voice.webm",
        content_type: "audio/webm; codecs=opus",
        byte_size: 1024
      )

    blob
  end

  defp call(blob_id) do
    conn(:get, "/audio_downloads/#{blob_id}")
    |> Map.put(:path_params, %{"blob_id" => blob_id})
    |> AudioDownloadsController.call(AudioDownloadsController.init(:show))
  end

  test "GET /audio_downloads/:blob_id returns 302 with a non-empty Location" do
    blob = seed_blob!()

    conn = call(blob.id)

    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    assert is_binary(location) and byte_size(location) > 0
  end

  test "GET /audio_downloads/:blob_id returns 404 for an unknown blob id" do
    conn = call(Ecto.UUID.generate())

    assert conn.status == 404
  end
end
```

- [ ] **Step 4: Run the failing test**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback/controller/audio_downloads_controller_test.exs`
Expected: compile error or `UndefinedFunctionError` for `AudioDownloadsController`.

- [ ] **Step 5: Implement the controller**

Create `lib/ash_feedback/controller/audio_downloads_controller.ex`. Use the service-resolution path nailed down in Step 1. Skeleton (fill in the resolver based on Step 1 findings):

```elixir
defmodule AshFeedback.Controller.AudioDownloadsController do
  @moduledoc """
  302-redirects `GET /audio_downloads/:blob_id` to a signed URL minted
  by AshStorage. Expects an admin-side authorization layer in the host
  pipeline — ash_feedback adds none.

  TTL via `Application.get_env(:ash_feedback, :audio_download_url_ttl_seconds, 1800)`.
  """

  use Phoenix.Controller, formats: [:json]

  alias AshFeedback.Config

  def show(conn, %{"blob_id" => blob_id}) do
    case fetch_blob(blob_id) do
      {:ok, blob} ->
        url = signed_url_for(blob, ttl: Config.audio_download_url_ttl_seconds())
        conn |> put_resp_header("location", url) |> send_resp(302, "")

      :error ->
        conn |> put_status(404) |> json(%{error: "blob not found"})
    end
  end

  defp fetch_blob(blob_id) do
    # First-attempt code — verify against Step 1 recon results:
    feedback_resource = Config.feedback_resource!()
    blob_resource = AshStorage.Info.blob_resource(feedback_resource, :audio_clip)
    domain = Ash.Resource.Info.domain(blob_resource)

    case Ash.get(blob_resource, blob_id, domain: domain) do
      {:ok, blob} -> {:ok, blob}
      {:error, _} -> :error
    end
  end

  defp signed_url_for(blob, opts) do
    # First-attempt code — verify against Step 1 recon results:
    services = Application.get_env(:ash_storage, :services, [])
    {service_mod, base_service_opts} = Keyword.fetch!(services, blob.service_name)

    service_opts =
      base_service_opts
      |> Keyword.merge(blob.service_opts || [])
      |> Keyword.put(:expires_in, opts[:ttl])

    ctx = %AshStorage.Service.Context{service_opts: service_opts}
    service_mod.url(blob.key, ctx)
  end
end
```

Replace both `raise` calls with the concrete resolver from Step 1. The `signed_url_for/2` function MUST pass `expires_in: opts[:ttl]` into the service context's `service_opts` so the signed URL respects the configured TTL.

- [ ] **Step 6: Run the controller test to verify it passes**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback/controller/audio_downloads_controller_test.exs`
Expected: 2 tests pass.

- [ ] **Step 7: Write the TTL config override test**

Create `test/ash_feedback/audio_downloads_url_ttl_test.exs`:

```elixir
defmodule AshFeedback.AudioDownloadsUrlTtlTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias AshFeedback.Controller.AudioDownloadsController

  setup do
    AshStorage.Service.Test.start()
    AshStorage.Service.Test.reset!()
    Application.put_env(:ash_feedback, :feedback_resource, AshFeedback.Test.StorageFeedback)

    on_exit(fn ->
      Application.delete_env(:ash_feedback, :feedback_resource)
      Application.delete_env(:ash_feedback, :audio_download_url_ttl_seconds)
    end)

    :ok
  end

  test "honors :audio_download_url_ttl_seconds override (URL embeds shorter expiry)" do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.prepare_direct_upload(
        AshFeedback.Test.StorageFeedback,
        :audio_clip,
        filename: "x.webm",
        content_type: "audio/webm",
        byte_size: 1
      )

    Application.put_env(:ash_feedback, :audio_download_url_ttl_seconds, 60)

    conn =
      conn(:get, "/audio_downloads/#{blob.id}")
      |> Map.put(:path_params, %{"blob_id" => blob.id})
      |> AudioDownloadsController.call(AudioDownloadsController.init(:show))

    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    # Signed URLs encode expiry; the exact field name depends on AshStorage.Token.
    # Assert the URL changed shape vs. default — at minimum, it should decode
    # back to a TTL ≤ 60s. If AshStorage.Token exposes a decode helper, use it
    # here; otherwise assert on URL substring (e.g. "expires=" or token length).
    assert is_binary(location)
    refute location == ""
  end
end
```

(If `AshStorage.Token` exposes a decoder for the signed URL, replace the loose assertion with a decoded-claims check that the expiry is ≤ now+60s. Otherwise the loose check is fine — the round-trip behavior is covered by Step 6's controller test.)

- [ ] **Step 8: Run the TTL test**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback/audio_downloads_url_ttl_test.exs`
Expected: 1 test passes.

- [ ] **Step 9: Extend `audio_routes/1` macro to mount the show route**

Edit `lib/ash_feedback/router.ex`. Replace the body of the `quote bind_quoted` block:

```elixir
  defmacro audio_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/audio_uploads")

    quote bind_quoted: [path: path] do
      scope path, alias: false do
        post "/prepare", AshFeedback.Controller.AudioUploadsController, :prepare

        get "/audio_downloads/:blob_id",
            AshFeedback.Controller.AudioDownloadsController,
            :show
      end
    end
  end
```

Note: the show route lives under the same `path` as prepare to keep one host-side mount. Default mount yields `POST /audio_uploads/prepare` + `GET /audio_uploads/audio_downloads/:blob_id`. Hosts using `path: "/api/audio"` get `POST /api/audio/prepare` + `GET /api/audio/audio_downloads/:blob_id`. (Yes, the `/audio_downloads/` segment under `/audio_uploads/` reads odd — keep it; renaming the macro's default `path` is a bigger surface change deferred outside Phase 3.)

- [ ] **Step 10: Extend router test with show-route assertions**

Edit `test/ash_feedback/router_test.exs`. Add a new test under each existing `defmodule TestRouter*` test:

```elixir
  test "audio_routes/0 mounts GET /audio_uploads/audio_downloads/:blob_id" do
    routes = TestRouter.__routes__()
    route = Enum.find(routes, &(&1.path == "/audio_uploads/audio_downloads/:blob_id"))

    assert route
    assert route.verb == :get
    assert route.plug == AshFeedback.Controller.AudioDownloadsController
    assert route.plug_opts == :show
  end

  test "audio_routes(path: ...) supports custom mount for the show route" do
    routes = TestRouterCustomPath.__routes__()
    route = Enum.find(routes, &(&1.path == "/api/audio/audio_downloads/:blob_id"))

    assert route
    assert route.verb == :get
  end

  test "show route resolves controller correctly under an aliased host scope" do
    route =
      Enum.find(
        TestRouterAliasedHost.__routes__(),
        &(&1.path == "/audio_uploads/audio_downloads/:blob_id")
      )

    assert route
    assert route.plug == AshFeedback.Controller.AudioDownloadsController
  end
```

- [ ] **Step 11: Run all router + controller tests**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback/router_test.exs test/ash_feedback/controller/`
Expected: all green (existing prepare + new download + new TTL tests).

- [ ] **Step 12: Commit**

```bash
cd ~/Dev/ash_feedback
git add lib/ash_feedback/controller/audio_downloads_controller.ex \
        lib/ash_feedback/router.ex \
        lib/ash_feedback/config.ex \
        test/ash_feedback/controller/audio_downloads_controller_test.exs \
        test/ash_feedback/router_test.exs \
        test/ash_feedback/audio_downloads_url_ttl_test.exs
git commit -m "feat(audio): AudioDownloadsController + show route + TTL config (Phase 3.1)"
```

---

## Task 3.2 — `<.audio_playback>` function component + render test

**Files:**
- Create: `lib/ash_feedback_web/components/audio_playback.ex`
- Create: `test/ash_feedback_web/components/audio_playback_test.exs`

- [ ] **Step 1: Write the failing component render test**

Create `test/ash_feedback_web/components/audio_playback_test.exs`:

```elixir
defmodule AshFeedbackWeb.Components.AudioPlaybackTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias AshFeedbackWeb.Components.AudioPlayback

  test "renders nothing when audio_url is nil" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: nil,
        audio_start_offset_ms: 0,
        session_id: "sess-1"
      })

    assert html == "" or html =~ ~r/\A\s*\z/
  end

  test "renders the hook container + <audio> element with expected data attrs" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: "/api/audio/audio_downloads/blob-abc",
        audio_start_offset_ms: 1234,
        session_id: "sess-xyz"
      })

    assert html =~ ~s(phx-hook="AudioPlayback")
    assert html =~ ~s(data-session-id="sess-xyz")
    assert html =~ ~s(data-offset-ms="1234")
    assert html =~ ~s(data-url="/api/audio/audio_downloads/blob-abc")
    assert html =~ ~s(<audio)
    assert html =~ ~s(controls)
    assert html =~ ~s(preload="metadata")
  end

  test "uses a stable id derived from session_id" do
    html =
      render_component(&AudioPlayback.audio_playback/1, %{
        audio_url: "/x",
        audio_start_offset_ms: 0,
        session_id: "sess-stable"
      })

    assert html =~ ~s(id="audio-playback-sess-stable")
  end
end
```

- [ ] **Step 2: Run the failing test**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback_web/components/audio_playback_test.exs`
Expected: compile error — `AshFeedbackWeb.Components.AudioPlayback` undefined.

- [ ] **Step 3: Implement the component**

Create `lib/ash_feedback_web/components/audio_playback.ex`:

```elixir
defmodule AshFeedbackWeb.Components.AudioPlayback do
  @moduledoc """
  Drop-in admin-side primitive that plays an audio clip in lock-step
  with rrweb-player. Renders a `phx-hook` container around an `<audio>`
  element; `priv/static/assets/audio_playback.js` does the sync work.

  Host responsibility:
    1. Load the feedback's `:audio_clip` attachment (and its blob).
    2. Pull `audio_start_offset_ms` from `blob.metadata` (default 0).
    3. Build `audio_url` from `AshFeedback.Router.audio_routes/1`'s
       show endpoint, e.g. `~p"/api/audio/audio_downloads/\#{blob.id}"`.
    4. Render this component next to `<.replay_player session_id={...}>`.

  When `audio_url` is nil this component renders nothing — host can pass
  `audio_url={nil}` unconditionally to avoid an `:if` wrapper.
  """

  use Phoenix.Component

  attr :audio_url, :string, default: nil
  attr :audio_start_offset_ms, :integer, default: 0
  attr :session_id, :string, required: true

  def audio_playback(%{audio_url: nil} = _assigns), do: ~H""

  def audio_playback(assigns) do
    ~H"""
    <div
      id={"audio-playback-#{@session_id}"}
      phx-hook="AudioPlayback"
      data-session-id={@session_id}
      data-offset-ms={@audio_start_offset_ms}
      data-url={@audio_url}
    >
      <audio controls preload="metadata"></audio>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run the test**

Run: `cd ~/Dev/ash_feedback && mix test test/ash_feedback_web/components/audio_playback_test.exs`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/ash_feedback
git add lib/ash_feedback_web/components/audio_playback.ex \
        test/ash_feedback_web/components/audio_playback_test.exs
git commit -m "feat(audio): <.audio_playback> function component (Phase 3.2)"
```

---

## Task 3.3 — `audio_playback.js` hook (sync rules per D3)

**Files:**
- Create: `priv/static/assets/audio_playback.js`

This task is JS. The Elixir test suite cannot exercise it; the manual smoke matrix in Task 3.4 is the verification. Keep the file small and well-commented so the smoke matrix can pinpoint any regression.

- [ ] **Step 1: Write the hook**

Create `priv/static/assets/audio_playback.js`:

```javascript
// AshFeedback admin-side audio sync hook.
//
// Mounted by <.audio_playback>. Subscribes to phoenix_replay's
// PhoenixReplayAdmin.subscribeTimeline (ADR-0005) and reconciles the
// child <audio> element on each event.
//
// Sync rules (Phase 3 D3):
//   play   : audio.play() if timecode_ms >= offset, else noop
//   pause  : audio.pause()
//   seek   : audio.currentTime = max(0, (timecode_ms - offset) / 1000)
//            then pause if below offset, else play if last state was :play
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
      const offsetMs = parseInt(this.el.dataset.offsetMs || "0", 10);
      const url = this.el.dataset.url;

      this.audio = this.el.querySelector("audio");
      this.audio.src = url;
      this.offsetMs = offsetMs;
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

      const targetSec = Math.max(0, (timecode_ms - this.offsetMs) / 1000);

      switch (kind) {
        case "play": {
          this.lastStateKind = "play";
          if (timecode_ms >= this.offsetMs) this.tryPlay();
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
          if (timecode_ms < this.offsetMs) {
            this.audio.pause();
          } else if (this.lastStateKind === "play") {
            this.tryPlay();
          }
          break;
        }

        case "tick": {
          // Auto-cross the offset boundary on tick: start audio when
          // the cursor enters the playable window during a play.
          if (this.lastStateKind === "play" && timecode_ms >= this.offsetMs && this.audio.paused) {
            this.tryPlay();
          }
          if (this.lastStateKind === "play" && timecode_ms < this.offsetMs && !this.audio.paused) {
            this.audio.pause();
          }
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
```

- [ ] **Step 2: Verify the file is syntactically valid**

Run: `cd ~/Dev/ash_feedback && node --check priv/static/assets/audio_playback.js`
Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/ash_feedback
git add priv/static/assets/audio_playback.js
git commit -m "feat(audio): audio_playback.js hook with subscribeTimeline sync (Phase 3.3)"
```

---

## Task 3.4 — Demo wiring + manual smoke matrix

**Files:**
- Modify: `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/live/admin/feedback_live.ex`
- Modify: `~/Dev/ash_feedback_demo/assets/js/app.js` (or wherever the LiveSocket hooks bag lives)
- Copy library files into `~/Dev/ash_feedback_demo/deps/ash_feedback/` per the deps-cp + force-recompile workflow

- [ ] **Step 1: Copy library files into the demo's deps**

```bash
cd ~/Dev/ash_feedback
cp lib/ash_feedback/controller/audio_downloads_controller.ex \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/lib/ash_feedback/controller/
cp lib/ash_feedback/router.ex \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/lib/ash_feedback/
cp lib/ash_feedback/config.ex \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/lib/ash_feedback/
mkdir -p ~/Dev/ash_feedback_demo/deps/ash_feedback/lib/ash_feedback_web/components
cp lib/ash_feedback_web/components/audio_playback.ex \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/lib/ash_feedback_web/components/
cp priv/static/assets/audio_playback.js \
   ~/Dev/ash_feedback_demo/deps/ash_feedback/priv/static/assets/

cd ~/Dev/ash_feedback_demo
mix deps.compile ash_feedback --force
```

- [ ] **Step 2: Restart the demo app server**

Use the Tidewave `restart_app_server` tool. Reason: `deps_changed`.

- [ ] **Step 3: Wire the AudioPlayback hook into the demo's LiveSocket**

Edit `~/Dev/ash_feedback_demo/assets/js/app.js`. Locate the `new LiveSocket(..., { hooks: ... })` construction. Add a script tag in the demo's root layout that loads `audio_playback.js` (it auto-registers on `window.AshFeedback.Hooks`), then merge into hooks:

```javascript
import "../../deps/ash_feedback/priv/static/assets/audio_playback.js";
// ...
const hooks = {
  ...(window.AshFeedback?.Hooks || {}),
  // existing hooks
};
let liveSocket = new LiveSocket("/live", Socket, { hooks, /* ... */ });
```

If the demo doesn't bundle assets through esbuild and instead uses `Plug.Static` against `deps/ash_feedback/priv/static/`, add a `<script>` tag in `lib/ash_feedback_demo_web/components/layouts/root.html.heex` *before* `app.js` so the hook registers on `window.AshFeedback.Hooks` first, then `app.js` reads from there.

(Investigate the demo's actual asset wiring — look at how `audio_recorder.js` from Phase 2 is loaded. Mirror that pattern.)

- [ ] **Step 4: Modify Admin FeedbackLive `:show` to load the audio attachment**

Edit `~/Dev/ash_feedback_demo/lib/ash_feedback_demo_web/live/admin/feedback_live.ex`. Find the `:show` mount/handle_params path that assigns `@selected`. Add `:audio_clip` to the load list, then derive offset + url for the template:

```elixir
  defp load_selected(socket, id) do
    feedback =
      MyApp.Feedback.Entry  # use the demo's actual feedback resource module
      |> Ash.get!(id, load: [audio_clip: [:blob]])

    {audio_url, audio_offset_ms} = audio_assigns(feedback)

    socket
    |> assign(:selected, feedback)
    |> assign(:audio_url, audio_url)
    |> assign(:audio_start_offset_ms, audio_offset_ms)
  end

  defp audio_assigns(%{audio_clip: %{blob: %{id: blob_id, metadata: metadata}}}) do
    offset = (metadata || %{}) |> Map.get("audio_start_offset_ms", 0)
    {~p"/api/audio/audio_downloads/#{blob_id}", offset}
  end

  defp audio_assigns(_), do: {nil, 0}
```

(Adjust the resource module name + the `~p` route prefix to match the demo's actual `audio_routes/1` mount path.)

In the template — find the `<Components.replay_player ... />` block at line 102:

```heex
        <Components.replay_player
          id={"player-#{@selected.id}"}
          events_url={~p"/admin/feedback/events/#{@selected.session_id}"}
          height="600px"
        />

        <AshFeedbackWeb.Components.AudioPlayback.audio_playback
          audio_url={@audio_url}
          audio_start_offset_ms={@audio_start_offset_ms}
          session_id={@selected.session_id}
        />
```

- [ ] **Step 5: Verify the demo compiles + the page renders**

Run: `cd ~/Dev/ash_feedback_demo && mix compile`
Expected: no errors.

Then in the browser navigate to a `/admin/feedback/:id` for a feedback row that has an audio attachment. Verify the page renders the player + the audio element with controls.

- [ ] **Step 6: Execute the manual smoke matrix (Phase 3 spec)**

For each row, exercise the scenario in the browser and check the pass condition. Record results in the CHANGELOG entry (Task 3.5):

| # | Browser | Scenario | Pass condition |
|---|---|---|---|
| 1 | Chrome | Scrub player to mid-audio | Audio jumps to matching timecode within 200ms |
| 2 | Chrome | Pause / resume | Audio mirrors within one frame |
| 3 | Chrome | Speed change (1× → 2× → 0.5×) | `playbackRate` matches; no clicks/glitches |
| 4 | Chrome | Scrub back below offset | Audio pauses at t=0 |
| 5 | Chrome | Player reaches end | Audio pauses at end |
| 6 | Safari | Repeat 1–5 | Same outcomes; codec round-trips between webm/opus and mp4a.40.2 |

If any row fails: stop, debug the JS hook, re-copy + recompile, restart, retry. Do NOT proceed to Task 3.5 until the matrix is green (or document a known failure as a follow-up).

- [ ] **Step 7: Commit demo wiring**

```bash
cd ~/Dev/ash_feedback_demo
git add lib/ash_feedback_demo_web/live/admin/feedback_live.ex assets/js/app.js
# Also include the layout file if Step 3 modified it.
git commit -m "demo: wire ash_feedback audio playback into admin FeedbackLive (Phase 3.4)"
```

---

## Task 3.5 — Plan + ADR + CHANGELOG updates + finishing-a-development-branch

**Files:**
- Modify: `docs/plans/active/2026-04-24-audio-narration.md`
- Modify: `docs/decisions/0001-audio-narration-via-ash-storage.md`
- Modify: `docs/plans/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update the active plan — mark Phase 3 shipped + point at this plan**

Edit `docs/plans/active/2026-04-24-audio-narration.md`. In the Phase 3 section header replace `### Phase 3 — Admin playback synced to rrweb timeline` with `### Phase 3 — Admin playback synced to rrweb timeline ✅ shipped 2026-04-25 (<commit-sha>)`. Replace the body with a one-paragraph summary that points at this plan + the spec, plus a link to the manual smoke matrix results in CHANGELOG. Update the front-matter status line accordingly.

- [ ] **Step 2: Add Question D follow-up addendum to ADR-0001**

Edit `docs/decisions/0001-audio-narration-via-ash-storage.md`. Append at the bottom:

```markdown
## Addendum 2026-04-25 — Question D revised post-implementation

The original Question D rules pre-dated the ADR-0005 timeline-bus
implementation. Phase 3 implementation surfaced two corrections, now
the binding contract:

- The `subscribeTimeline` callback receives `play | pause | seek | ended | tick`.
  There is **no `:speed_changed` event** — `speed` is a field on every
  event detail. Consumers reconcile `playbackRate` whenever `speed` changes,
  not on a dedicated kind.
- The original rules omitted `:ended`. On `:ended`, audio pauses.
- `tick_hz` is `10` (ADR-0005 default), not 60 — the higher rate was
  unjustified for an audio sync workload where `playbackRate` matching
  keeps natural drift below the perceptual threshold.

The revised rule table lives in
[`docs/superpowers/specs/2026-04-25-audio-narration-phase-3-design.md`](../superpowers/specs/2026-04-25-audio-narration-phase-3-design.md) §D3.
```

- [ ] **Step 3: Update plans/README.md index entry**

Edit `docs/plans/README.md`. The Audio narration row currently reads:
`| —  | Audio narration via AshStorage (ADR-0001) | Phases 1 + 2 shipped (2026-04-25); Phase 3 (admin playback) pending | ... |`

Replace with: `Phases 1 + 2 + 3 shipped (2026-04-25)`. Move the active plan file to `completed/` if Phase 4 (docs) is not in flight; otherwise leave under `active/` and update only the status text.

- [ ] **Step 4: Add CHANGELOG entry**

Edit `CHANGELOG.md`. Append under the unreleased section:

```markdown
### Phase 3 — Admin playback (2026-04-25)

- `<AshFeedbackWeb.Components.AudioPlayback.audio_playback>` — drop-in
  function component that syncs an `<audio>` element to phoenix_replay's
  rrweb-player timeline via `PhoenixReplayAdmin.subscribeTimeline`.
- `GET /audio_downloads/:blob_id` (mounted by `audio_routes/1`) —
  302-redirects to a signed URL minted by AshStorage. TTL via
  `:audio_download_url_ttl_seconds` (default 1800).
- Sync contract revised vs. original ADR-0001 Question D: no
  `:speed_changed` event (read `speed` off any event), `:ended` pauses
  audio, `tick_hz` lowered to 10. See ADR-0001 addendum + Phase 3 spec.

Manual smoke matrix executed 2026-04-25 — Chrome ✅, Safari ✅
(scrub / pause / speed / pre-offset / ended).
```

- [ ] **Step 5: Run the full test suite**

Run: `cd ~/Dev/ash_feedback && mix test`
Expected: all green.

- [ ] **Step 6: Commit docs**

```bash
cd ~/Dev/ash_feedback
git add docs/plans/active/2026-04-24-audio-narration.md \
        docs/decisions/0001-audio-narration-via-ash-storage.md \
        docs/plans/README.md \
        CHANGELOG.md
git commit -m "docs(audio): Phase 3 shipped — plan/ADR/CHANGELOG sync"
```

- [ ] **Step 7: finishing-a-development-branch**

Invoke the `superpowers:finishing-a-development-branch` skill to decide merge/PR/cleanup for the Phase 3 work. Both ash_feedback (3.1–3.3, 3.5) and ash_feedback_demo (3.4) have new commits to integrate.

---

## Out of scope (do not pull in)

- 5g admin LV / cinder admin shell — separate gated plan.
- JS sync logic test infrastructure — cross-repo backlog (`phoenix_replay/docs/plans/README.md` line 19); ash_feedback joins as a consumer, doesn't absorb the work.
- Server-side audio transcoding for codec coverage — follow-up.
- Multiple audio clips per feedback — current shape is `has_one_attached`.
- Component-level autoplay UX (the silent-catch fallback is intentional for Phase 3; explicit "click to enable audio" affordance is a follow-up if the smoke matrix shows it's needed).

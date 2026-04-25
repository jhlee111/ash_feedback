# Design: Audio Narration Phase 2 — Recorder + Direct Upload

**Date**: 2026-04-24
**Owners**: ash_feedback (primary), phoenix_replay (panel-addon API change)
**Driving plan**: [`ash_feedback/docs/plans/active/2026-04-24-audio-narration.md`](../../plans/active/2026-04-24-audio-narration.md) (Phase 2)
**ADR**: [`ash_feedback/docs/decisions/0001-audio-narration-via-ash-storage.md`](../../decisions/0001-audio-narration-via-ash-storage.md)
**Status**: Draft — supersedes the bullet-level Phase 2 sketch in the active plan; brainstorm session of 2026-04-24 produced the architectural decisions captured here.

## Context

Phase 1 shipped the resource-shape changes: `ash_feedback`'s `Feedback` macro now opt-in declares a `has_one_attached :audio_clip` via `AshStorage`, gated by a compile-time flag plus the optional `:ash_storage` dep (see commit `67fd09a`). Default behavior is unchanged.

Phase 2 is the user-visible piece: a microphone button inside the existing `phoenix_replay` widget panel that records audio via `MediaRecorder`, uploads it directly to the storage backend via an `AshStorage` presigned URL, and links the resulting blob to the submitted `Feedback` row — with `audio_start_offset_ms` captured at record-start and persisted alongside the attachment.

Two cross-cutting requirements shape the design:

1. **`phoenix_replay` is Ash-agnostic** and owns the widget panel + `/submit` route. It must not learn about audio.
2. **`ash_feedback` has no web layer today** (no `lib/ash_feedback_web/`); Phase 2 introduces a minimal one, following `phoenix_replay`'s `lib/phoenix_replay/controller/` + `Router` macro pattern for consistency.

## Architectural decisions

### D1 — Panel-addon API in phoenix_replay

`phoenix_replay`'s widget panel grows a small extension API:

- A DOM **slot** inside the panel form (`<div data-slot="form-top">`).
- A JS registration entrypoint: `window.PhoenixReplay.registerPanelAddon({ id, slot, mount })`.
- A `mount(ctx)` hook returning optional `{ beforeSubmit, onPanelClose }` callbacks.
- A new `extras` field on the `report()` call and `/submit` POST body, accumulated from all addons' `beforeSubmit` results, forwarded by the controller to the configured `Storage` adapter.

Audio is the first addon. Future addons (screenshot attach, tag picker, etc.) reuse the same surface. Phase 2 ships **only the `form-top` slot**; additional slots are deferred until a second addon needs them.

**Alternatives rejected:**
- Reaching into `phoenix_replay`'s panel DOM by selector from `ash_feedback`'s side — fragile; couples to internal markup.
- Building the recorder inside the demo first and promoting later — work doesn't end up in the library.

### D2 — `audio_start_offset_ms` lives in `AshStorage` attachment metadata

The offset is specific to the audio attachment, so it lives on the `Attachment.metadata` map, not on the `Feedback` row. Three benefits:

- `phoenix_replay`'s `phoenix_replay_feedbacks` table stays audio-free (no migration coupling).
- Co-location with the attachment is the natural shape for AshStorage.
- Playback (Phase 3) loads `feedback.audio_clip` and reads `metadata["audio_start_offset_ms"]` directly.

**Alternatives rejected:**
- New `Feedback` attribute / column — couples `phoenix_replay`'s schema to audio.
- Stuffing into `Feedback.metadata` — loose typing for a structured concept.

### D3 — `ash_feedback` controller + router macro mirror `phoenix_replay`

A new `lib/ash_feedback/controller/audio_uploads_controller.ex` exposes `POST /audio_uploads/prepare` and returns the AshStorage presigned URL + blob id. A new `AshFeedback.Router.audio_routes/0` macro mounts it in the host's existing pipeline. **No `lib/ash_feedback_web/` namespace** — the flat `lib/ash_feedback/controller/` shape matches `phoenix_replay` for consistency.

### D4 — `extras` is the integration channel for addons → Storage adapter

`phoenix_replay`'s `Storage` behaviour grows one optional argument: `extras` (map). Default adapters ignore it; `AshFeedback.Storage` extracts `audio_clip_blob_id` and `audio_start_offset_ms` and forwards them to `Feedback.submit`. Other libraries can add their own keys without touching `phoenix_replay`.

### D5 — Demo dev backend is `AshStorage.Service.Disk`

Zero-infra dev: `AshStorage.Service.Disk` mints `PUT /disk/:key` URLs against a local Plug. Real presigned-flow exercise without docker or a real S3 account. MinIO end-to-end smoke is deferred to a follow-up phase.

### D6 — Server-side test backend is Firkin

[`firkin`](https://hexdocs.pm/firkin/readme.html) is a Plug-based S3-compatible API library. We start it inside `ExUnit setup_all`, point `AshStorage.Service.S3` at it (with `presigned: true`), and exercise the **real** prepare → PUT → attach contract — not a mock. Catches AttachBlob wiring, presigned URL signing, and AshStorage's prepare-to-attach handoff that mocks would mask.

### D7 — Recorder UI is an inline pill above the severity row

Single-button state machine inside the panel form's `form-top` slot:
- **Idle**: `🎙 Record voice note`
- **Recording**: `■ Stop · M:SS` with live timer; cap warning at `audio_max_seconds - 30s`
- **Done**: `▶ M:SS · ✕ Re-record` with inline `<audio controls>` preview

Codec probe selects `audio/webm; codecs=opus` (primary) or `audio/mp4; codecs=mp4a.40.2` (Safari fallback). Permission denial renders an inline notice; the rest of the form remains usable.

## Component breakdown

```
┌─────────────── phoenix_replay (lib) ─────────────────────┐
│ panel-addon API (NEW):                                   │
│   • DOM slot inside form                                 │
│   • registerPanelAddon({id, slot, mount})                │
│   • report({extras}) + /submit body { extras: {...} }    │
│   • Storage callback gets extras (passthrough)           │
└──────────────────────────────────────────────────────────┘
                         ▲ registers "audio" addon
┌─────────────── ash_feedback (lib) ───────────────────────┐
│ • priv/static/assets/audio_recorder.js                   │
│ • lib/ash_feedback/controller/audio_uploads_controller   │
│ • lib/ash_feedback/router.ex (audio_routes/0)            │
│ • AshFeedback.Storage extras handler                     │
│ • Feedback.submit args: audio_clip_blob_id +             │
│   audio_start_offset_ms; AttachBlob change wires it      │
└──────────────────────────────────────────────────────────┘
                         ▲ host wires (one-time install)
┌─────────────── ash_feedback_demo (host) ─────────────────┐
│ • AshFeedbackDemo.Storage.{Blob, Attachment}             │
│ • AshStorage.Service.Disk + /disk/*key plug              │
│ • Router: AshFeedback.Router.audio_routes/0              │
│ • Layout: <script src=".../audio_recorder.js">           │
└──────────────────────────────────────────────────────────┘
```

### `phoenix_replay` panel-addon API (D1)

Three changes in `phoenix_replay`:

1. **DOM slot.** `renderPanel()` in `priv/static/assets/phoenix_replay.js` inserts a `<div class="phx-replay-panel-addons" data-slot="form-top"></div>` immediately above the severity row inside the form.
2. **`registerPanelAddon` JS API.** A top-level export on `window.PhoenixReplay`:

   ```js
   window.PhoenixReplay.registerPanelAddon({
     id: "audio",                 // unique; one entry per id
     slot: "form-top",            // slot name (only "form-top" in Phase 2)
     mount(ctx) {
       // ctx = { slotEl, sessionId, sessionStartedAtMs,
       //         onPanelClose(cb), reportError(message) }
       return { beforeSubmit, onPanelClose };  // both optional
     },
   });
   ```

   `beforeSubmit({ formData })` is `async` and returns `{ extras?: object }` or throws. The orchestrator runs all registered addons' `beforeSubmit` in series, merges every `extras`, and includes the merged map in the `report()` POST body.

3. **Submit pipeline.**
   - `report()` accepts an `extras` arg and sends it in the JSON body.
   - The form submit handler awaits all `beforeSubmit` hooks, merges `extras`, then calls `report({ ..., extras })`. A throw surfaces via the existing error screen.
   - `SubmitController` accepts `extras` (map) on the POST body and passes it to the `PhoenixReplay.Storage` callback as a new optional argument.

### `ash_feedback` audio addon (D2, D3, D4)

Four pieces:

1. **`priv/static/assets/audio_recorder.js`** — pure ES module, no build step. ~150–200 lines.
   - Self-registers via `window.PhoenixReplay.registerPanelAddon({ id: "audio", slot: "form-top", mount })`.
   - Codec probe: `audio/webm;codecs=opus` → fallback `audio/mp4;codecs=mp4a.40.2`. If neither, render a disabled mic + tooltip.
   - State machine UI per D7.
   - On record-start, captures `audio_start_offset_ms = Math.max(0, performance.now() - ctx.sessionStartedAtMs)` rounded to integer ms.
   - `beforeSubmit({ formData })`: if no captured blob, returns `{}`. Else POST to `/audio_uploads/prepare` (path overridable via `data-prepare-path` on the slot), PUT bytes to the returned URL, return `{ extras: { audio_clip_blob_id, audio_start_offset_ms } }`.

2. **`lib/ash_feedback/controller/audio_uploads_controller.ex`** — POST `/prepare` handler:

   ```elixir
   def prepare(conn, %{"filename" => filename, "content_type" => type, "byte_size" => size}) do
     feedback_resource = AshFeedback.Config.feedback_resource!()

     case AshStorage.Operations.prepare_direct_upload(
            feedback_resource, :audio_clip,
            filename: filename, content_type: type, byte_size: size
          ) do
       {:ok, %{blob: blob, url: url, method: method} = info} ->
         json(conn, %{
           blob_id: blob.id, url: url, method: to_string(method),
           fields: Map.get(info, :fields, %{})
         })

       {:error, error} ->
         conn |> put_status(422) |> json(%{error: Exception.message(error)})
     end
   end
   ```

   `AshFeedback.Config.feedback_resource!/0` reads `Application.get_env(:ash_feedback, :feedback_resource)` and raises with a helpful message if the host hasn't set it.

3. **`lib/ash_feedback/router.ex`** — new module:

   ```elixir
   defmacro audio_routes(opts \\ []) do
     path = Keyword.get(opts, :path, "/audio_uploads")
     quote do
       scope unquote(path), AshFeedback.Controller do
         post "/prepare", AudioUploadsController, :prepare
       end
     end
   end
   ```

   Host `pipe_through`s their pipeline before invoking the macro, mirroring `phoenix_replay`'s router macro pattern.

4. **`AshFeedback.Storage` + `Feedback.submit` changes.** The Storage callback receives `extras`, extracts `audio_clip_blob_id` and `audio_start_offset_ms`, and passes them to `Feedback.submit`. The `:submit` action gains two new optional `argument`s plus the `AshStorage.Changes.AttachBlob` change wired to `audio_clip_blob_id`. The offset is persisted onto the attachment's `metadata` map.

   **Open implementation question (verified in 2b first task):** does `AshStorage.Changes.AttachBlob` accept an option for setting attachment metadata at attach time? If yes, single change. If no, an `after_action` hook on `:submit` loads the freshly-attached attachment and updates its metadata.

### Demo wiring (D5)

- **Host AshStorage resources** — copy patterns from `~/Dev/ash_storage/dev/resources/blob.ex` + `attachment.ex` into `lib/ash_feedback_demo/storage/{blob,attachment}.ex`. Migration via `mix ash.codegen audio_storage`.
- **Service config** in `config/dev.exs`:

  ```elixir
  config :ash_storage, AshFeedbackDemo.Storage.Blob,
    service:
      {AshStorage.Service.Disk,
       root: Path.join(File.cwd!(), "tmp/uploads"),
       base_url: "http://localhost:4006",
       direct_upload: true}
  ```

- **Endpoint plug** — mount `AshStorage.Service.Disk.Plug` (or the equivalent) at `/disk`.
- **Router** — under the existing demo browser scope, call `AshFeedback.Router.audio_routes()`.
- **Root layout** — `<script defer src="/assets/ash_feedback/audio_recorder.js"></script>` served from `deps/ash_feedback/priv/static/assets/` via `Plug.Static`.

## Data flow on submit

1. User opens panel → audio addon mounts in `form-top` slot, idle UI rendered.
2. User clicks Record → `getUserMedia` → `MediaRecorder.start()`. `audio_start_offset_ms` captured.
3. User clicks Stop → blob assembled, addon transitions to "done" state with playback preview.
4. User clicks Submit on the panel form → `phoenix_replay`'s submit handler runs all addons' `beforeSubmit` hooks. Audio addon:
   - POST `/audio_uploads/prepare` → `{blob_id, url, method, fields}`.
   - PUT bytes to `url` (or POST form with `fields`).
   - Returns `{ extras: { audio_clip_blob_id: blob_id, audio_start_offset_ms: <int> } }`.
5. `phoenix_replay` POSTs `/submit` with the existing fields plus `extras: {...}`.
6. `SubmitController` calls `PhoenixReplay.Storage.store_session_feedback(session_id, attrs, extras)`.
7. `AshFeedback.Storage` extracts blob id + offset and calls `Feedback.submit`. `AttachBlob` change wires the blob; offset lands on attachment metadata (per D2 implementation outcome).

## Phasing

Five sub-phases, each ending with green tests + a commit so we can stop at any boundary.

| Sub-phase | Repo(s) | Scope | Done when |
|---|---|---|---|
| **2a** | `phoenix_replay` | Panel addon API: DOM slot, `registerPanelAddon`, `extras` through `report()` + `/submit` + `Storage` callback. **No audio code.** | A test addon registered in tests can mount + return extras that land in a stub `Storage` callback. |
| **2b** | `ash_feedback` | `audio_recorder.js` + `AudioUploadsController` + `Router.audio_routes/0` + `AshFeedback.Storage` extras handling + `Feedback.submit` arguments + `AttachBlob` change. | Resource macro tests pass with audio enabled; controller test green against a stub AshStorage service. |
| **2c** | `ash_feedback` | Firkin-backed end-to-end test: prepare → PUT → submit → verify Feedback row has `audio_clip` attached + offset on attachment metadata. | One `test "round-trip"` test passes. |
| **2d** | `ash_feedback_demo` | Host AshStorage Blob + Attachment resources, Disk service config, `/disk/*key` plug, `audio_routes()` mount, `<script>` tag, deps cp + force recompile + restart. | Browser smoke: open widget → record → submit → blob exists on disk → Feedback row references it. |
| **2e** | `ash_feedback` + `phoenix_replay` | CHANGELOG entries, README sections (recorder usage, `audio_max_seconds` config, browser support), commits, `mix deps.update` to pull library SHAs in the demo. | Both libraries' main branches updated; demo runs against released SHAs. |

Splitting 2a from 2b lets us verify the panel-addon API contract independently — catches API gaps before audio code rides on it.

## Test plan

### 2a (phoenix_replay)
- Unit test: `registerPanelAddon` with a stub addon mounts in the slot, returns extras from `beforeSubmit`, and the merged extras land in the `Storage` callback's third argument.
- Existing widget tests continue to pass.

### 2b (ash_feedback)
- **Controller test** — `POST /audio_uploads/prepare` returns `{blob_id, url, method, fields}`; AshStorage.Service.Test as backend.
- **Storage adapter test** — `AshFeedback.Storage.store_session_feedback/3` with extras containing `audio_clip_blob_id` and `audio_start_offset_ms` calls `Feedback.submit` with both arguments populated.
- **Resource macro test** — audio-enabled fixture compiles; `:submit` action accepts the new arguments.

### 2c (ash_feedback)
- **End-to-end** — Firkin in `setup_all`, AshStorage.Service.S3 pointed at it (with `presigned: true`):
  1. POST `/audio_uploads/prepare` → assert blob row created, URL points at Firkin.
  2. HTTP `PUT` fake bytes to the URL → assert 200.
  3. `Feedback.submit!(%{audio_clip_blob_id, audio_start_offset_ms})` → load `audio_clip: [:metadata, :blob]` → assert blob attached and metadata contains the offset.

### 2d (manual smoke in demo)
- Codec probe in Chrome (webm/opus path) and Safari (mp4 path).
- Permission denial UX (deny in browser → addon shows inline notice, rest of form usable).
- Cap enforcement (set `audio_max_seconds: 5` for smoke; verify 5s hard stop).
- Successful round-trip: file exists at `tmp/uploads/<key>`, Feedback row in DB references the blob id.

### Out of Phase 2 (per recurring debt)
- JS unit tests (codec probe table, timer math, offset calc) — own ADR.
- Headless browser test (Playwright/Puppeteer) — own ADR.

## Risks

| Risk | Mitigation |
|---|---|
| `phoenix_replay` panel addon API churns under future addon needs | Ship narrow (one slot, two hooks). Version the contract — addons opt into a specific API version field on the registration object. |
| Orphan blobs (user records but never submits) | Out of Phase 2 scope; accept short-term. Wire AshStorage GC patterns when a host complains. |
| `AshStorage.Changes.AttachBlob` doesn't accept attachment metadata at attach time | Verified in 2b first task. Fallback: `after_action` hook on `:submit` updates attachment metadata post-attach. |
| Browser `MediaRecorder` cap-enforcement lag (tab throttled) | Hard cap on `MediaRecorder.requestData` interval client-side + reject blob over `byte_size` server-side via the `prepare` arg. |
| Demo's Disk service has different presigned semantics than real S3 | 2c uses Firkin (real S3 contract) for tests; 2d uses Disk for dev only. Phase 2.5 (deferred) adds MinIO smoke before publish. |

## Out of scope (explicitly)

- **Phase 3** (admin playback synced to rrweb timeline) — separate phase, design unchanged.
- **`5f` auto-scaffold** — Igniter installer for the host AshStorage resources + Disk plug + script tag stays in 5f.
- **Server-side `audio_max_seconds` enforcement** — caps are client-side in Phase 2; server-side only validates `byte_size` from the prepare request. Hard server-side time enforcement deferred.
- **Transcription, voice-only feedback, system audio capture** — separate ADRs (per the active plan's "Follow-ups" list).

## Addendum 2026-04-24 — D2 revised to blob metadata

The Task 2b.1 recon (executed during plan execution) found two facts that revise D2:

1. `AshStorage.Changes.AttachBlob` does not accept a `metadata:` option at change-declaration time.
2. AshStorage's `AttachmentResource` extension does not add a `metadata` attribute — only `BlobResource` does.

Combined with the fact that `AshStorage.Operations.prepare_direct_upload/3` already accepts a `:metadata` option that's written to the blob row at prepare time, the pragmatic choice is to persist `audio_start_offset_ms` on the **blob's** metadata map, not the attachment's.

**Revised D2:** the offset is captured client-side at record-start, sent in the `/audio_uploads/prepare` POST body's `metadata` field, and persisted on the AshStorage Blob row's built-in `metadata :map`. The submit-side flow only carries `audio_clip_blob_id` through `extras` — no offset arg on the `:submit` action, no after_action hook, no Storage adapter offset handling.

The spec's prior D2 framing (offset on attachment metadata) stays as historical record; the plan's "Decisions log" section captures the revised path and propagates it through Tasks 2b.3 / 2b.5 / 2b.6 / 2b.7 / 2c.3.

## Decisions log (carry-forward from ADR-0001)

- **OQ1** — 5-minute max length default. ✓
- **OQ2** — `audio/webm; codecs=opus` primary, `audio/mp4` Safari fallback. ✓
- **OQ3** — single bundled `AshFeedback.Audio` namespace. Resolved differently than originally framed: ash_feedback ships the addon JS + controller; resource shapes (Blob/Attachment) stay host-defined per Phase 1's refinement.
- **OQ4** — per-host config flag + per-submission user affordance (the user can submit without recording).

# AshFeedback

> **Status: pre-1.0, pre-Hex.** APIs may still change. Validated against
> one production-style host (gs_net); other adopters should expect
> rough edges. See [Roadmap](#roadmap).

An Ash-native bug-report layer for [`phoenix_replay`](https://github.com/jhlee111/phoenix_replay).

`phoenix_replay` captures rrweb sessions from inside your app.
`ash_feedback` turns each submission into an Ash `Feedback` resource
with a triage state machine, version-tracked audit trail, PubSub
notifications, append-only comments, and (optionally) voice narration
synced to the replay timeline.

You write a 5-line concrete resource. The library produces the rest.

## Demo

A user reports an issue through the floating widget; an admin replays
the rrweb session from the triage page.

https://github.com/user-attachments/assets/b7f1ab30-60b2-4a2e-8ffb-d186bfa1e20d

Walkthrough source: [`docs/guides/demo-project.md`](docs/guides/demo-project.md).

## Why this exists

If you wire `phoenix_replay` to an Ash app by hand, you end up writing:

- A `Feedback` resource shaped for `phoenix_replay`'s submit payload
- A state machine for `new → acknowledged → in_progress → verified → resolved` (plus `dismissed`)
- `AshPaperTrail` so every transition keeps a diff
- `Ash.Notifier.PubSub` broadcasts so admin LiveViews can react
- An append-only `FeedbackComment` resource with the right policies
- Read actions for deploy-pipeline integration (preview blockers,
  verified-but-not-yet-shipped) and a generic action to bulk-resolve
  on ship
- A bridge between `phoenix_replay`'s storage protocol and your Ash
  domain, so policies + paper trail + tenant scoping all fire on
  submit instead of slipping past raw Ecto

`ash_feedback` ships all of that. Optionally, it also ships voice
narration synced to the rrweb cursor.

## What you get

- A `Feedback` resource exposed as a `use` macro — bring your own
  domain, repo, and (optional) `User` resource
- `AshStateMachine` triage workflow:
  ```
  new ─▶ acknowledged ─▶ in_progress ─▶ verified_on_preview ─▶ resolved
   │         │               │                    │
   └─────────┴───────────────┴────────────────────┴─▶ dismissed
  ```
- `AshPaperTrail` versions on every transition (optional actor tracking)
- `Ash.Notifier.PubSub` broadcasts on every lifecycle event ([topics below](#pubsub-topics))
- Append-only `FeedbackComment` resource — corrections are new comments,
  never edits
- `AshFeedback.Storage` — a `PhoenixReplay.Storage` implementation that
  routes the widget's `/submit` POST through your Ash domain
- Deploy-pipeline read actions: list preview blockers, list verified
  rows waiting on a ship, bulk-promote after deploy
- `AshPrefixedId` compatibility for hosts that use it (no library
  dependency on it; configurable per host)
- Optional audio narration that rides through `AshStorage` and plays
  back in lock-step with `phoenix_replay`'s timeline — gated by a
  compile-time flag, so bare hosts pay nothing

## What you write vs. what's bundled

**You write** (typically <50 lines of glue):

- One line in `mix.exs` (`{:ash_feedback, ...}`)
- A short `MyApp.Feedback` Ash `Domain` module
- A 5-line concrete `Feedback` resource (`use AshFeedback.Resources.Feedback, ...`)
- (Optional) A 5-line `FeedbackComment` resource
- One `<PhoenixReplay.UI.Components.phoenix_replay_widget>` tag in
  your layout — the visible "Report issue" button
- A `config :phoenix_replay, storage: {AshFeedback.Storage, ...}` line
- (Audio only) AshStorage `Blob` + `Attachment` resources, an
  `:audio_enabled` flag, and a router macro call

**The library provides automatically:**

- `AshFeedback.Storage` — bridge between `phoenix_replay`'s submit
  POST and your Ash domain (so policies + paper trail + tenant
  scoping all run on ingest)
- All `Feedback` attributes, state machine transitions, AshPaperTrail
  wiring, code interface (`submit!`, `acknowledge!`, `verify!`, …),
  and PubSub topics
- Append-only `FeedbackComment` with parent-status validation
- Type modules: `Status`, `Severity`, `Priority`, `DismissReason`,
  `Environment`
- (Audio only) presigned upload/download controllers, signed-URL
  playback component, rrweb-timeline sync

`phoenix_replay` (transitive dep) provides the widget component,
ingest endpoints, rrweb capture, and admin replay primitives.

## Requirements

- Elixir 1.17+
- Ash `~> 3.5`, AshPostgres `~> 2.6`, AshStateMachine `~> 0.2`,
  AshPaperTrail `~> 0.5`
- [`phoenix_replay`](https://github.com/jhlee111/phoenix_replay)
  installed and migrated. Its `mix phoenix_replay.install` task creates
  the `phoenix_replay_feedbacks` and `phoenix_replay_feedback_comments`
  tables this library binds to.
- (Optional) `ash_storage` — only when audio narration is enabled

## Installation

### 1. Add the dep

```elixir
# mix.exs
def deps do
  [
    {:ash_feedback, github: "jhlee111/ash_feedback", branch: "main"}
    # phoenix_replay comes transitively from ash_feedback's main branch.
    # To pin a specific SHA in production, add it explicitly with override:
    #   {:phoenix_replay, github: "jhlee111/phoenix_replay", ref: "<sha>", override: true},
  ]
end
```

### 2. Run `phoenix_replay`'s installer

`phoenix_replay` ships the migrations and config scaffolding for the
underlying tables. Follow its
[README](https://github.com/jhlee111/phoenix_replay#installation)
through `mix phoenix_replay.install` and `mix ecto.migrate`. Stop
before you set the `:storage` config key — this library provides the
implementation.

### 3. Point `phoenix_replay` at `AshFeedback.Storage`

```elixir
# config/config.exs
config :phoenix_replay,
  # ... your existing identify, metadata, session_token_secret ...
  storage: {AshFeedback.Storage, resource: MyApp.Feedback.Entry, repo: MyApp.Repo}
```

`AshFeedback.Storage` is a module shipped by this library that
implements the `PhoenixReplay.Storage` behaviour. Submissions go
through your Ash domain (so policies, paper trail, and tenant scoping
all apply); rrweb event blobs continue to stream through raw Ecto for
throughput.

> Not to be confused with `AshStorage`, a separate library used only
> by the optional [audio narration](#audio-narration-optional)
> feature. This step adds nothing beyond what's already in your deps.

### 4. Create the Ash domain and register it

```elixir
# lib/my_app/feedback.ex
defmodule MyApp.Feedback do
  use Ash.Domain, otp_app: :my_app

  resources do
    resource MyApp.Feedback.Entry
    resource MyApp.Feedback.Entry.Version  # auto-generated by AshPaperTrail
    resource MyApp.Feedback.Comment        # optional — skip if you don't need comments
  end
end
```

Then register the domain in your app config so Ash picks it up:

```elixir
# config/config.exs
config :my_app,
  ash_domains: [MyApp.Accounts, MyApp.Feedback]   # add MyApp.Feedback to your existing list
```

### 5. Create the concrete `Feedback` resource

```elixir
# lib/my_app/feedback/entry.ex
defmodule MyApp.Feedback.Entry do
  use AshFeedback.Resources.Feedback,
    domain: MyApp.Feedback,
    repo: MyApp.Repo,
    assignee_resource: MyApp.Accounts.User,
    pubsub: MyApp.PubSub
end
```

The macro emits a full Ash resource with attributes, the state
machine, paper trail, code interface, and notifier.

#### `use` options

| Option | Required | Purpose |
|---|---|---|
| `:domain` | yes | Your `Ash.Domain` module |
| `:repo` | yes | Your Ecto repo |
| `:otp_app` | no | OTP app name; needed by some Ash extensions |
| `:assignee_resource` | no | Your `User` module. If omitted, the `assignee` / `verified_by` / `resolved_by` relationships are not generated. |
| `:assignee_attribute_type` | conditional | FK column type. Default `:uuid`. **Required** if your User uses `AshPrefixedId` — see [AshPrefixedId compatibility](#ashprefixedid-compatibility). |
| `:pubsub` | no | `Phoenix.PubSub` server name. Omit to disable broadcasts. |
| `:paper_trail_actor` | no | `User` module passed to `AshPaperTrail`'s actor tracking. Adds a `user_id` column to the versions table — re-run `mix ash.codegen` after enabling. |
| `:audio_blob_resource` | conditional | Required when audio is enabled. Your AshStorage `Blob` resource. |
| `:audio_attachment_resource` | conditional | Required when audio is enabled. Your AshStorage `Attachment` resource. |

### 6. (Optional) Create the `FeedbackComment` resource

```elixir
# lib/my_app/feedback/comment.ex
defmodule MyApp.Feedback.Comment do
  use AshFeedback.Resources.FeedbackComment,
    domain: MyApp.Feedback,
    repo: MyApp.Repo,
    feedback_resource: MyApp.Feedback.Entry,
    author_resource: MyApp.Accounts.User,
    pubsub: MyApp.PubSub
end
```

Comments are append-only by design. Editing or deleting is
intentionally not supported — corrections happen by adding a new
comment.

### 7. Run codegen + migrate

The base tables (`phoenix_replay_feedbacks`,
`phoenix_replay_feedback_comments`) are owned by `phoenix_replay`'s
installer; you don't generate those. But `AshPaperTrail` produces a
`_versions` table for your concrete resource — emit that:

```bash
mix ash.codegen add_feedback_paper_trail
mix ash.migrate
```

### 8. Drop the Report issue widget into a layout

The visible "Report issue" button ships with `phoenix_replay`. Place
its component in your root layout (or any template):

```heex
<PhoenixReplay.UI.Components.phoenix_replay_widget
  base_path="/api/feedback"
  csrf_token={get_csrf_token()}
/>
```

`base_path` must match the router prefix where you mounted
`PhoenixReplay.Router` endpoints during step 2. The full data flow:

```
widget → POST {base_path}/submit
       → phoenix_replay's submit endpoint
       → AshFeedback.Storage (your :storage config)
       → MyApp.Feedback.Entry.submit!/1   ← runs policies, paper trail, notifier
```

For the full widget API (path scoping, audio mic toggle,
`window.PhoenixReplay.startRecording()`, etc.), see
[`phoenix_replay`'s README](https://github.com/jhlee111/phoenix_replay#installation).

## Data model

### `Feedback`

Generated when you `use AshFeedback.Resources.Feedback`. Stored in
`phoenix_replay_feedbacks`.

| Attribute | Type | Notes |
|---|---|---|
| `:id` | uuid (primary key) | |
| `:session_id` | string | Required. Max 128 chars. The rrweb session this report belongs to. |
| `:description` | string | The reporter's text. |
| `:severity` | `Severity` enum | `:info` / `:low` / `:medium` / `:high` / `:critical` |
| `:status` | `Status` enum | Default `:new`. Driven by the state machine. |
| `:priority` | `Priority` enum | `:low` / `:medium` / `:high` / `:critical` |
| `:reported_on_env` | `Environment` enum | `:dev` / `:staging` / `:preview` / `:prod` |
| `:metadata` | map (JSONB) | Free-form. The widget puts URL, viewport, user agent here. |
| `:identity` | map (JSONB) | Whatever your `phoenix_replay` `:identify` callback returned. |
| `:events_s3_key` | string | Pointer to the rrweb event blob in object storage (set by `phoenix_replay`). |
| `:pr_urls` | `[string]` | Default `[]`. Populated when transitioning to `:verified_on_preview`. |
| `:triage_notes` | string | |
| `:verified_at` | utc_datetime_usec | Set automatically by `:verify`. |
| `:resolved_at` | utc_datetime_usec | Set automatically by `:resolve`. |
| `:dismissed_reason` | `DismissReason` enum | `:not_a_bug` / `:wontfix` / `:duplicate` / `:cannot_reproduce` |
| `:audio_clip` | `has_one_attached` | Only present when audio narration is enabled. `dependent: :purge`. |
| `:inserted_at`, `:updated_at` | utc_datetime_usec | Auto-managed. |

Optional `belongs_to` relationships (only generated when
`:assignee_resource` is provided): `:assignee`, `:verified_by`,
`:resolved_by`.

A self-reference `belongs_to :related_to` is always generated for
grouping duplicates.

### `FeedbackComment`

Append-only. Stored in `phoenix_replay_feedback_comments`.

| Attribute | Type | Notes |
|---|---|---|
| `:id` | uuid (primary key) | |
| `:body` | string | Required. Min length 1. |
| `:inserted_at` | utc_datetime_usec | |

Relationships: `belongs_to :feedback` (required), `belongs_to :author`
(required).

Constraint: comments cannot be created on feedback whose status is
`:resolved` or `:dismissed`. Once a feedback closes, the conversation
is closed.

## Code interface

`use`'ing `AshFeedback.Resources.Feedback` generates these on your
concrete module:

```elixir
# Submission (called by AshFeedback.Storage when the widget POSTs)
MyApp.Feedback.Entry.submit!(%{
  session_id: "...",
  description: "Save button does nothing on the settings page",
  severity: :high,
  metadata: %{...},
  identity: %{...}
})

# Lookup
MyApp.Feedback.Entry.get_feedback!(id)
MyApp.Feedback.Entry.list_feedback!(severity: :high, limit: 50, offset: 0)

# Triage transitions (each runs the state machine, paper trail, and notifier)
MyApp.Feedback.Entry.acknowledge!(id, actor: user)
MyApp.Feedback.Entry.assign!(id, %{assignee_id: user_id}, actor: user)
MyApp.Feedback.Entry.verify!(id, %{pr_urls: ["https://..."], verified_by_id: user_id}, actor: user)
MyApp.Feedback.Entry.resolve!(id, %{resolved_by_id: user_id}, actor: user)
MyApp.Feedback.Entry.dismiss!(id, %{reason: :not_a_bug}, actor: user)

# Deploy pipeline
MyApp.Feedback.Entry.list_preview_blockers!()       # open + reported on preview
MyApp.Feedback.Entry.list_verified_non_preview!()   # verified, waiting on production ship
MyApp.Feedback.Entry.promote_verified_to_resolved!(
  %{promoted_at: DateTime.utc_now()},
  actor: deploy_user
)
```

`FeedbackComment` exposes:

```elixir
MyApp.Feedback.Comment.create_comment!(
  %{feedback_id: id, author_id: user.id, body: "..."},
  actor: user
)
MyApp.Feedback.Comment.list_by_feedback!(id)
MyApp.Feedback.Comment.get_comment!(id)
```

## State machine

| Action | From | To |
|---|---|---|
| `:acknowledge` | `:new` | `:acknowledged` |
| `:assign` | `:new`, `:acknowledged`, `:in_progress` | `:in_progress` |
| `:verify` | `:in_progress`, `:acknowledged` | `:verified_on_preview` |
| `:resolve` | `:verified_on_preview` | `:resolved` |
| `:dismiss` | `:new`, `:acknowledged`, `:in_progress`, `:verified_on_preview` | `:dismissed` |

`:resolved` is terminal. `:dismissed` is terminal.

## PubSub topics

When you pass `:pubsub`, every lifecycle event broadcasts on
`MyApp.PubSub`. All topics are prefixed with `feedback:`.

| Topic | Fires on |
|---|---|
| `feedback:created` | submit |
| `feedback:status_changed` | every transition |
| `feedback:assigned` | `:assign` |
| `feedback:verified` | `:verify` |
| `feedback:resolved` | `:resolve` |
| `feedback:dismissed` | `:dismiss` |
| `feedback:comment_added` | new `FeedbackComment` |

> **Implementation note.** Ash's `pub_sub do publish ... end` joins
> multi-segment topic lists into a single colon-separated topic. To
> fan out to two topics for one transition (e.g. both
> `status_changed` and `assigned` on `:assign`), the macro emits two
> `publish` lines. If you layer your own topics, do the same.

## AshPrefixedId compatibility

AshFeedback **does not depend on** `ash_prefixed_id`. It does support
hosts that use it.

If your `User` resource uses `AshPrefixedId`, pass the concrete
ObjectId type for the FK columns:

```elixir
use AshFeedback.Resources.Feedback,
  # ...
  assignee_resource: MyApp.Accounts.User,
  assignee_attribute_type: MyApp.Accounts.User.ObjectId
```

Same on `FeedbackComment` via `:author_attribute_type`.

The default `:uuid` short-name resolves to
`AshPrefixedId.AnyPrefixedId` on prefixed-ID hosts, which round-trips a
prefixed string into a raw UUID and breaks the `belongs_to` load.
Passing the concrete type fixes it.

For the same reason (no JSON-safe `dump_to_embedded` for prefixed
IDs), `AshPaperTrail` is configured to ignore `:assignee_id`,
`:verified_by_id`, `:resolved_by_id`, and `:related_to_id`. State
transitions still capture who-did-what via the action name + status
diff, so nothing meaningful is lost.

## Audio narration (optional)

Voice commentary on bug reports, played back in lock-step with the
rrweb cursor. The reporter taps the mic in the widget panel, records a
clip, submits; the audio rides through
[`AshStorage`](https://github.com/ash-project/ash_storage) (presigned
upload to S3, MinIO, Disk, or any compatible service) and links to
the feedback row.

**Default: off.** Bare hosts get the description-only flow with zero
change.

To enable:

1. Add `:ash_storage` to your deps. The library lists it as
   `optional: true`, so consumers must opt in:

   ```elixir
   {:ash_storage, github: "ash-project/ash_storage", branch: "main"}
   ```

2. Define your own `Blob` and `Attachment` resources. AshStorage does
   not ship these — they are host-owned because the data layer (S3 vs
   Disk vs MinIO), the bucket, and the auth strategy are yours. See
   the audio guide for a copy-pasteable starting point.

3. Set the compile-time flag and runtime config:

   ```elixir
   config :ash_feedback,
     audio_enabled: true,
     audio_attachment_resource: MyApp.Storage.Attachment,
     audio_max_seconds: 300,                 # default 300
     audio_download_url_ttl_seconds: 1800    # default 1800
   ```

4. Pass both resources to the macro:

   ```elixir
   use AshFeedback.Resources.Feedback,
     # ...
     audio_blob_resource: MyApp.Storage.Blob,
     audio_attachment_resource: MyApp.Storage.Attachment
   ```

5. Mount the audio routes:

   ```elixir
   # router.ex
   scope "/api" do
     pipe_through :api
     AshFeedback.Router.audio_routes(path: "/audio")
   end
   ```

   Mounts `POST /api/audio/prepare` (presigned upload) and
   `GET /api/audio/:blob_id` (signed download redirect).

6. Use the playback component in the admin UI:

   ```heex
   <AshFeedbackWeb.Components.audio_playback
     audio_url={@feedback_audio_url}
     session_id={@feedback.session_id}
   />
   ```

   The component subscribes to `phoenix_replay`'s timeline event bus
   so cursor and audio stay in sync.

Full setup — including AshStorage Blob/Attachment skeletons, browser
support matrix, and the timeline-bus contract — is in
[`docs/guides/audio-narration.md`](docs/guides/audio-narration.md).

## Deploy-pipeline integration

The two `list_*` read actions plus `promote_verified_to_resolved` are
designed for a CI/CD tool to query before a deploy and bulk-resolve
verified rows after a successful ship.

```elixir
# Before deploy: refuse to ship if preview has open blockers.
case MyApp.Feedback.Entry.list_preview_blockers!() do
  []       -> :ok
  blockers -> {:halt, "preview has #{length(blockers)} open blockers"}
end

# After deploy: bulk-resolve everything that was verified on preview.
MyApp.Feedback.Entry.promote_verified_to_resolved!(
  %{promoted_at: DateTime.utc_now()},
  actor: deploy_pipeline_user
)
```

A bearer-token-authed HTTP wrapper (`/api/internal/feedback/*`) is the
typical deployment shape; see the gs_net Phase 5d plan referenced in
`docs/plans/` for a reference implementation.

## Gotchas

1. **`AshPrefixedId` hosts must pass the concrete FK type** — see
   [AshPrefixedId compatibility](#ashprefixedid-compatibility).
   Default `:uuid` is wrong for those hosts.
2. **Actor tracking on PaperTrail needs a migration.** Pass
   `paper_trail_actor:` to the macro AND run `mix ash.codegen`
   afterward; it adds a `user_id` column to your versions table.
3. **`:verify` and `:resolve` use `require_atomic? false`** —
   intentional. They set `verified_at` / `resolved_at` via
   `&DateTime.utc_now/0` and run validations that need the loaded
   record. Don't try to remove it.
4. **Comments are blocked when feedback is closed.**
   `FeedbackComment.create` raises if the parent's status is
   `:resolved` or `:dismissed`.
5. **Audio is fully gated.** If you don't set `audio_enabled: true`,
   the `:audio_clip` attachment is not declared on the resource, the
   macro does not require Blob/Attachment opts, and
   `AshFeedback.Storage` silently drops `audio_clip_blob_id` from
   submission extras.

## Documentation

- [`docs/guides/demo-project.md`](docs/guides/demo-project.md) —
  end-to-end walkthrough on a fresh Phoenix+Ash app
- [`docs/guides/audio-narration.md`](docs/guides/audio-narration.md) —
  audio setup, timeline-bus contract, browser support
- [`docs/decisions/`](docs/decisions/) — ADRs (audio storage choice,
  optional dependency gating, lifecycle)
- [`docs/plans/`](docs/plans/) — forward roadmap with shipped phases
  under [`docs/plans/completed/`](docs/plans/completed/)

## Roadmap

Shipped:

- Phase 4a — Companion (storage adapter, resource, types)
- Phase 5a — Triage state machine + enums
- Phase 5b — `FeedbackComment` + PubSub + PaperTrail
- Phase 5d — Deploy-pipeline read actions + promote action
- ADR-0001 — Audio narration (recorder + presigned upload + admin
  playback synced to rrweb timeline)

Open:

- [Phase 5e](docs/plans/5e-integration-adapters.md) — Slack + GitHub
  Issues adapter stubs
- [Phase 5f](docs/plans/5f-igniter-installer.md) — Igniter installer
  (`mix ash_feedback.install`)
- [Phase 5g](docs/plans/5g-admin-live.md) — `AshFeedback.UI.AdminLive`
  (drop-in admin LiveView)
- Phase 6 — Hex publish

Until Phase 5g ships, the admin UI is your responsibility. The library
exposes the full Ash code interface and PubSub topics; wire them into
a LiveView in your app. The demo project at
`~/Dev/ash_feedback_demo` (referenced from the demo guide) is the
reference scaffold.

## License

MIT — see [LICENSE](LICENSE).

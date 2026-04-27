# Phase 5f — Igniter installer (`mix ash_feedback.install`) + admin generator

**Status**: proposed
**Est**: 4–6 hours for the base installer + 3–5 hours for the admin
generator extension (phoenix_replay's half is tracked in its own plan repo)

## Motivation

Today the install steps in [`../../README.md`](../../README.md) are
~20 minutes of manual copy-paste across ~8 touchpoints: mix.exs dep,
`:storage` config flip, domain module, concrete Feedback resource,
optional Comment resource, domain registered in `:ash_domains`,
`mix ash.codegen` + `mix ash.migrate`. That's a real risk of
misconfiguration for adopters, and it contradicts the Ash ecosystem
convention of `mix my_lib.install`.

[Igniter](https://hexdocs.pm/igniter) AST-patches the host codebase
so the whole thing becomes a single command.

## Scope

`mix ash_feedback.install` composes these Igniter patchers:

1. **Add dep** to `mix.exs` (skip if already present).
2. **Flip `:phoenix_replay :storage`** config to
   `{AshFeedback.Storage, resource: HostApp.Feedback.Entry, repo: HostApp.Repo}`.
   Detect the host app + repo module automatically; prompt if
   ambiguous.
3. **Generate domain** `HostApp.Feedback` with the 3 resources pre-
   registered (Entry, Entry.Version, Comment if opted in).
4. **Generate concrete Feedback resource** `HostApp.Feedback.Entry`
   with the `use AshFeedback.Resources.Feedback` macro pre-filled.
   Detect `assignee_resource` from
   `AshAuthentication.Info.authentication_resource/1` when available;
   otherwise prompt.
5. **Optional Comment resource** `HostApp.Feedback.Comment` (yes/no
   prompt, default yes).
6. **Register the domain** in `config :host_app, :ash_domains`.
7. **Prompt follow-up commands**: `mix ash.codegen add_feedback` +
   `mix ash.migrate`.

Host-specific resource type concerns (e.g. a User module that uses
`AshPrefixedId`) are the host's responsibility — the installer
generates with the default `:uuid` FK type, and hosts override
`:assignee_attribute_type` themselves when their User resource
demands it. The library does not detect or auto-patch.

Phoenix_replay's installer (tracked in that repo's plan) must run
first — document the dependency in the task's docstring and surface a
helpful error if `phoenix_replay`'s config isn't detected.

## Scope extension — admin LiveView generator (`--with-admin`)

Once the base installer ships, extend it with an opt-in admin
generator so hosts can scaffold a working triage UI in one command.

### Why a generator (not a drop-in LiveView)

Phase 5g originally proposed shipping `AshFeedback.UI.AdminLive` as
an in-library, mountable LiveView. That approach is gated on the
host's admin UX stabilizing for 2–3 weeks (see [5g-admin-live.md](5g-admin-live.md))
*and* it locks the library into Cinder + DaisyUI + a particular
auth/styling/layout shape that early adopters may not share.

A **generator** ships the same end-state (a working admin LiveView
in 1 command) without coupling the library to those choices: the
demo's `feedback_live.ex` becomes a templated file that gets
**copied into the host repo**, where the host owns it from then on.
Library updates do not flow through; the host customizes freely.

This is strictly additive to 5g — if community demand later forms
around a drop-in approach, 5g still ships on top.

### CLI flag

```bash
mix ash_feedback.install --with-admin
```

Accepts the same auto-detection inputs as the base installer
(host app name, repo, User module, AshAuthentication / AshPrefixedId
detection).

### What the generator emits

1. **`HostAppWeb.Admin.FeedbackLive`** — a LiveView module copied
   from a template based on the demo's
   `lib/ash_feedback_demo_web/live/admin/feedback_live.ex`.
   Contains:
   - Cinder table with status, severity, priority, env, assignee,
     inserted_at, description columns.
   - Right-sliding detail panel + replay player composition using
     `PhoenixReplay.UI.Components`.
   - Triage action modals: acknowledge / assign / verify / resolve
     / dismiss.
   - PubSub subscriptions to `feedback:created` /
     `feedback:status_changed` / `feedback:comment_added`.
   - Audio playback component (`AshFeedbackWeb.Components.audio_playback`)
     wired into the player layout.
2. **Router patch** — adds
   `live "/admin/feedback", HostAppWeb.Admin.FeedbackLive`
   inside an existing authenticated `scope` (or prompts the host
   to pick one). Skipped if the route already exists.
3. **Cinder dep** — adds `{:cinder, "~> 0.12"}` to `mix.exs` if not
   present.
4. **Deps message** — prints a "now run `mix deps.get` and restart
   your server" pointer.

### Template substitution rules

- `MyApp` / `MyAppWeb` → host's actual modules (auto-detected from
  `mix.exs`).
- `MyApp.Feedback.Entry` → whatever the base installer generated
  (or the host already has).
- `MyApp.Accounts.User` → detected from AshAuthentication or
  prompted.
- All Tailwind class strings are kept as-is; the host's Tailwind
  config picks them up via its content paths. DaisyUI is assumed to
  be present (typical Phoenix scaffold); if not, the host can
  retheme freely.

### Idempotency

Re-running `mix ash_feedback.install --with-admin` after the
generator has emitted a file:

- Detects the existing `HostAppWeb.Admin.FeedbackLive` and **does
  not overwrite it**. Prints a pointer instead. Once the file is in
  the host repo, ash_feedback never touches it again.

### Authorization handoff

The generated LiveView includes a TODO-marked auth pipeline call
referencing the host's existing pattern (e.g.
`ensure_authenticated`, `ensure_admin?`). The generator does not
invent an auth scheme — host fills it in once and edits the generated
file.

### Tests for the admin generator

- Igniter smoke: generate against a fresh `mix phx.new` fixture
  with AshAuthentication scaffold; confirm the LiveView module
  compiles and the route is reachable.
- Idempotency: second run produces zero diff on the existing
  LiveView file.
- Substitution: assert `MyApp` was replaced everywhere in the
  generated file; assert no leftover `MyApp` placeholders.

## Fallback for non-Igniter hosts

If Igniter isn't in the host's deps, the task should print a clear
pointer to the README manual steps rather than crashing. `Code.ensure_loaded?(Igniter)`
gates the behaviour.

## Tests

- Igniter smoke tests against a fresh `mix phx.new` dummy app
  fixture. Idempotency: re-running produces zero diff.
- Multi-shape fixtures:
  - Plain Phoenix + AshAuthentication user (happy path)
  - Phoenix without AshAuthentication (prompt branch)
- Manual verification: run the installer on a scratch app, submit a
  test feedback via the widget without any post-installer editing
  beyond filling in the README's TODO-comments
  (`session_token_secret`, identity callback).

## Definition of Done

- `mix ash_feedback.install` runs cleanly on a blank Phoenix app and
  the feedback resource persists a widget submission without manual
  editing.
- [`../../README.md`](../../README.md) installation section shortened
  to "run the installer, then fill in these 2 TODOs."
- Unit + smoke tests pass.

## Dependencies

- Requires phoenix_replay to ship its own Igniter installer first
  (tracked in phoenix_replay's plans repo).
- Add `{:igniter, "~> 0.6", optional: true}` to ash_feedback's deps.

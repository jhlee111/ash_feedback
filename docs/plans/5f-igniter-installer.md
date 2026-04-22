# Phase 5f — Igniter installer (`mix ash_feedback.install`)

**Status**: proposed
**Est**: 4–6 hours for the ash_feedback half (phoenix_replay's half is tracked in its own plan repo)

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
5. **AshPrefixedId detection** — if the target User resource lists
   `AshPrefixedId` in its extensions, pass
   `assignee_attribute_type: User.ObjectId` in the generated code
   (the documented gotcha — auto-handle it).
6. **Optional Comment resource** `HostApp.Feedback.Comment` (yes/no
   prompt, default yes).
7. **Register the domain** in `config :host_app, :ash_domains`.
8. **Prompt follow-up commands**: `mix ash.codegen add_feedback` +
   `mix ash.migrate`.

Phoenix_replay's installer (tracked in that repo's plan) must run
first — document the dependency in the task's docstring and surface a
helpful error if `phoenix_replay`'s config isn't detected.

## Fallback for non-Igniter hosts

If Igniter isn't in the host's deps, the task should print a clear
pointer to the README manual steps rather than crashing. `Code.ensure_loaded?(Igniter)`
gates the behaviour.

## Tests

- Igniter smoke tests against a fresh `mix phx.new` dummy app
  fixture. Idempotency: re-running produces zero diff.
- Multi-shape fixtures:
  - Plain Phoenix + AshAuthentication user (happy path)
  - Phoenix + AshPrefixedId user (FK type branch)
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

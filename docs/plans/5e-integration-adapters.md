# Phase 5e — Slack + GitHub Issues integration adapter stubs

**Status**: proposed
**Est**: 4–6 hours

## Scope

Scaffolding only — enough that a future adopter can wire Slack/GH
notifications with a small config change, not a fork. Opt-in per
adapter via the host's supervisor children.

## Design

### `AshFeedback.Integration` behaviour

```elixir
defmodule AshFeedback.Integration do
  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback handle_notification(Ash.Notifier.Notification.t()) :: any()
end
```

Each adapter is a GenServer that subscribes to `"feedback:*"` PubSub
topics in its `init/1` and handles notifications in
`handle_notification/1`.

### Host-owned supervisor wiring

Adapter registration is **explicit** in the host's supervision tree.
The library does NOT auto-start adapters — surprise startup behavior
violates CLAUDE.md "no surprises in libraries."

```elixir
# Host's application.ex
children = [
  # ...
  {AshFeedback.Integrations.Slack,
    webhook_url: System.get_env("SLACK_WEBHOOK")},
  {AshFeedback.Integrations.GithubIssues,
    token: System.get_env("GH_TOKEN"),
    repo: "acme/bugs"}
]
```

### `AshFeedback.Integrations.Slack`

- Subscribes to `feedback:created` and `feedback:status_changed`
- Config: `webhook_url`, `events: [...]` (filter), `format: {M, F}`
  (host formatter — ships a sane default)
- Posts to the Slack webhook with summary + deep-link

### `AshFeedback.Integrations.GithubIssues`

- Subscribes to `feedback:status_changed` where `to == :acknowledged`
- Creates a GH issue via a configurable HTTP client (token + repo
  from config)
- Body includes description, severity, replay deep-link (requires
  `base_url` config), reporter identity
- Stores resulting issue URL on the feedback row via an update action
  (host must configure a writable `external_issue_url` attribute;
  MVP just logs the URL)

## Tests

- Unit: adapter GenServers start, subscribe to the expected PubSub
  topics, and call mocked HTTP clients with the correct payload
  shape.
- No host integration test — this phase ships scaffolding only.

## Definition of Done

- `AshFeedback.Integration` behaviour defined
- `AshFeedback.Integrations.Slack` + `.GithubIssues` compile and
  pass unit tests
- Documented in [`../../README.md`](../../README.md)
- Not wired into any host in this repo

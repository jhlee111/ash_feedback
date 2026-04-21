# AshFeedback

> **Status:** pre-alpha. API not frozen. Do not use in production.

Ash-native storage adapter + resource for
[`phoenix_replay`](../phoenix_replay). Plug it in as the
`PhoenixReplay.Storage` backend and feedback writes route through your
Ash domain — policies, paper trail, and `AshPrefixedId` apply
automatically.

## Why not a single combined package?

Ash is a strong opinion; `phoenix_replay` stays Ash-free so that
non-Ash hosts can adopt it. This companion gives Ash users idiomatic
ergonomics without forcing Ash on the core. Mirrors the established
`ash_oban` / `ash_phoenix` pattern.

## Status

- [ ] Phase 4a — Ash companion (storage adapter, resource, types, policies)

The broader roadmap lives in
[`phoenix_replay`'s README](../phoenix_replay/README.md).

## Installation

_(not yet published)_

```elixir
def deps do
  [
    {:phoenix_replay, path: "../phoenix_replay"},
    {:ash_feedback,  path: "../ash_feedback"}
    # Later: both via Hex
  ]
end
```

## Quick start (design target — not implemented yet)

```elixir
config :phoenix_replay,
  storage: {AshFeedback.Storage, domain: MyApp.Feedback}

# Use AshFeedback.Resources.Feedback directly, or alias it into your
# own domain. Migrations are owned by phoenix_replay's mix task
# (`mix phoenix_replay.install`); the resource sets
# `postgres do migrate? false end` so `ash.codegen` never drifts.
```

## License

MIT. See [LICENSE](LICENSE).

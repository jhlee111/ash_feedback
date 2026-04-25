# ash_feedback — Plans

Forward-looking work plans. Completed phases are summarized in
[`../../README.md`](../../README.md) under **Status** and live in git
history; this directory holds plans that are **proposed** or
**in-progress**. New plans belong under `active/`, `backlog/`,
`proposals/`, or `completed/`; legacy phase files remain flat until
re-filed.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| —  | Audio narration via AshStorage (ADR-0001) | Phase 1 in progress | [active/2026-04-24-audio-narration.md](active/2026-04-24-audio-narration.md) |
| 5e | Slack + GitHub Issues adapter stubs | proposed | [5e-integration-adapters.md](5e-integration-adapters.md) |
| 5f | Igniter installer (`mix ash_feedback.install`) | proposed | [5f-igniter-installer.md](5f-igniter-installer.md) |
| 5g | `AshFeedback.UI.AdminLive` (Cinder drop-in) | proposed, gated | [5g-admin-live.md](5g-admin-live.md) |
| 6  | Hex publish | deferred | — |

## Proposals (drafted, not yet committed)

_None._

**Gated** = do not start until an upstream precondition clears. For
5g that's "primary host's admin UI stable for 2–3 weeks of real QA
usage"; extracting before the UX settles churns the library in
lockstep.

## Completed phases (historical)

| # | Scope | Shipped in |
|---|-------|-----------|
| 4a | Companion shipped (storage adapter, resource, types) | Phase 4a commits |
| 5a.0 | Deps + test-app fixtures | `b0904f2` / `8c7bd34` |
| 5a | Triage state machine + enum types + `promote_verified_to_resolved` | `b0904f2` |
| 5b | FeedbackComment + PubSub + PaperTrail | `bc9fcff` |
| 5d | Deploy-pipeline read actions (`list_verified_non_preview`, `list_preview_blockers`) | `65a4c2d` |

Details live in each commit's message.

# ash_feedback — Plans

Forward-looking work plans. Completed phases are summarized in
[`../../README.md`](../../README.md) under **Status** and live in git
history; this directory holds plans that are **proposed** or
**in-progress**.

Originating cross-cutting plan (covers gs_net integration + both
libraries): [gs_net/docs/plans/active/2026-04-21-feedback-triage.md](
https://github.com/jhlee111/gs-net/blob/main/docs/plans/active/2026-04-21-feedback-triage.md).
Library-scoped slices split out here so the library repo can be read
standalone.

## Index

| # | Phase | Status | File |
|---|-------|--------|------|
| 5e | Slack + GitHub Issues adapter stubs | proposed | [5e-integration-adapters.md](5e-integration-adapters.md) |
| 5f | Igniter installer (`mix ash_feedback.install`) | proposed | [5f-igniter-installer.md](5f-igniter-installer.md) |
| 5g | `AshFeedback.UI.AdminLive` (Cinder drop-in) | proposed, gated | [5g-admin-live.md](5g-admin-live.md) |
| 6  | Hex publish | deferred | — |

**Gated** = do not start until an upstream precondition clears. For
5g that's "gs_net admin UI stable for 2–3 weeks of real QA usage";
extracting before the UX settles churns the library in lockstep.

## Completed phases (historical)

| # | Scope | Shipped in |
|---|-------|-----------|
| 4a | Companion shipped (storage adapter, resource, types) | Phase 4a commits |
| 5a.0 | Deps + test-app fixtures | `b0904f2` / `8c7bd34` |
| 5a | Triage state machine + enum types + `promote_verified_to_resolved` | `b0904f2` |
| 5b | FeedbackComment + PubSub + PaperTrail | `bc9fcff` |
| 5d | Deploy-pipeline read actions (`list_verified_non_preview`, `list_preview_blockers`) | `65a4c2d` |

Details live in each commit's message + the originating gs_net plan.

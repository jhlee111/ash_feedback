# Architecture Decision Records

Ash-specific 결정의 기록 (resource shape, policy, scope, paper trail, triage workflow). 핵심 라이브러리(capture + ingest + storage behaviour + UI primitives) 설계는 [phoenix_replay/docs/decisions/](https://github.com/jhlee111/phoenix_replay/tree/main/docs/decisions)에 있음.

| # | Title | Status | Date |
|---|-------|--------|------|
| _(첫 ADR 작성 전)_ | | | |

## Rules

- 번호는 순차, 재사용 금지
- Status: `Proposed` → `Accepted` → `Superseded by ADR-XXXX`
- 기존 ADR은 수정하지 않음 — 변경은 새 ADR로 supersede
- **Scope**: "Ash 없는 Phoenix 앱에서도 의미 있나?" → Yes면 phoenix_replay에, No면 여기에.

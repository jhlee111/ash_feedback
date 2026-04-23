# ash_feedback Documentation Vault

> **Purpose**: 라이브러리의 설계 결정, 작업 계획, 운영 지식의 **Single Source of Truth**.
> 사용법은 [top-level README](../README.md)와 ExDoc을 참조. 이 폴더는 **왜 이렇게 설계했는지**와 **앞으로의 작업 계획**을 담습니다.

구조는 대규모 애플리케이션의 docs vault 관행(`decisions/` + `plans/` + `guides/` + `archive/`)을 라이브러리 범위에 맞게 축소한 버전입니다. 앱 전용 폴더(`contexts/`, `e2e/`, `infrastructure/`)는 제외.

ash_feedback은 `phoenix_replay`의 Ash wrapper입니다 (Oban / ash_oban 관계와 동일). 핵심 라이브러리 설계 결정(capture, storage behaviour, 트리거 UX 등)은 [phoenix_replay/docs/decisions/](https://github.com/jhlee111/phoenix_replay/tree/main/docs/decisions)에 있고, 이 저장소의 ADR은 **Ash-specific 결정**(resource 모양, policy, paper trail, triage workflow 등)만 담습니다.

---

## Trust Hierarchy

문서 간 내용이 충돌하면 **위에 있는 것이 정답**:

| Priority | Source | Why |
|----------|--------|-----|
| **1st** | `decisions/` (ADRs) | Ash-specific 결정의 공식 기록. Supersede 체인. |
| **2nd** | `plans/README.md` | 현재 phase 대시보드 + 우선순위. |
| **3rd** | `guides/` | 통합/운영 매뉴얼. 코드와 함께 검증됨. |
| **4th** | 코드 + ExDoc | 구현된 것의 SOT — 문서가 코드와 다르면 코드가 정답. |

---

## Folder Taxonomy

### `decisions/` — Architecture Decision Records (ADRs)

Ash-specific 결정 (resource 모양, action/policy, paper trail, scope) 의 공식 기록. 핵심 라이브러리 설계는 `phoenix_replay/docs/decisions/`.
- 번호는 순차, 재사용 금지
- Status: `Proposed` → `Accepted` → `Superseded by ADR-XXXX`
- 기존 ADR은 수정하지 않음 — 변경은 새 ADR로 supersede

### `plans/` — 작업 계획

- `README.md` — 현재 phase 대시보드 + 완료 이력
- `active/` — 진행 중인 계획
- `backlog/` — 시작 전 (우선순위 있음)
- `proposals/` — 아이디어 단계
- `completed/` — 완료 후 참고용

Phase 4a~5 기존 플랜 파일들은 루트에 flat하게 존재. 새 플랜은 해당 하위 폴더에 배치.

### `guides/` — 실행 가능한 매뉴얼

Consumer가 따라할 수 있는 통합 가이드, 운영 절차. 코드와 함께 검증됨. 예: "demo project 구성".

### `archive/` — Superseded 문서

Supersede된 ADR이나 더 이상 현행이 아닌 문서 참고용 보관.

---

## Upstream

core 라이브러리: [phoenix_replay](https://github.com/jhlee111/phoenix_replay) — rrweb 캡처 + ingest endpoints + storage behaviour + default Ecto adapter + admin UI primitives. ash_feedback은 이 라이브러리의 `PhoenixReplay.Storage` behaviour를 Ash Resource로 구현하여 Ash 사용자에게 idiomatic한 통합을 제공합니다.

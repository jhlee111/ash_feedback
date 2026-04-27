# Phase 5g — `AshFeedback.UI.AdminLive` (Cinder drop-in admin UI)

**Status**: proposed, **gated**
**Est**: 8–12 hours (extract + abstract + tests + docs)

## Gate: don't start until BOTH preconditions clear

1. **Reference host UI is stable** — a reference admin LV
   (~1034 lines) lives in the primary consuming host. Extracting
   **before** its UX settles means the library churns in lockstep
   with every host-side tweak. Need 2–3 weeks of real QA usage with
   no substantive layout/interaction changes.

2. **Phase 5f's `--with-admin` generator has shipped, and adopters
   are asking for a drop-in** — the generator copies the demo's
   admin into the host repo as a starting point; that addresses
   the immediate "I just want a working triage UI" need without
   coupling the library to Cinder/DaisyUI/auth choices. 5g layers a
   library-managed drop-in *on top* of that, but only makes sense
   if community demand surfaces for an upgrade path that flows
   library updates through (instead of host owning the file
   forever).

Until both signals arrive, host-owned generated files remain the
forward path for fast adoption.

## Motivation

Hosts without an existing admin UI currently have to build a 500+ line
Cinder LV from scratch to triage feedback. Shipping a drop-in means
"install + configure auth" is enough to go zero-to-triage.

## Scope

### `AshFeedback.UI.AdminLive` (drop-in LiveView)

- Mounted via `live "/feedback", AshFeedback.UI.AdminLive` in the
  host router.
- Cinder table with columns: status, priority, severity, env,
  assignee, inserted_at, description (truncated).
- Built-in filters: status, severity, priority, assignee (with
  "me / unassigned / all" quick filter).
- Right-sliding detail panel: description, metadata, identity,
  replay iframe slot.
- Comment thread (list + append form) via
  `AshFeedback.UI.Components.comment_thread/1`.
- Action bar: acknowledge / assign (me / user-search) / verify
  (pr_urls + note) / dismiss (reason) modals.
- PubSub subscriptions: `feedback:created`, `feedback:status_changed`,
  `feedback:comment_added` → auto-refresh.

### `AshFeedback.UI.Components` (standalone function components)

For hosts that want to compose their own LV:

- `feedback_table/1` — Cinder wrapper
- `detail_panel/1`
- `comment_thread/1`
- `verify_modal/1`, `dismiss_modal/1`, `assign_modal/1`
- `status_badge/1`, `severity_badge/1`, `priority_badge/1` — render
  via `AshFeedback.Types.*` icon/color metadata

### Host integration points (stay OUT of the library)

Everything host-specific goes behind a hook so the library doesn't
leak opinions:

| Hook | Default | Purpose |
|------|---------|---------|
| `:actor_assign` | `:current_user` | Which assign holds the Ash actor |
| `:user_display_fn` | `{String.Chars, :to_string}` (email) | Render assignee/author — hosts override with `{MyApp, :display_name}` |
| `:can_fn` | `fn _action, _record, _actor -> true end` | Permission gate — hosts using AshGrant plug in `Entry.can_acknowledge?/2` etc. |
| `:replay_iframe_src_fn` | `nil` | Optional replay player URL builder |

### Cinder as optional dep

```elixir
{:cinder, "~> 0.12", optional: true}
```

At compile time, detect Cinder's presence and expose `AdminLive` only
if it's loaded. Components that don't use Cinder (modals, badges,
`comment_thread`) remain available unconditionally.

## Tests

- LV mount + filter + row-click + action-modal open/submit flows
  against a fixture feedback set.
- PubSub refresh — two connected LVs, an action on one broadcasts to
  the other.
- Smoke: `mix ash_feedback.install` (Phase 5f) + mount `AdminLive`
  on a scratch app → end-to-end triage flow works without any
  host-side LV code.

## Definition of Done

- A host can `live "/admin/feedback", AshFeedback.UI.AdminLive`
  (plus their own auth pipeline) and triage feedback with zero LV
  code of their own.
- An existing host-side custom `FeedbackLive` can stay or be swapped
  for the library version — both approaches work.
- Documented in [`../../README.md`](../../README.md) and in
  [`../guides/demo-project.md`](../guides/demo-project.md) (the
  guide currently ships a copy-paste inline LV as a placeholder
  until this phase lands).

## Post-5g follow-up

Pencil in 2–4h for host-side migration if the decision is to adopt
the library LV instead of keeping the custom one. Tracked in the
host's planning, not here.

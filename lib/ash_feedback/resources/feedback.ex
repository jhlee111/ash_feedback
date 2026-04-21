defmodule AshFeedback.Resources.Feedback do
  @moduledoc """
  Ash resource mirroring the `phoenix_replay_feedbacks` table owned by
  `phoenix_replay`'s migration.

    * `postgres do migrate? false end` — migrations stay owned by
      `mix phoenix_replay.install`; `ash.codegen` will not emit a
      drift migration for this table.
    * `AshPrefixedId` with prefix `"fbk"` (configurable via
      `config :ash_feedback, prefix: "xyz"`).
    * Severity is an `Ash.Type.Enum` (`AshFeedback.Types.Severity`).
    * Optional `AshPaperTrail` extension — enabled when the app lists
      it as a hard dep.

  Example AshGrant scopes (recorded in the module source for reference
  — hosts lift them into their own permissions config):

      scope :always, true
      scope :at_own_tenant,
        expr(fragment("?->>'tenant_id'", metadata) == ^actor(:tenant_id))
      scope :triaged, expr(not is_nil(assignee_id))
  """

  # Implementation lands in Phase 4a.
end

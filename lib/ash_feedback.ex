defmodule AshFeedback do
  @moduledoc """
  Ash companion for [`phoenix_replay`](https://hex.pm/packages/phoenix_replay).

  Exposes `AshFeedback.Storage` as a `PhoenixReplay.Storage`
  implementation that writes through an Ash domain, so policies,
  paper trail, and prefixed IDs apply to every feedback submission.

  See `AshFeedback.Storage` for configuration, and
  `AshFeedback.Resources.Feedback` for the resource contract.
  """
end

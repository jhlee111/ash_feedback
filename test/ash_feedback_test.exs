defmodule AshFeedbackTest do
  use ExUnit.Case

  doctest AshFeedback

  describe "public API surface" do
    test "depends on phoenix_replay and declares Storage behaviour" do
      assert Code.ensure_loaded?(PhoenixReplay.Storage)
      assert Code.ensure_loaded?(AshFeedback.Storage)

      behaviours =
        AshFeedback.Storage.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixReplay.Storage in behaviours,
             "AshFeedback.Storage must declare @behaviour PhoenixReplay.Storage"
    end
  end
end

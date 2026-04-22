defmodule AshFeedback.Test.PubSub do
  @moduledoc false
  # Convenience for tests — returns the registered Phoenix.PubSub name
  # used by the library test-app, and provides subscribe/0.

  @name :ash_feedback_test_pubsub
  def name, do: @name

  def start_link(_opts \\ []), do: Phoenix.PubSub.Supervisor.start_link(name: @name)

  def subscribe(topic), do: Phoenix.PubSub.subscribe(@name, topic)
end

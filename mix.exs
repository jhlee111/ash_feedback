defmodule AshFeedback.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jhlee111/ash_feedback"

  def project do
    [
      app: :ash_feedback,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex
      description:
        "Ash-native storage adapter and resource for PhoenixReplay. " <>
          "Gives Ash apps idiomatic feedback ingestion with policies, " <>
          "paper trail, and prefixed IDs.",
      package: package(),

      # Docs
      name: "AshFeedback",
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Library consumers get phoenix_replay transitively from github main.
      # Override in the consumer's mix.exs with a pinned ref + `override: true`
      # when you want to lock to a specific SHA (recommended for production).
      # For active local library development, swap to `path: "../phoenix_replay"`.
      {:phoenix_replay, github: "jhlee111/phoenix_replay", branch: "main"},
      {:ash, "~> 3.5"},
      {:ash_postgres, "~> 2.6"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_paper_trail, "~> 0.5"},
      # Optional — gates the audio narration feature (ADR-0001).
      # Hosts opt in by adding `ash_storage` to their own deps and
      # setting `config :ash_feedback, audio_enabled: true`. Default
      # off; the Feedback resource's shape is unchanged when disabled.
      # Tracks `main` until ash_storage cuts a Hex release; switch to
      # `~> 0.1` then.
      {:ash_storage, github: "ash-project/ash_storage", branch: "main", optional: true},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

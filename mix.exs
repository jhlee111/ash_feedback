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
      # Consumer apps can override this with a pinned ref or path dep.
      {:phoenix_replay, git: "https://github.com/jhlee111/phoenix_replay.git"},
      {:ash, "~> 3.5"},
      {:ash_postgres, "~> 2.6"},
      {:ash_paper_trail, "~> 0.5", optional: true},
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

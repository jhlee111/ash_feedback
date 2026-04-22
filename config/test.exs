import Config

config :ash_feedback, ash_domains: [AshFeedback.Test.Accounts, AshFeedback.Test.Feedback]
config :ash_feedback, ecto_repos: [AshFeedback.Test.Repo]

config :ash_feedback, AshFeedback.Test.Repo,
  username: System.get_env("POSTGRES_USER", System.get_env("USER")),
  password: System.get_env("POSTGRES_PASSWORD", ""),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "ash_feedback_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool_size: 10,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [column: :id, type: :binary_id]

config :logger, level: :warning

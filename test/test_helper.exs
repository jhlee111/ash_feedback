{:ok, _} = Application.ensure_all_started(:ecto_sql)

_ = AshFeedback.Test.Repo.__adapter__().storage_up(AshFeedback.Test.Repo.config())

Ecto.Migrator.with_repo(AshFeedback.Test.Repo, fn repo ->
  Ecto.Migrator.run(
    repo,
    Path.expand("../priv/test_repo/migrations", __DIR__),
    :up,
    all: true,
    log: false
  )
end)

{:ok, _} =
  AshFeedback.Test.Repo.start_link(
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10
  )

{:ok, _} = AshFeedback.Test.PubSub.start_link()

Ecto.Adapters.SQL.Sandbox.mode(AshFeedback.Test.Repo, :manual)

ExUnit.start()

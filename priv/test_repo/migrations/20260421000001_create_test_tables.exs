defmodule AshFeedback.Test.Repo.Migrations.CreateTestTables do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    # Mirrors phoenix_replay's base schema plus the Phase 5a upgrade_triage columns.
    create table(:phoenix_replay_feedbacks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :description, :text
      add :severity, :string
      add :events_s3_key, :string
      add :metadata, :jsonb, default: fragment("'{}'::jsonb"), null: false
      add :identity, :jsonb, default: fragment("'{}'::jsonb"), null: false

      # upgrade_triage additions
      add :status, :string, null: false, default: "new"
      add :priority, :string
      add :assignee_id, :binary_id
      add :pr_urls, {:array, :string}, null: false, default: []
      add :triage_notes, :text
      add :reported_on_env, :string
      add :verified_by_id, :binary_id
      add :verified_at, :utc_datetime_usec
      add :resolved_by_id, :binary_id
      add :resolved_at, :utc_datetime_usec
      add :dismissed_reason, :string
      add :related_to_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:phoenix_replay_feedbacks, [:session_id])
    create index(:phoenix_replay_feedbacks, [:status])
    create index(:phoenix_replay_feedbacks, [:assignee_id])
    create index(:phoenix_replay_feedbacks, [:reported_on_env])
  end
end

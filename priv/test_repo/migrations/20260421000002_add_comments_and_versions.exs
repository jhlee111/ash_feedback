defmodule AshFeedback.Test.Repo.Migrations.AddCommentsAndVersions do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:phoenix_replay_feedback_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :feedback_id, :binary_id, null: false
      add :author_id, :binary_id, null: false
      add :body, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:phoenix_replay_feedback_comments, [:feedback_id])

    create table(:phoenix_replay_feedbacks_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version_action_type, :string, null: false
      add :version_action_name, :string, null: false
      add :version_source_id, :binary_id, null: false
      add :status, :string
      add :reported_on_env, :string
      add :changes, :jsonb
      add :version_inserted_at, :utc_datetime_usec, null: false
      add :version_updated_at, :utc_datetime_usec, null: false
    end

    create index(:phoenix_replay_feedbacks_versions, [:version_source_id])
  end
end

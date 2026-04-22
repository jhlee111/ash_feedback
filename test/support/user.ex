defmodule AshFeedback.Test.User do
  @moduledoc false
  use Ash.Resource,
    domain: AshFeedback.Test.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo AshFeedback.Test.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

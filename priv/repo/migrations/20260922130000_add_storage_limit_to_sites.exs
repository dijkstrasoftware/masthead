defmodule Masthead.Repo.Migrations.AddStorageLimitToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :storage_limit_bytes, :bigint
    end
  end
end

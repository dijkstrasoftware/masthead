defmodule Masthead.Repo.Migrations.AddProfileToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :display_name, :citext
      add :avatar_path, :string
    end

    # Seed every existing account with its email's local part, de-duplicated
    # by appending the id to every collision but the first.
    execute """
    UPDATE users u
    SET display_name = s.name
    FROM (
      SELECT id,
             split_part(email::text, '@', 1) ||
               CASE WHEN row_number() OVER (
                      PARTITION BY lower(split_part(email::text, '@', 1)) ORDER BY id
                    ) = 1 THEN '' ELSE '-' || id::text END AS name
      FROM users
    ) s
    WHERE u.id = s.id
    """

    alter table(:users) do
      modify :display_name, :citext, null: false
    end

    create unique_index(:users, [:display_name])
  end

  def down do
    alter table(:users) do
      remove :display_name
      remove :avatar_path
    end
  end
end

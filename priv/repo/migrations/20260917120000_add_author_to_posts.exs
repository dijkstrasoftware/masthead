defmodule Masthead.Repo.Migrations.AddAuthorToPosts do
  use Ecto.Migration

  def up do
    alter table(:posts) do
      add :author_id, references(:users, on_delete: :nilify_all)
    end

    create index(:posts, [:author_id])

    # Existing posts predate authorship. A site with a single member can only
    # have been written by that member; multi-member sites stay unattributed.
    execute """
    UPDATE posts p
    SET author_id = m.user_id
    FROM (
      SELECT site_id, min(user_id) AS user_id
      FROM site_memberships
      GROUP BY site_id
      HAVING count(*) = 1
    ) m
    WHERE p.site_id = m.site_id
    """
  end

  def down do
    alter table(:posts) do
      remove :author_id
    end
  end
end

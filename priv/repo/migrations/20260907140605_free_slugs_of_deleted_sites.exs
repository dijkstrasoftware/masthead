defmodule Masthead.Repo.Migrations.FreeSlugsOfDeletedSites do
  use Ecto.Migration

  # Sites deleted before the rename-on-delete change still hold their slug
  # hostage. Suffix them the same way, so those names come free.
  def up do
    execute("""
    UPDATE sites
       SET slug = slug || '-deleted-' || substr(md5(random()::text), 1, 8)
     WHERE deleted_at IS NOT NULL
       AND slug !~ '-deleted-[0-9a-f]{8}$'
    """)
  end

  # The original slug is recoverable from the suffixed one (that's what
  # restoring a site does), so there is nothing to undo here.
  def down, do: :ok
end

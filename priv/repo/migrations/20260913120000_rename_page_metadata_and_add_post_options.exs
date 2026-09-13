defmodule Masthead.Repo.Migrations.RenamePageMetadataAndAddPostOptions do
  use Ecto.Migration

  def change do
    rename table(:pages), :metadata, to: :page_options

    alter table(:posts) do
      add :post_options, :map, null: false, default: %{}
    end
  end
end

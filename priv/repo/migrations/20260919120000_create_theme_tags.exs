defmodule Masthead.Repo.Migrations.CreateThemeTags do
  use Ecto.Migration

  @starter_tags [
    "Blog",
    "Portfolio",
    "Business",
    "Magazine",
    "Personal",
    "Newsletter",
    "Documentation",
    "Landing page",
    "Photography",
    "Restaurant",
    "Agency",
    "Nonprofit",
    "Podcast",
    "Events",
    "Shop",
    "Resume",
    "Wedding",
    "Education",
    "Minimal",
    "Dark",
    "Light",
    "Colorful",
    "Bold",
    "Elegant",
    "Playful",
    "Retro",
    "Serif",
    "Monospace",
    "Image-heavy",
    "Text-focused",
    "Multi-column",
    "One-page"
  ]

  def up do
    create table(:theme_tags) do
      add :name, :string, null: false
      add :slug, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:theme_tags, [:slug])

    create table(:theme_taggings, primary_key: false) do
      add :theme_id, references(:themes, on_delete: :delete_all), null: false
      add :theme_tag_id, references(:theme_tags, on_delete: :delete_all), null: false
    end

    create unique_index(:theme_taggings, [:theme_id, :theme_tag_id])
    create index(:theme_taggings, [:theme_tag_id])

    flush()

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    repo().insert_all("theme_tags", Enum.map(@starter_tags, &starter_row(&1, now)))
  end

  def down do
    drop table(:theme_taggings)
    drop table(:theme_tags)
  end

  defp starter_row(name, now),
    do: %{name: name, slug: Slug.slugify(name), inserted_at: now, updated_at: now}
end

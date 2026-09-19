defmodule Masthead.Themes.ThemeTag do
  @moduledoc """
  A marketplace tag from the admin-curated list. Authors pick a few for
  their theme (see `Masthead.Themes.Theme.tags_changeset/2`); the slug is
  the stable handle the marketplace filters on (`?tag=<slug>`), so a
  rename keeps it.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Masthead.Content.ChangesetHelpers, only: [ensure_slug: 2]

  schema "theme_tags" do
    field :name, :string
    field :slug, :string
    many_to_many :themes, Masthead.Themes.Theme, join_through: "theme_taggings"
    timestamps(type: :utc_datetime)
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 30)
    |> ensure_slug(:name)
    |> unique_constraint(:slug, message: "already exists")
  end
end

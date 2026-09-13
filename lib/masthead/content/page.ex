defmodule Masthead.Content.Page do
  use Ecto.Schema
  import Ecto.Changeset

  import Masthead.Content.ChangesetHelpers,
    only: [ensure_slug: 2, validate_liquid_body: 1, normalize_options: 2]

  schema "pages" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :format, :string, default: "markdown"
    # For `theme`-format pages: the chosen template name from the theme's
    # templates/pages/ folder. nil for markdown/html pages.
    field :template, :string
    field :published, :boolean, default: false
    field :show_in_nav, :boolean, default: true
    field :page_options, :map, default: %{}
    belongs_to :site, Masthead.Sites.Site
    # Tags a "blog"-format page filters its post list by (empty = show all).
    # Pages are not taggable content; this is a render-time filter selection.
    many_to_many :filter_tags, Masthead.Content.Tag,
      join_through: "page_filter_tags",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :title,
      :slug,
      :body,
      :format,
      :template,
      :published,
      :show_in_nav,
      :page_options,
      :site_id
    ])
    |> validate_required([:title, :site_id])
    |> validate_inclusion(:format, ~w(markdown html theme))
    |> normalize_template()
    |> validate_liquid_body()
    |> ensure_slug(:title)
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,80}[a-z0-9])?$/,
      message: "lowercase letters, numbers, hyphens"
    )
    |> normalize_options(:page_options)
    |> unique_constraint([:site_id, :slug], name: :pages_site_id_slug_index)
    |> assoc_constraint(:site)
  end

  # A `theme` page must name a template; any other format never carries one
  # (so switching format can't leave a stale template behind).
  defp normalize_template(changeset) do
    case get_field(changeset, :format) do
      "theme" -> validate_required(changeset, [:template])
      _ -> put_change(changeset, :template, nil)
    end
  end
end

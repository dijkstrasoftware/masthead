defmodule Masthead.Content.Post do
  use Ecto.Schema
  import Ecto.Changeset

  import Masthead.Content.ChangesetHelpers,
    only: [ensure_slug: 2, validate_liquid_body: 1, normalize_options: 2]

  schema "posts" do
    field :title, :string
    field :slug, :string
    field :body, :string, default: ""
    field :excerpt, :string, default: ""
    field :format, :string, default: "markdown"
    field :published, :boolean, default: false
    field :published_at, :utc_datetime
    field :post_options, :map, default: %{}
    belongs_to :site, Masthead.Sites.Site
    many_to_many :tags, Masthead.Content.Tag, join_through: "post_tags", on_replace: :delete
    timestamps(type: :utc_datetime)
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :title,
      :slug,
      :body,
      :excerpt,
      :format,
      :published,
      :post_options,
      :site_id
    ])
    |> validate_required([:title, :site_id])
    |> validate_inclusion(:format, ~w(markdown html))
    |> validate_liquid_body()
    |> ensure_slug(:title)
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,80}[a-z0-9])?$/,
      message: "lowercase letters, numbers, hyphens"
    )
    |> normalize_options(:post_options)
    |> set_published_at()
    |> unique_constraint([:site_id, :slug], name: :posts_site_id_slug_index)
    |> assoc_constraint(:site)
  end

  defp set_published_at(changeset) do
    published = get_field(changeset, :published)
    at = get_field(changeset, :published_at)

    cond do
      published && is_nil(at) ->
        put_change(changeset, :published_at, DateTime.utc_now() |> DateTime.truncate(:second))

      !published ->
        changeset

      true ->
        changeset
    end
  end
end

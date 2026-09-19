defmodule Masthead.Themes.Theme do
  @moduledoc """
  Persistent representation of a theme.

  Two kinds of rows coexist in this table:

    * `source: "built_in"` — seeded from `priv/themes/*` on every release
      boot. `owner_id` is `nil`; the slug is globally reserved.
    * `source: "uploaded"` — created when a user uploads a theme zip
      through the admin UI. `owner_id` is the uploader; slugs are unique
      per owner.

  The CSS body and template sources do **not** live in this row. The
  `storage_path` field points to either a `priv/themes/<slug>` directory
  (for built-ins) or `themes/<slug>/<version>/` inside `Masthead.Storage`
  (for uploads). The renderer reads files through `Masthead.Themes.Loader`
  and caches the parsed results in `:persistent_term`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(built_in uploaded)
  @reserved_slugs ~w(default)
  @max_tags 3

  schema "themes" do
    field :slug, :string
    field :name, :string
    field :description, :string, default: ""
    field :version, :string
    field :source, :string
    field :storage_path, :string
    field :manifest, :map, default: %{}
    field :public, :boolean, default: false
    field :verified, :boolean, default: false
    field :price_cents, :integer, default: 0
    belongs_to :owner, Masthead.Accounts.User
    has_many :sites, Masthead.Sites.Site
    # Gallery order is the author's chosen order — a card's cover is the
    # first image, so every preload must respect `position`.
    has_many :images, Masthead.Themes.ThemeImage,
      foreign_key: :theme_id,
      preload_order: [asc: :position, asc: :id]

    has_many :links, Masthead.Themes.ThemeLink,
      foreign_key: :theme_id,
      preload_order: [asc: :position, asc: :id]

    many_to_many :tags, Masthead.Themes.ThemeTag,
      join_through: "theme_taggings",
      on_replace: :delete,
      preload_order: [asc: :name]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset used by the seed task to upsert a built-in theme. Built-ins
  have no owner and use a reserved slug.
  """
  def built_in_changeset(theme, attrs) do
    theme
    |> cast(attrs, [:slug, :name, :description, :version, :storage_path, :manifest, :public])
    |> put_change(:source, "built_in")
    |> put_change(:owner_id, nil)
    |> validate_required([:slug, :name, :version, :storage_path])
    |> validate_inclusion(:source, @sources)
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/)
    |> unique_constraint(:slug, name: :themes_system_slug_index)
  end

  @doc """
  Changeset used by the upload flow. The uploader becomes the owner; the
  slug cannot collide with any built-in.
  """
  def upload_changeset(theme, attrs) do
    theme
    |> cast(attrs, [
      :slug,
      :name,
      :description,
      :version,
      :storage_path,
      :manifest,
      :public,
      :owner_id
    ])
    |> put_change(:source, "uploaded")
    |> validate_required([:slug, :name, :version, :storage_path, :owner_id])
    |> validate_inclusion(:source, @sources)
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/)
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved for a built-in theme")
    |> unique_constraint([:owner_id, :slug], name: :themes_owner_slug_index)
    |> assoc_constraint(:owner)
  end

  @doc """
  Changeset toggling whether an uploaded theme is published to the
  marketplace. Publishing/unpublishing is an owner action.
  """
  def publish_changeset(theme, attrs) do
    theme
    |> cast(attrs, [:public])
    |> validate_required([:public])
  end

  @doc """
  Changeset toggling admin verification. A verified theme gets the blue
  "Verified" chip and ranks ahead of unverified "Community" themes.
  """
  def verify_changeset(theme, attrs) do
    theme
    |> cast(attrs, [:verified])
    |> validate_required([:verified])
  end

  @doc """
  Changeset for editing an uploaded theme's marketplace details (the
  description shown on its listing), edited inline on the detail page.
  """
  def details_changeset(theme, attrs) do
    theme
    |> cast(attrs, [:description])
    |> validate_length(:description, max: 500)
  end

  @doc """
  Changeset replacing a theme's marketplace tags. `theme` must have `:tags`
  preloaded. A few tags keep the listing honest and related-theme matches
  meaningful.
  """
  def tags_changeset(theme, tags) do
    theme
    |> change()
    |> put_assoc(:tags, tags)
    |> validate_length(:tags, max: @max_tags, message: "pick at most %{count} tags")
  end

  @doc "Most tags a theme may carry."
  def max_tags, do: @max_tags

  @doc """
  Changeset setting an uploaded theme's price. Kept separate from
  `upload_changeset/2` so only owners (not editors) can touch pricing.
  A price of `0` means free.
  """
  def pricing_changeset(theme, attrs) do
    theme
    |> cast(attrs, [:price_cents])
    |> validate_required([:price_cents])
    |> validate_number(:price_cents, greater_than_or_equal_to: 0)
  end

  @doc "Slugs that can never be claimed by uploaded themes."
  def reserved_slugs, do: @reserved_slugs

  @doc "Storage adapter path for an uploaded theme."
  def upload_storage_path(slug, version), do: Path.join(["themes", slug, version])
end

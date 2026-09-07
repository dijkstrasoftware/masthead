defmodule Masthead.Sites.Site do
  use Ecto.Schema
  import Ecto.Changeset

  @reserved_slugs ~w(www api app admin dashboard login signup logout auth public assets static help sites new themes pricing marketplace)

  schema "sites" do
    field :slug, :string
    field :name, :string
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :theme_tokens, :map, default: %{}
    field :theme_css_overrides, :string, default: ""
    field :custom_domain, :string
    field :custom_domain_status, :string, default: "unconfigured"
    field :custom_domain_token, :string
    field :custom_domain_verified_at, :utc_datetime
    field :custom_domain_last_checked_at, :utc_datetime
    field :custom_domain_last_error, :string
    # Non-null => the site does not resolve publicly (Subdomain plug 404s).
    # Set either by the member-availability cascade (when a site loses its last
    # verified member) or by an admin pausing it from the console.
    field :disabled_at, :utc_datetime
    # Why the site is disabled, so re-enable-on-verify only heals sites that
    # went offline for lack of a verified member — never an admin pause.
    #   "no_verified_member" (auto cascade) | "admin" (manual) | nil (online)
    field :disabled_reason, :string
    # Admin soft-delete (distinct from `disabled_at`): hides the site from
    # its members and the public, but the row is retained for recovery.
    field :deleted_at, :utc_datetime
    field :license_plan, :string
    field :license_status, :string
    field :license_expires_at, :utc_datetime
    field :payment_customer_id, :string
    field :payment_subscription_id, :string
    belongs_to :theme_ref, Masthead.Themes.Theme, foreign_key: :theme_id
    belongs_to :homepage_page, Masthead.Content.Page, foreign_key: :homepage_page_id
    has_many :posts, Masthead.Content.Post
    has_many :pages, Masthead.Content.Page
    has_many :tags, Masthead.Content.Tag
    has_many :memberships, Masthead.Sites.SiteMembership
    has_many :members, through: [:memberships, :user]
    has_many :invitations, Masthead.Sites.SiteInvitation
    timestamps(type: :utc_datetime)
  end

  def create_changeset(site, attrs) do
    site
    |> cast(attrs, [:slug, :name, :title, :description, :theme_id])
    |> normalize_slug()
    |> validate_required([:slug, :name])
    |> validate_format(:slug, ~r/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/,
      message: "must be 1-32 chars, lowercase letters/digits/hyphens, no leading/trailing hyphen"
    )
    |> validate_exclusion(:slug, @reserved_slugs)
    |> validate_length(:name, max: 100)
    |> validate_length(:title, max: 200)
    |> validate_length(:description, max: 1000)
    |> unique_constraint(:slug)
  end

  def settings_changeset(site, attrs) do
    attrs =
      attrs
      |> normalize_homepage_id()
      |> normalize_theme_tokens()

    site
    |> cast(attrs, [
      :name,
      :title,
      :description,
      :theme_id,
      :theme_tokens,
      :theme_css_overrides,
      :homepage_page_id
    ])
    |> validate_required([:name, :theme_id])
    |> validate_length(:name, max: 100)
    |> validate_length(:title, max: 200)
    |> validate_length(:description, max: 1000)
    |> validate_length(:theme_css_overrides, max: 50_000)
    |> assoc_constraint(:theme_ref)
  end

  @doc """
  User-facing changeset for setting/changing the custom domain. Only
  the domain string is cast here; lifecycle fields (`status`, `token`,
  timestamps) are managed by `Masthead.CustomDomains` via
  `custom_domain_state_changeset/2`.
  """
  def custom_domain_changeset(site, attrs) do
    site
    |> cast(attrs, [:custom_domain])
    |> normalize_custom_domain()
    |> validate_required([:custom_domain])
    |> validate_custom_domain_format()
    |> validate_custom_domain_not_app_host()
    |> unique_constraint(:custom_domain)
  end

  @doc """
  Internal changeset for lifecycle transitions driven by the
  `Masthead.CustomDomains` context (status, token, timestamps, errors).
  """
  def custom_domain_state_changeset(site, attrs) do
    cast(site, attrs, [
      :custom_domain,
      :custom_domain_status,
      :custom_domain_token,
      :custom_domain_verified_at,
      :custom_domain_last_checked_at,
      :custom_domain_last_error
    ])
  end

  # Accept anything a user might paste — a bare host, a URL, mixed
  # case, a trailing dot or path — and reduce it to a bare lowercase
  # hostname before validating.
  defp normalize_custom_domain(changeset) do
    case get_change(changeset, :custom_domain) do
      domain when is_binary(domain) ->
        normalized =
          domain
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r{^https?://}, "")
          |> String.split("/", parts: 2)
          |> List.first()
          |> String.split("?", parts: 2)
          |> List.first()
          |> String.split(":", parts: 2)
          |> List.first()
          |> String.trim_trailing(".")

        put_change(changeset, :custom_domain, normalized)

      _ ->
        changeset
    end
  end

  # Both apex (`example.com`) and subdomains (`blog.example.com`) are
  # allowed — the regex already requires at least two labels, so bare
  # hostnames like `localhost` are rejected. Which DNS records the user
  # must create depends on apex vs subdomain; that's handled at verify
  # time, not here.
  defp validate_custom_domain_format(changeset) do
    changeset
    |> validate_length(:custom_domain, max: 253)
    |> validate_format(
      :custom_domain,
      ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/,
      message: "must be a valid domain name"
    )
  end

  # A custom domain must never collide with the platform's own hosts or
  # any `<slug>.<app_host>` — those are served by subdomain routing and
  # allowing them here would be a hijack vector.
  defp validate_custom_domain_not_app_host(changeset) do
    validate_change(changeset, :custom_domain, fn :custom_domain, domain ->
      hosts =
        Application.get_env(:masthead, :app_hosts, ~w(masthead.local lvh.me localhost 127.0.0.1))

      reserved? =
        domain in hosts or Enum.any?(hosts, &String.ends_with?(domain, "." <> &1))

      if reserved?,
        do: [custom_domain: "cannot be a Masthead platform host"],
        else: []
    end)
  end

  # Token overrides come in as `site[theme_tokens][<key>]`: a string for scalar
  # tokens, a map for an `object` token, a list of maps for a `list` token.
  # An empty string means "fall back to the manifest default" — strip those out
  # so we don't pin the override to a blank value. Containers are stored as-is
  # (the settings form canonicalizes them first: `_id`s and empty subvalues
  # dropped), so an empty object/list is a deliberate "no items".
  defp normalize_theme_tokens(%{"theme_tokens" => tokens} = attrs) when is_map(tokens) do
    cleaned =
      tokens
      |> Enum.reject(fn {_, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    Map.put(attrs, "theme_tokens", cleaned)
  end

  defp normalize_theme_tokens(attrs), do: attrs

  defp normalize_homepage_id(%{"homepage_page_id" => ""} = attrs),
    do: Map.put(attrs, "homepage_page_id", nil)

  defp normalize_homepage_id(attrs), do: attrs

  defp normalize_slug(changeset) do
    case get_change(changeset, :slug) do
      slug when is_binary(slug) ->
        put_change(changeset, :slug, String.downcase(String.trim(slug)))

      _ ->
        changeset
    end
  end
end

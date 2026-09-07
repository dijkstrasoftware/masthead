defmodule Masthead.Themes do
  @moduledoc """
  Context for themes.

  Themes used to be plain Elixir modules registered in a hardcoded map.
  They are migrating to data — rows in the `themes` table plus on-disk /
  object-storage files — so that end users can upload and customize them.

  Every theme is a row here; templates and CSS live on disk (priv for
  built-ins, object storage for uploads).
  """

  import Ecto.Query
  alias Masthead.Query
  alias Masthead.Repo
  alias Masthead.Storage
  alias Masthead.Themes.Theme
  alias Masthead.Themes.ThemeImage
  alias Masthead.Themes.ThemeLink
  alias Masthead.Themes.ThemeInstall

  # Storage namespace for marketplace gallery images. Keys are scoped by
  # theme id underneath (e.g. "theme-previews/12/169…-42.png").
  @previews_namespace "theme-previews"

  # The canonical files that make up a theme directory.
  @theme_files ["manifest.json", "theme.css"] ++
                 Enum.map(~w(layout index post page blog not_found), &"templates/#{&1}.liquid")

  @doc """
  A user's own uploaded themes, for the marketplace "My themes" view. The
  only built-in (Default) is installed on every site already, so it's not
  listed here. Installing onto a site is separate — see `list_themes_for_site/1`.
  """
  def list_themes(user_id, search \\ nil, visibility \\ :all)

  def list_themes(user_id, search, visibility) when is_integer(user_id) do
    from(t in Theme,
      where: t.owner_id == ^user_id,
      order_by: ^theme_order(),
      preload: [:images]
    )
    |> apply_visibility(visibility)
    |> apply_search(search)
    |> Repo.all()
  end

  def list_themes(nil, _search, _visibility), do: []

  defp apply_visibility(query, :public), do: from(t in query, where: t.public == true)
  defp apply_visibility(query, :private), do: from(t in query, where: t.public == false)
  defp apply_visibility(query, _all), do: query

  @doc """
  Themes a site can select as its active theme: all built-ins (Default)
  plus every theme installed onto the site.
  """
  def list_themes_for_site(%Masthead.Sites.Site{id: site_id}) do
    installed = from(i in ThemeInstall, where: i.site_id == ^site_id, select: i.theme_id)

    Repo.all(
      from t in Theme,
        where: t.source == "built_in" or t.id in subquery(installed),
        order_by: ^theme_order()
    )
  end

  @doc "List only built-in themes."
  def list_built_ins do
    Repo.all(from t in Theme, where: t.source == "built_in", order_by: ^theme_order())
  end

  # Built-ins first, then uploads. Within built-ins the canonical Default
  # always leads (it's what every site starts on), then the rest of the
  # built-ins alphabetically. Uploads come after, by name.
  defp theme_order do
    [
      asc: dynamic([t], t.source),
      asc: dynamic([t], fragment("CASE WHEN ? = 'default' THEN 0 ELSE 1 END", t.slug)),
      asc: dynamic([t], t.name)
    ]
  end

  def get_theme!(id), do: Repo.get!(Theme, id)
  def get_theme(id), do: Repo.get(Theme, id)

  def get_built_in_by_slug(slug) when is_binary(slug) do
    Repo.one(from t in Theme, where: t.slug == ^slug and t.source == "built_in")
  end

  @doc """
  Used by the seed task. Inserts a built-in row if absent, updates it if
  the on-disk version is newer, no-ops otherwise.
  """
  def upsert_built_in(attrs) when is_map(attrs) do
    slug = Map.fetch!(attrs, :slug)

    case get_built_in_by_slug(slug) do
      nil ->
        %Theme{}
        |> Theme.built_in_changeset(attrs)
        |> Repo.insert()

      existing ->
        if existing.version == attrs[:version] do
          {:ok, existing}
        else
          existing
          |> Theme.built_in_changeset(attrs)
          |> Repo.update()
        end
    end
  end

  @doc "Create an uploaded theme. Owner is taken from `attrs.owner_id`."
  def create_upload(attrs) do
    %Theme{} |> Theme.upload_changeset(attrs) |> Repo.insert()
  end

  def update_theme(%Theme{source: "uploaded"} = theme, attrs) do
    theme |> Theme.upload_changeset(attrs) |> Repo.update()
  end

  @doc "Changeset for the inline description editor on a theme's detail page."
  def change_details(%Theme{} = theme, attrs \\ %{}), do: Theme.details_changeset(theme, attrs)

  @doc "Update an uploaded theme's marketplace details (description)."
  def update_details(%Theme{source: "uploaded"} = theme, attrs) do
    theme |> Theme.details_changeset(attrs) |> Repo.update()
  end

  @doc """
  Delete an uploaded theme.

  Built-ins are protected. A theme still referenced by a *live* site can't
  be deleted (the `sites.theme_id` foreign key forbids it): rather than
  letting the DB raise an `Ecto.ConstraintError`, we look those sites up
  first and return `{:error, {:in_use, names}}` so the caller can name
  them. A *disabled* site still counts — its owner can re-enable it.

  Soft-deleted sites are different: they render nothing, but their row
  still holds the foreign key, so they would otherwise pin the theme
  forever. We detach them onto the built-in `default` theme before
  deleting, so they no longer block (they'd come back on `default` if ever
  restored). The delete also carries a `foreign_key_constraint` as a
  safety net against a site adopting the theme mid-operation.
  """
  def delete_theme(%Theme{source: "built_in"}), do: {:error, :built_in_protected}

  def delete_theme(%Theme{source: "uploaded"} = theme) do
    case live_sites_using_theme(theme.id) do
      [] ->
        detach_deleted_sites(theme.id)
        purge_gallery_files(theme.id)

        theme
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:id, name: "sites_theme_id_fkey")
        |> Repo.delete()

      names ->
        {:error, {:in_use, names}}
    end
  end

  # Names of non-deleted sites referencing the theme. Only `deleted_at`
  # excludes a site; a disabled site can be re-enabled, so it still blocks.
  defp live_sites_using_theme(theme_id) do
    Repo.all(
      from s in Masthead.Sites.Site,
        where: s.theme_id == ^theme_id and is_nil(s.deleted_at),
        order_by: [asc: s.name],
        select: s.name
    )
  end

  # Re-point any soft-deleted sites off the doomed theme and onto `default`,
  # so the foreign key no longer blocks its deletion.
  defp detach_deleted_sites(theme_id) do
    case get_built_in_by_slug("default") do
      %Theme{id: default_id} ->
        Repo.update_all(
          from(s in Masthead.Sites.Site,
            where: s.theme_id == ^theme_id and not is_nil(s.deleted_at)
          ),
          set: [theme_id: default_id]
        )

        :ok

      nil ->
        :ok
    end
  end

  # ---- marketplace ----

  @doc """
  Publish an uploaded theme to the marketplace. Built-ins can't be
  published (they're already available to everyone).
  """
  def publish_theme(%Theme{source: "built_in"}), do: {:error, :built_in_protected}

  def publish_theme(%Theme{source: "uploaded"} = theme) do
    theme |> Theme.publish_changeset(%{public: true}) |> Repo.update()
  end

  @doc "Remove an uploaded theme from the marketplace."
  def unpublish_theme(%Theme{source: "uploaded"} = theme) do
    theme |> Theme.publish_changeset(%{public: false}) |> Repo.update()
  end

  @doc "Admin marks a theme as verified (blue chip, ranks first)."
  def verify_theme(%Theme{} = theme) do
    theme |> Theme.verify_changeset(%{verified: true}) |> Repo.update()
  end

  @doc "Admin clears verification (theme falls back to the yellow \"community\" chip)."
  def unverify_theme(%Theme{} = theme) do
    theme |> Theme.verify_changeset(%{verified: false}) |> Repo.update()
  end

  @doc """
  Published themes available to install, for the marketplace browser.
  Excludes the viewer's own themes (they live under "My themes"); a signed-out
  visitor (`nil`) has none to exclude and sees the whole catalogue. Verified
  themes rank first (then community), each group alphabetical — in Postgres
  `true > false`, so `desc: verified` floats verified to the top. Owner and
  gallery images are preloaded for the grid.
  """
  def list_marketplace(user_id, filter \\ :all, search \\ nil) do
    from(t in Theme,
      where: t.source == "uploaded" and t.public == true,
      order_by: [desc: t.verified, asc: t.name],
      preload: [:owner, :images]
    )
    |> exclude_own(user_id)
    |> apply_marketplace_filter(filter)
    |> apply_search(search)
    |> Repo.all()
  end

  defp exclude_own(query, nil), do: query

  defp exclude_own(query, user_id) when is_integer(user_id),
    do: from(t in query, where: t.owner_id != ^user_id)

  defp apply_marketplace_filter(query, :verified), do: from(t in query, where: t.verified == true)

  defp apply_marketplace_filter(query, :community),
    do: from(t in query, where: t.verified == false)

  defp apply_marketplace_filter(query, _all), do: query

  @doc "How many themes an author has published, for the detail page's author card."
  def published_count(owner_id) when is_integer(owner_id) do
    Repo.aggregate(from(t in Theme, where: t.owner_id == ^owner_id and t.public == true), :count)
  end

  @doc "Set of theme ids installed on a site (for marketplace install state)."
  def installed_theme_ids(site_id) when is_integer(site_id) do
    Repo.all(from i in ThemeInstall, where: i.site_id == ^site_id, select: i.theme_id)
    |> MapSet.new()
  end

  @doc """
  Install a theme onto a site (from the marketplace, in a site's context).
  Idempotent — a repeat install is a no-op. A theme is installable when it
  is published (`public`) or owned by a member of the site (so you can put
  your own not-yet-published theme on a site you belong to).
  """
  def install_theme(%Masthead.Sites.Site{} = site, %Theme{} = theme) do
    if theme.public or Masthead.Sites.member?(site.id, theme.owner_id) do
      %ThemeInstall{}
      |> ThemeInstall.changeset(%{site_id: site.id, theme_id: theme.id})
      |> Repo.insert(on_conflict: :nothing)
    else
      {:error, :not_installable}
    end
  end

  @doc """
  Remove a theme installed on a site. Refuses to uninstall the site's
  currently active theme (`{:error, :in_use}`) so a site is never themeless.
  """
  def uninstall_theme(%Masthead.Sites.Site{} = site, theme_id) do
    if site.theme_id == theme_id do
      {:error, :in_use}
    else
      {count, _} =
        Repo.delete_all(
          from i in ThemeInstall, where: i.site_id == ^site.id and i.theme_id == ^theme_id
        )

      {:ok, count}
    end
  end

  # ---- gallery images ----

  @doc "A theme's gallery images, in display order."
  def list_theme_images(theme_id) do
    Repo.all(
      from i in ThemeImage,
        where: i.theme_id == ^theme_id,
        order_by: [asc: i.position, asc: i.id]
    )
  end

  @doc """
  Store an uploaded preview file (a path on disk, as handed back by
  `consume_uploaded_entries`) and append it to the theme's gallery at the
  next free position.
  """
  def add_theme_image(%Theme{} = theme, %{filename: filename, path: path}) do
    ext = filename |> Path.extname() |> String.downcase()

    key =
      Path.join(
        to_string(theme.id),
        "#{System.system_time(:millisecond)}-#{:rand.uniform(1_000_000)}#{ext}"
      )

    case Storage.stream_into(@previews_namespace, key, path) do
      {:ok, rel} ->
        %ThemeImage{}
        |> ThemeImage.changeset(%{
          theme_id: theme.id,
          storage_path: rel,
          position: next_position(theme.id)
        })
        |> Repo.insert()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_position(theme_id) do
    max = Repo.one(from i in ThemeImage, where: i.theme_id == ^theme_id, select: max(i.position))
    (max || -1) + 1
  end

  @doc """
  Reorder a theme's gallery to match `ordered_ids` (image ids, first =
  position 0). Ids are scoped to the theme, so a stray id from another
  theme is ignored. Returns `:ok`.
  """
  def reorder_theme_images(theme_id, ordered_ids) when is_list(ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index()
      |> Enum.each(fn {id, index} ->
        Repo.update_all(
          from(i in ThemeImage, where: i.id == ^id and i.theme_id == ^theme_id),
          set: [position: index]
        )
      end)
    end)

    :ok
  end

  @doc "Delete a gallery image (removes the stored file, then the row)."
  def delete_theme_image(%ThemeImage{} = image) do
    _ = Storage.delete(image.storage_path)
    Repo.delete(image)
  end

  @doc "Public URL for a gallery image."
  def image_url(%ThemeImage{storage_path: path}), do: Storage.url(path)

  # ---- listing links ----

  @doc "A theme's listing links, in the author's chosen order."
  def list_theme_links(theme_id) do
    Repo.all(
      from l in ThemeLink,
        where: l.theme_id == ^theme_id,
        order_by: [asc: l.position, asc: l.id]
    )
  end

  @doc "Changeset for the listing-link form."
  def change_theme_link(%ThemeLink{} = link \\ %ThemeLink{}, attrs \\ %{}) do
    ThemeLink.changeset(link, attrs)
  end

  @doc "Append a link to a theme's listing, at the next free position."
  def add_theme_link(%Theme{} = theme, attrs) do
    %ThemeLink{}
    |> ThemeLink.changeset(
      Map.merge(attrs, %{"theme_id" => theme.id, "position" => next_link_position(theme.id)})
    )
    |> Repo.insert()
  end

  @doc """
  Reorder a theme's links to match `ordered_ids` (first = position 0). Ids
  are scoped to the theme, so a stray id from another theme is ignored.
  """
  def reorder_theme_links(theme_id, ordered_ids) when is_list(ordered_ids) do
    Repo.transaction(fn ->
      ordered_ids
      |> Enum.with_index()
      |> Enum.each(&set_link_position(&1, theme_id))
    end)

    :ok
  end

  @doc "Delete a listing link."
  def delete_theme_link(%ThemeLink{} = link), do: Repo.delete(link)

  defp set_link_position({id, index}, theme_id) do
    Repo.update_all(
      from(l in ThemeLink, where: l.id == ^id and l.theme_id == ^theme_id),
      set: [position: index]
    )
  end

  defp next_link_position(theme_id) do
    max = Repo.one(from l in ThemeLink, where: l.theme_id == ^theme_id, select: max(l.position))
    (max || -1) + 1
  end

  # Remove the stored gallery files before the rows go (the FK's
  # `on_delete: :delete_all` clears the rows; this clears the bytes).
  defp purge_gallery_files(theme_id) do
    theme_id
    |> list_theme_images()
    |> Enum.each(&Storage.delete(&1.storage_path))
  end

  # ---- admin ----

  @doc """
  Themes for the admin overview, with owner preloaded and optional filter +
  search. Capped at `count` rows — narrow with the filter + search rather
  than paging.
  """
  @sortable_themes [:name, :slug, :version, :source, :public]

  def list_all_themes(filter \\ :all, search_query \\ nil, count \\ 20, sort \\ nil) do
    from(t in Theme, order_by: ^theme_order(), preload: [:owner])
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Query.sort(sort, @sortable_themes)
    |> limit(^count)
    |> Repo.all()
  end

  @doc "Total themes matching the same filter + search, ignoring the row cap."
  def count_all_themes(filter \\ :all, search_query \\ nil) do
    from(t in Theme)
    |> apply_filter(filter)
    |> apply_search(search_query)
    |> Repo.aggregate(:count)
  end

  defp apply_filter(query, filter) do
    case filter do
      :built_in -> from t in query, where: t.source == "built_in"
      :public -> from t in query, where: t.public == true
      # Private = a user's own unpublished uploads; built-ins are excluded
      # (they default to public == false but aren't a user's "private" theme).
      :private -> from t in query, where: t.source == "uploaded" and t.public == false
      _ -> query
    end
  end

  # Descriptions are searchable too — a theme's name rarely says what it is
  # for ("Interstellar"), and its description is where the author says so.
  defp apply_search(query, search_query) do
    if search_query && search_query != "" do
      term = "%#{search_query}%"
      from t in query, where: ilike(t.name, ^term) or ilike(t.description, ^term)
    else
      query
    end
  end

  @doc """
  Reconstruct an uploaded theme's source files into an in-memory `.zip`.
  Returns `{:ok, filename, zip_binary}` or `{:error, reason}`. Built-in
  themes aren't downloadable (they live in the repo already).
  """
  def package_theme(%Theme{source: "built_in"}), do: {:error, :built_in_not_downloadable}

  def package_theme(%Theme{source: "uploaded", storage_path: path} = theme) do
    entries =
      Enum.reduce_while(@theme_files, [], fn rel, acc ->
        case Storage.read(Path.join(path, rel)) do
          {:ok, bin} -> {:cont, [{String.to_charlist(rel), bin} | acc]}
          {:error, reason} -> {:halt, {:error, {rel, reason}}}
        end
      end)

    with entries when is_list(entries) <- entries,
         filename = "#{theme.slug}-#{theme.version}.zip",
         {:ok, {_name, zip}} <-
           :zip.create(String.to_charlist(filename), Enum.reverse(entries), [:memory]) do
      {:ok, filename, zip}
    else
      {:error, _} = err -> err
    end
  end
end

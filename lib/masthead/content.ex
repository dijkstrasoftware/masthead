defmodule Masthead.Content do
  @moduledoc """
  CRUD for the publishable content of a site: posts and pages.

  Every function is scoped by `site_id`. Callers must pass a site (or its id)
  loaded for the current request/user — there is no global accessor by slug
  alone, on purpose.
  """
  import Ecto.Query
  alias Masthead.Realtime
  alias Masthead.Query
  alias Masthead.Repo
  alias Masthead.Content.{Post, Page, Tag}

  # Announce a post/page mutation so index/dashboard views reload and open
  # editors can detect an external change. Pass-through on the result tuple.
  defp broadcast_content({:ok, record} = result, kind, op) do
    Realtime.content_changed(record.site_id, %{
      kind: kind,
      id: record.id,
      op: op,
      updated_at: record.updated_at
    })

    result
  end

  defp broadcast_content(other, _kind, _op), do: other

  # Tag edits render on the settings page, so they ride the settings topic.
  defp broadcast_settings({:ok, %{site_id: site_id}} = result) do
    Realtime.settings_changed(site_id)
    result
  end

  defp broadcast_settings(other), do: other

  # ---- Posts ----

  @doc """
  Lists a site's posts, newest first. Posts are preloaded with `:tags`.

  Options:

    * `:filter` — `:all` (default), `:published`, `:draft`, `:untagged`, or
      a tag slug (string) to keep only posts carrying that tag. One value,
      not a combination: the toolbar is a single-select row of buttons.
    * `:search` — a string matched (ILIKE) against the post title.
    * `:limit` — cap the number of rows returned.
  """
  @sortable_posts [:title, :slug, :format, :published, :inserted_at, :updated_at]

  def list_posts(site_id, opts \\ []) do
    from(p in Post,
      where: p.site_id == ^site_id,
      order_by: [desc: p.inserted_at],
      preload: :tags
    )
    |> apply_post_filter(Keyword.get(opts, :filter, :all))
    |> apply_post_search(Keyword.get(opts, :search))
    |> Query.sort(Keyword.get(opts, :sort), @sortable_posts)
    |> cap(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc "Total posts matching the same filter + search, ignoring the row cap."
  def count_posts(site_id, opts \\ []) do
    from(p in Post, where: p.site_id == ^site_id)
    |> apply_post_filter(Keyword.get(opts, :filter, :all))
    |> apply_post_search(Keyword.get(opts, :search))
    |> Repo.aggregate(:count)
  end

  defp cap(query, limit) when is_integer(limit), do: limit(query, ^limit)
  defp cap(query, _limit), do: query

  defp apply_post_filter(query, :all), do: query

  defp apply_post_filter(query, :published),
    do: from(p in query, where: p.published == true)

  defp apply_post_filter(query, :draft),
    do: from(p in query, where: p.published == false)

  defp apply_post_filter(query, :untagged) do
    from p in query,
      where: fragment("NOT EXISTS (SELECT 1 FROM post_tags pt WHERE pt.post_id = ?)", p.id)
  end

  defp apply_post_filter(query, slug) when is_binary(slug) do
    from p in query,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM post_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.post_id = ? AND t.slug = ?)",
          p.id,
          ^slug
        )
  end

  defp apply_post_search(query, search) when is_binary(search) and search != "" do
    from p in query, where: ilike(p.title, ^"%#{search}%")
  end

  defp apply_post_search(query, _), do: query

  def list_published_posts(site_id) do
    Repo.all(
      from p in Post,
        where: p.site_id == ^site_id and p.published == true,
        order_by: [desc: p.published_at],
        preload: :tags
    )
  end

  @doc """
  Published posts for a blog page, keeping only those carrying at least one of
  the given tag ids. An empty list returns all published posts (no filter).
  """
  def list_published_posts_filtered(site_id, []), do: list_published_posts(site_id)

  def list_published_posts_filtered(site_id, tag_ids) when is_list(tag_ids) do
    Repo.all(
      from p in Post,
        where:
          p.site_id == ^site_id and p.published == true and
            fragment(
              "EXISTS (SELECT 1 FROM post_tags pt WHERE pt.post_id = ? AND pt.tag_id = ANY(?))",
              p.id,
              ^tag_ids
            ),
        order_by: [desc: p.published_at],
        preload: :tags
    )
  end

  @doc """
  Published posts for a site carrying the tag with the given slug, newest
  first. A site-scoped, tag-filtered DB query (not an in-memory filter of all
  posts) — used to back the `posts_by_tag["<slug>"]` collection in templates.
  An unknown slug simply returns `[]`.
  """
  def list_published_posts_by_tag(site_id, slug) when is_binary(slug) do
    Repo.all(
      from p in Post,
        where:
          p.site_id == ^site_id and p.published == true and
            fragment(
              "EXISTS (SELECT 1 FROM post_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.post_id = ? AND t.slug = ?)",
              p.id,
              ^slug
            ),
        order_by: [desc: p.published_at],
        preload: :tags
    )
  end

  @doc """
  Full-text-ish search over a site's published posts: case-insensitive
  substring match against title, excerpt, and body. A blank query returns all
  published posts (so the search page reads as "browse everything" rather than
  "no results"). Used by the public `/search` route.
  """
  def search_posts(site_id, query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        list_published_posts(site_id)

      trimmed ->
        like = "%#{trimmed}%"

        Repo.all(
          from p in Post,
            where:
              p.site_id == ^site_id and p.published == true and
                (ilike(p.title, ^like) or ilike(p.excerpt, ^like) or ilike(p.body, ^like)),
            order_by: [desc: p.published_at],
            preload: :tags
        )
    end
  end

  def search_posts(_site_id, _query), do: []

  def get_post!(site_id, id) do
    Repo.one!(from p in Post, where: p.site_id == ^site_id and p.id == ^id, preload: :tags)
  end

  def get_published_post_by_slug(site_id, slug) do
    Repo.one(
      from p in Post,
        where: p.site_id == ^site_id and p.slug == ^slug and p.published == true,
        preload: :tags
    )
  end

  def create_post(site_id, attrs) do
    changeset =
      %Post{site_id: site_id}
      |> Post.changeset(Map.put(attrs, "site_id", site_id))
      |> put_post_tags(site_id, attrs)

    with {:ok, post} <- Repo.insert(changeset) do
      Masthead.Actions.complete_action(site_id, "create_first_post")
      Masthead.Actions.reached_first_content(site_id)
      broadcast_content({:ok, post}, :post, :created)
    end
  end

  def update_post(%Post{} = post, attrs) do
    post = Repo.preload(post, :tags)

    post
    |> Post.changeset(attrs)
    |> put_post_tags(post.site_id, attrs)
    |> Repo.update()
    |> broadcast_content(:post, :updated)
  end

  def delete_post(%Post{} = post), do: post |> Repo.delete() |> broadcast_content(:post, :deleted)

  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  # Attach tags only when the caller actually submitted a `tag_ids` key, so
  # updates that don't touch tags (e.g. a publish toggle) leave them alone.
  # Tags are resolved site-scoped, so a forged id from another site is ignored.
  defp put_post_tags(changeset, site_id, attrs) do
    put_assoc_tags(changeset, :tags, site_id, attrs, "tag_ids", :tag_ids)
  end

  # Attach a tag association only when the caller submitted the id key, so
  # updates that don't touch tags leave the association alone. Tags are
  # resolved site-scoped, so a forged id from another site is ignored.
  defp put_assoc_tags(changeset, assoc, site_id, attrs, string_key, atom_key) do
    case fetch_ids(attrs, string_key, atom_key) do
      nil -> changeset
      ids -> Ecto.Changeset.put_assoc(changeset, assoc, list_tags_by_ids(site_id, ids))
    end
  end

  defp fetch_ids(attrs, string_key, atom_key) do
    cond do
      Map.has_key?(attrs, string_key) -> parse_ids(Map.get(attrs, string_key))
      Map.has_key?(attrs, atom_key) -> parse_ids(Map.get(attrs, atom_key))
      true -> nil
    end
  end

  defp parse_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(fn
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_ids(_), do: []

  # ---- Pages ----

  @doc """
  Lists a site's pages, by title.

  Options:

    * `:filter` — `:all` (default), `:published` or `:draft`. Pages carry no
      tags, so the status filters are the whole set.
    * `:search` — a string matched (ILIKE) against the page title.
    * `:limit` — cap the number of rows returned.
  """
  @sortable_pages [:title, :slug, :format, :published, :inserted_at, :updated_at]

  def list_pages(site_id, opts \\ []) do
    from(p in Page, where: p.site_id == ^site_id, order_by: p.title)
    |> apply_page_filter(Keyword.get(opts, :filter, :all))
    |> apply_page_search(Keyword.get(opts, :search))
    |> Query.sort(Keyword.get(opts, :sort), @sortable_pages)
    |> cap(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc "Total pages matching the same filter + search, ignoring the row cap."
  def count_pages(site_id, opts \\ []) do
    from(p in Page, where: p.site_id == ^site_id)
    |> apply_page_filter(Keyword.get(opts, :filter, :all))
    |> apply_page_search(Keyword.get(opts, :search))
    |> Repo.aggregate(:count)
  end

  defp apply_page_filter(query, :published), do: from(p in query, where: p.published == true)
  defp apply_page_filter(query, :draft), do: from(p in query, where: p.published == false)
  defp apply_page_filter(query, _all), do: query

  defp apply_page_search(query, search) when is_binary(search) and search != "" do
    from p in query, where: ilike(p.title, ^"%#{search}%")
  end

  defp apply_page_search(query, _search), do: query

  @doc """
  The status filters the posts and pages toolbars share, as `{value, label}`
  pairs. `PostIndex` appends its tag filters after these.
  """
  def status_filter_options,
    do: [{:all, "All"}, {:published, "Published"}, {:draft, "Draft"}]

  def list_published_pages(site_id) do
    Repo.all(
      from p in Page,
        where: p.site_id == ^site_id and p.published == true,
        order_by: p.title
    )
  end

  def get_page!(site_id, id) do
    Repo.one!(from p in Page, where: p.site_id == ^site_id and p.id == ^id, preload: :filter_tags)
  end

  def get_published_page_by_slug(site_id, slug) do
    Repo.one(
      from p in Page,
        where: p.site_id == ^site_id and p.slug == ^slug and p.published == true,
        preload: :filter_tags
    )
  end

  @doc """
  Returns the site's designated homepage page, or `nil` if none is set or
  the chosen page isn't currently published. Used by the public root URL
  to decide whether to render a custom page or fall back to the theme's
  default `render_index` (post list).
  """
  def get_homepage_page(%Masthead.Sites.Site{homepage_page_id: nil}), do: nil

  def get_homepage_page(%Masthead.Sites.Site{id: site_id, homepage_page_id: id}) do
    Repo.one(
      from p in Page,
        where: p.id == ^id and p.site_id == ^site_id and p.published == true,
        preload: :filter_tags
    )
  end

  def create_page(site_id, attrs) do
    changeset =
      %Page{site_id: site_id}
      |> Page.changeset(Map.put(attrs, "site_id", site_id))
      |> put_page_filter_tags(site_id, attrs)

    with {:ok, page} <- Repo.insert(changeset) do
      Masthead.Actions.complete_action(site_id, "create_first_page")
      Masthead.Actions.reached_first_content(site_id)
      broadcast_content({:ok, page}, :page, :created)
    end
  end

  def update_page(%Page{} = page, attrs) do
    page = Repo.preload(page, :filter_tags)

    page
    |> Page.changeset(attrs)
    |> put_page_filter_tags(page.site_id, attrs)
    |> Repo.update()
    |> broadcast_content(:page, :updated)
  end

  defp put_page_filter_tags(changeset, site_id, attrs) do
    put_assoc_tags(changeset, :filter_tags, site_id, attrs, "filter_tag_ids", :filter_tag_ids)
  end

  def delete_page(%Page{} = page), do: page |> Repo.delete() |> broadcast_content(:page, :deleted)

  def change_page(%Page{} = page, attrs \\ %{}), do: Page.changeset(page, attrs)

  # ---- Tags ----

  def list_tags(site_id) do
    Repo.all(from t in Tag, where: t.site_id == ^site_id, order_by: t.name)
  end

  @doc """
  Loads the given tag ids, scoped to a site. Foreign ids (belonging to another
  site) are silently dropped, so this is safe to call with user-submitted ids.
  """
  def list_tags_by_ids(_site_id, []), do: []

  def list_tags_by_ids(site_id, ids) when is_list(ids) do
    Repo.all(from t in Tag, where: t.site_id == ^site_id and t.id in ^ids)
  end

  def get_tag!(site_id, id) do
    Repo.one!(from t in Tag, where: t.site_id == ^site_id and t.id == ^id)
  end

  def create_tag(site_id, attrs) do
    %Tag{site_id: site_id}
    |> Tag.changeset(Map.put(attrs, "site_id", site_id))
    |> Repo.insert()
    |> broadcast_settings()
  end

  def update_tag(%Tag{} = tag, attrs),
    do: tag |> Tag.changeset(attrs) |> Repo.update() |> broadcast_settings()

  def delete_tag(%Tag{} = tag), do: tag |> Repo.delete() |> broadcast_settings()

  def change_tag(%Tag{} = tag, attrs \\ %{}), do: Tag.changeset(tag, attrs)

  # ---- Rendering ----

  alias Masthead.Content.HTML

  @doc """
  Render a post or page body to safe HTML. Dispatches on `format`:

    * `"markdown"` — parse with Earmark (HTML in source is escaped, so
      `<StrictMode>` inside a fenced code block renders literally), then
      run through the sanitizer as defense in depth.
    * `"html"` — sanitize the raw input directly.

  Returns a string.
  """
  def render_body(nil, _format), do: ""
  def render_body(body, "html") when is_binary(body), do: HTML.sanitize(body)

  def render_body(body, _markdown) when is_binary(body) do
    case Earmark.as_html(body, escape: true, code_class_prefix: "lang-") do
      {:ok, html, _} -> HTML.sanitize(html)
      {:error, html, _} -> HTML.sanitize(html)
    end
  end

  @doc false
  # Kept for backwards compat with anything that still calls it. New
  # callers should pass an explicit format via `render_body/2`.
  def render_markdown(body), do: render_body(body, "markdown")
end

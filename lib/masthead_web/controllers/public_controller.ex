defmodule MastheadWeb.PublicController do
  use MastheadWeb, :controller

  alias Masthead.Content
  alias Masthead.Sites
  alias Masthead.Themes.StructuredData
  alias Masthead.Themes.Renderer

  plug :require_site
  plug MastheadWeb.ViewTracker when action in [:index, :show_post, :show_page]

  def index(conn, _params) do
    site = conn.assigns.current_site
    all_pages = Content.list_published_pages(site.id)
    pages = nav_pages(site, all_pages)

    case Content.get_homepage_page(site) do
      nil ->
        # The theme's default index is a post list, so it gets the same
        # `?tag=<slug>` narrowing as a blog page. The filterable universe is
        # every site tag; an unknown slug falls back to the full list.
        tags = Content.list_tags(site.id)
        current_tag = Enum.find(tags, &(&1.slug == conn.params["tag"]))
        tag_ids = if current_tag, do: [current_tag.id], else: []
        posts = Content.list_published_posts_filtered(site.id, tag_ids)

        body =
          Renderer.render_index(%{
            site: site,
            posts: posts,
            pages: pages,
            tags: tags,
            current_tag: current_tag,
            structured_data: structured_data(conn, :website, nil)
          })

        send_themed(conn, body)

      page ->
        render_page_or_404(conn, page, pages, structured_data(conn, :website, nil))
    end
  end

  def show_post(conn, %{"slug" => slug}) do
    site = conn.assigns.current_site
    pages = nav_pages(site, Content.list_published_pages(site.id))
    posts = Content.list_published_posts(site.id)

    case Content.get_published_post_by_slug(site.id, slug) do
      nil ->
        body = Renderer.render_not_found(%{site: site, pages: pages, posts: posts})
        conn |> put_status(:not_found) |> send_themed(body)

      post ->
        body =
          Renderer.render_post(
            Map.merge(
              %{
                site: site,
                post: post,
                pages: pages,
                posts: posts,
                structured_data: structured_data(conn, :article, post)
              },
              body_assigns(post)
            )
          )

        send_themed(conn, body)
    end
  end

  def show_page(conn, %{"slug" => slug}) do
    site = conn.assigns.current_site
    pages = nav_pages(site, Content.list_published_pages(site.id))
    page = Content.get_published_page_by_slug(site.id, slug)
    render_page_or_404(conn, page, pages, page_structured_data(conn, page))
  end

  @doc "Sets the member opt-out cookie for a valid `t` token, then shows the site."
  def no_track(conn, params) do
    conn
    |> MastheadWeb.ViewTracker.opt_out(conn.assigns.current_site, params["t"] || "")
    |> redirect(to: "/")
  end

  @doc "Public post search: `/search?q=...`."
  def search(conn, params) do
    site = conn.assigns.current_site
    pages = nav_pages(site, Content.list_published_pages(site.id))
    query = params["q"] || ""
    posts = Content.search_posts(site.id, query)
    body = Renderer.render_search(%{site: site, posts: posts, query: query, pages: pages})
    send_themed(conn, body)
  end

  defp render_page_or_404(conn, nil, pages, _structured_data) do
    site = conn.assigns.current_site
    posts = Content.list_published_posts(site.id)
    body = Renderer.render_not_found(%{site: site, pages: pages, posts: posts})
    conn |> put_status(:not_found) |> send_themed(body)
  end

  defp render_page_or_404(conn, %{format: "theme"} = page, pages, structured_data) do
    site = conn.assigns.current_site
    page_tag_ids = Enum.map(page.filter_tags, & &1.id)

    # Every theme page receives the full post list, narrowed the same way the
    # old blog format was: by the page's `filter_tags` and an optional
    # `?tag=<slug>`. A template that doesn't render a list simply ignores it.
    #
    # The set of tags this page can be filtered by, exposed to the theme so it
    # can render filter links. When the page restricts to a set of
    # `filter_tags`, that set is the universe; otherwise every site tag is.
    filterable = if page_tag_ids == [], do: Content.list_tags(site.id), else: page.filter_tags

    # `?tag=<slug>` narrows *within* the universe. We resolve the slug against
    # the filterable set only, so a missing, foreign, or out-of-scope slug
    # falls back to the page's default list rather than erroring.
    current_tag = Enum.find(filterable, &(&1.slug == conn.params["tag"]))

    tag_ids = if current_tag, do: [current_tag.id], else: page_tag_ids
    posts = Content.list_published_posts_filtered(site.id, tag_ids)

    body =
      Renderer.render_theme_page(%{
        site: site,
        page: page,
        posts: posts,
        pages: pages,
        tags: filterable,
        current_tag: current_tag,
        structured_data: structured_data
      })

    send_themed(conn, body)
  end

  defp render_page_or_404(conn, page, pages, structured_data) do
    site = conn.assigns.current_site
    posts = Content.list_published_posts(site.id)

    body =
      Renderer.render_page(
        Map.merge(
          %{
            site: site,
            page: page,
            pages: pages,
            posts: posts,
            structured_data: structured_data
          },
          body_assigns(page)
        )
      )

    send_themed(conn, body)
  end

  # The "html" format is Liquid: hand the raw body to the renderer so it's
  # rendered in-context (tokens, logic) and emitted unsanitized. "markdown"
  # is converted to sanitized HTML up front. (Theme pages are handled in their
  # own clause; they have no body.)
  defp body_assigns(%{format: "html"} = content), do: %{liquid_body: content.body || ""}
  defp body_assigns(content), do: %{body_html: Content.render_body(content.body, content.format)}

  # The nav excludes: the site's designated homepage (already reachable
  # via the brand link at `/`), and any page explicitly hidden from the
  # nav via its `show_in_nav` flag.
  defp nav_pages(site, pages) do
    Enum.reject(pages, fn p ->
      p.id == site.homepage_page_id or p.show_in_nav == false
    end)
  end

  defp require_site(conn, _opts) do
    case conn.assigns[:current_site] do
      nil ->
        conn |> Plug.Conn.send_resp(404, "site not found") |> halt()

      _ ->
        conn
    end
  end

  defp page_structured_data(_conn, nil), do: nil

  defp page_structured_data(%{assigns: %{current_site: %{homepage_page_id: id}}}, %{id: id}),
    do: nil

  defp page_structured_data(conn, page), do: structured_data(conn, :web_page, page)

  # Only the canonical URL carries structured data: the active custom domain
  # (not the subdomain it shadows) and never a `?tag=` variant.
  defp structured_data(conn, kind, content) do
    site = conn.assigns.current_site
    base = Sites.public_url(site)

    if canonical_request?(conn, base), do: build_structured_data(kind, site, content, base)
  end

  defp canonical_request?(conn, base),
    do: conn.host == URI.parse(base).host and is_nil(conn.params["tag"])

  defp build_structured_data(:website, site, _content, base),
    do: StructuredData.website(site, base)

  defp build_structured_data(:web_page, site, page, base),
    do: StructuredData.web_page(site, page, base)

  defp build_structured_data(:article, site, post, base),
    do: StructuredData.article(site, post, base)

  defp send_themed(conn, body) when is_binary(body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(conn.status || 200, body)
  end
end

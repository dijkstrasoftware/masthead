defmodule MastheadWeb.PublicSeoController do
  @moduledoc """
  A site's `robots.txt`, `sitemap.xml` and `llms.txt`, generated from its
  published content on every request so owners never configure them.
  """
  use MastheadWeb, :controller

  alias Masthead.Content

  @sitemap_open ~s(<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)

  def robots(conn, _params) do
    send_text(conn, "text/plain", [
      "User-agent: *\nAllow: /\nDisallow: /search\n\nSitemap: ",
      base_url(conn),
      "/sitemap.xml\n"
    ])
  end

  def sitemap(conn, _params) do
    site = conn.assigns.current_site
    posts = Content.list_published_posts(site.id)

    entries =
      [{"/", newest_update(posts)}] ++
        Enum.map(listed_pages(site), &page_entry/1) ++
        Enum.map(posts, &post_entry/1)

    send_text(conn, "application/xml", [
      @sitemap_open,
      Enum.map(entries, &sitemap_url(&1, base_url(conn))),
      "</urlset>\n"
    ])
  end

  def llms(conn, _params) do
    site = conn.assigns.current_site
    base = base_url(conn)

    send_text(conn, "text/plain", [
      ["# ", one_line(site_title(site)), "\n\n"],
      summary(site.description),
      ["## Pages\n\n- [Home](", base, "/)\n"],
      Enum.map(listed_pages(site), &page_link(&1, base)),
      posts_section(Content.list_published_posts(site.id), base)
    ])
  end

  defp send_text(conn, content_type, body) do
    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end

  # Sitemap URLs must live on the host that served the sitemap, so the base
  # comes from the request rather than the site's configured domain.
  defp base_url(%{scheme: scheme, host: host, port: port}),
    do: "#{scheme}://#{host}#{port_suffix(scheme, port)}"

  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp listed_pages(site) do
    site.id
    |> Content.list_published_pages()
    |> Enum.reject(&homepage?(&1, site))
  end

  defp homepage?(page, site), do: page.id == site.homepage_page_id

  defp newest_update([]), do: nil

  defp newest_update(posts) do
    posts
    |> Enum.map(&updated_at/1)
    |> Enum.max(DateTime)
  end

  defp updated_at(%{updated_at: updated_at}), do: updated_at

  defp page_entry(page), do: {"/" <> page.slug, page.updated_at}

  defp post_entry(post), do: {"/posts/" <> post.slug, post.updated_at}

  defp sitemap_url({path, updated_at}, base) do
    [
      "  <url><loc>",
      Plug.HTML.html_escape(base <> path),
      "</loc>",
      lastmod(updated_at),
      "</url>\n"
    ]
  end

  defp lastmod(nil), do: []

  defp lastmod(updated_at) do
    date =
      updated_at
      |> DateTime.to_date()
      |> Date.to_iso8601()

    ["<lastmod>", date, "</lastmod>"]
  end

  defp site_title(%{title: title, name: name}) when title in [nil, ""], do: name
  defp site_title(%{title: title}), do: title

  defp summary(description) do
    description
    |> to_string()
    |> one_line()
    |> quote_line()
  end

  defp quote_line(""), do: []
  defp quote_line(text), do: ["> ", text, "\n\n"]

  defp page_link(page, base), do: ["- [", one_line(page.title), "](", base, "/", page.slug, ")\n"]

  defp posts_section([], _base), do: []

  defp posts_section(posts, base),
    do: ["\n## Posts\n\n", Enum.map(posts, &post_link(&1, base))]

  defp post_link(post, base) do
    note =
      post.excerpt
      |> to_string()
      |> one_line()
      |> link_note()

    ["- [", one_line(post.title), "](", base, "/posts/", post.slug, ")", note, "\n"]
  end

  defp link_note(""), do: []
  defp link_note(text), do: [": ", text]

  defp one_line(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end

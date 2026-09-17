defmodule Masthead.Themes.StructuredData do
  @moduledoc """
  Schema.org JSON-LD for public pages, built from the content model and
  injected into the rendered HTML independent of the site's theme.

  The homepage is a `WebSite`, a page a `WebPage` and a post an `Article`.
  Blank values are dropped so missing optional data never yields invalid
  output. A theme can opt out with `"structured_data": false` in its manifest.
  """

  @context "https://schema.org"

  def website(site, base) do
    compact(%{
      "@context" => @context,
      "@type" => "WebSite",
      "@id" => website_id(base),
      "url" => base <> "/",
      "name" => site_name(site),
      "description" => site.description,
      "publisher" => publisher(site, base)
    })
  end

  def web_page(site, page, base) do
    compact(%{
      "@context" => @context,
      "@type" => "WebPage",
      "url" => base <> "/" <> page.slug,
      "name" => page.title,
      "dateModified" => iso8601(page.updated_at),
      "isPartOf" => %{"@id" => website_id(base)},
      "publisher" => publisher(site, base)
    })
  end

  def article(site, post, base) do
    url = base <> "/posts/" <> post.slug

    compact(%{
      "@context" => @context,
      "@type" => "Article",
      "headline" => post.title,
      "description" => post.excerpt,
      "url" => url,
      "mainEntityOfPage" => url,
      "datePublished" => iso8601(post.published_at),
      "dateModified" => iso8601(post.updated_at),
      "isPartOf" => %{"@id" => website_id(base)},
      "publisher" => publisher(site, base)
    })
  end

  @doc """
  Puts `data` as a JSON-LD script before the first `</head>`, or at the end of
  a layout without one. Leaves `html` alone when there is no data or the
  theme opted out.
  """
  def inject(html, nil, _manifest), do: html
  def inject(html, _data, %{structured_data: false}), do: html

  def inject(html, data, _manifest) do
    script = [~s(<script type="application/ld+json">), json(data), "</script>"]

    case Regex.split(~r/<\/head>/i, html, parts: 2, include_captures: true) do
      [head, close, rest] -> IO.iodata_to_binary([head, script, close, rest])
      [_whole] -> IO.iodata_to_binary([html, script])
    end
  end

  defp json(data), do: Jason.encode!(data, escape: :html_safe)

  defp publisher(site, base),
    do: %{"@type" => "Organization", "name" => site_name(site), "url" => base <> "/"}

  defp website_id(base), do: base <> "/#website"

  defp site_name(%{title: title, name: name}) when title in [nil, ""], do: name
  defp site_name(%{title: title}), do: title

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)

  defp compact(map), do: Map.reject(map, &blank_value?/1)

  defp blank_value?({_key, value}), do: value in [nil, ""]
end

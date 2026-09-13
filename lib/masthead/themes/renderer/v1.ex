defmodule Masthead.Themes.Renderer.V1 do
  @moduledoc """
  Render contract v1, for themes whose manifest declares
  `"render_version": "v1"`.

  What changed from `Masthead.Themes.Renderer.Beta`:

    * per-page settings are declared as `page_options` (not `metadata`) and
      reach templates as `page.page_options.<key>`
    * posts carry their own settings: a manifest declares `post_options`, and
      every projected post — the one being rendered and every post in a list —
      exposes the effective merge as `post.post_options.<key>`

  Do not edit this module to change how themes render — copy it to a new
  version instead (see `Masthead.Themes.Renderer`). Fixing a crash or a
  security hole is fair game; changing output is not.
  """

  require Logger

  alias Masthead.Content
  alias Masthead.Themes.{CssSanitizer, Manifest, Presenter, Sandbox, TagPosts}
  alias Masthead.Uploads

  @doc """
  Render the site homepage (post list).

  Like `render_theme_page/1`, `tags`/`current_tag` are exposed (optional) so a
  theme can render a tag-filter bar on the index. A theme gates the bar on its
  own `show_tags` token; the data is always supplied.
  """
  def render_index(%{site: site, posts: posts, pages: pages} = assigns, entry) do
    current_tag = Map.get(assigns, :current_tag)

    render(site, entry, :index, %{
      "posts" => Presenter.posts(posts),
      "pages" => Presenter.pages(pages),
      "tags" => Presenter.tags(Map.get(assigns, :tags, []), current_tag && current_tag.slug),
      "current_tag" => Presenter.tag(current_tag),
      "post" => nil,
      "page" => nil,
      "body_html" => ""
    })
  end

  @doc """
  Render a single blog post. The full published-posts list is exposed as
  `posts` too, so a post template can pull related/tagged posts.
  """
  def render_post(%{site: site, post: post, pages: pages} = assigns, entry) do
    render(
      site,
      entry,
      :post,
      %{
        "post" => Presenter.post(post),
        "pages" => Presenter.pages(pages),
        "posts" => Presenter.posts(Map.get(assigns, :posts, [])),
        "page" => nil,
        "body_html" => Map.get(assigns, :body_html, "")
      },
      liquid_body: Map.get(assigns, :liquid_body)
    )
  end

  @doc """
  Render a standalone page (markdown or html). The full published-posts list
  is exposed as `posts` so any page can query posts by tag and render them as
  generic content blocks.
  """
  def render_page(%{site: site, page: page, pages: pages} = assigns, entry) do
    render(
      site,
      entry,
      :page,
      %{
        "page" => Presenter.page(page),
        "pages" => Presenter.pages(pages),
        "posts" => Presenter.posts(Map.get(assigns, :posts, [])),
        "post" => nil,
        "body_html" => Map.get(assigns, :body_html, "")
      },
      liquid_body: Map.get(assigns, :liquid_body)
    )
  end

  @doc """
  Render a theme page: a page whose layout is a Liquid template from the
  theme's `templates/pages/` folder (chosen via `page.template`). Theme pages
  have no editable body; they always receive the full (tag-filtered) post list,
  plus `tags`/`current_tag` so a template can render its own filter UI — which
  is how the former built-in "blog" format is now expressed as a theme page.
  """
  def render_theme_page(%{site: site, page: page, posts: posts, pages: pages} = assigns, entry) do
    current_tag = Map.get(assigns, :current_tag)

    render(site, entry, {:page_template, page.template}, %{
      "page" => Presenter.page(page),
      "posts" => Presenter.posts(posts),
      "pages" => Presenter.pages(pages),
      "tags" => Presenter.tags(Map.get(assigns, :tags, []), current_tag && current_tag.slug),
      "current_tag" => Presenter.tag(current_tag),
      "post" => nil,
      "body_html" => ""
    })
  end

  @doc "Render the site-scoped 404."
  def render_not_found(%{site: site, pages: pages} = assigns, entry) do
    render(site, entry, :not_found, %{
      "pages" => Presenter.pages(pages),
      "posts" => Presenter.posts(Map.get(assigns, :posts, [])),
      "post" => nil,
      "page" => nil,
      "body_html" => ""
    })
  end

  @doc """
  Render public search results. Reuses the theme's `index` template (so no
  new required template is introduced) and exposes `search_query` and
  `search_count` so a theme can branch on `{% if search_query %}` to show a
  results heading. `posts` is the already-filtered result set.
  """
  def render_search(%{site: site, posts: posts, query: query, pages: pages}, entry) do
    # Normalise a blank query to nil: an empty string is truthy in Liquid, so
    # leaving it as "" would render a "results for ''" heading on the
    # browse-everything view.
    search_query = if is_binary(query) and String.trim(query) != "", do: query, else: nil

    render(site, entry, :index, %{
      "posts" => Presenter.posts(posts),
      "pages" => Presenter.pages(pages),
      "tags" => [],
      "current_tag" => nil,
      "post" => nil,
      "page" => nil,
      "body_html" => "",
      "search_query" => search_query,
      "search_count" => length(posts)
    })
  end

  # ---- core ----

  defp render(site, entry, target, target_assigns, opts \\ []) do
    file_keys = file_token_keys(entry.manifest)

    tokens =
      entry.manifest
      |> Manifest.effective_tokens(site.theme_tokens || %{})
      |> resolve_file_fields(entry.manifest.tokens, site)

    base_context = %{
      "site" => Presenter.site(site),
      "posts_by_tag" => %TagPosts{
        resolver: tag_posts_resolver(site, entry.manifest.post_options)
      },
      "theme" => %{
        "name" => entry.theme.name,
        "slug" => entry.theme.slug,
        "version" => entry.theme.version,
        "asset_base" => entry.asset_base,
        "tokens" => tokens,
        "css" => composed_css(entry.css, tokens, file_keys)
      }
    }

    inner_template = fetch_template!(entry, target)
    layout_template = Map.fetch!(entry.templates, :layout)

    inner_context =
      base_context
      |> Map.merge(target_assigns)
      |> compose_post_options(entry, site)
      |> compose_page_options(entry, site)
      |> render_liquid_body(Keyword.get(opts, :liquid_body))

    {:ok, inner_iodata, _errs} = Sandbox.render(inner_template, inner_context)
    inner_html = IO.iodata_to_binary(inner_iodata)

    layout_context = Map.put(inner_context, "content", inner_html)
    {:ok, layout_iodata, _errs} = Sandbox.render(layout_template, layout_context)

    IO.iodata_to_binary(layout_iodata)
  end

  # Pick the inner template for a render target. A plain atom is one of the
  # fixed templates; `{:page_template, name}` is a theme page from the
  # `templates/pages/` folder. A theme page whose template is missing in the
  # current theme (theme switch, or the template was removed on a theme
  # update) falls back to the legacy `:blog` template if it's named "blog",
  # otherwise to the generic `:page` template — so the page still renders
  # rather than 500-ing.
  defp fetch_template!(entry, target) when is_atom(target) do
    Map.fetch!(entry.templates, target)
  end

  defp fetch_template!(entry, {:page_template, name}) do
    cond do
      is_binary(name) and Map.has_key?(entry.page_templates, name) ->
        entry.page_templates[name]

      name == "blog" and Map.has_key?(entry.templates, :blog) ->
        entry.templates[:blog]

      true ->
        Logger.warning(
          "theme page template #{inspect(name)} not found in theme #{entry.theme.slug}; " <>
            "falling back to :page"
        )

        Map.fetch!(entry.templates, :page)
    end
  end

  # An "html" post/page body is itself Liquid: render it against the same
  # context the template gets (site, theme.tokens, posts, page.page_options, ...)
  # and expose the result as `body_html`. The body is author-trusted, so it's
  # NOT sanitized — raw HTML and <script> pass through, the same as a theme
  # template. A broken template is caught at save time (changeset validation),
  # but stay defensive at render: on any error fall back to the raw body
  # rather than 500-ing the public page.
  # Build the `slug -> [post_map]` resolver behind `posts_by_tag`. Each lookup
  # is a real, site-scoped DB query; results are memoized in the (per-request)
  # process so referencing the same tag twice in a template doesn't re-query.
  defp tag_posts_resolver(site, fields) do
    fn slug ->
      key = {__MODULE__, :tag_posts, site.id, slug}

      case Process.get(key) do
        nil ->
          posts =
            site.id
            |> Content.list_published_posts_by_tag(slug)
            |> Presenter.posts()
            |> Enum.map(&effective_post(&1, fields, site))

          Process.put(key, posts)
          posts

        posts ->
          posts
      end
    end
  end

  defp render_liquid_body(context, nil), do: context

  defp render_liquid_body(context, raw_body) when is_binary(raw_body) do
    body_html =
      case Sandbox.render_string(raw_body, context) do
        {:ok, iodata} ->
          IO.iodata_to_binary(iodata)

        {:error, _err} ->
          # The body may have been entity-escaped in transit (a browser form
          # round-trip). Retry the unescaped form; only if that also fails do
          # we emit the raw body rather than 500 the page.
          case Sandbox.render_string(Sandbox.html_unescape(raw_body), context) do
            {:ok, iodata} -> IO.iodata_to_binary(iodata)
            {:error, _err} -> raw_body
          end
      end

    Map.put(context, "body_html", body_html)
  end

  defp compose_post_options(context, entry, site) do
    fields = entry.manifest.post_options

    context
    |> Map.replace_lazy("post", &effective_post(&1, fields, site))
    |> Map.replace_lazy("posts", fn posts ->
      if is_list(posts), do: Enum.map(posts, &effective_post(&1, fields, site)), else: posts
    end)
  end

  defp effective_post(post, fields, site) when is_map(post) do
    effective =
      fields
      |> Manifest.merge_fields(Map.get(post, "post_options", %{}))
      |> resolve_file_fields(fields, site)

    Map.put(post, "post_options", effective)
  end

  defp effective_post(post, _fields, _site), do: post

  defp compose_page_options(
         %{"page" => %{"template" => template} = page} = context,
         entry,
         site
       )
       when is_binary(template) and template != "" do
    fields = page_config_fields(entry, template)
    apply_effective(context, page, fields, site)
  end

  defp compose_page_options(%{"page" => %{} = page} = context, entry, site) do
    apply_effective(context, page, entry.manifest.page_options, site)
  end

  defp compose_page_options(context, _entry, _site), do: context

  # The settings field schema for a theme page comes from its sidecar config
  # (`templates/pages/<name>.json`), or [] when the page has no config.
  defp page_config_fields(entry, template) do
    case Map.get(entry.page_configs, template) do
      %{page_options: fields} when is_list(fields) -> fields
      _ -> []
    end
  end

  defp apply_effective(context, page, fields, site) do
    effective =
      fields
      |> Manifest.merge_fields(Map.get(page, "page_options", %{}))
      |> resolve_file_fields(fields, site)

    Map.put(context, "page", Map.put(page, "page_options", effective))
  end

  # A `file`-typed field (token or option, at any nesting depth) stores an
  # upload id; swap it for the upload's public URL so templates can use
  # `theme.tokens.<key>` / `page.page_options.<key>` directly. A blank or dangling
  # id resolves to "".
  defp resolve_file_fields(effective, fields, site) when is_map(effective) do
    Enum.reduce(fields, effective, fn field, acc ->
      case field.type do
        "file" ->
          Map.put(acc, field.key, resolve_upload_url(Map.get(acc, field.key), site))

        "object" ->
          obj = Map.get(acc, field.key)

          if is_map(obj),
            do: Map.put(acc, field.key, resolve_file_fields(obj, field.fields, site)),
            else: acc

        "list" ->
          items = Map.get(acc, field.key)

          if is_list(items) do
            Map.put(
              acc,
              field.key,
              Enum.map(items, &resolve_file_fields(&1, field.fields, site))
            )
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp resolve_file_fields(other, _fields, _site), do: other

  # The set of token keys declared as `file` in the manifest. These hold an
  # upload id (or "") rather than a literal CSS value, so they're resolved
  # to a URL and emitted as `url(...)` in the cascade.
  defp file_token_keys(%Manifest{tokens: tokens}) do
    for %{key: key, type: "file"} <- tokens, into: MapSet.new(), do: key
  end

  defp resolve_upload_url(id, site) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {int_id, ""} -> memoized_upload_url(site, int_id)
      _ -> ""
    end
  end

  defp resolve_upload_url(_id, _site), do: ""

  defp memoized_upload_url(site, int_id) do
    key = {__MODULE__, :upload_url, site.id, int_id}

    case Process.get(key) do
      nil ->
        url =
          case Uploads.get_upload(site.id, int_id) do
            nil -> ""
            upload -> Uploads.url(upload)
          end

        Process.put(key, url)
        url

      url ->
        url
    end
  end

  # Token overrides go AFTER the theme's CSS so they win in the cascade.
  defp composed_css(theme_css, tokens, _file_keys) when map_size(tokens) == 0, do: theme_css

  defp composed_css(theme_css, tokens, file_keys) do
    declarations =
      tokens
      # `object`/`list` tokens are template-only — a map or a list of maps has
      # no CSS custom-property form, so they never reach the `:root` block.
      |> Enum.reject(fn {_k, v} -> is_map(v) or is_list(v) end)
      |> Enum.map_join(" ", fn {k, v} -> declaration(k, v, file_keys) end)
      |> String.trim()

    if declarations == "" do
      theme_css
    else
      theme_css <> "\n:root { " <> declarations <> " }\n"
    end
  end

  # File tokens carry a resolved URL — wrap it as `url(...)` so themes can
  # write `background: var(--header-image)`. Skip empty file tokens entirely
  # so we never emit a useless `--key: url();`. The URL is sanitized first;
  # we leave it unquoted because the sanitizer strips quotes, and storage
  # keys/slugs never contain spaces or parens.
  defp declaration(key, value, file_keys) do
    if MapSet.member?(file_keys, key) do
      case CssSanitizer.sanitize_token_value(value) do
        "" -> ""
        url -> "--#{kebab(key)}: url(#{url});"
      end
    else
      "--#{kebab(key)}: #{CssSanitizer.sanitize_token_value(value)};"
    end
  end

  defp kebab(key), do: String.replace(key, "_", "-")
end

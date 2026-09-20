defmodule Masthead.Content.PreviewImport do
  @moduledoc """
  Imports an extracted `masthead preview` theme folder into a Masthead site,
  so the demo a theme developer built locally can go live as-is (see
  `Masthead.Content.SiteArchive` for the upload side).

  The archive's `manifest.json` has to name the theme the site runs, at the
  same version — the options and tokens a preview carries mean nothing to
  another theme — otherwise the import fails with `{:theme_mismatch, …}`.

  The preview data is resolved the way the CLI resolves it, minus its built-in
  sample content:

    * **posts / pages** — the sidebar's `preview.local.json` `content` list
      when present, else one file per item in `preview/posts|pages/`
      (`.md`/`.markdown`/`.html`, JSON front matter between `---` fences),
      else the inline `posts`/`pages` arrays in `preview.json`. They import
      published. A post keeps its `tags` and `published_at`; a page keeps its
      `format`/`template` and `show_in_nav`.
    * **options** — an item's `page_options` (or beta `metadata`) /
      `post_options`, with `preview.local.json`'s per-slug overrides on top.
    * **assets** — `assets/**` image and PDF files become uploads. Body
      references to `/assets/<file>` point at the upload URL; an option or
      token whose value is exactly `/assets/<file>` becomes the upload id,
      which is what a `file` field stores.
    * **site** — `preview.json` `site.title`, `description`, `css_overrides`
      and `homepage` (a page slug), plus the tokens from `preview.json` and
      `preview.local.json` merged over the site's own.
  """

  import Ecto.Changeset, only: [change: 2]

  alias Masthead.{Content, Repo, Sites, Themes}
  alias Masthead.Content.{Import, SiteArchive}

  @content_exts ~w(.md .markdown .html)
  @formats %{"pages" => ~w(markdown html theme), "posts" => ~w(markdown html)}
  @front_matter ~r/\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z/s

  @doc """
  Import the preview folder at `root` into `site`. Returns `{:ok, summary}` —
  see `SiteArchive.import/3`.
  """
  def run(site, root, author_id \\ nil) do
    with :ok <- check_theme(site, root), do: import_preview(site, root, author_id)
  end

  # A preview carries options and tokens declared by one theme at one version;
  # against any other theme they are values no template reads.
  defp check_theme(site, root) do
    manifest = read_json(Path.join(root, "manifest.json"))
    theme = site.theme_id && Themes.get_theme(site.theme_id)

    case {theme_label(manifest["slug"], manifest["version"]), theme_label(theme)} do
      {same, same} when is_binary(same) -> :ok
      {preview, installed} -> {:error, {:theme_mismatch, installed, preview}}
    end
  end

  defp theme_label(%Themes.Theme{} = theme), do: theme_label(theme.slug, theme.version)
  defp theme_label(nil), do: nil

  defp theme_label(slug, version) when is_binary(slug) and is_binary(version),
    do: slug <> " " <> version

  defp theme_label(_slug, _version), do: nil

  defp import_preview(site, root, author_id) do
    {assets, asset_stats} = SiteArchive.import_assets(site, Path.join(root, "assets"), "/assets/")

    ctx = %{
      site: site,
      root: root,
      author_id: author_id,
      assets: assets,
      seed: read_json(Path.join(root, "preview.json")),
      local: read_json(Path.join(root, "preview.local.json"))
    }

    {pages, skipped_pages} = import_items(ctx, "pages")
    {posts, skipped_posts} = import_items(ctx, "posts")

    {:ok,
     %{
       posts: posts,
       pages: pages,
       uploads: asset_stats.uploaded,
       skipped_assets: asset_stats.skipped,
       skipped_content: skipped_pages ++ skipped_posts ++ apply_site_settings(ctx, pages)
     }}
  end

  # ---- posts / pages ----

  defp import_items(ctx, kind) do
    ctx
    |> source_items(kind)
    |> Enum.map(&import_item(ctx, kind, &1))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> unwrap_results()
  end

  defp unwrap_results({created, skipped}),
    do: {Enum.map(created, &elem(&1, 1)), Enum.map(skipped, &elem(&1, 1))}

  defp source_items(ctx, kind) do
    items =
      local_items(ctx.local, kind) || file_items(ctx.root, kind) || seed_items(ctx.seed, kind)

    Enum.filter(items, &item_map?/1)
  end

  defp item_map?({_label, item}), do: is_map(item)

  defp local_items(local, kind) do
    case local |> map_at("content") |> Map.get(kind) do
      items when is_list(items) -> Enum.map(items, &{"preview.local.json", &1})
      _ -> nil
    end
  end

  defp file_items(root, kind) do
    root
    |> Path.join("preview/#{kind}/*")
    |> Path.wildcard()
    |> Enum.filter(&content_file?/1)
    |> Enum.map(&read_item_file(&1, root))
    |> nil_if_empty()
  end

  defp seed_items(seed, kind) do
    case Map.get(seed, kind) do
      items when is_list(items) -> Enum.map(items, &{"preview.json", &1})
      _ -> []
    end
  end

  defp content_file?(path),
    do: File.regular?(path) and String.downcase(Path.extname(path)) in @content_exts

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(items), do: items

  defp read_item_file(path, root) do
    {meta, body} = path |> File.read!() |> split_front_matter()
    name = path |> Path.basename() |> Path.rootname()

    item =
      meta
      |> Map.put_new("format", Import.format_from_filename(path))
      |> Map.put_new("slug", Slug.slugify(name) || "")
      |> Map.put_new("title", Import.title_from_filename(name))
      |> Map.put("body", body)

    {Path.relative_to(path, root), item}
  end

  defp split_front_matter(content) do
    case Regex.run(@front_matter, content) do
      [_, meta, body] -> {decode_map(meta), body}
      nil -> {%{}, content}
    end
  end

  defp import_item(ctx, "pages", {label, item}) do
    ctx.site.id
    |> Content.create_page(page_attrs(ctx, item))
    |> result(label)
  end

  defp import_item(ctx, "posts", {label, item}) do
    ctx.site.id
    |> Content.create_post(post_attrs(ctx, item), ctx.author_id)
    |> backdate(item["published_at"])
    |> result(label)
  end

  defp page_attrs(ctx, item) do
    %{
      "title" => item["title"],
      "slug" => item["slug"],
      "format" => format("pages", item["format"]),
      "template" => item["template"],
      "show_in_nav" => Map.get(item, "show_in_nav", true),
      "page_options" => options(ctx, "pages", item, item["page_options"] || item["metadata"]),
      "body" => body(ctx, item),
      "published" => true
    }
  end

  defp post_attrs(ctx, item) do
    %{
      "title" => item["title"],
      "slug" => item["slug"],
      "excerpt" => item["excerpt"] || "",
      "format" => format("posts", item["format"]),
      "post_options" => options(ctx, "posts", item, item["post_options"]),
      "body" => body(ctx, item),
      "published" => true,
      "tag_ids" => tag_ids(ctx.site.id, item["tags"])
    }
  end

  # The CLI renders any format it doesn't know as Markdown.
  defp format(kind, format) do
    if format in @formats[kind], do: format, else: "markdown"
  end

  defp body(ctx, item), do: SiteArchive.rewrite_assets(to_string(item["body"]), ctx.assets)

  defp options(ctx, kind, item, base) do
    overrides =
      ctx.local
      |> map_at(kind)
      |> map_at(item["slug"])
      |> map_at(option_key(kind))

    base
    |> map_or_empty()
    |> Map.merge(overrides)
    |> remap_files(ctx.assets)
  end

  defp option_key("pages"), do: "page_options"
  defp option_key("posts"), do: "post_options"

  defp result({:ok, record}, _label), do: {:ok, record}

  defp result({:error, changeset}, label),
    do: {:skip, {label, {:invalid, SiteArchive.changeset_error(changeset)}}}

  defp backdate({:ok, post}, value) do
    case parse_datetime(value) do
      nil -> {:ok, post}
      at -> post |> change(published_at: at) |> Repo.update()
    end
  end

  defp backdate(error, _value), do: error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _} -> parse_date(value)
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  # ---- tags ----

  defp tag_ids(site_id, tags) when is_list(tags) do
    tags
    |> Enum.map(&tag_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&ensure_tag(site_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp tag_ids(_site_id, _tags), do: []

  defp tag_name(name) when is_binary(name), do: name
  defp tag_name(%{"name" => name}) when is_binary(name), do: name
  defp tag_name(_tag), do: nil

  defp ensure_tag(site_id, name) do
    slug = Slug.slugify(name)

    case Enum.find(Content.list_tags(site_id), &(&1.slug == slug)) do
      nil -> create_tag_id(site_id, name)
      tag -> tag.id
    end
  end

  defp create_tag_id(site_id, name) do
    case Content.create_tag(site_id, %{"name" => name}) do
      {:ok, tag} -> tag.id
      {:error, _} -> nil
    end
  end

  # ---- site ----

  defp apply_site_settings(ctx, pages) do
    case Sites.update_settings(ctx.site, site_attrs(ctx, pages)) do
      {:ok, _site} ->
        []

      {:error, changeset} ->
        [{"preview.json", {:invalid, SiteArchive.changeset_error(changeset)}}]
    end
  end

  defp site_attrs(ctx, pages) do
    site = map_at(ctx.seed, "site")

    %{
      "title" => site["title"],
      "description" => site["description"],
      "theme_css_overrides" => site["css_overrides"],
      "homepage_page_id" => homepage_id(pages, site["homepage"]),
      "theme_tokens" => theme_tokens(ctx)
    }
    |> Map.reject(&nil_value?/1)
  end

  defp nil_value?({_key, value}), do: is_nil(value)

  defp homepage_id(_pages, nil), do: nil
  defp homepage_id(pages, slug), do: Enum.find_value(pages, &(&1.slug == slug && &1.id))

  defp theme_tokens(ctx) do
    preview_tokens =
      ctx.seed
      |> map_at("tokens")
      |> Map.merge(map_at(ctx.local, "tokens"))
      |> remap_files(ctx.assets)

    Map.merge(ctx.site.theme_tokens || %{}, preview_tokens)
  end

  # ---- helpers ----

  defp remap_files(value, assets) when is_map(value),
    do: Map.new(value, &remap_entry(&1, assets))

  defp remap_files(value, assets) when is_list(value),
    do: Enum.map(value, &remap_files(&1, assets))

  defp remap_files(value, assets) when is_binary(value) do
    case Map.fetch(assets, value) do
      {:ok, upload} -> to_string(upload.id)
      :error -> value
    end
  end

  defp remap_files(value, _assets), do: value

  defp remap_entry({key, value}, assets), do: {key, remap_files(value, assets)}

  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> decode_map(contents)
      {:error, _} -> %{}
    end
  end

  defp decode_map(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp map_at(map, key) when is_map(map), do: map |> Map.get(key) |> map_or_empty()
  defp map_at(_other, _key), do: %{}

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}
end

defmodule Masthead.Content.HugoImport do
  @moduledoc """
  Imports an extracted Hugo site into a Masthead site (see
  `Masthead.Content.SiteArchive` for the upload side).

  Translates the Hugo source into Masthead content:

    * `content/**` Markdown/HTML files become **posts** (when they live under a
      `post`/`posts`/`blog`/`articles`/`news` section) or **pages** (everything
      else). Frontmatter (YAML `---` or TOML `+++`) supplies the title, slug,
      and draft state; `draft: false` publishes, otherwise it stays a draft.
    * `static/**` image and PDF files become **uploads**.
    * The theme, layouts, config, and data files are ignored — Masthead themes
      are separate.

  URLs in the imported bodies are rewritten:

    * references to `static/` assets are pointed at their new upload URLs,
    * `figure` and `ref`/`relref` shortcodes are converted to Markdown,
    * trailing slashes on root-relative links are dropped to match Masthead's
      URLs (`/posts/<slug>`, `/<slug>`).

  This is a best-effort importer: unsupported shortcodes are left as-is, and
  internal links resolve when the Hugo slug matches Masthead's slugified one.
  """

  alias Masthead.Content
  alias Masthead.Content.{Frontmatter, Import, SiteArchive}

  @post_sections ~w(post posts blog articles article news)
  @content_exts ~w(.md .markdown .html .htm)
  @index_names ~w(index.md index.html)
  @section_index_names ~w(_index.md _index.html)

  @doc """
  Import the extracted Hugo site at `root` into `site`. Called by
  `Masthead.Content.SiteArchive`, which handles the archive and detection.

  Returns `{:ok, summary}` — see `SiteArchive.import/3`.
  """
  def run(site, root, author_id \\ nil) do
    {assets, asset_stats} = import_assets(site, root)
    {posts, pages, skipped} = import_content(site, root, assets, author_id)

    {:ok,
     %{
       posts: posts,
       pages: pages,
       uploads: asset_stats.uploaded,
       skipped_assets: asset_stats.skipped,
       skipped_content: skipped
     }}
  end

  # ---- assets ----

  defp import_assets(site, root) do
    static = Path.join(root, "static")

    if File.dir?(static) do
      {assets, stats} = SiteArchive.import_assets(site, static, "/")
      {Map.merge(assets, Map.new(assets, &bare_path/1)), stats}
    else
      {%{}, %{uploaded: 0, skipped: 0}}
    end
  end

  defp bare_path({"/" <> rel, upload}), do: {rel, upload}

  # ---- content ----

  defp import_content(site, root, assets, author_id) do
    content_dir = Path.join(root, "content")

    content_dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in @content_exts))
    |> Enum.reduce({[], [], []}, fn abs, {posts, pages, skipped} ->
      rel = Path.relative_to(abs, content_dir)

      case import_file(site, abs, rel, assets, author_id) do
        {:post, post} -> {[post | posts], pages, skipped}
        {:page, page} -> {posts, [page | pages], skipped}
        {:skip, reason} -> {posts, pages, [{rel, reason} | skipped]}
      end
    end)
    |> then(fn {posts, pages, skipped} ->
      {Enum.reverse(posts), Enum.reverse(pages), Enum.reverse(skipped)}
    end)
  end

  defp import_file(site, abs, rel, assets, author_id) do
    basename = Path.basename(abs)

    if basename in @section_index_names do
      # `_index.md` defines a section's list page in Hugo — there's no direct
      # Masthead equivalent, so skip it rather than create an odd empty page.
      {:skip, :section_index}
    else
      {meta, body} = abs |> File.read!() |> Frontmatter.split()

      attrs = %{
        "title" => Import.frontmatter_title(meta) || title_for(rel, basename),
        "slug" => slug_for(meta, rel, basename),
        "format" => Import.format_from_filename(basename),
        "body" => rewrite(body, assets),
        "published" => to_string(Import.published?(meta))
      }

      if post_path?(rel) do
        finish(:post, Content.create_post(site.id, attrs, author_id))
      else
        # Pages follow the normal default (shown in nav). Unpublished imports
        # are drafts and stay out of the nav until published regardless.
        finish(:page, Content.create_page(site.id, attrs))
      end
    end
  end

  defp finish(kind, {:ok, record}), do: {kind, record}

  defp finish(_kind, {:error, changeset}),
    do: {:skip, {:invalid, SiteArchive.changeset_error(changeset)}}

  defp post_path?(rel) do
    case Path.split(rel) do
      [first | _] -> String.downcase(first) in @post_sections
      _ -> false
    end
  end

  defp slug_for(meta, rel, basename) do
    cond do
      slug = present(meta["slug"]) -> last_segment(slug)
      url = present(meta["url"]) -> last_segment(url)
      basename in @index_names -> rel |> Path.dirname() |> Path.basename()
      true -> Path.rootname(basename)
    end
  end

  defp title_for(rel, basename) do
    source =
      if basename in @index_names,
        do: rel |> Path.dirname() |> Path.basename(),
        else: basename

    Import.title_from_filename(source)
  end

  defp last_segment(path), do: path |> String.trim("/") |> Path.basename()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp present(_), do: nil

  # ---- URL / shortcode rewriting ----

  @figure ~r/\{\{[<%]\s*figure\s+(.*?)\s*[%>]\}\}/s
  @ref ~r/\{\{[<%]\s*(?:ref|relref)\s+"([^"]+)"\s*[%>]\}\}/

  defp rewrite(body, assets) do
    body
    |> rewrite_shortcodes()
    |> SiteArchive.rewrite_assets(assets)
    |> strip_trailing_slashes()
  end

  defp rewrite_shortcodes(body) do
    body =
      Regex.replace(@figure, body, fn whole, attrs ->
        case shortcode_attr(attrs, "src") do
          nil ->
            whole

          src ->
            alt = shortcode_attr(attrs, "alt") || shortcode_attr(attrs, "caption") || ""
            "![#{alt}](#{src})"
        end
      end)

    Regex.replace(@ref, body, fn _whole, target -> target end)
  end

  defp shortcode_attr(attrs, key) do
    case Regex.run(~r/#{key}\s*=\s*"([^"]*)"/, attrs) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp strip_trailing_slashes(body) do
    body = Regex.replace(~r/\]\((\/[^)\s]+?)\/\)/, body, "](\\1)")
    Regex.replace(~r/(href|src)="(\/[^"]+?)\/"/, body, ~S(\1="\2"))
  end
end

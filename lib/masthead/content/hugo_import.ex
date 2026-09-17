defmodule Masthead.Content.HugoImport do
  @moduledoc """
  Imports a Hugo site (uploaded as a `.zip`) into a Masthead site.

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

  alias Masthead.{Content, Uploads}
  alias Masthead.Content.{Frontmatter, Import}

  @max_files 10_000
  @max_uncompressed_bytes 300_000_000
  @post_sections ~w(post posts blog articles article news)
  @content_exts ~w(.md .markdown .html .htm)
  @index_names ~w(index.md index.html)
  @section_index_names ~w(_index.md _index.html)

  @doc """
  Import the Hugo archive at `archive_path` into `site`.

  Returns `{:ok, summary}` where `summary` is a map of created `posts`/`pages`
  records, the count of `uploads` and `skipped_assets`, and a
  `skipped_content` list of `{relative_path, reason}` tuples. Returns
  `{:error, reason}` if the archive can't be read.
  """
  def run(site, archive_path, author_id \\ nil) do
    with {:ok, tmp} <- extract(archive_path),
         {:ok, root} <- find_root(tmp) do
      try do
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
      after
        File.rm_rf(tmp)
      end
    end
  end

  # ---- archive extraction (mirrors the safety caps in Themes.Package) ----

  defp extract(archive_path) do
    charlist = String.to_charlist(archive_path)

    with {:ok, entries} <- safe_list(charlist),
         :ok <- check_caps(entries) do
      tmp = Path.join(System.tmp_dir!(), "masthead-hugo-" <> random_id())
      File.mkdir_p!(tmp)

      case :zip.unzip(charlist, [{:cwd, String.to_charlist(tmp)}]) do
        {:ok, _} ->
          {:ok, tmp}

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, {:unzip_failed, reason}}
      end
    end
  end

  defp safe_list(charlist) do
    case :zip.list_dir(charlist) do
      {:ok, [_comment | files]} -> {:ok, files}
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:archive_invalid, reason}}
    end
  rescue
    e -> {:error, {:archive_invalid, Exception.message(e)}}
  end

  defp check_caps(entries) do
    files = Enum.filter(entries, &match?({:zip_file, _, _, _, _, _}, &1))

    total =
      Enum.reduce(files, 0, fn {:zip_file, _, info, _, _, _}, acc -> acc + file_size(info) end)

    cond do
      length(files) > @max_files -> {:error, :too_many_files}
      total > @max_uncompressed_bytes -> {:error, :archive_too_large}
      true -> validate_paths(files)
    end
  end

  defp validate_paths(files) do
    Enum.reduce_while(files, :ok, fn {:zip_file, name, _, _, _, _}, _ ->
      name = List.to_string(name)

      cond do
        String.starts_with?(name, "/") -> {:halt, {:error, {:absolute_path, name}}}
        String.contains?(name, "..") -> {:halt, {:error, {:traversal, name}}}
        String.contains?(name, "\\") -> {:halt, {:error, {:backslash, name}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp file_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _}), do: size
  defp file_size(_), do: 0

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  # The Hugo root is wherever `content/` lives — at the archive root or one
  # directory down (a zip of the project folder).
  defp find_root(tmp) do
    cond do
      File.dir?(Path.join(tmp, "content")) ->
        {:ok, tmp}

      true ->
        case Path.wildcard(Path.join(tmp, "*/content")) |> Enum.filter(&File.dir?/1) do
          [content | _] -> {:ok, Path.dirname(content)}
          [] -> {:error, :no_content_dir}
        end
    end
  end

  # ---- assets ----

  defp import_assets(site, root) do
    static = Path.join(root, "static")

    if File.dir?(static) do
      static
      |> Path.join("**")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.reduce({%{}, %{uploaded: 0, skipped: 0}}, fn abs, {map, stats} ->
        rel = Path.relative_to(abs, static)

        case Uploads.store_image(site, %{
               filename: Path.basename(abs),
               content_type: nil,
               path: abs
             }) do
          {:ok, upload} ->
            url = Uploads.url(upload)
            {Map.merge(map, %{("/" <> rel) => url, rel => url}), bump(stats, :uploaded)}

          {:error, _} ->
            {map, bump(stats, :skipped)}
        end
      end)
    else
      {%{}, %{uploaded: 0, skipped: 0}}
    end
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

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
  defp finish(_kind, {:error, changeset}), do: {:skip, {:invalid, changeset_error(changeset)}}

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

  defp changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  # ---- URL / shortcode rewriting ----

  @figure ~r/\{\{[<%]\s*figure\s+(.*?)\s*[%>]\}\}/s
  @ref ~r/\{\{[<%]\s*(?:ref|relref)\s+"([^"]+)"\s*[%>]\}\}/

  defp rewrite(body, assets) do
    body
    |> rewrite_shortcodes()
    |> rewrite_assets(assets)
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

  defp rewrite_assets(body, assets) do
    assets
    |> Map.keys()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(body, fn path, acc -> String.replace(acc, path, Map.fetch!(assets, path)) end)
  end

  defp strip_trailing_slashes(body) do
    body = Regex.replace(~r/\]\((\/[^)\s]+?)\/\)/, body, "](\\1)")
    Regex.replace(~r/(href|src)="(\/[^"]+?)\/"/, body, ~S(\1="\2"))
  end
end

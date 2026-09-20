defmodule Masthead.Content.SiteArchive do
  @moduledoc """
  Imports an uploaded site archive (`.zip`) into a Masthead site.

  The archive is extracted with the same safety caps as `Themes.Package`, then
  detected by its shape — at the archive root or one directory down (a zip of
  the project folder):

    * a `masthead preview` theme folder (`preview.json`, `preview.local.json`
      or `preview/`) goes to `Masthead.Content.PreviewImport`,
    * a Hugo site (`content/`) goes to `Masthead.Content.HugoImport`.

  Also holds the asset and error helpers both importers share.
  """

  alias Masthead.Uploads
  alias Masthead.Content.{HugoImport, PreviewImport}

  @max_files 10_000
  @max_uncompressed_bytes 300_000_000
  @preview_markers ~w(preview.json preview.local.json preview)

  @doc """
  Import the archive at `archive_path` into `site`.

  Returns `{:ok, summary}` where `summary` is a map of created `posts`/`pages`
  records, the count of `uploads` and `skipped_assets`, and a
  `skipped_content` list of `{relative_path, reason}` tuples. Returns
  `{:error, reason}` if the archive can't be read or isn't a known site.
  """
  def import(site, archive_path, author_id \\ nil) do
    with {:ok, tmp} <- extract(archive_path) do
      try do
        import_detected(site, detect(tmp), author_id)
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp import_detected(site, {:preview, root}, author_id),
    do: PreviewImport.run(site, root, author_id)

  defp import_detected(site, {:hugo, root}, author_id), do: HugoImport.run(site, root, author_id)
  defp import_detected(_site, :unknown, _author_id), do: {:error, :unrecognized_site}

  defp detect(tmp) do
    [tmp | Path.wildcard(Path.join(tmp, "*"))]
    |> Enum.filter(&File.dir?/1)
    |> Enum.find_value(:unknown, &site_kind/1)
  end

  defp site_kind(dir) do
    cond do
      Enum.any?(@preview_markers, &File.exists?(Path.join(dir, &1))) -> {:preview, dir}
      File.dir?(Path.join(dir, "content")) -> {:hugo, dir}
      true -> nil
    end
  end

  @doc """
  Store every file under `dir` as an upload. Returns `{assets, stats}` where
  `assets` maps each file's URL path (`url_prefix` + relative path) to its
  `%Upload{}`, and `stats` counts `uploaded` and `skipped` files.
  """
  def import_assets(site, dir, url_prefix) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce({%{}, %{uploaded: 0, skipped: 0}}, &store_asset(&1, &2, site, dir, url_prefix))
  end

  defp store_asset(abs, {assets, stats}, site, dir, url_prefix) do
    upload = %{filename: Path.basename(abs), content_type: nil, path: abs}

    case Uploads.store_image(site, upload) do
      {:ok, upload} ->
        {Map.put(assets, url_prefix <> Path.relative_to(abs, dir), upload),
         bump(stats, :uploaded)}

      {:error, _} ->
        {assets, bump(stats, :skipped)}
    end
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  @doc """
  Point every reference to an imported asset path in `body` at its upload
  URL. `assets` maps path → `%Upload{}` (see `import_assets/3`).
  """
  def rewrite_assets(body, assets) do
    assets
    |> Map.keys()
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(body, &String.replace(&2, &1, Uploads.url(Map.fetch!(assets, &1))))
  end

  @doc "Flatten a changeset's errors into one `field message; …` line."
  def changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  # ---- archive extraction (mirrors the safety caps in Themes.Package) ----

  defp extract(archive_path) do
    charlist = String.to_charlist(archive_path)

    with {:ok, entries} <- safe_list(charlist),
         :ok <- check_caps(entries) do
      tmp = Path.join(System.tmp_dir!(), "masthead-import-" <> random_id())
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
end

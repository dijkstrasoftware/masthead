defmodule Masthead.Themes.Package do
  @moduledoc """
  Validate and install an uploaded theme archive.

  An archive is a zip file laid out as:

      manifest.json
      templates/{layout,index,post,page,blog,not_found}.liquid
      theme.css
      assets/...    # optional

  This module is the trust boundary for everything uploaded. It:

    1. Refuses the archive if it would exceed the size/count/extension caps.
    2. Extracts into a temp dir, ignoring symlinks and path-traversal
       entries.
    3. Validates `manifest.json`, parses every `.liquid` template through
       the sandbox, and reads `theme.css`.
    4. Promotes the extracted files into `Masthead.Storage` at
       `themes/<slug>/<version>/...`.
    5. Inserts a new row, or — if a theme with the same slug already
       exists for this owner and the uploaded `version` is strictly
       newer (semver) — updates the existing row in place. Then warms
       the loader cache.

  Errors short-circuit; nothing is written to Storage or the DB unless
  every previous step succeeded.
  """

  alias Masthead.Themes
  alias Masthead.Themes.{Loader, Manifest, Sandbox, Theme}

  @max_zip_bytes 5 * 1024 * 1024
  @max_uncompressed_bytes 25 * 1024 * 1024
  @max_files 200
  @template_names ~w(layout index post page not_found)
  # `blog` is no longer required (it moved to templates/pages/), but a theme
  # may still ship it; load it when present for back-compat.
  @optional_template_names ~w(blog)
  @allowed_asset_extensions ~w(.css .js .mjs .png .jpg .jpeg .gif .webp .svg .woff .woff2 .ttf .otf .ico .json)

  @doc """
  Validate, extract, and install an uploaded zip located at `archive_path`
  for `owner_id`.

  Returns `{:ok, %Theme{}}` or `{:error, reason}`.
  """
  def install(archive_path, owner_id) when is_binary(archive_path) and is_integer(owner_id) do
    with :ok <- check_size(archive_path),
         {:ok, entries} <- safe_list(archive_path),
         :ok <- check_entry_caps(entries),
         {:ok, tmp_root} <- extract_to_tmp(archive_path, entries),
         {:ok, bundle} <- read_bundle(tmp_root),
         {:ok, action} <- resolve_target(bundle.manifest, owner_id),
         {:ok, theme} <- promote_and_persist(bundle, owner_id, action) do
      _ = File.rm_rf(tmp_root)
      warm_cache(theme, bundle)
      {:ok, theme}
    else
      {:error, _} = err ->
        # nothing to clean up if we never reached extract_to_tmp; cleanup
        # is best-effort and silent on success too
        err
    end
  end

  # ---- step 1: size cap ----

  defp check_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_zip_bytes ->
        :ok

      {:ok, %{size: size}} ->
        {:error, {:archive_too_large, size, @max_zip_bytes}}

      {:error, reason} ->
        {:error, {:archive_unreadable, reason}}
    end
  end

  # ---- step 2: list (without extracting) ----

  defp safe_list(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, [_comment | files]} -> {:ok, files}
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, {:archive_invalid, reason}}
    end
  rescue
    e -> {:error, {:archive_invalid, Exception.message(e)}}
  end

  # ---- step 3: cap entry count + uncompressed size + path safety ----

  defp check_entry_caps(entries) do
    files =
      Enum.filter(entries, fn
        {:zip_file, _, _, _, _, _} -> true
        _ -> false
      end)

    cond do
      length(files) > @max_files ->
        {:error, {:too_many_files, length(files), @max_files}}

      true ->
        total = total_uncompressed(files)

        if total > @max_uncompressed_bytes do
          {:error, {:uncompressed_too_large, total, @max_uncompressed_bytes}}
        else
          Enum.reduce_while(files, :ok, fn file, _acc ->
            {:zip_file, name, _info, _comment, _offset, _comp_size} = file
            name_str = List.to_string(name)

            cond do
              String.starts_with?(name_str, "/") -> {:halt, {:error, {:absolute_path, name_str}}}
              String.contains?(name_str, "..") -> {:halt, {:error, {:traversal, name_str}}}
              String.contains?(name_str, "\\") -> {:halt, {:error, {:backslash, name_str}}}
              true -> {:cont, :ok}
            end
          end)
        end
    end
  end

  defp total_uncompressed(files) do
    Enum.reduce(files, 0, fn {:zip_file, _name, info, _comment, _offset, _comp_size}, acc ->
      acc + file_info_size(info)
    end)
  end

  defp file_info_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _}), do: size
  defp file_info_size(_), do: 0

  # ---- step 4: extract ----

  defp extract_to_tmp(archive_path, _entries) do
    tmp_root = Path.join(System.tmp_dir!(), "masthead-theme-" <> random_id())
    File.mkdir_p!(tmp_root)

    case :zip.unzip(String.to_charlist(archive_path), [{:cwd, String.to_charlist(tmp_root)}]) do
      {:ok, _files} ->
        {:ok, tmp_root}

      {:error, reason} ->
        _ = File.rm_rf(tmp_root)
        {:error, {:unzip_failed, reason}}
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  # ---- step 5: read + validate bundle ----

  defp read_bundle(root) do
    with {:ok, manifest} <- read_manifest(root),
         {:ok, templates} <- read_templates(root),
         {:ok, page_templates} <- read_page_templates(root),
         {:ok, page_configs} <- read_page_configs(root),
         {:ok, css} <- read_css(root) do
      asset_files = list_asset_files(root)

      case asset_files do
        {:ok, assets} ->
          {:ok,
           %{
             manifest: manifest,
             templates: templates,
             page_templates: page_templates,
             page_template_names: Map.keys(page_templates) |> Enum.sort(),
             page_configs: page_configs,
             css: css,
             assets: assets,
             root: root
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp read_manifest(root) do
    path = Path.join(root, "manifest.json")

    with {:ok, body} <- File.read(path),
         {:ok, manifest} <- Manifest.parse(body) do
      {:ok, manifest}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:manifest_invalid, [Exception.message(e)]}}
      {:error, reasons} when is_list(reasons) -> {:error, {:manifest_invalid, reasons}}
      {:error, :enoent} -> {:error, :manifest_missing}
      {:error, reason} -> {:error, {:manifest_unreadable, reason}}
    end
  end

  defp read_templates(root) do
    with {:ok, required} <- read_required_templates(root) do
      read_optional_templates(root, required)
    end
  end

  defp read_required_templates(root) do
    Enum.reduce_while(@template_names, {:ok, %{}}, fn name, {:ok, acc} ->
      path = Path.join([root, "templates", name <> ".liquid"])

      case File.read(path) do
        {:ok, body} ->
          case Sandbox.parse(body) do
            {:ok, template} -> {:cont, {:ok, Map.put(acc, String.to_atom(name), template)}}
            {:error, err} -> {:halt, {:error, {:template_invalid, name, err}}}
          end

        {:error, :enoent} ->
          {:halt, {:error, {:template_missing, name}}}

        {:error, reason} ->
          {:halt, {:error, {:template_unreadable, name, reason}}}
      end
    end)
  end

  defp read_optional_templates(root, acc) do
    Enum.reduce_while(@optional_template_names, {:ok, acc}, fn name, {:ok, acc} ->
      path = Path.join([root, "templates", name <> ".liquid"])

      case File.read(path) do
        {:ok, body} ->
          case Sandbox.parse(body) do
            {:ok, template} -> {:cont, {:ok, Map.put(acc, String.to_atom(name), template)}}
            {:error, err} -> {:halt, {:error, {:template_invalid, name, err}}}
          end

        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, {:template_unreadable, name, reason}}}
      end
    end)
  end

  # Theme pages live in templates/pages/<name>.liquid. Names are author-chosen,
  # so they're kept as string keys (never atoms) here and in the cache.
  defp read_page_templates(root) do
    dir = Path.join([root, "templates", "pages"])

    case File.dir?(dir) do
      false ->
        {:ok, %{}}

      true ->
        names = page_template_names(dir)

        Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
          path = Path.join(dir, name <> ".liquid")

          case File.read(path) do
            {:ok, body} ->
              case Sandbox.parse(body) do
                {:ok, template} -> {:cont, {:ok, Map.put(acc, name, template)}}
                {:error, err} -> {:halt, {:error, {:page_template_invalid, name, err}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:page_template_unreadable, name, reason}}}
          end
        end)
    end
  end

  defp page_template_names(dir) do
    dir
    |> Path.join("*.liquid")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.basename(&1, ".liquid"))
    |> Enum.sort()
  end

  # Each `templates/pages/<name>.json` is an optional sidecar config (label,
  # description, page_options). Validated strictly: a present-but-invalid one fails
  # the install, like a bad manifest/template.
  defp read_page_configs(root) do
    dir = Path.join([root, "templates", "pages"])

    case File.dir?(dir) do
      false ->
        {:ok, %{}}

      true ->
        names =
          dir
          |> Path.join("*.json")
          |> Path.wildcard()
          |> Enum.reject(&File.dir?/1)
          |> Enum.map(&Path.basename(&1, ".json"))
          |> Enum.sort()

        Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
          path = Path.join(dir, name <> ".json")

          case File.read(path) do
            {:ok, body} ->
              case Manifest.parse_page_config(body) do
                {:ok, config} -> {:cont, {:ok, Map.put(acc, name, config)}}
                {:error, errors} -> {:halt, {:error, {:page_config_invalid, name, errors}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:page_config_unreadable, name, reason}}}
          end
        end)
    end
  end

  defp read_css(root) do
    path = Path.join(root, "theme.css")

    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :theme_css_missing}
      {:error, reason} -> {:error, {:theme_css_unreadable, reason}}
    end
  end

  defp list_asset_files(root) do
    assets_root = Path.join(root, "assets")

    case File.dir?(assets_root) do
      false ->
        {:ok, []}

      true ->
        files =
          assets_root
          |> Path.join("**")
          |> Path.wildcard()
          |> Enum.reject(&File.dir?/1)

        case Enum.find(files, fn f ->
               ext = f |> Path.extname() |> String.downcase()
               ext not in @allowed_asset_extensions
             end) do
          nil ->
            assets =
              Enum.map(files, fn abs ->
                rel = Path.relative_to(abs, assets_root)
                {rel, abs}
              end)

            {:ok, assets}

          bad ->
            {:error, {:disallowed_asset, Path.relative_to(bad, assets_root)}}
        end
    end
  end

  # ---- step 6: resolve install vs update ----

  # Decides what the upload should do:
  #   {:ok, :install}            — no existing theme; create a new row
  #   {:ok, {:update, theme}}    — same slug+owner exists and the uploaded
  #                                version is strictly newer (semver)
  #   {:error, ...}              — reserved slug, not-newer version, or a
  #                                version that isn't valid semver
  defp resolve_target(%Manifest{slug: slug}, _owner_id)
       when slug in ~w(default) do
    {:error, {:slug_reserved, slug}}
  end

  defp resolve_target(%Manifest{slug: slug, version: new_version}, owner_id) do
    case Masthead.Repo.get_by(Theme, slug: slug, owner_id: owner_id, source: "uploaded") do
      nil ->
        {:ok, :install}

      %Theme{version: old_version} = existing ->
        with {:ok, new_v} <- parse_version(new_version),
             {:ok, old_v} <- parse_version(old_version) do
          case Version.compare(new_v, old_v) do
            :gt -> {:ok, {:update, existing}}
            _ -> {:error, {:version_not_newer, slug, old_version, new_version}}
          end
        end
    end
  end

  defp parse_version(v) when is_binary(v) do
    case Version.parse(v) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:version_unparseable, v}}
    end
  end

  # ---- step 7: promote + persist (insert or update) ----

  defp promote_and_persist(bundle, owner_id, action) do
    manifest = bundle.manifest
    # The version is part of the storage path, so a newer version writes
    # to a fresh directory; the previous version's files stay in storage
    # (orphaned, harmless — versioned storage is forward-compatible with
    # a future rollback feature).
    storage_path = Theme.upload_storage_path(manifest.slug, manifest.version)

    case promote_files(bundle, storage_path) do
      :ok ->
        attrs = %{
          slug: manifest.slug,
          name: manifest.name,
          description: manifest.description || "",
          version: manifest.version,
          owner_id: owner_id,
          storage_path: storage_path,
          manifest: manifest_to_map(manifest, bundle.page_template_names, bundle.page_configs)
        }

        case persist(action, attrs) do
          {:ok, theme} ->
            {:ok, theme}

          {:error, changeset} ->
            cleanup_storage(storage_path, bundle)
            {:error, {:db_write, changeset}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp persist(:install, attrs), do: Themes.create_upload(attrs)

  defp persist({:update, %Theme{} = existing}, attrs) do
    case Themes.update_theme(existing, attrs) do
      {:ok, theme} = ok ->
        # Drop the cached parse of the previous version so the next
        # render reads the new templates/css. warm_cache/2 (called by
        # install/3 on success) then repopulates it.
        Masthead.Themes.Loader.invalidate(theme.id)
        ok

      err ->
        err
    end
  end

  defp promote_files(bundle, storage_path) do
    files = file_listing(bundle)

    Enum.reduce_while(files, :ok, fn {rel, abs}, _acc ->
      key = Path.join(storage_path_tail(storage_path), rel)

      case Masthead.Storage.stream_into("themes", key, abs) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:promote_failed, rel, reason}}}
      end
    end)
  end

  # We stream into "themes" + <slug>/<version>/<rel>; strip the leading
  # "themes/" so we don't end up with "themes/themes/..." paths.
  defp storage_path_tail("themes/" <> rest), do: rest
  defp storage_path_tail(other), do: other

  defp file_listing(bundle) do
    manifest_file = {"manifest.json", Path.join(bundle.root, "manifest.json")}
    css_file = {"theme.css", Path.join(bundle.root, "theme.css")}

    # Only list fixed templates that were actually read (optional `blog` may be
    # absent). `bundle.templates` is keyed by atom; reuse those names.
    template_files =
      Enum.map(Map.keys(bundle.templates), fn name ->
        rel = Path.join("templates", Atom.to_string(name) <> ".liquid")
        {rel, Path.join(bundle.root, rel)}
      end)

    page_template_files =
      Enum.map(bundle.page_template_names, fn name ->
        rel = Path.join(["templates", "pages", name <> ".liquid"])
        {rel, Path.join(bundle.root, rel)}
      end)

    # Sidecar configs (only the names that actually have a .json).
    page_config_files =
      Enum.map(Map.keys(bundle.page_configs), fn name ->
        rel = Path.join(["templates", "pages", name <> ".json"])
        {rel, Path.join(bundle.root, rel)}
      end)

    asset_files =
      Enum.map(bundle.assets, fn {rel, abs} ->
        {Path.join("assets", rel), abs}
      end)

    [manifest_file, css_file | template_files] ++
      page_template_files ++ page_config_files ++ asset_files
  end

  defp cleanup_storage(_storage_path, _bundle) do
    # Best-effort: re-list what we promoted and delete it. For v1 we let
    # the local filesystem / S3 bucket retain the orphans rather than
    # implementing a recursive delete here. The hardening phase tightens
    # this.
    :ok
  end

  defp manifest_to_map(%Manifest{} = m) do
    %{
      "name" => m.name,
      "slug" => m.slug,
      "version" => m.version,
      "author" => m.author,
      "description" => m.description,
      "render_version" => m.render_version,
      "tokens" => Enum.map(m.tokens, &Manifest.field_to_map/1),
      "page_options" => Enum.map(m.page_options, &Manifest.field_to_map/1),
      "post_options" => Enum.map(m.post_options, &Manifest.field_to_map/1)
    }
  end

  # Persist the installed page-template names and their sidecar configs so the
  # render path / admin UI can find theme pages (and their settings) without
  # listing object storage.
  defp manifest_to_map(%Manifest{} = m, page_template_names, page_configs) do
    serialized =
      Map.new(page_configs, fn {name, config} -> {name, Manifest.page_config_to_map(config)} end)

    m
    |> manifest_to_map()
    |> Map.put("page_templates", page_template_names)
    |> Map.put("page_configs", serialized)
  end

  # ---- step 8: warm cache ----

  defp warm_cache(%Theme{} = theme, bundle) do
    entry = %{
      theme: theme,
      manifest: bundle.manifest,
      templates: bundle.templates,
      page_templates: bundle.page_templates,
      page_configs: bundle.page_configs,
      css: bundle.css,
      asset_base: "/uploads/" <> theme.storage_path <> "/assets"
    }

    # Same key shape as Loader uses.
    :persistent_term.put({Loader, theme.id}, entry)
    :ok
  end
end

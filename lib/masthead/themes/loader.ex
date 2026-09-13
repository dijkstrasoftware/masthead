defmodule Masthead.Themes.Loader do
  @moduledoc """
  Loads a theme's source files (manifest, templates, CSS) into memory and
  caches the parsed result in `:persistent_term`.

  Two source roots are supported:

    * `built_in` themes live in `priv/themes/<slug>/`
    * `uploaded` themes live under `Masthead.Storage` at the theme's
      `storage_path` (handled in Phase 4 once uploads land)

  The loader is the only file-reading code path for themes — once it has
  cached a theme, `Renderer` works entirely off the in-memory entry.
  """

  alias Masthead.Themes.{Manifest, Sandbox, Theme}

  @cache_key __MODULE__
  # The fixed templates every theme must provide. `blog` is no longer
  # required — it moved into the `templates/pages/` folder as a theme page —
  # but it's still loaded *optionally* (see `read_templates!/1`) so themes
  # uploaded before that change keep rendering their old `blog.liquid`.
  @template_names ~w(layout index post page not_found)
  @optional_template_names ~w(blog)

  @typedoc "Cached entry shape stored in :persistent_term."
  @type entry :: %{
          theme: Theme.t(),
          manifest: Manifest.t(),
          css: String.t(),
          templates: %{atom() => Solid.Template.t()},
          page_templates: %{String.t() => Solid.Template.t()},
          page_configs: %{String.t() => Manifest.page_config()},
          asset_base: String.t()
        }

  @doc """
  Return the cached entry for a theme, loading and caching it on cache
  miss. Raises if the theme's source files are missing or fail to parse —
  this is a "should not happen at runtime" situation that means seeding /
  upload validation didn't do its job.
  """
  @spec fetch!(Theme.t()) :: entry()
  def fetch!(%Theme{id: id} = theme) do
    case :persistent_term.get({@cache_key, id}, :miss) do
      :miss -> load_and_cache!(theme)
      entry -> entry
    end
  end

  @doc "Drop the cache entry for a theme. Called after update/delete."
  @spec invalidate(integer()) :: :ok
  def invalidate(theme_id) when is_integer(theme_id) do
    _ = :persistent_term.erase({@cache_key, theme_id})
    :ok
  end

  @doc """
  Read a theme from its source root without consulting the cache.
  Used by the seed task to compute manifest+version before deciding
  whether to upsert, and by `fetch!/1` on cache miss.

  Built-ins are read from `priv/themes/<slug>/` via the filesystem.
  Uploaded themes are read through `Masthead.Storage.read/1`, which routes
  to whichever adapter is configured (local disk or S3). This is the
  cold-cache path — once an entry lands in `:persistent_term`, the
  Renderer never touches storage again.
  """
  @spec read_from_source!(Theme.t()) :: entry()
  def read_from_source!(%Theme{source: "built_in", storage_path: path} = theme) do
    reader = priv_reader(path)
    # Built-ins are on disk, so we can list the pages/ folder directly.
    read_with(theme, reader, asset_base_for(path), priv_page_template_names(path))
  end

  def read_from_source!(
        %Theme{source: "uploaded", storage_path: path, manifest: manifest} = theme
      ) do
    reader = storage_reader(path)
    # Object storage can't be listed, so uploaded themes carry the discovered
    # page-template names in their persisted manifest (written at install time).
    read_with(theme, reader, asset_base_for(path), manifest_page_template_names(manifest))
  end

  @doc """
  Read a theme's source files given a slug under `priv/themes/`. Used by
  the seed task before a `Theme` row exists.
  """
  @spec read_built_in_source!(String.t()) :: %{
          manifest: Manifest.t(),
          css: String.t(),
          templates: %{atom() => Solid.Template.t()},
          page_template_names: [String.t()],
          page_configs: %{String.t() => Manifest.page_config()},
          storage_path: String.t()
        }
  def read_built_in_source!(slug) when is_binary(slug) do
    storage_path = Path.join("themes", slug)
    reader = priv_reader(storage_path)
    page_template_names = priv_page_template_names(storage_path)

    %{
      manifest: read_manifest!(reader),
      templates: read_templates!(reader),
      css: read_css!(reader),
      # The seed task persists these into the DB manifest so the admin UI and
      # the uploaded-theme load path can find the pages without a glob.
      page_template_names: page_template_names,
      page_configs: read_page_configs!(reader, page_template_names),
      storage_path: storage_path
    }
  end

  @doc """
  Return the page-template names a manifest map declares (the list persisted
  by the seed task / package installer). Handles both string-keyed (uploaded)
  and atom-keyed (built-in seed) manifest maps. Defensive against a manifest
  predating the pages feature — returns `[]`.
  """
  @spec manifest_page_template_names(map() | nil) :: [String.t()]
  def manifest_page_template_names(%{} = manifest) do
    case Map.get(manifest, "page_templates", Map.get(manifest, :page_templates, [])) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  def manifest_page_template_names(_), do: []

  # ---- internal ----

  # A reader is `(relative_path :: String.t()) -> {:ok, binary} | {:error, term}`.
  # We pass it around so file-reading code can be source-agnostic — priv
  # disk for built-ins, Storage adapter (local or S3) for uploads.

  defp priv_reader(storage_path) do
    root = Path.join([:code.priv_dir(:masthead) |> to_string(), storage_path])

    fn rel ->
      case File.read(Path.join(root, rel)) do
        {:ok, body} -> {:ok, body}
        {:error, :enoent} -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  defp storage_reader(storage_path) do
    fn rel -> Masthead.Storage.read(Path.join(storage_path, rel)) end
  end

  defp load_and_cache!(theme) do
    entry = read_from_source!(theme)
    :persistent_term.put({@cache_key, theme.id}, entry)
    entry
  end

  defp read_with(%Theme{} = theme, reader, asset_base, page_template_names) do
    %{
      theme: theme,
      manifest: read_manifest!(reader),
      templates: read_templates!(reader),
      page_templates: read_page_templates!(reader, page_template_names),
      page_configs: read_page_configs!(reader, page_template_names),
      css: read_css!(reader),
      asset_base: asset_base
    }
  end

  defp read_manifest!(reader) do
    case reader.("manifest.json") do
      {:ok, body} ->
        case Manifest.parse(body) do
          {:ok, manifest} -> manifest
          {:error, errors} -> raise "invalid manifest: #{Enum.join(errors, ", ")}"
        end

      {:error, reason} ->
        raise "could not read manifest.json: #{inspect(reason)}"
    end
  end

  defp read_templates!(reader) do
    required =
      Map.new(@template_names, fn name ->
        rel = "templates/" <> name <> ".liquid"

        case reader.(rel) do
          {:ok, body} ->
            case Sandbox.parse(body) do
              {:ok, template} -> {String.to_atom(name), template}
              {:error, err} -> raise "could not parse #{rel}: #{inspect(err)}"
            end

          {:error, reason} ->
            raise "missing template #{rel}: #{inspect(reason)}"
        end
      end)

    # Optional fixed templates (e.g. legacy `blog`) are loaded only when
    # present so older uploaded themes keep working without forcing a re-upload.
    Enum.reduce(@optional_template_names, required, fn name, acc ->
      rel = "templates/" <> name <> ".liquid"

      case reader.(rel) do
        {:ok, body} ->
          case Sandbox.parse(body) do
            {:ok, template} -> Map.put(acc, String.to_atom(name), template)
            {:error, err} -> raise "could not parse #{rel}: #{inspect(err)}"
          end

        {:error, _reason} ->
          acc
      end
    end)
  end

  # Page templates live in `templates/pages/<name>.liquid`. Names are
  # user-controlled (a theme author's file names), so they're kept as STRING
  # keys — never `String.to_atom/1`, which would let an uploaded theme exhaust
  # the atom table.
  defp read_page_templates!(reader, names) when is_list(names) do
    Map.new(names, fn name ->
      rel = "templates/pages/" <> name <> ".liquid"

      case reader.(rel) do
        {:ok, body} ->
          case Sandbox.parse(body) do
            {:ok, template} -> {name, template}
            {:error, err} -> raise "could not parse #{rel}: #{inspect(err)}"
          end

        {:error, reason} ->
          raise "missing page template #{rel}: #{inspect(reason)}"
      end
    end)
  end

  # A page template may carry a sidecar `templates/pages/<name>.json` declaring
  # its label/description/page_options. The file is optional (no entry when absent);
  # a present-but-invalid one raises, like a bad manifest/template.
  defp read_page_configs!(reader, names) when is_list(names) do
    names
    |> Enum.reduce(%{}, fn name, acc ->
      rel = "templates/pages/" <> name <> ".json"

      case reader.(rel) do
        {:ok, body} ->
          case Manifest.parse_page_config(body) do
            {:ok, config} -> Map.put(acc, name, config)
            {:error, errors} -> raise "invalid page config #{rel}: #{Enum.join(errors, ", ")}"
          end

        {:error, _reason} ->
          acc
      end
    end)
  end

  # List the `<name>` of every `templates/pages/<name>.liquid` for a built-in
  # theme (priv disk). Returns [] when the folder is absent.
  defp priv_page_template_names(storage_path) do
    dir =
      Path.join([:code.priv_dir(:masthead) |> to_string(), storage_path, "templates", "pages"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".liquid"))
        |> Enum.map(&Path.rootname(&1, ".liquid"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp read_css!(reader) do
    case reader.("theme.css") do
      {:ok, body} -> body
      {:error, reason} -> raise "missing theme.css: #{inspect(reason)}"
    end
  end

  defp asset_base_for(storage_path), do: "/uploads/" <> storage_path <> "/assets"
end

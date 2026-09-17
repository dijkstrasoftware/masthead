defmodule Masthead.Themes.Manifest do
  @moduledoc """
  Parses and validates a theme's `manifest.json`.

  A manifest declares the theme's identity (name, slug, version, author,
  description) and the customisable tokens it exposes to site owners.

      {
        "name": "Studio",
        "slug": "studio",
        "version": "1.0.0",
        "author": "Masthead",
        "description": "Editorial / blue accent.",
        "tokens": [
          {"key": "accent", "label": "Accent color", "type": "color", "default": "#2563eb"}
        ]
      }

  Token types control how the per-site customization UI renders the input:

    * `color`  — `<input type="color">`, value is a `#rrggbb` string
    * `string` — free-text input (e.g. font stack)
    * `length` — CSS length string (`880px`, `60ch`, `4rem`)
    * `number` — numeric input, stored as a string for CSS embedding
    * `file`   — a picker over the site's existing uploads; the stored
      value is the chosen upload's **id**, resolved to a public URL at
      render time (see `Masthead.Themes.Renderer`). Useful for favicons,
      header images, logos, etc. Default should be `""` (no file).
    * `select` — a `<select>` over a fixed `options` list (required);
      value is the chosen option string. Use for layout switches like
      contained vs. full-width.
    * `boolean` — a checkbox. The value reaches templates as a real
      boolean (default is a JSON `true`/`false`), so themes can branch with
      `{% if theme.tokens.show_search %}`. Use for on/off feature toggles.
    * `text` — a textarea; `url` — a URL input. Both are plain strings.
    * `object` — a group of scalar subfields under one key, declared in a
      nested `fields` list. Reaches templates as a map
      (`{{ theme.tokens.hero.title }}`).
    * `list` — a repeatable group of scalar subfields (nested `fields`, plus
      an optional `item_label` for the "Add …" button and a `default` array of
      seed items). Reaches templates as an array of maps, so themes can
      `{% for link in theme.tokens.nav_links %}`.

  Tokens, page options and post options share one type set: anything a page
  option can declare, a token can declare too. The only difference is what the
  value is *for* — a scalar token also becomes a CSS custom property
  (`--accent`), while `object`/`list` tokens are template-only (they have no CSS
  representation, so they're skipped when the `:root` block is composed).

  ## Render version

  `render_version` pins the theme to a frozen renderer (see
  `Masthead.Themes.Renderer`). A manifest that omits it is a `"beta"` theme —
  the original render contract, where page options are declared under the
  legacy `"metadata"` key and reach templates as `page.metadata`. A `"v1"` theme
  declares `page_options`/`post_options` and reads them under those names.

  ## Structured data

  Masthead injects Schema.org JSON-LD into every canonical page's `<head>`
  (see `Masthead.Themes.StructuredData`). A theme extends it by emitting its
  own extra `<script type="application/ld+json">` in `layout.liquid`, or
  replaces it by setting `"structured_data": false` and emitting its own.
  """

  # A "field" — a customisation token, a global page option, a post option, or
  # a per-page option on a theme page — is conceptually the same thing: a
  # `key`/`label`/`type`/`default` (+ optional `options`/`description`/
  # `category`) declaration. Only where its value is stored and used differs
  # (a token feeds a CSS variable; a page option feeds a page's template
  # context). So they share one type set and one validator.
  @scalar_field_types ~w(color string length number file select boolean text url)
  # Container fields nest a `fields` list (one level only — their children must
  # be scalar). `object` holds one group; `list` holds a repeatable group.
  @container_field_types ~w(object list)
  @field_types @scalar_field_types ++ @container_field_types

  @slug_re ~r/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/
  @token_key_re ~r/^[a-z][a-z0-9_]*$/

  @render_versions ~w(beta v1)
  @default_render_version "beta"

  @enforce_keys [:name, :slug, :version, :tokens]
  defstruct [
    :name,
    :slug,
    :version,
    :author,
    :description,
    render_version: @default_render_version,
    structured_data: true,
    tokens: [],
    page_options: [],
    post_options: []
  ]

  # A token *is* a field — same declaration, same types, same validator.
  @type token :: option_field()

  @type option_field :: %{
          key: String.t(),
          label: String.t(),
          type: String.t(),
          default: term(),
          description: String.t() | nil,
          options: [String.t()] | nil,
          category: String.t() | nil,
          # For `object`/`list` container fields: the nested (scalar) fields and,
          # for lists, the singular item label. nil for scalar fields.
          fields: [option_field()] | nil,
          item_label: String.t() | nil
        }

  @typedoc """
  A page's sidecar config (`templates/pages/<name>.json`): an optional label and
  description plus that page's own `page_options` field schema. No version.
  """
  @type page_config :: %{
          label: String.t() | nil,
          description: String.t() | nil,
          page_options: [option_field()]
        }

  @type t :: %__MODULE__{
          name: String.t(),
          slug: String.t(),
          version: String.t(),
          author: String.t() | nil,
          description: String.t() | nil,
          render_version: String.t(),
          tokens: [token()],
          page_options: [option_field()],
          post_options: [option_field()],
          structured_data: boolean()
        }

  @doc """
  Parse a manifest from a JSON-encoded binary. Returns
  `{:ok, %Manifest{}}` or `{:error, [reason, ...]}` with all validation
  failures collected.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> from_map(map)
      {:ok, _} -> {:error, ["manifest must be a JSON object"]}
      {:error, %Jason.DecodeError{} = e} -> {:error, ["invalid JSON: " <> Exception.message(e)]}
    end
  end

  @doc """
  Build a manifest struct from an already-decoded map (used by tests and by
  the seed task that reads on-disk JSON via `Jason.decode!/1`).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) do
    errors =
      []
      |> require_string(map, "name", 1, 100)
      |> require_slug(map, "slug")
      |> require_string(map, "version", 1, 32)
      |> optional_string(map, "author", 0, 100)
      |> optional_string(map, "description", 0, 500)
      |> validate_render_version(map)
      |> validate_structured_data(map)
      |> validate_field_list(map, "tokens")
      |> validate_page_options(map)
      |> validate_field_list(map, "post_options")
      |> validate_post_options_version(map)

    case errors do
      [] ->
        manifest = %__MODULE__{
          name: map["name"],
          slug: map["slug"],
          version: map["version"],
          author: map["author"],
          description: map["description"],
          render_version: Map.get(map, "render_version") || @default_render_version,
          structured_data: Map.get(map, "structured_data", true),
          tokens: normalize_fields(Map.get(map, "tokens", [])),
          page_options: normalize_fields(raw_page_options(map)),
          post_options: normalize_fields(Map.get(map, "post_options", []))
        }

        {:ok, manifest}

      errs ->
        {:error, Enum.reverse(errs)}
    end
  end

  @doc """
  Return the merge of manifest token defaults with a map of per-site
  override values.

  Tokens use the same field types (and the same coercion) as page options, so
  an `object` token merges against its nested defaults and a `list` token comes
  back as a list of merged maps. Two things differ from `merge_fields/2`:

    * Unknown override keys are **dropped** — a token is inert without a
      matching declaration, whereas an option is preserved across theme
      switches so the user doesn't lose page content.
    * A blank scalar override falls back to the manifest default (the settings
      form stores "" for "not overridden").
  """
  @spec effective_tokens(t(), map()) :: %{String.t() => term()}
  def effective_tokens(%__MODULE__{tokens: tokens}, overrides) when is_map(overrides) do
    Enum.reduce(tokens, %{}, fn field, acc ->
      value =
        case Map.get(overrides, field.key) do
          v when v in [nil, ""] -> default_value(field)
          v -> merge_value(field, v)
        end

      Map.put(acc, field.key, value)
    end)
  end

  @doc """
  Merge an option field list's defaults with a map of overrides, coercing
  declared fields to their type and passing unknown keys through verbatim. This
  is the shared primitive behind page options, post options and a theme page's
  per-page options (whose fields come from its sidecar config).

  Differences from `effective_tokens/2`:

    * Unknown override keys are **preserved** — the page may have been
      authored under a different theme. Tokens disappear silently because
      they're inert without a matching CSS variable; options are meant to
      survive theme switches so the user doesn't lose data.
    * Values are coerced to the declared type at the boundary so the
      template sees a typed value (boolean true vs. "true", etc).
  """
  @spec merge_fields([option_field()], map()) :: %{String.t() => term()}
  def merge_fields(fields, overrides) when is_list(fields) and is_map(overrides) do
    defaults =
      Enum.reduce(fields, %{}, fn field, acc -> Map.put(acc, field.key, default_value(field)) end)

    field_index = Map.new(fields, fn f -> {f.key, f} end)

    Enum.reduce(overrides, defaults, fn {k, v}, acc ->
      case Map.get(field_index, k) do
        # Unknown override key — preserved verbatim (theme-switch resilience).
        nil -> Map.put(acc, k, v)
        field -> Map.put(acc, k, merge_value(field, v))
      end
    end)
  end

  # The effective value for a field with no override: scalars coerce their
  # declared default; an object derives its value from nested defaults; a list
  # defaults to empty.
  defp default_value(%{type: "object", fields: nested}) when is_list(nested),
    do: merge_fields(nested, %{})

  # A list with declared default items renders them (each merged against the
  # nested schema) when the page provides no override; otherwise it's empty.
  defp default_value(%{type: "list", fields: nested, default: items})
       when is_list(nested) and is_list(items) and items != [],
       do: Enum.map(items, fn item -> merge_fields(nested, item_map(item)) end)

  defp default_value(%{type: "list"}), do: []
  defp default_value(%{type: type, default: default}), do: coerce_value(type, default)

  # The effective value for a field given an override.
  defp merge_value(%{type: "object", fields: nested}, v) when is_list(nested) and is_map(v),
    do: merge_fields(nested, v)

  defp merge_value(%{type: "object", fields: nested}, _v) when is_list(nested),
    do: merge_fields(nested, %{})

  defp merge_value(%{type: "list", fields: nested}, items)
       when is_list(nested) and is_list(items),
       do: Enum.map(items, fn item -> merge_fields(nested, item_map(item)) end)

  defp merge_value(%{type: "list"}, _v), do: []
  defp merge_value(%{type: type}, v), do: coerce_value(type, v)

  defp item_map(item) when is_map(item), do: item
  defp item_map(_), do: %{}

  defp coerce_value("boolean", v) when is_boolean(v), do: v
  defp coerce_value("boolean", v) when v in ["true", "on", "1", 1], do: true
  defp coerce_value("boolean", _), do: false
  defp coerce_value("number", v) when is_number(v), do: v

  defp coerce_value("number", v) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> if n == trunc(n), do: trunc(n), else: n
      _ -> v
    end
  end

  defp coerce_value(_type, v), do: v

  # ---- internal validators ----

  defp require_string(errors, map, key, min, max) do
    case Map.get(map, key) do
      v when is_binary(v) ->
        len = String.length(v)

        cond do
          len < min -> ["#{key}: must be at least #{min} chars" | errors]
          len > max -> ["#{key}: must be at most #{max} chars" | errors]
          true -> errors
        end

      nil ->
        ["#{key}: is required" | errors]

      _ ->
        ["#{key}: must be a string" | errors]
    end
  end

  defp optional_string(errors, map, key, _min, max) do
    case Map.get(map, key) do
      nil ->
        errors

      v when is_binary(v) ->
        if String.length(v) > max do
          ["#{key}: must be at most #{max} chars" | errors]
        else
          errors
        end

      _ ->
        ["#{key}: must be a string" | errors]
    end
  end

  defp require_slug(errors, map, key) do
    case Map.get(map, key) do
      v when is_binary(v) ->
        if Regex.match?(@slug_re, v) do
          errors
        else
          ["#{key}: must be 1-32 chars, lowercase letters/digits/hyphens" | errors]
        end

      nil ->
        ["#{key}: is required" | errors]

      _ ->
        ["#{key}: must be a string" | errors]
    end
  end

  defp validate_render_version(errors, map) do
    case Map.get(map, "render_version") do
      nil -> errors
      v when v in @render_versions -> errors
      _ -> ["render_version: must be one of #{Enum.join(@render_versions, ", ")}" | errors]
    end
  end

  defp validate_structured_data(errors, map) do
    case Map.get(map, "structured_data", true) do
      value when is_boolean(value) -> errors
      _ -> ["structured_data: must be true or false" | errors]
    end
  end

  defp validate_post_options_version(errors, map) do
    beta? = (Map.get(map, "render_version") || @default_render_version) == @default_render_version

    if beta? and Map.get(map, "post_options", []) != [] do
      ["post_options: requires render_version v1" | errors]
    else
      errors
    end
  end

  defp validate_page_options(errors, map) do
    validate_field_list(errors, map, page_options_key(map))
  end

  defp validate_field_list(errors, map, key) do
    case Map.get(map, key, []) do
      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {field, idx}, acc ->
          validate_field(acc, field, "#{key}[#{idx}]")
        end)

      _ ->
        ["#{key}: must be a list" | errors]
    end
  end

  defp page_options_key(map) do
    if Map.has_key?(map, "page_options"), do: "page_options", else: "metadata"
  end

  defp raw_page_options(map), do: Map.get(map, page_options_key(map), [])

  # The one validator shared by tokens, page/post options and page-config
  # fields.
  # `allow_container?` is true at the top level and false for nested fields, so
  # `object`/`list` can only appear one level deep.
  defp validate_field(errors, field, prefix, allow_container? \\ true)

  defp validate_field(errors, field, prefix, allow_container?) when is_map(field) do
    errors =
      case Map.get(field, "key") do
        k when is_binary(k) ->
          if Regex.match?(@token_key_re, k) do
            errors
          else
            ["#{prefix}.key: must match #{inspect(@token_key_re.source)}" | errors]
          end

        _ ->
          ["#{prefix}.key: is required and must be a string" | errors]
      end

    errors =
      case Map.get(field, "label") do
        l when is_binary(l) and l != "" -> errors
        _ -> ["#{prefix}.label: is required and must be a non-empty string" | errors]
      end

    type = Map.get(field, "type")
    valid_types = if allow_container?, do: @field_types, else: @scalar_field_types

    errors =
      cond do
        type not in valid_types ->
          ["#{prefix}.type: must be one of #{Enum.join(valid_types, ", ")}" | errors]

        type == "select" and
            (not is_list(Map.get(field, "options")) or Map.get(field, "options") == []) ->
          ["#{prefix}.options: select fields require a non-empty options list" | errors]

        true ->
          errors
      end

    cond do
      type in @container_field_types ->
        validate_container_fields(errors, field, prefix)

      # A scalar's default is required; its shape is coerced at read time, so any
      # JSON-serializable value is accepted here.
      Map.has_key?(field, "default") ->
        errors

      true ->
        ["#{prefix}.default: is required" | errors]
    end
  end

  defp validate_field(errors, _, prefix, _allow_container?),
    do: ["#{prefix}: must be an object" | errors]

  # An object/list field nests a non-empty `fields` list of scalar fields.
  defp validate_container_fields(errors, field, prefix) do
    case Map.get(field, "fields") do
      [_ | _] = fields ->
        fields
        |> Enum.with_index()
        |> Enum.reduce(errors, fn {f, i}, acc ->
          validate_field(acc, f, "#{prefix}.fields[#{i}]", false)
        end)

      _ ->
        [
          "#{prefix}.fields: #{Map.get(field, "type")} fields require a non-empty fields list"
          | errors
        ]
    end
  end

  # One normalizer for tokens, options and page-config fields. `category` is an
  # optional grouping label: fields with one render in an accordion in the
  # settings UI (uncategorized → "General").
  defp normalize_fields(list) when is_list(list) do
    Enum.map(list, fn field ->
      %{
        key: field["key"],
        label: field["label"],
        type: field["type"],
        default: field["default"],
        description: field["description"],
        options: field["options"],
        category: field["category"],
        item_label: field["item_label"],
        fields: normalize_nested(field["fields"])
      }
    end)
  end

  defp normalize_nested(list) when is_list(list), do: normalize_fields(list)
  defp normalize_nested(_), do: nil

  # ---- page config (templates/pages/<name>.json) ----

  @doc """
  Parse a theme page's sidecar config from a JSON-encoded binary. A page config
  is `{"label"?, "description"?, "page_options"?: [field, ...]}` — no version.
  The fields reuse the same validation as manifest tokens and options; a beta
  theme's config declares them under the legacy `"metadata"` key.
  """
  @spec parse_page_config(String.t()) :: {:ok, page_config()} | {:error, [String.t()]}
  def parse_page_config(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> from_page_map(map)
      {:ok, _} -> {:error, ["page config must be a JSON object"]}
      {:error, %Jason.DecodeError{} = e} -> {:error, ["invalid JSON: " <> Exception.message(e)]}
    end
  end

  @doc "Build a page config from an already-decoded map."
  @spec from_page_map(map()) :: {:ok, page_config()} | {:error, [String.t()]}
  def from_page_map(map) when is_map(map) do
    errors =
      []
      |> optional_string(map, "label", 0, 100)
      |> optional_string(map, "description", 0, 500)
      |> validate_page_options(map)

    case errors do
      [] ->
        {:ok,
         %{
           label: map["label"],
           description: map["description"],
           page_options: normalize_fields(raw_page_options(map))
         }}

      errs ->
        {:error, Enum.reverse(errs)}
    end
  end

  @doc """
  Serialize a page config to a string-keyed map for DB persistence (mirrors the
  field shape `Package.manifest_to_map/1` uses for tokens and options).
  """
  @spec page_config_to_map(page_config()) :: map()
  def page_config_to_map(%{} = config) do
    %{
      "label" => config[:label],
      "description" => config[:description],
      "page_options" => Enum.map(config[:page_options] || [], &field_to_map/1)
    }
  end

  @doc """
  Read one option field list out of a **persisted** manifest (or page config)
  map — the jsonb blob on `themes.manifest`, which the admin UI reads without
  going through `from_map/1`. The list comes back as declared; callers that
  render it normalize with `MastheadWeb.AdminLive.SettingsFields.normalize_fields/1`.

  Two key spellings are in the wild — string-keyed (uploaded themes, written by
  `Package`) and atom-keyed (built-ins, written by `Seed` via
  `Map.from_struct/1`) — plus the legacy `"metadata"` key that beta themes use
  for their page options.
  """
  @spec option_fields(map() | nil, :page_options | :post_options) :: list()
  def option_fields(%{} = map, :page_options) do
    get_either(map, :page_options) || get_either(map, :metadata) || []
  end

  def option_fields(%{} = map, :post_options) do
    get_either(map, :post_options) || []
  end

  def option_fields(_map, _kind), do: []

  defp get_either(map, key), do: Map.get(map, to_string(key), Map.get(map, key))

  @doc "Serialize one normalized field to a string-keyed map."
  @spec field_to_map(option_field()) :: map()
  def field_to_map(f) do
    nested = Map.get(f, :fields)

    %{
      "key" => f.key,
      "label" => f.label,
      "type" => f.type,
      "default" => f.default,
      "description" => f.description,
      "options" => f.options,
      "category" => f.category,
      "item_label" => Map.get(f, :item_label),
      "fields" => if(is_list(nested), do: Enum.map(nested, &field_to_map/1))
    }
  end
end

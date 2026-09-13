defmodule MastheadWeb.AdminLive.SettingsFields do
  @moduledoc """
  The shared editor for schema-declared settings fields.

  A theme declares its field lists in its manifest — `tokens` (per-site),
  `page_options` and `post_options` (per-page / per-post), plus a theme page's
  sidecar config — and they all use the same field types
  (`Masthead.Themes.Manifest`). This module is the one editor for all of them:
  the HEEx components that render a field list, plus the draft-value helpers
  that keep nested `object`/`list` values in shape across form round-trips.

  Callers differ only in where the values live and what the inputs are named:

    * `AdminLive.SiteTheme` — `site[theme_tokens][...]`, values in `@tokens`
    * `AdminLive.PageForm`  — `page[page_options][...]`, values in `@draft["page_options"]`
    * `AdminLive.PostForm`  — `post[post_options][...]`, values in `@draft["post_options"]`

  ## Why a draft map, and not just form params

  A `list` field is a repeatable group whose items need identity — remove the
  second of three items, or drag it to the top, and the surviving items must
  keep their values. Form params alone can't express that (they're keyed by
  position), so each item carries an ephemeral `_id` while it's being edited:

    * `hydrate/2` gives stored items fresh `_id`s (and seeds a list's declared
      default items when there's no stored value yet),
    * `merge_params/3` folds submitted params back into the draft *by `_id`*,
      with the draft — not the params — authoritative for order and identity,
    * `canonicalize/2` strips the `_id`s and empty subvalues before persisting.

  ## Events the host LiveView must handle

  The components emit `toggle_container`, `add_list_item`,
  `remove_list_item`, `reorder_list` and `clear_meta`, and open the file picker
  named by `picker_target` with a `meta`/`sub`/`item` context that comes back as
  `{:file_picked, upload, ctx}`.
  """
  use Phoenix.Component

  alias Masthead.Uploads

  # ---- field schema ----

  @doc """
  Normalize a manifest field list (string- or atom-keyed, as it comes off the
  jsonb manifest) into `%{key, label, type, default, description, options,
  category, item_label, fields}` maps. Nested container fields are normalized
  recursively.
  """
  def normalize_fields(list) when is_list(list) do
    Enum.map(list, fn f ->
      %{
        key: f["key"] || f[:key],
        label: f["label"] || f[:label],
        type: f["type"] || f[:type],
        default: f["default"] || f[:default],
        description: f["description"] || f[:description],
        options: f["options"] || f[:options] || [],
        category: f["category"] || f[:category],
        item_label: f["item_label"] || f[:item_label],
        fields: normalize_fields(f["fields"] || f[:fields])
      }
    end)
  end

  def normalize_fields(_), do: []

  # ---- draft values ----

  @doc """
  Prepare stored values for editing: give each list item a fresh `_id` so the
  editor can track it across add/remove/reorder, seed a list that has no stored
  value with the schema's default items, and ensure object keys hold a map.
  """
  def hydrate(values, fields) when is_map(values) do
    Enum.reduce(fields, values, fn field, acc ->
      key = field.key

      case field.type do
        "list" ->
          case Map.get(acc, key) do
            list when is_list(list) ->
              Map.put(acc, key, Enum.map(list, &Map.put(ensure_map(&1), "_id", new_id())))

            _ ->
              Map.put(acc, key, default_items(field))
          end

        "object" ->
          if is_map(Map.get(acc, key)), do: acc, else: Map.put(acc, key, %{})

        _ ->
          acc
      end
    end)
  end

  def hydrate(_values, _fields), do: %{}

  @doc """
  Strip the ephemeral `_id` and empty subvalues before persisting. Empty list
  *items* are kept (their count and order are meaningful); empty subvalues are
  dropped so they don't pin an override the renderer would otherwise fill from
  the field's default.
  """
  def canonicalize(values, fields) when is_map(values) do
    Enum.reduce(fields, values, fn field, acc ->
      key = field.key

      case {field.type, Map.get(acc, key)} do
        {"object", %{} = obj} ->
          Map.put(acc, key, strip_empty(obj))

        {"list", list} when is_list(list) ->
          Map.put(acc, key, Enum.map(list, &(&1 |> Map.delete("_id") |> strip_empty())))

        _ ->
          acc
      end
    end)
  end

  def canonicalize(_values, _fields), do: %{}

  @doc """
  Fold submitted form params into the draft values, schema-aware: scalars
  overwrite, an object writes only the subkeys present in the params (so an
  untouched hidden input isn't cleared), and a list merges item-by-item keyed on
  `_id` — the draft stays authoritative for order, length and identity, so a
  stale or removed item can't bleed its values into a surviving one.
  """
  def merge_params(values, params, fields) when is_map(values) and is_map(params) do
    Enum.reduce(fields, values, fn field, acc ->
      key = field.key

      case field.type do
        "object" ->
          Map.put(
            acc,
            key,
            merge_object(Map.get(acc, key) || %{}, Map.get(params, key) || %{}, field.fields)
          )

        "list" ->
          Map.put(
            acc,
            key,
            merge_list(Map.get(acc, key) || [], Map.get(params, key) || %{}, field.fields)
          )

        _ ->
          case Map.fetch(params, key) do
            {:ok, v} -> Map.put(acc, key, v)
            :error -> acc
          end
      end
    end)
  end

  def merge_params(values, _params, _fields) when is_map(values), do: values

  @doc """
  The options sub-map a wizard draft keeps under `draft_key` (`"page_options"`,
  `"post_options"`), always a map.
  """
  def draft_values(draft, draft_key), do: ensure_map(Map.get(draft, draft_key))

  @doc "Apply `fun` to the draft's options sub-map."
  def update_draft(draft, draft_key, fun),
    do: Map.put(draft, draft_key, fun.(draft_values(draft, draft_key)))

  @doc """
  Fold submitted form params into a wizard draft: everything but the options
  sub-map shallow-merges (title/slug/format/…), while the sub-map merges against
  the field schema so nested objects/lists keep their canonical shape and item
  identity.
  """
  def merge_draft_params(draft, draft_key, params, fields) do
    {option_params, rest} = Map.pop(params, draft_key)
    draft = Map.merge(draft, rest)

    if is_map(option_params) do
      update_draft(draft, draft_key, &merge_params(&1, option_params, fields))
    else
      draft
    end
  end

  @doc "Set (or, when the value is blank, clear) one top-level field."
  def put_value(values, key, "" = _value), do: Map.delete(values, key)
  def put_value(values, key, value), do: Map.put(values, key, value)

  @doc "Set (or clear) one subfield of an `object` field."
  def put_object_value(values, key, sub, value) do
    obj = ensure_map(Map.get(values, key))
    obj = if value == "", do: Map.delete(obj, sub), else: Map.put(obj, sub, value)
    Map.put(values, key, obj)
  end

  @doc "Set (or clear) one subfield of a single `list` item, addressed by `_id`."
  def put_list_item_value(values, key, id, sub, value) do
    update_list(values, key, fn list ->
      Enum.map(list, fn item ->
        cond do
          to_string(item["_id"]) != to_string(id) -> item
          value == "" -> Map.delete(item, sub)
          true -> Map.put(item, sub, value)
        end
      end)
    end)
  end

  @doc "Append a blank item (all subfields empty) to a `list` field."
  def add_item(values, fields, key) do
    subfields = list_subfields(fields, key)
    update_list(values, key, &(&1 ++ [blank_item(subfields)]))
  end

  @doc """
  The open/closed state of every settings accordion, in one value the host
  keeps across re-renders (a `phx-change` would reset native `<details>`).
  `group` is the expanded category and `open` the expanded list item — both
  open one at a time, collapsed by default. `closed` holds the `object` fields
  the user has collapsed: an object is a group of its own, so it starts open
  and never closes anything else.
  """
  def containers, do: %{group: nil, open: nil, closed: MapSet.new()}

  @doc "Toggle one container. `kind` picks which of the three rules applies."
  def toggle_container(state, handle, "group"),
    do: %{state | group: toggle_slot(state.group, handle)}

  def toggle_container(state, handle, "standalone"),
    do: %{state | closed: toggle_member(state.closed, handle)}

  def toggle_container(state, handle, _item), do: %{state | open: toggle_slot(state.open, handle)}

  @doc "Expand the last item of `key` — the one `add_item/3` just appended."
  def open_last_item(state, values, key), do: %{state | open: last_item_handle(values, key)}

  defp toggle_slot(open, handle), do: if(open == handle, do: nil, else: handle)

  defp toggle_member(set, handle) do
    case MapSet.member?(set, handle) do
      true -> MapSet.delete(set, handle)
      false -> MapSet.put(set, handle)
    end
  end

  defp last_item_handle(values, key) do
    case List.last(items_at(values, key)) do
      nil -> nil
      item -> item_handle(key, item)
    end
  end

  @doc "Drop the `list` item with the given `_id`."
  def remove_item(values, key, id) do
    update_list(values, key, fn list ->
      Enum.reject(list, &(to_string(&1["_id"]) == to_string(id)))
    end)
  end

  @doc """
  Reorder a `list` field to the given `_id` order (as reported by the drag
  hook). Ids the client didn't mention keep their relative order at the end, so
  a stale reorder event can never drop an item.
  """
  def reorder(values, key, ids) do
    update_list(values, key, fn list ->
      by_id = Map.new(list, &{to_string(&1["_id"]), &1})
      ordered = Enum.flat_map(ids, fn id -> List.wrap(Map.get(by_id, to_string(id))) end)
      seen = MapSet.new(ids, &to_string/1)
      ordered ++ Enum.reject(list, &MapSet.member?(seen, to_string(&1["_id"])))
    end)
  end

  @doc "Apply `fun` to a `list` field's items (treating a missing value as `[]`)."
  def update_list(values, key, fun) do
    list =
      case Map.get(values, key) do
        l when is_list(l) -> l
        _ -> []
      end

    Map.put(values, key, fun.(list))
  end

  defp list_subfields(fields, key) do
    case Enum.find(fields, &(&1.key == key and &1.type == "list")) do
      %{fields: sub} when is_list(sub) -> sub
      _ -> []
    end
  end

  defp blank_item(subfields) do
    Enum.reduce(subfields, %{"_id" => new_id()}, fn sf, acc -> Map.put(acc, sf.key, "") end)
  end

  # A list field's default items (from its `default` array), each filled against
  # the nested field defaults and given a tracking `_id`.
  defp default_items(%{default: items, fields: subfields}) when is_list(items) do
    subs = subfields || []

    Enum.map(items, fn item ->
      base = Enum.reduce(subs, %{}, fn sf, acc -> Map.put(acc, sf.key, sf.default) end)
      base |> Map.merge(ensure_map(item)) |> Map.put("_id", new_id())
    end)
  end

  defp default_items(_), do: []

  # Write only the subkeys present in params, preserving `_id` and any untouched
  # keys (e.g. a file hidden input not in this change).
  defp merge_object(obj, params, subfields) when is_map(params) do
    Enum.reduce(subfields || [], obj, fn sf, acc ->
      case Map.fetch(params, sf.key) do
        {:ok, v} -> Map.put(acc, sf.key, v)
        :error -> acc
      end
    end)
  end

  defp merge_object(obj, _params, _subfields), do: obj

  defp merge_list(list, params, subfields) when is_list(list) and is_map(params) do
    Enum.map(list, fn item ->
      case Map.get(params, to_string(item["_id"])) do
        %{} = item_params -> merge_object(item, item_params, subfields)
        _ -> item
      end
    end)
  end

  defp merge_list(list, _params, _subfields) when is_list(list), do: list
  defp merge_list(_list, _params, _subfields), do: []

  defp strip_empty(map), do: map |> Enum.reject(fn {_k, v} -> v in [nil, ""] end) |> Map.new()

  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}

  defp new_id, do: System.unique_integer([:positive, :monotonic])

  # ---- components ----

  @doc """
  Render a field list. Fields group into collapsible sections when any of them
  declares a `category`; otherwise they render flat. `containers` is the host's
  accordion state (see `containers/0`).

  `prefix` is the form-name prefix the values are cast from (`"page[page_options]"`,
  `"site[theme_tokens]"`), and `picker_target` is the DOM id of the host's
  `FilePicker` live component.
  """
  attr :fields, :list, required: true
  attr :values, :map, required: true
  attr :prefix, :string, required: true
  attr :picker_target, :string, required: true
  attr :site_uploads, :list, default: []
  attr :containers, :map, required: true

  def settings_fields(assigns) do
    ~H"""
    <%= if Enum.any?(@fields, &categorized?/1) do %>
      <div class="token-groups">
        <details
          :for={{category, fields} <- group_fields(@fields)}
          class="token-group"
          open={@containers.group == category}
        >
          <summary
            class="token-group-summary"
            phx-click="toggle_container"
            phx-value-handle={category}
            phx-value-kind="group"
          >
            {category}
          </summary>
          <div class="settings-fields">
            <.setting_input
              :for={f <- fields}
              field={f}
              values={@values}
              prefix={@prefix}
              picker_target={@picker_target}
              site_uploads={@site_uploads}
              containers={@containers}
            />
          </div>
        </details>
      </div>
    <% else %>
      <div class="settings-fields">
        <.setting_input
          :for={f <- @fields}
          field={f}
          values={@values}
          prefix={@prefix}
          picker_target={@picker_target}
          site_uploads={@site_uploads}
          containers={@containers}
        />
      </div>
    <% end %>
    """
  end

  @doc """
  A wizard step's settings form: the shared editor wrapped in the `<form>` both
  the page and post wizards submit it from. The caller supplies the surrounding
  stepper, heading and footer buttons, and drives its own submit event.
  """
  attr :id, :string, required: true
  attr :submit, :string, required: true
  attr :fields, :list, required: true
  attr :values, :map, required: true
  attr :prefix, :string, required: true
  attr :picker_target, :string, required: true
  attr :site_uploads, :list, default: []
  attr :containers, :map, required: true

  def settings_form(assigns) do
    ~H"""
    <form id={@id} phx-submit={@submit} phx-change="validate" class="form">
      <.settings_fields
        fields={@fields}
        values={@values}
        prefix={@prefix}
        picker_target={@picker_target}
        site_uploads={@site_uploads}
        containers={@containers}
      />
    </form>
    """
  end

  defp categorized?(%{category: c}) when is_binary(c), do: String.trim(c) != ""
  defp categorized?(_), do: false

  defp category(f), do: if(categorized?(f), do: String.trim(f.category), else: "General")

  @doc """
  Group fields by category, preserving first-seen order of both the categories
  and the fields within each. Fields with no category fall under "General".
  """
  def group_fields(fields) do
    Enum.reduce(fields, [], fn f, acc ->
      cat = category(f)

      case List.keyfind(acc, cat, 0) do
        nil -> acc ++ [{cat, [f]}]
        {^cat, list} -> List.keyreplace(acc, cat, 0, {cat, list ++ [f]})
      end
    end)
  end

  # Dispatch a top-level field: container types render their own structure,
  # everything else is a scalar input.
  attr :field, :map, required: true
  attr :values, :map, required: true
  attr :prefix, :string, required: true
  attr :picker_target, :string, required: true
  attr :site_uploads, :list, default: []
  attr :containers, :map, required: true

  defp setting_input(%{field: %{type: "object"}} = assigns), do: object_field(assigns)
  defp setting_input(%{field: %{type: "list"}} = assigns), do: list_field(assigns)

  defp setting_input(assigns) do
    assigns =
      assign(assigns,
        name: assigns.prefix <> "[" <> assigns.field.key <> "]",
        value: value_at(assigns.values, assigns.field.key),
        picker_ctx: %{"meta" => assigns.field.key}
      )

    scalar_field(assigns)
  end

  # An `object` field: a group of scalar subfields under one key, collapsed
  # into the accordion the host tracks as `containers`.
  defp object_field(assigns) do
    assigns = assign(assigns, :obj, ensure_map(Map.get(assigns.values, assigns.field.key)))

    ~H"""
    <details
      class="settings-group-field"
      open={standalone_open?(@containers, @field.key)}
    >
      <summary
        class="settings-group-summary"
        phx-click="toggle_container"
        phx-value-handle={@field.key}
        phx-value-kind="standalone"
      >
        {@field.label}
      </summary>
      <small :if={@field.description} class="muted">{@field.description}</small>
      <div class="settings-fields">
        <.scalar_field
          :for={sf <- @field.fields}
          field={sf}
          name={@prefix <> "[" <> @field.key <> "][" <> sf.key <> "]"}
          value={sub_value(@obj, sf.key)}
          picker_ctx={%{"meta" => @field.key, "sub" => sf.key}}
          picker_target={@picker_target}
          site_uploads={@site_uploads}
        />
      </div>
    </details>
    """
  end

  # A `list` field: a repeatable group with add / remove / drag-reorder. Items
  # collapse into the same one-at-a-time accordion as `object` fields, so a long
  # list reads as a sortable overview rather than a wall of inputs.
  defp list_field(assigns) do
    assigns = assign(assigns, :items, items_at(assigns.values, assigns.field.key))

    ~H"""
    <fieldset class="settings-group-field">
      <legend>{@field.label}</legend>
      <small :if={@field.description} class="muted">{@field.description}</small>

      <ul
        id={"meta-list-" <> @field.key}
        phx-hook="SortableList"
        data-sortable-event="reorder_list"
        data-sortable-key={@field.key}
        class="settings-list"
      >
        <li
          :for={{item, index} <- Enum.with_index(@items)}
          id={@field.key <> "-" <> to_string(item["_id"])}
          draggable="true"
          data-sortable-id={item["_id"]}
          class="settings-list-item"
        >
          <span class="settings-list-drag" aria-hidden="true"><.drag_handle_icon /></span>
          <details
            class="settings-list-details"
            open={item_open?(@containers, item_handle(@field.key, item))}
          >
            <summary
              class="settings-list-summary"
              phx-click="toggle_container"
              phx-value-handle={item_handle(@field.key, item)}
            >
              <span class="settings-list-title">{item_title(item, @field, index)}</span>
              <button
                type="button"
                class="settings-list-remove"
                phx-click="remove_list_item"
                phx-value-key={@field.key}
                phx-value-id={item["_id"]}
                title={"Remove " <> item_title(item, @field, index)}
                aria-label={"Remove " <> item_title(item, @field, index)}
              >
                <.trash_icon />
              </button>
            </summary>
            <div class="settings-fields settings-list-fields">
              <.scalar_field
                :for={sf <- @field.fields}
                field={sf}
                name={@prefix <> "[" <> @field.key <> "][" <> to_string(item["_id"]) <> "][" <> sf.key <> "]"}
                value={sub_value(item, sf.key)}
                picker_ctx={
                  %{"meta" => @field.key, "item" => to_string(item["_id"]), "sub" => sf.key}
                }
                picker_target={@picker_target}
                site_uploads={@site_uploads}
              />
            </div>
          </details>
        </li>
      </ul>

      <button type="button" class="btn btn-sm" phx-click="add_list_item" phx-value-key={@field.key}>
        + Add {@field.item_label || @field.label}
      </button>
    </fieldset>
    """
  end

  # A single scalar input. `name` is the full form name (so it works at any
  # nesting depth) and `picker_ctx` is the file-picker context (`meta`/`sub`/
  # `item`) round-tripped back via `{:file_picked, _, ctx}`.
  attr :field, :map, required: true
  attr :value, :any, required: true
  attr :name, :string, required: true
  attr :picker_target, :string, required: true
  attr :picker_ctx, :map, default: %{}
  attr :site_uploads, :list, default: []

  defp scalar_field(%{field: %{type: "file"}} = assigns) do
    assigns =
      assign(assigns,
        selected: selected_upload(assigns.site_uploads, assigns.value),
        open_attrs: picker_attrs(assigns.picker_ctx) ++ [{"phx-value-current", assigns.value}],
        clear_attrs: picker_attrs(assigns.picker_ctx)
      )

    ~H"""
    <label>
      {@field.label}
      <div class="token-file">
        <input type="hidden" name={@name} value={@value} />
        <span :if={@selected} class="token-file-thumb">
          <img :if={Uploads.image?(@selected)} src={Uploads.url(@selected)} alt="" />
          <span :if={not Uploads.image?(@selected)} class="file-badge file-badge-sm">
            {file_ext(@selected.filename)}
          </span>
        </span>
        <span :if={@selected} class="token-file-name">{@selected.filename}</span>
        <span :if={is_nil(@selected)} class="token-file-empty">No file selected</span>
        <div class="token-file-actions">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="open"
            phx-target={@picker_target}
            {@open_attrs}
          >
            {if @selected, do: "Change", else: "Choose file"}
          </button>
          <button
            :if={@selected}
            type="button"
            class="btn btn-sm"
            phx-click="clear_meta"
            {@clear_attrs}
          >
            Remove
          </button>
        </div>
      </div>
      <small :if={@field.description}>{@field.description}</small>
    </label>
    """
  end

  defp scalar_field(%{field: %{type: "boolean"}} = assigns) do
    assigns =
      assign(assigns,
        checked?: truthy?(assigns.value, assigns.field.default),
        dom_id: field_dom_id(assigns.name)
      )

    ~H"""
    <div class="settings-checkbox">
      <label for={@dom_id} class="settings-checkbox-text">
        <span>{@field.label}</span>
        <small :if={@field.description}>{@field.description}</small>
      </label>
      <input type="hidden" name={@name} value="false" />
      <input type="checkbox" id={@dom_id} name={@name} value="true" checked={@checked?} />
    </div>
    """
  end

  defp scalar_field(%{field: %{type: "select"}} = assigns) do
    ~H"""
    <label>
      {@field.label}
      <select name={@name}>
        <option
          :for={opt <- @field.options}
          value={opt}
          selected={to_string(opt) == to_string((@value == "" && @field.default) || @value)}
        >
          {capitalize_first(opt)}
        </option>
      </select>
      <small :if={@field.description}>{@field.description}</small>
    </label>
    """
  end

  defp scalar_field(%{field: %{type: "text"}} = assigns) do
    ~H"""
    <label>
      {@field.label}
      <textarea name={@name} rows="3" placeholder={placeholder(@field)}>{@value}</textarea>
      <small :if={@field.description}>{@field.description}</small>
    </label>
    """
  end

  # A `color` input has no placeholder to fall back on, so it's pre-filled with
  # the effective value (override-or-default) rather than showing black. Every
  # other input holds the override alone, with the default as its placeholder —
  # so leaving a field untouched keeps it unset instead of pinning the current
  # default as an override.
  defp scalar_field(%{field: %{type: "color"}} = assigns) do
    assigns = assign(assigns, :display_value, effective_value(assigns.value, assigns.field))

    ~H"""
    <label>
      {@field.label}
      <input type="color" name={@name} value={@display_value} />
      <small :if={@field.description}>{@field.description}</small>
      <small :if={is_nil(@field.description) and @field.default not in [nil, ""]}>
        Default: <code>{@field.default}</code>
      </small>
    </label>
    """
  end

  defp scalar_field(assigns) do
    ~H"""
    <label>
      {@field.label}
      <input
        type={input_type(@field.type)}
        name={@name}
        value={@value}
        placeholder={placeholder(@field)}
      />
      <small :if={@field.description}>{@field.description}</small>
    </label>
    """
  end

  defp drag_handle_icon(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M9 5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm0 7a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm-1.5 8.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3ZM18 5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm-1.5 8.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Zm0 7a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z" />
    </svg>
    """
  end

  defp trash_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.7"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0"
      />
    </svg>
    """
  end

  # ---- value + input helpers ----

  # A stored `false` is a value, not an absence — match on nil rather than
  # falling back with `||`, or an unchecked boolean would read as "unset" and
  # bounce back to a `"default": true`.
  defp value_at(values, key) when is_map(values) do
    case Map.get(values, key, Map.get(values, to_string(key))) do
      nil -> ""
      v -> v
    end
  end

  defp value_at(_values, _key), do: ""

  defp items_at(values, key) when is_map(values) do
    case Map.get(values, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp items_at(_values, _key), do: []

  defp sub_value(map, key) when is_map(map), do: value_at(map, key)
  defp sub_value(_map, _key), do: ""

  defp item_handle(key, item), do: key <> ":" <> to_string(item["_id"])

  defp standalone_open?(containers, handle), do: not MapSet.member?(containers.closed, handle)

  defp item_open?(containers, handle), do: containers.open == handle

  # A collapsed item is identified by its first titleish subfield — the one an
  # author would recognise the row by. Numbers, colors and files say nothing
  # at a glance, so they never become the title.
  @title_types ~w(string text url select)

  defp item_title(item, field, index) do
    field.fields
    |> Enum.filter(&(&1.type in @title_types))
    |> Enum.map(&subfield_text(item, &1))
    |> Enum.find("#{field.item_label || field.label} #{index + 1}", &(&1 != ""))
  end

  defp subfield_text(item, subfield),
    do: item |> sub_value(subfield.key) |> to_string() |> String.trim()

  defp effective_value(value, field) do
    case value do
      v when v in [nil, ""] -> to_string(field.default || "")
      v -> to_string(v)
    end
  end

  # Always give an input a placeholder: the field's default, or its label when
  # there is no default.
  defp placeholder(field) do
    case to_string(field.default || "") do
      "" -> to_string(field.label || "")
      default -> default
    end
  end

  defp input_type("number"), do: "number"
  defp input_type("url"), do: "url"
  defp input_type(_), do: "text"

  defp truthy?(value, default) do
    case value do
      v when v in [true, "true", "on", "1", 1] -> true
      v when v in [false, "false", "0", 0] -> false
      # Unset (nil / "") → fall back to the declared default, so a field with
      # `"default": true` starts checked.
      _ -> truthy?(default, false)
    end
  end

  # File-picker context → phx-value-* attribute tuples for dynamic spreading.
  defp picker_attrs(ctx), do: Enum.map(ctx, fn {k, v} -> {"phx-value-#{k}", v} end)

  # A DOM-safe id from a bracketed input name (unique per nested path).
  defp field_dom_id(name),
    do: "meta-" <> (name |> String.replace(~r/[^a-zA-Z0-9_]+/, "-") |> String.trim("-"))

  defp selected_upload(_uploads, value) when value in [nil, ""], do: nil

  defp selected_upload(uploads, value),
    do: Enum.find(uploads, fn u -> to_string(u.id) == to_string(value) end)

  defp file_ext(filename),
    do: filename |> Path.extname() |> String.trim_leading(".") |> String.upcase()

  # Capitalize only the first letter (keeps the rest as-authored, unlike
  # String.capitalize/1 which lowercases the tail).
  defp capitalize_first(opt) do
    case to_string(opt) do
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      other -> other
    end
  end
end

defmodule MastheadWeb.AdminLive.SiteTheme do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  import MastheadWeb.AdminLive.SettingsFields, only: [settings_fields: 1]

  alias Masthead.{Actions, Sites, Themes, Uploads}
  alias MastheadWeb.AdminLive.SettingsFields

  # Token overrides are edited exactly like page options — same field types,
  # same editor (`SettingsFields`), including `object`/`list` containers. They
  # live in their own `@tokens` draft rather than in the changeset: a `list`
  # token's items need identity (`_id`) across add/remove/drag-reorder, which
  # form params alone can't carry. The draft is canonicalized back into
  # `site[theme_tokens]` on save.
  defp prefix, do: "site[theme_tokens]"
  defp picker_target, do: "#theme-file-picker"

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site
    changeset = Sites.change_settings(site)
    themes = Themes.list_themes_for_site(site)
    selected = pick_theme(themes, current_theme_id(changeset, site))
    fields = token_fields(selected)

    {:ok,
     socket
     |> assign(
       page_title: "Theme — #{site.name}",
       themes: themes,
       site_uploads: Uploads.list_uploads(site.id),
       action_count: Actions.count_pending(site),
       show_errors: false,
       containers: SettingsFields.containers(),
       selected_theme: selected,
       token_fields: fields,
       tokens: SettingsFields.hydrate(site.theme_tokens || %{}, fields)
     )
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("toggle_container", %{"handle" => handle} = params, socket) do
    {:noreply,
     update(socket, :containers, &SettingsFields.toggle_container(&1, handle, params["kind"]))}
  end

  def handle_event("validate", %{"site" => params}, socket) do
    changeset =
      socket.assigns.site
      |> Sites.change_settings(site_params(params))
      |> Map.put(:action, :validate)

    selected = pick_theme(socket.assigns.themes, current_theme_id(changeset, socket.assigns.site))

    {:noreply,
     socket
     |> sync_tokens(selected, token_params(params))
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"site" => params}, socket) do
    fields = socket.assigns.token_fields
    tokens = SettingsFields.merge_params(socket.assigns.tokens, token_params(params), fields)

    full_params = Map.put(site_params(params), "theme_tokens", tokens_to_store(tokens, fields))

    case Sites.update_settings(socket.assigns.site, full_params) do
      {:ok, site} ->
        Masthead.Themes.Loader.invalidate(site.theme_id)
        changeset = Sites.change_settings(site)

        {:noreply,
         socket
         |> assign(
           site: site,
           action_count: Actions.count_pending(site),
           selected_theme: pick_theme(socket.assigns.themes, site.theme_id),
           tokens: SettingsFields.hydrate(site.theme_tokens || %{}, fields)
         )
         |> put_flash(:info, "Theme saved.")
         |> assign_form(changeset)}

      {:error, changeset} ->
        {:noreply, socket |> assign(show_errors: true, tokens: tokens) |> assign_form(changeset)}
    end
  end

  # ---- list tokens (add / remove / drag-reorder) ----

  def handle_event("add_list_item", %{"key" => key}, socket) do
    tokens = SettingsFields.add_item(socket.assigns.tokens, socket.assigns.token_fields, key)

    {:noreply,
     assign(socket,
       tokens: tokens,
       containers: SettingsFields.open_last_item(socket.assigns.containers, tokens, key)
     )}
  end

  def handle_event("remove_list_item", %{"key" => key, "id" => id}, socket) do
    {:noreply, update(socket, :tokens, &SettingsFields.remove_item(&1, key, id))}
  end

  def handle_event("reorder_list", %{"key" => key, "ids" => ids}, socket) do
    {:noreply, update(socket, :tokens, &SettingsFields.reorder(&1, key, ids))}
  end

  # ---- file tokens ----
  # The picker UI lives in the shared `FilePicker` LiveComponent; it reports the
  # chosen upload back here via `{:file_picked, upload, context}`, where the
  # context locates the field (top-level / inside an object / inside a list
  # item) it was opened from.

  def handle_event("clear_meta", %{"meta" => key, "sub" => sub, "item" => id}, socket) do
    {:noreply, update(socket, :tokens, &SettingsFields.put_list_item_value(&1, key, id, sub, ""))}
  end

  def handle_event("clear_meta", %{"meta" => key, "sub" => sub}, socket) do
    {:noreply, update(socket, :tokens, &SettingsFields.put_object_value(&1, key, sub, ""))}
  end

  def handle_event("clear_meta", %{"meta" => key}, socket) do
    {:noreply, update(socket, :tokens, &SettingsFields.put_value(&1, key, ""))}
  end

  @impl true
  def handle_info({:file_picked, upload, %{"meta" => key, "sub" => sub, "item" => id}}, socket) do
    value = upload_value(upload)

    {:noreply,
     socket
     |> maybe_refresh_uploads(upload)
     |> update(:tokens, &SettingsFields.put_list_item_value(&1, key, id, sub, value))}
  end

  def handle_info({:file_picked, upload, %{"meta" => key, "sub" => sub}}, socket) do
    value = upload_value(upload)

    {:noreply,
     socket
     |> maybe_refresh_uploads(upload)
     |> update(:tokens, &SettingsFields.put_object_value(&1, key, sub, value))}
  end

  def handle_info({:file_picked, upload, %{"meta" => key}}, socket) do
    value = upload_value(upload)

    {:noreply,
     socket
     |> maybe_refresh_uploads(upload)
     |> update(:tokens, &SettingsFields.put_value(&1, key, value))}
  end

  def handle_info({:file_picked, _upload, _ctx}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp upload_value(nil), do: ""
  defp upload_value(upload), do: to_string(upload.id)

  # A freshly uploaded file must be in the list before the field can show it.
  defp maybe_refresh_uploads(socket, nil), do: socket

  defp maybe_refresh_uploads(socket, _upload),
    do: assign(socket, site_uploads: Uploads.list_uploads(socket.assigns.site.id))

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :site), changeset: changeset)
  end

  # The token draft is edited outside the changeset, so it never rides along in
  # the raw params (an in-progress list item's `_id` keys have no business in
  # the jsonb column).
  defp site_params(params), do: Map.delete(params, "theme_tokens")

  defp token_params(%{"theme_tokens" => %{} = tokens}), do: tokens
  defp token_params(_params), do: %{}

  # Fold this change's inputs into the token draft. When the change *is* a theme
  # switch, re-shape the draft against the new theme's fields — values keyed the
  # same in both themes carry over, and the new theme's list defaults get seeded.
  defp sync_tokens(socket, selected, token_params) do
    old_fields = socket.assigns.token_fields
    tokens = SettingsFields.merge_params(socket.assigns.tokens, token_params, old_fields)

    if selected == socket.assigns.selected_theme do
      assign(socket, selected_theme: selected, tokens: tokens)
    else
      new_fields = token_fields(selected)

      assign(socket,
        selected_theme: selected,
        token_fields: new_fields,
        tokens:
          tokens
          |> SettingsFields.canonicalize(old_fields)
          |> SettingsFields.hydrate(new_fields)
      )
    end
  end

  # What actually lands in the jsonb column: the declared tokens only (a value
  # left over from a previously selected theme is inert, so it isn't kept), with
  # `_id`s and empty subvalues stripped.
  defp tokens_to_store(tokens, fields) do
    tokens
    |> SettingsFields.canonicalize(fields)
    |> Map.take(Enum.map(fields, & &1.key))
  end

  defp current_theme_id(changeset, site) do
    case Ecto.Changeset.get_field(changeset, :theme_id) do
      nil -> site.theme_id
      id -> id
    end
  end

  defp pick_theme(themes, nil), do: List.first(themes)

  defp pick_theme(themes, id) do
    Enum.find(themes, List.first(themes), fn t -> t.id == id end)
  end

  # The theme's token declarations, normalized. A token is the same kind of
  # field as page options — scalars, plus `object`/`list` containers — so the
  # manifest's list feeds the shared editor directly.
  defp token_fields(nil), do: []

  defp token_fields(%Masthead.Themes.Theme{manifest: %{} = m}) do
    m
    |> Map.get("tokens", Map.get(m, :tokens, []))
    |> SettingsFields.normalize_fields()
  end

  defp token_fields(_theme), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Theme"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:theme}
      action_count={@action_count}
      present_users={@present_users}
    >
      <div class="wizard">
        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="form settings-form"
          id="site-theme-form"
        >
          <.error_list changeset={@changeset} show={@show_errors} />

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Theme</h2>
              <p>The rendering style applied to your public site.</p>
            </header>

            <div class="settings-fields">
              <fieldset class="theme-picker">
                <legend class="sr-only">Theme</legend>
                <label
                  :for={t <- @themes}
                  class={"theme-picker-card" <> if(@selected_theme && t.id == @selected_theme.id, do: " theme-picker-card-selected", else: "")}
                >
                  <input
                    type="radio"
                    name="site[theme_id]"
                    value={t.id}
                    checked={@selected_theme && t.id == @selected_theme.id}
                  />
                  <span class="theme-picker-card-name">{t.name}</span>
                </label>
                <.link
                  class="theme-picker-card theme-picker-card-add"
                  navigate={~p"/marketplace?#{[for: @site.slug]}"}
                >
                  <span class="theme-picker-card-icon" aria-hidden="true">+</span>
                </.link>
              </fieldset>
            </div>
          </div>

          <div :if={@selected_theme && @token_fields != []} class="settings-section">
            <header class="settings-section-head">
              <h2>Theme customization</h2>
              <p>Override the {@selected_theme.name} theme's design tokens.</p>
            </header>

            <.settings_fields
              fields={@token_fields}
              values={@tokens}
              prefix={prefix()}
              picker_target={picker_target()}
              site_uploads={@site_uploads}
              containers={@containers}
            />
          </div>

          <div :if={@selected_theme} class="settings-section">
            <header class="settings-section-head">
              <h2>Custom CSS</h2>
              <p>Optional escape hatch — appended after the theme's stylesheet.</p>
            </header>

            <div class="settings-fields">
              <label>
                CSS overrides <textarea
                  name="site[theme_css_overrides]"
                  rows="6"
                  placeholder=".my-class { color: red; }"
                >{@form[:theme_css_overrides].value}</textarea>
                <small>Up to 50 KB. No imports or external resources.</small>
              </label>
            </div>
          </div>

          <div class="wizard-footer">
            <.link navigate={~p"/#{@site.slug}"} class="btn">Cancel</.link>
            <button type="submit" class="btn btn-primary" data-shortcut="save">
              Save theme
            </button>
          </div>
        </.form>
      </div>

      <.live_component
        module={MastheadWeb.AdminLive.FilePicker}
        id="theme-file-picker"
        site={@site}
        accept={~w(.png .jpg .jpeg .gif .webp .svg .ico .pdf)}
        clearable
      />
    </.shell>
    """
  end
end

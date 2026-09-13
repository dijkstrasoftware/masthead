defmodule MastheadWeb.AdminLive.PageForm do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  import MastheadWeb.AdminLive.SettingsFields, only: [settings_fields: 1, settings_form: 1]

  alias Masthead.{Content, Realtime, Themes, Uploads}
  alias Masthead.Content.Page
  alias Masthead.Themes.Manifest
  alias MastheadWeb.AdminLive.SettingsFields

  # The form-name prefix a page's settings values are cast from, and the file
  # picker they open. The editor itself is shared with the site's theme-token
  # settings (`site[theme_tokens]`) — see `SettingsFields`.
  defp prefix, do: "page[page_options]"
  defp picker_target, do: "#page-meta-file-picker"

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket),
      do: Realtime.subscribe(Realtime.content_topic(socket.assigns.site.id))

    {page, draft, page_title, step} =
      case socket.assigns.live_action do
        :new ->
          {nil, %{"format" => "markdown"}, "New page", 1}

        :import ->
          # Step 0 is the file-picker screen. A single imported file seeds the
          # draft and jumps to step 2 (Details); multiple files are created as
          # drafts directly.
          {nil, %{"format" => "markdown"}, "Import pages", 0}

        :edit ->
          page = Content.get_page!(socket.assigns.site.id, params["id"])
          # Markdown/HTML pages open on the content step (4); theme pages have
          # no content step, so they open on Page settings (3). Earlier steps
          # are reachable via Back.
          edit_step = if page.format == "theme", do: 3, else: 4
          {page, page_to_draft(page), "Edit: #{page.title}", edit_step}
      end

    theme_manifest = Themes.manifest_for_site(socket.assigns.site)
    page_option_fields = extract_page_option_fields(theme_manifest)
    has_page_options? = page_option_fields != []
    page_template_names = Themes.Loader.manifest_page_template_names(theme_manifest)

    # Give any existing list-item option fresh `_id`s so the editor can track
    # them across add/remove/reorder.
    fields = settings_fields_for(draft, theme_manifest, page_option_fields)
    draft = update_page_options(draft, &SettingsFields.hydrate(&1, fields))

    {:ok,
     socket
     |> assign(
       page: page,
       step: step,
       draft: draft,
       page_title: page_title,
       slug_touched: page != nil,
       show_errors: false,
       external_change: nil,
       theme_manifest: theme_manifest,
       page_option_fields: page_option_fields,
       has_page_options?: has_page_options?,
       page_template_names: page_template_names,
       page_templates: page_template_options(theme_manifest, page_template_names),
       allow_theme?: page_template_names != [],
       tags: Content.list_tags(socket.assigns.site.id),
       site_uploads: Uploads.list_uploads(socket.assigns.site.id),
       open_settings_group: nil
     )
     |> maybe_allow_import()
     |> assign_changeset(draft)}
  end

  defp maybe_allow_import(%{assigns: %{live_action: :import}} = socket) do
    allow_upload(socket, :document,
      accept: ~w(.md .markdown .html .htm .txt),
      max_entries: 20,
      max_file_size: 5_000_000
    )
  end

  defp maybe_allow_import(socket), do: socket

  # The site's current theme manifest (a plain map from the DB), or nil.
  defp extract_page_option_fields(manifest) do
    manifest
    |> Manifest.option_fields(:page_options)
    |> normalize_field_list()
  end

  # A theme page's settings come from its sidecar config
  # (`templates/pages/<name>.json`), persisted into the DB manifest under
  # `page_configs` (keyed by template name) at seed / install time.
  # The DB manifest is string-keyed (jsonb round-trip), so configs are looked up
  # by the string template name — never String.to_atom on user input.
  defp page_config(%{} = manifest, template) when is_binary(template) do
    case Map.get(manifest, "page_configs", Map.get(manifest, :page_configs, %{})) do
      %{} = configs -> configs[template]
      _ -> nil
    end
  end

  defp page_config(_manifest, _template), do: nil

  defp page_settings_fields(manifest, template) do
    case page_config(manifest, template) do
      %{} = cfg -> normalize_field_list(Manifest.option_fields(cfg, :page_options))
      _ -> []
    end
  end

  defp page_setting_label(manifest, template) do
    case page_config(manifest, template) do
      %{} = cfg -> cfg["label"] || cfg[:label] || template_label(template)
      _ -> template_label(template)
    end
  end

  defp page_setting_description(manifest, template) do
    case page_config(manifest, template) do
      %{} = cfg -> cfg["description"] || cfg[:description]
      _ -> nil
    end
  end

  # The picker list: one `%{name, label}` per page template (label from the
  # sidecar config, else the humanized file name).
  defp page_template_options(manifest, names) do
    Enum.map(names, fn name -> %{name: name, label: page_setting_label(manifest, name)} end)
  end

  defp normalize_field_list(list), do: SettingsFields.normalize_fields(list)

  @impl true
  def handle_event("choose_format", %{"format" => "theme"}, socket) do
    # Selecting the Theme page card marks the format without requiring a
    # template yet — Continue and the stepper stay locked until one is picked.
    if socket.assigns.page do
      {:noreply, socket}
    else
      {:noreply, update(socket, :draft, &Map.put(&1, "format", "theme"))}
    end
  end

  def handle_event("choose_format", %{"format" => fmt}, socket)
      when fmt in ~w(markdown html) do
    # Selecting a format doesn't advance — the user can freely switch between
    # the cards and then hit Continue. Switching away from a theme page drops
    # any chosen template.
    if socket.assigns.page do
      {:noreply, socket}
    else
      {:noreply,
       update(socket, :draft, fn d -> d |> Map.put("format", fmt) |> Map.delete("template") end)}
    end
  end

  def handle_event("choose_template", %{"template" => name}, socket) do
    # Picking a template from the Theme page card selects the theme format too;
    # it does not advance (Continue does). The template is fixed once the page
    # is created, so this is a no-op when editing.
    cond do
      socket.assigns.page ->
        {:noreply, socket}

      name not in socket.assigns.page_template_names ->
        {:noreply, socket}

      true ->
        # Seed the draft with the chosen template's settings (incl. any default
        # list items) so the editor opens pre-filled with the theme's defaults.
        meta =
          SettingsFields.hydrate(%{}, page_settings_fields(socket.assigns.theme_manifest, name))

        {:noreply,
         update(socket, :draft, fn d ->
           d
           |> Map.put("format", "theme")
           |> Map.put("template", name)
           |> Map.put("page_options", meta)
         end)}
    end
  end

  def handle_event("toggle_settings_group", %{"group" => group}, socket) do
    open = if socket.assigns.open_settings_group == group, do: nil, else: group
    {:noreply, assign(socket, open_settings_group: open)}
  end

  def handle_event("clear_meta", %{"meta" => k, "sub" => sub, "item" => id}, socket) do
    draft = put_list_item_value(socket.assigns.draft, k, id, sub, "")
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("clear_meta", %{"meta" => k, "sub" => sub}, socket) do
    draft = put_object_value(socket.assigns.draft, k, sub, "")
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("clear_meta", %{"meta" => key}, socket) do
    draft = put_page_option_value(socket.assigns.draft, key, "")
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("add_list_item", %{"key" => key}, socket) do
    fields = current_settings_fields(socket)
    draft = update_page_options(socket.assigns.draft, &SettingsFields.add_item(&1, fields, key))
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("remove_list_item", %{"key" => key, "id" => id}, socket) do
    draft = update_page_options(socket.assigns.draft, &SettingsFields.remove_item(&1, key, id))
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("reorder_list", %{"key" => key, "ids" => ids}, socket) do
    draft = update_page_options(socket.assigns.draft, &SettingsFields.reorder(&1, key, ids))
    {:noreply, socket |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_event("toggle_filter_tag", %{"id" => id}, socket) do
    selected = socket.assigns.draft["filter_tag_ids"] || []

    selected =
      if id in selected, do: List.delete(selected, id), else: [id | selected]

    {:noreply, update(socket, :draft, &Map.put(&1, "filter_tag_ids", selected))}
  end

  def handle_event("advance", _params, socket) do
    # Fired by the Format step's Continue button. Advance only once a complete
    # selection exists (a theme page needs its template).
    draft = socket.assigns.draft

    if socket.assigns.page != nil or format_chosen?(draft["format"], draft["template"]) do
      {:noreply, assign(socket, step: 2)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: prev_step(socket))}
  end

  # Stepper navigation â jump directly to any visible step. The draft is
  # kept in sync by the per-step `phx-change="validate"`, so jumping
  # around doesn't lose typed content or page-option selections. Final
  # validation still happens on save.
  def handle_event("goto_step", %{"step" => step}, socket) do
    target = String.to_integer(step)
    valid = visible_step_nums(socket.assigns)

    if target in valid and nav_allowed?(socket.assigns, target) do
      {:noreply, assign(socket, step: target)}
    else
      {:noreply, socket}
    end
  end

  # ---- Import ----

  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_import", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :document, ref)}
  end

  def handle_event("import_file", _params, socket) do
    files =
      consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    case files do
      [] ->
        {:noreply, socket}

      [{filename, body}] ->
        # A single file flows into the wizard so details can be refined
        # before saving â landing on step 2 (Details).
        draft = Map.merge(socket.assigns.draft, Content.Import.attrs_from_file(filename, body))

        {:noreply,
         socket
         |> assign(draft: draft, step: 2, slug_touched: false)
         |> assign_changeset(draft)}

      many ->
        # Multiple files are created as drafts straight away.
        {ok, failed} =
          Enum.reduce(many, {0, 0}, fn {filename, body}, {ok, failed} ->
            attrs = Content.Import.attrs_from_file(filename, body)

            case Content.create_page(socket.assigns.site.id, attrs) do
              {:ok, _} -> {ok + 1, failed}
              {:error, _} -> {ok, failed + 1}
            end
          end)

        {:noreply,
         socket
         |> put_flash(:info, import_flash("page", ok, failed))
         |> push_navigate(to: ~p"/#{socket.assigns.site.slug}/pages")}
    end
  end

  def handle_event("next_meta", %{"page" => params}, socket) do
    draft = Map.merge(socket.assigns.draft, params)
    changeset = build_changeset(socket, draft)

    if Ecto.Changeset.get_field(changeset, :title) not in [nil, ""] do
      # Skip the settings step entirely when the theme declares no
      # page options — we'd render an empty step otherwise.
      next =
        cond do
          draft["format"] == "theme" -> 3
          socket.assigns.has_page_options? -> 3
          true -> 4
        end

      {:noreply,
       socket
       |> assign(draft: draft, step: next)
       |> assign_changeset(draft)}
    else
      {:noreply,
       socket
       |> assign(draft: draft, show_errors: true)
       |> assign_changeset(draft, validate: true)}
    end
  end

  def handle_event("next_settings", %{"page" => params}, socket) do
    # Merge the page-options sub-map into the draft and advance to Content.
    draft = merge_draft_params(socket.assigns.draft, params, current_settings_fields(socket))

    {:noreply,
     socket
     |> assign(draft: draft, step: 4)
     |> assign_changeset(draft)}
  end

  def handle_event("next_settings", _params, socket) do
    # Form submitted with no inputs (all blank). Still advance.
    {:noreply, assign(socket, step: 4)}
  end

  def handle_event("validate", %{"page" => params} = full_params, socket) do
    target = List.last(full_params["_target"] || [])
    slug_touched = update_slug_touched(socket.assigns[:slug_touched], target, params)

    params =
      if !slug_touched and target == "title" do
        Map.put(params, "slug", "")
      else
        params
      end

    draft = merge_draft_params(socket.assigns.draft, params, current_settings_fields(socket))

    {:noreply,
     socket
     |> assign(draft: draft, slug_touched: slug_touched)
     |> assign_changeset(draft, validate: true)}
  end

  def handle_event("save", %{"page" => page_params} = params, socket) do
    publish? =
      case socket.assigns.page do
        nil -> Map.get(params, "action", "draft") == "publish"
        page -> page.published
      end

    fields = current_settings_fields(socket)
    draft = merge_draft_params(socket.assigns.draft, page_params, fields)
    canonical = SettingsFields.canonicalize(page_options(draft), fields)

    full_params =
      draft
      |> Map.put("page_options", canonical)
      |> Map.put("published", to_string(publish?))

    result =
      case socket.assigns.page do
        nil -> Content.create_page(socket.assigns.site.id, full_params)
        page -> Content.update_page(page, full_params)
      end

    case result do
      {:ok, saved} ->
        flash =
          case {socket.assigns.page, publish?} do
            {nil, true} -> "Page published."
            {nil, false} -> "Draft saved."
            {_, _} -> "Changes saved."
          end

        if socket.assigns.page do
          # Editing: save in place so UI state (an expanded settings group, the
          # current step, scroll) is preserved rather than reset by a remount.
          {:noreply,
           socket
           |> assign(page: saved, draft: draft, show_errors: false)
           |> assign_changeset(draft)
           |> put_flash(:info, flash)}
        else
          # First save of a new page: navigate so the editor switches into edit
          # mode (and the URL reflects the saved page).
          {:noreply,
           socket
           |> put_flash(:info, flash)
           |> push_navigate(to: ~p"/#{socket.assigns.site.slug}/pages/#{saved.id}/edit")}
        end

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form: to_form(changeset, as: :page),
           changeset: changeset,
           show_errors: true
         )}
    end
  end

  def handle_event("toggle_publish", _params, socket) do
    case socket.assigns[:page] do
      nil ->
        {:noreply, socket}

      page ->
        new_published = !page.published

        case Content.update_page(page, %{"published" => to_string(new_published)}) do
          {:ok, updated} ->
            msg = if new_published, do: "Page published.", else: "Page unpublished."

            {:noreply,
             socket
             |> assign(page: updated)
             |> update(:draft, &Map.put(&1, "published", to_string(new_published)))
             |> put_flash(:info, msg)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Couldn't update publish state.")}
        end
    end
  end

  def handle_event("delete", _params, socket) do
    case socket.assigns[:page] do
      nil ->
        {:noreply, socket}

      page ->
        {:ok, _} = Content.delete_page(page)

        {:noreply,
         socket
         |> put_flash(:info, "Page deleted.")
         |> push_navigate(to: ~p"/#{socket.assigns.site.slug}/pages")}
    end
  end

  def handle_event("dismiss_external_change", _params, socket),
    do: {:noreply, assign(socket, external_change: nil)}

  # ---- Editor tools (sidebar) ----

  def handle_event("format_body", _params, socket) do
    format = socket.assigns.draft["format"] || "markdown"
    formatted = Masthead.Content.Format.run(socket.assigns.draft["body"] || "", format)
    draft = Map.put(socket.assigns.draft, "body", formatted)

    {:noreply,
     socket
     |> assign(draft: draft)
     |> assign_changeset(draft)
     |> push_event("editor_replace", %{id: editor_dom_id(format), text: formatted})}
  end

  # A file-type page option's picker reports back here with the field key in
  # its context. Store the chosen upload's id (or "" to clear) into the draft's
  # options map — the renderer resolves the id to a URL, exactly like a file
  # token. Must precede the body-insert clause, which matches any upload.
  # A file inside a list item (context carries the list key, item `_id`, subkey).
  @impl true
  def handle_info({:file_picked, upload, %{"meta" => k, "sub" => sub, "item" => id}}, socket) do
    draft = put_list_item_value(socket.assigns.draft, k, id, sub, upload_value(upload))

    {:noreply,
     socket |> maybe_refresh_uploads(upload) |> assign(draft: draft) |> assign_changeset(draft)}
  end

  # A file inside an object field (context carries the object key + subkey).
  def handle_info({:file_picked, upload, %{"meta" => k, "sub" => sub}}, socket) do
    draft = put_object_value(socket.assigns.draft, k, sub, upload_value(upload))

    {:noreply,
     socket |> maybe_refresh_uploads(upload) |> assign(draft: draft) |> assign_changeset(draft)}
  end

  # A top-level file page option.
  def handle_info({:file_picked, upload, %{"meta" => key}}, socket) do
    draft = put_page_option_value(socket.assigns.draft, key, upload_value(upload))

    {:noreply,
     socket |> maybe_refresh_uploads(upload) |> assign(draft: draft) |> assign_changeset(draft)}
  end

  def handle_info({:file_picked, %Masthead.Uploads.Upload{} = upload, _ctx}, socket) do
    format = socket.assigns.draft["format"] || "markdown"
    text = image_snippet(upload, format)
    {:noreply, push_event(socket, "editor_insert", %{id: editor_dom_id(format), text: text})}
  end

  def handle_info({:file_picked, _other, _ctx}, socket), do: {:noreply, socket}

  # Someone else changed or deleted the page being edited (updated_at compare
  # ignores this editor's own save).
  def handle_info({:realtime, :content, %{kind: :page, id: id} = meta}, socket) do
    {:noreply, note_external_change(socket, id, meta)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp note_external_change(socket, id, %{op: op, updated_at: updated_at}) do
    page = socket.assigns.page

    cond do
      is_nil(page) or page.id != id ->
        socket

      op == :deleted ->
        assign(socket, external_change: :deleted)

      op == :updated and updated_at != page.updated_at ->
        assign(socket, external_change: :updated)

      true ->
        socket
    end
  end

  defp editor_dom_id(format), do: "page-body-editor-" <> format

  defp image_snippet(upload, "html"),
    do: ~s(<img src="#{Masthead.Uploads.url(upload)}" alt="#{image_alt(upload)}" />)

  defp image_snippet(upload, _markdown),
    do: "![#{image_alt(upload)}](#{Masthead.Uploads.url(upload)})"

  defp image_alt(upload), do: upload.filename |> Path.rootname()

  defp update_slug_touched(_prev, "slug", %{"slug" => slug}) when slug != "", do: true
  defp update_slug_touched(_prev, "slug", _params), do: false
  defp update_slug_touched(prev, _target, _params), do: prev || false

  defp page_to_draft(page) do
    %{
      "title" => page.title,
      "slug" => page.slug,
      "format" => page.format,
      "template" => page.template,
      "body" => page.body,
      "published" => to_string(page.published),
      "show_in_nav" => to_string(page.show_in_nav),
      "page_options" => page.page_options || %{},
      "filter_tag_ids" => Enum.map(page.filter_tags, &to_string(&1.id))
    }
  end

  # The draft's settings values live under "page_options" (they're cast straight
  # into the page's jsonb column); every mutation goes through the shared
  # editor's value helpers.
  defp page_options(draft), do: SettingsFields.draft_values(draft, "page_options")

  defp update_page_options(draft, fun),
    do: SettingsFields.update_draft(draft, "page_options", fun)

  defp put_page_option_value(draft, key, value),
    do: update_page_options(draft, &SettingsFields.put_value(&1, key, value))

  defp put_object_value(draft, key, sub, value),
    do: update_page_options(draft, &SettingsFields.put_object_value(&1, key, sub, value))

  defp put_list_item_value(draft, key, id, sub, value),
    do: update_page_options(draft, &SettingsFields.put_list_item_value(&1, key, id, sub, value))

  defp upload_value(nil), do: ""
  defp upload_value(upload), do: to_string(upload.id)

  defp maybe_refresh_uploads(socket, nil), do: socket

  defp maybe_refresh_uploads(socket, _upload),
    do: assign(socket, site_uploads: Uploads.list_uploads(socket.assigns.site.id))

  # The settings field schema for whatever the draft currently is: a theme
  # page's sidecar config, or the theme's global page options for markdown/html.
  defp current_settings_fields(%{assigns: a}),
    do: settings_fields_for(a.draft, a.theme_manifest, a.page_option_fields)

  defp settings_fields_for(draft, theme_manifest, page_option_fields) do
    if draft["format"] == "theme",
      do: page_settings_fields(theme_manifest, draft["template"] || ""),
      else: page_option_fields
  end

  # ---- schema-aware draft/params reconciliation ----

  defp merge_draft_params(draft, params, fields),
    do: SettingsFields.merge_draft_params(draft, "page_options", params, fields)

  defp import_flash(entity, ok, 0), do: "Imported #{ok} #{entity}s."

  defp import_flash(entity, ok, failed),
    do: "Imported #{ok} #{entity}s. #{failed} couldn't be imported."

  defp import_error(:too_large), do: "That file is too large (5MB max)."
  defp import_error(:not_accepted), do: "Only Markdown and HTML files are allowed."
  defp import_error(:too_many_files), do: "You can import up to 20 files at once."
  defp import_error(other), do: to_string(other)

  defp build_changeset(socket, attrs) do
    base = socket.assigns[:page] || %Page{site_id: socket.assigns.site.id}
    Content.change_page(base, attrs)
  end

  defp assign_changeset(socket, attrs, opts \\ []) do
    changeset = build_changeset(socket, attrs)

    changeset =
      if Keyword.get(opts, :validate, false),
        do: Map.put(changeset, :action, :validate),
        else: changeset

    assign(socket, form: to_form(changeset, as: :page), changeset: changeset)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title={@page_title}
      site={@site}
      current_user={@current_user}
      action_count={@action_count}
      present_users={@present_users}
      flash={@flash}
      active={:pages}
    >
      <:actions>
        <.publish_status :if={@page} published={@page.published} />
      </:actions>

      <.external_change_banner
        change={@external_change}
        reload_to={@page && ~p"/#{@site.slug}/pages/#{@page.id}/edit"}
      />

      <div class="wizard" id="page-wizard" phx-hook="SaveShortcut" data-save-param="page">
        <%= case @step do %>
          <% 0 -> %>
            <.import_step uploads={@uploads} site_slug={@site.slug} />
          <% 1 -> %>
            <.format_step
              locked={@page != nil}
              format={@draft["format"]}
              template={@draft["template"]}
              editing={@page != nil}
              site_slug={@site.slug}
              has_page_options={@has_page_options?}
              allow_theme={@allow_theme?}
              page_templates={@page_templates}
            />
          <% 2 -> %>
            <.meta_step
              form={@form}
              changeset={@changeset}
              format={@draft["format"]}
              editing={@page != nil}
              site_slug={@site.slug}
              show_errors={@show_errors}
              has_page_options={@has_page_options?}
              tags={@tags}
              selected_filter_tag_ids={@draft["filter_tag_ids"] || []}
            />
          <% 3 -> %>
            <%= if @draft["format"] == "theme" do %>
              <.theme_settings_step
                fields={page_settings_fields(@theme_manifest, @draft["template"] || "")}
                draft={@draft}
                changeset={@changeset}
                editing={@page != nil}
                published={@page != nil and @page.published}
                site={@site}
                site_uploads={@site_uploads}
                open_group={@open_settings_group}
                view_path={@page && "/" <> @page.slug}
                show_errors={@show_errors}
                template={@draft["template"]}
                label={page_setting_label(@theme_manifest, @draft["template"] || "")}
                description={page_setting_description(@theme_manifest, @draft["template"] || "")}
                has_page_options={@has_page_options?}
              />
            <% else %>
              <.settings_step
                fields={@page_option_fields}
                draft={@draft}
                format={@draft["format"]}
                site_uploads={@site_uploads}
                open_group={@open_settings_group}
                has_page_options={@has_page_options?}
              />
            <% end %>
          <% 4 -> %>
            <.content_step
              form={@form}
              changeset={@changeset}
              format={@draft["format"]}
              editing={@page != nil}
              published={@page != nil and @page.published}
              site={@site}
              view_path={@page && "/" <> @page.slug}
              site_slug={@site.slug}
              show_errors={@show_errors}
              has_page_options={@has_page_options?}
            />
        <% end %>

        <.live_component
          module={MastheadWeb.AdminLive.FilePicker}
          id="page-meta-file-picker"
          site={@site}
          accept={~w(.png .jpg .jpeg .gif .webp .svg .ico .pdf)}
          clearable
        />
      </div>
    </.shell>
    """
  end

  attr :step, :integer, default: 1
  attr :format, :string, default: nil
  attr :has_page_options, :boolean, default: false
  attr :nav_locked, :boolean, default: false

  defp stepper(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        Enum.with_index(visible_steps(assigns.format, assigns.has_page_options), 1)
      )

    ~H"""
    <ol class="stepper">
      <li
        :for={{{step_num, label}, display_idx} <- @entries}
        class={[
          "step",
          step_class(step_num, @step),
          @nav_locked and step_num != @step and "step-disabled"
        ]}
        phx-click={(not @nav_locked or step_num == @step) && "goto_step"}
        phx-value-step={step_num}
        role="button"
        tabindex="0"
      >
        <span class="step-num">{display_idx}</span>
        <span class="step-label">{label}</span>
      </li>
    </ol>
    """
  end

  defp step_class(i, current) when i < current, do: "step-done"
  defp step_class(i, current) when i == current, do: "step-current"
  defp step_class(_, _), do: "step-future"

  # Returns [{internal_step, label}, ...] for the wizard. Theme pages end on
  # Page settings (no Content step); markdown/html pages skip Page settings
  # when the theme declares no global page options.
  defp visible_steps("theme", _has_page_options),
    do: [{1, "Format"}, {2, "Details"}, {3, "Page settings"}]

  defp visible_steps(_format, true),
    do: [{1, "Format"}, {2, "Details"}, {3, "Page settings"}, {4, "Content"}]

  defp visible_steps(_format, false),
    do: [{1, "Format"}, {2, "Details"}, {4, "Content"}]

  defp visible_steps_for(assigns),
    do: visible_steps(assigns.draft["format"], assigns.has_page_options?)

  defp visible_step_nums(assigns),
    do: visible_steps_for(assigns) |> Enum.map(&elem(&1, 0))

  # Previous visible step for the Back button (skips omitted steps so the user
  # never lands on a blank/hidden screen).
  defp prev_step(%{assigns: %{step: step} = assigns}) do
    assigns
    |> visible_step_nums()
    |> Enum.take_while(&(&1 < step))
    |> List.last()
    |> Kernel.||(1)
  end

  defp prev_step(_), do: 1

  attr :uploads, :map, required: true
  attr :site_slug, :string, required: true

  defp import_step(assigns) do
    ~H"""
    <h2 class="wizard-heading">Import pages</h2>
    <p class="wizard-intro muted">
      Upload one or more Markdown (<code>.md</code>) or HTML (<code>.html</code>)
      files. The format is detected per file and the title is prefilled from the
      filename. YAML frontmatter is stripped — its <code>title</code>
      wins and <code>draft: false</code>
      publishes. Import a single file to refine it in
      the editor, or several to create them in bulk.
    </p>

    <form id="import-form" phx-submit="import_file" phx-change="validate_import" class="form">
      <label class="dropzone" phx-drop-target={@uploads.document.ref}>
        <.live_file_input upload={@uploads.document} />
        <p class="dropzone-headline">Drop files here, or click to browse</p>
        <p class="muted">Markdown or HTML, up to 5MB each.</p>
      </label>

      <ul :if={@uploads.document.entries != []} class="upload-entries">
        <li :for={entry <- @uploads.document.entries}>
          <span class="filename">{entry.client_name}</span>
          <button
            type="button"
            phx-click="cancel_import"
            phx-value-ref={entry.ref}
            class="btn btn-sm"
          >
            Remove
          </button>
          <p :for={err <- upload_errors(@uploads.document, entry)} class="error entry-error">
            {import_error(err)}
          </p>
        </li>
      </ul>

      <p :for={err <- upload_errors(@uploads.document)} class="error">{import_error(err)}</p>
    </form>

    <div class="wizard-footer">
      <.link navigate={~p"/#{@site_slug}/pages"} class="btn">Cancel</.link>
      <button
        type="submit"
        form="import-form"
        class="btn btn-primary"
        disabled={@uploads.document.entries == []}
      >
        Import &rarr;
      </button>
    </div>
    """
  end

  attr :locked, :boolean, default: false
  attr :format, :string, default: nil
  attr :template, :string, default: nil
  attr :editing, :boolean, default: false
  attr :site_slug, :string, required: true
  attr :has_page_options, :boolean, default: false
  attr :allow_theme, :boolean, default: false
  attr :page_templates, :list, default: []

  defp format_step(assigns) do
    ~H"""
    <.stepper
      step={1}
      format={@format}
      has_page_options={@has_page_options}
      nav_locked={not @locked and not format_chosen?(@format, @template)}
    />

    <h2 class="wizard-heading">
      {if @editing, do: "Page format", else: "How do you want to write this page?"}
    </h2>

    <.format_cards
      selected={@format}
      locked={@locked}
      allow_theme={@allow_theme}
      template={@template}
      page_templates={@page_templates}
    />

    <div class="wizard-footer">
      <.link navigate={~p"/#{@site_slug}/pages"} class="btn">Cancel</.link>
      <span :if={@locked} class="muted">Format is set at creation and cannot be changed.</span>
      <span
        :if={not @locked and @format == "theme" and not format_chosen?(@format, @template)}
        class="muted"
      >
        Pick a template to continue.
      </span>
      <button
        type="button"
        phx-click="advance"
        class="btn btn-primary"
        disabled={not @locked and not format_chosen?(@format, @template)}
      >
        Continue &rarr;
      </button>
    </div>
    """
  end

  # A format is ready to continue from the Format step when a writing format is
  # picked, or — for a theme page — a template has also been chosen.
  defp format_chosen?("theme", template), do: is_binary(template) and template != ""
  defp format_chosen?(format, _template), do: format in ~w(markdown html)

  # Stepper navigation is open while editing or once the format selection is
  # complete; otherwise only the Format step (and Import) is reachable, so a
  # half-picked theme page can't jump ahead without choosing a template.
  defp nav_allowed?(%{page: page}, _target) when not is_nil(page), do: true

  defp nav_allowed?(assigns, target),
    do: target <= 1 or format_chosen?(assigns.draft["format"], assigns.draft["template"])

  attr :form, :map, required: true
  attr :changeset, :map, required: true
  attr :format, :string, required: true
  attr :editing, :boolean, default: false
  attr :site_slug, :string, required: true
  attr :show_errors, :boolean, default: false
  attr :has_page_options, :boolean, default: false
  attr :tags, :list, default: []
  attr :selected_filter_tag_ids, :list, default: []

  defp meta_step(assigns) do
    ~H"""
    <.stepper step={2} format={@format} has_page_options={@has_page_options} />

    <form id="meta-form" phx-submit="next_meta" phx-change="validate" class="form">
      <.error_list changeset={@changeset} show={@show_errors} />

      <label>
        Title <input type="text" name="page[title]" value={@form[:title].value} required autofocus />
      </label>

      <label>
        Slug
        <input type="text" name="page[slug]" value={@form[:slug].value} placeholder="auto from title" />
        <small>URL: <code>/{Ecto.Changeset.get_field(@changeset, :slug) || "your-slug"}</code></small>
      </label>

      <div class="settings-checkbox">
        <label for="page-show-in-nav" class="settings-checkbox-text">
          <span>Show in top navigation</span>
          <small>
            Untick to keep this page out of the nav bar (e.g. a privacy policy or landing page). It stays reachable by its URL.
          </small>
        </label>
        <input type="hidden" name="page[show_in_nav]" value="false" />
        <input
          type="checkbox"
          id="page-show-in-nav"
          name="page[show_in_nav]"
          value="true"
          checked={@form[:show_in_nav].value not in [false, "false"]}
        />
      </div>

      <div :if={@format == "theme"} class="field">
        <span class="field-label">Filter posts by tag</span>
        <div class="tag-picker">
          <button
            :for={t <- @tags}
            type="button"
            phx-click="toggle_filter_tag"
            phx-value-id={t.id}
            class={["tag-toggle", to_string(t.id) in @selected_filter_tag_ids && "tag-toggle-on"]}
          >
            {t.name}
          </button>
          <.link navigate={~p"/#{@site_slug}/settings"} class="tag-chip-add">Manage tags</.link>
        </div>
        <small>Leave empty to show all posts. Selected tags show posts matching any of them.</small>
      </div>

      <input type="hidden" name="page[format]" value={@format} />
    </form>

    <div class="wizard-footer">
      <button type="button" phx-click="back" class="btn">&larr; Back</button>
      <span class="muted">Writing in <strong>{format_label(@format)}</strong></span>
      <button type="submit" form="meta-form" class="btn btn-primary">Continue &rarr;</button>
    </div>
    """
  end

  attr :fields, :list, required: true
  attr :draft, :map, required: true
  attr :format, :string, default: nil
  attr :site_uploads, :list, default: []
  attr :open_group, :string, default: nil
  attr :has_page_options, :boolean, default: true

  defp settings_step(assigns) do
    ~H"""
    <.stepper step={3} format={@format} has_page_options={@has_page_options} />

    <h2 class="wizard-heading">Page settings</h2>

    <.settings_form
      id="settings-form"
      submit="next_settings"
      fields={@fields}
      values={page_options(@draft)}
      prefix={prefix()}
      picker_target={picker_target()}
      site_uploads={@site_uploads}
      open={@open_group}
    />

    <div class="wizard-footer">
      <button type="button" phx-click="back" class="btn">&larr; Back</button>
      <button type="submit" form="settings-form" class="btn btn-primary">Continue &rarr;</button>
    </div>
    """
  end

  attr :fields, :list, required: true
  attr :draft, :map, required: true
  attr :changeset, :map, required: true
  attr :editing, :boolean, default: false
  attr :published, :boolean, default: false
  attr :site, :map, default: nil
  attr :site_uploads, :list, default: []
  attr :open_group, :string, default: nil
  attr :view_path, :string, default: nil
  attr :show_errors, :boolean, default: false
  attr :template, :string, default: nil
  attr :label, :string, default: nil
  attr :description, :string, default: nil
  attr :has_page_options, :boolean, default: false

  # The terminal step for theme pages: there is no body to edit, so the page's
  # settings (the chosen template's sidecar config) are the final step, saved
  # via the content sidebar. The template is fixed at creation, so it's shown
  # but not editable here.
  defp theme_settings_step(assigns) do
    ~H"""
    <.stepper step={3} format="theme" has_page_options={@has_page_options} />

    <h2 class="wizard-heading">{@label}</h2>
    <p :if={@description} class="wizard-intro muted">{@description}</p>

    <div class="content-layout">
      <div class="content-main">
        <form id="content-form" phx-submit="save" phx-change="validate" class="form">
          <.error_list changeset={@changeset} show={@show_errors} />

          <input type="hidden" name="page[title]" value={@draft["title"]} />
          <input type="hidden" name="page[slug]" value={@draft["slug"]} />
          <input type="hidden" name="page[format]" value="theme" />
          <input type="hidden" name="page[template]" value={@template} />

          <.settings_fields
            fields={@fields}
            values={page_options(@draft)}
            prefix={prefix()}
            picker_target={picker_target()}
            site_uploads={@site_uploads}
            open={@open_group}
          />

          <p :if={@fields == []} class="muted">This template has no settings to configure.</p>
        </form>
      </div>

      <.content_sidebar
        editing={@editing}
        published={@published}
        entity="page"
        site={@site}
        view_path={@view_path}
        format="theme"
        tools={false}
      />
    </div>

    <div class="wizard-footer">
      <button type="button" phx-click="back" class="btn">&larr; Back</button>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :changeset, :map, required: true
  attr :format, :string, required: true
  attr :editing, :boolean, default: false
  attr :published, :boolean, default: false
  attr :site, :map, default: nil
  attr :view_path, :string, default: nil
  attr :site_slug, :string, required: true
  attr :show_errors, :boolean, default: false
  attr :has_page_options, :boolean, default: false

  defp content_step(assigns) do
    ~H"""
    <.stepper step={4} format={@format} has_page_options={@has_page_options} />

    <div class="content-layout">
      <div class="content-main">
        <form id="content-form" phx-submit="save" phx-change="validate" class="form post-form">
          <.error_list changeset={@changeset} show={@show_errors} />

          <input type="hidden" name="page[title]" value={@form[:title].value} />
          <input type="hidden" name="page[slug]" value={@form[:slug].value} />
          <input type="hidden" name="page[format]" value={@format} />

          <.body_editor form={@form} format={@format} />
        </form>
      </div>

      <.content_sidebar
        editing={@editing}
        published={@published}
        entity="page"
        site={@site}
        view_path={@view_path}
        format={@format}
      />
    </div>

    <div class="wizard-footer">
      <button type="button" phx-click="back" class="btn">&larr; Back</button>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :format, :string, required: true

  defp body_editor(assigns) do
    ~H"""
    <div class="editor">
      <div class="editor-pane">
        <label for="page-body-textarea" class="editor-label">Body ({format_label(@format)})</label>
        <div
          id={"page-body-editor-" <> @format}
          class="code-editor"
          phx-hook="CodeEditor"
          phx-update="ignore"
          data-language={@format}
        >
          <textarea
            id="page-body-textarea"
            name="page[body]"
            rows="20"
            phx-debounce="200"
            class="markdown-editor"
          >{@form[:body].value}</textarea>
        </div>
      </div>
    </div>
    """
  end

  defp format_label("html"), do: "HTML"
  defp format_label(_), do: "Markdown"

  # Humanize a page-template file name for display ("about-us" -> "About us").
  defp template_label(nil), do: "page"

  defp template_label(name) when is_binary(name),
    do: name |> String.replace(["-", "_"], " ") |> String.capitalize()
end

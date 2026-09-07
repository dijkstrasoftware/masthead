defmodule MastheadWeb.AdminLive.Marketplace do
  @moduledoc """
  The Marketplace hub — discover, manage, and install themes. One gallery
  with a filter bar; "My themes" is just another filter (like Verified /
  Community):

    * `:all` / `:verified` / `:community` — themes published by others.
    * `:mine` — your own uploaded themes. Upload here; a card opens the
      theme detail page, where the author edits description, gallery and
      listing visibility in place.

  Cards are covers only — every card opens the theme's detail page
  (`AdminLive.ThemeShow`) for the description, gallery, and install panel.

  Opened from the nav it's discovery-only. Opened from a site's theme page
  ("+" card → `?for=<site-slug>`) it enters that site's **install context**:
  each card gets an Install button that adds the theme to that site, which
  the site can then select on its theme page.

  `/marketplace/my-themes` is an alias that opens straight on the `:mine`
  filter (kept so existing links and the old `/themes` URL still land here).
  """
  use MastheadWeb, :live_view

  import MastheadWeb.AdminLive.Components
  alias Masthead.Sites
  alias Masthead.Themes
  alias Masthead.Themes.Package

  @max_upload_bytes 5 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       # browse
       page_title: "Marketplace",
       filter: :all,
       search: "",
       visibility: :all,
       installed: MapSet.new(),
       install_site: nil,
       # my themes
       modal_open?: false,
       upload_error: nil,
       themes: []
     )
     |> allow_upload(:theme_zip,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: @max_upload_bytes
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The filter is the live action, so it's carried in the URL and every
    # view is linkable (/marketplace, /marketplace/verified, …). An optional
    # `?for=<site-slug>` puts the marketplace in that site's install context.
    filter = socket.assigns.live_action
    site = load_install_site(socket, params["for"])
    installed = if site, do: Themes.installed_theme_ids(site.id), else: MapSet.new()

    if filter == :mine and is_nil(socket.assigns.current_user) do
      {:noreply, push_navigate(socket, to: ~p"/marketplace")}
    else
      {:noreply,
       socket
       |> assign(
         page_title: "Marketplace",
         filter: filter,
         install_site: site,
         installed: installed
       )
       |> load_themes()}
    end
  end

  # Load the site named by `?for=`, owner-checked. Nil (discovery mode) when
  # absent, not accessible, or nobody's signed in.
  defp load_install_site(_socket, nil), do: nil
  defp load_install_site(_socket, ""), do: nil

  defp load_install_site(socket, slug) do
    case socket.assigns.current_user do
      nil -> nil
      %{admin: true} -> Sites.get_site_for_admin_by_slug!(slug)
      user -> Sites.get_user_site_by_slug!(user.id, slug)
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  # URL for each filter — the filter bar patches between these, preserving the
  # site install context (`?for=`) when present.
  defp filter_path(:all), do: ~p"/marketplace"
  defp filter_path(:verified), do: ~p"/marketplace/verified"
  defp filter_path(:community), do: ~p"/marketplace/community"
  defp filter_path(:mine), do: ~p"/marketplace/my-themes"

  defp filter_path(value, nil), do: filter_path(value)

  defp filter_path(value, %{slug: slug}),
    do: filter_path(value) <> "?" <> URI.encode_query(for: slug)

  # Load the grid for the active filter: the user's own themes for "My themes",
  # published themes from others for everything else.
  defp load_themes(%{assigns: %{filter: :mine} = a} = socket) do
    assign(socket, themes: Themes.list_themes(a.current_user.id, a.search, a.visibility))
  end

  defp load_themes(%{assigns: a} = socket) do
    assign(socket, themes: Themes.list_marketplace(viewer_id(a), a.filter, a.search))
  end

  defp viewer_id(%{current_user: nil}), do: nil
  defp viewer_id(%{current_user: user}), do: user.id

  # Reload after an install/uninstall/etc. — refresh the installed set too.
  defp refresh(%{assigns: %{install_site: nil}} = socket), do: load_themes(socket)

  defp refresh(%{assigns: %{install_site: site}} = socket) do
    socket |> assign(installed: Themes.installed_theme_ids(site.id)) |> load_themes()
  end

  # Every card links to the theme's detail page — description, gallery and
  # the install panel live there. The site install context rides along.
  defp theme_path(theme, nil), do: ~p"/marketplace/themes/#{theme.id}"

  defp theme_path(theme, %{slug: slug}),
    do: ~p"/marketplace/themes/#{theme.id}?#{[for: slug]}"

  # ---- filter / search ----

  # "My themes" sits alongside the published-theme filters; to a user it's
  # the same idea — narrow the same gallery. A signed-out visitor has no
  # library, so the filter isn't offered.
  defp filter_options(nil),
    do: [{:all, "All"}, {:verified, "Verified"}, {:community, "Community"}]

  defp filter_options(_user), do: filter_options(nil) ++ [{:mine, "My themes"}]

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(search: query) |> load_themes()}
  end

  def handle_event("visibility", %{"visibility" => value}, socket) do
    {:noreply, socket |> assign(visibility: to_visibility(value)) |> load_themes()}
  end

  # ---- install / uninstall onto the site in context ----

  def handle_event("install", %{"id" => id}, socket) do
    site = socket.assigns.install_site
    theme = Themes.get_theme!(id)

    case site && Themes.install_theme(site, theme) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "\"#{theme.name}\" installed on #{site.name}.")}

      {:error, :not_installable} ->
        {:noreply, put_flash(socket, :error, "That theme can't be installed.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("uninstall", %{"id" => id}, socket) do
    site = socket.assigns.install_site
    theme = Themes.get_theme!(id)

    case site && Themes.uninstall_theme(site, theme.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:info, "\"#{theme.name}\" removed from #{site.name}.")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(socket, :error, "That theme is active on the site — pick another first.")}

      _ ->
        {:noreply, socket}
    end
  end

  # ---- my themes: upload ----

  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: true, upload_error: nil)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :theme_zip, ref)}
  end

  # The button is hidden for a visitor, but hidden markup isn't a permission
  # check — the socket is reachable either way.
  def handle_event("upload", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("upload", _params, socket) do
    owner_id = socket.assigns.current_user.id

    results =
      consume_uploaded_entries(socket, :theme_zip, fn %{path: path}, _entry ->
        case Package.install(path, owner_id) do
          {:ok, theme} -> {:ok, {:ok, theme}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case results do
      # Straight to the new theme's page — a fresh upload has no description
      # or previews yet, and that's where they're added.
      [{:ok, theme}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Theme \"#{theme.name}\" uploaded.")
         |> push_navigate(to: ~p"/marketplace/themes/#{theme.id}")}

      [{:error, reason}] ->
        {:noreply, assign(socket, upload_error: format_error(reason))}

      [] ->
        {:noreply, assign(socket, upload_error: "Please pick a .zip file first.")}
    end
  end

  # ---- browse helpers ----

  # Never String.to_atom on a form value.
  defp to_visibility("public"), do: :public
  defp to_visibility("private"), do: :private
  defp to_visibility(_all), do: :all

  defp first_image(%{images: [image | _]}), do: image
  defp first_image(_), do: nil

  # A tasteful Unsplash placeholder for themes with no preview images, picked
  # deterministically per theme so a card's art is stable across renders.
  @placeholder_photos ~w(
    photo-1508739773434-c26b3d09e071
    photo-1618005182384-a83a8bd57fbe
    photo-1550859492-d5da9d8e45f3
    photo-1557683316-973673baf926
    photo-1487017159836-4e23ece2e4cf
    photo-1541701494587-cb58502866ab
  )

  defp placeholder_image(%{id: id}) do
    photo = Enum.at(@placeholder_photos, rem(id, length(@placeholder_photos)))
    "https://images.unsplash.com/#{photo}?w=640&h=360&fit=crop&auto=format&q=60"
  end

  # ---- my themes helpers ----

  defp close_modal(socket) do
    refs = Enum.map(socket.assigns.uploads.theme_zip.entries, & &1.ref)

    socket =
      Enum.reduce(refs, socket, fn ref, acc ->
        cancel_upload(acc, :theme_zip, ref)
      end)

    assign(socket, modal_open?: false, upload_error: nil)
  end

  # Install control for a theme — a compact icon button. With a site in
  # context, install/uninstall act directly on that site (its active theme
  # can't be uninstalled). Without one, it opens the theme's detail page,
  # where the install panel picks the target site.
  attr :theme, :map, required: true
  attr :installed, :any, required: true
  attr :install_site, :map, default: nil

  defp install_button(%{install_site: nil} = assigns) do
    ~H"""
    <.link
      navigate={theme_path(@theme, nil)}
      class="card-icon-btn is-primary"
      title="Install on a site"
      aria-label={"Install #{@theme.name}"}
    >
      <.install_icon />
    </.link>
    """
  end

  defp install_button(assigns) do
    ~H"""
    <button
      :if={not MapSet.member?(@installed, @theme.id)}
      type="button"
      class="card-icon-btn is-primary"
      phx-click="install"
      phx-value-id={@theme.id}
      title="Install on this site"
      aria-label={"Install #{@theme.name}"}
    >
      <.install_icon />
    </button>
    <button
      :if={MapSet.member?(@installed, @theme.id)}
      type="button"
      class="card-icon-btn is-installed"
      phx-click="uninstall"
      phx-value-id={@theme.id}
      disabled={@install_site.theme_id == @theme.id}
      title={
        if @install_site.theme_id == @theme.id,
          do: "Active theme — pick another first",
          else: "Installed — click to remove"
      }
      aria-label="Installed"
    >
      <.check_icon />
    </button>
    """
  end

  defp install_icon(assigns) do
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
        d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3"
      />
    </svg>
    """
  end

  defp check_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.9"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" />
    </svg>
    """
  end

  defp format_error(reason) do
    case reason do
      {:archive_too_large, _, _} ->
        "Archive exceeds the 5 MB size cap."

      {:too_many_files, _, max} ->
        "Archive contains more than #{max} files."

      {:uncompressed_too_large, _, _} ->
        "Archive's uncompressed contents exceed the cap."

      {:archive_invalid, _} ->
        "That doesn't look like a valid zip file."

      :manifest_missing ->
        "manifest.json is missing from the archive."

      {:manifest_invalid, msgs} ->
        "manifest.json: " <> Enum.join(msgs, "; ")

      {:template_missing, name} ->
        "templates/#{name}.liquid is missing."

      {:template_invalid, name, _} ->
        "templates/#{name}.liquid failed to parse."

      :theme_css_missing ->
        "theme.css is missing."

      {:slug_reserved, slug} ->
        "Slug \"#{slug}\" is reserved."

      {:version_not_newer, slug, old, new} ->
        "Theme \"#{slug}\" is already at #{old}; uploaded version #{new} is not newer. " <>
          "Bump the version in manifest.json to update it."

      {:version_unparseable, v} ->
        "Version \"#{v}\" isn't valid semver (e.g. 1.2.0) — required to update an existing theme."

      {:db_write, _changeset} ->
        "Could not save the theme. Check the manifest and try again."

      {:disallowed_asset, name} ->
        "Asset \"#{name}\" has an unsupported file extension."

      {:traversal, name} ->
        "Unsafe path in entry \"#{name}\"."

      {:absolute_path, name} ->
        "Absolute path in entry \"#{name}\"."

      {:backslash, name} ->
        "Windows-style path separator in entry \"#{name}\"."

      other ->
        "Upload failed: #{inspect(other)}"
    end
  end

  defp error_to_string(:too_large), do: "File is too large."
  defp error_to_string(:not_accepted), do: "Wrong file type."
  defp error_to_string(:too_many_files), do: "Too many files."
  defp error_to_string(err), do: inspect(err)

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <.marketplace_shell title={@page_title} current_user={@current_user} flash={@flash}>
      <:actions>
        <a
          href="https://github.com/JoeriDijkstra/masthead-template"
          target="_blank"
          rel="noopener"
          class="github-btn"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            aria-hidden="true"
          >
            <path d="M12 .5C5.6.5.5 5.6.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.2.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.8-1.6-2.6-.3-5.3-1.3-5.3-5.8 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3.2 0 0 1-.3 3.3 1.2 1-.3 2-.4 3-.4s2 .1 3 .4c2.3-1.5 3.3-1.2 3.3-1.2.6 1.7.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.1 0 4.5-2.7 5.5-5.3 5.8.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6 4.6-1.5 7.9-5.9 7.9-10.9C23.5 5.6 18.4.5 12 .5z" />
          </svg>
          <span>Theme template</span>
        </a>
        <button
          :if={@current_user}
          type="button"
          phx-click="open_modal"
          class="btn btn-primary"
        >
          + Upload theme
        </button>
      </:actions>

      <div :if={@install_site} class="marketplace-context-bar">
        <span>
          Adding a theme to <strong>{@install_site.name}</strong> — install one below, then
          pick it on the theme page.
        </span>
        <.link navigate={~p"/#{@install_site.slug}/theme"} class="btn btn-sm">
          ← Back to theme settings
        </.link>
      </div>

      <p :if={is_nil(@install_site)} class="page-intro">
        {cond do
          @filter == :mine ->
            "Every theme you have — built-ins and your uploads. Upload your own Liquid packages and publish them to the marketplace for others to use."

          is_nil(@current_user) ->
            "Themes the Masthead community has published. Open one to see its previews — installing takes an account."

          true ->
            "Discover themes the community has published. Open the marketplace from a site's theme page to install one onto that site."
        end}
      </p>

      <div class="admin-toolbar">
        <div class="admin-toolbar-row">
          <div class="admin-filters">
            <.link
              :for={{value, label} <- filter_options(@current_user)}
              patch={filter_path(value, @install_site)}
              class={["btn btn-sm", @filter == value && "btn-primary"]}
            >
              {label}
            </.link>
          </div>
          <div class="admin-toolbar-controls">
            <form :if={@filter == :mine} phx-change="visibility" class="visibility-filter">
              <select name="visibility" aria-label="Filter by visibility">
                <option value="all" selected={@visibility == :all}>All themes</option>
                <option value="public" selected={@visibility == :public}>Public</option>
                <option value="private" selected={@visibility == :private}>Private</option>
              </select>
            </form>
            <form phx-change="search" phx-submit="search" class="admin-search">
              <input
                type="search"
                name="query"
                value={@search}
                placeholder="Search themes…"
                phx-debounce="300"
                autocomplete="off"
                data-shortcut="search"
              />
            </form>
          </div>
        </div>
      </div>

      <%= if @filter == :mine do %>
        {my_themes_body(assigns)}
      <% else %>
        {browse_body(assigns)}
      <% end %>

      <.upload_modal :if={@modal_open?} uploads={@uploads} upload_error={@upload_error} />
    </.marketplace_shell>
    """
  end

  # ---- browse body (published themes from others) ----

  defp browse_body(assigns) do
    ~H"""
    <div>
      <div :if={@themes == []} class="empty-state">
        <img src={~p"/images/illustrations/empty-themes.svg"} alt="" class="empty-illustration" />
        <h2>Nothing here yet</h2>
        <p>
          {cond do
            @search != "" -> "No themes match \"#{@search}\"."
            @filter == :verified -> "No verified themes yet."
            @filter == :community -> "No community themes yet."
            true -> "No themes have been published to the marketplace yet."
          end}
        </p>
      </div>

      <ul :if={@themes != []} class="marketplace-grid">
        <li :for={t <- @themes} id={"marketplace-card-#{t.id}"}>
          <article class="marketplace-card">
            <div class="marketplace-thumb">
              <.link
                navigate={theme_path(t, @install_site)}
                class="marketplace-thumb-btn"
                aria-label={"View #{t.name}"}
              >
                <img
                  :if={first_image(t)}
                  src={Themes.image_url(first_image(t))}
                  alt={"#{t.name} preview"}
                />
                <img
                  :if={is_nil(first_image(t))}
                  class="marketplace-thumb-placeholder"
                  src={placeholder_image(t)}
                  alt=""
                  aria-hidden="true"
                  loading="lazy"
                />
                <span class="marketplace-thumb-zoom" aria-hidden="true">⤢</span>
              </.link>
              <div class="marketplace-card-tags">
                <.theme_badge theme={t} />
                <span class="chip chip-accent theme-card-version">v{t.version}</span>
              </div>
            </div>
            <div class="marketplace-card-meta">
              <div class="marketplace-card-id">
                <h3><.link navigate={theme_path(t, @install_site)}>{t.name}</.link></h3>
                <p :if={t.description not in [nil, ""]} class="marketplace-card-desc">
                  {t.description}
                </p>
              </div>
              <div class="marketplace-card-actions">
                <.install_button theme={t} installed={@installed} install_site={@install_site} />
              </div>
            </div>
          </article>
        </li>
      </ul>
    </div>
    """
  end

  # ---- my themes body (the user's library + management) ----

  defp my_themes_body(assigns) do
    ~H"""
    <div>
      <div :if={@themes == [] and @search != ""} class="empty-state">
        <img src={~p"/images/illustrations/empty-themes.svg"} alt="" class="empty-illustration" />
        <h2>Nothing here yet</h2>
        <p>No themes match "{@search}".</p>
      </div>

      <div :if={@themes == [] and @search == ""} class="empty-state">
        <img src={~p"/images/illustrations/empty-themes.svg"} alt="" class="empty-illustration" />
        <h2>No themes yet</h2>
        <p>Upload a Liquid theme package to get started.</p>
        <button type="button" phx-click="open_modal" class="btn btn-primary">+ Upload theme</button>
      </div>

      <ul :if={@themes != []} class="marketplace-grid">
        <li :for={t <- @themes} id={"theme-card-#{t.id}"}>
          <article class="marketplace-card">
            <div class="marketplace-thumb">
              <.link
                navigate={theme_path(t, @install_site)}
                class="marketplace-thumb-btn"
                aria-label={"View #{t.name}"}
              >
                <img
                  :if={first_image(t)}
                  src={Themes.image_url(first_image(t))}
                  alt={"#{t.name} preview"}
                />
                <img
                  :if={is_nil(first_image(t))}
                  class="marketplace-thumb-placeholder"
                  src={placeholder_image(t)}
                  alt=""
                  aria-hidden="true"
                  loading="lazy"
                />
                <span class="marketplace-thumb-zoom" aria-hidden="true">⤢</span>
              </.link>
              <div class="marketplace-card-tags">
                <.theme_status theme={t} />
                <span class="chip chip-accent theme-card-version">v{t.version}</span>
              </div>
            </div>
            <div class="marketplace-card-meta">
              <div class="marketplace-card-id">
                <h3><.link navigate={theme_path(t, @install_site)}>{t.name}</.link></h3>
                <p :if={t.description not in [nil, ""]} class="marketplace-card-desc">
                  {t.description}
                </p>
              </div>
              <div class="marketplace-card-actions">
                <.install_button theme={t} installed={@installed} install_site={@install_site} />
              </div>
            </div>
          </article>
        </li>

        <li>
          <button type="button" phx-click="open_modal" class="marketplace-card marketplace-card-add">
            <span class="marketplace-card-add-icon" aria-hidden="true">+</span>
            <span class="marketplace-card-add-label">Upload theme</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # ---- modals & icons (function components) ----

  defp upload_modal(assigns) do
    ~H"""
    <div class="dialog-backdrop" phx-window-keydown="close_modal" phx-key="Escape">
      <button
        type="button"
        phx-click="close_modal"
        class="dialog-close-overlay"
        aria-label="Close"
        tabindex="-1"
      >
      </button>
      <div class="dialog">
        <header class="dialog-header">
          <h2>Upload theme</h2>
          <button type="button" phx-click="close_modal" class="dialog-close" aria-label="Close">
            &times;
          </button>
        </header>

        <form id="theme-upload-form" phx-submit="upload" phx-change="validate" class="dialog-form">
          <label class="dropzone" phx-drop-target={@uploads.theme_zip.ref}>
            <svg
              class="dropzone-icon"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.5"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 7.5m0 0L7.5 12m4.5-4.5v12"
              />
            </svg>
            <.live_file_input upload={@uploads.theme_zip} />
            <p class="dropzone-headline">Drop a theme .zip here, or click to browse</p>
            <p class="muted">Up to 5 MB. Must contain a manifest, templates, and theme.css.</p>
          </label>

          <ul :if={@uploads.theme_zip.entries != []} class="upload-entries">
            <li :for={entry <- @uploads.theme_zip.entries}>
              <span class="entry-name">{entry.client_name}</span>
              <span class="muted entry-progress">{entry.progress}%</span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="btn btn-sm"
              >
                Remove
              </button>
              <p :for={err <- upload_errors(@uploads.theme_zip, entry)} class="error entry-error">
                {error_to_string(err)}
              </p>
            </li>
          </ul>

          <p :for={err <- upload_errors(@uploads.theme_zip)} class="error">
            {error_to_string(err)}
          </p>
          <p :if={@upload_error} class="error">{@upload_error}</p>

          <footer class="dialog-footer">
            <button type="button" phx-click="close_modal" class="btn">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@uploads.theme_zip.entries == []}>
              Install
            </button>
          </footer>
        </form>
      </div>
    </div>
    """
  end
end

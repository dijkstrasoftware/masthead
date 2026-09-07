defmodule MastheadWeb.AdminLive.ThemeShow do
  @moduledoc """
  A theme's detail page: its description and preview gallery, plus the
  install panel. Reached from any marketplace card. Public themes are
  visible to everyone; private ones only to their author (or a platform
  admin).

  Installing happens here instead of in a modal — the sidebar picks the
  target site with a filterable dropdown, preselected from the marketplace's
  `?for=<site-slug>` context when there is one.

  The author edits the listing in place on this same page: a pencil on the
  description, an "add" tile at the end of the preview strip, and drag to
  reorder. Every editing event re-checks ownership — the markup is hidden
  for everyone else, but hidden markup isn't a permission check.
  """
  use MastheadWeb, :live_view

  import MastheadWeb.AdminLive.Components
  alias Masthead.Sites
  alias Masthead.Themes
  alias Masthead.Themes.ThemeLink

  @max_image_bytes 8 * 1024 * 1024

  @impl true
  def mount(%{"theme_id" => id}, _session, socket) do
    theme = Themes.get_theme!(id) |> Masthead.Repo.preload(:owner)
    user = socket.assigns.current_user

    if visible?(theme, user) do
      {:ok,
       socket
       |> assign(
         page_title: theme.name,
         theme: theme,
         images: Themes.list_theme_images(theme.id),
         links: Themes.list_theme_links(theme.id),
         link_form: to_form(Themes.change_theme_link()),
         adding_link?: false,
         author: author(theme),
         index: 0,
         sites: sites_for(user),
         site: nil,
         installed?: false,
         query: "",
         open?: false,
         editable?: editable?(theme, user),
         editing?: false,
         managing?: false,
         description_form: to_form(Themes.change_details(theme)),
         upload_error: nil
       )
       |> allow_upload(:preview,
         accept: ~w(.png .jpg .jpeg .gif .webp),
         max_entries: 8,
         max_file_size: @max_image_bytes,
         auto_upload: true,
         progress: &save_preview/3
       )}
    else
      {:ok, socket |> put_flash(:error, "Theme not found.") |> redirect(to: ~p"/marketplace")}
    end
  rescue
    Ecto.NoResultsError ->
      {:ok, socket |> put_flash(:error, "Theme not found.") |> redirect(to: ~p"/marketplace")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, select_site(socket, params["for"])}
  end

  # ---- gallery ----

  @impl true
  def handle_event("show_image", %{"index" => index}, socket) do
    {:noreply, assign(socket, index: String.to_integer(index))}
  end

  def handle_event("gallery_key", %{"key" => key}, socket) do
    {:noreply, assign(socket, index: step_index(socket.assigns, key))}
  end

  # ---- install ----

  def handle_event("filter_sites", %{"site" => query}, socket) do
    {:noreply, assign(socket, query: query, open?: true)}
  end

  def handle_event("open_sites", _params, socket) do
    {:noreply, assign(socket, query: "", open?: true)}
  end

  def handle_event("close_sites", _params, socket) do
    {:noreply, assign(socket, open?: false)}
  end

  def handle_event("pick_site", %{"site" => slug}, socket) do
    {:noreply, socket |> select_site(slug) |> assign(open?: false)}
  end

  def handle_event("install", _params, socket) do
    %{theme: theme, site: site} = socket.assigns

    case site && Themes.install_theme(site, theme) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(installed?: true)
         |> push_event("celebrate", %{from: ".install-card"})
         |> put_flash(:info, "\"#{theme.name}\" installed on #{site.name}.")}

      {:error, :not_installable} ->
        {:noreply, put_flash(socket, :error, "That theme can't be installed on that site.")}

      nil ->
        {:noreply, put_flash(socket, :error, "Pick a site to install onto first.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not install that theme.")}
    end
  end

  def handle_event("uninstall", _params, socket) do
    %{theme: theme, site: site} = socket.assigns

    case site && Themes.uninstall_theme(site, theme.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(installed?: false)
         |> put_flash(:info, "\"#{theme.name}\" removed from #{site.name}.")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(socket, :error, "That theme is active on the site — pick another first.")}

      _ ->
        {:noreply, socket}
    end
  end

  # ---- inline editing (author only) ----

  def handle_event("edit_description", _params, socket) do
    {:noreply, assign(socket, editing?: socket.assigns.editable?)}
  end

  def handle_event("cancel_description", _params, socket) do
    form = to_form(Themes.change_details(socket.assigns.theme))
    {:noreply, assign(socket, editing?: false, description_form: form)}
  end

  def handle_event("validate_description", %{"theme" => params}, socket) do
    form = to_form(Themes.change_details(socket.assigns.theme, params), action: :validate)
    {:noreply, assign(socket, description_form: form)}
  end

  def handle_event("save_description", %{"theme" => params}, socket) do
    case editable(socket) && Themes.update_details(socket.assigns.theme, params) do
      {:ok, theme} ->
        {:noreply,
         socket
         |> assign(
           theme: theme,
           editing?: false,
           description_form: to_form(Themes.change_details(theme))
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, description_form: to_form(changeset, action: :validate))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_preview", _params, socket) do
    {:noreply, assign(socket, upload_error: nil)}
  end

  def handle_event("cancel_preview", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :preview, ref)}
  end

  def handle_event("remove_preview", %{"id" => id}, socket) do
    image = Enum.find(socket.assigns.images, &(to_string(&1.id) == id))

    if image && editable(socket) do
      {:ok, _} = Themes.delete_theme_image(image)

      {:noreply,
       socket
       |> assign(images: Themes.list_theme_images(socket.assigns.theme.id), index: 0)
       |> put_flash(:info, "Image removed.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_previews", %{"ids" => ids}, socket) do
    theme = socket.assigns.theme

    if editable(socket) do
      Themes.reorder_theme_images(theme.id, Enum.map(ids, &String.to_integer/1))

      {:noreply,
       socket
       |> assign(images: Themes.list_theme_images(theme.id), index: 0)
       |> put_flash(:info, "Image order saved.")}
    else
      {:noreply, socket}
    end
  end

  # ---- listing links (author only) ----

  def handle_event("add_link", _params, socket) do
    {:noreply, assign(socket, adding_link?: socket.assigns.editable?)}
  end

  def handle_event("cancel_link", _params, socket) do
    {:noreply,
     assign(socket, adding_link?: false, link_form: to_form(Themes.change_theme_link()))}
  end

  def handle_event("validate_link", %{"theme_link" => params}, socket) do
    form = to_form(Themes.change_theme_link(%ThemeLink{}, params), action: :validate)
    {:noreply, assign(socket, link_form: form)}
  end

  def handle_event("save_link", %{"theme_link" => params}, socket) do
    theme = socket.assigns.theme

    case editable(socket) && Themes.add_theme_link(theme, params) do
      {:ok, _link} ->
        {:noreply,
         socket
         |> assign(
           links: Themes.list_theme_links(theme.id),
           adding_link?: false,
           link_form: to_form(Themes.change_theme_link())
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, link_form: to_form(changeset, action: :validate))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_link", %{"id" => id}, socket) do
    link = Enum.find(socket.assigns.links, &(to_string(&1.id) == id))

    if link && editable(socket) do
      {:ok, _} = Themes.delete_theme_link(link)
      {:noreply, assign(socket, links: Themes.list_theme_links(socket.assigns.theme.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_links", %{"ids" => ids}, socket) do
    theme = socket.assigns.theme

    if editable(socket) do
      Themes.reorder_theme_links(theme.id, Enum.map(ids, &String.to_integer/1))

      {:noreply,
       socket
       |> assign(links: Themes.list_theme_links(theme.id))
       |> put_flash(:info, "Link order saved.")}
    else
      {:noreply, socket}
    end
  end

  # ---- listing visibility & deletion (author only) ----

  def handle_event("open_manage", _params, socket) do
    {:noreply, assign(socket, managing?: socket.assigns.editable?)}
  end

  def handle_event("close_manage", _params, socket) do
    {:noreply, assign(socket, managing?: false)}
  end

  def handle_event("publish", _params, socket) do
    case editable(socket) && Themes.publish_theme(socket.assigns.theme) do
      {:ok, theme} ->
        {:noreply,
         socket
         |> assign(theme: theme)
         |> put_flash(:info, "\"#{theme.name}\" is live on the marketplace.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("unpublish", _params, socket) do
    case editable(socket) && Themes.unpublish_theme(socket.assigns.theme) do
      {:ok, theme} ->
        {:noreply,
         socket
         |> assign(theme: theme)
         |> put_flash(:info, "\"#{theme.name}\" is private again.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete", _params, socket) do
    theme = socket.assigns.theme

    case editable(socket) && Themes.delete_theme(theme) do
      {:ok, _} ->
        Themes.Loader.invalidate(theme.id)

        {:noreply,
         socket
         |> put_flash(:info, "Theme deleted.")
         |> redirect(to: ~p"/marketplace/my-themes")}

      {:error, {:in_use, names}} ->
        {:noreply, put_flash(socket, :error, theme_in_use_message(names))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not delete theme.")}
    end
  end

  defp theme_in_use_message(names) do
    count = length(names)
    site_word = if count == 1, do: "site", else: "sites"

    "Can't delete this theme — it's still installed on #{count} #{site_word}: " <>
      "#{Enum.join(names, ", ")}. Remove it there first."
  end

  defp error_to_string(:too_large), do: "That image is larger than 8 MB."
  defp error_to_string(:not_accepted), do: "Only PNG, JPG, GIF or WebP images."
  defp error_to_string(:too_many_files), do: "Up to 8 images."
  defp error_to_string(err), do: inspect(err)

  # auto_upload consumes each file as it finishes, so the strip fills in as
  # the images land — no separate "add" submit.
  defp save_preview(:preview, entry, socket) do
    theme = socket.assigns.theme

    if entry.done? and editable(socket) do
      consume_uploaded_entry(socket, entry, &add_image(&1, theme, entry))
      {:noreply, assign(socket, images: Themes.list_theme_images(theme.id), upload_error: nil)}
    else
      {:noreply, socket}
    end
  end

  defp add_image(%{path: path}, theme, entry) do
    Themes.add_theme_image(theme, %{filename: entry.client_name, path: path})
    {:ok, :ok}
  end

  # Arrow keys walk the gallery from anywhere on the page, wrapping at both
  # ends — except while a text field is open, where the arrows belong to the
  # caret. Those are the only places on this page you can be typing.
  defp step_index(%{index: index} = assigns, key) do
    if typing?(assigns), do: index, else: stepped(assigns, key)
  end

  defp typing?(%{editing?: editing?, open?: open?, adding_link?: adding_link?}),
    do: editing? or open? or adding_link?

  defp stepped(%{images: images, index: index}, "ArrowRight") when images != [],
    do: rem(index + 1, length(images))

  defp stepped(%{images: images, index: index}, "ArrowLeft") when images != [],
    do: rem(index + length(images) - 1, length(images))

  defp stepped(%{index: index}, _key), do: index

  defp editable(%{assigns: %{editable?: editable?}}), do: editable?

  # A published listing is public — that's the point of the marketplace. An
  # unpublished one is only its author's (or a platform admin's) to see.
  defp visible?(%{public: true}, _user), do: true
  defp visible?(_theme, nil), do: false
  defp visible?(theme, user), do: theme.owner_id == user.id or user.admin

  defp sites_for(nil), do: []
  defp sites_for(user), do: Sites.list_sites_for_user(user.id)

  # Built-ins are maintained by the platform, not editable from here.
  defp editable?(_theme, nil), do: false
  defp editable?(%{source: "uploaded"} = theme, user), do: theme.owner_id == user.id or user.admin
  defp editable?(_theme, _user), do: false

  # A slug that doesn't name one of the user's sites (an empty `?for=`, say)
  # leaves nothing selected.
  defp select_site(socket, slug) do
    site = Enum.find(socket.assigns.sites, &(&1.slug == slug))

    installed? =
      site && MapSet.member?(Themes.installed_theme_ids(site.id), socket.assigns.theme.id)

    assign(socket, site: site, installed?: !!installed?, query: "")
  end

  defp matching_sites(%{sites: sites, query: ""}), do: sites

  defp matching_sites(%{sites: sites, query: query}) do
    Enum.filter(
      sites,
      &String.contains?(String.downcase(&1.name <> &1.slug), String.downcase(query))
    )
  end

  defp active?(%{site: %{theme_id: id}, theme: %{id: id}}), do: true
  defp active?(_assigns), do: false

  # Built-ins have no owner — they're maintained by the platform.
  defp author(%{owner: %{} = owner}) do
    %{
      user: owner,
      handle: owner.display_name,
      joined: Calendar.strftime(owner.inserted_at, "%B %Y"),
      published: Themes.published_count(owner.id)
    }
  end

  defp author(_theme), do: nil

  # Blank-line-separated blocks become real paragraphs. Rendering the raw
  # string with `white-space: pre-wrap` would also preserve the template's
  # own indentation, which reads as a stray indent before the first word.
  defp paragraphs(nil), do: []

  defp paragraphs(text) do
    text |> String.trim() |> String.split(~r/\n\s*\n/, trim: true)
  end

  defp theme_count(1), do: "1 published theme"
  defp theme_count(count), do: "#{count} published themes"

  @impl true
  def render(assigns) do
    ~H"""
    <.marketplace_shell title={@theme.name} current_user={@current_user} flash={@flash}>
      <:title_meta>
        <span class="chip chip-accent theme-card-version">v{@theme.version}</span>
        <%!-- Public/private is the author's own bookkeeping — a visitor only
              ever reaches published listings, so the chip tells them nothing. --%>
        <.theme_status :if={@current_user} theme={@theme} />
        <.theme_badge theme={@theme} />
      </:title_meta>
      <:actions>
        <button :if={@editable?} type="button" phx-click="open_manage" class="btn btn-primary">
          Manage
        </button>
        <.link navigate={~p"/marketplace"} class="btn">← Back to marketplace</.link>
      </:actions>

      <div class="theme-detail">
        <div class="theme-detail-main">
          <figure class="theme-preview" phx-window-keydown="gallery_key">
            <figcaption class="theme-preview-chrome">
              <span class="theme-preview-dots" aria-hidden="true"><i></i><i></i><i></i></span>
              <span :if={@images != []} class="theme-preview-count">
                {@index + 1} of {length(@images)}
              </span>
            </figcaption>
            <div class={["theme-preview-stage", @images == [] && "is-empty"]}>
              <img
                :if={@images != []}
                src={Themes.image_url(Enum.at(@images, @index))}
                alt={"#{@theme.name} preview #{@index + 1}"}
              />
              <p :if={@images == []} class="theme-preview-empty">No preview images yet.</p>
            </div>
          </figure>

          <div :if={length(@images) > 1 or @editable?} class="theme-thumbs">
            <div
              :if={@images != []}
              id="theme-thumb-strip"
              class="theme-thumb-strip"
              phx-hook={@editable? && "SortableList"}
              data-sortable-event="reorder_previews"
              data-sortable-axis="x"
            >
              <div
                :for={{image, i} <- Enum.with_index(@images)}
                id={"thumb-#{image.id}"}
                class="theme-thumb-wrap"
                draggable={@editable? && "true"}
                data-sortable-id={image.id}
              >
                <button
                  type="button"
                  class={["theme-thumb", i == @index && "is-active"]}
                  phx-click="show_image"
                  phx-value-index={i}
                  aria-label={"Show preview #{i + 1}"}
                  aria-current={i == @index && "true"}
                >
                  <img src={Themes.image_url(image)} alt="" loading="lazy" />
                </button>
                <button
                  :if={@editable?}
                  type="button"
                  class="theme-thumb-remove"
                  phx-click="remove_preview"
                  phx-value-id={image.id}
                  data-confirm="Remove this image?"
                  aria-label={"Remove preview #{i + 1}"}
                >
                  &times;
                </button>
              </div>
            </div>

            <form :if={@editable?} id="preview-upload" phx-change="validate_preview">
              <label
                id="theme-thumb-add"
                class="theme-thumb-add"
                phx-hook="ImageCompress"
                phx-drop-target={@uploads.preview.ref}
              >
                <input type="file" multiple accept="image/*" class="js-image-picker" />
                <.live_file_input upload={@uploads.preview} />
                <span class="theme-thumb-add-icon" aria-hidden="true">+</span>
                <span class="theme-thumb-add-label">Add image</span>
              </label>
            </form>
          </div>

          <p :for={err <- upload_errors(@uploads.preview)} class="error">
            {error_to_string(err)}
          </p>
          <p :for={entry <- @uploads.preview.entries} class="muted theme-upload-progress">
            {entry.client_name} — {entry.progress}%
            <span :for={err <- upload_errors(@uploads.preview, entry)} class="error">
              {error_to_string(err)}
            </span>
          </p>

          <section class="theme-about">
            <div class="theme-about-head">
              <h2>About this theme</h2>
              <button
                :if={@editable? and not @editing?}
                type="button"
                class="card-icon-btn"
                phx-click="edit_description"
                title="Edit description"
                aria-label="Edit description"
              >
                <.pencil_icon />
              </button>
            </div>

            <.form
              :if={@editing?}
              for={@description_form}
              phx-change="validate_description"
              phx-submit="save_description"
              class="theme-about-form"
            >
              <textarea
                id={@description_form[:description].id}
                name={@description_form[:description].name}
                rows="4"
                placeholder="Describe your theme — who it's for, what it looks like…"
              >{Phoenix.HTML.Form.normalize_value("textarea", @description_form[:description].value)}</textarea>
              <p :for={{msg, _} <- @description_form[:description].errors} class="error">{msg}</p>
              <div class="theme-about-actions">
                <button type="button" class="btn btn-sm" phx-click="cancel_description">
                  Cancel
                </button>
                <button type="submit" class="btn btn-sm btn-primary">Save description</button>
              </div>
            </.form>

            <p :for={para <- paragraphs(@theme.description)} :if={not @editing?}>{para}</p>
            <p :if={not @editing? and @theme.description in [nil, ""]} class="muted">
              {if @editable?,
                do: "No description yet — add one so people know what this theme is for.",
                else: "This theme doesn't have a description yet."}
            </p>
          </section>
        </div>

        <aside class="theme-detail-aside">
          <section class="install-card">
            <h2>Install this theme</h2>
            <p :if={is_nil(@current_user)} class="muted">
              Themes install onto a Masthead site
            </p>
            <.link :if={is_nil(@current_user)} href={~p"/signup"} class="btn btn-primary btn-block">
              Create your site
            </.link>
            <p :if={is_nil(@current_user)} class="install-card-next">
              Already have one? <.link href={~p"/login"}>Log in</.link>
            </p>
            <p :if={@current_user && @sites == []} class="muted">
              You don't have any sites yet. <.link navigate={~p"/sites"}>Create one</.link> first.
            </p>

            <div :if={@sites != []} class="site-select" phx-click-away="close_sites">
              <form phx-change="filter_sites" autocomplete="off">
                <input
                  type="text"
                  id="install-site"
                  name="site"
                  class={["site-select-input", @open? && "is-open"]}
                  aria-label="Site to install this theme on"
                  value={if @open?, do: @query, else: @site && @site.name}
                  placeholder={if @site, do: @site.name, else: "Choose a site…"}
                  role="combobox"
                  aria-expanded={to_string(@open?)}
                  aria-controls="install-site-menu"
                  phx-focus="open_sites"
                  phx-debounce="150"
                  phx-window-keydown="close_sites"
                  phx-key="Escape"
                />
              </form>

              <ul :if={@open?} id="install-site-menu" class="site-select-menu" role="listbox">
                <li :for={site <- matching_sites(assigns)}>
                  <button
                    type="button"
                    class={["site-select-option", @site && @site.id == site.id && "is-selected"]}
                    role="option"
                    aria-selected={to_string(!!(@site && @site.id == site.id))}
                    phx-click="pick_site"
                    phx-value-site={site.slug}
                  >
                    <span class="site-select-name">{site.name}</span>
                    <span class="site-select-slug">{site.slug}</span>
                  </button>
                </li>
                <li :if={matching_sites(assigns) == []} class="site-select-empty">
                  No sites match "{@query}".
                </li>
              </ul>
            </div>

            <button
              :if={@sites != [] and not @installed?}
              type="button"
              phx-click="install"
              class="btn btn-primary btn-block"
              disabled={is_nil(@site)}
            >
              Install on this site
            </button>

            <button
              :if={@installed?}
              type="button"
              phx-click="uninstall"
              class="btn btn-block btn-installed"
              disabled={active?(assigns)}
            >
              {if active?(assigns), do: "Active theme", else: "Installed — remove"}
            </button>

            <p :if={@installed?} class="install-card-next">
              <.link navigate={~p"/#{@site.slug}/theme"}>
                Go to {@site.name}'s theme page →
              </.link>
            </p>
          </section>

          <section class="author-card">
            <div class="author-identity">
              <.user_avatar :if={@author} user={@author.user} class="author-avatar" />
              <span :if={is_nil(@author)} class="author-avatar" aria-hidden="true">M</span>
              <div class="author-lines">
                <.link
                  :if={@author}
                  navigate={~p"/marketplace?#{[author: @author.handle]}"}
                  class="author-name"
                >
                  {@author.handle}
                </.link>
                <span :if={is_nil(@author)} class="author-name">Masthead</span>
                <span :if={@author} class="author-meta">Member since {@author.joined}</span>
                <span :if={@author} class="author-meta">{theme_count(@author.published)}</span>
                <span :if={is_nil(@author)} class="author-meta">Built-in theme</span>
              </div>
            </div>

            <div :if={@links != [] or @editable?} class="author-links">
              <ul
                :if={@links != []}
                id="theme-links"
                class="theme-links"
                phx-hook={@editable? && "SortableList"}
                data-sortable-event="reorder_links"
              >
                <li
                  :for={link <- @links}
                  id={"theme-link-#{link.id}"}
                  class="theme-link"
                  draggable={@editable? && "true"}
                  data-sortable-id={link.id}
                >
                  <a href={link.url} target="_blank" rel="noopener noreferrer">{link.label}</a>
                  <button
                    :if={@editable?}
                    type="button"
                    class="theme-link-remove"
                    phx-click="remove_link"
                    phx-value-id={link.id}
                    data-confirm={"Remove the \"#{link.label}\" link?"}
                    aria-label={"Remove #{link.label}"}
                  >
                    &times;
                  </button>
                </li>
              </ul>

              <p :if={@links == [] and not @adding_link?} class="muted author-links-empty">
                Point people at your docs, source or support address.
              </p>

              <.form
                :if={@adding_link?}
                for={@link_form}
                phx-change="validate_link"
                phx-submit="save_link"
                class="link-form"
              >
                <input
                  type="text"
                  id={@link_form[:label].id}
                  name={@link_form[:label].name}
                  value={Phoenix.HTML.Form.normalize_value("text", @link_form[:label].value)}
                  placeholder="Label — Documentation, Support…"
                />
                <p
                  :for={{msg, _} <- @link_form[:label].errors}
                  :if={used_input?(@link_form[:label])}
                  class="error"
                >
                  {msg}
                </p>
                <input
                  type="text"
                  id={@link_form[:url].id}
                  name={@link_form[:url].name}
                  value={Phoenix.HTML.Form.normalize_value("text", @link_form[:url].value)}
                  placeholder="example.com/docs"
                />
                <p
                  :for={{msg, _} <- @link_form[:url].errors}
                  :if={used_input?(@link_form[:url])}
                  class="error"
                >
                  {msg}
                </p>
                <div class="link-form-actions">
                  <button type="button" class="btn btn-sm" phx-click="cancel_link">Cancel</button>
                  <button type="submit" class="btn btn-sm btn-primary">Add link</button>
                </div>
              </.form>

              <button
                :if={@editable? and not @adding_link?}
                type="button"
                class="author-add-link"
                phx-click="add_link"
              >
                + Add link
              </button>
            </div>
          </section>
        </aside>
      </div>

      <.manage_dialog :if={@managing?} theme={@theme} />
    </.marketplace_shell>
    """
  end

  # Visibility and deletion, out of the reading flow and behind one button —
  # they're the author's chrome, not part of the listing.
  attr :theme, :map, required: true

  defp manage_dialog(assigns) do
    ~H"""
    <div class="dialog-backdrop" phx-window-keydown="close_manage" phx-key="Escape">
      <button
        type="button"
        phx-click="close_manage"
        class="dialog-close-overlay"
        aria-label="Close"
        tabindex="-1"
      >
      </button>
      <div class="dialog">
        <header class="dialog-header">
          <h2>Manage theme</h2>
          <button type="button" phx-click="close_manage" class="dialog-close" aria-label="Close">
            &times;
          </button>
        </header>

        <div class="dialog-body">
          <section class="manage-row">
            <div>
              <h3>Visibility</h3>
              <p>
                {if @theme.public,
                  do: "Public — anyone can find and install this theme.",
                  else: "Private — only you can install it, on your own sites."}
              </p>
            </div>
            <button :if={not @theme.public} type="button" phx-click="publish" class="btn">
              Make public
            </button>
            <button :if={@theme.public} type="button" phx-click="unpublish" class="btn">
              Make private
            </button>
          </section>

          <section class="manage-row is-danger">
            <div>
              <h3>Delete theme</h3>
              <p>
                Removes the theme, its previews and its links for good. A theme installed
                on a site has to be removed there first.
              </p>
            </div>
            <button
              type="button"
              phx-click="delete"
              class="btn btn-danger"
              data-confirm={"Delete \"#{@theme.name}\"? This can't be undone."}
            >
              Delete
            </button>
          </section>
        </div>

        <footer class="dialog-footer">
          <button type="button" phx-click="close_manage" class="btn">Done</button>
        </footer>
      </div>
    </div>
    """
  end
end

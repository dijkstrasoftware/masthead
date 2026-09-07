defmodule MastheadWeb.AdminLive.SiteIndex do
  use MastheadWeb, :live_view
  import MastheadWeb.AdminLive.Components
  alias Masthead.Licenses
  alias Masthead.Sites
  alias Masthead.Sites.Site

  @impl true
  def mount(_params, _session, socket) do
    sites = Sites.list_sites_for_user(socket.assigns.current_user.id)
    changeset = Sites.change_site(%Site{})

    {:ok,
     socket
     |> assign(
       sites: sites,
       page_title: "Your sites",
       host: site_host(),
       modal_open?: false,
       show_errors: false,
       slug_edited?: false
     )
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(modal_open?: true, show_errors: false, slug_edited?: false)
     |> assign_form(Sites.change_site(%Site{}))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: false, show_errors: false)}
  end

  def handle_event("validate", %{"site" => params}, socket) do
    # Auto-derive the slug from the name until the user edits the slug field
    # directly, after which we leave their value alone.
    prev_slug = socket.assigns.form[:slug].value || ""
    incoming_slug = params["slug"] || ""

    slug_edited? =
      socket.assigns.slug_edited? or (incoming_slug != "" and incoming_slug != prev_slug)

    params =
      if slug_edited?,
        do: params,
        else: Map.put(params, "slug", slugify(params["name"] || ""))

    changeset =
      %Site{}
      |> Sites.change_site(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(slug_edited?: slug_edited?)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"site" => params}, socket) do
    params = Map.put(params, "title", params["name"])

    case Sites.create_site(params, socket.assigns.current_user) do
      {:ok, site} ->
        {:noreply, push_navigate(socket, to: ~p"/#{site.slug}")}

      {:error, changeset} ->
        {:noreply, socket |> assign(show_errors: true) |> assign_form(changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :site), changeset: changeset)
  end

  # Turn a free-form name into a valid slug: lowercase, non-alphanumeric runs
  # collapsed to hyphens, trimmed, capped at the schema's 32-char limit.
  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 32)
    |> String.trim("-")
  end

  defp site_host do
    cfg = Application.get_env(:masthead, :site_url, [])
    host = Keyword.get(cfg, :host, "lvh.me")
    port = Keyword.get(cfg, :port)
    scheme = Keyword.get(cfg, :scheme, "http")

    suffix =
      cond do
        is_nil(port) -> ""
        scheme == "http" and port == 80 -> ""
        scheme == "https" and port == 443 -> ""
        true -> ":#{port}"
      end

    "#{host}#{suffix}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell title="Your sites" current_user={@current_user} flash={@flash} active={:sites}>
      <:actions>
        <button type="button" phx-click="open_modal" class="btn btn-primary btn-add">
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New site</span>
        </button>
      </:actions>

      <ul :if={@sites != []} class="card-list">
        <li :for={s <- @sites}>
          <span class={"pill card-pill " <> Licenses.pill_class(s)}>{Licenses.chip(s)}</span>
          <.link navigate={~p"/#{s.slug}"}>
            <strong>{s.name}</strong>
            <span class="muted">{s.slug}.{@host}</span>
          </.link>
        </li>
      </ul>

      <div :if={@sites == []} class="empty-state empty-state-illustrated">
        <img src={~p"/images/illustrations/empty-sites.svg"} alt="" class="empty-illustration" />
        <h2>No sites yet</h2>
        <p>
          Each site is a separate brand or product on its own subdomain. Create your first one to start publishing.
        </p>
        <button type="button" phx-click="open_modal" class="btn btn-primary">+ New site</button>
      </div>

      <div
        :if={@modal_open?}
        class="dialog-backdrop"
        phx-window-keydown="close_modal"
        phx-key="Escape"
      >
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
            <h2>Create a new site</h2>
            <button type="button" phx-click="close_modal" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <.form
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="dialog-form"
            id="new-site-form"
          >
            <div class="dialog-scroll">
              <.error_list changeset={@changeset} show={@show_errors} />

              <label>Name</label>
              <small>Shown in nav and as default page title.</small>
              <input type="text" name="site[name]" value={@form[:name].value} required autofocus />

              <label>Slug (subdomain)</label>
              <input type="text" name="site[slug]" value={@form[:slug].value} required />
              <small>
                Public URL: <code>{(@form[:slug].value || "your-slug") <> "." <> @host}</code>
              </small>
            </div>

            <footer class="dialog-footer">
              <button type="button" phx-click="close_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Create site</button>
            </footer>
          </.form>
        </div>
      </div>
    </.shell>
    """
  end
end

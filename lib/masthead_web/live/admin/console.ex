defmodule MastheadWeb.AdminLive.Console do
  @moduledoc "Platform-admin overview: manage all users, sites, and themes."
  use MastheadWeb, :live_view

  import MastheadWeb.AdminLive.Components

  alias Masthead.{Accounts, Actions, Licenses, Sites, Themes}

  @default_filters %{users: :all, sites: :enabled, themes: :public}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Admin",
       tab: :users,
       action_modal?: false,
       action_site: nil,
       gift_modal?: false,
       gift_site: nil,
       open_menu: nil,
       users_filter: @default_filters.users,
       users_search: "",
       users_sort: nil,
       sites_filter: @default_filters.sites,
       sites_search: "",
       sites_sort: nil,
       themes_filter: @default_filters.themes,
       themes_search: "",
       themes_sort: nil
     )}
  end

  # Tab and filter live in the URL (`/admin/:tab/:filter` or `?filter=`),
  # so views are shareable. Unknown values fall back to the defaults.
  @impl true
  def handle_params(params, _uri, socket) do
    tab = parse_tab(params)
    socket = assign(socket, tab: tab)

    socket =
      case parse_filter(tab, params) do
        nil -> socket
        filter -> assign(socket, :"#{tab}_filter", filter)
      end

    {:noreply, load_data(socket)}
  end

  defp parse_tab(%{"tab" => tab}) when tab in ~w(users sites themes),
    do: String.to_existing_atom(tab)

  defp parse_tab(_params), do: :users

  defp parse_filter(tab, %{"filter" => filter}) do
    Enum.find_value(filter_options(tab), fn {value, _label} ->
      if Atom.to_string(value) == filter, do: value
    end)
  end

  defp parse_filter(_tab, _params), do: nil

  # Always include the filter segment: a bare `/admin/:tab` keeps whatever
  # filter is currently assigned, so e.g. "All" must link to `/users/all`
  # explicitly to reset it.
  defp admin_path(tab, filter), do: ~p"/admin/#{tab}/#{filter}"

  # Filter buttons offered per tab. The atoms match the context
  # `apply_filter/2` clauses; this list also whitelists the `:filter`
  # URL param in `parse_filter/2`.
  defp filter_options(:users),
    do: [
      {:all, "All"},
      {:verified, "Verified"},
      {:unverified, "Unverified"},
      {:disabled, "Disabled"},
      {:admins, "Admins"}
    ]

  defp filter_options(:sites),
    do: [
      {:enabled, "Enabled"},
      {:disabled, "Disabled"},
      {:deleted, "Deleted"},
      {:paid, "Paid"},
      {:free, "Free"}
    ]

  defp filter_options(:themes),
    do: [
      {:public, "Public"},
      {:private, "Private"},
      {:built_in, "Built-in"}
    ]

  # Each tab shows at most this many rows; the overview is meant to be
  # narrowed with the filter + search, not paged through. The toolbar warns
  # when a list hits the cap so a hidden match doesn't read as "none".
  defp list_limit, do: 20

  defp load_data(%{assigns: a} = socket) do
    assign(socket,
      users: Accounts.list_all_users(a.users_filter, a.users_search, list_limit(), a.users_sort),
      users_total: Accounts.count_all_users(a.users_filter, a.users_search),
      sites: Sites.list_all_sites(a.sites_filter, a.sites_search, list_limit(), a.sites_sort),
      sites_total: Sites.count_all_sites(a.sites_filter, a.sites_search),
      themes:
        Themes.list_all_themes(a.themes_filter, a.themes_search, list_limit(), a.themes_sort),
      themes_total: Themes.count_all_themes(a.themes_filter, a.themes_search)
    )
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ~w(users sites themes) do
    tab = String.to_existing_atom(tab)
    {:noreply, push_patch(socket, to: admin_path(tab, socket.assigns[:"#{tab}_filter"]))}
  end

  def handle_event("sort_list", %{"scope" => scope, "field" => field}, socket) do
    sort = toggle_sort(socket.assigns[:"#{scope}_sort"], field)
    {:noreply, socket |> assign(:"#{scope}_sort", sort) |> load_data()}
  end

  # ---- users ----

  def handle_event("verify_user", %{"id" => id}, socket) do
    {:ok, _} = id |> Accounts.get_user!() |> Accounts.verify_user()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "User verified.") |> load_data()}
  end

  def handle_event("disable_user", %{"id" => id}, socket) do
    {:ok, _} = id |> Accounts.get_user!() |> Accounts.disable_user()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "User disabled.") |> load_data()}
  end

  def handle_event("enable_user", %{"id" => id}, socket) do
    {:ok, _} = id |> Accounts.get_user!() |> Accounts.enable_user()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "User re-enabled.") |> load_data()}
  end

  # ---- sites ----

  def handle_event("disable_site", %{"id" => id}, socket) do
    {:ok, _} = id |> Sites.get_site!() |> Sites.disable_site()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "Site disabled.") |> load_data()}
  end

  def handle_event("enable_site", %{"id" => id}, socket) do
    {:ok, _} = id |> Sites.get_site!() |> Sites.enable_site()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "Site enabled.") |> load_data()}
  end

  def handle_event("delete_site", %{"id" => id}, socket) do
    {:ok, _} = id |> Sites.get_site!() |> Sites.soft_delete_site()

    {:noreply,
     socket
     |> assign(open_menu: nil)
     |> put_flash(:info, "Site deleted (recoverable).")
     |> load_data()}
  end

  def handle_event("restore_site", %{"id" => id}, socket) do
    {:ok, _} = id |> Sites.get_site!() |> Sites.restore_site()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "Site restored.") |> load_data()}
  end

  def handle_event("toggle_menu", %{"id" => id}, socket) do
    id = String.to_integer(id)
    open = if socket.assigns.open_menu == id, do: nil, else: id
    {:noreply, assign(socket, open_menu: open)}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, open_menu: nil)}
  end

  def handle_event("open_gift_modal", %{"site_id" => id}, socket) do
    {:noreply, assign(socket, gift_modal?: true, gift_site: Sites.get_site!(id), open_menu: nil)}
  end

  def handle_event("close_gift_modal", _params, socket) do
    {:noreply, assign(socket, gift_modal?: false, gift_site: nil)}
  end

  def handle_event("gift_pro", %{"months" => months}, socket) do
    site = socket.assigns.gift_site

    case Integer.parse(months) do
      {months, ""} when months > 0 and months <= 120 ->
        {:ok, site} = Licenses.gift(site, months)

        {:noreply,
         socket
         |> assign(gift_modal?: false, gift_site: nil)
         |> put_flash(:info, "#{site.name} is licensed until #{gift_date(site)}.")
         |> load_data()}

      _ ->
        {:noreply, put_flash(socket, :error, "Enter a whole number of months between 1 and 120.")}
    end
  end

  def handle_event("open_action_modal", %{"site_id" => id}, socket) do
    {:noreply,
     assign(socket, action_modal?: true, action_site: Sites.get_site!(id), open_menu: nil)}
  end

  def handle_event("close_action_modal", _params, socket) do
    {:noreply, assign(socket, action_modal?: false, action_site: nil)}
  end

  # ---- themes ----

  def handle_event("verify_theme", %{"id" => id}, socket) do
    {:ok, _} = id |> Themes.get_theme!() |> Themes.verify_theme()

    {:noreply,
     socket |> assign(open_menu: nil) |> put_flash(:info, "Theme verified.") |> load_data()}
  end

  def handle_event("unverify_theme", %{"id" => id}, socket) do
    {:ok, _} = id |> Themes.get_theme!() |> Themes.unverify_theme()

    {:noreply,
     socket
     |> assign(open_menu: nil)
     |> put_flash(:info, "Theme verification cleared.")
     |> load_data()}
  end

  # ---- filtering & search (users / sites / themes) ----

  def handle_event("switch_filter", %{"scope" => scope, "filter" => filter}, socket) do
    tab = parse_tab(%{"tab" => scope})
    filter = parse_filter(tab, %{"filter" => filter}) || @default_filters[tab]
    {:noreply, push_patch(socket, to: admin_path(tab, filter))}
  end

  def handle_event("search_list", %{"scope" => scope, "query" => query}, socket) do
    key = String.to_existing_atom("#{scope}_search")
    {:noreply, socket |> assign(key, query) |> load_data()}
  end

  def handle_event("create_action", %{"title" => title} = params, socket) do
    site = socket.assigns.action_site

    case Actions.create_custom_action(site, %{"title" => title, "message" => params["message"]}) do
      {:ok, _action} ->
        {:noreply,
         socket
         |> assign(action_modal?: false, action_site: nil)
         |> put_flash(:info, "Action added to #{site.name}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "A title is required.")}
    end
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <.shell title="Admin" current_user={@current_user} flash={@flash} active={:admin}>
      <div class="admin-tabs">
        <button
          :for={{id, label} <- [{:users, "Users"}, {:sites, "Sites"}, {:themes, "Themes"}]}
          type="button"
          phx-click="switch_tab"
          phx-value-tab={id}
          class={"admin-tab" <> if(@tab == id, do: " is-active", else: "")}
        >
          {label}
        </button>
      </div>

      <div :if={@tab == :users} class="admin-table-wrap">
        <.list_toolbar
          scope={:users}
          filter={@users_filter}
          options={filter_options(:users)}
          search={@users_search}
          placeholder="Search by email…"
          limit={list_limit()}
          truncated?={length(@users) == list_limit()}
          total={@users_total}
        />
        <table class="table table-menus">
          <thead>
            <tr>
              <.sort_th scope={:users} field={:email} sort={@users_sort}>Email</.sort_th>
              <.sort_th scope={:users} field={:confirmed_at} sort={@users_sort}>Status</.sort_th>
              <.sort_th scope={:users} field={:admin} sort={@users_sort}>Role</.sort_th>
              <.sort_th scope={:users} field={:inserted_at} sort={@users_sort}>Joined</.sort_th>
              <.sort_th scope={:users} field={:last_login_at} sort={@users_sort}>Last login</.sort_th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={u <- @users}>
              <td>{u.email}</td>
              <td>
                <span class={"pill " <> if(Accounts.User.confirmed?(u), do: "pill-ok", else: "pill-warn")}>
                  {if Accounts.User.confirmed?(u), do: "verified", else: "unverified"}
                </span>
                <span :if={Accounts.User.disabled?(u)} class="pill pill-danger">disabled</span>
              </td>
              <td>{if u.admin, do: "admin", else: "—"}</td>
              <td class="muted"><.relative_time at={u.inserted_at} /></td>
              <td class="muted">
                <.relative_time :if={u.last_login_at} at={u.last_login_at} />
                <span :if={is_nil(u.last_login_at)}>—</span>
              </td>
              <td class="admin-row-actions">
                <.row_menu id={u.id} open?={@open_menu == u.id} label={"Actions for #{u.email}"}>
                  <button
                    :if={not Accounts.User.confirmed?(u)}
                    type="button"
                    role="menuitem"
                    phx-click="verify_user"
                    phx-value-id={u.id}
                  >
                    Verify
                  </button>
                  <button
                    :if={not Accounts.User.disabled?(u)}
                    type="button"
                    role="menuitem"
                    class="is-danger"
                    phx-click="disable_user"
                    phx-value-id={u.id}
                    data-confirm={"Disable #{u.email}? Their sites stop resolving."}
                  >
                    Disable
                  </button>
                  <button
                    :if={Accounts.User.disabled?(u)}
                    type="button"
                    role="menuitem"
                    phx-click="enable_user"
                    phx-value-id={u.id}
                  >
                    Enable
                  </button>
                </.row_menu>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@tab == :sites} class="admin-table-wrap">
        <.list_toolbar
          scope={:sites}
          filter={@sites_filter}
          options={filter_options(:sites)}
          search={@sites_search}
          placeholder="Search by name…"
          limit={list_limit()}
          truncated?={length(@sites) == list_limit()}
          total={@sites_total}
        />
        <table class="table table-menus">
          <thead>
            <tr>
              <.sort_th scope={:sites} field={:name} sort={@sites_sort}>Name</.sort_th>
              <.sort_th scope={:sites} field={:slug} sort={@sites_sort}>Slug</.sort_th>
              <.sort_th scope={:sites} field={:inserted_at} sort={@sites_sort}>Created</.sort_th>
              <th>Status</th>
              <th>License</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @sites}>
              <td>{s.name}</td>
              <td class="muted">{s.slug}</td>
              <td class="muted"><.relative_time at={s.inserted_at} /></td>
              <td>
                <span :if={not is_nil(s.deleted_at)} class="pill pill-danger">deleted</span>
                <span
                  :if={is_nil(s.deleted_at) and not is_nil(s.disabled_at)}
                  class="pill pill-warn"
                >
                  disabled
                </span>
                <span :if={is_nil(s.deleted_at) and is_nil(s.disabled_at)} class="pill pill-ok">
                  active
                </span>
              </td>
              <td>
                <span class={["pill", Licenses.pill_class(s)]}>{Licenses.label(s)}</span>
              </td>
              <td class="admin-row-actions">
                <.row_menu id={s.id} open?={@open_menu == s.id} label={"Actions for #{s.name}"}>
                  <.link :if={is_nil(s.deleted_at)} navigate={~p"/#{s.slug}"} role="menuitem">
                    Enter site
                  </.link>
                  <button
                    type="button"
                    role="menuitem"
                    phx-click="open_action_modal"
                    phx-value-site_id={s.id}
                  >
                    Add action...
                  </button>
                  <button
                    type="button"
                    role="menuitem"
                    phx-click="open_gift_modal"
                    phx-value-site_id={s.id}
                  >
                    Gift Pro…
                  </button>

                  <hr />

                  <button
                    :if={is_nil(s.disabled_at) and is_nil(s.deleted_at)}
                    type="button"
                    role="menuitem"
                    phx-click="disable_site"
                    phx-value-id={s.id}
                  >
                    Disable
                  </button>
                  <button
                    :if={not is_nil(s.disabled_at) and is_nil(s.deleted_at)}
                    type="button"
                    role="menuitem"
                    phx-click="enable_site"
                    phx-value-id={s.id}
                  >
                    Enable
                  </button>
                  <button
                    :if={is_nil(s.deleted_at)}
                    type="button"
                    role="menuitem"
                    class="is-danger"
                    phx-click="delete_site"
                    phx-value-id={s.id}
                    data-confirm={"Delete #{s.name}? It's recoverable from here."}
                  >
                    Delete
                  </button>
                  <button
                    :if={not is_nil(s.deleted_at)}
                    type="button"
                    role="menuitem"
                    phx-click="restore_site"
                    phx-value-id={s.id}
                  >
                    Restore
                  </button>
                </.row_menu>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@tab == :themes} class="admin-table-wrap">
        <.list_toolbar
          scope={:themes}
          filter={@themes_filter}
          options={filter_options(:themes)}
          search={@themes_search}
          placeholder="Search by name…"
          limit={list_limit()}
          truncated?={length(@themes) == list_limit()}
          total={@themes_total}
        />
        <table class="table table-menus">
          <thead>
            <tr>
              <.sort_th scope={:themes} field={:name} sort={@themes_sort}>Name</.sort_th>
              <.sort_th scope={:themes} field={:slug} sort={@themes_sort}>Slug</.sort_th>
              <.sort_th scope={:themes} field={:version} sort={@themes_sort}>Version</.sort_th>
              <.sort_th scope={:themes} field={:source} sort={@themes_sort}>Source</.sort_th>
              <th>Status</th>
              <th>Owner</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={t <- @themes}>
              <td>{t.name}</td>
              <td class="muted">{t.slug}</td>
              <td class="muted">{t.version}</td>
              <td>{t.source}</td>
              <td>
                <span :if={t.verified} class="chip chip-verified">Verified</span>
                <span :if={t.public and not t.verified} class="muted">community</span>
                <span :if={t.source == "uploaded" and not t.public} class="muted">private</span>
                <span :if={t.source == "built_in"} class="muted">—</span>
              </td>
              <td class="muted">{(t.owner && t.owner.email) || "—"}</td>
              <td class="admin-row-actions">
                <.row_menu id={t.id} open?={@open_menu == t.id} label={"Actions for #{t.name}"}>
                  <button
                    :if={t.source == "uploaded" and not t.verified}
                    type="button"
                    role="menuitem"
                    phx-click="verify_theme"
                    phx-value-id={t.id}
                  >
                    Verify
                  </button>
                  <button
                    :if={t.source == "uploaded" and t.verified}
                    type="button"
                    role="menuitem"
                    phx-click="unverify_theme"
                    phx-value-id={t.id}
                  >
                    Unverify
                  </button>
                  <a
                    :if={t.source == "uploaded"}
                    href={~p"/admin/themes/#{t.id}/download"}
                    role="menuitem"
                  >
                    Download
                  </a>
                  <button
                    :if={t.source != "uploaded"}
                    type="button"
                    role="menuitem"
                    disabled
                    title="Built-in themes live in the repo and can't be downloaded."
                  >
                    Download
                  </button>
                </.row_menu>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div
        :if={@action_modal?}
        class="dialog-backdrop"
        phx-window-keydown="close_action_modal"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_action_modal"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>Add action{if @action_site, do: " — #{@action_site.name}"}</h2>
            <button
              type="button"
              phx-click="close_action_modal"
              class="dialog-close"
              aria-label="Close"
            >
              &times;
            </button>
          </header>

          <form phx-submit="create_action" class="dialog-form">
            <label>
              Title <input type="text" name="title" autocomplete="off" required />
            </label>
            <label>
              Message <textarea
                name="message"
                rows="3"
                placeholder="Optional detail shown under the title."
              ></textarea>
              <small>Appears as a pending action in the owner's checklist.</small>
            </label>
            <div class="dialog-footer">
              <button type="button" phx-click="close_action_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Add action</button>
            </div>
          </form>
        </div>
      </div>
      <div
        :if={@gift_modal?}
        class="dialog-backdrop"
        phx-window-keydown="close_gift_modal"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_gift_modal"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>Gift Pro{if @gift_site, do: " — #{@gift_site.name}"}</h2>
            <button type="button" phx-click="close_gift_modal" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <form phx-submit="gift_pro" class="dialog-form">
            <label>
              Months
              <input
                type="number"
                name="months"
                value="3"
                min="1"
                max="120"
                step="1"
                required
                autocomplete="off"
              />
              <small>
                {gift_hint(@gift_site)} No card is charged and no subscription is created.
              </small>
            </label>
            <div class="dialog-footer">
              <button type="button" phx-click="close_gift_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Gift Pro</button>
            </div>
          </form>
        </div>
      </div>
    </.shell>
    """
  end

  defp gift_hint(nil), do: ""

  defp gift_hint(site) do
    if Licenses.paid?(site),
      do: "Added on top of the current expiry (#{gift_date(site)}).",
      else: "Starts today."
  end

  defp gift_date(%{license_expires_at: nil}), do: "—"
  defp gift_date(%{license_expires_at: at}), do: Calendar.strftime(at, "%-d %B %Y")

  attr :id, :any, required: true
  attr :open?, :boolean, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row_menu(assigns) do
    ~H"""
    <div class="row-menu" phx-click-away={@open? && "close_menu"}>
      <button
        type="button"
        class="row-menu-trigger"
        phx-click="toggle_menu"
        phx-value-id={@id}
        aria-haspopup="menu"
        aria-expanded={to_string(@open?)}
        aria-label={@label}
      >
        <.dots_icon />
      </button>

      <div :if={@open?} class="row-menu-panel" role="menu">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp dots_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <circle cx="12" cy="5" r="1.75" />
      <circle cx="12" cy="12" r="1.75" />
      <circle cx="12" cy="19" r="1.75" />
    </svg>
    """
  end
end

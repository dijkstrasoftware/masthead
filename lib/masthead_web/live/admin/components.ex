defmodule MastheadWeb.AdminLive.Components do
  @moduledoc "Shared HEEx components for admin LiveViews."
  use Phoenix.Component
  use MastheadWeb, :verified_routes

  import MastheadWeb.MarketingComponents

  alias Masthead.Accounts.User
  alias Masthead.Actions
  alias Phoenix.LiveView.JS

  attr :title, :string, default: nil
  attr :site, :map, default: nil
  attr :current_user, :map, default: nil
  attr :flash, :map, default: %{}

  attr :active, :atom,
    default: nil,
    doc:
      ":overview | :posts | :pages | :uploads | :theme | :users | :settings | :checklist | :sites | :marketplace | :themes"

  attr :action_count, :integer,
    default: nil,
    doc:
      "Pending-action count for the checklist badge. Pass a tracked assign from " <>
        "LiveViews that mutate actions in-page (so the badge stays live); otherwise " <>
        "it is computed from the site."

  attr :present_users, :list,
    default: [],
    doc: "Other members currently viewing this site (from Presence via the :load_site hook)."

  slot :inner_block, required: true
  slot :actions
  slot :title_meta

  def shell(assigns) do
    ~H"""
    <div id="admin-shell" class="admin-shell">
      <%!-- Mobile-only top bar. The hamburger opens the off-canvas sidebar
            drawer; the bar and drawer behaviour are hidden at desktop widths
            via CSS, where the sidebar is a normal fixed column. --%>
      <header class="admin-topbar">
        <button
          type="button"
          class="hamburger"
          aria-label="Open menu"
          aria-controls="admin-sidebar"
          phx-click={JS.add_class("nav-open", to: "#admin-shell")}
        >
          <.icon_menu />
        </button>
        <.link navigate={~p"/sites"} class="topbar-brand">
          <img src={~p"/images/logo.png"} alt="Masthead" class="brand-logo" />
          <span class="brand-name">Masthead</span>
        </.link>
        <span :if={@site} class="topbar-site">{@site.name}</span>
      </header>

      <%!-- Backdrop behind the open drawer; tapping it closes the menu. --%>
      <div class="sidebar-overlay" aria-hidden="true" phx-click={close_nav()}></div>

      <aside id="admin-sidebar" class="admin-sidebar">
        <div class="sidebar-brand">
          <.link navigate={~p"/sites"} class="brand">
            <img src={~p"/images/logo.png"} alt="Masthead" class="brand-logo" />
            <span class="brand-name">Masthead</span>
          </.link>
          <button
            type="button"
            class="sidebar-close"
            aria-label="Close menu"
            phx-click={close_nav()}
          >
            <.icon_close />
          </button>
          <p class="sidebar-version">v{Application.spec(:masthead, :vsn)}</p>
          <p :if={@site} class="sidebar-site">
            <span class="sidebar-site-name">{@site.name}</span>
            <span class={["sidebar-pill", Masthead.Licenses.paid?(@site) && "sidebar-pill-paid"]}>
              {Masthead.Licenses.label(@site)}
            </span>
          </p>
        </div>

        <nav class="sidebar-nav">
          <%= if @site do %>
            <.nav_link href={~p"/#{@site.slug}"} label="Overview" active={@active == :overview}>
              <.icon_home />
            </.nav_link>
            <.nav_link
              href={~p"/#{@site.slug}/checklist"}
              label="Checklist"
              active={@active == :checklist}
              badge={@action_count || Actions.count_pending(@site)}
            >
              <.icon_check />
            </.nav_link>
            <.nav_link href={~p"/#{@site.slug}/posts"} label="Posts" active={@active == :posts}>
              <.icon_doc />
            </.nav_link>
            <.nav_link href={~p"/#{@site.slug}/pages"} label="Pages" active={@active == :pages}>
              <.icon_page />
            </.nav_link>
            <.nav_link href={~p"/#{@site.slug}/uploads"} label="Uploads" active={@active == :uploads}>
              <.icon_image />
            </.nav_link>
            <.nav_link href={~p"/#{@site.slug}/theme"} label="Theme" active={@active == :theme}>
              <.icon_palette />
            </.nav_link>
            <.nav_link href={~p"/#{@site.slug}/users"} label="Users" active={@active == :users}>
              <.icon_users />
            </.nav_link>
            <.nav_link
              href={~p"/#{@site.slug}/settings"}
              label="Settings"
              active={@active == :settings}
            >
              <.icon_cog />
            </.nav_link>

            <div class="sidebar-divider"></div>

            <a
              class="nav-item nav-external"
              href={site_url(@site)}
              target="_blank"
              rel="noopener"
              phx-click={close_nav()}
            >
              <.icon_external />
              <span>View site</span>
            </a>

            <.nav_link href={~p"/sites"} label="All sites" active={false}>
              <.icon_grid />
            </.nav_link>
          <% else %>
            <.nav_link href={~p"/sites"} label="Your sites" active={@active == :sites}>
              <.icon_grid />
            </.nav_link>

            <.nav_link href={~p"/marketplace"} label="Marketplace" active={@active == :marketplace}>
              <.icon_store />
            </.nav_link>

            <.nav_link
              :if={@current_user && @current_user.admin}
              href={~p"/admin"}
              label="Admin"
              active={@active == :admin}
            >
              <.icon_shield />
            </.nav_link>

            <div class="sidebar-divider"></div>

            <a
              class="nav-item nav-external"
              href="https://docs.masthead.site"
              target="_blank"
              rel="noopener"
              phx-click={close_nav()}
            >
              <.icon_book />
              <span>Docs</span>
            </a>
          <% end %>
        </nav>

        <div :if={@current_user} class="sidebar-user">
          <div class="user-avatar">{user_initial(@current_user)}</div>
          <.link
            navigate={~p"/account"}
            class="user-email"
            title="Account settings"
            phx-click={close_nav()}
          >
            {@current_user.email}
          </.link>
          <.link href={~p"/logout"} method="delete" class="logout-link" title="Log out">
            <.icon_logout />
          </.link>
        </div>
      </aside>

      <main class="admin-content">
        <.unconfirmed_banner :if={@current_user} user={@current_user} />

        <.flash_toasts flash={@flash} />

        <div
          :if={@title || @actions != [] || @title_meta != [] || @present_users != []}
          class="page-head"
        >
          <div class="page-head-title">
            <h1 :if={@title}>{@title}</h1>
            {render_slot(@title_meta)}
            <.presence_cluster :if={@present_users != []} users={@present_users} />
          </div>
          <div class="actions">
            {render_slot(@actions)}
          </div>
        </div>

        {render_slot(@inner_block)}
      </main>

      <%!-- Site-scoped, so it only exists where there is content to search.
            Self-contained: no host LiveView wiring needed. --%>
      <.live_component
        :if={@site}
        module={MastheadWeb.AdminLive.CommandPalette}
        id="command-palette"
        site={@site}
      />
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :current_user, :map, default: nil
  attr :flash, :map, default: %{}
  attr :active, :atom, default: nil
  slot :inner_block, required: true
  slot :actions
  slot :title_meta

  @doc """
  Chrome for the marketplace, the one page that serves signed-in users and
  visitors alike. The body is the same either way; only the frame differs —
  the admin sidebar for a member, the homepage's nav and footer for a
  visitor, so arriving from the front page doesn't feel like a different site.
  """
  def marketplace_shell(%{current_user: nil} = assigns), do: public_shell(assigns)

  def marketplace_shell(assigns) do
    ~H"""
    <.shell title={@title} current_user={@current_user} flash={@flash} active={:marketplace}>
      <:title_meta>{render_slot(@title_meta)}</:title_meta>
      <:actions>{render_slot(@actions)}</:actions>
      {render_slot(@inner_block)}
    </.shell>
    """
  end

  defp public_shell(assigns) do
    ~H"""
    <div class="public-shell">
      <.marketing_nav active={:marketplace} />

      <main class="public-content">
        <.flash_toasts flash={@flash} />

        <div :if={@title || @actions != [] || @title_meta != []} class="page-head">
          <div class="page-head-title">
            <h1 :if={@title}>{@title}</h1>
            {render_slot(@title_meta)}
          </div>
          <div class="actions">
            {render_slot(@actions)}
          </div>
        </div>

        {render_slot(@inner_block)}
      </main>

      <.marketing_footer />
    </div>
    """
  end

  attr :flash, :map, required: true

  @doc "Transient info/error toasts. Both shells show them the same way."
  def flash_toasts(assigns) do
    ~H"""
    <div class="flash-toasts" aria-live="polite">
      <div
        :if={Phoenix.Flash.get(@flash, :info)}
        id="toast-info"
        class="flash-toast flash-toast-info"
        phx-hook="FlashToast"
        data-key="info"
        role="status"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>
      <div
        :if={Phoenix.Flash.get(@flash, :error)}
        id="toast-error"
        class="flash-toast flash-toast-error"
        phx-hook="FlashToast"
        data-key="error"
        role="alert"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
    </div>
    """
  end

  attr :user, :map, required: true

  @doc """
  Persistent reminder shown to signed-in users whose email is not yet
  confirmed. Renders nothing once confirmed. The resend action posts to
  `/confirm`; the controller is enumeration-safe.
  """
  def unconfirmed_banner(assigns) do
    ~H"""
    <div :if={not User.confirmed?(@user)} class="account-banner" role="status">
      <p>
        Please confirm your email address. We sent a link to <strong>{@user.email}</strong>. Unconfirmed accounts are disabled after 7 days.
      </p>
      <.link href={~p"/confirm"} method="post" class="account-banner-btn">
        Resend confirmation
      </.link>
    </div>
    """
  end

  attr :change, :atom, default: nil, doc: ":updated | :deleted | nil"
  attr :reload_to, :string, default: nil

  @doc """
  Banner shown in a post/page editor when someone else changed or deleted the
  record being edited. `phx-click=\"dismiss_external_change\"` is handled by
  the editor LiveView.
  """
  def external_change_banner(assigns) do
    ~H"""
    <div :if={@change} class="account-banner" role="alert">
      <p :if={@change == :updated}>
        Someone else changed this while you had it open. <.link
          :if={@reload_to}
          navigate={@reload_to}
          class="account-banner-link"
        >
          Reload to see the latest
        </.link>.
      </p>
      <p :if={@change == :deleted}>
        Someone else deleted this. Your changes can no longer be saved here.
      </p>
      <button type="button" phx-click="dismiss_external_change" class="account-banner-btn">
        Dismiss
      </button>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :badge, :integer, default: nil
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={"nav-item" <> if(@active, do: " active", else: "")}
      phx-click={close_nav()}
    >
      {render_slot(@inner_block)}
      <span>{@label}</span>
      <span
        :if={@badge && @badge > 0}
        id="checklist-badge"
        phx-hook="BadgePulse"
        class="nav-badge"
        phx-no-format
      >{@badge}</span>
    </.link>
    """
  end

  # Collapses the mobile sidebar drawer. The class is toggled on the shell so
  # CSS can drive both the drawer transform and the backdrop. On desktop the
  # class is inert (the sidebar is a static column), so this is a no-op there.
  defp close_nav, do: JS.remove_class("nav-open", to: "#admin-shell")

  attr :action, :map, required: true
  attr :dismissible, :boolean, default: true

  @doc """
  Renders a single action as a light-yellow card: an optional dismiss cross
  on the left, the title (from the action registry) and message, and a button
  linking to its path when set. When `dismissible` is true the enclosing
  LiveView must handle the `"dismiss_action"` event (carrying `phx-value-key`).
  """
  def action_card(assigns) do
    ~H"""
    <div class="action-card">
      <button
        :if={@dismissible}
        type="button"
        class="action-card-dismiss"
        phx-click="dismiss_action"
        phx-value-key={@action.key}
        aria-label="Dismiss this action"
        title="Dismiss this action"
      >
        &times;
      </button>
      <div class="action-card-body">
        <h3 class="action-card-title">{Actions.title(@action)}</h3>
        <p class="action-card-message">{@action.message}</p>
      </div>
      <.link :if={@action.path} navigate={@action.path} class="btn btn-primary btn-sm">
        {Actions.cta(@action) || "Open"}
      </.link>
    </div>
    """
  end

  attr :rest, :global
  attr :variant, :string, default: "primary"
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button class={"btn btn-" <> @variant} {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  attr :at, :any, default: nil, doc: "a DateTime to render as a relative 'time ago' label"

  @doc """
  Renders a timestamp as a relative label (e.g. "a day ago") with the exact
  date and time shown in a custom hover tooltip (see `.rel-time` in app.css).
  The tooltip is server-rendered in UTC as a no-JS fallback; app.js rewrites
  it to the viewer's local timezone on hover. Renders nothing when `at` is nil.
  """
  def relative_time(assigns) do
    ~H"""
    <time
      :if={@at}
      class="rel-time"
      datetime={DateTime.to_iso8601(@at)}
      data-tooltip={Calendar.strftime(@at, "%b %-d, %Y at %-I:%M %p UTC")}
    >
      {relative_label(@at)}
    </time>
    """
  end

  # Coarse "time ago" phrasing in the style of moment.js's fromNow. Computed at
  # render time; it doesn't tick live, which is fine for list timestamps.
  defp relative_label(at) do
    diff = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      diff < 0 -> "just now"
      diff < 45 -> "a few seconds ago"
      true -> diff |> relative_unit() |> relative_phrase()
    end
  end

  defp relative_unit(s) when s < 90, do: {1, "minute"}
  defp relative_unit(s) when s < 2_700, do: {div(s, 60), "minute"}
  defp relative_unit(s) when s < 5_400, do: {1, "hour"}
  defp relative_unit(s) when s < 79_200, do: {div(s, 3_600), "hour"}
  defp relative_unit(s) when s < 129_600, do: {1, "day"}
  defp relative_unit(s) when s < 2_246_400, do: {div(s, 86_400), "day"}
  defp relative_unit(s) when s < 3_974_400, do: {1, "month"}
  defp relative_unit(s) when s < 27_648_000, do: {round(s / 2_629_800), "month"}
  defp relative_unit(s) when s < 47_347_200, do: {1, "year"}
  defp relative_unit(s), do: {round(s / 31_557_600), "year"}

  defp relative_phrase({1, "hour"}), do: "an hour ago"
  defp relative_phrase({1, unit}), do: "a #{unit} ago"
  defp relative_phrase({n, unit}), do: "#{n} #{unit}s ago"

  @doc """
  Filter + search toolbar for the admin overview tables (users / sites /
  themes). Renders a row of filter buttons — highlighting the active one —
  and a search box. The caller owns the state; this only emits events:

  * clicking a filter button sends `"switch_filter"` with `scope` + `filter`
  * typing in the search box sends `"search_list"` (debounced) with
    `scope` + `query`

  The search input carries `data-shortcut="search"`, which is what
  `app.js` focuses on Cmd/Ctrl+F instead of opening the browser's find bar.

  `scope` identifies which list the events belong to so a single pair of
  handlers can serve all three tabs.
  """
  attr :scope, :atom, required: true, doc: ":users | :sites | :themes | :posts | :uploads"
  attr :filter, :any, required: true, doc: "the currently active filter value (atom or string)"
  attr :options, :list, required: true, doc: ~s(list of `{value, label}` filter buttons)
  attr :search, :string, default: "", doc: "the current search term"
  attr :placeholder, :string, default: "Search…"
  attr :limit, :integer, required: true, doc: "the row cap applied to the list"
  attr :truncated?, :boolean, default: false, doc: "true when the list hit the cap"
  attr :total, :integer, default: nil, doc: "total rows matching the filter + search"

  def list_toolbar(assigns) do
    ~H"""
    <div class="admin-toolbar">
      <div class="admin-toolbar-row">
        <div class="admin-filters">
          <button
            :for={{value, label} <- @options}
            type="button"
            class={["btn btn-sm", @filter == value && "btn-primary"]}
            phx-click="switch_filter"
            phx-value-scope={@scope}
            phx-value-filter={value}
          >
            {label}
          </button>
        </div>
        <form phx-change="search_list" class="admin-search">
          <input type="hidden" name="scope" value={@scope} />
          <input
            type="search"
            name="query"
            value={@search}
            placeholder={@placeholder}
            phx-debounce="300"
            autocomplete="off"
            data-shortcut="search"
          />
        </form>
      </div>
      <div :if={@truncated?} class="admin-toolbar-hint">
        <span>Showing the first {@limit}. Refine with search or a filter to find more.</span>
        <span :if={@total}>{@total} total</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the Markdown / HTML format picker as a pair of cards.

  * `selected` — `"markdown"` or `"html"` to mark a card as active, or `nil` for none
  * `locked`   — when true, cards are non-interactive (no `phx-click`) and
                 the un-selected card is disabled. Used on edit pages where
                 format is fixed at creation.
  * `allow_theme` — when true, shows a third "Theme page" card (pages only;
                 requires the active theme to expose page templates).
  """
  attr :selected, :string, default: nil
  attr :locked, :boolean, default: false
  attr :allow_theme, :boolean, default: false
  attr :template, :string, default: nil
  attr :page_templates, :list, default: []

  def format_cards(assigns) do
    ~H"""
    <div class="format-cards">
      <button
        type="button"
        phx-click={!@locked && "choose_format"}
        phx-value-format="markdown"
        disabled={@locked && @selected != "markdown"}
        class={card_classes("markdown", @selected, @locked)}
      >
        <div class="format-icon">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <rect x="3" y="6" width="18" height="12" rx="2" />
            <path d="M7 14V10l2.5 3L12 10v4" stroke-linecap="round" stroke-linejoin="round" />
            <path d="M16 10v4M14.5 12.5L16 14l1.5-1.5" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </div>
        <h3>Markdown</h3>
        <p>Plain text with simple formatting. Headings, lists, links, code, images.</p>
        <span class="format-pill">Recommended</span>
      </button>

      <button
        type="button"
        phx-click={!@locked && "choose_format"}
        phx-value-format="html"
        disabled={@locked && @selected != "html"}
        class={card_classes("html", @selected, @locked)}
      >
        <div class="format-icon">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <polyline points="16 18 22 12 16 6" stroke-linecap="round" stroke-linejoin="round" />
            <polyline points="8 6 2 12 8 18" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </div>
        <h3>HTML</h3>
        <p>
          Raw HTML with Liquid tokens and logic for full control. Nothing is stripped — scripts and embeds run.
        </p>
        <span class="format-pill format-pill-muted">Advanced</span>
      </button>

      <div
        :if={@allow_theme}
        phx-click={!@locked && "choose_format"}
        phx-value-format="theme"
        role="button"
        tabindex="0"
        class={card_classes("theme", @selected, @locked)}
      >
        <div class="format-icon">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          >
            <rect x="3" y="4" width="18" height="16" rx="2" />
            <path stroke-linecap="round" stroke-linejoin="round" d="M3 9h18M8 9v11" />
          </svg>
        </div>
        <h3>Theme page</h3>
        <p>
          A ready-made layout from your theme (e.g. a blog index or landing page). You set its options, not its body.
        </p>
        <form phx-change="choose_template" class="format-card-select" onsubmit="return false">
          <label>
            <span class="sr-only">Page template</span>
            <select name="template" disabled={@locked}>
              <option value="" disabled selected={@selected != "theme" or @template in [nil, ""]}>
                Choose a template…
              </option>
              <option :for={t <- @page_templates} value={t.name} selected={@template == t.name}>
                {t.label}
              </option>
            </select>
          </label>
        </form>
      </div>
    </div>
    """
  end

  defp card_classes(key, selected, locked) do
    [
      "format-card",
      selected == key && "format-card-selected",
      locked && selected != key && "format-card-disabled"
    ]
  end

  attr :changeset, :map, required: true
  attr :show, :boolean, default: false

  def error_list(assigns) do
    ~H"""
    <ul :if={@show and @changeset.errors != []} class="errors">
      <li :for={{field, {msg, _}} <- @changeset.errors}>{field}: {msg}</li>
    </ul>
    """
  end

  @doc """
  Right-hand control rail for the content editor (post & page forms).

  Sits beside the body editor on the content step and holds the save,
  publishing, and delete controls. The save buttons submit the body form
  via `form="content-form"`; the publish/delete buttons emit the
  `"toggle_publish"` and `"delete"` events handled by the parent LiveView.
  """
  attr :editing, :boolean, required: true
  attr :published, :boolean, default: false
  attr :entity, :string, required: true, doc: ~s(noun for labels, e.g. "post" or "page")
  attr :site, :map, default: nil

  attr :view_path, :string,
    default: nil,
    doc: ~s(public path of the record, e.g. "/posts/my-slug")

  attr :format, :string, default: "markdown", doc: ~s("markdown" | "html" | "theme")
  attr :tools, :boolean, default: true, doc: "show the editor Tools card (Insert / Format)"

  def content_sidebar(assigns) do
    ~H"""
    <aside class="content-sidebar">
      <%= if @editing do %>
        <div class="sidebar-card">
          <h3 class="sidebar-card-title">Manage</h3>
          <button
            type="submit"
            form="content-form"
            class="btn btn-primary btn-block"
            data-shortcut="save"
          >
            Save changes
          </button>
          <button type="button" phx-click="toggle_publish" class="btn btn-block">
            {if @published, do: "Unpublish", else: "Publish"}
          </button>
          <a
            :if={@published}
            href={site_url(@site) <> @view_path}
            target="_blank"
            rel="noopener"
            class="btn btn-block"
          >
            <.icon_external /> View {@entity}
          </a>
          <button
            :if={not @published}
            type="button"
            class="btn btn-block"
            disabled
            title={"Publish this " <> @entity <> " to view it live"}
          >
            <.icon_external /> View {@entity}
          </button>
        </div>
      <% else %>
        <div class="sidebar-card">
          <h3 class="sidebar-card-title">Manage</h3>
          <button
            type="submit"
            form="content-form"
            name="action"
            value="publish"
            class="btn btn-primary btn-block"
            data-shortcut="publish"
          >
            Save &amp; publish
          </button>
          <button
            type="submit"
            form="content-form"
            name="action"
            value="draft"
            class="btn btn-block"
            data-shortcut="save"
          >
            Save as draft
          </button>
        </div>
      <% end %>

      <div :if={@tools} class="sidebar-card">
        <h3 class="sidebar-card-title">Tools</h3>
        <button
          type="button"
          class="btn btn-block"
          phx-click="open"
          phx-target={"#" <> @entity <> "-file-picker"}
        >
          <.icon_image /> Insert
        </button>
        <button
          :if={@format == "html"}
          type="button"
          class="btn btn-block"
          phx-click="format_body"
        >
          <.icon_format /> Format
        </button>
      </div>

      <div :if={@editing} class="sidebar-card sidebar-card-danger">
        <h3 class="sidebar-card-title">Danger zone</h3>
        <button
          type="button"
          phx-click="delete"
          data-confirm={"Delete this " <> @entity <> "? This can't be undone."}
          class="btn btn-danger btn-block"
        >
          Delete {@entity}
        </button>
      </div>

      <.live_component
        module={MastheadWeb.AdminLive.FilePicker}
        id={@entity <> "-file-picker"}
        site={@site}
        accept={~w(.png .jpg .jpeg .gif .webp .svg)}
        images_only
        title="Insert image"
      />
    </aside>
    """
  end

  defp icon_format(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5"
      />
    </svg>
    """
  end

  @doc """
  Read-only publish-state badge for the editor header. Mirrors the pill
  shape of a button, but only reports state — the actual publish/unpublish
  action lives in the content sidebar's "Manage" card.
  """
  attr :published, :boolean, required: true

  def publish_status(assigns) do
    ~H"""
    <span class={"publish-status " <> if(@published, do: "is-published", else: "is-draft")}>
      {if @published, do: "Published", else: "Draft"}
    </span>
    """
  end

  defp user_initial(%{email: email}) when is_binary(email) do
    email |> String.first() |> String.upcase()
  end

  defp user_initial(_), do: "?"

  attr :users, :list, required: true

  # Overlapping avatars of who else is viewing, shown right after the page
  # title. Each avatar reveals the member's email in a popover on hover. Fed by
  # `@present_users` (Presence), which the `:load_site` hook keeps current.
  defp presence_cluster(assigns) do
    ~H"""
    <div class="presence-cluster" aria-label="Also viewing" phx-no-format>
      <span :for={u <- @users} class="presence-avatar" tabindex="0">
        {user_initial(u)}
        <span class="presence-popover" role="tooltip">{u.email}</span>
      </span>
    </div>
    """
  end

  @doc false
  # Builds the public URL for a site based on `:masthead, :site_url`:
  #
  #   * `scheme: "http", host: "lvh.me", port: 4000`        -> http://slug.lvh.me:4000
  #   * `scheme: "https", host: "yourdomain.com", port: nil` -> https://slug.yourdomain.com
  defp site_url(%{custom_domain: domain, custom_domain_status: "active"})
       when is_binary(domain),
       do: "https://#{domain}"

  defp site_url(site) do
    cfg = Application.get_env(:masthead, :site_url, scheme: "http", host: "lvh.me", port: 4000)
    scheme = Keyword.fetch!(cfg, :scheme)
    host = Keyword.fetch!(cfg, :host)
    port = Keyword.get(cfg, :port)

    port_segment =
      cond do
        is_nil(port) -> ""
        scheme == "http" and port == 80 -> ""
        scheme == "https" and port == 443 -> ""
        true -> ":#{port}"
      end

    "#{scheme}://#{site.slug}.#{host}#{port_segment}"
  end

  # ---- Icons (heroicons outline, inlined) ----

  defp icon_home(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M2.25 12 12 2.25 21.75 12M4.5 9.75v9.75A1.5 1.5 0 0 0 6 21h3.75v-6h4.5v6H18a1.5 1.5 0 0 0 1.5-1.5V9.75"
      />
    </svg>
    """
  end

  defp icon_doc(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.862 4.487 18.549 2.8a2.121 2.121 0 1 1 3 3L19.862 7.487m-3-3L6.34 15.013a4.5 4.5 0 0 0-1.13 1.897l-.943 3.18 3.18-.943a4.5 4.5 0 0 0 1.897-1.13L19.862 7.487m-3-3 3 3"
      />
    </svg>
    """
  end

  defp icon_page(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"
      />
    </svg>
    """
  end

  defp icon_image(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 0 0 1.5-1.5V6a1.5 1.5 0 0 0-1.5-1.5H3.75A1.5 1.5 0 0 0 2.25 6v12a1.5 1.5 0 0 0 1.5 1.5Zm10.5-11.25h.008v.008h-.008V8.25Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z"
      />
    </svg>
    """
  end

  defp icon_cog(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
      />
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
    </svg>
    """
  end

  defp icon_users(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M18 18.72a9.094 9.094 0 0 0 3.741-.479 3 3 0 0 0-4.682-2.72m.94 3.198.001.031c0 .225-.012.447-.037.666A11.944 11.944 0 0 1 12 21c-2.17 0-4.207-.576-5.963-1.584A6.062 6.062 0 0 1 6 18.719m12 0a5.971 5.971 0 0 0-.941-3.197m0 0A5.995 5.995 0 0 0 12 12.75a5.995 5.995 0 0 0-5.058 2.772m0 0a3 3 0 0 0-4.681 2.72 8.986 8.986 0 0 0 3.74.477m.94-3.197a5.971 5.971 0 0 0-.94 3.197M15 6.75a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm6 3a2.25 2.25 0 1 1-4.5 0 2.25 2.25 0 0 1 4.5 0Zm-13.5 0a2.25 2.25 0 1 1-4.5 0 2.25 2.25 0 0 1 4.5 0Z"
      />
    </svg>
    """
  end

  defp icon_external(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
      />
    </svg>
    """
  end

  defp icon_book(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25"
      />
    </svg>
    """
  end

  defp icon_grid(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25A2.25 2.25 0 0 1 13.5 18v-2.25Z"
      />
    </svg>
    """
  end

  defp icon_logout(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9"
      />
    </svg>
    """
  end

  defp icon_palette(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9.53 16.122a3 3 0 0 0-5.78 1.128 2.25 2.25 0 0 1-2.4 2.245 4.5 4.5 0 0 0 8.4-2.245c0-.399-.078-.78-.22-1.128Zm0 0a15.998 15.998 0 0 0 3.388-1.62m-5.043-.025a15.994 15.994 0 0 1 1.622-3.395m3.42 3.42a15.995 15.995 0 0 0 4.764-4.648l3.876-5.814a1.151 1.151 0 0 0-1.597-1.597L14.146 6.32a15.996 15.996 0 0 0-4.649 4.763m3.42 3.42a6.776 6.776 0 0 0-3.42-3.42"
      />
    </svg>
    """
  end

  defp icon_shield(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9 12.75 11.25 15 15 9.75m-3-7.036A11.959 11.959 0 0 1 3.598 6 11.99 11.99 0 0 0 3 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285Z"
      />
    </svg>
    """
  end

  defp icon_store(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M13.5 21v-7.5a.75.75 0 0 1 .75-.75h3a.75.75 0 0 1 .75.75V21m-4.5 0H2.36m11.14 0H18m0 0h3.64m-1.39 0V9.349M3.75 21V9.349m0 0a3.001 3.001 0 0 0 3.75-.615A2.993 2.993 0 0 0 9.75 9.75c.896 0 1.7-.393 2.25-1.016a2.993 2.993 0 0 0 2.25 1.016c.896 0 1.7-.393 2.25-1.016a3.001 3.001 0 0 0 3.75.614m-16.5 0a3.004 3.004 0 0 1-.621-4.72l1.189-1.19A1.5 1.5 0 0 1 5.378 3h13.243a1.5 1.5 0 0 1 1.06.44l1.19 1.189a3 3 0 0 1-.621 4.72M6.75 18h3.75a.75.75 0 0 0 .75-.75V13.5a.75.75 0 0 0-.75-.75H6.75a.75.75 0 0 0-.75.75v3.75c0 .414.336.75.75.75Z"
      />
    </svg>
    """
  end

  @doc """
  Paywall dialog offered wherever a licensed-only action is attempted, so a
  free site is never sent off the page it is working on to pay.

  The host LiveView needs an `upgrade_modal?` assign, a `plans` assign from
  `Masthead.Licenses.plans/0`, and `open_upgrade` / `close_upgrade` /
  `checkout` events.
  """
  attr :show, :boolean, required: true
  attr :plans, :list, required: true
  attr :feature, :string, required: true

  def upgrade_modal(assigns) do
    assigns = assign(assigns, :saving, Masthead.Licenses.yearly_saving())

    ~H"""
    <div :if={@show} class="dialog-backdrop" phx-window-keydown="close_upgrade" phx-key="Escape">
      <button
        type="button"
        phx-click="close_upgrade"
        class="dialog-close-overlay"
        aria-label="Close"
        tabindex="-1"
      >
      </button>
      <div class="dialog">
        <header class="dialog-header">
          <h2>Upgrade to use this functionality</h2>
          <button type="button" phx-click="close_upgrade" class="dialog-close" aria-label="Close">
            &times;
          </button>
        </header>

        <div class="upgrade-body">
          <p class="upgrade-lede">{@feature} needs a paid license for this site.</p>

          <div class="plan-grid">
            <button
              :for={{name, plan} <- @plans}
              type="button"
              phx-click="checkout"
              phx-value-plan={name}
              class={["plan-card", name == "yearly" && "plan-card-best"]}
            >
              <span class="plan-head">
                <span class="plan-name">{String.capitalize(name)}</span>
                <span :if={name == "yearly" && @saving} class="pill pill-ok">
                  Save {Masthead.Licenses.format(@saving)}
                </span>
              </span>
              <span class="plan-price">
                {Masthead.Licenses.format(plan.amount)}<span class="plan-per">/{plan.label}</span>
              </span>
              <span class="plan-note">Billed every {plan.label}. Cancel any time.</span>
            </button>
          </div>

          <p class="upgrade-foot">
            <.link href={~p"/pricing"} target="_blank" rel="noopener">
              See what's included
            </.link>
          </p>

          <footer class="dialog-footer">
            <button type="button" phx-click="close_upgrade" class="btn">Not now</button>
          </footer>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Marketplace status chip. Verified themes get the green "Verified" chip;
  everything else (community / unpublished) renders nothing.
  """
  attr :theme, :map, required: true

  def theme_badge(assigns) do
    ~H"""
    <span :if={@theme.verified} class="chip chip-verified">Verified</span>
    """
  end

  @doc "Pencil — the edit affordance on cards and inline-editable sections."
  def pencil_icon(assigns) do
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
        d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"
      />
    </svg>
    """
  end

  @doc """
  Visibility chip for a theme. A private theme isn't a half-finished draft —
  it's a finished theme its author keeps for their own sites.
  """
  attr :theme, :map, required: true

  def theme_status(assigns) do
    ~H"""
    <span class={["chip", if(@theme.public, do: "chip-marketplace", else: "chip-private")]}>
      {if @theme.public, do: "Public", else: "Private"}
    </span>
    """
  end

  defp icon_check(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      />
    </svg>
    """
  end

  defp icon_menu(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.75"
      stroke="currentColor"
      class="icon"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M3.75 6.75h16.5M3.75 12h16.5M3.75 17.25h16.5"
      />
    </svg>
    """
  end

  defp icon_close(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.75"
      stroke="currentColor"
      class="icon"
    >
      <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
    </svg>
    """
  end
end

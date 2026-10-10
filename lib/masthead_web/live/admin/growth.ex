defmodule MastheadWeb.AdminLive.Growth do
  @moduledoc """
  Platform-admin growth dashboard: signups through activation and return,
  acquisition channels and theme choice. Every figure is a server-side
  aggregate from `Masthead.Growth`; definitions are in
  docs/2026-10-10-growth-dashboard-spec.md. Tab, range and funnel window live
  in the URL; only the open tab's figures are queried.
  """
  use MastheadWeb, :live_view

  import MastheadWeb.AdminLive.Components

  alias Masthead.Growth

  @tabs [overview: "Overview", funnel: "Funnel", acquisition: "Acquisition", themes: "Themes"]
  @tab_ids Enum.map(@tabs, fn {id, _} -> Atom.to_string(id) end)
  @ranges [7, 30, 90, :all]
  @windows [7, 14, 30]
  @cards ~w(signed_up activated returned)
  @stages ~w(signed_up created_site activated returned)

  @impl true
  def mount(_params, _session, socket) do
    since = Calendar.strftime(Growth.tracking_since(), "%-d %b %Y")
    {:ok, assign(socket, page_title: "Growth", theme_scope: :first, drill: nil, since: since)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      if params["tab"] in @tab_ids, do: String.to_existing_atom(params["tab"]), else: :overview

    range = parse(params["range"], @ranges, 30)
    window = parse(params["window"], @windows, 14)

    {:noreply,
     socket
     |> assign(tab: tab, range: range, window: window, filters: %{range: range}, drill: nil)
     |> load()}
  end

  defp parse(value, allowed, default),
    do: Enum.find(allowed, default, &(to_string(&1) == value))

  defp load(%{assigns: %{tab: :overview, filters: filters}} = socket) do
    assign(socket,
      summary: Growth.summary(filters),
      chart: filters |> Growth.daily() |> bar_chart_data(:signups, :activations)
    )
  end

  defp load(%{assigns: %{tab: :funnel, filters: filters, window: window}} = socket),
    do: assign(socket, funnel: Growth.funnel(filters, window))

  defp load(%{assigns: %{tab: :acquisition, filters: filters, window: window}} = socket),
    do: assign(socket, acquisition: Growth.acquisition(filters, window))

  defp load(%{assigns: %{tab: :themes, filters: filters, theme_scope: scope}} = socket),
    do: assign(socket, themes: Growth.themes(filters, scope))

  @impl true
  def handle_event("theme_scope", %{"scope" => scope}, socket) do
    scope = if scope == "all", do: :all, else: :first
    {:noreply, socket |> assign(theme_scope: scope) |> load()}
  end

  def handle_event("drill", %{"metric" => metric}, socket) when metric in @cards do
    metric = String.to_existing_atom(metric)
    {:noreply, open_drill(socket, card_label(metric), metric, socket.assigns.filters)}
  end

  def handle_event("drill", %{"stage" => stage}, socket) when stage in @stages do
    stage = String.to_existing_atom(stage)
    %{window: window, filters: filters} = socket.assigns
    title = "#{stage_label(stage)} within #{window} days"
    {:noreply, open_drill(socket, title, {:funnel, stage, window}, filters)}
  end

  def handle_event("drill", %{"channel" => channel}, socket) do
    {:noreply,
     open_drill(socket, "Signups via #{channel}", {:channel, channel}, socket.assigns.filters)}
  end

  def handle_event("close_drill", _params, socket), do: {:noreply, assign(socket, drill: nil)}

  defp open_drill(socket, title, metric, filters) do
    assign(socket, drill: Map.put(Growth.drilldown(metric, filters), :title, title))
  end

  defp growth_path(tab, range, window),
    do: ~p"/admin/growth/#{tab}?#{[range: range, window: window]}"

  defp range_label(:all), do: "All time"
  defp range_label(days), do: "#{days} days"

  defp range_phrase(:all), do: "All signups"
  defp range_phrase(days), do: "Signups from the last #{days} days"

  defp card_label(:signed_up), do: "Signups"
  defp card_label(:activated), do: "Activated signups"
  defp card_label(:returned), do: "Returning signups"

  defp stage_label(:signed_up), do: "Signed up"
  defp stage_label(:created_site), do: "Created first site"
  defp stage_label(:activated), do: "Activated"
  defp stage_label(:returned), do: "Returned"

  defp stage_info(:signed_up, _window),
    do: "Eligible users (not admins, not invited) who signed up in range and long enough ago."

  defp stage_info(:created_site, window),
    do: "Created at least one site (deleted sites count) within #{window} days of signup."

  defp stage_info(:activated, window),
    do:
      "Published a page or post, written or imported, and created a site, both within " <>
        "#{window} days of signup."

  defp stage_info(:returned, window),
    do:
      "Active on a day after the signup day, within #{window} days, having reached every " <>
        "earlier stage. Only signups since growth tracking started."

  defp pct(_count, total) when total in [nil, 0], do: "—"
  defp pct(count, total), do: "#{round(count * 100 / total)}%"

  defp width(_count, total) when total in [nil, 0], do: 0
  defp width(count, total), do: Float.round(count * 100 / total, 1)

  defp per_creator(%{creators: 0}), do: "—"
  defp per_creator(summary), do: Float.round(summary.creator_sites / summary.creators, 1)

  defp date(nil), do: "—"
  defp date(at), do: Calendar.strftime(at, "%-d %b %Y")

  defp accounts_note(%{total: total, users: users}) do
    noun = if total == 1, do: "account", else: "accounts"
    shown = if total > length(users), do: ", newest #{length(users)} shown"
    "#{total} #{noun}#{shown}"
  end

  attr :text, :string, required: true

  defp info(assigns) do
    ~H"""
    <span class="growth-info" title={@text} aria-label={@text} role="img">
      <.icon name="hero-information-circle" />
    </span>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :info, :string, required: true
  attr :metric, :string, default: nil
  attr :primary, :boolean, default: false
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div id={@id} class={["growth-card", @primary && "growth-card-primary"]}>
      <span class="growth-card-label">{@label} <.info text={@info} /></span>
      <button
        :if={@metric}
        type="button"
        class="growth-num"
        phx-click="drill"
        phx-value-metric={@metric}
        title="Show accounts"
      >
        {@value}
      </button>
      <span :if={!@metric} class="growth-num">{@value}</span>
      <div class="growth-sub">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tabs: @tabs, ranges: @ranges, windows: @windows)

    ~H"""
    <.shell title="Growth" current_user={@current_user} flash={@flash} active={:growth}>
      <div id="growth" class="growth">
        <div class="growth-bar">
          <nav id="growth-tabs" class="admin-tabs growth-tabs" aria-label="Growth sections">
            <.link
              :for={{id, label} <- @tabs}
              id={"growth-tab-#{id}"}
              patch={growth_path(id, @range, @window)}
              class={["admin-tab", @tab == id && "is-active"]}
            >
              {label}
            </.link>
          </nav>
          <div class="growth-filters">
            <div
              :if={@tab in [:funnel, :acquisition]}
              id="growth-window"
              class="admin-filters"
              title="Count a step only when it happened within this many days of signup"
            >
              <span class="growth-filter-label">Within</span>
              <.link
                :for={window <- @windows}
                patch={growth_path(@tab, @range, window)}
                class={["btn btn-sm", window == @window && "btn-primary"]}
              >
                {window}d
              </.link>
            </div>
            <div id="growth-range" class="admin-filters">
              <span class="growth-filter-label">Period</span>
              <.link
                :for={range <- @ranges}
                patch={growth_path(@tab, range, @window)}
                class={["btn btn-sm", range == @range && "btn-primary"]}
              >
                {range_label(range)}
              </.link>
            </div>
          </div>
        </div>

        <section :if={@tab == :overview} id="growth-overview">
          <div class="growth-cards">
            <.card
              id="card-activated"
              metric="activated"
              label="Activation rate"
              value={pct(@summary.activated, @summary.users)}
              info="Share of eligible signups in range who published a page or post at least once, written or imported. Never cleared."
              primary
            >
              <span>{@summary.activated} of {@summary.users} signups published</span>
              <span>
                {@summary.written} written · {@summary.import} imported<span :if={@range != :all}> · {pct(@summary.activated_all, @summary.users_all)} all time</span>
              </span>
            </.card>
            <.card
              id="card-users"
              metric="signed_up"
              label="Signups"
              value={@summary.users}
              info="Eligible users: not admins and not invited collaborators. Disabled and suspended users count."
            >
              <span :if={@range != :all}>{@summary.users_all} all time</span>
            </.card>
            <.card
              id="card-sites"
              label="Sites created"
              value={@summary.sites}
              info="Every site created in range, soft-deleted ones included. Per creator: sites by signups in range who created at least one."
            >
              <span>{per_creator(@summary)} per creator</span>
              <span :if={@range != :all}>{@summary.sites_all} all time</span>
            </.card>
            <.card
              id="card-returning"
              metric="returned"
              label="Returning"
              value={@summary.returning}
              info={"Signups with a meaningful action on a day after their signup day. Only signups since #{@since}. D7: active on or after day 7."}
            >
              <span>of {@summary.tracked} tracked signups</span>
              <span>D7 retention {pct(@summary.d7_retained, @summary.d7_cohort)}</span>
            </.card>
          </div>

          <h2 class="growth-panel-title">
            Signups and activations
            <.info text="Eligible signups and first publishes per UTC day; per week for all time." />
          </h2>
          <div id="growth-chart">
            <.bar_chart chart={@chart} nouns={["signup", "activation"]} weekly={@range == :all} />
          </div>
          <p class="growth-note">Returns are tracked since {@since}.</p>
        </section>

        <section :if={@tab == :funnel} id="growth-funnel" class="growth-panel">
          <div class="funnel-head" aria-hidden="true">
            <span>Stage</span>
            <span></span>
            <span>Users</span>
            <span>Of signups</span>
            <span>Of previous</span>
          </div>
          <ol class="funnel">
            <li :for={stage <- @funnel.stages} id={"funnel-#{stage.stage}"} class="funnel-stage">
              <div class="funnel-label">
                <span>
                  {stage_label(stage.stage)} <.info text={stage_info(stage.stage, @window)} />
                </span>
                <span :if={stage.stage == :activated} class="growth-sub">
                  {@funnel.activated.written} written · {@funnel.activated.import} imported
                </span>
                <span :if={stage.stage == :returned} class="growth-sub">
                  signups since {@since}
                </span>
              </div>
              <div class="funnel-track">
                <span class="funnel-fill" style={"width: #{width(stage.users, stage.signups)}%"}>
                </span>
              </div>
              <button
                type="button"
                class="growth-link funnel-num"
                phx-click="drill"
                phx-value-stage={stage.stage}
                title="Show accounts"
              >
                {stage.users}
              </button>
              <span class="funnel-num">{pct(stage.users, stage.signups)}</span>
              <span class="funnel-num">
                <%= if stage.previous do %>
                  {pct(stage.users, stage.previous)}
                  <span :if={stage.previous > stage.users} class="funnel-drop">
                    −{stage.previous - stage.users} dropped
                  </span>
                <% end %>
              </span>
            </li>
          </ol>
          <p class="growth-note">
            {range_phrase(@range)} that are at least {@window} days old; each stage needs every earlier one within {@window} days.
            <span :if={@funnel.excluded > 0}>
              {@funnel.excluded} newer {if @funnel.excluded == 1, do: "signup is", else: "signups are"} not counted yet.
            </span>
          </p>
        </section>

        <section :if={@tab == :acquisition} id="growth-acquisition-tab">
          <table id="growth-acquisition" class="table growth-table">
            <thead>
              <tr>
                <th>
                  Channel
                  <.info text="First touch: utm_source, else google-ads (gclid), organic-search, referral:<domain>, direct; Unknown when nothing was captured." />
                </th>
                <th class="num-cell">Signups <.info text="Eligible signups in range." /></th>
                <th class="num-cell">
                  Activated <.info text={"Share who published within #{@window} days of signup."} />
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{row, i} <- Enum.with_index(@acquisition)} id={"channel-#{i}"}>
                <td>
                  <details :if={row.campaigns != []}>
                    <summary>{row.channel}</summary>
                    <ul class="growth-campaigns">
                      <li :for={c <- row.campaigns}>
                        {c.medium || "—"} / {c.campaign || "—"}: {c.signups} signups, {pct(
                          c.activated,
                          c.signups
                        )} activated
                      </li>
                    </ul>
                  </details>
                  <span :if={row.campaigns == []}>{row.channel}</span>
                </td>
                <td class="num-cell">
                  <button
                    type="button"
                    class="growth-link"
                    phx-click="drill"
                    phx-value-channel={row.channel}
                    title="Show accounts"
                  >
                    {row.signups}
                  </button>
                </td>
                <td class="num-cell">{pct(row.activated, row.signups)}</td>
              </tr>
            </tbody>
          </table>
          <p class="growth-note">
            Channels are captured from {@since}; earlier accounts show as Unknown.
          </p>
        </section>

        <section :if={@tab == :themes} id="growth-themes-tab">
          <div class="growth-panel-head">
            <p class="growth-note">
              Initial theme of sites created in range. {if @theme_scope == :first,
                do: "Each user's first site only, so users with many sites don't dominate.",
                else: "Every site, including users' later sites."}
            </p>
            <div id="growth-theme-scope" class="admin-filters">
              <button
                :for={{scope, label} <- [first: "First sites", all: "All sites"]}
                type="button"
                class={["btn btn-sm", scope == @theme_scope && "btn-primary"]}
                phx-click="theme_scope"
                phx-value-scope={scope}
              >
                {label}
              </button>
            </div>
          </div>
          <p :if={@themes.total == 0} class="growth-empty">No sites created in this range.</p>
          <div :if={@themes.total > 0} id="growth-themes">
            <div class="growth-panel">
              <h2 class="growth-panel-title">
                How the theme was picked
                <.info text="In the new-site wizard: chosen, skipped, the default, or unknown for sites from before tracking." />
              </h2>
              <div class="growth-split" aria-hidden="true">
                <span
                  :for={choice <- ~w(chosen skipped default unknown)}
                  class={"growth-split-#{choice}"}
                  style={"width: #{width(Map.get(@themes.choices, choice, 0), @themes.total)}%"}
                >
                </span>
              </div>
              <ul class="growth-legend">
                <li :for={choice <- ~w(chosen skipped default unknown)} id={"theme-choice-#{choice}"}>
                  <span class={"growth-key growth-split-#{choice}"}></span>
                  {String.capitalize(choice)}
                  <strong>{pct(Map.get(@themes.choices, choice, 0), @themes.total)}</strong>
                </li>
              </ul>
            </div>
            <table class="table growth-table">
              <thead>
                <tr>
                  <th>Theme</th>
                  <th class="num-cell">Sites</th>
                  <th class="num-cell">Share</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={theme <- @themes.themes}>
                  <td>{theme.name || "No theme recorded"}</td>
                  <td class="num-cell">{theme.count}</td>
                  <td class="num-cell">{pct(theme.count, @themes.total)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <div
          :if={@drill}
          class="dialog-backdrop growth-drill-backdrop"
          phx-window-keydown="close_drill"
          phx-key="Escape"
        >
          <button
            type="button"
            phx-click="close_drill"
            class="dialog-close-overlay"
            aria-label="Close"
            tabindex="-1"
          >
          </button>
          <aside id="growth-drill" class="growth-drill" aria-label="Accounts">
            <div class="growth-drill-head">
              <div>
                <h2>{@drill.title}</h2>
                <p class="growth-note">
                  {accounts_note(@drill)}
                </p>
              </div>
              <button type="button" class="btn btn-sm" phx-click="close_drill" aria-label="Close">
                <.icon name="hero-x-mark" />
              </button>
            </div>
            <table class="table growth-table">
              <thead>
                <tr>
                  <th>Email</th>
                  <th>Signed up</th>
                  <th>Activated</th>
                  <th>Channel</th>
                  <th class="num-cell">Sites</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={user <- @drill.users} id={"drill-user-#{user.id}"}>
                  <td>
                    <.link navigate={~p"/admin/users/all?#{[search: user.email]}"}>
                      {user.email}
                    </.link>
                  </td>
                  <td>{date(user.signed_up_at)}</td>
                  <td>{date(user.activated_at)}</td>
                  <td>{user.channel}</td>
                  <td class="num-cell">{user.site_count}</td>
                </tr>
              </tbody>
            </table>
          </aside>
        </div>
      </div>
    </.shell>
    """
  end
end

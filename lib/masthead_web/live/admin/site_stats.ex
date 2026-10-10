defmodule MastheadWeb.AdminLive.SiteStats do
  @moduledoc """
  Views and daily unique visitors for a site over the last 30 or 90 days, as a
  daily chart and a per-path table. Picking a path narrows the chart to it;
  picking a day narrows the table to it. The range, path and day live in the
  URL. Every site is tracked, but only a paid site sees its numbers — a free
  site gets the upgrade offer instead.
  """
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.{Licenses, Stats}

  @blank %{views: nil, visitors: nil}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Statistics",
       locked?: not Licenses.paid?(socket.assigns.site),
       upgrade_modal?: not Licenses.paid?(socket.assigns.site),
       plans: Licenses.plans()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    days = if params["range"] == "90", do: 90, else: 30
    path = if params["path"] in [nil, ""], do: nil, else: params["path"]

    {:noreply,
     socket
     |> assign(days: days, path: path, day: parse_day(params["day"]))
     |> load_stats()}
  end

  defp parse_day(nil), do: nil

  defp parse_day(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp load_stats(socket) do
    if socket.assigns.locked?, do: assign_preview(socket), else: assign_stats(socket)
  end

  defp assign_stats(%{assigns: %{site: site, days: days, path: path, day: day}} = socket) do
    range = last_days(days)
    previous = Date.range(Date.add(range.first, -days), Date.add(range.first, -1))
    table_range = if day, do: Date.range(day, day), else: range

    assign(socket,
      totals: Stats.totals(site.id, range),
      previous: Stats.totals(site.id, previous),
      chart: bar_chart_data(Stats.daily(site.id, range, path), :views, :visitors),
      paths: Stats.top_paths(site.id, table_range)
    )
  end

  defp assign_preview(socket) do
    assign(socket,
      path: nil,
      day: nil,
      totals: @blank,
      previous: @blank,
      chart: preview_chart(last_days(socket.assigns.days)),
      paths: List.duplicate(%{path: nil, views: nil, visitors: nil}, 5)
    )
  end

  defp last_days(days), do: Date.range(Date.add(Date.utc_today(), 1 - days), Date.utc_today())

  @impl true
  def handle_event("open_upgrade", _params, socket) do
    {:noreply, assign(socket, upgrade_modal?: true)}
  end

  def handle_event("close_upgrade", _params, socket) do
    {:noreply, assign(socket, upgrade_modal?: false)}
  end

  def handle_event("checkout", %{"plan" => plan}, socket) do
    site = socket.assigns.site

    case Licenses.checkout_url(site, plan, url(~p"/#{site.slug}/stats")) do
      {:ok, checkout} -> {:noreply, redirect(socket, external: checkout)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp preview_chart(range) do
    %{top: nil, bars: range |> Enum.with_index() |> Enum.map(&preview_day/1)}
  end

  defp preview_day({date, i}) do
    height = Float.round(45 + 30 * :math.sin(i / 2.2) + 10 * :math.sin(i / 0.9), 1)

    %{
      date: date,
      primary: nil,
      secondary: nil,
      primary_height: height,
      secondary_height: Float.round(height * 0.4, 1)
    }
  end

  defp stats_path(site, days, path, day) do
    params =
      Enum.reject(
        [range: days, path: path, day: day && Date.to_iso8601(day)],
        &is_nil(elem(&1, 1))
      )

    ~p"/#{site.slug}/stats?#{params}"
  end

  defp toggle(current, current), do: nil
  defp toggle(_current, value), do: value

  defp delta(current, previous) when is_nil(current) or previous in [nil, 0], do: nil

  defp delta(current, previous) do
    percent = round((current - previous) / previous * 100)
    if percent >= 0, do: "+#{percent}%", else: "#{percent}%"
  end

  defp day_label(date), do: Calendar.strftime(date, "%-d %b")

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :previous, :integer, required: true

  defp stats_metric(assigns) do
    assigns = assign(assigns, :delta, delta(assigns.value, assigns.previous))

    ~H"""
    <div class="metric">
      <div class="metric-body">
        <span class="num">{@value || "—"}</span>
        <span class="metric-label">
          {@label}
          <span :if={@delta} class="stats-delta" title="Against the previous period">{@delta}</span>
        </span>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Statistics"
      site={@site}
      current_user={@current_user}
      action_count={@action_count}
      present_users={@present_users}
      flash={@flash}
      active={:stats}
    >
      <div data-feature="stats">
        <div
          class={["site-stats", @locked? && "stats-locked"]}
          phx-click={@locked? && "open_upgrade"}
          aria-hidden={@locked? && "true"}
        >
          <div class="admin-toolbar">
            <div class="admin-toolbar-row stats-toolbar-row">
              <div class="admin-filters">
                <.link
                  :for={days <- [30, 90]}
                  patch={stats_path(@site, days, @path, nil)}
                  class={["btn btn-sm", days == @days && "btn-primary"]}
                >
                  Last {days} days
                </.link>
              </div>
              <div :if={@path || @day} class="stats-active-filters">
                <.link
                  :if={@path}
                  patch={stats_path(@site, @days, nil, @day)}
                  class="author-chip"
                  title="Clear the page filter"
                >
                  Page {@path} <span aria-hidden="true">&times;</span>
                </.link>
                <.link
                  :if={@day}
                  patch={stats_path(@site, @days, @path, nil)}
                  class="author-chip"
                  title="Clear the day filter"
                >
                  On {day_label(@day)}
                  <span aria-hidden="true">&times;</span>
                </.link>
              </div>
            </div>
          </div>

          <section class="metrics">
            <.stats_metric label="Views" value={@totals.views} previous={@previous.views} />
            <.stats_metric
              label="Visitors"
              value={@totals.visitors}
              previous={@previous.visitors}
            />
          </section>

          <.bar_chart
            chart={@chart}
            nouns={["view", "visitor"]}
            patch={&stats_path(@site, @days, @path, toggle(@day, &1))}
            selected={@day}
          />

          <h2 class="section-heading">{if @day, do: "Pages on #{day_label(@day)}", else: "Pages"}</h2>

          <p :if={@paths == []} class="muted">No views in this period yet.</p>

          <table :if={@paths != []} class="table">
            <thead>
              <tr>
                <th>Page</th>
                <th class="num-cell">Views</th>
                <th class="num-cell">Visitors</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @paths} class={@path && row.path == @path && "active"}>
                <td>
                  <.link patch={stats_path(@site, @days, toggle(@path, row.path), @day)}>
                    {row.path || "—"}
                  </.link>
                </td>
                <td class="num-cell">{row.views || "—"}</td>
                <td class="num-cell">{row.visitors || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <.upgrade_modal show={@upgrade_modal?} plans={@plans} feature="Statistics" />
      </div>
    </.shell>
    """
  end
end

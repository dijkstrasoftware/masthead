defmodule MastheadWeb.AdminLive.PageIndex do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.{Content, Realtime}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Realtime.subscribe(Realtime.content_topic(socket.assigns.site.id))

    {:ok,
     assign(socket,
       status_filter: :all,
       search: "",
       sort: nil,
       page_title: "Pages — #{socket.assigns.site.name}"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(status_filter: parse_filter(params), search: params["q"] || "")
     |> load()}
  end

  @impl true
  def handle_info({:realtime, :content, _meta}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: pages_path(socket, filter, socket.assigns.search))}
  end

  def handle_event("search_list", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket, to: pages_path(socket, filter_param(socket.assigns.status_filter), query))}
  end

  def handle_event("sort_list", %{"field" => field}, socket) do
    {:noreply, socket |> assign(:sort, toggle_sort(socket.assigns.sort, field)) |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    page = Content.get_page!(socket.assigns.site.id, id)
    {:ok, _} = Content.delete_page(page)

    {:noreply,
     socket
     |> put_flash(:info, "Page deleted.")
     |> load()}
  end

  # The table shows at most this many rows; narrow with the filter or search
  # rather than paging, and the toolbar says how many matched in total.
  defp list_limit, do: 20

  defp load(socket) do
    opts = [filter: socket.assigns.status_filter, search: socket.assigns.search]

    assign(socket,
      pages:
        Content.list_pages(
          socket.assigns.site.id,
          [sort: socket.assigns.sort, limit: list_limit()] ++ opts
        ),
      pages_total: Content.count_pages(socket.assigns.site.id, opts)
    )
  end

  # Keep the filter and search in the URL so they survive a reload and stay
  # shareable, dropping each param when it's back at its default.
  defp pages_path(socket, filter, query) do
    params =
      %{}
      |> maybe_put("status", filter, &(&1 in [nil, "", "all"]))
      |> maybe_put("q", query, &(&1 in [nil, ""]))

    ~p"/#{socket.assigns.site.slug}/pages?#{params}"
  end

  defp maybe_put(params, key, value, drop?) do
    if drop?.(value), do: params, else: Map.put(params, key, value)
  end

  defp parse_filter(%{"status" => "published"}), do: :published
  defp parse_filter(%{"status" => "draft"}), do: :draft
  defp parse_filter(_params), do: :all

  defp filter_param(filter), do: Atom.to_string(filter)

  defp filtering?(filter, search), do: filter != :all or search != ""

  defp format_label(%{format: "theme", template: t}) when is_binary(t),
    do: t |> String.replace(["-", "_"], " ") |> String.capitalize()

  defp format_label(%{format: format}), do: format_label(format)
  defp format_label("markdown"), do: "Markdown"
  defp format_label("html"), do: "HTML"
  defp format_label("theme"), do: "Theme page"
  defp format_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Pages"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:pages}
      action_count={@action_count}
      present_users={@present_users}
    >
      <:actions>
        <.link navigate={~p"/#{@site.slug}/pages/import"} class="btn btn-add">
          <span class="btn-add-icon" aria-hidden="true">↑</span>
          <span class="btn-add-label">Import</span>
        </.link>
        <.link
          navigate={~p"/#{@site.slug}/pages/new"}
          class="btn btn-primary btn-add"
          data-shortcut="new"
        >
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New page</span>
        </.link>
      </:actions>

      <.list_toolbar
        :if={@pages != [] or filtering?(@status_filter, @search)}
        scope={:pages}
        filter={@status_filter}
        options={Content.status_filter_options()}
        search={@search}
        placeholder="Search pages…"
        limit={list_limit()}
        truncated?={length(@pages) == list_limit()}
        total={@pages_total}
      />

      <table :if={@pages != []} class="table table-cards">
        <thead>
          <tr>
            <.sort_th scope={:pages} field={:title} sort={@sort}>Title</.sort_th>
            <.sort_th scope={:pages} field={:format} sort={@sort}>Format</.sort_th>
            <.sort_th scope={:pages} field={:published} sort={@sort}>Status</.sort_th>
            <.sort_th scope={:pages} field={:updated_at} sort={@sort}>Updated</.sort_th>
            <th class="actions-cell"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @pages}
            class="row-link"
            phx-click={JS.navigate(~p"/#{@site.slug}/pages/#{p.id}/edit")}
          >
            <td>
              <span class="row-title">{p.title}</span>
              <div class="muted">/{p.slug}</div>
            </td>
            <td data-label="Format">
              <span class={"format-tag format-tag-" <> p.format}>{format_label(p)}</span>
            </td>
            <td data-label="Status">
              <span class={"pill pill-" <> if(p.published, do: "live", else: "draft")}>
                {if p.published, do: "Published", else: "Draft"}
              </span>
            </td>
            <td data-label="Updated"><.relative_time at={p.updated_at} /></td>
            <td class="actions-cell">
              <div class="row-actions">
                <button
                  type="button"
                  phx-click={JS.navigate(~p"/#{@site.slug}/pages/#{p.id}/edit")}
                  class="btn btn-sm"
                >
                  Edit
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm={"Delete page \"" <> p.title <> "\"?"}
                  class="btn btn-danger btn-sm"
                >
                  Delete
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <div
        :if={@pages == [] and not filtering?(@status_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-pages.svg"} alt="" class="empty-illustration" />
        <h2>No pages yet</h2>
        <p>
          Pages are standalone content such as About or Contact. Published pages appear in the site navigation.
        </p>
        <.link navigate={~p"/#{@site.slug}/pages/new"} class="btn btn-primary">+ New page</.link>
      </div>

      <div
        :if={@pages == [] and filtering?(@status_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-pages.svg"} alt="" class="empty-illustration" />
        <h2>No pages match</h2>
        <p>No pages match this filter.</p>
        <.link patch={~p"/#{@site.slug}/pages"} class="btn">Clear filter</.link>
      </div>
    </.shell>
    """
  end
end

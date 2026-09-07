defmodule MastheadWeb.AdminLive.PostIndex do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.{Content, Realtime}

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site
    if connected?(socket), do: Realtime.subscribe(Realtime.content_topic(site.id))
    tags = Content.list_tags(site.id)
    {:ok, assign(socket, tags: tags, sort: nil, page_title: "Posts — #{site.name}")}
  end

  @impl true
  def handle_info({:realtime, :content, _meta}, socket), do: {:noreply, reload_posts(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    filter = parse_filter(params)
    search = params["q"] || ""

    {:noreply,
     socket
     |> assign(tag_filter: filter, search: search)
     |> reload_posts()}
  end

  @impl true
  def handle_event("switch_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: posts_path(socket, filter, socket.assigns.search))}
  end

  def handle_event("search_list", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket, to: posts_path(socket, filter_param(socket.assigns.tag_filter), query))}
  end

  def handle_event("sort_list", %{"field" => field}, socket) do
    {:noreply, socket |> assign(:sort, toggle_sort(socket.assigns.sort, field)) |> reload_posts()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    post = Content.get_post!(socket.assigns.site.id, id)
    {:ok, _} = Content.delete_post(post)

    {:noreply,
     socket
     |> put_flash(:info, "Post deleted.")
     |> reload_posts()}
  end

  # The table shows at most this many rows; narrow with the filter or search
  # rather than paging, and the toolbar says how many matched in total.
  defp list_limit, do: 20

  defp reload_posts(socket) do
    opts = [filter: socket.assigns.tag_filter, search: socket.assigns.search]

    assign(socket,
      posts:
        Content.list_posts(
          socket.assigns.site.id,
          [sort: socket.assigns.sort, limit: list_limit()] ++ opts
        ),
      posts_total: Content.count_posts(socket.assigns.site.id, opts)
    )
  end

  # Status filters are atoms; anything else is a tag slug.
  @status_filters ~w(published draft untagged)

  defp parse_filter(%{"tag" => value}) when value in @status_filters,
    do: String.to_existing_atom(value)

  defp parse_filter(%{"tag" => slug}) when is_binary(slug) and slug not in ["", "all"], do: slug
  defp parse_filter(_params), do: :all

  defp filter_param(:all), do: "all"
  defp filter_param(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp filter_param(slug) when is_binary(slug), do: slug

  # Build a `/posts` path carrying the active tag filter and search as query
  # params, dropping the defaults so a clean list stays at a clean URL.
  defp posts_path(socket, tag, query) do
    params =
      %{}
      |> maybe_put("tag", tag, &(&1 in [nil, "", "all"]))
      |> maybe_put("q", query, &(&1 in [nil, ""]))

    ~p"/#{socket.assigns.site.slug}/posts?#{params}"
  end

  defp maybe_put(params, key, value, drop?) do
    if drop?.(value), do: params, else: Map.put(params, key, value)
  end

  # Status filters always; the tag filters (Untagged + one per tag, value is
  # the slug) only get appended once the site actually has tags.
  defp filter_options([]), do: Content.status_filter_options()

  defp filter_options(tags) do
    Content.status_filter_options() ++
      [{:untagged, "Untagged"}] ++ Enum.map(tags, &{&1.slug, &1.name})
  end

  defp filtering?(tag_filter, search), do: tag_filter != :all or search != ""

  defp format_label("markdown"), do: "Markdown"
  defp format_label("html"), do: "HTML"
  defp format_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Posts"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:posts}
      action_count={@action_count}
      present_users={@present_users}
    >
      <:actions>
        <.link navigate={~p"/#{@site.slug}/posts/import"} class="btn btn-add">
          <span class="btn-add-icon" aria-hidden="true">↑</span>
          <span class="btn-add-label">Import</span>
        </.link>
        <.link
          navigate={~p"/#{@site.slug}/posts/new"}
          class="btn btn-primary btn-add"
          data-shortcut="new"
        >
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New post</span>
        </.link>
      </:actions>

      <.list_toolbar
        :if={@posts != [] or filtering?(@tag_filter, @search)}
        scope={:posts}
        filter={@tag_filter}
        options={filter_options(@tags)}
        search={@search}
        placeholder="Search posts…"
        limit={list_limit()}
        truncated?={length(@posts) == list_limit()}
        total={@posts_total}
      />

      <table :if={@posts != []} class="table table-cards">
        <thead>
          <tr>
            <.sort_th scope={:posts} field={:title} sort={@sort}>Title</.sort_th>
            <th>Tags</th>
            <.sort_th scope={:posts} field={:format} sort={@sort}>Format</.sort_th>
            <.sort_th scope={:posts} field={:published} sort={@sort}>Status</.sort_th>
            <.sort_th scope={:posts} field={:updated_at} sort={@sort}>Updated</.sort_th>
            <th class="actions-cell"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @posts}
            class="row-link"
            phx-click={JS.navigate(~p"/#{@site.slug}/posts/#{p.id}/edit")}
          >
            <td>
              <span class="row-title">{p.title}</span>
              <div class="muted">/posts/{p.slug}</div>
            </td>
            <td data-label="Tags">
              <div class="tag-cell">
                <button
                  :for={t <- p.tags}
                  type="button"
                  class="tag-filter"
                  phx-click="switch_filter"
                  phx-value-scope="posts"
                  phx-value-filter={t.slug}
                >
                  {t.name}
                </button>
              </div>
            </td>
            <td data-label="Format">
              <span class={"format-tag format-tag-" <> p.format}>{format_label(p.format)}</span>
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
                  phx-click={JS.navigate(~p"/#{@site.slug}/posts/#{p.id}/edit")}
                  class="btn btn-sm"
                >
                  Edit
                </button>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={p.id}
                  data-confirm={"Delete post \"" <> p.title <> "\"?"}
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
        :if={@posts == [] and not filtering?(@tag_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-posts.svg"} alt="" class="empty-illustration" />
        <h2>No posts yet</h2>
        <p>
          Create your first post to start publishing. Drafts remain private until you publish them.
        </p>
        <.link navigate={~p"/#{@site.slug}/posts/new"} class="btn btn-primary">+ New post</.link>
      </div>

      <div
        :if={@posts == [] and filtering?(@tag_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-posts.svg"} alt="" class="empty-illustration" />
        <h2>No posts match</h2>
        <p>No posts match this filter.</p>
        <.link patch={~p"/#{@site.slug}/posts"} class="btn">Clear filter</.link>
      </div>
    </.shell>
    """
  end
end

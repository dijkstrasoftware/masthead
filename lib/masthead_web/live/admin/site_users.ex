defmodule MastheadWeb.AdminLive.SiteUsers do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.Accounts.User
  alias Masthead.{Accounts, Actions, Licenses, Realtime, Sites}

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site
    if connected?(socket), do: Realtime.subscribe(Realtime.members_topic(site.id))

    {:ok,
     assign(socket,
       page_title: "Users — #{site.name}",
       action_count: Actions.count_pending(site),
       modal_open?: false,
       email: ""
     )}
  end

  @impl true
  def handle_info({:realtime, :members}, socket), do: {:noreply, reload_people(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    view = parse_view(params)
    search = params["q"] || ""

    {:noreply,
     socket
     |> assign(view: view, search: search)
     |> reload_people()}
  end

  @impl true
  def handle_event("switch_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: users_path(socket, filter, socket.assigns.search))}
  end

  def handle_event("search_list", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: users_path(socket, view_param(socket.assigns.view), query))}
  end

  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: true, email: "")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: false)}
  end

  def handle_event("validate", %{"email" => email}, socket) do
    {:noreply, assign(socket, email: email)}
  end

  def handle_event("invite", %{"email" => email}, socket) do
    case Sites.invite_to_site(socket.assigns.site, email, &url(~p"/invite/#{&1}")) do
      {:ok, :added} ->
        {:noreply,
         socket
         |> assign(modal_open?: false, email: "")
         |> put_flash(:info, "#{String.trim(email)} was added to the site.")
         |> reload_people()}

      {:ok, :invited} ->
        {:noreply,
         socket
         |> assign(modal_open?: false, email: "", view: :invitations)
         |> put_flash(:info, "Invitation sent to #{String.trim(email)}.")
         |> reload_people()}

      {:error, :already_member} ->
        {:noreply, put_flash(socket, :error, "That person is already a member.")}

      {:error, :invalid_email} ->
        {:noreply, put_flash(socket, :error, "That doesn't look like a valid email address.")}

      {:error, :requires_license} ->
        {:noreply,
         socket
         |> assign(modal_open?: false)
         |> put_flash(:error, "Extra collaborators need a paid license for this site.")}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    site = socket.assigns.site
    user = Accounts.get_user!(id)

    case Sites.remove_member(site, user) do
      :ok ->
        if user.id == socket.assigns.current_user.id do
          {:noreply,
           socket
           |> put_flash(:info, "You left #{site.name}.")
           |> push_navigate(to: ~p"/sites")}
        else
          {:noreply,
           socket
           |> put_flash(:info, "#{user.email} was removed.")
           |> reload_people()}
        end

      {:error, :last_member} ->
        {:noreply, put_flash(socket, :error, "You can't remove the last member of a site.")}

      {:error, :not_member} ->
        {:noreply, reload_people(socket)}
    end
  end

  def handle_event("cancel_invitation", %{"id" => id}, socket) do
    invitation = Sites.get_site_invitation!(socket.assigns.site, id)
    {:ok, _} = Sites.delete_invitation(invitation)

    {:noreply,
     socket
     |> put_flash(:info, "Invitation to #{invitation.email} cancelled.")
     |> reload_people()}
  end

  defp reload_people(socket) do
    site = socket.assigns.site
    members = Sites.list_members(site)
    invitations = Sites.list_invitations(site)

    assign(socket,
      members: members,
      member_count: length(members),
      invitations: invitations,
      invitation_count: length(invitations),
      rows: rows_for(socket.assigns.view, members, invitations, socket.assigns.search)
    )
  end

  defp rows_for(:invitations, _members, invitations, search),
    do: filter_by_email(invitations, search)

  defp rows_for(_members_view, members, _invitations, search),
    do: filter_by_email(members, search)

  defp filter_by_email(list, ""), do: list

  defp filter_by_email(list, query) do
    q = String.downcase(query)
    Enum.filter(list, &String.contains?(String.downcase(&1.email), q))
  end

  defp parse_view(%{"view" => "invitations"}), do: :invitations
  defp parse_view(_params), do: :members

  defp view_param(:invitations), do: "invitations"
  defp view_param(_), do: "members"

  # Build a `/users` path carrying the active view + search, dropping defaults
  # so the members list stays at a clean URL.
  defp users_path(socket, view, query) do
    params =
      %{}
      |> maybe_put("view", view, &(&1 in [nil, "", "members"]))
      |> maybe_put("q", query, &(&1 in [nil, ""]))

    ~p"/#{socket.assigns.site.slug}/users?#{params}"
  end

  defp maybe_put(params, key, value, drop?) do
    if drop?.(value), do: params, else: Map.put(params, key, value)
  end

  defp filter_options(member_count, invitation_count) do
    [
      {"members", "Members (#{member_count})"},
      {"invitations", "Invitations (#{invitation_count})"}
    ]
  end

  defp searching?(search), do: search != ""

  # Query params to clear the search while keeping the active view.
  defp clear_search_params(:invitations), do: %{"view" => "invitations"}
  defp clear_search_params(_), do: %{}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Users"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:users}
      action_count={@action_count}
      present_users={@present_users}
    >
      <:actions>
        <.link
          :if={not Licenses.paid?(@site)}
          navigate={~p"/#{@site.slug}/settings"}
          class="btn btn-primary btn-add"
        >
          Upgrade to invite people
        </.link>

        <button
          :if={Licenses.paid?(@site)}
          type="button"
          phx-click="open_modal"
          class="btn btn-primary btn-add"
          data-shortcut="new"
        >
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New user</span>
        </button>
      </:actions>

      <.list_toolbar
        scope={:users}
        filter={view_param(@view)}
        options={filter_options(@member_count, @invitation_count)}
        search={@search}
        placeholder="Search people…"
        limit={length(@rows)}
        truncated?={false}
      />

      <table :if={@view == :members and @rows != []} class="table table-cards">
        <thead>
          <tr>
            <th>Email</th>
            <th>Status</th>
            <th>Joined</th>
            <th class="actions-cell"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={m <- @rows}>
            <td>
              <span class="row-title">{m.email}</span>
              <span :if={m.id == @current_user.id} class="chip chip-neutral chip-you">You</span>
            </td>
            <td data-label="Status">
              <span class={"pill pill-" <> if(User.confirmed?(m), do: "live", else: "draft")}>
                {if User.confirmed?(m), do: "Active", else: "Unconfirmed"}
              </span>
            </td>
            <td data-label="Joined"><.relative_time at={m.joined_at} /></td>
            <td class="actions-cell">
              <div class="row-actions">
                <button
                  type="button"
                  class="btn btn-danger btn-sm"
                  phx-click="remove_member"
                  phx-value-id={m.id}
                  disabled={@member_count <= 1}
                  data-confirm={
                    if m.id == @current_user.id,
                      do: "Remove yourself from #{@site.name}? You'll lose access to it.",
                      else: "Remove #{m.email} from #{@site.name}?"
                  }
                >
                  Remove
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <table :if={@view == :invitations and @rows != []} class="table table-cards">
        <thead>
          <tr>
            <th>Email</th>
            <th>Status</th>
            <th>Invited</th>
            <th class="actions-cell"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={i <- @rows}>
            <td><span class="row-title">{i.email}</span></td>
            <td data-label="Status"><span class="pill pill-draft">Invited</span></td>
            <td data-label="Invited"><.relative_time at={i.inserted_at} /></td>
            <td class="actions-cell">
              <div class="row-actions">
                <button
                  type="button"
                  class="btn btn-sm"
                  phx-click="cancel_invitation"
                  phx-value-id={i.id}
                  data-confirm={"Cancel the invitation to #{i.email}?"}
                >
                  Cancel
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@rows == [] and searching?(@search)} class="empty-state">
        <h2>No people match</h2>
        <p>
          Nothing matches “{@search}”.
          <.link patch={~p"/#{@site.slug}/users?#{clear_search_params(@view)}"}>Clear search</.link>
        </p>
      </div>

      <div
        :if={@view == :invitations and @rows == [] and not searching?(@search)}
        class="empty-state empty-state-illustrated"
      >
        <img
          src={~p"/images/illustrations/empty-invitations.svg"}
          alt=""
          class="empty-illustration"
        />
        <h2>No pending invitations</h2>
        <p :if={Licenses.paid?(@site)}>
          Invite someone by email and any pending invitations will show up here.
        </p>
        <p :if={not Licenses.paid?(@site)}>
          Inviting collaborators needs a paid license for this site.
        </p>
        <button
          :if={Licenses.paid?(@site)}
          type="button"
          phx-click="open_modal"
          class="btn btn-primary"
        >
          + New user
        </button>
        <.link
          :if={not Licenses.paid?(@site)}
          navigate={~p"/#{@site.slug}/settings"}
          class="btn btn-primary"
        >
          View license options
        </.link>
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
            <h2>Invite a collaborator</h2>
            <button type="button" phx-click="close_modal" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <form phx-submit="invite" phx-change="validate" class="dialog-form" id="invite-user-form">
            <div class="dialog-scroll">
              <label>Email</label>
              <input
                type="email"
                name="email"
                value={@email}
                placeholder="person@example.com"
                required
                autofocus
              />
              <small>
                People with an account are added straight away. New addresses get an invitation to sign up.
              </small>
            </div>

            <footer class="dialog-footer">
              <button type="button" phx-click="close_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Send invite</button>
            </footer>
          </form>
        </div>
      </div>
    </.shell>
    """
  end
end

defmodule MastheadWeb.AdminLive.Hooks do
  @moduledoc "On-mount hooks shared by admin LiveViews."
  import Phoenix.Component, only: [assign: 3]
  alias Phoenix.LiveView
  alias Masthead.{Actions, Realtime, Sites}
  alias MastheadWeb.Presence

  @doc """
  Loads the site referenced by `:site_slug` and verifies the current user is
  a member (admins may enter any site). Halts with a redirect to `/sites`
  otherwise.

  On a connected socket it also wires up the site's real-time layer once, so
  every admin page gets it for free:

    * subscribes to the per-site actions/lifecycle + per-user access topics,
    * tracks the viewer in Presence and subscribes to presence diffs,
    * seeds `@action_count` (the live sidebar badge) and `@present_users`,
    * attaches a `handle_info` hook that keeps the badge/presence in sync and
      redirects the viewer if they lose access (removed, or the site is
      deleted). Page-specific messages fall through to the LiveView's own
      `handle_info/2`.
  """
  def on_mount(:load_site, %{"site_slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    # Admins can enter any site; everyone else is scoped to sites they're a
    # member of.
    site =
      if user.admin,
        do: Sites.get_site_for_admin_by_slug!(slug),
        else: Sites.get_user_site_by_slug!(user.id, slug)

    if LiveView.connected?(socket) do
      Realtime.subscribe(Realtime.actions_topic(site.id))
      Realtime.subscribe(Realtime.lifecycle_topic(site.id))
      Realtime.subscribe(Realtime.user_topic(user.id))
      Realtime.subscribe(Realtime.presence_topic(site.id))

      Presence.track(self(), Realtime.presence_topic(site.id), to_string(user.id), %{
        display_name: user.display_name,
        avatar_path: user.avatar_path
      })
    end

    socket =
      socket
      |> assign(:site, site)
      |> assign(:action_count, Actions.count_pending(site))
      |> assign(:present_users, list_present(site.id, user.id))
      |> LiveView.attach_hook(:realtime, :handle_info, &handle_realtime/2)

    {:cont, socket}
  rescue
    Ecto.NoResultsError ->
      {:halt,
       socket
       |> LiveView.put_flash(:error, "Site not found.")
       |> LiveView.redirect(to: "/sites")}
  end

  # Keep the sidebar badge live on every admin page, then let the page also
  # react (e.g. the checklist refreshes its list, the dashboard its top action).
  defp handle_realtime({:realtime, :actions}, socket) do
    {:cont, assign(socket, :action_count, Actions.count_pending(socket.assigns.site))}
  end

  defp handle_realtime(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    present = list_present(socket.assigns.site.id, socket.assigns.current_user.id)
    {:halt, assign(socket, :present_users, present)}
  end

  defp handle_realtime({:realtime, :site_gone}, socket) do
    {:halt, leave(socket, "This site is no longer available.")}
  end

  defp handle_realtime({:realtime, :access_revoked, site_id}, socket) do
    if site_id == socket.assigns.site.id do
      {:halt, leave(socket, "You no longer have access to this site.")}
    else
      {:halt, socket}
    end
  end

  # Anything else (content/members/settings + the local {:file_picked, ...})
  # is left for the LiveView's own handle_info/2.
  defp handle_realtime(_message, socket), do: {:cont, socket}

  defp leave(socket, message) do
    socket
    |> LiveView.put_flash(:info, message)
    |> LiveView.push_navigate(to: "/sites")
  end

  # Members currently viewing the site, excluding the current user.
  defp list_present(site_id, current_user_id) do
    self_id = to_string(current_user_id)

    Realtime.presence_topic(site_id)
    |> Presence.list()
    |> Enum.reject(fn {id, _meta} -> id == self_id end)
    |> Enum.map(fn {id, %{metas: [meta | _]}} ->
      %{id: id, display_name: meta.display_name, avatar_path: meta.avatar_path}
    end)
  end
end

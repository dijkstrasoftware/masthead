defmodule MastheadWeb.UserAuth do
  @moduledoc """
  Session-based authentication. Intentionally minimal: a signed user id is
  stored in the cookie session; there is no separate tokens table, no
  remember-me, no email confirmation.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Masthead.Accounts

  @session_key :user_id

  def log_in_user(conn, user, params \\ %{}) do
    return_to = get_session(conn, :user_return_to)
    {:ok, _} = Accounts.record_login(user)

    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> maybe_put_flash(params)
    |> maybe_mark_signup(params)
    |> redirect(to: return_to || "/sites")
  end

  def log_out_user(conn) do
    conn
    |> renew_session()
    |> redirect(to: "/")
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, @session_key)

    user =
      if user_id, do: safe_get_user(user_id)

    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_session(:user_return_to, current_path(conn))
      |> Phoenix.Controller.put_flash(:error, "You must log in to access that page.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  Pins a suspended (day-30 unconfirmed) user to the verify screen: every
  authenticated page except `/verify` redirects there until they confirm.
  Runs after `require_authenticated_user`. A non-suspended (or logged-out)
  request passes straight through.
  """
  def require_verified_user(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && user.suspended_at && current_path(conn) != "/verify" do
      conn
      |> redirect(to: "/verify")
      |> halt()
    else
      conn
    end
  end

  def require_admin_user(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && user.admin do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You don't have access to that page.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> safe_get_user(id)
      end

    if user && user.admin do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You don't have access to that page.")
       |> Phoenix.LiveView.redirect(to: "/")}
    end
  end

  def on_mount(:current_user, _params, session, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> safe_get_user(id)
      end

    {:cont, Phoenix.Component.assign(socket, :current_user, user)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user =
      case session["user_id"] do
        nil -> nil
        id -> safe_get_user(id)
      end

    if user do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must log in to access that page.")
       |> Phoenix.LiveView.redirect(to: "/login")}
    end
  end

  # Pairs with the `:require_authenticated` on_mount (which assigns
  # `:current_user`): pins a suspended user to the verify screen for every
  # live route.
  def on_mount(:require_verified, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{suspended_at: at} when not is_nil(at) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/verify")}

      _ ->
        {:cont, socket}
    end
  end

  # A disabled account resolves to nil everywhere a session is read, so
  # an in-flight session (e.g. the user just disabled themselves) is
  # effectively logged out on the next request.
  defp safe_get_user(id) do
    case Accounts.get_user!(id) do
      %{disabled_at: nil} = user -> user
      _ -> nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_put_flash(conn, %{"flash" => msg}),
    do: Phoenix.Controller.put_flash(conn, :info, msg)

  defp maybe_put_flash(conn, _), do: conn

  defp maybe_mark_signup(conn, %{"signup" => method}),
    do: MastheadWeb.Attribution.mark_signup(conn, method)

  defp maybe_mark_signup(conn, _), do: conn
end

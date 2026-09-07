defmodule MastheadWeb.AccountController do
  use MastheadWeb, :controller

  import Plug.Conn

  alias Masthead.Accounts

  # Self-serve disable. Cascades to the user's sites and logs them out.
  # Reversible only via console/admin (no self re-enable by design).
  # Stays a controller action because it clears the session, which the
  # account LiveView can't do.
  def disable(conn, _params) do
    {:ok, _user} = Accounts.disable_user(conn.assigns.current_user)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Your account and all its sites have been disabled.")
    |> redirect(to: ~p"/login")
  end
end

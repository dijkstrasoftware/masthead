defmodule MastheadWeb.AccountController do
  use MastheadWeb, :controller

  import Plug.Conn

  alias Masthead.Accounts

  def show(conn, _params), do: render_account(conn)

  def update_profile(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params["user"] || %{}, ["display_name"])

    case Accounts.update_profile(user, attrs, params["avatar"]) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Profile updated.")
        |> redirect(to: ~p"/account")

      {:error, :unsupported_image} ->
        conn
        |> put_flash(:error, "That file isn't an image we can use (png, jpg, gif or webp).")
        |> render_account(status: :unprocessable_entity)

      {:error, changeset} ->
        render_account(conn, status: :unprocessable_entity, profile_changeset: changeset)
    end
  end

  def update_password(conn, %{"current_password" => current, "user" => user_params}) do
    user = conn.assigns.current_user

    case Accounts.update_user_password(user, current, user_params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Password updated.")
        |> redirect(to: ~p"/account")

      {:error, :invalid_current_password} ->
        conn
        |> put_flash(:error, "Current password is incorrect.")
        |> render_account(status: :unprocessable_entity)

      {:error, changeset} ->
        render_account(conn, status: :unprocessable_entity, password_changeset: changeset)
    end
  end

  # Self-serve disable. Cascades to the user's sites and logs them out.
  # Reversible only via console/admin (no self re-enable by design).
  def disable(conn, _params) do
    {:ok, _user} = Accounts.disable_user(conn.assigns.current_user)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Your account and all its sites have been disabled.")
    |> redirect(to: ~p"/login")
  end

  defp render_account(conn, overrides \\ []) do
    user = conn.assigns.current_user
    {status, overrides} = Keyword.pop(overrides, :status)

    conn
    |> put_status(status || :ok)
    |> render(
      :show,
      Keyword.merge(
        [
          user: user,
          profile_changeset: Accounts.change_user_profile(user, %{}),
          password_changeset: Accounts.change_user_password(user)
        ],
        overrides
      )
    )
  end
end

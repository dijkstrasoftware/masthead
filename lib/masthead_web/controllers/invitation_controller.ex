defmodule MastheadWeb.InvitationController do
  use MastheadWeb, :controller

  alias Masthead.Accounts
  alias Masthead.Accounts.User
  alias Masthead.Sites
  alias Masthead.Sites.SiteInvitation
  alias MastheadWeb.{Attribution, UserAuth}

  # GET /invite/:token — the link from the invitation email.
  def new(conn, %{"token" => token}) do
    case Sites.get_invitation_by_token(token) do
      %SiteInvitation{} = invitation ->
        case Accounts.get_user_by_email(invitation.email) do
          %User{} = user ->
            # The email already has an account — add them and skip signup.
            {:ok, _} = Sites.accept_invitation(invitation, user)
            redirect_existing_user(conn, invitation, user)

          nil ->
            changeset = Accounts.change_user_registration(%User{}, %{"email" => invitation.email})
            render(conn, :new, changeset: changeset, invitation: invitation, token: token)
        end

      nil ->
        invalid_link(conn)
    end
  end

  # POST /invite/:token — create the account and join the site.
  def create(conn, %{"token" => token, "user" => user_params}) do
    case Sites.get_invitation_by_token(token) do
      %SiteInvitation{} = invitation ->
        # The invited email is authoritative; the form field is display-only.
        attrs = Map.put(user_params, "email", invitation.email)

        case Accounts.register_invited_user(attrs, Attribution.user_attrs(conn)) do
          {:ok, user} ->
            {:ok, _} = Sites.accept_invitation(invitation, user)
            Accounts.deliver_welcome(user, url(~p"/sites"))

            conn
            |> Attribution.delete()
            |> put_session(:user_return_to, ~p"/#{invitation.site.slug}")
            |> UserAuth.log_in_user(user, %{
              "flash" => "Welcome! You've joined #{invitation.site.name}."
            })

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> render(:new, changeset: changeset, invitation: invitation, token: token)
        end

      nil ->
        invalid_link(conn)
    end
  end

  defp redirect_existing_user(conn, invitation, user) do
    if conn.assigns[:current_user] && conn.assigns.current_user.id == user.id do
      conn
      |> put_flash(:info, "You've been added to #{invitation.site.name}.")
      |> redirect(to: ~p"/#{invitation.site.slug}")
    else
      conn
      |> put_flash(:info, "You've been added to #{invitation.site.name}. Log in to access it.")
      |> redirect(to: ~p"/login")
    end
  end

  defp invalid_link(conn) do
    conn
    |> put_flash(:error, "That invitation link is invalid or has expired.")
    |> redirect(to: ~p"/signup")
  end
end

defmodule MastheadWeb.RegistrationController do
  use MastheadWeb, :controller

  alias Masthead.Accounts
  alias MastheadWeb.{Attribution, UserAuth}

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%Masthead.Accounts.User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params, Attribution.user_attrs(conn)) do
      {:ok, user} ->
        Accounts.deliver_user_confirmation_instructions(
          user,
          &url(~p"/confirm/#{&1}")
        )

        conn
        |> Attribution.delete()
        |> UserAuth.log_in_user(user, %{
          "flash" => "Account created. Check your email to confirm it."
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:new, changeset: changeset)
    end
  end
end

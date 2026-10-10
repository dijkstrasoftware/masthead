defmodule MastheadWeb.AuthController do
  @moduledoc """
  OAuth sign-in via Ueberauth (Google, GitHub). The `Ueberauth` plug
  handles the redirect to the provider in the request phase and populates
  `:ueberauth_auth` / `:ueberauth_failure` in the callback phase.
  """
  use MastheadWeb, :controller

  plug Ueberauth

  alias Masthead.Accounts
  alias MastheadWeb.{Attribution, UserAuth}

  # Reached only if the Ueberauth plug didn't recognise the provider
  # (it otherwise redirects to the provider during the request phase).
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown sign-in provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Sign-in was cancelled or failed. Please try again.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    # New OAuth accounts are confirmed on creation, so `on_create` is their one
    # welcome trigger; returning users never fire it.
    on_create = fn user -> Accounts.deliver_welcome(user, url(~p"/sites")) end

    opts = [on_create: on_create, attribution: Attribution.user_attrs(conn)]

    case Accounts.get_or_create_user_from_oauth(oauth_info(auth), opts) do
      {:ok, user} ->
        conn
        |> Attribution.delete()
        |> UserAuth.log_in_user(user, %{"flash" => "Signed in."})

      {:error, :disabled} ->
        fail(conn, "This account has been disabled. Contact support if this is unexpected.")

      {:error, :email_unverified} ->
        fail(
          conn,
          "Your #{auth.provider} email isn't verified, so we can't link it to an existing account."
        )

      {:error, :no_email} ->
        fail(conn, "Your #{auth.provider} account didn't share an email address.")

      {:error, _changeset} ->
        fail(conn, "Could not complete sign-in. Please try again.")
    end
  end

  defp fail(conn, msg) do
    conn |> put_flash(:error, msg) |> redirect(to: ~p"/login")
  end

  defp oauth_info(auth) do
    %{
      provider: auth.provider,
      uid: auth.uid,
      email: auth.info && auth.info.email,
      email_verified: email_verified?(auth)
    }
  end

  # Google returns an explicit `email_verified` claim. GitHub only
  # surfaces the account's primary email (which GitHub itself verifies)
  # when the `user:email` scope is granted, so we trust it.
  defp email_verified?(%{provider: :google} = auth) do
    raw = (auth.extra && auth.extra.raw_info) || %{}
    user = Map.get(raw, :user) || Map.get(raw, "user") || %{}
    Map.get(user, "email_verified") in [true, "true"]
  end

  defp email_verified?(%{provider: :github} = auth) do
    is_binary(auth.info && auth.info.email)
  end

  defp email_verified?(_), do: false
end

defmodule MastheadWeb.SessionHTML do
  use MastheadWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout eyebrow="Welcome back" title="Your site's admin, built from its theme.">
      <:story>
        <.home_flow />
      </:story>

      <h1>Sign in</h1>
      <p class="auth-sub">to manage your sites on Masthead.</p>
      <p :if={@error} class="error">{@error}</p>

      <form action={~p"/login"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <label>
          Email
          <input
            type="email"
            name="user[email]"
            value={@email}
            autocomplete="email"
            required
            autofocus
          />
        </label>
        <label>
          <span class="auth-label-row">
            Password <a href={~p"/reset-password"}>Forgot it?</a>
          </span>
          <.password_input name="user[password]" autocomplete="current-password" required />
        </label>
        <button type="submit">Sign in</button>
      </form>

      <MastheadWeb.SSO.buttons />

      <p class="meta">
        New to Masthead? <a href={~p"/signup"}>Create a free account</a>
      </p>
    </.auth_layout>
    """
  end
end

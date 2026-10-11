defmodule MastheadWeb.RegistrationHTML do
  use MastheadWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout eyebrow="Start free" title="Your website, and the admin that fits it.">
      <:story>
        <ul class="auth-points">
          <li><.icon name="hero-check" /> Unlimited posts and pages, in Markdown or HTML</li>
          <li><.icon name="hero-check" /> Themes from the marketplace, or upload your own</li>
          <li>
            <.icon name="hero-check" />
            <span>A <code>yoursite.masthead.site</code> address with automatic HTTPS</span>
          </li>
          <li><.icon name="hero-check" /> Import an existing Hugo site</li>
        </ul>
        <p class="auth-note">No card, no trial. A free site never expires.</p>
      </:story>

      <h1>Create your Masthead account</h1>
      <p class="auth-sub">You'll pick a theme for your first site right after.</p>

      <form action={~p"/signup"} method="post" data-confirm-password>
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.error_list changeset={@changeset} />
        <label>
          Email
          <input
            type="email"
            name="user[email]"
            value={Ecto.Changeset.get_field(@changeset, :email) || ""}
            autocomplete="email"
            required
            autofocus
          />
        </label>
        <label>
          Password <span class="auth-hint">at least 8 characters</span>
          <.password_input
            name="user[password]"
            autocomplete="new-password"
            required
            minlength="8"
          />
        </label>
        <label>
          Confirm password
          <.password_input
            name="user[password_confirmation]"
            autocomplete="new-password"
            required
            minlength="8"
          />
        </label>
        <button type="submit">Create account</button>
      </form>

      <MastheadWeb.SSO.buttons />

      <p class="meta">
        Already have an account? <a href={~p"/login"}>Sign in</a>
      </p>
    </.auth_layout>
    """
  end

  attr :changeset, :map, required: true

  defp error_list(assigns) do
    ~H"""
    <ul :if={@changeset.action && @changeset.errors != []} class="errors">
      <li :for={{field, {msg, _}} <- @changeset.errors}>{field}: {msg}</li>
    </ul>
    """
  end
end

defmodule MastheadWeb.InvitationHTML do
  use MastheadWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout eyebrow="You're invited" title={"Join #{@invitation.site.name}."}>
      <:story>
        <p class="auth-lede">
          You've been invited to help run this site. Its theme decides what there is to
          manage, so you'll only see what this website needs.
        </p>
      </:story>

      <h1>Create your account</h1>
      <p class="auth-sub">and join {@invitation.site.name} as a collaborator.</p>

      <form action={~p"/invite/#{@token}"} method="post" data-confirm-password>
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <.error_list changeset={@changeset} />
        <label>
          Email <input type="email" name="user[email]" value={@invitation.email} readonly />
        </label>
        <label>
          Password <span class="auth-hint">at least 8 characters</span>
          <.password_input
            name="user[password]"
            autocomplete="new-password"
            required
            minlength="8"
            autofocus
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
        <button type="submit">Create account &amp; join</button>
      </form>

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

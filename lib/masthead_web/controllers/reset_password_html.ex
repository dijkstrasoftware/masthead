defmodule MastheadWeb.ResetPasswordHTML do
  use MastheadWeb, :html

  def new(assigns) do
    ~H"""
    <.auth_layout eyebrow="Account" title="Locked out? It happens.">
      <:story>
        <p class="auth-lede">
          We'll email you a link to choose a new password. Your sites keep running in the
          meantime.
        </p>
      </:story>

      <h1>Reset your password</h1>
      <p class="auth-sub">
        Enter your account email and we'll send you a link to choose a new password.
      </p>

      <form action={~p"/reset-password"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <label>
          Email <input type="email" name="user[email]" autocomplete="email" required autofocus />
        </label>
        <button type="submit">Send reset link</button>
      </form>

      <p class="meta">
        Remembered it? <a href={~p"/login"}>Sign in</a>
      </p>
    </.auth_layout>
    """
  end

  attr :changeset, :map, required: true
  attr :token, :string, required: true

  def edit(assigns) do
    ~H"""
    <.auth_layout eyebrow="Account" title="Pick a new password.">
      <:story>
        <p class="auth-lede">
          Once it's saved, sign in with your new password.
        </p>
      </:story>

      <h1>Choose a new password</h1>

      <form action={~p"/reset-password/#{@token}"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <input type="hidden" name="_method" value="put" />
        <.error_list changeset={@changeset} />
        <label>
          New password <span class="auth-hint">at least 8 characters</span>
          <.password_input
            name="user[password]"
            autocomplete="new-password"
            required
            minlength="8"
            autofocus
          />
        </label>
        <button type="submit">Update password</button>
      </form>

      <p class="meta">
        <a href={~p"/login"}>Back to sign in</a>
      </p>
    </.auth_layout>
    """
  end

  attr :changeset, :map, required: true

  defp error_list(assigns) do
    ~H"""
    <ul :if={@changeset.errors != []} class="errors">
      <li :for={{field, {msg, opts}} <- @changeset.errors}>{field}: {interpolate(msg, opts)}</li>
    </ul>
    """
  end

  # Ecto stores messages with `%{key}` placeholders + the values in opts
  # (e.g. {"should be at least %{count} character(s)", count: 8}).
  defp interpolate(msg, opts) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end

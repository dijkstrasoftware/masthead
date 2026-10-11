defmodule MastheadWeb.VerifyHTML do
  use MastheadWeb, :html

  def show(assigns) do
    ~H"""
    <.auth_layout
      current_user={assigns[:current_user]}
      eyebrow="One step left"
      title="Confirm your email."
    >
      <:story>
        <p class="auth-lede">
          Confirming brings your account and its sites back automatically.
        </p>
      </:story>

      <h1>Confirm your email to continue</h1>
      <p class="auth-sub">
        Your account has been suspended because <strong>{@email}</strong>
        was never confirmed. Any site with no other confirmed member is offline
        until you confirm.
      </p>

      <form action={~p"/confirm"} method="post">
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <button type="submit">Send me a confirmation link</button>
      </form>

      <p class="meta">
        Check your inbox for the confirmation email, then click the link inside it.
      </p>
      <p class="meta">
        <.link href={~p"/logout"} method="delete">Log out</.link>
      </p>
    </.auth_layout>
    """
  end
end

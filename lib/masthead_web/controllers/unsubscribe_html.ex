defmodule MastheadWeb.UnsubscribeHTML do
  use MastheadWeb, :html

  def onboarding(assigns) do
    ~H"""
    <.auth_layout
      eyebrow="Email preferences"
      title={if @unsubscribed, do: "You're unsubscribed.", else: "Link expired."}
    >
      <%= if @unsubscribed do %>
        <h1>No more product emails</h1>
        <p class="auth-sub">
          You won't receive product emails from Masthead anymore. You can turn them
          back on in your account settings.
        </p>
      <% else %>
        <h1>This link no longer works</h1>
        <p class="auth-sub">This unsubscribe link is invalid or has expired.</p>
      <% end %>

      <p class="meta">
        <a href={~p"/"}>Back to Masthead</a>
      </p>
    </.auth_layout>
    """
  end
end

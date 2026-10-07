defmodule MastheadWeb.UnsubscribeHTML do
  use MastheadWeb, :html

  def onboarding(assigns) do
    ~H"""
    <div class="auth-page">
      <div class="auth-card">
        <%= if @unsubscribed do %>
          <h1>You're unsubscribed</h1>
          <p>
            You won't receive product emails from Masthead anymore. You can turn them
            back on in your account settings.
          </p>
        <% else %>
          <h1>Link expired</h1>
          <p>This unsubscribe link is invalid or has expired.</p>
        <% end %>

        <p class="meta">
          <a href={~p"/"}>Back to Masthead</a>
        </p>
      </div>
    </div>
    """
  end
end

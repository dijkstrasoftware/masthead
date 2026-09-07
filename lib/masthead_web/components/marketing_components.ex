defmodule MastheadWeb.MarketingComponents do
  @moduledoc """
  The marketing chrome — the nav and footer of the homepage. They also dress
  the signed-out marketplace, which is a public page wearing an admin body,
  so both surfaces share one header and one footer instead of drifting.

  `current_user` is optional: signed in, the calls to action become links
  into the dashboard.
  """
  use Phoenix.Component
  use MastheadWeb, :verified_routes

  attr :current_user, :map, default: nil
  attr :active, :atom, default: nil, doc: ":marketplace | :pricing | nil"

  def marketing_nav(assigns) do
    ~H"""
    <nav class="landing-nav">
      <.link href={~p"/"} class="brand">
        <img src={~p"/images/logo.png"} alt="Masthead" class="brand-logo" />
        <span class="brand-name">Masthead</span>
      </.link>
      <%!-- A native checkbox, not a JS toggle: this nav also renders on the
            dead landing page, where LiveView's JS commands don't run. --%>
      <input type="checkbox" id="nav-toggle" class="nav-toggle" aria-label="Menu" />
      <label for="nav-toggle" class="nav-burger">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="1.75"
          stroke="currentColor"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"
          />
        </svg>
      </label>
      <div class="nav-menu">
        <div class="nav-links">
          <.link
            navigate={~p"/marketplace"}
            class={["nav-link", @active == :marketplace && "is-active"]}
            aria-current={@active == :marketplace && "page"}
          >
            Marketplace
          </.link>
          <.link
            navigate={~p"/pricing"}
            class={["nav-link", @active == :pricing && "is-active"]}
            aria-current={@active == :pricing && "page"}
          >
            Pricing
          </.link>
          <a href="https://docs.masthead.site" target="_blank" rel="noopener" class="nav-link">
            Docs<.external_mark />
          </a>
        </div>

        <div class="nav-cta">
          <.link :if={@current_user} navigate={~p"/sites"} class="btn btn-primary btn-sm">
            Open dashboard &rarr;
          </.link>
          <.link :if={is_nil(@current_user)} navigate={~p"/login"} class="btn btn-primary btn-sm">
            Login
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  attr :current_user, :map, default: nil

  def marketing_footer(assigns) do
    ~H"""
    <footer class="landing-footer">
      <div class="landing-footer-brand">
        <span class="brand-mark">●</span>
        <strong>Masthead</strong>
        <span class="landing-version">v{Application.spec(:masthead, :vsn)}</span>
      </div>
      <div class="landing-footer-links">
        <.link navigate={~p"/marketplace"}>Marketplace</.link>
        <.link navigate={~p"/pricing"}>Pricing</.link>
        <a href="https://blog.masthead.site" target="_blank" rel="noopener">Blog</a>
        <a href="https://docs.masthead.site" target="_blank" rel="noopener">Docs</a>
        <.link :if={@current_user} navigate={~p"/sites"}>Dashboard</.link>
        <.link :if={is_nil(@current_user)} navigate={~p"/login"}>Log in</.link>
        <.link :if={is_nil(@current_user)} navigate={~p"/signup"}>Sign up</.link>
      </div>
      <a
        href="https://github.com/dijkstrasoftware/masthead"
        target="_blank"
        rel="noopener"
        class="github-btn"
      >
        <.github_mark />
        <span>GitHub</span>
      </a>
    </footer>
    """
  end

  defp external_mark(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      class="external-mark"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
      />
    </svg>
    """
  end

  defp github_mark(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 .5C5.6.5.5 5.6.5 12c0 5.1 3.3 9.4 7.9 10.9.6.1.8-.2.8-.6v-2c-3.2.7-3.9-1.4-3.9-1.4-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.8 1.2 1.8 1.2 1 1.8 2.7 1.3 3.4 1 .1-.8.4-1.3.8-1.6-2.6-.3-5.3-1.3-5.3-5.8 0-1.3.5-2.3 1.2-3.1-.1-.3-.5-1.5.1-3.2 0 0 1-.3 3.3 1.2 1-.3 2-.4 3-.4s2 .1 3 .4c2.3-1.5 3.3-1.2 3.3-1.2.6 1.7.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.1 0 4.5-2.7 5.5-5.3 5.8.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6 4.6-1.5 7.9-5.9 7.9-10.9C23.5 5.6 18.4.5 12 .5z" />
    </svg>
    """
  end
end

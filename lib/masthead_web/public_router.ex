defmodule MastheadWeb.PublicRouter do
  @moduledoc """
  Router for site-on-subdomain requests. Dispatched to by the Endpoint when
  `MastheadWeb.Plugs.Subdomain` has resolved a site.
  """
  use MastheadWeb, :router

  pipeline :public do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
  end

  scope "/", MastheadWeb do
    get "/robots.txt", PublicSeoController, :robots
    get "/sitemap.xml", PublicSeoController, :sitemap
    get "/llms.txt", PublicSeoController, :llms
  end

  scope "/", MastheadWeb do
    pipe_through :public

    get "/", PublicController, :index
    get "/search", PublicController, :search
    get "/_masthead/no-track", PublicController, :no_track
    get "/posts/:slug", PublicController, :show_post
    get "/:slug", PublicController, :show_page
  end
end

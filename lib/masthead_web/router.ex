defmodule MastheadWeb.Router do
  use MastheadWeb, :router

  import MastheadWeb.UserAuth,
    only: [
      fetch_current_user: 2,
      require_authenticated_user: 2,
      require_verified_user: 2,
      require_admin_user: 2
    ]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MastheadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :require_admin do
    plug :require_admin_user
  end

  scope "/webhooks", MastheadWeb do
    post "/payments", WebhookController, :payments
  end

  scope "/", MastheadWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/pricing", PageController, :pricing

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete

    get "/signup", RegistrationController, :new
    post "/signup", RegistrationController, :create

    # Site-invitation signup for an address without an account yet.
    get "/invite/:token", InvitationController, :new
    post "/invite/:token", InvitationController, :create

    get "/confirm/:token", ConfirmationController, :confirm
    post "/confirm", ConfirmationController, :create

    get "/unsubscribe/onboarding/:token", UnsubscribeController, :onboarding

    get "/reset-password", ResetPasswordController, :new
    post "/reset-password", ResetPasswordController, :create
    get "/reset-password/:token", ResetPasswordController, :edit
    put "/reset-password/:token", ResetPasswordController, :update
  end

  scope "/auth", MastheadWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    post "/:provider/callback", AuthController, :callback
  end

  # The marketplace is the one signed-out surface of the admin host: anyone can
  # browse the published themes and open a theme's page. Uploading, "My themes"
  # and installing still need an account — the LiveViews hide that chrome from a
  # visitor. Declared before the `/:site_slug` catch-all further down.
  scope "/", MastheadWeb do
    pipe_through :browser

    # The Themes section merged into the Marketplace hub; keep the old URL.
    get "/themes", PageController, :themes_redirect

    live_session :marketplace, on_mount: [{MastheadWeb.UserAuth, :current_user}] do
      # The active filter lives in the URL so each view is linkable.
      live "/marketplace", AdminLive.Marketplace, :all
      live "/marketplace/verified", AdminLive.Marketplace, :verified
      live "/marketplace/community", AdminLive.Marketplace, :community
      live "/marketplace/my-themes", AdminLive.Marketplace, :mine
      live "/marketplace/themes/:theme_id", AdminLive.ThemeShow, :show
    end
  end

  # Admin controller routes (platform admins only).
  scope "/admin", MastheadWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    get "/themes/:id/download", AdminController, :download_theme
  end

  scope "/", MastheadWeb do
    pipe_through [:browser, :require_authenticated_user, :require_verified_user]

    # The forced-verify screen for suspended accounts. Must sit inside the
    # verified-user pipeline (it exempts "/verify") so it's the one authenticated
    # page a suspended user can reach.
    get "/verify", VerifyController, :show

    post "/account/disable", AccountController, :disable

    # Admin overview — defined before the `/:site_slug` catch-all so "admin"
    # isn't resolved as a site slug.
    live_session :admin,
      on_mount: [
        {MastheadWeb.UserAuth, :require_admin},
        {MastheadWeb.UserAuth, :require_verified}
      ] do
      live "/admin", AdminLive.Console, :index
      live "/admin/:tab", AdminLive.Console, :index
      live "/admin/:tab/:filter", AdminLive.Console, :index
    end

    live_session :authenticated,
      on_mount: [
        {MastheadWeb.UserAuth, :require_authenticated},
        {MastheadWeb.UserAuth, :require_verified}
      ] do
      live "/sites", AdminLive.SiteIndex, :index
      live "/account", AdminLive.Account, :show

      live "/:site_slug", AdminLive.SiteDashboard, :show
      live "/:site_slug/settings", AdminLive.SiteSettings, :edit
      live "/:site_slug/import", AdminLive.SiteImport, :index
      live "/:site_slug/theme", AdminLive.SiteTheme, :edit
      live "/:site_slug/checklist", AdminLive.Checklist, :index
      live "/:site_slug/domain", AdminLive.DomainSetup, :show
      live "/:site_slug/users", AdminLive.SiteUsers, :index

      live "/:site_slug/posts", AdminLive.PostIndex, :index
      live "/:site_slug/posts/new", AdminLive.PostForm, :new
      live "/:site_slug/posts/import", AdminLive.PostForm, :import
      live "/:site_slug/posts/:id/edit", AdminLive.PostForm, :edit

      live "/:site_slug/pages", AdminLive.PageIndex, :index
      live "/:site_slug/pages/new", AdminLive.PageForm, :new
      live "/:site_slug/pages/import", AdminLive.PageForm, :import
      live "/:site_slug/pages/:id/edit", AdminLive.PageForm, :edit

      live "/:site_slug/uploads", AdminLive.UploadIndex, :index
      live "/:site_slug/uploads/:id", AdminLive.UploadShow, :show
    end
  end

  if Application.compile_env(:masthead, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MastheadWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

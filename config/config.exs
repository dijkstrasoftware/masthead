# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :masthead,
  ecto_repos: [Masthead.Repo],
  generators: [timestamp_type: :utc_datetime]

# Hosts treated as the bare app surface (no subdomain). Overridden via APP_HOSTS
# at runtime in prod. Dev defaults to lvh.me so `*.lvh.me:4000` resolves to
# 127.0.0.1 without any /etc/hosts changes.
config :masthead, :app_hosts, ~w(lvh.me localhost 127.0.0.1)

# Used by the admin to build the public URL of a site (for "View site" links
# and the slug helper text in the new-site form). Prod overrides this in
# runtime.exs with the real domain + https.
config :masthead, :site_url,
  scheme: "http",
  host: "lvh.me",
  port: 4000

# Custom-domain feature. `cname_target` is the hostname users point
# their domain's CNAME at — our own branded edge host, not the
# underlying `*.fly.dev` app name, so the target is stable and never
# exposes the hosting provider to customers' DNS. `txt_prefix` is the
# label under which the ownership token is published as a TXT record.
# Prod overrides `cname_target` from the primary app host in runtime.exs.
config :masthead, :custom_domain,
  cname_target: "masthead.site",
  txt_prefix: "_masthead-verify"

# Configure the endpoint
config :masthead, MastheadWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MastheadWeb.ErrorHTML, json: MastheadWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Masthead.PubSub,
  live_view: [signing_salt: "MCz9rXle"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  masthead: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  # Use the npm-installed Tailwind CLI (assets/package.json) instead of the
  # standalone GitHub-release binary, so the Docker/Fly build never has to
  # reach github.com to download it. `npm ci` provides this during the build.
  path: Path.expand("../assets/node_modules/.bin/tailwindcss", __DIR__),
  masthead: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Transactional email (Swoosh). Adapter is environment-specific: Local in
# dev, Test in test, Resend in prod (see the respective config files).
# Hackney is the HTTP API client (already a dependency).
config :masthead, Masthead.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Default "from" for account email. Prod overrides this from MAIL_FROM in
# runtime.exs once a verified sending domain exists.
config :masthead, :mail_from, {"Masthead", "noreply@masthead.site"}

# Background jobs (Oban). The maintenance queue runs the unconfirmed-account
# sweep; mailers runs transactional email with retries. The Cron schedule
# itself is attached where the job is defined. Test disables execution
# (`testing: :manual`).
# Social sign-in (Ueberauth). Client id/secret per provider are read
# from env in runtime.exs (prod) and dev.exs (local testing) — only set
# when present so a missing provider doesn't break boot.
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]},
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

# Ueberauth's OAuth strategies use Tesla; route it through Hackney
# (already a dependency) instead of the bare :httpc default.
config :tesla, adapter: Tesla.Adapter.Hackney

config :masthead, Oban,
  repo: Masthead.Repo,
  # `thumbnails` is deliberately narrow: each job forks pdftoppm, so the
  # concurrency here is a cap on simultaneous rasterizer subprocesses.
  queues: [mailers: 10, maintenance: 5, thumbnails: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"30 2 * * *", Masthead.Workers.PruneStats},
       # Daily 03:00 UTC: suspend accounts unconfirmed for 30+ days.
       {"0 3 * * *", Masthead.Workers.SuspendUnconfirmed},
       # Daily 03:30 UTC: staged lifecycle emails (day 14 nudge, day 16/23 warnings).
       {"30 3 * * *", Masthead.Workers.LifecycleEmails},
       # Daily 04:00 UTC: remind owners of onboarding actions open for 7+ days.
       {"0 4 * * *", Masthead.Workers.OnboardingReminder}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

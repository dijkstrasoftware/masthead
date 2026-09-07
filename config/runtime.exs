import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/masthead start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :masthead, MastheadWeb.Endpoint, server: true
end

config :masthead, MastheadWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Social sign-in credentials. Read in every environment so the flow can
# be tested locally by exporting the env vars. A provider is only
# configured when its client id is present, so an unconfigured provider
# never breaks boot (the button just fails with a clear error).
if google_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: google_id,
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
end

if github_id = System.get_env("GITHUB_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_id,
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
end

if config_env() != :test and System.get_env("STRIPE_SECRET_KEY") do
  config :masthead, :payments, Masthead.Payments.Stripe
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :masthead, Masthead.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :masthead, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Hosts treated as the bare app surface (no subdomain). Everything that
  # ends in ".<one of these>" is treated as a site subdomain.
  app_hosts =
    case System.get_env("APP_HOSTS") do
      nil -> [host]
      raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :masthead, :app_hosts, app_hosts

  # Used by the admin "View site" link to build a site's public URL.
  config :masthead, :site_url,
    scheme: "https",
    host: List.first(app_hosts),
    port: nil

  # Custom domains: users delegate by CNAME-ing their domain at our
  # primary app host (a stable, branded edge we control) rather than the
  # underlying `*.fly.dev` app name — so the target survives infra
  # changes and never leaks the hosting provider into customers' DNS.
  config :masthead, :custom_domain,
    cname_target: List.first(app_hosts),
    txt_prefix: "_masthead-verify"

  config :masthead, MastheadWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: {MastheadWeb.CheckOrigin, :allowed?, [%{host: host, app_hosts: app_hosts}]},
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Object storage. If a BUCKET_NAME env var is set, use the S3 adapter
  # (Tigris on Fly by default — works with any S3-compatible service).
  # Otherwise fall back to local-disk storage.
  if System.get_env("BUCKET_NAME") do
    s3_endpoint = System.get_env("AWS_ENDPOINT_URL_S3") || "https://fly.storage.tigris.dev"
    s3_host = URI.parse(s3_endpoint).host
    s3_region = System.get_env("AWS_REGION") || "auto"

    config :masthead, Masthead.Storage, adapter: Masthead.Storage.S3

    config :ex_aws,
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      region: s3_region

    config :ex_aws, :s3,
      scheme: "https://",
      host: s3_host,
      region: s3_region
  end

  # Transactional email via Resend. Account confirmation and password
  # reset depend on this, so a missing key is a hard boot failure (same
  # posture as DATABASE_URL above) rather than silently dropping mail.
  config :masthead, Masthead.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key:
      System.get_env("RESEND_API_KEY") ||
        raise("""
        environment variable RESEND_API_KEY is missing.
        Create a Resend API key and set it as a Fly secret.
        """)

  config :masthead,
         :mail_from,
         {System.get_env("MAIL_FROM_NAME") || "Masthead",
          System.get_env("MAIL_FROM") ||
            raise("""
            environment variable MAIL_FROM is missing.
            Set it to an address on your Resend-verified sending domain,
            e.g. noreply@masthead.site
            """)}

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :masthead, MastheadWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :masthead, MastheadWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Masthead

Open-source, multi-tenant publishing platform for blogs and small business
sites. Each site runs on its own subdomain, content is written in Markdown
or HTML, and the whole project deploys as a single application.

A hosted instance runs at [**masthead.site**](https://masthead.site)
— sign up there to use Masthead without operating it yourself, or follow the
instructions below to self-host.

## What you get

- **Unlimited sites, one account.** Manage multiple brands or products
  from a single dashboard.
- **Subdomains out of the box, custom domains on paid sites.** Every site is
  served at `<slug>.<your-domain>`; paid sites can attach their own domain.
- **Markdown and HTML editors.** Live preview, syntax-aware editor.
- **Built-in blog pages.** Mark any page as a blog and the post list is
  generated for you. Set it as the homepage to make it the front page.
- **Image library.** Upload once, paste ready-made Markdown or HTML embed
  snippets into any post or page. PDFs get a page-one thumbnail.
- **Themes and a theme marketplace.** Ships with one built-in theme;
  more can be installed from the marketplace or uploaded as a package.
- **Site import.** Bring posts, pages and images over from a `.zip` export
  (Hugo sites supported).
- **Safe HTML by default.** All rendered content is run through an
  allowlist sanitizer before reaching the browser.
- **Paid plans (optional).** Custom domains, statistics and site
  collaborators are gated behind a per-site license, billed through Stripe.

## Architecture

- Phoenix LiveView app, single Postgres database, single OTP release.
  Background jobs (email, PDF thumbnails, maintenance) run on Oban in the
  same database.
- Multi-tenancy resolved at the `Host:` header by
  `MastheadWeb.Plugs.Subdomain` — site rows in the `sites` table are looked
  up by subdomain (or custom domain) on every request and assigned to
  `conn.assigns.current_site`.
- Two routers: `MastheadWeb.PublicRouter` serves site-scoped public URLs
  (`/`, `/posts/:slug`, `/:slug`); `MastheadWeb.Router` serves the admin
  and marketing surface on the bare app host.
- Object storage is pluggable via `Masthead.Storage.Adapter`. Ships with a
  local-disk adapter for development and an S3-compatible adapter for
  production (works with any S3-compatible provider).

## Run it locally

Requires Elixir 1.18+, Erlang/OTP 28+, Postgres 14+ and Node.js (npm, for
the editor's JavaScript dependencies).

```bash
mix deps.get
(cd assets && npm install)
mix ecto.setup        # creates DB, migrates, seeds a demo site
mix phx.server
```

Open:

- `http://localhost:4000` — sign in / admin
- `http://localhost:4000/admin` — platform admin console
- `http://demo.lvh.me:4000` — seeded demo site

`*.lvh.me` is a public DNS record that resolves to `127.0.0.1`, so
subdomain-based tenancy works in dev without `/etc/hosts` edits.

Seeded credentials (a platform admin):

```
email:    admin@example.com
password: password1234
```

In dev, a `.env` file in the project root is loaded automatically, so you
can put any of the variables below there (e.g. to try social sign-in).

## Configuration

All prod config is read from environment variables (see
[`config/runtime.exs`](config/runtime.exs)).

### Required

The release refuses to boot without these.

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection string, e.g. `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | Cookie / LiveView token signing key (`mix phx.gen.secret`) |
| `PHX_HOST` | The canonical hostname, e.g. `masthead.example.com`. Falls back to `example.com`, so set it. |
| `RESEND_API_KEY` | [Resend](https://resend.com) API key. Account confirmation and password reset email go through Resend. |
| `MAIL_FROM` | Sender address on your Resend-verified domain, e.g. `noreply@masthead.example.com` |

### Optional — server

| Var | Default | Purpose |
|---|---|---|
| `APP_HOSTS` | `PHX_HOST` | Comma-separated hostnames treated as the bare app surface. Subdomains of any of these are routed as sites. The first one is the CNAME target for custom domains. |
| `PHX_SERVER` | — | `true` to start the HTTP server. `bin/server` sets it for you. |
| `PORT` | `4000` | HTTP port |
| `POOL_SIZE` | `10` | Database connection pool size |
| `ECTO_IPV6` | — | `true` to connect to Postgres over IPv6 |
| `DNS_CLUSTER_QUERY` | — | DNS name used to cluster multiple nodes |
| `MAIL_FROM_NAME` | `Masthead` | Display name on outgoing email |
| `FEATURES` | — | Comma-separated optional features. `homepage` shows the marketing homepage at `/`; without it, `/` redirects to the login screen. |

### Optional — object storage (S3-compatible)

If `BUCKET_NAME` is set, the S3 storage adapter takes over. Without it,
uploads are written to `priv/uploads` inside the release — fine on a
machine with a persistent disk, but **lost on every redeploy** in a
container unless that path is a mounted volume.

| Var | Default | Purpose |
|---|---|---|
| `BUCKET_NAME` | — | Bucket to store uploads in |
| `AWS_ACCESS_KEY_ID` | — | Required when `BUCKET_NAME` is set |
| `AWS_SECRET_ACCESS_KEY` | — | Required when `BUCKET_NAME` is set |
| `AWS_ENDPOINT_URL_S3` | `https://fly.storage.tigris.dev` | S3 API endpoint of your provider |
| `AWS_REGION` | `auto` | Bucket region |
| `AWS_PUBLIC_URL_S3` | `https://<bucket>.<endpoint-host>` | Base URL files are served from, e.g. a CDN or custom domain in front of the bucket |

The bucket must allow public reads (bucket policy or per-object ACL) for
image embeds to resolve in browsers.

### Optional — social sign-in

A provider's button only works once its client ID is set. Register the
OAuth app with callback URL `https://<PHX_HOST>/auth/<provider>/callback`
(`google` or `github`).

| Var | Purpose |
|---|---|
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Continue with Google |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | Continue with GitHub |

### Optional — paid plans (Stripe)

Without Stripe the install runs fine, it just can't sell licenses. A
platform admin can still unlock paid features for any site by gifting
license months from the `/admin` console.

| Var | Default | Purpose |
|---|---|---|
| `STRIPE_SECRET_KEY` | — | Stripe secret API key |
| `STRIPE_WEBHOOK_SECRET` | — | Signing secret (`whsec_…`) of a webhook endpoint at `https://<PHX_HOST>/webhooks/payments`, subscribed to `customer.subscription.*` events |
| `LICENSE_PRICE_MONTHLY_CENTS` | `500` | Monthly price, in cents |
| `LICENSE_PRICE_YEARLY_CENTS` | `5000` | Yearly price, in cents |
| `LICENSE_CURRENCY` | `eur` | Currency for checkout and price display |

Prices are created inline at checkout, so no Stripe products need to exist.

### Optional — custom domains (Fly.io only)

Custom domains get their TLS certificates through the Fly.io API, so this
feature only works when deployed on Fly. Site owners point a CNAME at the
first `APP_HOSTS` entry and verify ownership with a `_masthead-verify` TXT
record.

| Var | Purpose |
|---|---|
| `FLY_API_TOKEN` | Fly API token allowed to manage the app's certificates |
| `FLY_APP_NAME` | Name of the Fly app |

### Optional — analytics and support chat

| Var | Purpose |
|---|---|
| `GOOGLE_ANALYTICS_ID` | Google Analytics measurement ID for the app's own pages |
| `CHATWOOT_HMAC_TOKEN` | Chatwoot identity-validation token, used to sign the logged-in user passed to the support chat widget |

## Deploy

The repo ships a [`Dockerfile`](Dockerfile) that builds a release, and
[`fly.toml`](fly.toml) for Fly.io. Any host that runs a container works.

1. Provision Postgres and, ideally, an S3-compatible bucket (see above).
2. Set the required environment variables.
3. Build and run the image. The container starts with `bin/server`.
4. Run migrations on every deploy with `bin/migrate` (on Fly this is the
   `release_command` in `fly.toml`).
5. Point wildcard DNS (`*.your-domain.com`) and the bare domain at the app,
   and serve both over HTTPS with a wildcard certificate.
6. Sign up through the app, then make yourself a platform admin from a
   remote console:

   ```bash
   bin/masthead remote
   ```

   ```elixir
   "you@example.com" |> Masthead.Accounts.get_user_by_email() |> Masthead.Accounts.set_admin(true)
   ```

   On Fly: `fly ssh console -C "/app/bin/masthead remote"`.

Wildcard TLS issuance via Let's Encrypt requires the DNS-01 challenge,
since HTTP-01 doesn't support wildcards. Most modern hosting providers
(or a Caddy / Traefik reverse proxy) handle this automatically.

PDF thumbnails need `pdftoppm` (`poppler-utils`), which the Docker image
already includes. Without it PDFs simply show a file badge.

## Project layout

```
lib/
├── masthead/                        # business logic
│   ├── accounts/                    # users, session + social auth
│   ├── actions/                     # per-site checklist / todos
│   ├── content/                     # posts, pages, HTML sanitizer
│   ├── custom_domains/              # domain verification, Fly certs
│   ├── sites/                       # tenant sites
│   ├── storage/                     # local + S3 adapters
│   ├── themes/                      # theme loading, rendering, packages
│   ├── uploads/                     # file metadata, thumbnails
│   └── workers/                     # Oban background jobs
└── masthead_web/
    ├── plugs/subdomain.ex           # host → site resolution
    ├── public_router.ex             # site-scoped routes
    ├── router.ex                    # admin + marketing routes
    ├── controllers/                 # public, auth, webhook controllers
    └── live/admin/                  # all admin LiveViews
priv/themes/                         # built-in theme
```

## Contributing

Issues and pull requests welcome at
[github.com/dijkstrasoftware/masthead](https://github.com/dijkstrasoftware/masthead).

## License

MIT.

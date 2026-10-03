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
- **Custom subdomains with HTTPS.** Wildcard TLS is provisioned
  automatically; every site is served at `<slug>.<your-domain>`.
- **Markdown and HTML editors.** Live preview, syntax-aware textarea.
- **Built-in blog pages.** Mark any page as a blog and the post list is
  generated for you. Set it as the homepage to make it the front page.
- **Image library.** Upload once, paste ready-made Markdown or HTML embed
  snippets into any post or page.
- **Safe HTML by default.** All rendered content is run through a
  configurable allowlist sanitizer before reaching the browser.
- **Three themes shipped.** Default (compact / typographic), Studio
  (editorial / blue accent), and Blank (zero chrome — bring your own HTML).

## Architecture

- Phoenix LiveView app, single Postgres database, single OTP release.
- Multi-tenancy resolved at the `Host:` header by
  `MastheadWeb.Plugs.Subdomain` — site rows in the `sites` table are looked
  up by subdomain on every request and assigned to
  `conn.assigns.current_site`.
- Two routers: `MastheadWeb.PublicRouter` serves site-scoped public URLs
  (`/`, `/posts/:slug`, `/:slug`); `MastheadWeb.Router` serves the admin
  and marketing surface on the bare app host.
- Object storage is pluggable via `Masthead.Storage.Adapter`. Ships with a
  local-disk adapter for development and an S3-compatible adapter for
  production (works with any S3-compatible provider).

## Run it locally

Requires Elixir 1.18+, Erlang/OTP 28+, Postgres 14+.

```bash
mix deps.get
mix ecto.setup        # creates DB, migrates, seeds an example site
mix phx.server
```

Open:

- `http://localhost:4000` — admin and marketing pages
- `http://admin.lvh.me:4000` — seeded example site

`*.lvh.me` is a public DNS record that resolves to `127.0.0.1`, so
subdomain-based tenancy works in dev without `/etc/hosts` edits.

Default seeded credentials:

```
email:    admin@example.com
password: password1234
```

## Configuration

All prod config is read from environment variables (see
[`config/runtime.exs`](config/runtime.exs)).

### Required

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection string |
| `SECRET_KEY_BASE` | Cookie / LiveView token signing key (`mix phx.gen.secret`) |
| `PHX_SERVER` | `true` to start the HTTP server |
| `PHX_HOST` | The canonical hostname (e.g. `masthead.site`) |
| `APP_HOSTS` | Comma-separated hostnames treated as the bare app surface. Subdomains of any of these are routed as sites. Defaults to `PHX_HOST`. |

### Optional — features

| Var | Purpose |
|---|---|
| `FEATURES` | Comma-separated optional features. `homepage` shows the marketing homepage at `/`; without it, `/` redirects to the login screen. Unset by default. |

### Optional — object storage (S3-compatible)

If `BUCKET_NAME` is set, the S3 storage adapter takes over. Files go to
the configured bucket and public URLs are generated as
`https://<bucket>.<endpoint-host>/<key>`.

| Var | Example |
|---|---|
| `BUCKET_NAME` | `your-bucket-name` |
| `AWS_ENDPOINT_URL_S3` | `https://s3.your-provider.example` |
| `AWS_REGION` | `auto` |
| `AWS_ACCESS_KEY_ID` | _from your storage provider_ |
| `AWS_SECRET_ACCESS_KEY` | _from your storage provider_ |

The bucket must be configured for public read (either via bucket policy
or per-object ACL) for image embeds to resolve in browsers.

## Deploy

Ships as a standard Phoenix release. The general shape:

1. Provision a Postgres database and an S3-compatible bucket (optional —
   omit if you're fine writing uploads to local disk).
2. Set the required environment variables (see above).
3. Build a release with `mix phx.gen.release` + `mix release`, or
   deploy via your platform's Phoenix-aware tooling.
4. Configure wildcard DNS (`*.your-domain.com`) and wildcard TLS for
   subdomain-based site routing.

Wildcard TLS issuance via Let's Encrypt requires the DNS-01 challenge,
since HTTP-01 doesn't support wildcards. Most modern hosting providers
(or a Caddy / Traefik reverse proxy) handle this automatically.

## Project layout

```
lib/
├── masthead/                          # business logic
│   ├── accounts/                    # users + session auth
│   ├── sites/                       # tenant sites
│   ├── content/                     # posts, pages, HTML sanitizer
│   ├── uploads/                     # file metadata
│   ├── storage/                     # local + S3 adapters
│   └── themes/                      # default, studio, blank
└── masthead_web/
    ├── plugs/subdomain.ex           # host → site resolution
    ├── public_router.ex             # site-scoped routes
    ├── router.ex                    # admin + marketing routes
    ├── controllers/                 # public + auth controllers
    └── live/admin/                  # all admin LiveViews
```

## Contributing

Issues and pull requests welcome at
[github.com/JoeriDijkstra/masthead](https://github.com/JoeriDijkstra/masthead).

## License

MIT.

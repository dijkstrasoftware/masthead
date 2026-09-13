# CLAUDE.md

Project-specific guidance for working in this repository. Phoenix/Elixir
and HEEx conventions live in `AGENTS.md` — read that too; this file does
not repeat it.

## What this is

**Masthead** — an open-source, multi-tenant publishing platform for blogs
and small business sites (hosted at masthead.site). Each site runs on
its own subdomain; content is Markdown or HTML; the whole thing deploys
as a single Phoenix/OTP release.

## Architecture map

- **Multi-tenancy** is resolved at the `Host:` header by
  `MastheadWeb.Plugs.Subdomain` — the site row is looked up by subdomain
  and assigned to `conn.assigns.current_site`.
- **Two routers**: `MastheadWeb.PublicRouter` serves site-scoped public
  URLs (`/`, `/posts/:slug`, `/:slug`); `MastheadWeb.Router` serves the
  admin + marketing surface on the bare app host.
- **Themes** are data, not code. A theme is a row in `themes` plus
  files in object storage (or `priv/themes/` for built-ins). The render
  pipeline is `Themes.Renderer` → `Loader` (parses + caches templates in
  `:persistent_term`) → `Sandbox` (Solid/Liquid, no Elixir/DB/FS access)
  → `Presenter` (the *only* path from schemas to templates). Uploaded
  theme zips go through `Themes.Package` (validation + install/update).
- **Renderers are versioned and frozen.** A manifest's `render_version`
  picks the renderer: absent or `"beta"` → `Themes.Renderer.Beta` (page
  settings declared as `metadata`, read as `page.metadata`); `"v1"` →
  `Themes.Renderer.V1` (`page.page_options` + `post.post_options`).
  `Themes.Renderer` itself is only a façade that resolves the theme and
  dispatches. **Never edit a shipped version to change output** — copy it
  to the next version and add the name to `Manifest`'s `@render_versions`,
  so a site keeps rendering the way it did the day it was built.
- **Per-page / per-post theme settings** come from the manifest's
  `page_options` / `post_options` schema, rendered as a form step in
  `AdminLive.PageForm` and `AdminLive.PostForm`, stored in
  `pages.page_options` / `posts.post_options` jsonb, merged with manifest
  defaults at render time.
- **Settings fields are one system.** A manifest `token`, a page option, a
  post option and a page's sidecar config field are the same declaration
  with the same type set (scalars + `object`/`list` containers, one level
  deep) — validated by `Themes.Manifest`, edited by the shared
  `AdminLive.SettingsFields` (the editor component, the wizard's
  `settings_form`, and the draft-value helpers all three wizards use).
  The only difference is the destination: tokens land in
  `sites.theme_tokens`, options in the page/post row, and only *scalar*
  tokens also become CSS custom properties (`--accent`).
- **Object storage** is pluggable via `Masthead.Storage.Adapter`
  (`Local` for dev, `S3` for prod). Call sites are adapter-agnostic.
- **Content sanitization**: all post/page bodies pass through
  `Masthead.Content.HTML.Scrubber` (HtmlSanitizeEx). It allows structural
  tags + `class`/`id` but strips `<script>`, `<style>`, `on*`,
  `javascript:` URLs, and inline `style`. Theme templates are NOT
  sanitized (author-trusted).

## Commands

- `mix precommit` — compile (warnings as errors), `deps.unlock --unused`,
  format, test. **Run this before every commit; it must pass.**
- `mix test` / `mix test path:line` — tests (creates+migrates test DB).
- `mix phx.server` — dev server. Public site at `http://<slug>.lvh.me:4000`,
  admin at `http://localhost:4000`. Seeded login:
  `admin@example.com` / `password1234`.
- `mix ecto.gen.migration name` then edit, then `mix ecto.migrate`.

## Build/runtime gotchas (learned the hard way)

- **Never hand-delete `.beam` files and rely on plain `mix compile`.**
  The incremental compiler keys off source mtime, not beam presence, so
  a deleted module won't regenerate and the server boots with it
  missing (`__live__/0 undefined`). Use `mix compile --force` or don't
  delete beams.
- The dev code reloader recompiles on request, but a long-running server
  across many edits can serve stale LiveView modules. When in doubt,
  restart the server; hard-reload the browser to drop stale sockets.
- `Loader` caches parsed theme templates/CSS in `:persistent_term` per
  VM. Theme content changes need `Loader.invalidate/1` (or a restart).
  Page *content* is read fresh per request — no cache, no restart.
- Theme zip = `manifest.json` + `theme.css` + `templates/`. The
  `pages/` HTML in a theme repo is pasted into Masthead as page content,
  not part of the zip. Re-uploading a theme updates in place only if
  the manifest `version` is a strictly-newer SemVer.

## Versioning — bump before every commit

**Before a branch is ready for a PR, bump `version:` in `mix.exs`**, sized to the
change (SemVer):

- **patch** (`x.y.Z`) — bug fixes, copy tweaks, small CSS/UI
  adjustments, refactors with no behavior change.
- **minor** (`x.Y.0`) — a new user-facing feature, a new option/field,
  a new module or endpoint, a schema addition that's backward
  compatible.
- **major** (`X.0.0`) — a breaking change: removed/renamed public
  behavior, a migration that drops/renames columns other code depends
  on, an incompatible API change.

Pick the highest level any change in the commit reaches (one breaking
change in an otherwise small commit → major). Include the bump in the
same commit as the change it describes, and mention the new version in
the commit body when it's notable.

# Plan: A standalone "Logic" subsystem (agnostic sibling to Themes)

## Context

Masthead today is a **presentation-only** publishing platform. Themes are
standalone, uploadable packages (zip + `manifest.json` + files) that control
*how a site looks* — Liquid templates + CSS + design tokens, rendered in a
sandboxed engine with no DB/FS/code access. The public site is **100% static
HTML**: GET-only routes, no forms, no POST handlers, no dynamic behavior at all.

The user wants a way to add **behavior** to a site — form submissions, dynamic
data, computed values, and custom endpoints — as **standalone, uploadable,
sandboxed packages just like themes**, but **completely agnostic** of each
other: neither built on top of the other. A theme must never name a specific
logic package, and a logic package must never know about themes, slots, or HTML.

Decisions already made (by the user):
- Logic does **all four**: form submissions, dynamic-data fetch, computed
  values/transforms, and custom endpoints.
- Authoring model: **uploadable packages**, versioned + seeded exactly like themes.
- Execution: a **sandboxed scripting engine** running untrusted author code with
  no raw DB/FS/network — implemented with **`luerl`** (pure-Erlang Lua VM), the
  behavioral analog of Solid/Liquid for themes.
- **Themes and Logic must connect agnostically** — via dependency inversion onto
  a neutral platform contract, with the actual wiring living in per-site config.

## The core idea — dependency inversion via a neutral contract

The divide is by **output type**, not feature area:

| | Themes (exists) | Logic (new) |
|---|---|---|
| Question | *How does it look?* | *How does it behave?* |
| Engine | Solid (Liquid) | luerl (Lua) |
| Author writes | `.liquid` + `.css` | `.lua` scripts |
| Produces | **HTML** | **DATA** + **ACTIONS** (typed capabilities) |
| Never does | run side effects | emit HTML / name a theme |
| Per site | exactly **one** theme | **many** logic packages |

**Neither package depends on the other. Both depend on a platform-owned neutral
contract, and the binding between them is per-site configuration owned by the
site owner.**

```
            Masthead.Capabilities          ← neutral contract (platform-owned)
             ▲                  ▲              capability "kinds" + slot vocabulary
             │ depends on       │ depends on
      Masthead.Themes      Masthead.Logic
   declares SLOTS          declares CAPABILITIES
   renders kinds           (form / feed / facts / links…)
   never names a logic     never names a theme or emits HTML
```

Three pieces make the connection agnostic:

1. **Slots are neutral placement points, on two surfaces (see next section).**
   A *theme slot* is declared in the theme manifest and placed in a `.liquid`
   template; a *page slot* is dropped inline by a page author in the page body.
   Both render a neutral marker that never names a logic:
   ```liquid
   {% slot "sidebar" %}        {# theme template: theme has no idea what fills this #}
   ```
   ```
   [[slot: contact_form]]      ← page body: author drops this anywhere in prose
   ```

2. **Logic declares *capabilities* of shared kinds, not HTML.** Logic produces
   data + actions typed against a **shared vocabulary of kinds** the platform
   defines (e.g. `form`, `feed` = `[{title,url,date}]`, `facts` = key/values,
   `links`). Logic never knows a theme or slot exists, and ships no HTML.

3. **The site owner *binds* capability → slot** in the admin UI. That binding is
   data on the `site_logics` join (`slot_bindings` map), owned by the owner —
   not baked into either package. Swap the contact-form logic for another form
   logic and `{% slot "footer_form" %}` is unchanged; swap themes and the binding
   survives as long as the new theme exposes a compatible slot.

The platform renderer is the **mediator** — allowed to know both sides and marry
them at render time. So the *packages* and the code modules `Themes`/`Logic` stay
mutually agnostic; only the neutral `Capabilities` layer and the runtime mediator
touch both. (Analogy: RSS — a publisher and a reader never know each other, they
share a *schema*. Here the schema is the capability-kind vocabulary.)

**Two-way graceful degradation proves the decoupling:** an unbound slot renders
nothing; a logic whose data isn't bound to any slot still has working action
endpoints. Each side is fully functional without the other.

### The one real tradeoff — how typed the kind vocabulary is

A small fixed kind set (`form` / `feed` / `facts` / `links`) renders beautifully
but constrains what logic can express; fully generic key/value rendering is
infinitely flexible but ugly. **Recommendation:** ship a small fixed kind set
plus an owner-controlled **field-mapping escape hatch** in the binding UI for
rich/custom data (the owner maps a logic's data fields onto a theme slot's
expected fields). This keeps both sides agnostic while allowing richness.

## Two slot surfaces — theme slots vs page slots

A capability can be placed in two different surfaces. **Same `Capabilities`
contract, same per-kind renderers — only the placement and binding scope differ.**

| | **Theme slot** | **Page slot** |
|---|---|---|
| Placed by | Theme author, in `.liquid` | Page author, inside the page body |
| Scope | Structural, site-wide (sidebar, footer) | Inline, this-page-only, mid-prose |
| Declared | Theme manifest `slots` (with `accepts` kinds) | Ad hoc — author invents the key inline |
| Marker | `{% slot "key" %}` (custom Solid tag) | `[[slot: key]]` text shortcode in body |
| Bound in | `site_logics.slot_bindings` (per-site) | `pages.slot_bindings` (per-page) |

**Why page slots need a different marker.** A page's `body` goes
`Content.render_body` → **scrubber** → `body_html`, injected into the theme as
`{{ body_html }}`. It is **not** run through Liquid, so `{% slot %}` won't work
inside page content. A **text shortcode `[[slot: key]]`** survives scrubbing (it's
plain text), works in both Markdown and HTML pages, and needs no pre-declaration —
the author invents the key inline.

**Resolution pipeline (page slots):** a new mediator pass runs in the public
controller, after scrubbing and **before** the body enters the theme template:
```
page.body → render_body → body_html (scrubbed)
   → SlotResolver.resolve_page_slots(site, page, body_html)            ← NEW
       scan for [[slot: KEY]] → look up pages.slot_bindings[KEY]
       → render the bound capability via the same per-kind partial
       → substitute into the string (unbound/unknown KEY → "")
   → inject as {{ body_html }} into the theme template
```
By the time the theme wraps the body, the capability HTML is already inlined. A
`form` capability embedded in a page carries the same `action_url` + `csrf_token`
descriptor as a theme-slot form — identical behavior. The page *content* stays
neutral; the binding is owner-configured data, exactly like theme slots. Logic
never knows whether it landed in a theme region or a page body.

## The neutral contract — `Masthead.Capabilities`

A platform-owned module both subsystems depend on. It defines:

- **Capability kinds** — a small enum with fixed shapes:
  - `form` → `%{action_url, csrf_token, method, fields: [%{key,type,label,required}]}`
  - `feed` → `[%{title, url, date, summary}]`
  - `facts` → `%{<label> => <value>}`
  - `links` → `[%{label, url}]`
  - `html_fragment` is **intentionally excluded** — logic never emits markup.
- **Descriptor structs** for each kind (what the mediator hands a theme slot).
- **Slot descriptor** — `%{key, label, accepts: [kinds]}` (parsed from a theme
  manifest's `slots`).
- **Validation** that a logic capability's declared kind is one the platform
  knows, and that a binding connects a capability whose kind ∈ slot's `accepts`.

`Masthead.Themes` and `Masthead.Logic` both `alias Masthead.Capabilities`;
**neither aliases the other.** This is the architectural invariant to enforce
(a simple boundary test can assert no `Logic.*` reference appears in `Themes.*`
source and vice versa).

## Manifest schemas

### Theme manifest — add a `slots` array (otherwise unchanged)

```json
"slots": [
  { "key": "footer_form", "label": "Footer form", "accepts": ["form"] },
  { "key": "sidebar",     "label": "Sidebar",     "accepts": ["feed","links","facts"] }
]
```
Existing themes with no `slots` keep working exactly as today. Templates opt in
with `{% slot "key" %}`.

### Logic manifest (`priv/logic/<slug>/manifest.json`)

Mirrors `Themes.Manifest` identity + typed-field system, replacing
`tokens`/`page_options` with `config` (per-site settings, reusing the token type
system verbatim), `providers`, and `actions`. Each provider/action declares the
capability **kind** it emits — the only thing that crosses the boundary:

```json
{
  "name": "Contact Form", "slug": "contact", "version": "1.0.0",
  "author": "Masthead", "description": "...",
  "config": [
    { "key": "recipient", "label": "Send to", "type": "string", "default": "" }
  ],
  "providers": [
    { "key": "forecast", "kind": "feed", "script": "providers/forecast.lua",
      "cache_ttl": 300, "inputs": ["site","page","config"] }
  ],
  "actions": [
    { "key": "submit", "kind": "form", "method": "POST",
      "script": "actions/submit.lua",
      "rate_limit": { "max": 5, "per_seconds": 3600, "scope": "ip" },
      "fields": [ {"key":"email","type":"email","required":true},
                  {"key":"message","type":"text","required":true,"max":5000} ],
      "on_success": { "redirect": "thanks" } }
  ]
}
```

- `config` reuses `Themes.Manifest` `@valid_token_types` so the per-site config
  UI reuses the exact token-field form components.
- `kind` must be a `Capabilities` kind; for `form`, the `fields` list **is** the
  form descriptor's field schema (no HTML required from logic).
- `script` paths validated `^[a-z0-9_/-]+\.lua$`, no `..`, at parse and extraction.

## Database schema (3 migrations, mirroring `create_themes`)

- **`logics`** — near-identical to `themes`: `slug, name, description, version,
  source ("built_in"|"uploaded"), owner_id (nilify_all), storage_path, manifest
  (map), public`. Same two partial unique indexes; reserved built-in slugs.
- **`site_logics`** (join — required because logic is many-per-site, each
  independently enabled/configured/**bound**, and we must *query* "which sites
  use logic X" for the same in-use-on-delete guard `delete_theme` uses):
  ```
  site_id  references(:sites, on_delete: :delete_all), null: false
  logic_id references(:logics, on_delete: :restrict),  null: false
  config        :map default %{}      # per-site config overrides
  slot_bindings :map default %{}      # %{ "<theme_slot_key>" => "<provider_or_action_key>" }
  field_map     :map default %{}      # optional escape-hatch field remapping
  enabled :boolean default true, position :integer
  unique_index [site_id, logic_id]; index [site_id]
  ```
  `slot_bindings` is the agnostic glue, owned by the owner. `on_delete: :restrict`
  reuses themes' "can't delete in-use" pattern exactly.
- **`logic_submissions`** — generic form store (payload `data :map`; typed
  columns for query/moderation):
  ```
  site_id (delete_all), logic_id (nilify_all), action_key, data :map,
  status "received"|"spam"|"handled", remote_ip, user_agent, timestamps
  index [site_id, logic_id, action_key]; index [site_id, inserted_at]
  ```
- **`pages.slot_bindings`** (new jsonb column on the existing `pages` table) —
  per-page binding for inline `[[slot: key]]` markers; maps a body key to a
  capability of a site-enabled logic:
  ```
  %{ "contact_form" => %{ "logic_slug" => "contact", "capability" => "submit" } }
  ```
  Mirrors `pages.page_options` storage/normalization. Only logics the *site* has
  enabled (via `site_logics`) are bindable.

## New modules

**Neutral layer first:** `Masthead.Capabilities` (kinds, descriptor structs,
slot descriptor, binding validation) — see above. Both `Themes` and `Logic`
depend on it; neither depends on the other.

**Shared zip-safety:** extract helpers from `Themes.Package` into
`Masthead.Packaging` (`check_size`, `safe_list`, `check_entry_caps`,
`extract_to_tmp`, `random_id`); have `Themes.Package` call it. Low-risk refactor
with existing `package_test.exs` coverage.

**Theme-side changes (small, additive):**
- `Themes.Manifest` — parse the new `slots` array into `Capabilities` slot descriptors.
- A neutral `{% slot "key" %}` Liquid tag (a custom Solid tag, registered in the
  theme `Sandbox`). At render it asks the **mediator** (not Logic directly) for
  the descriptor bound to that slot and renders it via a per-kind partial. The
  tag depends on `Capabilities`, **not** on `Masthead.Logic`.
- Per-kind neutral renderers (`form`, `feed`, `facts`, `links`) — generic Liquid
  partials the theme can override but that ship with sane defaults.

**Logic-side (mirror themes one-for-one):**
- `Masthead.Logic` (context): list/get/create/update/`delete_logic` (with
  `{:error, {:in_use, names}}`), `package_logic`; join ops
  `enabled_logics_for_site/1`, `enable_logic/3`, `update_site_logic_config/3`,
  `bind_slot/4`.
- `Masthead.Logic.Logic` + `Masthead.Logic.SiteLogic` schemas (mirror `Theme`).
- `Masthead.Logic.Manifest` — parse/validate; each provider/action's `kind`
  validated against `Capabilities`.
- `Masthead.Logic.Package` — same 8-step install pipeline; compiles every
  referenced `.lua` via `Logic.Sandbox.compile/1` before promoting; asset
  allowlist `~w(.lua .json)` only; **rejects `.liquid`/`.css`/`.html`**.
- `Masthead.Logic.Loader` — mirrors `Themes.Loader`; caches **compiled Lua
  chunks** in `:persistent_term` keyed `{Loader, logic_id}`; `invalidate/1`.
- `Masthead.Logic.Sandbox` — luerl wrapper (security core, below).
- `Masthead.Logic.Presenter` — reuse `Themes.Presenter` for site/post/page; add
  only `to_lua/1`/`from_lua/1` shaping + validated-params projection.
- `Masthead.Logic.Runner` — `provide/2` (run enabled providers → capability
  descriptors, cached + degrading) and `run_action/4` (validate, execute, return
  outcome). **Returns `Capabilities` descriptors**, not Liquid-specific maps.
- `Masthead.Logic.Seed`, `Masthead.Logic.RateLimiter` (ETS token bucket),
  `Masthead.Logic.Http` (SSRF-guarded).

**Mediator:** `Masthead.SlotResolver` (or a function in `Themes.Renderer`) — the
*one* place allowed to touch both. Two entry points, same internals:
- `for_slot(site, slot_key)` — for theme `{% slot %}` tags: reads
  `site_logics.slot_bindings`, calls `Logic.Runner` for the bound capability,
  renders via the per-kind partial.
- `resolve_page_slots(site, page, body_html)` — scans `body_html` for
  `[[slot: key]]` markers, reads `pages.slot_bindings`, renders each bound
  capability via the same per-kind partial, substitutes into the string.

Page-side change: `Content` / `PublicController` calls `resolve_page_slots/3` on
`body_html` before passing it to `Renderer`. The scrubber must preserve the
`[[slot: …]]` text token (it already preserves plain text — verify no markdown
pass mangles it; if needed, resolve *before* scrubbing on a placeholder map).

Critical files to read/mirror/modify:
- `lib/masthead/themes/package.ex` (extract `Packaging`; mirror as `Logic.Package`)
- `lib/masthead/themes/renderer.ex` (mediator hook + slot resolution)
- `lib/masthead/themes/sandbox.ex` / `filters.ex` (register the `{% slot %}` tag)
- `lib/masthead/themes/{loader,manifest,seed,presenter}.ex` (mirror / extend `slots`)
- `lib/masthead_web/public_router.ex`, `controllers/public_controller.ex` (action route)
- new: `lib/masthead/capabilities.ex`, `lib/masthead/packaging.ex`, `lib/masthead/logic/*`
- modify: `mix.exs` (`{:luerl, "~> 1.2"}`), `lib/masthead/application.ex`
  (seed + RateLimiter child), `lib/masthead_web/router.ex` (download + `live "/logic"`)

## Lifecycle wiring

**Slots + providers → render (capabilities 2 & 3, agnostic path).** The theme
renders `{% slot "sidebar" %}`. The tag calls the mediator
(`SlotResolver.for_slot(site, "sidebar")`), which looks up the binding, asks
`Logic.Runner.provide/2` for the bound provider's descriptor (ETS result cache
keyed by `{site, logic, provider, inputs_hash}` honoring `cache_ttl`), and renders
it through the per-kind partial. **Graceful degradation:** unbound slot or
provider error → render nothing; the page always renders. No `logic.<slug>`
namespace appears anywhere in theme source.
**Latency mitigation:** compiled-chunk cache + TTL result cache + per-provider
time/heap limits; render-time `http_get` defaults **off** — providers read values
populated by a background `Masthead.Workers.LogicFetch` Oban job.

**Actions → routing (capabilities 1 & 4).** A `form`-kind capability's descriptor
carries `action_url` + `csrf_token`, both produced by the platform — the theme's
generic `form` partial just renders them, never naming a logic. Add a POST
pipeline + controller before the `/:slug` catch-all:
```elixir
scope "/_logic", MastheadWeb do
  pipe_through :logic_action     # accepts html/json, fetch_session, parsers; NO session-CSRF
  post "/:logic_slug/:action_key", LogicController, :handle
end
```
`LogicController.handle/2`: resolve enabled `site_logic` (404) → verify signed
token (403) → rate-limit (429) → `Runner.run_action/4` → `{:redirect, slug}` /
`{:json, map}` / validation error (422 or re-render).

**CSRF on author-trusted-but-public forms.** Public pipeline has no session, so
use a **scoped signed token** baked into the form descriptor:
`Phoenix.Token.sign(Endpoint, "logic_action", {site_id, logic_slug, action_key})`,
verified with `max_age` (~2h). Plus rate limiter + optional manifest honeypot.

## luerl sandbox security model

- Add `{:luerl, "~> 1.2"}`. Start from `:luerl.init/0` and **remove** `os`, `io`,
  `package`, `require`, `load`/`loadfile`/`dofile`/`loadstring`, `debug`,
  `collectgarbage`, raw `print`. Author sees only
  `string/table/math/tonumber/tostring/pairs/ipairs` + our host tables.
- **Limits:** wall-clock via `Task.yield`/`shutdown` (~250ms providers, ~1000ms
  actions); `process_flag(:max_heap_size, …)`; output-size cap (~256KB).
- **Provider host API (read-only):** `host.site()/page()/post()` (via
  `Themes.Presenter`), `host.config()`, `host.json_decode/encode`, and
  `host.http_get` only when `cache_ttl>0` + feature-flagged (through `Logic.Http`).
  The chunk's return value is shaped into the declared capability kind.
- **Action host API (effectful, thin wrappers — Lua requests, Elixir performs):**
  `host.params()` (validated/whitelisted against `fields`), `host.config()`,
  `host.save_submission(table)` (inserts `logic_submissions`),
  `host.send_email(to,subj,body)` (**enqueues `Masthead.Workers.Email`**, `to`
  constrained server-side to owner/declared recipient — no open relay),
  `host.redirect(slug)`, `host.json(table)`.
- **SSRF guard (`Logic.Http`):** require http/https; reject private/loopback/
  link-local/metadata ranges; re-check after redirects; hard timeout + max bytes.

## Admin UI

- `MastheadWeb.AdminLive.LogicLibrary` (`live "/logic"`): upload modal
  (`allow_upload :logic_zip`, 5MB, `.zip`), list/delete (reuse `{:in_use, names}`
  flash), download route mirroring `download_theme`.
- Per-site Logic surface (extend `AdminLive.SiteSettings`): enable/disable +
  reorder; config form **generated from `manifest.config`** reusing theme-token
  field components; **theme-slot binding UI** — for each theme slot, a dropdown of
  enabled logics' capabilities whose `kind` ∈ the slot's `accepts` (plus the
  optional field-map escape hatch). Read-only **Submissions** viewer per logic.
- **Page-slot UI in `AdminLive.PageForm`:** an "Insert logic" action that drops a
  `[[slot: key]]` token into the body editor and binds that key in
  `pages.slot_bindings` via a dropdown of the site's enabled-logic capabilities.
  This is where a page author places a capability inline in their content.

## Phased rollout

- **Phase 1 — Foundation.** `:luerl` dep; 3 migrations; `Masthead.Capabilities`
  (kinds + slot descriptor); extract `Masthead.Packaging`; logic schemas +
  context + `Manifest` + `Sandbox.compile` + `Loader` + `Package` + `Seed` +
  `LogicLibrary` + download route + wire seed. *Demo:* upload/list/download/delete
  a logic zip; built-ins seed on boot.
- **Phase 2 — Slots + providers (the agnostic render path; lowest risk).** Theme
  `slots` parsing, `{% slot %}` tag, `[[slot: key]]` page-body resolution +
  `pages.slot_bindings`, per-kind partials, `SlotResolver` mediator (both
  `for_slot/2` and `resolve_page_slots/3`), `Runner.provide/2` + cache, read-only
  host API, binding storage + minimal bind UI (site + page). *Demo:* a `feed`
  logic bound to a theme slot *and* a capability dropped inline via `[[slot: …]]`
  on a page both render, with neither package naming the other; unbind → empties,
  page still renders.
- **Phase 3 — Actions / forms (highest surface).** submissions write path,
  `Runner.run_action/4`, effectful host API, `RateLimiter`, `Logic.Http` + SSRF,
  email enqueue (+ `:logic` Oban queue / `LogicFetch`), `LogicController` +
  `/_logic` route + scoped-token CSRF, `form`-kind descriptor with `action_url`
  + `csrf_token`. *Demo:* contact-form end-to-end via slot binding — submit →
  row stored → email enqueued → redirect; 429 and 403 observable.
- **Phase 4 — Binding UI + polish.** Full slot-binding UI (kind-filtered
  dropdowns + field-map escape hatch), submissions viewer, reorder/enable UX,
  boundary test asserting `Themes`↔`Logic` have no direct dependency, contract docs.

## End-to-end example (contact form, fully agnostic)

- **Theme manifest** declares a slot: `{ "key":"footer_form", "accepts":["form"] }`,
  and `page.liquid` contains just `{% slot "footer_form" %}`. The theme names no logic.
- **`priv/logic/contact/manifest.json`** — config `recipient`; one `submit` action
  with `"kind":"form"`, fields `email`/`message`, rate-limit, `on_success.redirect`.
  The logic names no theme/slot.
- **`priv/logic/contact/actions/submit.lua`:**
  ```lua
  local p, cfg = host.params(), host.config()
  host.save_submission({ email = p.email, message = p.message })
  host.send_email(cfg.recipient, "New message from " .. p.email,
                  "From: " .. p.email .. "\n\n" .. p.message)
  return host.redirect("thanks")
  ```
- **Theme-slot path:** the owner binds `footer_form` → `contact.submit` in admin.
  At render, the mediator builds the `form` descriptor (fields + `action_url` +
  `csrf_token`) and the theme's generic `form` partial renders it.
- **Page-slot path (alternative placement):** instead of (or as well as) the
  footer, the author opens the Contact page, types `[[slot: contact_form]]` mid-
  prose, and binds that key → `contact.submit` in the page editor. The form renders
  inline at exactly that spot. Same descriptor, same partial, same endpoint.
- Swap themes or swap the form logic without touching either package — only the
  binding changes.

## Verification

**Tests (mirror existing patterns):**
- `logic/package_test.exs`, `logic/manifest_test.exs`, `logic/delete_logic_test.exs`
  (mirror `package_test.exs` / `delete_theme_test.exs`): install/reject paths,
  kind validation, semver-gated update, `{:in_use, names}`, soft-delete detach.
- `logic/sandbox_test.exs`: `os/io/require/load` unavailable; infinite loop hits
  timeout; oversized return rejected.
- `logic/runner_test.exs`: provider cache/TTL; error → empty slot (degradation);
  unknown params dropped; `save_submission` writes; `send_email` enqueues (Oban.Testing).
- `logic/http_test.exs`: SSRF guard rejects private/loopback/metadata + non-http.
- `capabilities_test.exs`: binding rejected when capability kind ∉ slot `accepts`.
- `logic_controller_test.exs`: valid token+within-limit → 302 + row + job;
  bad/missing token → 403; over limit → 429.
- **Boundary test:** assert no `Masthead.Logic.*` reference in `Masthead.Themes.*`
  source and vice versa (the agnosticism invariant).
- A renderer/slot test: bound theme slot renders the descriptor; unbound slot
  renders nothing; unbound logic's action endpoint still works.
- A page-slot test: `[[slot: key]]` in a page body resolves to the bound
  capability HTML; survives the scrubber; unknown/unbound key → "".

**Manual (`mix phx.server`):** seed runs → contact logic at `/logic` → enable on
`foo.lvh.me`, set `recipient`, bind `footer_form` → `contact.submit` → public page
renders form with token → submit → 302 `/thanks` + `logic_submissions` row + email
in `/dev/mailbox` → 6 quick submits → 429 → tampered token → 403 → unbind → slot
empties, page still renders.

Run `mix precommit` before each commit (compile warnings-as-errors, format, test)
and bump `mix.exs` version once before the PR per the project's versioning policy.

## Key risks

- **Hidden coupling creep** — guard the `Themes`↔`Logic` independence with the
  boundary test; keep all cross-talk in `Capabilities` + the mediator.
- **Render-time latency** — compiled-chunk + TTL caches, per-provider time/heap
  limits, background-fetch default for HTTP.
- **SSRF** — `Logic.Http` scheme + private-IP blocklist + redirect re-check + caps.
- **CSRF** — `Phoenix.Token` scoped to `{site, logic, action}` with `max_age`.
- **Sandbox escape** — strip dangerous luerl tables; wall-clock + max_heap +
  output-size limits.
- **Spam** — ETS rate limiter + signed token + optional honeypot; `send_email`
  recipient constrained server-side.
- **Versioning/seeding** — reuse themes' semver-gated, non-destructive upsert;
  reserved built-in slugs.

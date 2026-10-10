# 2026-10-10 — Spec: Growth dashboard (admin)

Status: Phase 1 built (2.31.0); Phases 2 and 3 not started. Source: founder brief
"Masthead Growth Dashboard" plus the answers to the open questions (see *Decisions*).

## Goal

An admin-only page that shows how people move from signup to real use of the product:
signups, sites created, first publish, return visits, paying customers, acquisition
channels and theme choice.

**Primary metric:** the share of eligible users who have published at least one page
or post (the *activation rate*).

The database is the source of truth. Every number on the dashboard comes from Postgres
rows written by the app. Nothing comes from Google Analytics or from browser-side
events.

Non-goals: a general analytics product, per-customer traffic analytics (that's the
existing site stats), session replay, multi-touch attribution, real-time streaming.

## Context — what exists today

| Need | Today | Gap |
|---|---|---|
| Signup time | `users.inserted_at` | — |
| Signup method / invited | not stored; `site_invitations` rows are deleted on accept | need `users.signup_method` |
| Site creator | `site_memberships` only. `sites.owner_id` was dropped; no roles | need `sites.created_by_id` |
| Sites created | `sites.inserted_at`; soft delete via `deleted_at` | — |
| First publish, posts | `posts.published_at` is set the first time a post is published and never cleared; posts are hard-deleted | history is lost when posts are deleted |
| First publish, pages | `pages.published` bool only; pages are hard-deleted | need `pages.published_at` |
| Activation | — | need `users.activated_at` / `activated_via` |
| Meaningful activity | `updated_at` (overwritten on every save), `last_login_at` (login only) | need `user_activity_days` |
| Attribution | nothing (no UTM, referrer or landing page anywhere) | need cookie capture + `users` columns |
| Wizard theme choice | only in socket assigns (`SiteIndex`); later switches overwrite `sites.theme_id` | need `sites.initial_theme_id` / `theme_choice` |
| Subscriptions | current state on `sites.license_*`, overwritten by Stripe webhooks; `gift` plan not reliable | need `license_events` |
| Imports | completed `import_site` action; `PreviewImport` backdates post `published_at` to source dates | must not count as dated activity |
| Charts | CSS bar chart in `AdminLive.SiteStats` (`site_stats.ex` 227-264) | reuse it |
| Timezone | UTC everywhere | keep UTC |

A site has no publish flag. It is live from creation, and no page or post is created
automatically, so site creation can never count as activation.

## Definitions

All dates are **UTC calendar days**. "In range" means `>= start of first day` and
`< start of the day after the last day`.

- **Eligible user:** `admin = false` and `signup_method <> 'invite'`. Disabled and
  suspended users stay in (they are part of their cohort's history). Every user metric
  and the funnel use only eligible users. Site counts include every site.
- **Signed up:** `users.inserted_at`.
- **Created a site:** the user is `created_by_id` of at least one site. Soft-deleted
  sites count, because creation is historical. *First site* = earliest of those.
- **Activated:** `users.activated_at IS NOT NULL`. This is set once, on the user's first
  publish of a page or post, and never cleared. Unpublishing or deleting content does
  not change it. `activated_via` is `written` or `import`.
- **Active day:** a row in `user_activity_days` (one per user per UTC day with at least
  one meaningful action). These count as meaningful actions:
  - creating, editing, publishing or unpublishing a page or post
  - creating a site
  - saving site settings
  - saving theme settings or switching theme
  - running an import

  Page loads and logins are **not** meaningful actions.
- **Returned:** at least one active day *after* the signup day.
- **Retention Dn (rolling):** among eligible users who signed up at least *n* days ago,
  the share with an active day `>= signup_date + n`. Shown for n = 1, 7 and 30.
- **Paying customer:** an eligible user who is `created_by_id` of a site that is
  currently `Licenses.paid?/1` **and** whose latest license event has
  `source = 'stripe'`. Gifts and grants are not paying.
- **Paid site:** a site that is currently paid with a Stripe-sourced license.
- **MRR:** the sum over paid sites of the monthly equivalent of the `amount_cents` on the
  site's latest `started`, `renewed` or `plan_changed` event: monthly as-is, yearly ÷ 12.
  Shown in `LICENSE_CURRENCY`.
- **Channel** (derived from the attribution columns, in this order):
  1. `utm_source` (lowercased), e.g. `google`, `newsletter`
  2. `google-ads` when a `gclid` was present and there is no `utm_source`
  3. `organic-search` when `referrer_domain` is a known search engine (google, bing,
     duckduckgo, ecosia, yahoo, …)
  4. `referral:<domain>` for any other external referrer
  5. `direct` when attribution was captured but has no source or referrer
  6. `Unknown` when nothing was captured (every account from before tracking started)

## Data model changes

One migration (plus a separate data-migration backfill, see *Backfill*).

```
users
  signup_method           string  not null default 'email'   -- email|google|github|invite
  signup_method_inferred  boolean not null default false
  activated_at            utc_datetime null
  activated_via           string  null                       -- written|import
  utm_source              string  null
  utm_medium              string  null
  utm_campaign            string  null
  gclid_present           boolean not null default false     -- the gclid value is never stored
  landing_path            string  null                       -- path only, no query
  referrer_domain         string  null                       -- host only
  first_seen_at           utc_datetime null                  -- null = not captured → "Unknown"
  index (inserted_at)

sites
  created_by_id           references users on_delete: nilify_all, null
  initial_theme_id        references themes on_delete: nilify_all, null
  theme_choice            string  null                       -- chosen|skipped|default|unknown
  index (created_by_id)

pages
  published_at            utc_datetime null                  -- same rule as posts

user_activity_days
  user_id   references users on_delete: delete_all
  date      date
  primary key (user_id, date)

license_events
  id, site_id references sites on_delete: delete_all
  kind          string  -- started|renewed|plan_changed|canceling|canceled|past_due|reactivated|gifted|granted|backfill
  source        string  -- stripe|gift|grant|backfill
  plan          string  null
  status        string  null
  amount_cents  integer null   -- price of the plan at the time of the event
  currency      string  null
  expires_at    utc_datetime null
  occurred_at   utc_datetime
  index (site_id, occurred_at)
```

No generic events table. The brief's events map onto rows as follows:

| Brief event | Record |
|---|---|
| `user_signed_up` | `users.inserted_at` |
| `site_created` | `sites.inserted_at` + `created_by_id` |
| `content_created` | `posts/pages.inserted_at` (live rows) + an activity day |
| `content_published` | `posts/pages.published_at`, `users.activated_at` |
| `content_unpublished` / `deleted` | activity day; activation is unaffected by design |
| `user_returned` | `user_activity_days` |
| `subscription_started` / `cancelled` | `license_events` |

## Capture (write paths)

### `Masthead.Growth` (new context, `lib/masthead/growth.ex`)

Write helpers, each a single statement and safe to call repeatedly:

- `touch(user_id)` inserts `(user_id, Date.utc_today())` into `user_activity_days` with
  `on_conflict: :nothing`.
- `mark_activated(user_id, via)` runs
  `UPDATE users SET activated_at = now(), activated_via = ^via WHERE id = ^user_id AND activated_at IS NULL`.
  Repeated publishes are no-ops, so a user is counted once.

Both run **after** the domain write has succeeded, as plain single-statement `Repo`
calls outside the domain transaction, so they can't roll back the user's save.

### Call sites

Contexts don't know who the actor is, so the calls go in the web layer, where
`current_user` is available:

| Where | Calls |
|---|---|
| `AdminLive.PostForm` save (create/update, ~293-298) and publish toggle (~332) | `touch`; `mark_activated(:written)` when the saved post is published |
| `AdminLive.PageForm` save (~407-410), publish toggle (~457), bulk create (~313) | same |
| `AdminLive.SiteIndex` wizard save (site created) | `touch` |
| `AdminLive.SiteSettings` save (~82) | `touch` |
| `AdminLive.SiteTheme` save (~70) | `touch` |
| Import completion (`Content.HugoImport`, `Content.PreviewImport` callers) | `touch`; `mark_activated(:import)` if at least one published item was created |

Activation always uses `now()`, never a content timestamp, because imports backdate
`posts.published_at`.

Risk: any future write path that skips these calls under-counts activity. The
implementation should add one test per call site that asserts the row was written.

### Content

`Page.changeset/2` gets the same `set_published_at` rule as `Post`: fill `published_at`
when `published` becomes true and it is nil, never clear it, never cast it.

### Signup

- `Accounts.register_user/1` → `signup_method: "email"`.
- `Accounts.get_or_create_user_from_oauth/2` (create branch) → `"google"` / `"github"`.
- `Accounts.register_invited_user/1` → `"invite"`.
- All three take the attribution map from the cookie (below). The controllers read the
  cookie and pass it on. The attribution columns are set in the same insert and are
  **not** in the user-facing `cast` list; they go through a separate internal changeset.

### Site creation

- `Sites.do_create_site/2` sets `created_by_id` to the creating user's id.
- `SiteIndex` save passes `theme_choice`:
  - `chosen` when the user picked a template; `initial_theme_id` = the applied theme
  - `skipped` when the user pressed skip
  - `default` for every other path (seeds, tests, any non-wizard creation)

  `initial_theme_id` is always the theme the site was created with. Neither field is
  updated afterwards.

### License events

`Licenses` writes one `license_events` row whenever a site's license state actually
changes. It compares the state before and after in `write/2` (Stripe webhooks),
`gift/2` and `grant/3`. The kind is derived from the transition:

| Transition | kind |
|---|---|
| not paid → paid (stripe) | `started` |
| paid → paid, `expires_at` moved forward, same plan | `renewed` |
| plan changed while paid | `plan_changed` |
| status → `canceling` | `canceling` |
| status → `canceled`, or expired | `canceled` |
| status → `past_due` | `past_due` |
| `canceling`/`past_due` → `active` | `reactivated` |
| `gift/2` | `gifted` (source `gift`, amount 0) |
| `grant/3` | `granted` (source `grant`, amount 0) |

No change → no row, so webhook redeliveries don't create duplicates. `amount_cents`
comes from `Licenses.amount/1` at the time of the event.

### Attribution cookie

`MastheadWeb.Attribution`, a plug added to the `:analytics` pipeline (marketing, auth
and marketplace routes):

- Runs only when there is no logged-in user and no `_mh_attr` cookie (**first touch**,
  never overwritten).
- Stores a signed cookie `_mh_attr` (30 days, `SameSite=Lax`, `http_only`) containing:
  - `utm_source`, `utm_medium`, `utm_campaign`, each truncated to 100 characters
  - `gclid_present` (boolean)
  - `landing_path` (path only)
  - `referrer_domain`: the host of the `Referer` header, only when it isn't Masthead's
    own host
  - `first_seen_at`
- No IP address, full URL, user agent or `gclid` value is stored.
- On signup the controllers copy it onto the user and delete the cookie.

Consent: this is a first-party, functional-purpose cookie with no third-party sharing.
Whether it needs consent is the founder's/privacy policy's call. The spec doesn't add
a banner.

## Backfill (one-off data migration)

Every backfilled value is approximate. The dashboard shows "Tracking since
<deploy date>; earlier values are reconstructed" under each affected section.
`Masthead.Growth.tracking_since/0` reads that moment from the DB: the
`schema_migrations.inserted_at` of the growth tracking migration.

1. **`sites.created_by_id`**: the user on the site's earliest `site_memberships` row.
2. **`users.signup_method`** (`signup_method_inferred = true` for every existing user):
   - `google`/`github` when a `user_identities` row was created within 60 s of
     `users.inserted_at`
   - otherwise `invite` when the user's earliest membership was created within
     10 min of signup, is on a site created before the user, and the user created no
     site themselves
   - otherwise `email`
3. **`pages.published_at`** = `inserted_at` for currently published pages.
4. **`users.activated_at`**:
   - the earliest `GREATEST(published_at, inserted_at)` over published posts authored by
     the user, plus published pages and author-less posts on sites the user created
   - `activated_via = 'import'` when that first item's site has a completed
     `import_site` action whose `updated_at` is within 10 min of the item's
     `inserted_at`; otherwise `written`
   - content that was published and then deleted can't be recovered, so those users
     stay unactivated
5. **`sites.initial_theme_id` / `theme_choice`**:
   - `chosen`, with that theme, when a `theme_installs` row exists within 60 s of
     `sites.inserted_at`
   - `default` when the current theme is the built-in `default`
   - `unknown` otherwise, with `initial_theme_id` = current `theme_id`
6. **`license_events`**: one `backfill` row per currently paid site:
   - `source = 'stripe'` when `payment_subscription_id` is present, else `gift`
   - `occurred_at` = the site's `updated_at`
7. **`user_activity_days`**: no backfill, because the history doesn't exist. Retention
   cohorts that signed up before `tracking_since` show "—".
8. **Attribution:** no backfill, so all existing users get channel `Unknown`.

## Dashboard

### Routing and access

- `live "/admin/growth"` and `live "/admin/growth/:tab"` → `AdminLive.Growth`, declared
  in the existing `live_session :admin` (`require_admin` + `require_verified`)
  **before** `live "/admin/:tab"` and `"/admin/:tab/:filter"`; otherwise the console
  would swallow them.
- Reached through the "Growth" item in the admin sidebar only; the console tab bar
  doesn't link it.
- Non-admins get the same redirect as `/admin`.

### Layout

`MastheadWeb.AdminLive.Growth`, a new LiveView using the admin `shell`. The page is
built from server-side aggregates only; no raw rows reach the browser apart from
drill-down lists of at most 50 rows. Only the open tab's figures are queried.

One bar holds the tabs (left) and the filters (right). The window selector shows only
on tabs that use it.

| Tab (`:tab`) | Content | Later |
|---|---|---|
| Overview (default) | Summary cards, activation rate first and highlighted; daily chart | P2: paying card |
| Funnel | One row per stage: horizontal bar (share of signups), users, % of signups, % of previous + drop-off; one caption line under it. Window selector | P2: stage 5 |
| Acquisition | Channel table, campaigns expand under the channel. Window selector | P2: D7 column · P3: theme by channel, campaign drill-downs |
| Themes | First/all sites toggle; stacked bar of the theme choice + legend; theme table | — |
| Retention *(Phase 2)* | Cohort table; the tab is added with it, not shown empty before | — |

Card numbers, funnel stages and channel signups open the drill-down: a slide-over on a
dimmed backdrop, closed with the button, a click outside or Esc.

Every card, funnel stage and column header has a definition tooltip: an
`<.icon name="hero-information-circle">` with the text from *Definitions*, exposed as
both `title` and `aria-label`.

### Filters

Tab and filters live in the URL (`/admin/growth/funnel?range=30&window=14`, Phase 3 adds
`&channel=google-ads&cohort=2026-W40`) and are applied with `push_patch`, the same
pattern the console uses. Switching tabs keeps the filters.

- **Range / "Period"** (default 30 days): applies to every figure: the cards (signups in
  range, sites created in range), the chart, the funnel cohort, theme insights (sites
  created in range) and acquisition (signups in range). Cards add the all-time
  equivalent as a sub-line, hidden when the range is already "All time".
- **Channel** (Phase 3): restricts the eligible-user set everywhere.
- **Cohort week** (Phase 3): restricts the eligible-user set to signups in that ISO week
  and overrides the range.

### Sections

**Summary cards (MVP)**: all over signups in range.

| Card | Main figure | Secondary |
|---|---|---|
| Activation rate (highlighted) | activated / eligible signups | "x of y signups published"; written/import split; all-time rate |
| Signups | eligible signups | all time |
| Sites created | sites created in range (every site) | sites per creator among signups in range; all time |
| Returning | signups with ≥ 1 active day after signup day, among signups ≥ `tracking_since` | tracked signups; rolling D7 retention |
| Paying customers *(Phase 2)* | paying customers | paid sites; MRR |

**Funnel (MVP stages 1-4, Phase 2 adds 5)**

1. Signed up
2. Created first site
3. Activated
4. Returned
5. Became paying (first `started` event on a site they created)

- The cohort is the eligible users who signed up in range.
- A user is counted at a stage only if they reached it **and every earlier stage**
  within the window *N* (7, 14 or 30 days after signup; default 14).
- Only signups at least *N* days old are included (mature cohort). The UI states how
  many recent signups were left out.
- Each stage shows: users, % of the previous stage, % of signups, and drop-off.
- Stage 3 shows the written/import split.
- Stage 4 is measured only for signups ≥ `tracking_since`, and the funnel says so.

**Daily chart (MVP).** Signups and activations per UTC day over the range, as two series
in the existing CSS bar chart. The `SiteStats` chart markup (227-264) and the `chart/1`
normalisation (96-119) are moved to `AdminLive.Components` and reused by both pages.
Range "all time" uses weekly buckets.

**Theme breakdown (MVP).** Covers each eligible user's **first site** created in range,
so users with many sites don't dominate:

- each theme by `initial_theme_id`: count and %
- the share `skipped`, `default` and `unknown`

A secondary toggle switches to "all sites created in range". *Phase 3:* theme by
channel, shown only for channels with ≥ 10 first sites.

**Acquisition (MVP: signups + activation; Phase 2: retention).** One row per channel:
signups in range, % activated (within the window *N*), and *(Phase 2)* rolling D7
retention. Columns `utm_medium` / `utm_campaign` expand under the source row. The
`Unknown` row is always shown, even when it is 0.

**Cohort retention (Phase 2).** One row per ISO signup week (newest first, max 26):

- signups
- % created a site
- % activated by D1/D7/D30
- % retained (rolling) D1/D7/D30

A cell shows "—" when the cohort isn't old enough or predates `tracking_since`.

**Drill-down (MVP).** Clicking a card number, funnel stage or acquisition row opens a
side panel listing up to 50 matching eligible accounts (newest first): email, signed
up, activated at, channel, and site count. The email links to
`/admin/users?search=<email>`. The panel has no export and no paging; the total count
is shown above the list.

### Query layer (`Masthead.Growth`)

Read functions return plain maps. Each is one or a few SQL aggregates:

- `summary(filters)`
- `funnel(filters, window_days)`
- `daily(filters)`
- `themes(filters, scope)`
- `acquisition(filters, window_days)`
- `cohorts(filters)`
- `drilldown(metric, filters, limit \\ 50)`

Shared building blocks:

- `eligible_users(filters)`: the base `User` query (eligible + range + channel + cohort).
- `channel_expr/0`: a SQL `CASE` built from the channel rules, used by both grouping and
  filtering so definitions can't drift.
- Every funnel/card number uses the **same** stage subqueries, so a card and the
  matching funnel stage always agree.

Scale today is in the hundreds of users, so there's no caching or materialised views.
Every section is computed on mount and on filter change.

## Phases

| Phase | Scope |
|---|---|
| **1 — MVP** | All schema changes, **all capture** (signup method, attribution cookie, activity days, activation stamping, page `published_at`, site creator/theme choice, license events) and the backfill. Capture ships first because lost history can't be recovered later. UI: summary cards (users, sites, activation, returning), funnel stages 1-4 with window selector, daily chart, theme breakdown, acquisition (signups + activation), drill-down, range filter. |
| **2** | Paying-customer card, MRR, funnel stage 5, cohort retention table, retention column in acquisition. |
| **3** | Channel and cohort-week filters across all sections; theme by channel; campaign drill-downs. |

## Tests

New `test/masthead/growth_test.exs` (context) and
`test/masthead_web/admin_growth_live_test.exs` (LiveView). They cover the acceptance
criteria, not the wiring:

- User + sites totals match the inserted fixtures.
- Publishing 3 posts → `activated_at` set once; the activation count is 1; a second
  publish keeps the first timestamp.
- Unpublishing or deleting all content keeps the user activated.
- A user with 3 sites counts once in unique-user metrics and 3 times in site metrics;
  their first site alone feeds the theme breakdown.
- An import activation is reported as `import` and counted in the total.
- Admin and invited users are excluded from every user metric.
- The funnel excludes signups younger than the window; a stage reached after the window
  isn't counted.
- The card and funnel numbers for the same filter are equal.
- A missing cookie gives `Unknown`; a captured but empty one gives `direct`; `gclid` only
  gives `google-ads`.
- Changing the range changes every in-range figure and leaves all-time figures alone.
- A non-admin is redirected from `/admin/growth`.
- `license_events`: a repeated identical webhook writes no second row; gift → `gifted`,
  not counted as paying.
- The attribution plug never overwrites an existing cookie and never runs for a
  logged-in user.

## Implementation order

1. Migration + schemas (`Growth`, `Licenses.Event`); `Page` `published_at`.
2. Capture: `Growth.touch/mark_activated` and call sites; signup method; attribution
   plug + signup wiring; `created_by_id` / theme choice; license events.
3. Backfill data migration; verify the counts against prod with `fly ssh console` before
   building the UI.
4. `Growth` read functions + context tests.
5. `AdminLive.Growth` + route + nav link; move the chart component out of `SiteStats`.
6. Phase 2, then Phase 3.

## Decisions

| Question | Decision |
|---|---|
| Spec scope | Full feature, phased; MVP = brief section 11 |
| Placement | Separate LiveView at `/admin/growth` |
| Eligible users | Exclude admins and invited collaborators; keep disabled/suspended |
| Imports | Count as activation; reported separately (`activated_via`) |
| Timezone | UTC |
| Retention storage | `user_activity_days` (user, date) |
| Attribution | First-party signed cookie, first touch, 30 days; no IP/gclid/full URL |
| Theme choice | Stored on `sites` at creation; backfill inferred |
| Subscriptions | `license_events` table from deploy; current paid sites backfilled |
| Page publish date | Add `pages.published_at`; backfill = `inserted_at` |
| Invited users | `users.signup_method`; existing users inferred and flagged |
| Activation window | Window selector on the funnel + weekly cohort table |
| Drill-down | Email + key dates, max 50, linked to the Users tab |
| Activation record | Stamped on `users` (`activated_at`, `activated_via`), never cleared |
| Retention flavour | Rolling (active on or after day *n*) — fits low volume better than exact-day |
| Site creator | New `sites.created_by_id` instead of inferring from the earliest membership, which breaks if the creator leaves the site |
| Site creation | Counts as a meaningful action (not in the brief's list; clearly product use) |

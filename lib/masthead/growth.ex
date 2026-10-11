defmodule Masthead.Growth do
  @moduledoc """
  Platform growth reporting for the admin Growth dashboard: the write helpers
  that record activity/activation, and the aggregate queries that read them.
  Definitions live in docs/2026-10-10-growth-dashboard-spec.md.
  """
  import Ecto.Query

  alias Masthead.Accounts.User
  alias Masthead.Licenses
  alias Masthead.Licenses.Event
  alias Masthead.Repo
  alias Masthead.Sites.Site
  alias Masthead.Themes.Theme

  # Capture starts when the growth migration runs (release_command, just
  # before the new code serves traffic), so the DB knows the exact moment.
  @tracking_migration 20_261_010_120_000

  @search_engines ~w(google bing duckduckgo ecosia yahoo yandex baidu startpage qwant brave)

  # Registrable host match: `www.google.nl`, `google.co.uk`, `search.brave.com`.
  # `{0,1}` rather than `?`, which `fragment/1` would read as a placeholder.
  @search_regex "(^|\\.)(#{Enum.join(@search_engines, "|")})(\\.[a-z]{2,3}){0,1}\\.[a-z]{2,}$"

  # The channel rules from the spec, in order. Literal SQL (no parameters) so
  # the same expression can be selected, grouped and filtered on.
  @channel_sql """
  CASE
    WHEN ? IS NULL THEN 'Unknown'
    WHEN coalesce(?, '') <> '' THEN lower(?)
    WHEN ? THEN 'google-ads'
    WHEN ? ~* '#{@search_regex}' THEN 'organic-search'
    WHEN coalesce(?, '') <> '' THEN 'referral:' || lower(?)
    ELSE 'direct'
  END
  """

  # SQL `CASE` deriving a user's acquisition channel; `u` is a `User` binding.
  defmacrop channel_expr(u) do
    quote do
      fragment(
        unquote(@channel_sql),
        unquote(u).first_seen_at,
        unquote(u).utm_source,
        unquote(u).utm_source,
        unquote(u).gclid_present,
        unquote(u).referrer_domain,
        unquote(u).referrer_domain,
        unquote(u).referrer_domain
      )
    end
  end

  @doc "Records that `user_id` did a meaningful action today (UTC). Idempotent."
  def touch(user_id) when is_integer(user_id) do
    Repo.insert_all("user_activity_days", [%{user_id: user_id, date: Date.utc_today()}],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Stamps the user's first publish. `via` is `"written"` or `"import"`. Only
  the first call has an effect, so repeated publishes count the user once.
  """
  def mark_activated(user_id, via) when is_integer(user_id) and via in ~w(written import) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(u in User, where: u.id == ^user_id and is_nil(u.activated_at)),
      set: [activated_at: now, activated_via: via]
    )

    :ok
  end

  # ---- Reads ----
  #
  # `filters` is `%{range: 7 | 30 | 90 | :all}`: the last N UTC days including
  # today. Every user number counts eligible users only; site counts are all
  # sites, soft-deleted included.

  @stages [:signed_up, :created_site, :activated, :returned, :paying]

  @doc """
  When growth capture started: the moment the tracking migration ran.
  Returns and attribution only exist for signups from here on.
  """
  def tracking_since do
    from(m in "schema_migrations",
      where: m.version == ^@tracking_migration,
      select: m.inserted_at
    )
    |> Repo.one!()
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc "Eligible users (not admin, not invited) who signed up in the range."
  def eligible_users(filters) do
    from(u in User, where: not u.admin and u.signup_method != "invite")
    |> in_range(:inserted_at, filters)
  end

  @doc """
  Card figures for the eligible users who signed up in range (sites: every
  site created in range). `*_all` are the all-time equivalents; returns only
  count signups since `tracking_since/0`. `paid_sites`/`mrr_cents` are the
  current state, whatever the range.
  """
  def summary(filters) do
    users = rows(filters)
    all = rows(%{range: :all})
    activated = split(users, reached(:activated, nil))

    d7_cohort =
      users
      |> where(^tracked())
      |> where([x], x.signup_date <= ^Date.add(Date.utc_today(), -7))

    %{
      users: count_where(users, dynamic(true)),
      users_all: count_where(all, dynamic(true)),
      sites: Site |> in_range(:inserted_at, filters) |> Repo.aggregate(:count),
      sites_all: Repo.aggregate(Site, :count),
      creators: count_where(users, reached(:created_site, nil)),
      creator_sites:
        Repo.aggregate(
          from(s in Site,
            join: u in subquery(eligible_users(filters)),
            on: u.id == s.created_by_id
          ),
          :count
        ),
      activated: activated.total,
      written: activated.written,
      import: activated.import,
      activated_all: count_where(all, reached(:activated, nil)),
      returning: count_where(users, reached(:returned, nil)),
      tracked: count_where(users, tracked()),
      d7_cohort: count_where(d7_cohort, dynamic(true)),
      d7_retained:
        count_where(
          d7_cohort,
          dynamic([x], x.last_active_on >= date_add(x.signup_date, 7, "day"))
        ),
      paying: count_where(users, reached(:paying, nil)),
      paying_all: count_where(all, reached(:paying, nil))
    }
    |> Map.merge(revenue())
  end

  @doc """
  Funnel over the users who signed up in range and at least `window` days
  ago. A stage counts a user only if they reached it and every earlier stage
  within `window` days of signup. `previous`/`signups` are each stage's
  denominators; "returned" is compared against tracked signups only.
  """
  def funnel(filters, window) when window in [7, 14, 30] do
    cohort = cohort(filters, window)
    counts = Map.new(@stages, &{&1, count_where(cohort, reached(&1, window))})
    tracked_signups = count_where(cohort, tracked())
    tracked_activated = count_where(cohort, dynamic(^reached(:activated, window) and ^tracked()))

    %{
      window: window,
      excluded: Repo.aggregate(rows(filters), :count) - counts.signed_up,
      activated: split(cohort, reached(:activated, window)),
      stages: [
        %{stage: :signed_up, users: counts.signed_up, previous: nil, signups: counts.signed_up},
        %{
          stage: :created_site,
          users: counts.created_site,
          previous: counts.signed_up,
          signups: counts.signed_up
        },
        %{
          stage: :activated,
          users: counts.activated,
          previous: counts.created_site,
          signups: counts.signed_up
        },
        %{
          stage: :returned,
          users: counts.returned,
          previous: tracked_activated,
          signups: tracked_signups
        },
        %{
          stage: :paying,
          users: counts.paying,
          previous: counts.returned,
          signups: tracked_signups
        }
      ]
    }
  end

  @doc """
  Paid sites right now (Stripe-sourced, not deleted) and their MRR in cents:
  each site's latest priced event, monthly as-is, yearly ÷ 12. Sites known only
  from the backfill have no price on record and use today's plan price.
  """
  def revenue do
    priced =
      from(e in Event,
        where: e.kind in ~w(started renewed plan_changed) and not is_nil(e.amount_cents),
        distinct: e.site_id,
        order_by: [asc: e.site_id, desc: e.occurred_at, desc: e.id]
      )

    sites =
      from(s in paid_sites(),
        left_join: p in subquery(priced),
        on: p.site_id == s.id,
        select: {coalesce(p.plan, s.license_plan), p.amount_cents}
      )
      |> Repo.all()

    mrr = sites |> Enum.map(fn {plan, cents} -> monthly(plan, cents) end) |> Enum.sum()
    %{paid_sites: length(sites), mrr_cents: round(mrr)}
  end

  defp monthly("monthly", cents), do: cents || Licenses.amount("monthly")
  defp monthly("yearly", cents), do: (cents || Licenses.amount("yearly")) / 12
  defp monthly(_plan, cents), do: cents || 0

  @doc """
  Weekly signup cohorts (ISO weeks, newest first, up to `limit`), all time.
  Activation by day n is over every signup in the week, retention (active on
  or after day n) over its signups since `tracking_since/0`. A day-n figure
  is nil until the week's last signup is n days old, and retention is nil for
  weeks without tracked signups.
  """
  def cohorts(limit \\ 26) do
    since = tracking_since()

    weeks =
      select_merge(rows(%{range: :all}), [x], %{
        week: fragment("date_trunc('week', ?)::date", x.signed_up_at)
      })

    from(w in subquery(weeks),
      group_by: w.week,
      order_by: [desc: w.week],
      limit: ^limit,
      select: %{
        week: w.week,
        signups: count(w.id),
        created_site: filter(count(w.id), not is_nil(w.first_site_at)),
        tracked: filter(count(w.id), w.signed_up_at >= ^since),
        activated_d1:
          filter(count(w.id), w.activated_at <= datetime_add(w.signed_up_at, 1, "day")),
        activated_d7:
          filter(count(w.id), w.activated_at <= datetime_add(w.signed_up_at, 7, "day")),
        activated_d30:
          filter(count(w.id), w.activated_at <= datetime_add(w.signed_up_at, 30, "day")),
        retained_d1:
          filter(
            count(w.id),
            w.signed_up_at >= ^since and w.last_active_on >= date_add(w.signup_date, 1, "day")
          ),
        retained_d7:
          filter(
            count(w.id),
            w.signed_up_at >= ^since and w.last_active_on >= date_add(w.signup_date, 7, "day")
          ),
        retained_d30:
          filter(
            count(w.id),
            w.signed_up_at >= ^since and w.last_active_on >= date_add(w.signup_date, 30, "day")
          )
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      age = Date.diff(Date.utc_today(), Date.add(row.week, 6))
      at = fn n, count -> if age >= n, do: count end
      retained = fn n, count -> if age >= n and row.tracked > 0, do: count end

      %{
        week: row.week,
        signups: row.signups,
        created_site: row.created_site,
        tracked: row.tracked,
        activated: [
          at.(1, row.activated_d1),
          at.(7, row.activated_d7),
          at.(30, row.activated_d30)
        ],
        retained: [
          retained.(1, row.retained_d1),
          retained.(7, row.retained_d7),
          retained.(30, row.retained_d30)
        ]
      }
    end)
  end

  @doc """
  Signups and activations per UTC day in range; per ISO week (Monday dates)
  for `range: :all`.
  """
  def daily(%{range: range} = filters) do
    weekly? = range == :all
    signups = bucket_counts(eligible_users(filters), :inserted_at, weekly?)

    activations =
      eligible_users(%{range: :all})
      |> where([u], not is_nil(u.activated_at))
      |> in_range(:activated_at, filters)
      |> bucket_counts(:activated_at, weekly?)

    for date <- buckets(range, Map.keys(signups)) do
      %{
        date: date,
        signups: Map.get(signups, date, 0),
        activations: Map.get(activations, date, 0)
      }
    end
  end

  @doc """
  Initial theme and theme choice of sites created in range. `:first` takes
  each eligible user's first site (so prolific users don't dominate), `:all`
  every site.
  """
  def themes(filters, :first) do
    firsts =
      from(s in Site,
        join: u in subquery(eligible_users(%{range: :all})),
        on: u.id == s.created_by_id,
        distinct: s.created_by_id,
        order_by: [asc: s.inserted_at, asc: s.id]
      )

    from(s in subquery(firsts)) |> in_range(:inserted_at, filters) |> theme_breakdown()
  end

  def themes(filters, :all), do: Site |> in_range(:inserted_at, filters) |> theme_breakdown()

  @doc """
  Signups in range per channel, with how many activated within `window`
  days and rolling D7 retention (`d7_retained` of `d7_cohort`: tracked
  signups at least 7 days old); `campaigns` breaks a channel down by
  utm_medium/utm_campaign. The `Unknown` row is always present and listed last.
  """
  def acquisition(filters, window) when window in [7, 14, 30] do
    since = tracking_since()
    week_ago = Date.add(Date.utc_today(), -7)

    from(x in rows(filters),
      group_by: [x.channel, x.utm_medium, x.utm_campaign],
      select: %{
        channel: x.channel,
        medium: x.utm_medium,
        campaign: x.utm_campaign,
        signups: count(x.id),
        activated:
          filter(count(x.id), x.activated_at <= datetime_add(x.signed_up_at, ^window, "day")),
        d7_cohort: filter(count(x.id), x.signed_up_at >= ^since and x.signup_date <= ^week_ago),
        d7_retained:
          filter(
            count(x.id),
            x.signed_up_at >= ^since and x.signup_date <= ^week_ago and
              x.last_active_on >= date_add(x.signup_date, 7, "day")
          )
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.channel)
    |> Map.put_new("Unknown", [])
    |> Enum.map(fn {channel, subs} ->
      sum = fn key -> subs |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

      %{
        channel: channel,
        signups: sum.(:signups),
        activated: sum.(:activated),
        d7_cohort: sum.(:d7_cohort),
        d7_retained: sum.(:d7_retained),
        campaigns: Enum.filter(subs, &(&1.medium || &1.campaign))
      }
    end)
    |> Enum.sort_by(&{&1.channel == "Unknown", -&1.signups, &1.channel})
  end

  @doc """
  Up to `limit` accounts behind a figure, newest signup first, plus the total.
  `metric` is a card (`:signed_up | :created_site | :activated | :returned`),
  `{:funnel, stage, window}` or `{:channel, channel}`.
  """
  def drilldown(metric, filters, limit \\ 50) do
    query = drill_query(metric, filters)

    %{
      total: Repo.aggregate(query, :count),
      users:
        query |> order_by([x], desc: x.signed_up_at, desc: x.id) |> limit(^limit) |> Repo.all()
    }
  end

  defp drill_query({:funnel, stage, window}, filters) when stage in @stages,
    do: where(cohort(filters, window), ^reached(stage, window))

  defp drill_query({:channel, channel}, filters),
    do: where(rows(filters), [x], x.channel == ^channel)

  defp drill_query(stage, filters) when stage in @stages,
    do: where(rows(filters), ^reached(stage, nil))

  # One row per eligible user with the moment they reached each stage: the
  # single source for every card, funnel stage and drill-down.
  defp rows(filters), do: from(x in subquery(stages(eligible_users(filters))))

  defp stages(users) do
    sites =
      from(s in Site,
        where: not is_nil(s.created_by_id),
        group_by: s.created_by_id,
        select: %{user_id: s.created_by_id, first_at: min(s.inserted_at), count: count()}
      )

    activity =
      from(d in "user_activity_days",
        join: u in User,
        on: u.id == d.user_id,
        group_by: d.user_id,
        select: %{
          user_id: d.user_id,
          returned_on: filter(min(d.date), d.date > fragment("?::date", u.inserted_at)),
          last_active_on: max(d.date)
        }
      )

    # First Stripe start on any site the user created; history starts at
    # `tracking_since/0`, the backfill only records who pays now.
    first_paid =
      from(e in Event,
        join: s in Site,
        on: s.id == e.site_id,
        where: e.kind == "started" and not is_nil(s.created_by_id),
        group_by: s.created_by_id,
        select: %{user_id: s.created_by_id, at: min(e.occurred_at)}
      )

    paying =
      from(s in paid_sites(), group_by: s.created_by_id, select: %{user_id: s.created_by_id})

    from(u in users,
      left_join: s in subquery(sites),
      on: s.user_id == u.id,
      left_join: a in subquery(activity),
      on: a.user_id == u.id,
      left_join: fp in subquery(first_paid),
      on: fp.user_id == u.id,
      left_join: p in subquery(paying),
      on: p.user_id == u.id,
      select: %{
        id: u.id,
        email: u.email,
        signed_up_at: u.inserted_at,
        signup_date: fragment("?::date", u.inserted_at),
        first_site_at: s.first_at,
        site_count: coalesce(s.count, 0),
        activated_at: u.activated_at,
        activated_via: u.activated_via,
        returned_on: a.returned_on,
        last_active_on: a.last_active_on,
        first_paid_at: fp.at,
        paying: not is_nil(p.user_id),
        channel: channel_expr(u),
        utm_medium: u.utm_medium,
        utm_campaign: u.utm_campaign
      }
    )
  end

  # Sites paid right now whose latest license event came from Stripe: gifts,
  # grants and deleted sites don't count.
  # ponytail: a gift top-up on a Stripe site hides it until its next renewal
  # webhook; key on the subscription instead if that starts to matter.
  defp paid_sites do
    latest =
      from(e in Event,
        distinct: e.site_id,
        order_by: [asc: e.site_id, desc: e.occurred_at, desc: e.id],
        select: %{site_id: e.site_id, source: e.source}
      )

    from(s in Site,
      join: l in subquery(latest),
      on: l.site_id == s.id and l.source == "stripe",
      where: is_nil(s.deleted_at)
    )
    |> Licenses.where_paid()
  end

  # Signups in range old enough to have had the full window.
  defp cohort(filters, window) do
    cutoff = DateTime.utc_now() |> DateTime.add(-window, :day) |> DateTime.truncate(:second)
    where(rows(filters), [x], x.signed_up_at <= ^cutoff)
  end

  # Reached `stage`: ever (window nil, the cards), or strictly — together with
  # every earlier stage — within `window` days of signup (the funnel).
  defp reached(:signed_up, _window), do: dynamic(true)
  defp reached(:created_site, nil), do: dynamic([x], not is_nil(x.first_site_at))
  defp reached(:activated, nil), do: dynamic([x], not is_nil(x.activated_at))
  defp reached(:returned, nil), do: dynamic([x], not is_nil(x.returned_on) and ^tracked())
  # Cards count who pays now; the funnel counts a first Stripe start in the window.
  defp reached(:paying, nil), do: dynamic([x], x.paying)

  defp reached(:created_site, window),
    do: dynamic([x], x.first_site_at <= datetime_add(x.signed_up_at, ^window, "day"))

  defp reached(:activated, window) do
    dynamic(
      [x],
      ^reached(:created_site, window) and
        x.activated_at <= datetime_add(x.signed_up_at, ^window, "day")
    )
  end

  defp reached(:returned, window) do
    dynamic(
      [x],
      ^reached(:activated, window) and ^tracked() and
        x.returned_on <= date_add(x.signup_date, ^window, "day")
    )
  end

  defp reached(:paying, window) do
    dynamic(
      [x],
      ^reached(:returned, window) and
        x.first_paid_at <= datetime_add(x.signed_up_at, ^window, "day")
    )
  end

  defp tracked do
    since = tracking_since()
    dynamic([x], x.signed_up_at >= ^since)
  end

  defp count_where(query, condition), do: query |> where(^condition) |> Repo.aggregate(:count)

  defp split(query, condition) do
    by_via =
      query
      |> where(^condition)
      |> group_by([x], x.activated_via)
      |> select([x], {x.activated_via, count()})
      |> Repo.all()
      |> Map.new()

    %{
      total: by_via |> Map.values() |> Enum.sum(),
      written: Map.get(by_via, "written", 0),
      import: Map.get(by_via, "import", 0)
    }
  end

  defp theme_breakdown(sites) do
    themes =
      from(s in sites,
        left_join: t in Theme,
        on: t.id == s.initial_theme_id,
        group_by: [s.initial_theme_id, t.name],
        order_by: [desc: count(s.id), asc: t.name],
        select: %{name: t.name, count: count(s.id)}
      )
      |> Repo.all()

    choices =
      from(s in sites,
        group_by: fragment("coalesce(?, 'unknown')", s.theme_choice),
        select: {fragment("coalesce(?, 'unknown')", s.theme_choice), count(s.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{total: themes |> Enum.map(& &1.count) |> Enum.sum(), themes: themes, choices: choices}
  end

  defp bucket_counts(query, field, weekly?) do
    dates =
      if weekly?,
        do: select(query, [r], %{d: fragment("date_trunc('week', ?)::date", field(r, ^field))}),
        else: select(query, [r], %{d: fragment("?::date", field(r, ^field))})

    from(b in subquery(dates), group_by: b.d, select: {b.d, count()}) |> Repo.all() |> Map.new()
  end

  defp buckets(:all, dates) do
    this_week = Date.beginning_of_week(Date.utc_today())
    Date.range(Enum.min(dates, Date, fn -> this_week end), this_week, 7)
  end

  defp buckets(days, _dates),
    do: Date.range(Date.add(Date.utc_today(), 1 - days), Date.utc_today())

  defp in_range(query, _field, %{range: :all}), do: query

  defp in_range(query, field, %{range: days}) do
    today = Date.utc_today()
    first = DateTime.new!(Date.add(today, 1 - days), ~T[00:00:00])
    stop = DateTime.new!(Date.add(today, 1), ~T[00:00:00])
    where(query, [r], field(r, ^field) >= ^first and field(r, ^field) < ^stop)
  end
end

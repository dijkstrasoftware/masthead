defmodule Masthead.Growth do
  @moduledoc """
  Platform growth reporting for the admin Growth dashboard: the write helpers
  that record activity/activation, and the aggregate queries that read them.
  Definitions live in docs/2026-10-10-growth-dashboard-spec.md.
  """
  import Ecto.Query

  alias Masthead.Accounts.User
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

  @stages [:signed_up, :created_site, :activated, :returned]

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
  count signups since `tracking_since/0`.
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
        )
    }
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
        }
      ]
    }
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
  days; `campaigns` breaks a channel down by utm_medium/utm_campaign. The
  `Unknown` row is always present and listed last.
  """
  def acquisition(filters, window) when window in [7, 14, 30] do
    from(x in rows(filters),
      group_by: [x.channel, x.utm_medium, x.utm_campaign],
      select: %{
        channel: x.channel,
        medium: x.utm_medium,
        campaign: x.utm_campaign,
        signups: count(x.id),
        activated:
          filter(count(x.id), x.activated_at <= datetime_add(x.signed_up_at, ^window, "day"))
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.channel)
    |> Map.put_new("Unknown", [])
    |> Enum.map(fn {channel, subs} ->
      %{
        channel: channel,
        signups: subs |> Enum.map(& &1.signups) |> Enum.sum(),
        activated: subs |> Enum.map(& &1.activated) |> Enum.sum(),
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

    from(u in users,
      left_join: s in subquery(sites),
      on: s.user_id == u.id,
      left_join: a in subquery(activity),
      on: a.user_id == u.id,
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
        channel: channel_expr(u),
        utm_medium: u.utm_medium,
        utm_campaign: u.utm_campaign
      }
    )
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

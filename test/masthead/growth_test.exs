defmodule Masthead.GrowthTest do
  use Masthead.DataCase, async: true

  alias Masthead.Accounts.User
  alias Masthead.Growth
  alias Masthead.Sites.Site

  @all %{range: :all}

  setup do
    Masthead.Themes.Seed.run()
    %{theme: Masthead.Themes.get_built_in_by_slug("default")}
  end

  defp ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)

  defp after_signup(%User{inserted_at: at}, days), do: DateTime.add(at, days, :day)

  defp user(attrs \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct!(
        %User{
          email: "growth-#{n}@example.com",
          display_name: "Growth #{n}",
          hashed_password: "not-a-real-hash",
          inserted_at: ago(20)
        },
        attrs
      )
    )
  end

  defp site(creator, theme, attrs \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct!(
        %Site{
          slug: "growth#{n}",
          name: "Growth #{n}",
          theme_id: theme.id,
          initial_theme_id: theme.id,
          theme_choice: "chosen",
          created_by_id: creator && creator.id,
          inserted_at: ago(19)
        },
        attrs
      )
    )
  end

  defp activity(user, date),
    do: Repo.insert_all("user_activity_days", [%{user_id: user.id, date: date}])

  defp stage(funnel, name), do: Enum.find(funnel.stages, &(&1.stage == name))

  test "totals count eligible users once and every site", %{theme: theme} do
    prolific = user()
    single = user()
    admin = user(admin: true)
    invited = user(signup_method: "invite")

    for i <- 1..3, do: site(prolific, theme, inserted_at: ago(19 - i))
    site(single, theme)
    site(admin, theme)
    site(invited, theme, deleted_at: ago(1))

    summary = Growth.summary(@all)

    assert summary.users == 2
    assert summary.sites == 6
    assert summary.creators == 2
    assert summary.creator_sites == 4
  end

  test "a user's repeated publishes activate them once; imports are split out" do
    writer = user()
    importer = user()
    invited = user(signup_method: "invite")

    Growth.mark_activated(writer.id, "written")
    first = Repo.reload!(writer).activated_at
    Growth.mark_activated(writer.id, "written")
    Growth.mark_activated(writer.id, "import")
    Growth.mark_activated(importer.id, "import")
    Growth.mark_activated(invited.id, "written")

    assert Repo.reload!(writer).activated_at == first
    assert Repo.reload!(writer).activated_via == "written"
    assert %{activated: 2, written: 1, import: 1} = Growth.summary(@all)
  end

  test "the first site alone feeds the theme breakdown", %{theme: theme} do
    prolific = user()
    site(prolific, theme, inserted_at: ago(19))
    site(prolific, theme, inserted_at: ago(18), initial_theme_id: nil, theme_choice: "skipped")
    site(prolific, theme, inserted_at: ago(17), initial_theme_id: nil, theme_choice: "skipped")
    site(user(admin: true), theme, theme_choice: "default")

    first = Growth.themes(@all, :first)
    assert first.total == 1
    assert [%{name: "Default", count: 1}] = first.themes
    assert first.choices == %{"chosen" => 1}

    all = Growth.themes(@all, :all)
    assert all.total == 4
    assert all.choices == %{"chosen" => 1, "skipped" => 2, "default" => 1}
  end

  test "the funnel leaves out young signups and stages reached after the window",
       %{theme: theme} do
    on_time = user()
    site(on_time, theme, inserted_at: after_signup(on_time, 1))

    Repo.update_all(where(User, id: ^on_time.id),
      set: [activated_at: after_signup(on_time, 2), activated_via: "written"]
    )

    late = user()
    site(late, theme, inserted_at: after_signup(late, 15))

    Repo.update_all(where(User, id: ^late.id),
      set: [activated_at: after_signup(late, 16), activated_via: "written"]
    )

    young = user(inserted_at: ago(3))
    site(young, theme, inserted_at: ago(2))

    funnel = Growth.funnel(@all, 14)

    assert funnel.excluded == 1
    assert stage(funnel, :signed_up).users == 2
    assert stage(funnel, :created_site).users == 1
    assert stage(funnel, :activated).users == 1
    assert funnel.activated.written == 1

    # A 30-day window only takes signups 30+ days old: all three are left out.
    funnel = Growth.funnel(@all, 30)
    assert funnel.excluded == 3
    assert stage(funnel, :signed_up).users == 0

    assert %{total: 1, users: [%{id: id}]} =
             Growth.drilldown({:funnel, :activated, 14}, @all)

    assert id == on_time.id
  end

  test "cards and funnel stages agree for the same users", %{theme: theme} do
    for _ <- 1..3 do
      u = user()
      site(u, theme, inserted_at: after_signup(u, 1))
    end

    activated = user()
    site(activated, theme, inserted_at: after_signup(activated, 1))
    Growth.mark_activated(activated.id, "import")

    Repo.update_all(where(User, id: ^activated.id),
      set: [activated_at: after_signup(activated, 3)]
    )

    summary = Growth.summary(@all)
    funnel = Growth.funnel(@all, 14)

    assert summary.users == stage(funnel, :signed_up).users
    assert summary.creators == stage(funnel, :created_site).users
    assert summary.activated == stage(funnel, :activated).users
    assert summary.activated == 1
  end

  test "returns are only measured from tracking_since" do
    since = Growth.tracking_since()
    day = DateTime.to_date(since)
    before = user(inserted_at: DateTime.add(since, -1, :day))
    tracked = user(inserted_at: since)

    activity(before, day)
    activity(tracked, day)
    activity(tracked, Date.add(day, 1))

    summary = Growth.summary(@all)
    assert summary.returning == 1
    assert summary.tracked == 1
    assert [%{id: id}] = Growth.drilldown(:returned, @all).users
    assert id == tracked.id
  end

  test "channels follow the attribution rules" do
    seen = ago(21)
    user()
    user(first_seen_at: seen)
    user(first_seen_at: seen, gclid_present: true)
    user(first_seen_at: seen, referrer_domain: "www.google.nl")
    user(first_seen_at: seen, referrer_domain: "news.ycombinator.com")

    user(
      first_seen_at: seen,
      utm_source: "Newsletter",
      utm_medium: "email",
      utm_campaign: "launch",
      gclid_present: true
    )

    rows = Map.new(Growth.acquisition(@all, 14), &{&1.channel, &1})

    assert Map.keys(rows) |> Enum.sort() ==
             ~w(Unknown direct google-ads newsletter organic-search referral:news.ycombinator.com)

    assert [%{medium: "email", campaign: "launch", signups: 1}] = rows["newsletter"].campaigns
    assert Growth.drilldown({:channel, "google-ads"}, @all).total == 1

    # Unknown is listed even without signups in range.
    assert [%{channel: "Unknown", signups: 0}] = Growth.acquisition(%{range: 7}, 14)
  end

  test "the range moves every card figure and leaves the all-time ones alone", %{theme: theme} do
    recent = user(inserted_at: ago(3))
    old = user(inserted_at: ago(40))
    site(recent, theme, inserted_at: ago(2))
    site(old, theme, inserted_at: ago(39))
    Growth.mark_activated(old.id, "written")

    week = Growth.summary(%{range: 7})
    quarter = Growth.summary(%{range: 90})

    assert {week.users, quarter.users} == {1, 2}
    assert {week.sites, quarter.sites} == {1, 2}
    assert {week.activated, quarter.activated} == {0, 1}

    all_time = &Map.take(&1, [:users_all, :sites_all, :activated_all])
    assert all_time.(week) == all_time.(quarter)
    assert all_time.(week) == %{users_all: 2, sites_all: 2, activated_all: 1}

    daily = Growth.daily(%{range: 7})
    assert length(daily) == 7
    assert daily |> Enum.map(& &1.signups) |> Enum.sum() == 1
    assert List.last(daily) == %{date: Date.utc_today(), signups: 0, activations: 1}

    weekly = Growth.daily(@all)
    assert weekly |> Enum.map(& &1.signups) |> Enum.sum() == 2
    assert Enum.all?(weekly, &(Date.day_of_week(&1.date) == 1))

    assert Growth.themes(%{range: 7}, :first).total == 1
    assert Growth.acquisition(%{range: 7}, 14) |> Enum.map(& &1.signups) == [1]
  end
end

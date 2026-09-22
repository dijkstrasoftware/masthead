defmodule Masthead.StatsTest do
  use Masthead.DataCase, async: true

  alias Masthead.{Accounts, Sites, Stats}

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "stats-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "stats#{System.unique_integer([:positive])}",
        "name" => "Stats",
        "owner_id" => user.id
      })

    %{site: site, today: ~D[2026-09-22]}
  end

  defp range(today, days), do: Date.range(Date.add(today, 1 - days), today)

  test "a first view counts a view and a visitor", %{site: site, today: today} do
    Stats.record_view(site.id, "/", "alice", today)

    assert Stats.totals(site.id, range(today, 1)) == %{views: 1, visitors: 1}
    assert [%{path: "/", views: 1, visitors: 1}] = Stats.top_paths(site.id, range(today, 1))
  end

  test "the same visitor again only counts views", %{site: site, today: today} do
    Stats.record_view(site.id, "/", "alice", today)
    Stats.record_view(site.id, "/", "alice", today)
    Stats.record_view(site.id, "/about", "alice", today)

    assert Stats.totals(site.id, range(today, 1)) == %{views: 3, visitors: 1}

    assert [%{path: "/", views: 2, visitors: 1}, %{path: "/about", views: 1, visitors: 1}] =
             Stats.top_paths(site.id, range(today, 1))
  end

  test "a visitor is counted again on another day", %{site: site, today: today} do
    Stats.record_view(site.id, "/", "alice", Date.add(today, -1))
    Stats.record_view(site.id, "/", "alice", today)

    assert Stats.totals(site.id, range(today, 2)) == %{views: 2, visitors: 2}
  end

  test "daily is zero-filled and narrows to a path", %{site: site, today: today} do
    Stats.record_view(site.id, "/", "alice", today)
    Stats.record_view(site.id, "/about", "bob", Date.add(today, -2))

    daily = Stats.daily(site.id, range(today, 30))
    assert length(daily) == 30
    assert %{date: ^today, views: 1, visitors: 1} = List.last(daily)
    assert Enum.sum_by(daily, & &1.views) == 2

    about = Stats.daily(site.id, range(today, 30), "/about")
    assert Enum.sum_by(about, & &1.views) == 1
    assert %{views: 0} = List.last(about)
  end

  test "totals are zero without views", %{site: site, today: today} do
    assert Stats.totals(site.id, range(today, 30)) == %{views: 0, visitors: 0}
  end

  test "prune drops old aggregates and yesterday's visitor hashes", %{site: site, today: today} do
    Stats.record_view(site.id, "/", "alice", Date.add(today, -400))
    Stats.record_view(site.id, "/", "alice", Date.add(today, -2))
    Stats.record_view(site.id, "/", "alice", today)

    Stats.prune(today)

    assert Stats.totals(site.id, range(today, 500)) == %{views: 2, visitors: 2}
    assert Repo.aggregate("view_visitors", :count) == 1
  end
end

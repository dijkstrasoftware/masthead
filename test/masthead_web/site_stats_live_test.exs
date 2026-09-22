defmodule MastheadWeb.SiteStatsLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Licenses, Sites, Stats}

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ss-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "ss#{System.unique_integer([:positive])}",
        "name" => "SS Test",
        "owner_id" => user.id
      })

    Stats.record_view(site.id, "/", "alice")
    Stats.record_view(site.id, "/posts/hello", "bob")
    Stats.record_view(site.id, "/old", "carol", Date.add(Date.utc_today(), -3))

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  test "a free site sees a blank preview under the upgrade dialog", %{conn: conn, site: site} do
    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/stats")

    assert html =~ "plan-card"
    assert has_element?(lv, ".stats-locked .metric .num", "—")
    refute html =~ "/posts/hello"

    lv |> element("button", "Not now") |> render_click()
    refute has_element?(lv, ".plan-card")

    lv |> element(".stats-locked") |> render_click()
    assert has_element?(lv, ".plan-card")
  end

  test "the nav item and page are marked with the stats feature flag", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}")

    assert html =~ ~s(data-feature="stats")
    assert html =~ "/_masthead/no-track?t="
  end

  test "a paid site sees totals, the chart and per-path rows", %{conn: conn, site: site} do
    {:ok, site} = Licenses.grant(site)
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/stats")

    refute html =~ "Upgrade to see statistics"
    assert html =~ "stats-bar"
    assert html =~ "/posts/hello"
    assert html =~ "Last 90 days"
  end

  test "picking a path and a range patches the URL", %{conn: conn, site: site} do
    {:ok, site} = Licenses.grant(site)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/stats")

    lv |> element("td a", "/posts/hello") |> render_click()
    assert_patch(lv, ~p"/#{site.slug}/stats?#{[range: 30, path: "/posts/hello"]}")
    assert has_element?(lv, ".stats-active-filters .author-chip", "Page /posts/hello")

    lv |> element(".admin-filters a", "Last 90 days") |> render_click()
    assert_patch(lv, ~p"/#{site.slug}/stats?#{[range: 90, path: "/posts/hello"]}")

    lv |> element(".author-chip", "Page") |> render_click()
    assert_patch(lv, ~p"/#{site.slug}/stats?#{[range: 90]}")
    refute has_element?(lv, ".stats-active-filters")
  end

  test "picking a day narrows the table to that day", %{conn: conn, site: site} do
    {:ok, site} = Licenses.grant(site)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/stats")
    assert has_element?(lv, "td a", "/old")

    today = Date.to_iso8601(Date.utc_today())
    lv |> element(~s(.stats-day[href*="day=#{today}"])) |> render_click()

    assert_patch(lv, ~p"/#{site.slug}/stats?#{[range: 30, day: today]}")
    assert has_element?(lv, "h2", "Pages on")
    assert has_element?(lv, ".author-chip", "On ")
    assert has_element?(lv, "td a", "/posts/hello")
    refute has_element?(lv, "td a", "/old")
  end

  test "hovering a day has its counts in the tooltip", %{conn: conn, site: site} do
    {:ok, site} = Licenses.grant(site)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/stats")

    assert lv |> element(".stats-day:last-child .stats-tip") |> render() =~ "2 views"
  end
end

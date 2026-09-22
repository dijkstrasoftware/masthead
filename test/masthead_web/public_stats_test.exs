defmodule MastheadWeb.PublicStatsTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Content, Sites, Stats, Themes}
  alias MastheadWeb.ViewTracker

  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15"

  setup %{conn: conn} do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ps-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    slug = "ps#{System.unique_integer([:positive])}"

    {:ok, site} =
      Sites.create_site(%{
        "slug" => slug,
        "name" => "Stats Site",
        "owner_id" => user.id,
        "theme_id" => Themes.get_built_in_by_slug("default").id
      })

    {:ok, _post} =
      Content.create_post(site.id, %{"title" => "Hi", "slug" => "hi", "published" => "true"})

    conn =
      %{conn | host: "#{slug}.lvh.me"}
      |> put_req_header("user-agent", @browser)

    %{conn: conn, site: site}
  end

  defp today, do: Date.range(Date.utc_today(), Date.utc_today())

  test "a rendered page records a view by its path without the query", %{conn: conn, site: site} do
    conn |> get("/") |> html_response(200)
    conn |> get("/posts/hi/?utm=x") |> html_response(200)

    assert Stats.totals(site.id, today()) == %{views: 2, visitors: 1}
    paths = site.id |> Stats.top_paths(today()) |> Enum.map(& &1.path) |> Enum.sort()
    assert paths == ["/", "/posts/hi"]
  end

  test "not-found pages, search and bots are not counted", %{conn: conn, site: site} do
    conn |> get("/posts/missing") |> html_response(404)
    conn |> get("/search?q=hi") |> html_response(200)
    conn |> put_req_header("user-agent", "Googlebot/2.1") |> get("/") |> html_response(200)

    assert Stats.totals(site.id, today()) == %{views: 0, visitors: 0}
  end

  test "the opt-out link stops counting that browser", %{conn: conn, site: site} do
    token = ViewTracker.opt_out_url(site) |> URI.parse() |> Map.fetch!(:query)
    opted = get(conn, "/_masthead/no-track?" <> token)

    assert redirected_to(opted) == "/"
    assert opted.resp_cookies["masthead_no_track"].value == "1"

    conn |> put_req_cookie("masthead_no_track", "1") |> get("/") |> html_response(200)
    assert Stats.totals(site.id, today()) == %{views: 0, visitors: 0}
  end

  test "an opt-out token for another site sets no cookie", %{conn: conn, site: site} do
    other = %{site | id: site.id + 1_000_000}
    token = ViewTracker.opt_out_url(other) |> URI.parse() |> Map.fetch!(:query)

    refute get(conn, "/_masthead/no-track?" <> token).resp_cookies["masthead_no_track"]
  end
end

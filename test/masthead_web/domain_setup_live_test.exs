defmodule MastheadWeb.DomainSetupLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ds-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "ds#{System.unique_integer([:positive])}",
        "name" => "DS Test",
        "owner_id" => user.id
      })

    {:ok, site} = Masthead.Licenses.grant(site)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  test "renders step 1 for an unconfigured site", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, "/#{site.slug}/domain")
    assert html =~ "Add a custom domain"
  end

  test "adding a subdomain advances to the DNS step", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, "/#{site.slug}/domain")

    html =
      lv
      |> form("form", %{"custom_domain" => "blog.example.com"})
      |> render_submit()

    assert html =~ "blog.example.com"
    assert html =~ "Proves you own this domain"
    assert html =~ "Add these records at your DNS provider"
  end

  test "settings shows the set-up link", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, "/#{site.slug}/settings")
    assert html =~ "Set up a custom domain"
  end
end

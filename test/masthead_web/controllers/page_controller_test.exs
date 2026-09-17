defmodule MastheadWeb.PageControllerTest do
  use MastheadWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~
             "A publishing engine for content-driven websites."
  end

  test "GET / renders SEO metadata", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(<meta name="description")
    assert html =~ "open-source, multi-tenant publishing platform"
    assert html =~ ~s(rel="canonical")
    assert html =~ ~s(property="og:title")
    assert html =~ ~s(name="twitter:card")
  end

  test "GET / embeds JSON-LD structured data for answer engines", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(<script type="application/ld+json")
    assert html =~ "SoftwareApplication"
    assert html =~ "FAQPage"
    # Visible FAQ content must be present so it matches the FAQPage schema.
    assert html =~ "What is Masthead?"
    assert html =~ "Can I use my own domain?"
  end

  test "GET /pricing is public and shows both plans", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    assert html =~ "Free to publish."
    assert html =~ "€0"
    assert html =~ "€5"
    assert html =~ "€50"
    assert html =~ "Save €10 a year"
    assert html =~ "Your own custom domain"
    assert html =~ "Invite collaborators to the site"
  end

  test "GET /pricing follows the configured prices", %{conn: conn} do
    System.put_env("LICENSE_PRICE_MONTHLY_CENTS", "900")
    System.put_env("LICENSE_PRICE_YEARLY_CENTS", "9900")

    on_exit(fn ->
      System.delete_env("LICENSE_PRICE_MONTHLY_CENTS")
      System.delete_env("LICENSE_PRICE_YEARLY_CENTS")
    end)

    html = conn |> get(~p"/pricing") |> html_response(200)

    assert html =~ "€9"
    assert html =~ "€99"
    assert html =~ "Save €9 a year"
  end

  test "GET /pricing embeds Offer structured data", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    assert html =~ ~s(<script type="application/ld+json")
    assert html =~ "Offer"
    assert html =~ "priceCurrency"
    assert html =~ ~s(rel="canonical")
  end

  test "the public pages carry the Google Analytics snippet when configured", %{conn: conn} do
    System.put_env("GOOGLE_ANALYTICS_ID", "G-TEST123")
    on_exit(fn -> System.delete_env("GOOGLE_ANALYTICS_ID") end)

    assert conn |> get(~p"/") |> html_response(200) =~ "gtag/js?id=G-TEST123"
    assert conn |> get(~p"/pricing") |> html_response(200) =~ "gtag/js?id=G-TEST123"
    assert conn |> get(~p"/login") |> html_response(200) =~ "gtag/js?id=G-TEST123"
  end

  test "the Google Analytics snippet is absent when unconfigured", %{conn: conn} do
    refute conn |> get(~p"/") |> html_response(200) =~ "googletagmanager"
  end

  test "the homepage links to pricing", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/pricing")
  end

  test "serves robots.txt, sitemap.xml and llms.txt", %{conn: conn} do
    assert conn |> get("/robots.txt") |> response(200) =~
             "Sitemap: https://masthead.site/sitemap.xml"

    assert conn |> get("/sitemap.xml") |> response(200) =~
             "<loc>https://masthead.site/pricing</loc>"

    assert conn |> get("/llms.txt") |> response(200) =~ "# Masthead"
  end
end

defmodule MastheadWeb.PublicSeoTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Content, Repo, Sites, Themes}

  setup %{conn: conn} do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "seo-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    slug = "seo#{System.unique_integer([:positive])}"

    {:ok, site} =
      Sites.create_site(%{
        "slug" => slug,
        "name" => "Seo Site",
        "description" => "Notes on\nbaking bread.",
        "owner_id" => user.id,
        "theme_id" => Themes.get_built_in_by_slug("default").id
      })

    {:ok, _post} =
      Content.create_post(site.id, %{
        "title" => "Sourdough",
        "slug" => "sourdough",
        "excerpt" => "A starter guide.",
        "published" => "true"
      })

    {:ok, _draft} =
      Content.create_post(site.id, %{"title" => "Secret", "slug" => "secret-draft"})

    {:ok, _about} =
      Content.create_page(site.id, %{"title" => "About", "slug" => "about", "published" => "true"})

    {:ok, home} =
      Content.create_page(site.id, %{
        "title" => "Welcome",
        "slug" => "welcome",
        "published" => "true"
      })

    site |> Ecto.Changeset.change(homepage_page_id: home.id) |> Repo.update!()

    %{conn: %{conn | host: "#{slug}.lvh.me"}, base: "http://#{slug}.lvh.me"}
  end

  test "robots.txt points at the site's own sitemap", %{conn: conn, base: base} do
    body = conn |> get("/robots.txt") |> response(200)

    assert body =~ "Sitemap: #{base}/sitemap.xml"
    refute body =~ "masthead.site"
    refute body =~ "/admin"
  end

  test "sitemap.xml lists published content, with the homepage page only at /", %{
    conn: conn,
    base: base
  } do
    body = conn |> get("/sitemap.xml") |> response(200)

    assert body =~ "<loc>#{base}/</loc>"
    assert body =~ "<loc>#{base}/about</loc>"
    assert body =~ "<loc>#{base}/posts/sourdough</loc>"
    refute body =~ "secret-draft"
    refute body =~ "/welcome"
  end

  test "llms.txt summarises the site and its posts", %{conn: conn, base: base} do
    body = conn |> get("/llms.txt") |> response(200)

    assert body =~ "# Seo Site\n\n> Notes on baking bread.\n"
    assert body =~ "- [About](#{base}/about)"
    assert body =~ "- [Sourdough](#{base}/posts/sourdough): A starter guide."
    refute body =~ "Secret"
  end
end

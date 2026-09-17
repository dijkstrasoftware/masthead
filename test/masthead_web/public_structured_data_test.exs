defmodule MastheadWeb.PublicStructuredDataTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Content, Repo, Sites, Themes}

  setup %{conn: conn} do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ld-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    slug = "ld#{System.unique_integer([:positive])}"

    {:ok, site} =
      Sites.create_site(%{
        "slug" => slug,
        "name" => "Bakery",
        "description" => "Notes on bread.",
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

    {:ok, _draft} = Content.create_post(site.id, %{"title" => "Draft", "slug" => "draft"})

    {:ok, _about} =
      Content.create_page(site.id, %{"title" => "About", "slug" => "about", "published" => "true"})

    %{conn: %{conn | host: "#{slug}.lvh.me"}, site: site, base: "http://#{slug}.lvh.me:4000"}
  end

  defp json_ld(conn, path, status \\ 200) do
    html = conn |> get(path) |> html_response(status)

    case Regex.run(~r{<script type="application/ld\+json">(.*?)</script>}s, html) do
      [_, json] -> Jason.decode!(json)
      nil -> nil
    end
  end

  test "the homepage is a WebSite", %{conn: conn, base: base} do
    assert %{"@type" => "WebSite", "url" => url, "name" => "Bakery"} = data = json_ld(conn, "/")
    assert url == base <> "/"
    assert data["description"] == "Notes on bread."
  end

  test "a post is an Article", %{conn: conn, base: base} do
    data = json_ld(conn, "/posts/sourdough")

    assert data["@type"] == "Article"
    assert data["headline"] == "Sourdough"
    assert data["description"] == "A starter guide."
    assert data["url"] == base <> "/posts/sourdough"
    assert data["datePublished"]
    assert data["dateModified"]
    assert data["publisher"]["name"] == "Bakery"
    refute Map.has_key?(data, "author")
  end

  test "a page is a WebPage", %{conn: conn, base: base} do
    assert %{"@type" => "WebPage", "name" => "About", "url" => url} = json_ld(conn, "/about")
    assert url == base <> "/about"
  end

  test "non-canonical and missing pages carry none", %{conn: conn} do
    assert json_ld(conn, "/posts/draft", 404) == nil
    assert json_ld(conn, "/?tag=news") == nil
    assert json_ld(conn, "/search?q=sour") == nil
  end

  test "a homepage page is described at / only", %{conn: conn, site: site} do
    {:ok, home} =
      Content.create_page(site.id, %{"title" => "Home", "slug" => "home", "published" => "true"})

    site |> Ecto.Changeset.change(homepage_page_id: home.id) |> Repo.update!()

    assert %{"@type" => "WebSite"} = json_ld(conn, "/")
    assert json_ld(conn, "/home") == nil
  end

  test "an active custom domain is the only canonical host", %{conn: conn, site: site} do
    site
    |> Ecto.Changeset.change(custom_domain: "bakery.example", custom_domain_status: "active")
    |> Repo.update!()

    assert json_ld(conn, "/posts/sourdough") == nil

    data = json_ld(%{conn | host: "bakery.example"}, "/posts/sourdough")
    assert data["url"] == "https://bakery.example/posts/sourdough"
  end
end

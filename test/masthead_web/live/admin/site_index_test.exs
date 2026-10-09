defmodule MastheadWeb.AdminLive.SiteIndexTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Repo, Themes}
  alias Masthead.Sites.Site

  setup do
    Themes.Seed.run()
    user = register("owner")
    author = register("author")

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, author: author}
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp theme(author, name, tag_slug, opts) do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "st#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: author.id
      })

    {:ok, theme} = Themes.set_theme_tags(theme, [Themes.get_theme_tag_by_slug(tag_slug).id])
    theme = if Keyword.get(opts, :public, true), do: ok(Themes.publish_theme(theme)), else: theme
    if Keyword.get(opts, :verified, true), do: ok(Themes.verify_theme(theme)), else: theme
  end

  defp ok({:ok, value}), do: value

  defp open(conn) do
    {:ok, lv, _html} = live(conn, ~p"/sites")
    lv |> element("button.btn-add") |> render_click()
    lv
  end

  defp submit(lv, params) do
    lv |> form("#new-site-form", site: params) |> render_submit()
  end

  defp default_theme_id, do: Themes.get_built_in_by_slug("default").id

  test "purpose step lists only tags with a verified public theme", %{conn: conn, author: a} do
    theme(a, "Blogger", "blog", [])
    theme(a, "Unverified", "portfolio", verified: false)
    theme(a, "Private", "shop", public: false)

    lv = open(conn)

    assert has_element?(lv, "#new-site-purpose")
    assert has_element?(lv, "#purpose-blog", "1 template")
    refute has_element?(lv, "#purpose-portfolio")
    refute has_element?(lv, "#purpose-shop")
    refute has_element?(lv, "#purpose-minimal")
  end

  test "picking a purpose shows only matching starter themes", %{conn: conn, author: a} do
    match = theme(a, "Blogger", "blog", [])
    unverified = theme(a, "Unverified", "blog", verified: false)
    private = theme(a, "Private", "blog", public: false)
    other = theme(a, "Folio", "portfolio", [])

    lv = open(conn)
    lv |> element("#purpose-blog") |> render_click()

    assert has_element?(lv, "#new-site-templates")
    assert has_element?(lv, "#starter-theme-#{match.id}")
    assert has_element?(lv, ~s(#starter-theme-#{match.id} a[target="_blank"]))
    refute has_element?(lv, "#starter-theme-#{unverified.id}")
    refute has_element?(lv, "#starter-theme-#{private.id}")
    refute has_element?(lv, "#starter-theme-#{other.id}")
  end

  test "choosing a template creates the site on it and installs it", %{conn: conn, author: a} do
    starter = theme(a, "Blogger", "blog", [])

    lv = open(conn)
    lv |> element("#purpose-blog") |> render_click()
    lv |> element("#starter-theme-#{starter.id} button") |> render_click()

    assert has_element?(lv, "#new-site-form", "Blogger")

    assert {:error, {:live_redirect, _}} = submit(lv, %{name: "Picked", slug: "picked"})

    site = Repo.get_by!(Site, slug: "picked")
    assert site.theme_id == starter.id
    assert starter.id in Enum.map(Themes.list_themes_for_site(site), & &1.id)
  end

  test "skip creates the site on the default theme", %{conn: conn, author: a} do
    theme(a, "Blogger", "blog", [])

    lv = open(conn)
    lv |> element("#new-site-skip") |> render_click()

    assert {:error, {:live_redirect, _}} = submit(lv, %{name: "Skipped", slug: "skipped"})
    assert Repo.get_by!(Site, slug: "skipped").theme_id == default_theme_id()
  end

  test "with no starter themes the dialog opens on the details step", %{conn: conn} do
    lv = open(conn)

    assert has_element?(lv, "#new-site-form")
    refute has_element?(lv, "#new-site-purpose")
  end

  test "a crafted theme_id in the save params is ignored", %{conn: conn, author: a} do
    private = theme(a, "Private", "blog", public: false, verified: false)

    lv = open(conn)

    assert {:error, {:live_redirect, _}} =
             render_submit(lv, "save", %{
               "site" => %{"name" => "Crafted", "slug" => "crafted", "theme_id" => private.id}
             })

    assert Repo.get_by!(Site, slug: "crafted").theme_id == default_theme_id()
  end
end

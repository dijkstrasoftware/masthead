defmodule MastheadWeb.PostFormOptionsLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Content, Sites, Themes}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "pof-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "pof#{System.unique_integer([:positive])}",
        "name" => "Post Options Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site, user: user}
  end

  test "the wizard offers a Post options step when the theme declares them", %{
    conn: conn,
    site: site
  } do
    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/posts/new")

    assert html =~ "Post options"

    lv
    |> element(~s([phx-click="choose_format"][phx-value-format="markdown"]))
    |> render_click()

    html =
      lv
      |> form("#meta-form", post: %{"title" => "Hello"})
      |> render_submit()

    assert html =~ ~s(name="post[post_options][seo_description]")
    assert html =~ ~s(phx-value-meta="featured_image")
  end

  test "a post option is saved to the post", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/new")

    lv
    |> element(~s([phx-click="choose_format"][phx-value-format="markdown"]))
    |> render_click()

    lv |> form("#meta-form", post: %{"title" => "Hello"}) |> render_submit()

    lv
    |> form("#settings-form", post: %{"post_options" => %{"seo_description" => "Read this."}})
    |> render_submit()

    lv
    |> form("#content-form", post: %{"body" => "Body."})
    |> render_submit(%{"action" => "draft"})

    [post] = Content.list_posts(site.id)
    assert post.post_options["seo_description"] == "Read this."
  end

  test "an existing post's options prefill the step", %{conn: conn, site: site} do
    {:ok, post} =
      Content.create_post(site.id, %{
        "title" => "Stored",
        "body" => "Body.",
        "post_options" => %{"seo_description" => "Already set."}
      })

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/#{post.id}/edit")

    html =
      lv
      |> element(~s(li[phx-click="goto_step"][phx-value-step="3"]))
      |> render_click()

    assert html =~ "Already set."
  end

  test "the step is skipped when the theme declares no post options", %{
    conn: conn,
    site: site,
    user: user
  } do
    site = install_optionless_theme(site, user)

    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/posts/new")

    refute html =~ "Post options"

    lv
    |> element(~s([phx-click="choose_format"][phx-value-format="markdown"]))
    |> render_click()

    html =
      lv
      |> form("#meta-form", post: %{"title" => "Hello"})
      |> render_submit()

    assert html =~ ~s(id="content-form")
  end

  defp install_optionless_theme(site, user) do
    slug = "noopt#{System.unique_integer([:positive])}"

    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "No options",
          "slug" => slug,
          "version" => "1.0.0",
          "render_version" => "v1",
          "tokens" => [],
          "page_options" => [],
          "post_options" => []
        }),
      "templates/layout.liquid" => "<html><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/not_found.liquid" => "<h1>404</h1>",
      "theme.css" => "body { background: #fff; }"
    }

    tmp = Path.join(System.tmp_dir!(), "noopt-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)

    {:ok, theme} = Masthead.Themes.Package.install(tmp, user.id)
    File.rm(tmp)
    {:ok, _} = Sites.update_settings(site, %{"theme_id" => theme.id})
    Sites.get_site!(site.id)
  end
end

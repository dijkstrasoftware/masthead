defmodule MastheadWeb.SiteImportLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Actions, Content, Sites, Themes}

  setup do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "si-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "si#{System.unique_integer([:positive])}",
        "name" => "SI Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site, theme: default}
  end

  test "renders the import screen", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/import")

    assert html =~ "Import a site"
    assert html =~ "dropzone"
  end

  test "imports a Hugo site uploaded as a zip", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/import")

    zip =
      site_zip(%{
        "content/posts/hello.md" => "---\ntitle: Hello\ndraft: false\n---\nHi there.",
        "content/about.md" => "---\ntitle: About\n---\nAbout us.",
        "config.toml" => "x = 1"
      })

    file =
      file_input(lv, "#import-form", :site_archive, [
        %{name: "site.zip", content: zip, type: "application/zip"}
      ])

    render_upload(file, "site.zip")
    html = lv |> element("#import-form") |> render_submit()

    assert html =~ "Imported 1 posts, 1 pages"
    assert length(Content.list_posts(site.id)) == 1
    assert length(Content.list_pages(site.id)) == 1

    # A successful import ticks off the onboarding checklist item.
    refute Enum.any?(Actions.list_pending(site), &(&1.key == "import_site"))
  end

  test "imports a Masthead theme preview uploaded as a zip", %{
    conn: conn,
    site: site,
    theme: theme
  } do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/import")

    zip =
      site_zip(%{
        "preview.json" => ~s({"site": {"homepage": "home"}}),
        "preview/pages/home.md" =>
          ~s(---\n{"title": "Home", "page_options": {"layout": "wide"}}\n---\nHi.),
        "preview/posts/hello.md" => "Hello there.",
        "manifest.json" => Jason.encode!(%{"slug" => theme.slug, "version" => theme.version})
      })

    file =
      file_input(lv, "#import-form", :site_archive, [
        %{name: "theme.zip", content: zip, type: "application/zip"}
      ])

    render_upload(file, "theme.zip")
    html = lv |> element("#import-form") |> render_submit()

    assert html =~ "Imported 1 posts, 1 pages"

    assert [%{slug: "home", page_options: %{"layout" => "wide"}} = home] =
             Content.list_pages(site.id)

    assert Sites.get_site!(site.id).homepage_page_id == home.id
  end

  test "rejects a preview built for another theme", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/import")

    zip =
      site_zip(%{
        "preview.json" => ~s({"site": {}}),
        "manifest.json" => ~s({"slug": "studio", "version": "2.0.0"})
      })

    file =
      file_input(lv, "#import-form", :site_archive, [
        %{name: "theme.zip", content: zip, type: "application/zip"}
      ])

    render_upload(file, "theme.zip")
    html = lv |> element("#import-form") |> render_submit()

    assert html =~ "built for studio 2.0.0"
    assert Content.list_pages(site.id) == []
  end

  test "rejects an archive it can't recognise", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/import")

    file =
      file_input(lv, "#import-form", :site_archive, [
        %{name: "x.zip", content: site_zip(%{"readme.txt" => "hi"}), type: "application/zip"}
      ])

    render_upload(file, "x.zip")
    html = lv |> element("#import-form") |> render_submit()

    assert html =~ "doesn&#39;t look like a Hugo site or a Masthead theme preview"
  end

  # Builds an in-memory zip of a source tree from a relpath => content map.
  defp site_zip(files) do
    base = Path.join(System.tmp_dir!(), "si-src-#{System.unique_integer([:positive])}")

    for {rel, content} <- files do
      abs = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end

    rels = files |> Map.keys() |> Enum.map(&String.to_charlist/1)

    {:ok, {_name, bytes}} =
      :zip.create(~c"site.zip", rels, [:memory, cwd: String.to_charlist(base)])

    File.rm_rf(base)
    bytes
  end
end

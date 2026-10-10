defmodule MastheadWeb.GrowthCaptureLiveTest do
  use MastheadWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Content, Repo, Sites, Themes}
  alias Masthead.Accounts.User
  alias Masthead.Sites.Site

  setup do
    Themes.Seed.run()
    user = register("owner")
    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "gc#{System.unique_integer([:positive])}",
        "name" => "Growth Capture",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site, user: user, default: default}
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp active_today?(user) do
    Repo.exists?(
      from d in "user_activity_days",
        where: d.user_id == ^user.id and d.date == ^Date.utc_today()
    )
  end

  defp reload(user), do: Repo.get!(User, user.id)

  describe "site creation" do
    test "create_site/1 records the creator and defaults theme_choice", %{
      site: site,
      user: user,
      default: default
    } do
      site = Repo.get!(Site, site.id)
      assert site.created_by_id == user.id
      assert site.initial_theme_id == default.id
      assert site.theme_choice == "default"
      # Context calls are not user actions.
      refute active_today?(user)
    end

    test "wizard: picking a template is chosen", %{conn: conn, user: user} do
      starter = starter_theme()
      lv = open_wizard(conn)
      lv |> element("#purpose-blog") |> render_click()
      lv |> element("#starter-theme-#{starter.id} button") |> render_click()
      submit_wizard(lv, "picked")

      site = Repo.get_by!(Site, slug: "picked")
      assert site.theme_choice == "chosen"
      assert site.initial_theme_id == starter.id
      assert site.created_by_id == user.id
      assert active_today?(user)
    end

    test "wizard: skip is skipped", %{conn: conn, user: user, default: default} do
      starter_theme()
      lv = open_wizard(conn)
      lv |> element("#new-site-skip") |> render_click()
      submit_wizard(lv, "skipped")

      site = Repo.get_by!(Site, slug: "skipped")
      assert site.theme_choice == "skipped"
      assert site.initial_theme_id == default.id
      assert active_today?(user)
    end

    test "wizard: growth fields can't be forged from params", %{conn: conn, user: user} do
      other = register("other")
      lv = open_wizard(conn)

      render_submit(lv, "save", %{
        "site" => %{
          "name" => "Forged",
          "slug" => "forged",
          "theme_choice" => "chosen",
          "created_by_id" => other.id
        }
      })

      site = Repo.get_by!(Site, slug: "forged")
      assert site.created_by_id == user.id
      assert site.theme_choice == "default"
    end
  end

  describe "posts" do
    test "saving a draft records activity but not activation", %{
      conn: conn,
      site: site,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/new")
      render_submit(lv, "save", %{"post" => %{"title" => "Draft"}, "action" => "draft"})

      assert [%{published: false}] = Content.list_posts(site.id)
      assert active_today?(user)
      assert reload(user).activated_at == nil
    end

    test "first publish activates once; later publishes, unpublish and delete keep it", %{
      conn: conn,
      site: site,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/new")
      render_submit(lv, "save", %{"post" => %{"title" => "Live"}, "action" => "publish"})

      user = reload(user)
      assert user.activated_via == "written"
      assert active_today?(user)

      # Backdate so a re-stamp would be visible.
      first = ~U[2026-01-01 00:00:00Z]
      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [activated_at: first])

      [post] = Content.list_posts(site.id)
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/#{post.id}/edit")
      render_click(lv, "toggle_publish")
      render_click(lv, "toggle_publish")
      render_submit(lv, "save", %{"post" => %{"title" => "Live again"}})
      # Save navigates away, so delete through the context.
      {:ok, _} = site.id |> Content.list_posts() |> hd() |> Content.delete_post()

      assert reload(user).activated_at == first
      assert reload(user).activated_via == "written"
    end
  end

  describe "pages" do
    test "editing a draft records activity; publishing activates", %{
      conn: conn,
      site: site,
      user: user
    } do
      {:ok, page} = Content.create_page(site.id, %{"title" => "About"})
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/#{page.id}/edit")

      render_submit(lv, "save", %{"page" => %{"title" => "About us"}})
      assert active_today?(user)
      assert reload(user).activated_at == nil

      render_click(lv, "toggle_publish")
      assert %User{activated_via: "written", activated_at: %DateTime{}} = reload(user)
    end
  end

  test "saving site settings records activity", %{conn: conn, site: site, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
    lv |> form("#site-settings-form", site: %{name: "Renamed"}) |> render_submit()

    assert active_today?(user)
  end

  test "saving theme settings records activity", %{conn: conn, site: site, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")
    lv |> form("#site-theme-form") |> render_submit()

    assert active_today?(user)
  end

  describe "site import" do
    test "published content activates via import", %{conn: conn, site: site, user: user} do
      import_zip(conn, site, %{
        "content/posts/hello.md" => "---\ntitle: Hello\ndraft: false\n---\nHi.",
        "config.toml" => "x = 1"
      })

      assert active_today?(user)
      assert %User{activated_via: "import", activated_at: %DateTime{}} = reload(user)
    end

    test "drafts only record activity", %{conn: conn, site: site, user: user} do
      import_zip(conn, site, %{
        "content/posts/hello.md" => "---\ntitle: Hello\ndraft: true\n---\nHi.",
        "config.toml" => "x = 1"
      })

      assert active_today?(user)
      assert reload(user).activated_at == nil
    end
  end

  defp open_wizard(conn) do
    {:ok, lv, _html} = live(conn, ~p"/sites")
    lv |> element("button.btn-add") |> render_click()
    lv
  end

  defp submit_wizard(lv, slug) do
    lv |> form("#new-site-form", site: %{name: slug, slug: slug}) |> render_submit()
  end

  defp starter_theme do
    author = register("author")

    {:ok, theme} =
      Themes.create_upload(%{
        slug: "st#{System.unique_integer([:positive])}",
        name: "Blogger",
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: author.id
      })

    {:ok, theme} = Themes.set_theme_tags(theme, [Themes.get_theme_tag_by_slug("blog").id])
    {:ok, theme} = Themes.publish_theme(theme)
    {:ok, theme} = Themes.verify_theme(theme)
    theme
  end

  defp import_zip(conn, site, files) do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/import")

    file =
      file_input(lv, "#import-form", :site_archive, [
        %{name: "site.zip", content: site_zip(files), type: "application/zip"}
      ])

    render_upload(file, "site.zip")
    lv |> element("#import-form") |> render_submit()
  end

  defp site_zip(files) do
    base = Path.join(System.tmp_dir!(), "gc-src-#{System.unique_integer([:positive])}")

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

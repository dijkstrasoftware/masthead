defmodule MastheadWeb.AdminConsoleLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, admin} =
      Accounts.register_user(%{
        "email" => "admin-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, admin} = Accounts.set_admin(admin, true)

    {:ok, member} =
      Accounts.register_user(%{
        "email" => "member-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "mem#{System.unique_integer([:positive])}",
        "name" => "Member Site",
        "owner_id" => member.id
      })

    %{admin: admin, member: member, site: site, conn: conn_for(admin)}
  end

  defp conn_for(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "non-admins are redirected away from /admin", %{member: member} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn_for(member), ~p"/admin")
  end

  test "admin sees all users, sites and themes", %{conn: conn, member: member, site: site} do
    {:ok, lv, html} = live(conn, ~p"/admin")

    # Users tab (default).
    assert html =~ member.email

    # Sites tab.
    html = lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()
    assert html =~ site.name
    assert html =~ site.slug

    # Themes tab defaults to the Public filter; built-ins live under Built-in.
    lv |> element(~s(button[phx-value-tab="themes"])) |> render_click()

    html =
      lv
      |> element(~s(button[phx-value-scope="themes"][phx-value-filter="built_in"]))
      |> render_click()

    assert html =~ "Default"
  end

  test "tab and filter are read from the URL", %{conn: conn, member: member, site: site} do
    {:ok, _} = Sites.soft_delete_site(site)

    # Filter as a path segment.
    {:ok, _lv, html} = live(conn, ~p"/admin/sites/deleted")
    assert html =~ site.name

    # The default sites view (enabled) hides the deleted site.
    {:ok, _lv, html} = live(conn, ~p"/admin/sites")
    refute html =~ site.name

    # Filter as a query param.
    {:ok, _} = Accounts.verify_user(member)
    {:ok, _lv, html} = live(conn, ~p"/admin/users?filter=verified")
    assert html =~ member.email
  end

  test "switching tab and filter patches the URL", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/admin")

    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()
    assert_patch(lv, ~p"/admin/sites/enabled")

    lv
    |> element(~s(button[phx-click="switch_filter"][phx-value-filter="deleted"]))
    |> render_click()

    assert_patch(lv, ~p"/admin/sites/deleted")

    # "All" on the users tab resets explicitly via /all (a bare /admin/users
    # would keep the previous filter).
    lv |> element(~s(button[phx-value-tab="users"])) |> render_click()

    lv
    |> element(~s(button[phx-click="switch_filter"][phx-value-filter="verified"]))
    |> render_click()

    assert_patch(lv, ~p"/admin/users/verified")

    lv
    |> element(
      ~s(button[phx-click="switch_filter"][phx-value-scope="users"][phx-value-filter="all"])
    )
    |> render_click()

    assert_patch(lv, ~p"/admin/users/all")
  end

  test "clicking a column header sorts the list and flips on a second click", %{conn: conn} do
    for email <- ["aaa@example.com", "zzz@example.com"] do
      {:ok, _} = Accounts.register_user(%{"email" => email, "password" => "password1234"})
    end

    {:ok, lv, _} = live(conn, ~p"/admin")

    html = click_sort(lv, "email")
    assert index_of(html, "aaa@example.com") < index_of(html, "zzz@example.com")

    html = click_sort(lv, "email")
    assert index_of(html, "zzz@example.com") < index_of(html, "aaa@example.com")
  end

  defp click_sort(lv, field) do
    lv
    |> element(~s(button[phx-value-scope="users"][phx-value-field="#{field}"]))
    |> render_click()
  end

  # The signed-in admin's own email also sits in the page shell, so only the
  # table body says anything about the sort.
  defp index_of(html, needle) do
    [rows] = Regex.run(~r/<tbody.*<\/tbody>/s, html)
    {start, _} = :binary.match(rows, needle)
    start
  end

  test "admin can verify an unverified user", %{conn: conn, member: member} do
    refute Accounts.User.confirmed?(member)
    {:ok, lv, _} = live(conn, ~p"/admin")

    open_row_menu(lv, member)

    lv
    |> element(~s(button[phx-click="verify_user"][phx-value-id="#{member.id}"]))
    |> render_click()

    assert Accounts.get_user!(member.id) |> Accounts.User.confirmed?()
  end

  test "admin can disable and re-enable a site", %{conn: conn, site: site} do
    {:ok, lv, _} = live(conn, ~p"/admin")
    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="disable_site"][phx-value-id="#{site.id}"]))
    |> render_click()

    assert Sites.get_site!(site.id).disabled_at

    # The list defaults to enabled sites, so switch filters to find it again.
    lv
    |> element(
      ~s(button[phx-click="switch_filter"][phx-value-scope="sites"][phx-value-filter="disabled"])
    )
    |> render_click()

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="enable_site"][phx-value-id="#{site.id}"]))
    |> render_click()

    refute Sites.get_site!(site.id).disabled_at
  end

  test "admin can soft-delete and restore a site", %{conn: conn, site: site} do
    {:ok, lv, _} = live(conn, ~p"/admin")
    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="delete_site"][phx-value-id="#{site.id}"]))
    |> render_click()

    assert Sites.get_site!(site.id).deleted_at

    # The list defaults to enabled sites, so switch filters to find it again.
    lv
    |> element(
      ~s(button[phx-click="switch_filter"][phx-value-scope="sites"][phx-value-filter="deleted"])
    )
    |> render_click()

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="restore_site"][phx-value-id="#{site.id}"]))
    |> render_click()

    refute Sites.get_site!(site.id).deleted_at
  end

  test "admin can add a custom action to a site via the modal", %{conn: conn, site: site} do
    {:ok, lv, _} = live(conn, ~p"/admin")
    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="open_action_modal"][phx-value-site_id="#{site.id}"]))
    |> render_click()

    lv
    |> form(~s(form[phx-submit="create_action"]), %{
      title: "Please add a logo",
      message: "Your header looks bare."
    })
    |> render_submit()

    action = Enum.find(Masthead.Actions.list_pending(site), &(&1.title == "Please add a logo"))
    assert action
    assert action.message == "Your header looks bare."
  end

  test "admin can enter another person's site at owner level", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}")
    # The site dashboard loads (admin bypassed the ownership check).
    assert html =~ site.name
  end

  test "admin can download an uploaded theme as a zip", %{conn: conn, member: member} do
    slug = "dl#{System.unique_integer([:positive])}"
    {:ok, theme} = install_uploaded_theme(slug, member.id)

    conn = get(conn, ~p"/admin/themes/#{theme.id}/download")

    assert response_content_type(conn, :zip) =~ "zip"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "#{slug}-1.0.0.zip"
    # The body is a real zip (PK magic bytes).
    assert binary_part(conn.resp_body, 0, 2) == "PK"
  end

  defp install_uploaded_theme(slug, owner_id) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "DL #{slug}",
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => []
        }),
      "templates/layout.liquid" => "<html><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body{}"
    }

    tmp = Path.join(System.tmp_dir!(), "dl-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    result = Masthead.Themes.Package.install(tmp, owner_id)
    File.rm(tmp)
    result
  end

  defp open_row_menu(lv, row) do
    lv
    |> element(~s(button[phx-click="toggle_menu"][phx-value-id="#{row.id}"]))
    |> render_click()
  end

  test "the row menu gifts Pro to a site", %{conn: conn, site: site} do
    {:ok, lv, _} = live(conn, ~p"/admin")
    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()

    refute Masthead.Licenses.paid?(Sites.get_site!(site.id))

    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="open_gift_modal"][phx-value-site_id="#{site.id}"]))
    |> render_click()

    lv |> form(~s(form[phx-submit="gift_pro"]), %{months: "4"}) |> render_submit()

    site = Sites.get_site!(site.id)
    assert Masthead.Licenses.paid?(site)
    assert site.license_plan == "gift"
    assert DateTime.diff(site.license_expires_at, DateTime.utc_now(), :day) in 119..123
  end

  test "gifting rejects a nonsense number of months", %{conn: conn, site: site} do
    {:ok, lv, _} = live(conn, ~p"/admin")
    lv |> element(~s(button[phx-value-tab="sites"])) |> render_click()
    open_row_menu(lv, site)

    lv
    |> element(~s(button[phx-click="open_gift_modal"][phx-value-site_id="#{site.id}"]))
    |> render_click()

    html = lv |> form(~s(form[phx-submit="gift_pro"]), %{months: "0"}) |> render_submit()

    assert html =~ "between 1 and 120"
    refute Masthead.Licenses.paid?(Sites.get_site!(site.id))
  end
end

defmodule MastheadWeb.ChecklistLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "cl-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "cl#{System.unique_integer([:positive])}",
        "name" => "CL Test",
        "owner_id" => user.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  test "checklist lists the pending content actions with their buttons", %{
    conn: conn,
    site: site
  } do
    {:ok, _lv, html} = live(conn, "/#{site.slug}/checklist")
    assert html =~ "Create your first post"
    assert html =~ "Create post"
    assert html =~ ~p"/#{site.slug}/posts/new"
  end

  test "the overview dashboard surfaces the highest-priority action", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, "/#{site.slug}")
    assert html =~ "action-card"
    # a brand-new site leads with importing an existing site
    assert html =~ "Import your old site"
  end

  test "dismissing an action removes it and updates the badge count", %{conn: conn, site: site} do
    {:ok, lv, html} = live(conn, "/#{site.slug}/checklist")
    assert html =~ "Create your first post"
    # three seeded actions: import_site, create_first_post, create_first_page
    assert html =~ ~s(nav-badge">3)

    html =
      lv
      |> element(~s(button[phx-value-key="create_first_post"]))
      |> render_click()

    refute html =~ "Create your first post"
    assert html =~ ~s(nav-badge">2)
  end

  test "the sidebar shows a red badge with the pending count", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, "/#{site.slug}")
    assert html =~ "nav-badge"
    # The badge carries the pulse hook so it animates when the count changes.
    assert html =~ ~s(phx-hook="BadgePulse")
  end

  test "the checklist shows the empty state once every action is done", %{conn: conn, site: site} do
    for key <- ["set_description", "create_first_post", "create_first_page", "import_site"] do
      :ok = Masthead.Actions.complete_action(site, key)
    end

    {:ok, _lv, html} = live(conn, "/#{site.slug}/checklist")
    assert html =~ "caught up"
    refute html =~ "Set the description"
  end

  describe "new todo" do
    test "adds a todo with a site-relative link", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      lv
      |> form("#new-todo-form", %{
        "title" => "Swap the logo",
        "message" => "Ask Sam for the SVG",
        "path" => "/uploads"
      })
      |> render_submit()

      assert has_element?(lv, ".action-card-title", "Swap the logo")
      assert has_element?(lv, ~s(a[href="/#{site.slug}/uploads"]), "Open")
      refute has_element?(lv, "#new-todo-form")
    end

    test "a todo without a link has no button", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      lv
      |> form("#new-todo-form", %{"title" => "Just a reminder", "path" => ""})
      |> render_submit()

      [action] =
        Enum.filter(Masthead.Actions.list_pending(site), &(&1.title == "Just a reminder"))

      assert action.path == nil
    end

    test "an external link opens in a new tab", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      lv
      |> form("#new-todo-form", %{"title" => "Read this", "path" => "https://example.com"})
      |> render_submit()

      assert has_element?(lv, ~s(a[href="https://example.com"][target="_blank"]))
    end

    test "counts description characters and flags going over", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()
      assert has_element?(lv, "#todo-message-count", "0/200")

      lv |> form("#new-todo-form", %{"message" => "Hello"}) |> render_change()
      assert has_element?(lv, "#todo-message-count", "5/200")
      refute has_element?(lv, "#todo-message-count.is-over")

      lv |> form("#new-todo-form", %{"message" => String.duplicate("a", 201)}) |> render_change()
      assert has_element?(lv, "#todo-message-count.is-over", "201/200")
      assert has_element?(lv, ~s(#new-todo-form button[type="submit"][disabled]))
    end

    test "editing the description keeps the title and link", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      lv
      |> form("#new-todo-form", %{"title" => "Keep me", "message" => "x", "path" => "/uploads"})
      |> render_change()

      assert has_element?(lv, ~s(#new-todo-form input[name="title"][value="Keep me"]))
      assert has_element?(lv, ~s(#new-todo-form input[name="path"][value="/uploads"]))
      assert has_element?(lv, "#new-todo-form textarea", "x")
    end

    test "caps the description so the card stays small", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      html =
        lv
        |> form("#new-todo-form", %{"title" => "Long", "message" => String.duplicate("a", 201)})
        |> render_submit()

      assert html =~ "short description (max 200)"
      refute has_element?(lv, ".action-card-title", "Long")
    end

    test "rejects a javascript: link", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, "/#{site.slug}/checklist")
      lv |> element("#new-todo") |> render_click()

      html =
        lv
        |> form("#new-todo-form", %{"title" => "Bad", "path" => "javascript:alert(1)"})
        |> render_submit()

      assert html =~ "Link must start with"
      assert has_element?(lv, "#new-todo-form")
    end
  end
end

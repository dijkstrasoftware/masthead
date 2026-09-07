defmodule MastheadWeb.MarketplaceLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites, Themes}

  setup do
    Themes.Seed.run()

    user = register("viewer")
    author = register("author")

    %{user: user, author: author, conn: conn_for(user)}
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp conn_for(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp published(user, name, opts \\ []) do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "ut#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id
      })

    {:ok, theme} = Themes.publish_theme(theme)
    if opts[:verified], do: elem(Themes.verify_theme(theme), 1), else: theme
  end

  test "lists published themes from others with status chips", %{conn: conn, author: author} do
    _verified = published(author, "Verified One", verified: true)
    _community = published(author, "Community One")

    {:ok, _lv, html} = live(conn, ~p"/marketplace")

    assert html =~ "Verified One"
    assert html =~ "Community One"
    # Verified themes get the green chip; community themes show no badge.
    assert html =~ "chip-verified"
    refute html =~ "chip-community"
  end

  test "verified and community filters narrow the list", %{conn: conn, author: author} do
    _verified = published(author, "Verified One", verified: true)
    _community = published(author, "Community One")

    {:ok, lv, _html} = live(conn, ~p"/marketplace")

    html = lv |> element(~s(a[href="/marketplace/verified"])) |> render_click()
    assert html =~ "Verified One"
    refute html =~ "Community One"

    html = lv |> element(~s(a[href="/marketplace/community"])) |> render_click()
    assert html =~ "Community One"
    refute html =~ "Verified One"
  end

  test "each filter is directly linkable by URL", %{conn: conn, author: author} do
    _verified = published(author, "Verified One", verified: true)
    _community = published(author, "Community One")

    {:ok, _lv, html} = live(conn, ~p"/marketplace/verified")
    assert html =~ "Verified One"
    refute html =~ "Community One"

    {:ok, _lv, html} = live(conn, ~p"/marketplace/community")
    assert html =~ "Community One"
    refute html =~ "Verified One"
  end

  test "search narrows themes by name", %{conn: conn, author: author} do
    _sunrise = published(author, "Sunrise")
    _moonset = published(author, "Moonset")

    {:ok, lv, _html} = live(conn, ~p"/marketplace")

    html = lv |> form(~s(form[phx-change="search"]), %{query: "sun"}) |> render_change()

    assert html =~ "Sunrise"
    refute html =~ "Moonset"
  end

  test "search also matches a theme's description", %{conn: conn, author: author} do
    described = published(author, "Nebula")
    {:ok, _} = Themes.update_details(described, %{"description" => "A documentation theme."})
    _other = published(author, "Sunrise")

    {:ok, lv, _html} = live(conn, ~p"/marketplace")

    html = lv |> form(~s(form[phx-change="search"]), %{query: "documentation"}) |> render_change()

    assert html =~ "Nebula"
    refute html =~ "Sunrise"
  end

  test "the browse card shows the description", %{conn: conn, author: author} do
    theme = published(author, "Described")
    {:ok, _} = Themes.update_details(theme, %{"description" => "Calm and roomy."})

    {:ok, _lv, html} = live(conn, ~p"/marketplace")

    assert html =~ "Calm and roomy."
  end

  test "My themes has its own search box", %{conn: conn, user: user} do
    _keep = published(user, "Keeper")
    _drop = published(user, "Dropper")

    {:ok, lv, html} = live(conn, ~p"/marketplace/my-themes")
    # The search box carries the Cmd/Ctrl+F shortcut hook, like every list page.
    assert html =~ ~s(data-shortcut="search")

    html = lv |> form(~s(form[phx-change="search"]), %{query: "keep"}) |> render_change()

    assert html =~ "Keeper"
    refute html =~ "Dropper"
  end

  test "a fruitless My themes search says so instead of offering onboarding", %{
    conn: conn,
    user: user
  } do
    _own = published(user, "Keeper")

    {:ok, lv, _html} = live(conn, ~p"/marketplace/my-themes")

    html =
      lv |> form(~s(form[phx-change="search"]), %{query: "nothing-matches"}) |> render_change()

    assert html =~ "Nothing here yet"
    assert html =~ "No themes match"
    refute html =~ "Upload a Liquid theme package"
  end

  test "the visibility dropdown narrows My themes to public or private", %{conn: conn, user: user} do
    _pub = published(user, "Out In The Open")

    {:ok, priv} =
      Themes.create_upload(%{
        slug: "priv#{System.unique_integer([:positive])}",
        name: "Kept Back",
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id
      })

    {:ok, lv, html} = live(conn, ~p"/marketplace/my-themes")
    assert html =~ "Out In The Open"
    assert html =~ priv.name

    html =
      lv |> form(~s(form[phx-change="visibility"]), %{visibility: "private"}) |> render_change()

    assert html =~ "Kept Back"
    refute html =~ "Out In The Open"

    html =
      lv |> form(~s(form[phx-change="visibility"]), %{visibility: "public"}) |> render_change()

    assert html =~ "Out In The Open"
    refute html =~ "Kept Back"

    html = lv |> form(~s(form[phx-change="visibility"]), %{visibility: "all"}) |> render_change()
    assert html =~ "Out In The Open"
    assert html =~ "Kept Back"
  end

  test "does not show your own themes", %{conn: conn, user: user} do
    _own = published(user, "My Own Theme")

    {:ok, _lv, html} = live(conn, ~p"/marketplace")
    refute html =~ "My Own Theme"
  end

  test "installing in a site's context adds it to that site", %{
    conn: conn,
    user: user,
    author: author
  } do
    site = site_for(user)
    theme = published(author, "Installable")

    {:ok, lv, html} = live(conn, ~p"/marketplace?#{[for: site.slug]}")
    assert html =~ "Install"
    # The context banner names the site.
    assert html =~ site.name

    html =
      lv
      |> element(~s(button[phx-click="install"][phx-value-id="#{theme.id}"]))
      |> render_click()

    assert html =~ "Installed"
    assert MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
  end

  test "without a site context, a card links to the theme's detail page", %{
    conn: conn,
    author: author
  } do
    theme = published(author, "Browseable")

    {:ok, _lv, html} = live(conn, ~p"/marketplace")

    assert html =~ ~s(href="/marketplace/themes/#{theme.id}")
  end

  test "a card carries the site install context into the detail page", %{
    conn: conn,
    user: user,
    author: author
  } do
    site = site_for(user)
    theme = published(author, "Contextual")

    {:ok, _lv, html} = live(conn, ~p"/marketplace?#{[for: site.slug]}")

    assert html =~ ~s(href="/marketplace/themes/#{theme.id}?for=#{site.slug}")
  end

  test "the My themes filter shows the user's library", %{conn: conn, user: user} do
    _own =
      elem(
        Themes.create_upload(%{
          slug: "own#{System.unique_integer([:positive])}",
          name: "My Own Theme",
          version: "1.0.0",
          storage_path: "themes/uploaded/1.0.0",
          owner_id: user.id
        }),
        1
      )

    {:ok, lv, _html} = live(conn, ~p"/marketplace")

    html = lv |> element(~s(a[href="/marketplace/my-themes"])) |> render_click()
    assert html =~ "Every theme you have"
    assert html =~ "My Own Theme"
  end

  test "the /marketplace/my-themes URL opens on the My themes filter", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/marketplace/my-themes")
    assert html =~ "Every theme you have"
    # The My themes filter chip is the active (primary) one.
    assert has_element?(lv, ~s(a.btn-primary[href="/marketplace/my-themes"]))
  end

  test "the site-context banner links back to the site's theme page", %{conn: conn, user: user} do
    site = site_for(user)

    {:ok, _lv, html} = live(conn, ~p"/marketplace?#{[for: site.slug]}")

    assert html =~ ~s(href="/#{site.slug}/theme")
  end

  test "a signed-out visitor browses the same gallery without the sidebar", %{author: author} do
    _theme = published(author, "Open To All")

    {:ok, _lv, html} = live(signed_out(), ~p"/marketplace")

    assert html =~ "Open To All"
    # No sidebar, no "My themes" filter, no upload button — just the catalogue.
    refute html =~ ~s(id="admin-sidebar")
    refute html =~ "My themes"
    refute html =~ "Upload theme"
    # It wears the homepage's nav and footer instead, with Marketplace marked
    # as the page you're on.
    assert html =~ "landing-nav"
    assert html =~ "landing-footer"
    assert html =~ ~s(href="/signup")
    assert html =~ ~s(aria-current="page")
  end

  test "a signed-out visitor is sent back to the marketplace from My themes" do
    assert {:error, {:live_redirect, %{to: "/marketplace"}}} =
             live(signed_out(), ~p"/marketplace/my-themes")
  end

  defp signed_out, do: build_conn() |> Plug.Test.init_test_session(%{})

  defp site_for(user) do
    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "mk#{System.unique_integer([:positive])}",
        "name" => "MK Site",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    site
  end

  describe "author filter" do
    test "?author= narrows the gallery and offers a way out", %{conn: conn, author: author} do
      other = register("other")
      _theirs = published(author, "Theirs One")
      _elsewhere = published(other, "Elsewhere One")

      {:ok, lv, html} = live(conn, ~p"/marketplace?#{[author: author.display_name]}")

      assert html =~ "Theirs One"
      refute html =~ "Elsewhere One"
      assert html =~ "By #{author.display_name}"

      # Clearing the chip patches back to the whole gallery.
      cleared = lv |> element(".author-chip") |> render_click()
      assert cleared =~ "Elsewhere One"
    end

    test "an unknown author shows an empty shelf, not everything", %{
      conn: conn,
      author: author
    } do
      _theirs = published(author, "Theirs One")

      {:ok, _lv, html} = live(conn, ~p"/marketplace?#{[author: "nobody-by-that-name"]}")

      refute html =~ "Theirs One"
      assert html =~ "hasn&#39;t published any themes here"
    end

    test "the theme page's author name links to their shelf", %{conn: conn, author: author} do
      theme = published(author, "Theirs One")

      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      {:ok, _lv, html} = lv |> element("a.author-name") |> render_click() |> follow_redirect(conn)

      assert html =~ "By #{author.display_name}"
      assert html =~ "Theirs One"
    end
  end
end

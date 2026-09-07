defmodule MastheadWeb.SiteUsersLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites}

  setup do
    Masthead.Themes.Seed.run()

    user = register("owner")

    {:ok, site} =
      Sites.create_site(
        %{"slug" => "su#{System.unique_integer([:positive])}", "name" => "SU Test"},
        user
      )

    {:ok, site} = Masthead.Licenses.grant(site)

    %{conn: login(build_conn(), user), site: site, user: user}
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp open_invite(lv) do
    lv |> element("button", "New user") |> render_click()
    lv
  end

  test "members view (default) lists members in a table", %{conn: conn, site: site, user: user} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/users")
    assert html =~ user.email
    assert html =~ "You"
    assert html =~ "Members (1)"
    assert html =~ "Invitations (0)"
  end

  test "inviting an existing user adds them immediately", %{conn: conn, site: site} do
    other = register("other")
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    open_invite(lv)

    html =
      lv
      |> form("#invite-user-form", %{"email" => other.email})
      |> render_submit()

    assert html =~ "was added"
    assert html =~ other.email
    assert Sites.member?(site.id, other.id)
  end

  test "inviting a new email creates a pending invitation and switches to that view",
       %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    open_invite(lv)

    html =
      lv
      |> form("#invite-user-form", %{"email" => "fresh@example.com"})
      |> render_submit()

    assert html =~ "Invitation sent"
    assert html =~ "fresh@example.com"
    assert html =~ "Invited"
    assert [_] = Sites.list_invitations(site)
  end

  test "the invitations view lists pending invitations", %{conn: conn, site: site} do
    {:ok, :invited} = Sites.invite_to_site(site, "fresh@example.com", fn t -> "u/#{t}" end)

    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/users?view=invitations")
    assert html =~ "fresh@example.com"
    assert html =~ "Invitations (1)"
  end

  test "search filters the member table by email", %{conn: conn, site: site} do
    other = register("needle")
    {:ok, _} = Sites.add_member(site, other)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    html =
      lv
      |> form(".admin-search", %{"query" => "needle"})
      |> render_change()

    assert html =~ other.email
    refute html =~ "No people match"
  end

  test "the last member's remove button is disabled", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/users")
    assert html =~ ~r/disabled/
    assert Sites.count_members(site.id) == 1
  end

  test "removing another member works", %{conn: conn, site: site} do
    other = register("other")
    {:ok, _} = Sites.add_member(site, other)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    lv
    |> element("button[phx-value-id='#{other.id}']", "Remove")
    |> render_click()

    refute Sites.member?(site.id, other.id)
  end

  test "leaving the site (removing self) redirects to /sites", %{
    conn: conn,
    site: site,
    user: user
  } do
    other = register("other")
    {:ok, _} = Sites.add_member(site, other)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    assert {:error, {:live_redirect, %{to: "/sites"}}} =
             lv
             |> element("button[phx-value-id='#{user.id}']", "Remove")
             |> render_click()

    refute Sites.member?(site.id, user.id)
  end

  test "cancelling a pending invitation removes it", %{conn: conn, site: site} do
    {:ok, :invited} = Sites.invite_to_site(site, "fresh@example.com", fn t -> "u/#{t}" end)
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users?view=invitations")

    lv |> element("button", "Cancel") |> render_click()

    assert Sites.list_invitations(site) == []
  end

  test "a non-member cannot reach the users page", %{site: site} do
    stranger = register("stranger")
    conn = login(build_conn(), stranger)

    assert {:error, {:redirect, %{to: "/sites"}}} = live(conn, ~p"/#{site.slug}/users")
  end

  test "inviting on a free site opens the upgrade modal instead", %{conn: conn, site: site} do
    {:ok, free} =
      site
      |> Ecto.Changeset.change(license_status: nil, license_expires_at: nil)
      |> Masthead.Repo.update()

    {:ok, lv, _html} = live(conn, ~p"/#{free.slug}/users")

    html = lv |> element(~s(button[phx-click="open_upgrade"])) |> render_click()

    assert html =~ "Upgrade to use this functionality"
    assert html =~ "Inviting collaborators needs a paid license"
    refute has_element?(lv, "#invite-user-form")
  end

  test "a licensed site still opens the invite form", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/users")

    lv |> element(~s(button[phx-click="open_modal"]), "New user") |> render_click()

    assert has_element?(lv, "#invite-user-form")
    refute has_element?(lv, ".dialog", "Upgrade to use this functionality")
  end
end

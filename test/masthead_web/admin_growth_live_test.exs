defmodule MastheadWeb.AdminGrowthLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Masthead.Accounts
  alias Masthead.Accounts.User
  alias Masthead.Repo

  setup do
    Masthead.Themes.Seed.run()

    {:ok, admin} =
      Accounts.register_user(%{"email" => email("admin"), "password" => "password1234"})

    {:ok, admin} = Accounts.set_admin(admin, true)

    {:ok, recent} =
      Accounts.register_user(%{"email" => email("recent"), "password" => "password1234"})

    {:ok, old} = Accounts.register_user(%{"email" => email("old"), "password" => "password1234"})

    forty_days_ago = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.truncate(:second)
    Repo.update_all(from(u in User, where: u.id == ^old.id), set: [inserted_at: forty_days_ago])

    %{admin: admin, recent: recent, old: old, conn: conn_for(admin)}
  end

  defp email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp conn_for(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "non-admins are redirected away from /admin/growth", %{recent: recent} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn_for(recent), ~p"/admin/growth")
  end

  test "the range moves the cards and survives switching tabs", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/growth")

    assert has_element?(lv, "#card-users .growth-num", "1")
    assert has_element?(lv, "#card-users .growth-sub", "2 all time")

    lv |> element("#growth-range a", "90 days") |> render_click()
    assert_patch(lv, ~p"/admin/growth/overview?#{[range: 90, window: 14]}")
    assert has_element?(lv, "#card-users .growth-num", "2")

    lv |> element("#growth-tab-acquisition") |> render_click()
    assert_patch(lv, ~p"/admin/growth/acquisition?#{[range: 90, window: 14]}")
    assert has_element?(lv, "#growth-acquisition tr", "Unknown")
    refute has_element?(lv, "#card-users")
  end

  test "a figure opens the accounts behind it, linked to the users tab",
       %{conn: conn, recent: recent, old: old} do
    {:ok, lv, _html} = live(conn, ~p"/admin/growth?range=all")

    lv |> element("#card-users button") |> render_click()

    assert has_element?(lv, "#growth-drill", "2 accounts")
    assert has_element?(lv, "#drill-user-#{recent.id} a", recent.email)
    assert has_element?(lv, "#drill-user-#{old.id}")

    lv |> element("#growth-drill button[phx-click=close_drill]") |> render_click()
    refute has_element?(lv, "#growth-drill")
  end

  test "the users tab reads the drill-down's search param", %{
    conn: conn,
    recent: recent,
    old: old
  } do
    {:ok, _lv, html} = live(conn, ~p"/admin/users/all?#{[search: recent.email]}")

    assert html =~ recent.email
    refute html =~ old.email
  end
end

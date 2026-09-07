defmodule MastheadWeb.AccountLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.Accounts
  alias Masthead.Repo

  defp new_user(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "acct-#{System.unique_integer([:positive])}@example.com",
            "password" => "password1234"
          },
          attrs
        )
      )

    user
  end

  defp log_in(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  setup do
    user = new_user()
    %{conn: log_in(user), user: user}
  end

  test "shows the profile and hides the password dialog until asked", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/account")

    assert html =~ user.display_name
    assert html =~ user.email
    refute html =~ "Current password"

    assert lv |> element(~s(button[phx-click="open_password"])) |> render_click() =~
             "Current password"
  end

  describe "display name" do
    test "registration derives it from the email, uniquely" do
      taken = new_user(%{"email" => "picard-#{System.unique_integer([:positive])}@example.com"})
      twin = new_user(%{"email" => "#{taken.display_name}@elsewhere.example"})

      assert taken.display_name =~ ~r/^picard-\d+$/
      assert twin.display_name == "#{taken.display_name}1"
    end

    test "is edited in place", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element(~s(button[phx-click="edit_name"])) |> render_click()

      html =
        lv
        |> form(".profile-name-form", %{"user" => %{"display_name" => "  Jean-Luc  "}})
        |> render_submit()

      assert html =~ "Jean-Luc"
      assert Repo.reload(user).display_name == "Jean-Luc"
    end

    test "survives being cleared", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element(~s(button[phx-click="edit_name"])) |> render_click()

      html =
        lv
        |> form(".profile-name-form", %{"user" => %{"display_name" => "  "}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Repo.reload(user).display_name == user.display_name
    end

    test "refuses a name another account already uses", %{conn: conn, user: user} do
      other = new_user()
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element(~s(button[phx-click="edit_name"])) |> render_click()

      html =
        lv
        |> form(".profile-name-form", %{"user" => %{"display_name" => other.display_name}})
        |> render_submit()

      assert html =~ "has already been taken"
      assert Repo.reload(user).display_name == user.display_name
    end
  end

  describe "profile picture" do
    test "uploads and replaces the initial", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/account")
      refute html =~ "avatar-image"

      input =
        file_input(lv, "#avatar-upload", :avatar, [
          %{
            name: "me.png",
            content: File.read!("test/support/fixtures/pixel.png"),
            type: "image/png"
          }
        ])

      assert render_upload(input, "me.png") =~ "avatar-image"

      reloaded = Repo.reload(user)
      assert reloaded.avatar_path
      assert Accounts.avatar_url(reloaded) =~ "avatars"
    end
  end

  describe "password dialog" do
    test "updates with the correct current password", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/account")
      lv |> element(~s(button[phx-click="open_password"])) |> render_click()

      lv
      |> form("#password-form", %{
        "current_password" => "password1234",
        "user" => %{"password" => "freshpass987"}
      })
      |> render_submit()

      assert Accounts.get_user_by_email_and_password(user.email, "freshpass987")
      refute render(lv) =~ "Current password"
    end

    test "keeps the dialog open on a wrong current password", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/account")
      lv |> element(~s(button[phx-click="open_password"])) |> render_click()

      html =
        lv
        |> form("#password-form", %{
          "current_password" => "wrongwrong",
          "user" => %{"password" => "freshpass987"}
        })
        |> render_submit()

      assert html =~ "Current password is incorrect"
      refute Accounts.get_user_by_email_and_password(user.email, "freshpass987")
    end
  end
end

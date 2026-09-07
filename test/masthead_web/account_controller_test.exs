defmodule MastheadWeb.AccountControllerTest do
  use MastheadWeb.ConnCase

  alias Masthead.Accounts
  alias Masthead.Accounts.User
  alias Masthead.Repo

  defp new_user(attrs \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        Map.merge(
          %{
            "email" => "acc-#{System.unique_integer([:positive])}@example.com",
            "password" => "password1234"
          },
          attrs
        )
      )

    user
  end

  defp log_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "GET /account requires auth", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/account")) == ~p"/login"
  end

  test "GET /account shows the account page", %{conn: conn} do
    user = new_user()
    conn = conn |> log_in(user) |> get(~p"/account")
    assert html_response(conn, 200) =~ "Account"
    assert html_response(conn, 200) =~ user.email
  end

  describe "POST /account/password" do
    test "updates with correct current password", %{conn: conn} do
      user = new_user()

      conn =
        conn
        |> log_in(user)
        |> post(~p"/account/password", %{
          "current_password" => "password1234",
          "user" => %{"password" => "freshpass987"}
        })

      assert redirected_to(conn) == ~p"/account"
      assert Accounts.get_user_by_email_and_password(user.email, "freshpass987")
    end

    test "rejects a wrong current password", %{conn: conn} do
      user = new_user()

      conn =
        conn
        |> log_in(user)
        |> post(~p"/account/password", %{
          "current_password" => "wrongwrong",
          "user" => %{"password" => "freshpass987"}
        })

      assert html_response(conn, 422) =~ "Current password is incorrect"
      refute Accounts.get_user_by_email_and_password(user.email, "freshpass987")
    end
  end

  describe "POST /account/disable" do
    test "disables, logs out, and blocks re-login", %{conn: conn} do
      user = new_user()

      conn = conn |> log_in(user) |> post(~p"/account/disable")
      assert redirected_to(conn) == ~p"/login"
      refute get_session(conn, :user_id)
      assert User.disabled?(Repo.reload(user))

      # cannot sign back in
      login =
        post(build_conn(), ~p"/login", %{
          "user" => %{"email" => user.email, "password" => "password1234"}
        })

      assert html_response(login, 401) =~ "disabled"
    end
  end

  test "a disabled user's live session is treated as logged out", %{conn: conn} do
    user = new_user()
    {:ok, _} = Accounts.disable_user(user)

    conn = conn |> log_in(user) |> get(~p"/sites")
    assert redirected_to(conn) == ~p"/login"
  end

  describe "POST /account/profile" do
    test "registration derives the display name from the email, uniquely", %{conn: _conn} do
      taken = new_user(%{"email" => "picard-#{System.unique_integer([:positive])}@example.com"})
      twin = new_user(%{"email" => "#{taken.display_name}@elsewhere.example"})

      assert taken.display_name =~ ~r/^picard-\d+$/
      assert twin.display_name == "#{taken.display_name}1"
    end

    test "changes the display name", %{conn: conn} do
      user = new_user()

      conn =
        conn
        |> log_in(user)
        |> post(~p"/account/profile", %{"user" => %{"display_name" => "  Jean-Luc  "}})

      assert redirected_to(conn) == ~p"/account"
      assert Repo.reload(user).display_name == "Jean-Luc"
    end

    test "refuses a display name another account already uses", %{conn: conn} do
      other = new_user()
      user = new_user()

      conn =
        conn
        |> log_in(user)
        |> post(~p"/account/profile", %{"user" => %{"display_name" => other.display_name}})

      assert html_response(conn, 422) =~ "has already been taken"
      assert Repo.reload(user).display_name == user.display_name
    end

    test "stores an uploaded profile picture and shows it", %{conn: conn} do
      user = new_user()

      conn =
        conn |> log_in(user) |> post(~p"/account/profile", profile_params(user, "avatar.png"))

      assert redirected_to(conn) == ~p"/account"
      reloaded = Repo.reload(user)
      assert reloaded.avatar_path
      assert Accounts.avatar_url(reloaded) =~ "avatar"
    end

    test "refuses a file that isn't an image", %{conn: conn} do
      user = new_user()

      conn =
        conn |> log_in(user) |> post(~p"/account/profile", profile_params(user, "resume.pdf"))

      assert html_response(conn, 422) =~ "isn&#39;t an image"
      refute Repo.reload(user).avatar_path
    end
  end

  defp profile_params(user, filename) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, "not really an image, but bytes all the same")

    %{
      "user" => %{"display_name" => user.display_name},
      "avatar" => %Plug.Upload{
        filename: filename,
        path: path,
        content_type: "application/octet-stream"
      }
    }
  end
end

defmodule MastheadWeb.InvitationControllerTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Sites}
  alias Masthead.Accounts.User

  setup do
    Masthead.Themes.Seed.run()

    {:ok, inviter} =
      Accounts.register_user(%{
        "email" => "inv-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(
        %{"slug" => "iv#{System.unique_integer([:positive])}", "name" => "Invite Test"},
        inviter
      )

    {:ok, site} = Masthead.Licenses.grant(site)

    %{site: site}
  end

  # Invite an unregistered email and return the raw token from the emailed link.
  defp invite(site, email) do
    test_pid = self()

    Sites.invite_to_site(site, email, fn token ->
      send(test_pid, {:token, token})
      "url/#{token}"
    end)

    assert_received {:token, token}
    token
  end

  describe "GET /invite/:token" do
    test "renders a locked-email signup form for a new invitee", %{conn: conn, site: site} do
      token = invite(site, "newbie@example.com")

      conn = get(conn, ~p"/invite/#{token}")
      html = html_response(conn, 200)

      assert html =~ "Join #{site.name}"
      assert html =~ "newbie@example.com"
      assert html =~ "readonly"
    end

    test "invalid token redirects to signup", %{conn: conn} do
      conn = get(conn, ~p"/invite/bogus")
      assert redirected_to(conn) == ~p"/signup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"
    end
  end

  describe "POST /invite/:token" do
    test "creates an auto-confirmed account, joins the site, and logs in", %{
      conn: conn,
      site: site
    } do
      token = invite(site, "joiner@example.com")

      conn =
        post(conn, ~p"/invite/#{token}", %{
          "user" => %{"password" => "password1234"}
        })

      assert redirected_to(conn) == ~p"/#{site.slug}"
      assert get_session(conn, :user_id)

      user = Accounts.get_user_by_email("joiner@example.com")
      assert User.confirmed?(user)
      assert Sites.member?(site.id, user.id)
      # Invitation consumed.
      assert Sites.list_invitations(site) == []
    end

    test "ignores a tampered email field and uses the invited address", %{conn: conn, site: site} do
      token = invite(site, "real@example.com")

      post(conn, ~p"/invite/#{token}", %{
        "user" => %{"email" => "attacker@example.com", "password" => "password1234"}
      })

      assert Accounts.get_user_by_email("real@example.com")
      refute Accounts.get_user_by_email("attacker@example.com")
    end

    test "invalid token redirects to signup", %{conn: conn} do
      conn =
        post(conn, ~p"/invite/bogus", %{"user" => %{"password" => "password1234"}})

      assert redirected_to(conn) == ~p"/signup"
    end
  end

  describe "invited email registers separately before clicking the link" do
    test "GET adds the now-existing user and redirects to login", %{conn: conn, site: site} do
      email = "later-#{System.unique_integer([:positive])}@example.com"
      # Invitation created while the email had no account.
      token = invite(site, email)

      # The invitee signs up through the normal flow before clicking the link.
      {:ok, existing} =
        Accounts.register_user(%{"email" => email, "password" => "password1234"})

      conn = get(conn, ~p"/invite/#{token}")
      assert redirected_to(conn) == ~p"/login"
      assert Sites.member?(site.id, existing.id)
    end
  end
end

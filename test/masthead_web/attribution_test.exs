defmodule MastheadWeb.AttributionTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Sites}

  @cookie "_mh_attr"

  defp register(prefix, attribution \\ %{}) do
    {:ok, user} =
      Accounts.register_user(
        %{
          "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
          "password" => "password1234"
        },
        attribution
      )

    user
  end

  describe "cookie capture" do
    test "stores first-touch fields only, never the gclid value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://News.Example.org/some/article?x=1")
        |> get(~p"/pricing", %{
          "utm_source" => "Newsletter",
          "utm_medium" => "  ",
          "utm_campaign" => String.duplicate("c", 150),
          "gclid" => "secret-click-id"
        })

      assert %{max_age: 2_592_000, same_site: "Lax", http_only: true, value: signed} =
               conn.resp_cookies[@cookie]

      refute signed =~ "secret-click-id"

      attr = conn.cookies[@cookie]
      assert attr.utm_source == "Newsletter"
      refute Map.has_key?(attr, :utm_medium)
      assert attr.utm_campaign == String.duplicate("c", 100)
      assert attr.gclid_present == true
      assert attr.landing_path == "/pricing"
      assert attr.referrer_domain == "news.example.org"
      assert {:ok, _, 0} = DateTime.from_iso8601(attr.first_seen_at)
      refute "secret-click-id" in Map.values(attr)
    end

    test "ignores a referrer from the app's own host", %{conn: conn} do
      for referer <- ["http://www.example.com/signup", "https://lvh.me/"] do
        conn = conn |> put_req_header("referer", referer) |> get(~p"/pricing")
        refute Map.has_key?(conn.cookies[@cookie], :referrer_domain)
      end
    end

    test "never overwrites an existing cookie", %{conn: conn} do
      conn = get(conn, ~p"/pricing", %{"utm_source" => "first"})
      assert conn.resp_cookies[@cookie]

      conn = get(conn, ~p"/", %{"utm_source" => "second"})
      refute conn.resp_cookies[@cookie]
      assert conn.cookies[@cookie].utm_source == "first"
    end

    test "is not set for a logged-in user", %{conn: conn} do
      user = register("attr-in")

      conn =
        conn
        |> Plug.Test.init_test_session(%{user_id: user.id})
        |> get(~p"/pricing", %{"utm_source" => "x"})

      refute conn.resp_cookies[@cookie]
    end
  end

  describe "signup" do
    test "email signup copies the cookie onto the user and deletes it", %{conn: conn} do
      conn = get(conn, ~p"/pricing", %{"utm_source" => "newsletter", "gclid" => "g"})
      email = "attr-signup-#{System.unique_integer([:positive])}@example.com"

      conn =
        post(conn, ~p"/signup", %{"user" => %{"email" => email, "password" => "password1234"}})

      assert conn.resp_cookies[@cookie].max_age == 0

      user = Accounts.get_user_by_email(email)
      assert user.signup_method == "email"
      assert user.utm_source == "newsletter"
      assert user.gclid_present
      assert user.landing_path == "/pricing"
      assert %DateTime{} = user.first_seen_at
    end

    test "invited signup is marked invite and keeps attribution", %{conn: conn} do
      Masthead.Themes.Seed.run()
      inviter = register("attr-inviter")

      {:ok, site} =
        Sites.create_site(
          %{"slug" => "ai#{System.unique_integer([:positive])}", "name" => "Attr"},
          inviter
        )

      {:ok, site} = Masthead.Licenses.grant(site)
      test_pid = self()
      email = "attr-invitee-#{System.unique_integer([:positive])}@example.com"

      Sites.invite_to_site(site, email, fn token ->
        send(test_pid, {:token, token})
        "url/#{token}"
      end)

      assert_received {:token, token}

      conn = get(conn, ~p"/pricing", %{"utm_source" => "partner"})
      conn = post(conn, ~p"/invite/#{token}", %{"user" => %{"password" => "password1234"}})

      assert conn.resp_cookies[@cookie].max_age == 0
      user = Accounts.get_user_by_email(email)
      assert user.signup_method == "invite"
      assert user.utm_source == "partner"
    end

    test "no cookie leaves attribution empty (channel Unknown)" do
      user = register("attr-none")
      assert user.signup_method == "email"
      assert user.first_seen_at == nil
      assert user.utm_source == nil
    end

    test "OAuth creation stores the provider; later logins change nothing" do
      email = "attr-oauth-#{System.unique_integer([:positive])}@example.com"
      info = %{provider: :github, uid: "gh-#{email}", email: email, email_verified: true}
      first_seen = ~U[2026-10-01 08:00:00Z]

      assert {:ok, user} =
               Accounts.get_or_create_user_from_oauth(info,
                 attribution: %{utm_source: "hn", first_seen_at: first_seen}
               )

      assert user.signup_method == "github"
      assert user.utm_source == "hn"
      assert user.first_seen_at == first_seen

      assert {:ok, again} =
               Accounts.get_or_create_user_from_oauth(info, attribution: %{utm_source: "other"})

      again = Masthead.Repo.reload!(again)
      assert again.id == user.id
      assert again.signup_method == "github"
      assert again.utm_source == "hn"
    end

    test "OAuth linking to an existing email account keeps its signup method" do
      existing = register("attr-link")

      assert {:ok, user} =
               Accounts.get_or_create_user_from_oauth(
                 %{provider: :google, uid: "g-link", email: existing.email, email_verified: true},
                 attribution: %{utm_source: "x"}
               )

      user = Masthead.Repo.reload!(user)
      assert user.signup_method == "email"
      assert user.utm_source == nil
    end
  end
end

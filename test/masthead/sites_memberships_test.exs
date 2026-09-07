defmodule Masthead.SitesMembershipsTest do
  use Masthead.DataCase
  use Oban.Testing, repo: Masthead.Repo

  alias Masthead.{Accounts, Sites}
  alias Masthead.Accounts.User
  alias Masthead.Sites.SiteInvitation
  alias Masthead.Workers.Email

  setup do
    Masthead.Themes.Seed.run()
    %{user: user("a")}
  end

  defp user(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp verified_user(prefix) do
    user = user(prefix)
    {:ok, user} = Accounts.confirm_user(Accounts.generate_email_token(user, "confirm"))
    user
  end

  defp site_for(user) do
    {:ok, site} =
      Sites.create_site(
        %{"slug" => "m#{System.unique_integer([:positive])}", "name" => "Membership Test"},
        user
      )

    {:ok, site} = Masthead.Licenses.grant(site)
    site
  end

  defp url_fun, do: fn token -> "https://example.test/invite/#{token}" end

  describe "create_site/2" do
    test "creates the site with the creating user as its sole member", %{user: user} do
      site = site_for(user)

      assert Sites.member?(site.id, user.id)
      assert Sites.count_members(site.id) == 1
      assert [%User{id: id}] = Sites.list_members(site)
      assert id == user.id
    end
  end

  describe "add_member / remove_member" do
    test "adds and removes a second member", %{user: user} do
      site = site_for(user)
      other = user("b")

      assert {:ok, _} = Sites.add_member(site, other)
      assert Sites.count_members(site.id) == 2

      assert :ok = Sites.remove_member(site, other)
      refute Sites.member?(site.id, other.id)
    end

    test "add_member is idempotent", %{user: user} do
      site = site_for(user)
      other = user("b")

      assert {:ok, _} = Sites.add_member(site, other)
      assert {:ok, _} = Sites.add_member(site, other)
      assert Sites.count_members(site.id) == 2
    end

    test "refuses to remove the last member", %{user: user} do
      site = site_for(user)
      assert {:error, :last_member} = Sites.remove_member(site, user)
      assert Sites.member?(site.id, user.id)
    end

    test "a member can remove themselves when others remain", %{user: user} do
      site = site_for(user)
      other = user("b")
      {:ok, _} = Sites.add_member(site, other)

      assert :ok = Sites.remove_member(site, user)
      refute Sites.member?(site.id, user.id)
      assert Sites.member?(site.id, other.id)
    end
  end

  describe "invite_to_site/3" do
    test "adds an existing user immediately and emails them", %{user: user} do
      site = site_for(user)
      existing = user("b")

      assert {:ok, :added} = Sites.invite_to_site(site, existing.email, url_fun())
      assert Sites.member?(site.id, existing.id)
      assert [%{args: %{"to" => to, "subject" => subject}}] = all_enqueued(worker: Email)
      assert to == existing.email
      assert subject =~ "added"
    end

    test "creates an invitation for an unregistered email and emails a signup link", %{user: user} do
      site = site_for(user)

      assert {:ok, :invited} = Sites.invite_to_site(site, "new@example.com", url_fun())
      assert [%SiteInvitation{email: "new@example.com"}] = Sites.list_invitations(site)

      assert [%{args: %{"to" => "new@example.com", "subject" => subject}}] =
               all_enqueued(worker: Email)

      assert subject =~ "invited"
    end

    test "normalizes the email and rejects an already-member", %{user: user} do
      site = site_for(user)
      existing = user("b")
      {:ok, :added} = Sites.invite_to_site(site, existing.email, url_fun())

      assert {:error, :already_member} =
               Sites.invite_to_site(site, String.upcase(existing.email), url_fun())
    end

    test "rejects a malformed email", %{user: user} do
      site = site_for(user)
      assert {:error, :invalid_email} = Sites.invite_to_site(site, "not-an-email", url_fun())
    end

    test "re-inviting the same unregistered email replaces the invitation", %{user: user} do
      site = site_for(user)
      {:ok, :invited} = Sites.invite_to_site(site, "new@example.com", url_fun())
      {:ok, :invited} = Sites.invite_to_site(site, "new@example.com", url_fun())

      assert [_only_one] = Sites.list_invitations(site)
    end
  end

  describe "invitation acceptance" do
    test "get_invitation_by_token resolves a valid token and accept creates the membership",
         %{user: user} do
      site = site_for(user)
      # Capture the raw token from the URL the notifier is handed.
      test_pid = self()

      Sites.invite_to_site(site, "new@example.com", fn token ->
        send(test_pid, {:token, token})
        "https://example.test/invite/#{token}"
      end)

      assert_received {:token, raw_token}

      assert %SiteInvitation{email: "new@example.com"} =
               invitation = Sites.get_invitation_by_token(raw_token)

      joined = user("b")
      assert {:ok, site_id} = Sites.accept_invitation(invitation, joined)
      assert site_id == site.id
      assert Sites.member?(site.id, joined.id)
      # Invitation consumed.
      assert Sites.list_invitations(site) == []
    end

    test "get_invitation_by_token returns nil for an unknown token" do
      assert Sites.get_invitation_by_token("bogus") == nil
    end
  end

  describe "verified-member availability cascade" do
    test "disabling a verified owner takes down a site with no other verified member" do
      owner = verified_user("owner")
      solo = site_for(owner)
      shared = site_for(owner)
      {:ok, _} = Sites.add_member(shared, verified_user("b"))

      {:ok, _} = Accounts.disable_user(owner)

      # Solo site: lost its only verified member -> offline.
      refute Sites.get_site_by_slug(solo.slug)
      # Shared site: another verified member remains -> stays online.
      assert Sites.get_site_by_slug(shared.slug)
    end

    test "disabling an unverified user never takes a site offline", %{user: unverified} do
      site = site_for(unverified)

      {:ok, _} = Accounts.disable_user(unverified)

      assert Sites.get_site_by_slug(site.slug)
    end
  end
end

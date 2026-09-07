defmodule MastheadWeb.RealtimeLiveTest do
  @moduledoc """
  End-to-end tests for the live admin: two clients on the same site, mutate
  through one path, assert the other re-renders. Non-async so the SQL sandbox
  is shared across the LiveView processes.
  """
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Masthead.{Accounts, Content, Sites}

  setup do
    Masthead.Themes.Seed.run()

    a = register("a")
    {:ok, site} = Sites.create_site(%{"slug" => "rt#{uniq()}", "name" => "RT Site"}, a)
    {:ok, site} = Masthead.Licenses.grant(site)
    b = register("b")
    {:ok, _} = Sites.add_member(site, b)

    %{site: site, a: a, b: b, conn_a: login(build_conn(), a), conn_b: login(build_conn(), b)}
  end

  defp uniq, do: System.unique_integer([:positive])

  # Push a post's updated_at a minute into the past (second-precision), so a
  # subsequent edit produces a strictly newer timestamp.
  defp backdate(post) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    Masthead.Repo.update_all(
      from(p in Masthead.Content.Post, where: p.id == ^post.id),
      set: [updated_at: past]
    )
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{uniq()}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp login(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  describe "content" do
    test "a post created elsewhere appears in the posts index live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/posts")
      refute render(lv) =~ "Breaking News"

      {:ok, _} = Content.create_post(site.id, %{"title" => "Breaking News"})

      assert render(lv) =~ "Breaking News"
    end

    test "a publish toggle elsewhere updates the status pill live", %{conn_b: conn, site: site} do
      {:ok, post} = Content.create_post(site.id, %{"title" => "Toggle Me"})
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/posts")
      # Match the pill, not the bare word — "Draft" and "Published" are also
      # filter-button labels in the toolbar.
      assert render(lv) =~ "pill pill-draft"

      {:ok, _} = Content.update_post(post, %{"published" => "true"})

      html = render(lv)
      assert html =~ "pill pill-live"
      refute html =~ "pill pill-draft"
    end

    test "a page created elsewhere appears in the pages index live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/pages")
      {:ok, _} = Content.create_page(site.id, %{"title" => "About Us", "format" => "markdown"})

      assert render(lv) =~ "About Us"
    end

    test "the dashboard post count updates live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}")
      {:ok, _} = Content.create_post(site.id, %{"title" => "Dash Post"})

      assert render(lv) =~ "Dash Post"
    end
  end

  describe "members" do
    test "a member added elsewhere appears in the users tab live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/users")
      c = register("c")

      {:ok, _} = Sites.add_member(site, c)

      assert render(lv) =~ c.email
    end

    test "an invitation created elsewhere appears live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/users?view=invitations")
      {:ok, :invited} = Sites.invite_to_site(site, "invitee@example.com", fn t -> "u/#{t}" end)

      assert render(lv) =~ "invitee@example.com"
    end
  end

  describe "settings" do
    test "a tag created elsewhere appears on the settings page live", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/settings")
      {:ok, _} = Content.create_tag(site.id, %{"name" => "Featured"})

      assert render(lv) =~ "Featured"
    end
  end

  describe "todo badge" do
    test "the sidebar badge updates on an unrelated page when a todo changes",
         %{conn_b: conn, site: site} do
      # A freshly seeded site has 3 pending onboarding actions.
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/users")
      assert has_element?(lv, "#checklist-badge", "3")

      :ok = Masthead.Actions.dismiss_action(site, "import_site")

      assert has_element?(lv, "#checklist-badge", "2")
    end
  end

  describe "access revoked" do
    test "a removed member is redirected off the site", %{conn_b: conn, site: site, b: b} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/posts")

      :ok = Sites.remove_member(site, b)

      assert_redirect(lv, "/sites")
    end

    test "everyone viewing a soft-deleted site is redirected", %{conn_b: conn, site: site} do
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}")

      {:ok, _} = Sites.soft_delete_site(site)

      assert_redirect(lv, "/sites")
    end
  end

  describe "editor banner" do
    test "an external update shows the banner in an open editor", %{conn_b: conn, site: site} do
      {:ok, post} = Content.create_post(site.id, %{"title" => "Shared Draft"})
      # Backdate so the external edit lands on a strictly newer second — the
      # self-filter compares updated_at, which is second-precision.
      backdate(post)
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/posts/#{post.id}/edit")
      refute render(lv) =~ "Someone else changed"

      {:ok, _} = Content.update_post(post, %{"title" => "Edited by A"})

      assert render(lv) =~ "Someone else changed"
    end

    test "an external delete shows the banner in an open editor", %{conn_b: conn, site: site} do
      {:ok, post} = Content.create_post(site.id, %{"title" => "Doomed Draft"})
      {:ok, lv, _} = live(conn, ~p"/#{site.slug}/posts/#{post.id}/edit")

      {:ok, _} = Content.delete_post(post)

      assert render(lv) =~ "Someone else deleted"
    end
  end

  describe "presence" do
    test "a member sees another member who is viewing the same site",
         %{conn_a: conn_a, conn_b: conn_b, site: site, b: b} do
      {:ok, lv_a, _} = live(conn_a, ~p"/#{site.slug}")
      refute render(lv_a) =~ "presence-cluster"

      {:ok, _lv_b, _} = live(conn_b, ~p"/#{site.slug}")

      html = render(lv_a)
      assert html =~ "presence-cluster"
      # b is named in the avatar's hover popover
      assert html =~ b.display_name
    end
  end
end

defmodule MastheadWeb.SiteSettingsLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Content, Sites, Themes}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ss-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "ss#{System.unique_integer([:positive])}",
        "name" => "SS Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  test "the settings page no longer carries the theme controls", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/settings")

    # Theme selection/customization now lives on its own /theme page.
    refute html =~ "theme-picker"
    refute html =~ ~s(name="site[theme_id]")
    assert html =~ "Identity"
    assert html =~ "Custom domain"
  end

  test "identity fields can be edited and saved", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

    lv
    |> form("#site-settings-form", site: %{name: "Renamed", description: "A fresh tagline."})
    |> render_submit()

    site = Sites.get_site!(site.id)
    assert site.name == "Renamed"
    assert site.description == "A fresh tagline."
  end

  test "the owner can soft-delete their site from the danger zone", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

    lv |> element("button", "Delete site") |> render_click()

    assert_redirect(lv, ~p"/sites")

    # The row is retained (soft delete) but hidden from the owner's list and
    # no longer resolvable as their site.
    assert Sites.get_site!(site.id).deleted_at != nil
    assert Sites.list_sites_for_user(hd(Sites.list_members(site)).id) == []
  end

  test "the settings page links to the Hugo import page", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/settings")

    assert html =~ "Import site"
    assert html =~ ~p"/#{site.slug}/import"
  end

  describe "tag management" do
    test "creating a tag via the modal", %{conn: conn, site: site} do
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/settings")
      assert html =~ "Tags"
      assert html =~ "No tags yet."

      # The modal opens on demand.
      refute has_element?(lv, ".dialog")
      lv |> element(~s(button[phx-click="new_tag"])) |> render_click()
      assert has_element?(lv, ".dialog")

      html =
        lv
        |> form(~s(.dialog-form), tag: %{name: "Announcements"})
        |> render_submit()

      refute html =~ "No tags yet."
      [tag] = Content.list_tags(site.id)
      assert tag.name == "Announcements"
      assert tag.slug == "announcements"
    end

    test "the slug keeps tracking the name across keystrokes", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
      lv |> element(~s(button[phx-click="new_tag"])) |> render_click()

      # Simulate typing the name one keystroke at a time, with the slug input
      # echoing its derived value back each time (as the browser would).
      lv
      |> element(~s(.dialog-form))
      |> render_change(%{"_target" => ["tag", "name"], "tag" => %{"name" => "N", "slug" => ""}})

      html =
        lv
        |> element(~s(.dialog-form))
        |> render_change(%{
          "_target" => ["tag", "name"],
          "tag" => %{"name" => "News", "slug" => "n"}
        })

      assert html =~ ~s(value="news")
    end

    test "an explicitly edited slug is preserved", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
      lv |> element(~s(button[phx-click="new_tag"])) |> render_click()

      # User edits the slug directly, then changes the name — slug stays put.
      lv
      |> element(~s(.dialog-form))
      |> render_change(%{
        "_target" => ["tag", "slug"],
        "tag" => %{"name" => "", "slug" => "custom"}
      })

      html =
        lv
        |> element(~s(.dialog-form))
        |> render_change(%{
          "_target" => ["tag", "name"],
          "tag" => %{"name" => "News", "slug" => "custom"}
        })

      assert html =~ ~s(value="custom")
    end

    test "validating a new tag does not complain about site_id", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
      lv |> element(~s(button[phx-click="new_tag"])) |> render_click()

      html = lv |> form(~s(.dialog-form), tag: %{name: "News"}) |> render_change()
      refute html =~ "site_id"
    end

    test "an invalid tag keeps the modal open with an error", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
      lv |> element(~s(button[phx-click="new_tag"])) |> render_click()

      html =
        lv
        |> form(~s(.dialog-form), tag: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert has_element?(lv, ".dialog")
      assert Content.list_tags(site.id) == []
    end

    test "deleting a tag", %{conn: conn, site: site} do
      {:ok, tag} = Content.create_tag(site.id, %{"name" => "Temp"})
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

      lv
      |> element(~s(button.tag-chip-remove[phx-value-id="#{tag.id}"]))
      |> render_click()

      assert Content.list_tags(site.id) == []
    end
  end

  describe "license" do
    setup do
      on_exit(fn -> Application.delete_env(:masthead, :payments_stub) end)
    end

    test "a free site offers both upgrade plans", %{conn: conn, site: site} do
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/settings")

      assert html =~ "License"
      assert html =~ "See what&#39;s included"
      assert html =~ "Upgrade — €5/month"
      assert html =~ "Upgrade — €50/year"
      refute html =~ "Manage billing"
    end

    test "upgrading leaves for the provider's checkout", %{conn: conn, site: site} do
      Application.put_env(:masthead, :payments_stub, %{checkout_url: "https://checkout.test/abc"})
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

      assert {:error, {:redirect, %{to: "https://checkout.test/abc"}}} =
               lv
               |> element(~s(button[phx-click="checkout"][phx-value-plan="yearly"]))
               |> render_click()
    end

    test "a licensed site shows its renewal date and the billing portal", %{
      conn: conn,
      site: site
    } do
      {:ok, _site} = Masthead.Licenses.grant(site, "yearly")

      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/settings")

      assert html =~ "Paid"
      assert html =~ "Renews"
      assert html =~ "Manage billing"
      refute html =~ "Upgrade —"
      assert has_element?(lv, ".license-state .pill", "yearly")
    end

    test "a provider failure is reported instead of redirecting", %{conn: conn, site: site} do
      {:ok, _site} = Masthead.Licenses.grant(site, "yearly")
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

      html =
        lv
        |> element(~s(button[phx-click="billing_portal"]))
        |> render_click()

      assert html =~ "this site has no billing account yet"
    end

    test "a webhook landing elsewhere flips the section live", %{conn: conn, site: site} do
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/settings")
      assert html =~ "See what&#39;s included"
      refute has_element?(lv, ".license-state .pill")

      {:ok, _site} = Masthead.Licenses.grant(site, "monthly")

      assert render(lv) =~ "Renews"
      assert has_element?(lv, ".license-state .pill", "monthly")
    end

    test "custom domain on a free site opens the upgrade modal", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")

      refute has_element?(lv, ".dialog", "Upgrade to use this functionality")
      refute has_element?(lv, ~s(a[href="/#{site.slug}/domain"].btn-primary))

      html = lv |> element(~s(button[phx-click="open_upgrade"])) |> render_click()

      assert html =~ "Upgrade to use this functionality"
      assert html =~ "A custom domain needs a paid license"
    end

    test "the upgrade modal starts a checkout", %{conn: conn, site: site} do
      Application.put_env(:masthead, :payments_stub, %{checkout_url: "https://checkout.test/x"})
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/settings")
      lv |> element(~s(button[phx-click="open_upgrade"])) |> render_click()

      assert {:error, {:redirect, %{to: "https://checkout.test/x"}}} =
               lv
               |> element(~s(.dialog button[phx-value-plan="yearly"]))
               |> render_click()
    end

    test "a licensed site gets the custom domain link back", %{conn: conn, site: site} do
      {:ok, _site} = Masthead.Licenses.grant(site, "yearly")
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/settings")

      refute html =~ "Upgrade this site to set up a custom domain."
      assert has_element?(lv, ~s(a[href="/#{site.slug}/domain"]), "Set up a custom domain")
    end
  end
end

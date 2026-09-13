defmodule MastheadWeb.PageFormLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites, Themes}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "pf-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "pf#{System.unique_integer([:positive])}",
        "name" => "PF Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  describe "theme pages" do
    test "the Theme page card offers a template dropdown", %{conn: conn, site: site} do
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/pages/new")

      # The default theme ships templates/pages/blog.liquid, so the card and its
      # template dropdown show.
      assert html =~ "Theme page"
      assert html =~ ~s(<select name="template")
      assert html =~ ~s(value="blog")
    end

    test "selecting the Theme page card locks Continue and the stepper until a template is picked",
         %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

      # Click the card itself (no template yet).
      html =
        lv
        |> element(~s([phx-click="choose_format"][phx-value-format="theme"]))
        |> render_click()

      # Continue is disabled and the forward stepper steps are marked disabled.
      assert html =~ ~r/<button[^>]*phx-click="advance"[^>]*disabled/
      assert html =~ "step-disabled"
      assert html =~ "Pick a template to continue"

      # Jumping ahead via the stepper is refused while half-selected.
      lv |> render_hook("goto_step", %{"step" => "2"})
      assert render(lv) =~ "How do you want to write this page?"

      # Choose a template -> Continue and the stepper unlock.
      html =
        lv
        |> element(~s(form[phx-change="choose_template"]))
        |> render_change(%{"template" => "blog"})

      refute html =~ ~r/<button[^>]*phx-click="advance"[^>]*disabled/
      refute html =~ "step-disabled"
    end

    test "a file-type page setting renders a file picker in the settings step", %{
      conn: conn,
      site: site
    } do
      # The fixture theme's "widgets" page has a top-level file field (banner).
      site = install_fixture_theme(site)

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

      lv
      |> element(~s(form[phx-change="choose_template"]))
      |> render_change(%{"template" => "widgets"})

      lv |> element(~s(button[phx-click="advance"])) |> render_click()

      html =
        lv
        |> form("#meta-form", page: %{"title" => "Home"})
        |> render_submit()

      assert html =~ ~s(name="page[page_options][banner]")
      assert html =~ ~s(phx-value-meta="banner")
      assert html =~ "Choose file"
    end

    test "categorized page settings render as collapsible groups", %{conn: conn, site: site} do
      # The fixture theme's "widgets" page groups its fields by category.
      site = install_fixture_theme(site)

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

      lv
      |> element(~s(form[phx-change="choose_template"]))
      |> render_change(%{"template" => "widgets"})

      lv |> element(~s(button[phx-click="advance"])) |> render_click()

      html =
        lv
        |> form("#meta-form", page: %{"title" => "Home"})
        |> render_submit()

      assert html =~ "token-group"
      assert html =~ ~s(phx-value-group="Media")
      assert html =~ ~s(phx-value-group="Hero")

      # Expanding a group is tracked server-side so typing doesn't collapse it.
      html = lv |> render_hook("toggle_settings_group", %{"group" => "Hero"})
      assert html =~ ~r/<details[^>]*open[^>]*>\s*<summary[^>]*phx-value-group="Hero"/
    end

    test "the wizard ends on Page settings (no Content step) and saves a theme page", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

      # Pick a template from the card dropdown — selects the theme format but
      # stays on the Format step (Continue advances).
      html =
        lv
        |> element(~s(form[phx-change="choose_template"]))
        |> render_change(%{"template" => "blog"})

      # The stepper has exactly three steps for a theme page (no Content).
      refute html =~ ">Content<"
      assert html =~ ">Page settings<"

      lv |> element(~s(button[phx-click="advance"])) |> render_click()

      # Fill Details and continue to Page settings.
      html =
        lv
        |> form("#meta-form", page: %{"title" => "Writing"})
        |> render_submit()

      # Page settings shows the blog template's page options (layout select).
      assert html =~ "Page settings"
      assert html =~ ~s(name="page[page_options][layout]")

      # Save & publish from the terminal settings step.
      lv
      |> form("#content-form", page: %{"page_options" => %{"layout" => "wide"}})
      |> render_submit(%{"action" => "publish"})

      page = Masthead.Content.list_pages(site.id) |> Enum.find(&(&1.title == "Writing"))
      assert page.format == "theme"
      assert page.template == "blog"
      assert page.page_options["layout"] == "wide"
      assert page.published
    end

    test "object + list settings render, and save as a nested map + real array", %{
      conn: conn,
      site: site
    } do
      # The fixture "widgets" page has an object (hero) and a list (crew).
      site = install_fixture_theme(site)

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

      lv
      |> element(~s(form[phx-change="choose_template"]))
      |> render_change(%{"template" => "widgets"})

      lv |> element(~s(button[phx-click="advance"])) |> render_click()

      html = lv |> form("#meta-form", page: %{"title" => "Home"}) |> render_submit()

      # Object subfield input + the list (pre-seeded with its default item).
      assert html =~ ~s(name="page[page_options][hero][title]")
      assert html =~ ~s(phx-click="add_list_item")
      assert html =~ ~s(phx-value-key="crew")
      # The crew list declares a default member, seeded into the editor.
      assert html =~ "Ada Lovelace"

      # Object/list fields group under their declared categories like any field.
      assert html =~ "token-group"
      assert html =~ ~s(phx-value-group="Hero")
      assert html =~ ~s(phx-value-group="Crew")

      # Open the Crew group, then add a second item inside it → a draggable row.
      lv |> render_hook("toggle_settings_group", %{"group" => "Crew"})

      html =
        lv
        |> element(~s(button[phx-click="add_list_item"][phx-value-key="crew"]))
        |> render_click()

      assert html =~ ~s(data-sortable-event="reorder_list")
      assert html =~ ~r/<li[^>]*draggable="true"[^>]*data-sortable-id=/

      # Set an object subfield, then save.
      lv
      |> form("#content-form", page: %{"page_options" => %{"hero" => %{"title" => "Welcome"}}})
      |> render_change()

      lv |> form("#content-form") |> render_submit(%{"action" => "publish"})

      page = Masthead.Content.list_pages(site.id) |> Enum.find(&(&1.title == "Home"))
      assert page.template == "widgets"
      # Object saved as a real map; list as a real array (`_id` stripped) with the
      # seeded default item first, then the added (empty) one.
      assert page.page_options["hero"] == %{"title" => "Welcome"}
      assert [%{"name" => "Ada Lovelace"}, empty] = page.page_options["crew"]
      refute Map.has_key?(empty, "_id")
    end

    test "saving an existing theme page stays in place and keeps the open group", %{
      conn: conn,
      site: site
    } do
      site = install_fixture_theme(site)

      {:ok, page} =
        Masthead.Content.create_page(site.id, %{
          "title" => "Home",
          "format" => "theme",
          "template" => "widgets",
          "published" => true
        })

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/#{page.id}/edit")

      # Expand a settings group, then save.
      lv |> render_hook("toggle_settings_group", %{"group" => "Hero"})

      html =
        lv
        |> form("#content-form", page: %{"page_options" => %{"hero" => %{"title" => "Hi"}}})
        |> render_submit()

      # Saved in place (no redirect — html is rendered markup, not a redirect),
      # and the Hero group is still expanded.
      assert html =~ "Changes saved."
      assert html =~ ~r/<details[^>]*open[^>]*>\s*<summary[^>]*phx-value-group="Hero"/
      assert render(lv) =~ "Page settings"
    end
  end

  # Install an uploaded fixture theme whose "widgets" page exercises a file
  # field, an object, and a list (each with files), all grouped by category;
  # point the site at it. Returns the reloaded site.
  defp install_fixture_theme(site) do
    slug = "fix#{System.unique_integer([:positive])}"

    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Fix",
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [],
          "page_options" => []
        }),
      "templates/layout.liquid" => "<html><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/not_found.liquid" => "<h1>404</h1>",
      "templates/pages/widgets.liquid" => "<div>{{ page.title | escape }}</div>",
      "templates/pages/widgets.json" =>
        Jason.encode!(%{
          "label" => "Widgets",
          "page_options" => [
            %{
              "key" => "banner",
              "label" => "Banner",
              "type" => "file",
              "default" => "",
              "category" => "Media"
            },
            %{
              "key" => "hero",
              "label" => "Hero",
              "type" => "object",
              "category" => "Hero",
              "fields" => [
                %{"key" => "title", "label" => "Title", "type" => "string", "default" => ""},
                %{"key" => "image", "label" => "Image", "type" => "file", "default" => ""}
              ]
            },
            %{
              "key" => "crew",
              "label" => "Crew",
              "type" => "list",
              "item_label" => "Member",
              "category" => "Crew",
              "default" => [%{"name" => "Ada Lovelace"}],
              "fields" => [
                %{"key" => "name", "label" => "Name", "type" => "string", "default" => ""},
                %{"key" => "photo", "label" => "Photo", "type" => "file", "default" => ""}
              ]
            }
          ]
        }),
      "theme.css" => "body { background: #fff; }"
    }

    tmp = Path.join(System.tmp_dir!(), "fixtheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)

    {:ok, theme} = Masthead.Themes.Package.install(tmp, hd(Sites.list_members(site)).id)
    File.rm(tmp)
    {:ok, _} = Sites.update_settings(site, %{"theme_id" => theme.id})
    Sites.get_site!(site.id)
  end

  test "a boolean page option defaults to its manifest value (checked)", %{
    conn: conn,
    site: site
  } do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/pages/new")

    # Jump to the Page settings step via the stepper.
    html =
      lv
      |> element(~s(li[phx-click="goto_step"][phx-value-step="3"]))
      |> render_click()

    # The default theme declares show_navigation with "default": true, so a
    # brand-new page must start with the checkbox checked.
    assert html =~ ~s(id="meta-page-page_options-show_navigation")
    assert html =~ ~r/<input[^>]*id="meta-page-page_options-show_navigation"[^>]*checked/
  end
end

defmodule MastheadWeb.SiteThemeLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites, Themes, Uploads}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "st-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "st#{System.unique_integer([:positive])}",
        "name" => "ST Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  test "the selected theme can be changed and saved", %{conn: conn, site: site} do
    # A site can only select themes installed onto it; install a second one.
    theme = install_theme_onto(site, build_uncategorized_theme_zip("pick#{uniq()}"))

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    lv
    |> form("#site-theme-form", site: %{theme_id: theme.id})
    |> render_submit()

    assert Sites.get_site!(site.id).theme_id == theme.id
  end

  test "a theme without token categories renders the tokens flat", %{conn: conn, site: site} do
    # The built-in default groups its tokens, so install a custom theme whose
    # token has no category to exercise the flat path.
    theme = install_theme_onto(site, build_uncategorized_theme_zip("flat#{uniq()}"))
    {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")
    refute html =~ "token-group"
    assert html =~ "Accent"
  end

  defp build_uncategorized_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Flat " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [
            %{"key" => "accent", "label" => "Accent", "type" => "color", "default" => "#000000"}
          ],
          "page_options" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "flattheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  defp uniq, do: System.unique_integer([:positive])

  # Install an uploaded theme zip and make it available on the site, so the
  # site's theme picker (Default + installed) can select it.
  defp install_theme_onto(site, zip) do
    {:ok, theme} = Masthead.Themes.Package.install(zip, hd(Sites.list_members(site)).id)
    File.rm(zip)
    {:ok, _} = Themes.install_theme(site, theme)
    theme
  end

  # A theme with categorized tokens (Header + Footer) plus one uncategorized
  # token (→ General), to exercise the accordion grouping.
  defp build_categorized_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Cat " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [
            %{
              "key" => "header_bg",
              "label" => "Header background",
              "type" => "color",
              "default" => "#ffffff",
              "category" => "Header"
            },
            %{
              "key" => "footer_bg",
              "label" => "Footer background",
              "type" => "color",
              "default" => "#000000",
              "category" => "Footer"
            },
            %{"key" => "accent", "label" => "Accent", "type" => "color", "default" => "#123456"}
          ],
          "page_options" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "cattheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  test "a boolean token renders as a checkbox", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")
    assert html =~ ~s(name="site[theme_tokens][show_search]")
    assert html =~ ~s(type="checkbox")
  end

  test "a boolean token can be toggled on and saved", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    lv
    |> form("#site-theme-form", site: %{theme_tokens: %{show_search: "true"}})
    |> render_submit()

    assert Sites.get_site!(site.id).theme_tokens["show_search"] == "true"
  end

  test "a theme with token categories renders accordions, uncategorized under General", %{
    conn: conn,
    site: site
  } do
    theme = install_theme_onto(site, build_categorized_theme_zip("cat#{uniq()}"))
    {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")

    assert html =~ "token-group-summary"
    assert html =~ ~s(phx-value-handle="Header")
    assert html =~ ~s(phx-value-handle="Footer")
    # the uncategorized accent token → grouped under General.
    assert html =~ ~s(phx-value-handle="General")
  end

  test "an opened category stays open across a form change, and only one opens at a time", %{
    conn: conn,
    site: site
  } do
    theme = install_theme_onto(site, build_categorized_theme_zip("cat#{uniq()}"))
    {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})
    {:ok, lv, _} = live(conn, ~p"/#{site.slug}/theme")

    open_header = ~r/<details[^>]*\bopen\b[^>]*>\s*<summary[^>]*phx-value-handle="Header"/

    # Open the Header group.
    html = lv |> element(~s(summary[phx-value-handle="Header"])) |> render_click()
    assert html =~ open_header

    # A form change (what previously closed it) keeps it open.
    html =
      lv |> form("#site-theme-form", site: %{theme_css_overrides: "/* x */"}) |> render_change()

    assert html =~ open_header

    # Opening Footer closes Header (single-open accordion).
    html = lv |> element(~s(summary[phx-value-handle="Footer"])) |> render_click()
    refute html =~ open_header
    assert html =~ ~r/<details[^>]*\bopen\b[^>]*>\s*<summary[^>]*phx-value-handle="Footer"/
  end

  test "a file token renders a picker that lists the site's uploads in a modal", %{
    conn: conn,
    site: site
  } do
    upload = create_upload(site, "brand.png")

    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/theme")

    # The field carries a hidden value input and a "Choose file" trigger —
    # no inline <select>. The picker (and its options) is closed initially.
    assert html =~ ~s(name="site[theme_tokens][favicon]")
    assert html =~ "Choose file"
    refute html =~ "Upload new"

    # Opening the picker reveals the upload as a card, a "No file" option, and
    # an "Upload new" add-card.
    html =
      lv
      |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
      |> render_click()

    assert html =~ "No file"
    assert html =~ "brand.png"
    assert html =~ ~s(phx-value-id="#{upload.id}")
    assert html =~ "Upload new"
  end

  test "the picker loads only enough files to fill its 3x3 grid", %{conn: conn, site: site} do
    for n <- 1..12, do: create_upload(site, "shot-#{n}.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    html =
      lv
      |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
      |> render_click()

    # Nine slots, less the "Upload new" card and the "No file" card.
    assert picker_card_count(html) == 7
    assert html =~ "Showing the first 7. Search to find more."
    assert html =~ "No file"
    assert html =~ "Upload new"
  end

  test "searching the picker reaches a file the capped grid left out", %{conn: conn, site: site} do
    # Oldest upload, so a newest-first cap pushes it off the end.
    needle = create_upload(site, "needle.png")
    for n <- 1..12, do: create_upload(site, "shot-#{n}.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    html =
      lv
      |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
      |> render_click()

    refute html =~ "needle.png"

    html = lv |> form(~s(form.picker-search), %{"query" => "needle"}) |> render_change()

    assert html =~ "needle.png"
    assert html =~ ~s(phx-value-id="#{needle.id}")
    assert picker_card_count(html) == 1
    refute html =~ "Showing the first"
  end

  test "the picker says when a search matches nothing", %{conn: conn, site: site} do
    create_upload(site, "brand.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    lv
    |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
    |> render_click()

    html = lv |> form(~s(form.picker-search), %{"query" => "no-such-file"}) |> render_change()

    assert html =~ "No files match"
    assert picker_card_count(html) == 0
    # The upload path stays reachable from an empty result.
    assert html =~ "Upload new"
  end

  test "selecting an upload and saving persists its id as the token value", %{
    conn: conn,
    site: site
  } do
    upload = create_upload(site, "icon.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    lv
    |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
    |> render_click()

    # Clicking a card selects it (the picker reports back to the LiveView,
    # which sets the token); the field now shows the chosen filename.
    lv
    |> element(~s(button[phx-click="select"][phx-value-id="#{upload.id}"]))
    |> render_click()

    assert render(lv) =~ "icon.png"

    # Selection is part of the theme form; Save persists it.
    lv |> form("#site-theme-form") |> render_submit()

    site = Sites.get_site!(site.id)
    assert site.theme_tokens["favicon"] == to_string(upload.id)
  end

  test "uploading a new file in the picker stores it and selects it", %{conn: conn, site: site} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

    lv
    |> element(~s(button[phx-click="open"][phx-value-meta="favicon"]))
    |> render_click()

    # The uploader lives behind the "Upload new" add-card.
    lv |> element(~s(button[phx-click="show_upload"])) |> render_click()

    file =
      file_input(lv, "#theme-file-picker-upload-form", :file, [
        %{name: "fresh.png", content: "imgbytes", type: "image/png"}
      ])

    render_upload(file, "fresh.png")
    lv |> element("#theme-file-picker-upload-form") |> render_submit()

    # Stored and immediately selected for the active token.
    assert render(lv) =~ "fresh.png"
    fresh = Enum.find(Uploads.list_uploads(site.id), &(&1.filename == "fresh.png"))
    assert fresh

    lv |> form("#site-theme-form") |> render_submit()
    site = Sites.get_site!(site.id)
    assert site.theme_tokens["favicon"] == to_string(fresh.id)
  end

  test "token inputs are pre-filled with the manifest default when unset", %{
    conn: conn,
    site: site
  } do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")

    # The default theme's accent token defaults to #0066cc — the (color)
    # input must carry that as its value, not render blank/black.
    assert html =~ ~s(value="#0066cc")
  end

  test "a saved override is shown instead of the default", %{conn: conn, site: site} do
    {:ok, site} = Sites.update_settings(site, %{"theme_tokens" => %{"accent" => "#ff0000"}})

    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")

    assert html =~ ~s(value="#ff0000")
    refute html =~ ~s(value="#0066cc")
  end

  describe "object/list tokens" do
    setup %{site: site} do
      theme = install_theme_onto(site, build_container_token_theme_zip("cont#{uniq()}"))
      {:ok, site} = Sites.update_settings(site, %{"theme_id" => theme.id})

      {:ok, site: Sites.get_site!(site.id)}
    end

    test "they render like page options: subfield inputs, a seeded item, an Add button", %{
      conn: conn,
      site: site
    } do
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/theme")

      # An object's subfields are named per-subkey; a list's items are named by
      # their tracking id, and the theme's declared default item is seeded in.
      assert html =~ ~s(name="site[theme_tokens][hero][title]")
      assert html =~ ~s(phx-click="add_list_item")
      assert html =~ ~s(phx-value-key="links")
      assert html =~ "+ Add Link"
      assert html =~ "Home"

      # Container fields group into accordions by category like any other field.
      assert html =~ ~s(phx-value-handle="Hero")
    end

    test "an added list item is draggable, and saves as a nested map + real array", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/theme")

      html =
        lv
        |> element(~s(button[phx-click="add_list_item"][phx-value-key="links"]))
        |> render_click()

      assert html =~ ~s(data-sortable-event="reorder_list")
      assert html =~ ~r/<li[^>]*draggable="true"[^>]*data-sortable-id=/

      # Fill in the object's subfield, then save the form.
      lv
      |> form("#site-theme-form", site: %{theme_tokens: %{hero: %{title: "Welcome"}}})
      |> render_change()

      lv |> form("#site-theme-form") |> render_submit()

      tokens = Sites.get_site!(site.id).theme_tokens

      # The object is a real map; the list a real array — the seeded default item
      # first, then the (still empty) one we added, with no `_id` leaking in.
      assert tokens["hero"] == %{"title" => "Welcome"}
      assert [%{"label" => "Home"}, empty] = tokens["links"]
      refute Map.has_key?(empty, "_id")
    end

    test "a removed list item stays removed after saving", %{conn: conn, site: site} do
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/theme")

      [_, id] = Regex.run(~r/data-sortable-id="(\d+)"/, html)

      lv
      |> element(~s(button[phx-click="remove_list_item"][phx-value-id="#{id}"]))
      |> render_click()

      lv |> form("#site-theme-form") |> render_submit()

      assert Sites.get_site!(site.id).theme_tokens["links"] == []
    end

    test "items collapse one at a time; an object starts open and sits that out", %{
      conn: conn,
      site: site
    } do
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/theme")

      [_, id] = Regex.run(~r/data-sortable-id="(\d+)"/, html)
      item = ~r/<details[^>]*open[^>]*>\s*<summary[^>]*phx-value-handle="links:#{id}"/
      hero = ~r/<details[^>]*open[^>]*>\s*<summary[^>]*phx-value-handle="hero"/

      # The item is collapsed and labelled by its first text subfield, the
      # object open.
      refute html =~ item
      assert html =~ ~s(<span class="settings-list-title">Home</span>)
      assert html =~ hero

      html = lv |> element(~s(summary[phx-value-handle="links:#{id}"])) |> render_click()
      assert html =~ item
      assert html =~ hero

      # The object closes only by hand; adding an item opens it over this one.
      refute lv |> element(~s(summary[phx-value-handle="hero"])) |> render_click() =~ hero

      refute lv
             |> element(~s(button[phx-click="add_list_item"][phx-value-key="links"]))
             |> render_click() =~ item
    end
  end

  # A theme whose tokens include an `object` and a `list` — the same field types
  # a page's options can declare.
  defp build_container_token_theme_zip(slug) do
    files = %{
      "manifest.json" =>
        Jason.encode!(%{
          "name" => "Container " <> slug,
          "slug" => slug,
          "version" => "1.0.0",
          "tokens" => [
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
              "key" => "links",
              "label" => "Links",
              "type" => "list",
              "category" => "Nav",
              "item_label" => "Link",
              "default" => [%{"label" => "Home"}],
              "fields" => [
                %{"key" => "label", "label" => "Label", "type" => "string", "default" => ""},
                %{"key" => "url", "label" => "URL", "type" => "url", "default" => ""}
              ]
            }
          ],
          "page_options" => []
        }),
      "templates/layout.liquid" => "<html><head></head><body>{{ content }}</body></html>",
      "templates/index.liquid" => "<h1>{{ site.name | escape }}</h1>",
      "templates/post.liquid" => "<article>{{ body_html }}</article>",
      "templates/page.liquid" => "<article>{{ body_html }}</article>",
      "templates/blog.liquid" => "<h1>{{ page.title | escape }}</h1>",
      "templates/not_found.liquid" => "<h1>Not found</h1>",
      "theme.css" => "body { background: white; }"
    }

    tmp = Path.join(System.tmp_dir!(), "conttheme-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end)
    {:ok, _} = :zip.create(String.to_charlist(tmp), entries)
    tmp
  end

  # Selectable file cards in the picker grid (excludes "No file" and
  # "Upload new", which carry their own events).
  defp picker_card_count(html),
    do: html |> String.split(~s(phx-click="select")) |> length() |> Kernel.-(1)

  defp create_upload(site, filename) do
    tmp = Path.join(System.tmp_dir!(), "st-up-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "bytes")

    {:ok, upload} =
      Uploads.store_image(site, %{filename: filename, content_type: "image/png", path: tmp})

    File.rm(tmp)
    upload
  end
end

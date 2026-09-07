defmodule MastheadWeb.ThemeShowLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites, Themes}

  setup do
    Themes.Seed.run()

    user = register("viewer")
    author = register("author")

    %{user: user, author: author, conn: conn_for(user)}
  end

  test "shows the description and gallery", %{conn: conn, author: author} do
    theme = published(author, "Gallery Theme")
    {:ok, theme} = Themes.update_details(theme, %{"description" => "A calm, roomy layout."})
    {:ok, _} = Themes.add_theme_image(theme, image_file("a.png"))
    {:ok, _} = Themes.add_theme_image(theme, image_file("b.png"))

    {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

    assert html =~ "Gallery Theme"
    assert html =~ "A calm, roomy layout."
    assert html =~ "preview 1"

    html = lv |> element(~s(button[phx-value-index="1"])) |> render_click()
    assert html =~ "preview 2"
  end

  test "arrow keys walk the gallery", %{conn: conn, author: author} do
    theme = published(author, "Gallery Keys")
    {:ok, _} = Themes.add_theme_image(theme, image_file("a.png"))
    {:ok, _} = Themes.add_theme_image(theme, image_file("b.png"))

    {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
    assert html =~ "preview 1"

    html = render_keydown(lv, "gallery_key", %{"key" => "ArrowRight"})
    assert html =~ "preview 2"

    # Wraps at both ends.
    html = render_keydown(lv, "gallery_key", %{"key" => "ArrowRight"})
    assert html =~ "preview 1"

    html = render_keydown(lv, "gallery_key", %{"key" => "ArrowLeft"})
    assert html =~ "preview 2"

    # Anything else leaves the gallery where it is.
    html = render_keydown(lv, "gallery_key", %{"key" => "Enter"})
    assert html =~ "preview 2"
  end

  test "picking a site in the sidebar installs the theme onto it", %{
    conn: conn,
    user: user,
    author: author
  } do
    site = site_for(user)
    theme = published(author, "Installable")

    {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
    # Nothing is picked yet, so the install button is disabled.
    assert html =~ "disabled"

    # Opening the dropdown lists the sites; typing narrows them.
    html = lv |> element(~s(input#install-site)) |> render_focus()
    assert html =~ site.name

    html =
      lv |> form(~s(form[phx-change="filter_sites"]), %{site: "no-such-site"}) |> render_change()

    assert html =~ "No sites match"

    lv
    |> form(~s(form[phx-change="filter_sites"]), %{site: String.slice(site.name, 0, 3)})
    |> render_change()

    lv |> element(~s(button[phx-value-site="#{site.slug}"])) |> render_click()
    lv |> element(~s(button[phx-click="install"])) |> render_click()

    assert MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
    assert render(lv) =~ "Installed"
    assert_push_event(lv, "celebrate", %{from: ".install-card"})
  end

  test "the ?for= context preselects the site", %{conn: conn, user: user, author: author} do
    site = site_for(user)
    theme = published(author, "Contextual")

    {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}?#{[for: site.slug]}")

    lv |> element(~s(button[phx-click="install"])) |> render_click()

    assert MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
  end

  test "the sidebar credits the author", %{conn: conn, author: author} do
    theme = published(author, "Credited")

    {:ok, _lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

    assert html =~ author.email |> String.split("@") |> hd()
    assert html =~ "1 published theme"
    # Public themes carry the public chip; private ones the amber one.
    assert html =~ "Public"
    refute html =~ "chip-private"
  end

  test "a private theme is hidden from other users", %{conn: conn, author: author} do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "priv#{System.unique_integer([:positive])}",
        name: "Private Theme",
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: author.id
      })

    assert {:error, {:redirect, %{to: "/marketplace"}}} =
             live(conn, ~p"/marketplace/themes/#{theme.id}")
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp conn_for(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  describe "inline editing" do
    setup %{user: user} do
      %{own: published(user, "My Theme")}
    end

    test "the author edits the description in place", %{conn: conn, own: theme} do
      {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
      assert html =~ "No description yet"

      lv |> element(~s(button[phx-click="edit_description"])) |> render_click()

      html =
        lv
        |> form(~s(form[phx-submit="save_description"]), %{
          theme: %{description: "Roomy and calm."}
        })
        |> render_submit()

      assert html =~ "Roomy and calm."
      assert Themes.get_theme!(theme.id).description == "Roomy and calm."
    end

    test "arrow keys leave the gallery alone while a text field is open", %{
      conn: conn,
      own: theme
    } do
      {:ok, _} = Themes.add_theme_image(theme, image_file("a.png"))
      {:ok, _} = Themes.add_theme_image(theme, image_file("b.png"))

      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      # Editing the description: the arrows belong to the caret.
      lv |> element(~s(button[phx-click="edit_description"])) |> render_click()
      html = render_keydown(lv, "gallery_key", %{"key" => "ArrowRight"})
      assert html =~ "preview 1"

      lv |> element(~s(button[phx-click="cancel_description"])) |> render_click()
      html = render_keydown(lv, "gallery_key", %{"key" => "ArrowRight"})
      assert html =~ "preview 2"
    end

    test "the author adds, reorders and removes preview images", %{conn: conn, own: theme} do
      {:ok, a} = Themes.add_theme_image(theme, image_file("a.png"))
      {:ok, b} = Themes.add_theme_image(theme, image_file("b.png"))

      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      html = render_hook(lv, "reorder_previews", %{"ids" => [to_string(b.id), to_string(a.id)]})
      assert html =~ "Image order saved."
      assert Enum.map(Themes.list_theme_images(theme.id), & &1.id) == [b.id, a.id]

      html =
        lv
        |> element(~s(button[phx-click="remove_preview"][phx-value-id="#{a.id}"]))
        |> render_click()

      assert html =~ "Image removed."
      assert Enum.map(Themes.list_theme_images(theme.id), & &1.id) == [b.id]
    end

    test "the author adds an image from the strip", %{conn: conn, own: theme} do
      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      input =
        file_input(lv, "#preview-upload", :preview, [
          %{
            name: "c.png",
            content: File.read!("test/support/fixtures/pixel.png"),
            type: "image/png"
          }
        ])

      render_upload(input, "c.png")

      assert length(Themes.list_theme_images(theme.id)) == 1
    end

    test "a non-author gets no editing controls, and forged events do nothing", %{
      conn: conn,
      author: author
    } do
      theme = published(author, "Someone Else's")
      {:ok, image} = Themes.add_theme_image(theme, image_file("a.png"))

      {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      refute html =~ "edit_description"
      refute html =~ ~s(phx-click="delete")

      render_click(lv, "save_description", %{"theme" => %{"description" => "hijacked"}})
      render_click(lv, "remove_preview", %{"id" => to_string(image.id)})
      render_click(lv, "delete", %{})

      assert Themes.get_theme!(theme.id).description != "hijacked"
      assert Themes.list_theme_images(theme.id) != []
    end

    test "the author adds, reorders and removes listing links", %{conn: conn, own: theme} do
      {:ok, lv, html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
      assert html =~ "Point people at your docs"

      lv |> element(~s(button[phx-click="add_link"])) |> render_click()

      html =
        lv
        |> form(~s(form[phx-submit="save_link"]), %{
          theme_link: %{label: "Documentation", url: "docs.example.com"}
        })
        |> render_submit()

      assert html =~ "Documentation"
      # A bare host is assumed https rather than rejected.
      assert [%{url: "https://docs.example.com", label: "Documentation"}] =
               Themes.list_theme_links(theme.id)

      {:ok, second} =
        Themes.add_theme_link(theme, %{"label" => "Support", "url" => "mailto:me@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      [first, _] = Themes.list_theme_links(theme.id)

      html =
        render_hook(lv, "reorder_links", %{"ids" => [to_string(second.id), to_string(first.id)]})

      assert html =~ "Link order saved."
      assert Enum.map(Themes.list_theme_links(theme.id), & &1.id) == [second.id, first.id]

      lv
      |> element(~s(button[phx-click="remove_link"][phx-value-id="#{second.id}"]))
      |> render_click()

      refute Enum.any?(Themes.list_theme_links(theme.id), &(&1.id == second.id))
    end

    test "a blank link still reports the error on submit", %{conn: conn, own: theme} do
      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
      lv |> element(~s(button[phx-click="add_link"])) |> render_click()

      # Typing only the label must not yet complain about the empty URL.
      html =
        lv
        |> form(~s(form[phx-submit="save_link"]))
        |> render_change(%{
          "theme_link" => %{"_unused_url" => "", "label" => "Docs", "url" => ""}
        })

      refute html =~ "can&#39;t be blank"

      html =
        lv
        |> form(~s(form[phx-submit="save_link"]), %{theme_link: %{label: "", url: ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "a link must be a http(s) or mailto URL", %{conn: conn, own: theme} do
      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")
      lv |> element(~s(button[phx-click="add_link"])) |> render_click()

      html =
        lv
        |> form(~s(form[phx-submit="save_link"]), %{
          theme_link: %{label: "Bad", url: "javascript:alert(1)"}
        })
        |> render_submit()

      assert html =~ "must be a http(s) or mailto link"
      assert Themes.list_theme_links(theme.id) == []
    end

    test "the author makes a theme private and public again", %{conn: conn, own: theme} do
      {:ok, lv, _html} = live(conn, ~p"/marketplace/themes/#{theme.id}")

      lv |> element(~s(button[phx-click="open_manage"])) |> render_click()
      lv |> element(~s(button[phx-click="unpublish"])) |> render_click()
      refute Themes.get_theme!(theme.id).public

      lv |> element(~s(button[phx-click="publish"])) |> render_click()
      assert Themes.get_theme!(theme.id).public
    end
  end

  describe "signed out" do
    test "a published listing is readable, with a sign-up prompt in place of the install picker",
         %{author: author} do
      theme = published(author, "Public Listing")
      {:ok, theme} = Themes.update_details(theme, %{"description" => "Anyone can read this."})

      {:ok, _lv, html} = live(signed_out(), ~p"/marketplace/themes/#{theme.id}")

      assert html =~ "Public Listing"
      assert html =~ "Anyone can read this."
      assert html =~ "Create your site"
      refute html =~ ~s(id="install-site")
      refute html =~ ~s(id="admin-sidebar")
    end

    test "an unpublished listing is not", %{author: author} do
      theme = published(author, "Private Listing")
      {:ok, theme} = Themes.unpublish_theme(theme)

      assert {:error, {:redirect, %{to: "/marketplace"}}} =
               live(signed_out(), ~p"/marketplace/themes/#{theme.id}")
    end
  end

  defp signed_out, do: build_conn() |> Plug.Test.init_test_session(%{})

  defp published(user, name) do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "ts#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id
      })

    {:ok, theme} = Themes.publish_theme(theme)
    theme
  end

  defp site_for(user) do
    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "ts#{System.unique_integer([:positive])}",
        "name" => "TS Site",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    site
  end

  defp image_file(filename) do
    tmp = Path.join(System.tmp_dir!(), "ts-#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, "bytes")
    %{filename: filename, path: tmp}
  end
end

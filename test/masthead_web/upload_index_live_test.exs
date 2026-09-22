defmodule MastheadWeb.UploadIndexLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Sites, Uploads}

  # Keep in sync with `MastheadWeb.AdminLive.UploadIndex.list_limit/0`.
  @list_limit 18

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "ui-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "ui#{System.unique_integer([:positive])}",
        "name" => "UI Test",
        "owner_id" => user.id
      })

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site}
  end

  defp create_upload(site, filename, content_type \\ "image/png") do
    tmp = Path.join(System.tmp_dir!(), "ui-up-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "bytes")

    {:ok, upload} =
      Uploads.store_image(site, %{filename: filename, content_type: content_type, path: tmp})

    File.rm(tmp)
    upload
  end

  defp switch_filter(lv, filter) do
    lv
    |> element(~s(button[phx-click="switch_filter"][phx-value-filter="#{filter}"]))
    |> render_click()
  end

  defp card_count(html), do: html |> String.split("upload-card") |> length() |> Kernel.-(1)

  defp search(lv, query) do
    lv
    |> form(~s(form[phx-change="search_list"]), %{"query" => query})
    |> render_change()
  end

  test "no search box on an empty uploads page", %{conn: conn, site: site} do
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

    assert html =~ "Nothing uploaded yet"
    refute html =~ ~s(phx-change="search_list")
  end

  test "search filters the grid by filename", %{conn: conn, site: site} do
    create_upload(site, "hero-banner.png")
    create_upload(site, "footer-logo.png")

    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/uploads")

    assert html =~ "hero-banner.png"
    assert html =~ "footer-logo.png"

    html = search(lv, "hero")

    assert html =~ "hero-banner.png"
    refute html =~ "footer-logo.png"
  end

  test "the search term lives in the URL so it survives a reload", %{conn: conn, site: site} do
    create_upload(site, "hero-banner.png")
    create_upload(site, "footer-logo.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")
    search(lv, "hero")
    assert_patch(lv, ~p"/#{site.slug}/uploads?q=hero")

    # Landing on that URL directly applies the same filter.
    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads?q=hero")
    assert html =~ "hero-banner.png"
    refute html =~ "footer-logo.png"
  end

  test "the grid is capped and says so", %{conn: conn, site: site} do
    for n <- 1..(@list_limit + 4), do: create_upload(site, "file-#{n}.png")

    {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

    assert card_count(html) == @list_limit
    assert html =~ "Showing the first #{@list_limit}."
  end

  test "search reaches an upload that the capped grid never rendered", %{conn: conn, site: site} do
    # Oldest upload, so it falls off the end of a newest-first cap.
    create_upload(site, "needle.png")
    for n <- 1..(@list_limit + 4), do: create_upload(site, "file-#{n}.png")

    {:ok, lv, html} = live(conn, ~p"/#{site.slug}/uploads")
    refute html =~ "needle.png"

    html = search(lv, "needle")

    assert html =~ "needle.png"
    assert card_count(html) == 1
    refute html =~ "Showing the first"
  end

  test "a search with no matches explains itself and offers a way back", %{
    conn: conn,
    site: site
  } do
    create_upload(site, "hero-banner.png")

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")
    html = search(lv, "nothing-matches-this")

    assert html =~ "No uploads match"
    assert html =~ "Clear filter"
    # The illustrated "nothing uploaded yet" state is for a genuinely empty
    # library, not an empty search result.
    refute html =~ "Nothing uploaded yet"
  end

  describe "PDF previews" do
    # Set the path directly rather than running poppler: what's under test
    # here is what the grid renders, not how the PNG got made.
    defp with_thumbnail(upload) do
      upload
      |> Masthead.Uploads.Upload.changeset(%{thumbnail_path: "site/thumbs/#{upload.id}.png"})
      |> Masthead.Repo.update!()
    end

    test "a PDF without a thumbnail shows the extension badge", %{conn: conn, site: site} do
      create_upload(site, "manual.pdf", "application/pdf")

      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

      assert html =~ "file-badge"
      assert html =~ "PDF"
    end

    test "a PDF with a thumbnail shows it instead of the badge", %{conn: conn, site: site} do
      site |> create_upload("manual.pdf", "application/pdf") |> with_thumbnail()

      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

      assert html =~ "thumbs/"
      refute html =~ "file-badge"
    end
  end

  describe "type filter" do
    setup %{site: site} do
      create_upload(site, "hero.png", "image/png")
      create_upload(site, "manual.pdf", "application/pdf")
      :ok
    end

    test "every filter option is offered", %{conn: conn, site: site} do
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

      for {value, label} <- Uploads.filter_options() do
        assert html =~ ~s(phx-value-filter="#{value}")
        assert html =~ label
      end

      # What app.js focuses on Cmd/Ctrl+F instead of the browser find bar.
      assert html =~ ~s(data-shortcut="search")
    end

    test "Images hides documents and Documents hides images", %{conn: conn, site: site} do
      {:ok, lv, html} = live(conn, ~p"/#{site.slug}/uploads")
      assert html =~ "hero.png"
      assert html =~ "manual.pdf"

      html = switch_filter(lv, "images")
      assert html =~ "hero.png"
      refute html =~ "manual.pdf"

      html = switch_filter(lv, "documents")
      assert html =~ "manual.pdf"
      refute html =~ "hero.png"

      html = switch_filter(lv, "all")
      assert html =~ "hero.png"
      assert html =~ "manual.pdf"
    end

    test "the filter lives in the URL and combines with search", %{conn: conn, site: site} do
      create_upload(site, "hero-wide.png", "image/png")

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")

      switch_filter(lv, "images")
      assert_patch(lv, ~p"/#{site.slug}/uploads?type=images")

      search(lv, "hero")
      # `~p` encodes the param map with its keys sorted.
      assert_patch(lv, ~p"/#{site.slug}/uploads?q=hero&type=images")

      # Both constraints apply on a cold load of that URL.
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads?type=images&q=hero")
      assert html =~ "hero.png"
      assert html =~ "hero-wide.png"
      refute html =~ "manual.pdf"
    end

    test "switching back to All drops the param from the URL", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads?type=images")

      switch_filter(lv, "all")

      assert_patch(lv, ~p"/#{site.slug}/uploads")
    end

    test "a filter that matches nothing shows the no-match state", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")

      html = search(lv, "hero")
      assert html =~ "hero.png"

      # "hero" matches an image, so Documents + "hero" matches nothing.
      html = switch_filter(lv, "documents")

      assert html =~ "No uploads match"
      refute html =~ "Nothing uploaded yet"
    end

    test "the cap hint mentions the filter now that there is one", %{conn: conn, site: site} do
      for n <- 1..(@list_limit + 2), do: create_upload(site, "shot-#{n}.png")

      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

      assert html =~ "Refine with search or a filter to find more."
    end
  end

  describe "storage" do
    defp make_large(upload) do
      upload |> Ecto.Changeset.change(byte_size: 2 * 1024 * 1024) |> Masthead.Repo.update!()
    end

    test "the meter shows how much of the limit is used", %{conn: conn, site: site} do
      create_upload(site, "a.png")
      {:ok, _lv, html} = live(conn, ~p"/#{site.slug}/uploads")

      assert html =~ "storage-meter"
      assert html =~ "5 B of 1.0 GB used"
    end

    test "an upload past the limit is refused with a message", %{conn: conn, site: site} do
      {:ok, _} = Sites.set_storage_limit(site, 3)
      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads?new=1")

      input =
        file_input(lv, "#upload-form", :image, [
          %{name: "big.png", content: "12345", type: "image/png"}
        ])

      render_upload(input, "big.png")
      html = lv |> form("#upload-form") |> render_submit()

      assert html =~ "Not enough storage"
      assert Uploads.storage_used(site.id) == 0
    end

    test "the Heavy filter shows only images worth compressing", %{conn: conn, site: site} do
      site |> create_upload("big.jpg", "image/jpeg") |> make_large()
      create_upload(site, "small.png")
      site |> create_upload("big.pdf", "application/pdf") |> make_large()

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")
      switch_filter(lv, "heavy")
      assert_patch(lv, ~p"/#{site.slug}/uploads?type=heavy")

      assert has_element?(lv, ".upload-card", "big.jpg")
      refute has_element?(lv, ".upload-card", "small.png")
      refute has_element?(lv, ".upload-card", "big.pdf")
    end

    test "a large image gets a warning that compresses it in place", %{conn: conn, site: site} do
      upload = site |> create_upload("photo.jpg", "image/jpeg") |> make_large()
      small = create_upload(site, "small.png")

      {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/uploads")
      assert has_element?(lv, ".size-warning")
      refute has_element?(lv, ~s(.size-warning[aria-label^="#{small.filename}"]))

      lv |> element(".size-warning") |> render_click()
      assert has_element?(lv, "#compress-dialog", "Very large image")

      lv
      |> element("#compress-dialog-work-#{upload.id}")
      |> render_hook("compressed", %{"before" => upload.byte_size, "after" => 3})

      input =
        file_input(lv, "#compress-dialog-form", :replacement, [
          %{name: "photo.jpg", content: "abc", type: "image/jpeg"}
        ])

      render_upload(input, "photo.jpg")
      assert has_element?(lv, "#compress-dialog", "2.0 MB")

      lv |> form("#compress-dialog-form") |> render_submit()

      replaced = Uploads.get_upload!(site.id, upload.id)
      assert replaced.path == upload.path
      assert replaced.byte_size == 3
      refute has_element?(lv, "#compress-dialog", "Very large image")
      refute has_element?(lv, ".size-warning")
    end
  end
end

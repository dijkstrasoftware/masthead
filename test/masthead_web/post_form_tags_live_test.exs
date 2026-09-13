defmodule MastheadWeb.PostFormTagsLiveTest do
  use MastheadWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Masthead.{Accounts, Content, Sites, Themes}

  setup do
    Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "pft-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "pft#{System.unique_integer([:positive])}",
        "name" => "PFT Test",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    {:ok, tag} = Content.create_tag(site.id, %{"name" => "Featured"})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, user.id)

    %{conn: conn, site: site, tag: tag}
  end

  test "toggling a tag on a new post attaches it on save", %{conn: conn, site: site, tag: tag} do
    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/new")

    # Step 1: choosing a format advances to the details step.
    lv |> element(~s(button[phx-value-format="markdown"])) |> render_click()

    # Toggle the tag (managed in the draft, outside the form fields).
    lv |> element(~s(button.tag-toggle[phx-value-id="#{tag.id}"])) |> render_click()

    # Submit the details form to advance, step past Post options, then save
    # from the content step.
    lv |> form("#meta-form", post: %{title: "Tagged via form"}) |> render_submit()
    lv |> form("#settings-form") |> render_submit()
    lv |> form("#content-form") |> render_submit()

    [post] = Content.list_posts(site.id)
    assert post.title == "Tagged via form"
    assert Enum.map(post.tags, & &1.slug) == ["featured"]
  end

  test "editing a post preselects its tags and can clear them", %{
    conn: conn,
    site: site,
    tag: tag
  } do
    {:ok, post} =
      Content.create_post(site.id, %{"title" => "Has a tag", "tag_ids" => [tag.id]})

    {:ok, lv, _html} = live(conn, ~p"/#{site.slug}/posts/#{post.id}/edit")

    # Editing opens on the content step; jump back to Details where tags live.
    lv |> element(~s(.step), "Details") |> render_click()

    # The existing tag is preselected (active toggle).
    assert has_element?(lv, ~s(button.tag-toggle-on[phx-value-id="#{tag.id}"]))

    # Toggle it off, advance, and save.
    lv |> element(~s(button.tag-toggle[phx-value-id="#{tag.id}"])) |> render_click()
    lv |> form("#meta-form", post: %{title: "Has a tag"}) |> render_submit()
    lv |> form("#settings-form") |> render_submit()
    lv |> form("#content-form") |> render_submit()

    assert Content.get_post!(site.id, post.id).tags == []
  end
end

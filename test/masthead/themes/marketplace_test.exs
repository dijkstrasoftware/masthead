defmodule Masthead.Themes.MarketplaceTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Themes}

  setup do
    Themes.Seed.run()

    %{user: register("viewer"), author: register("author")}
  end

  defp register(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp upload(user, name) do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "ut#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id
      })

    theme
  end

  defp published(user, name, opts \\ []) do
    theme = upload(user, name)
    {:ok, theme} = Themes.publish_theme(theme)
    if opts[:verified], do: elem(Themes.verify_theme(theme), 1), else: theme
  end

  defp site_for(user) do
    default = Themes.get_built_in_by_slug("default")

    {:ok, site} =
      Masthead.Sites.create_site(%{
        "slug" => "s#{System.unique_integer([:positive])}",
        "name" => "S",
        "owner_id" => user.id,
        "theme_id" => default.id
      })

    site
  end

  describe "publish / verify" do
    test "publishing flips public; built-ins are protected", %{user: user} do
      theme = upload(user, "Mine")
      refute theme.public

      {:ok, theme} = Themes.publish_theme(theme)
      assert theme.public

      {:ok, theme} = Themes.unpublish_theme(theme)
      refute theme.public

      built_in = Themes.get_built_in_by_slug("default")
      assert {:error, :built_in_protected} = Themes.publish_theme(built_in)
    end
  end

  describe "list_marketplace/2" do
    test "published themes from others, verified first, excluding your own", %{
      user: user,
      author: author
    } do
      _community = published(author, "Bbb Community")
      _verified = published(author, "Aaa Verified", verified: true)
      _own = published(user, "Mine Published")
      _private = upload(author, "Private")

      names = Themes.list_marketplace(user.id) |> Enum.map(& &1.name)

      # Verified ranks ahead of community; viewer's own + private excluded.
      assert names == ["Aaa Verified", "Bbb Community"]
    end

    test "filter narrows to verified or community", %{user: user, author: author} do
      _community = published(author, "Community")
      _verified = published(author, "Verified", verified: true)

      assert [%{name: "Verified"}] = Themes.list_marketplace(user.id, :verified)
      assert [%{name: "Community"}] = Themes.list_marketplace(user.id, :community)
    end

    test "an author id narrows to that author's published themes", %{
      user: user,
      author: author
    } do
      other = register("other")
      _theirs = published(author, "Theirs")
      _elsewhere = published(other, "Elsewhere")
      _private = upload(author, "Private")

      assert [%{name: "Theirs"}] = Themes.list_marketplace(user.id, :all, nil, author.id)
    end

    test "your own shelf is visible when you ask for it by author", %{user: user} do
      _own = published(user, "Mine Published")

      assert Themes.list_marketplace(user.id) == []
      assert [%{name: "Mine Published"}] = Themes.list_marketplace(user.id, :all, nil, user.id)
    end
  end

  describe "install / uninstall (per site)" do
    test "installing makes the theme selectable on the site; uninstall removes it", %{
      user: user,
      author: author
    } do
      site = site_for(user)
      theme = published(author, "Installable")

      refute MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
      refute theme.id in (Themes.list_themes_for_site(site) |> Enum.map(& &1.id))

      {:ok, _} = Themes.install_theme(site, theme)

      assert MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
      assert theme.id in (Themes.list_themes_for_site(site) |> Enum.map(& &1.id))

      # Idempotent: a second install is a no-op.
      {:ok, _} = Themes.install_theme(site, theme)
      assert Themes.installed_theme_ids(site.id) |> MapSet.size() == 1

      {:ok, _} = Themes.uninstall_theme(site, theme.id)
      refute MapSet.member?(Themes.installed_theme_ids(site.id), theme.id)
    end

    test "the site owner can install their own unpublished theme", %{user: user} do
      site = site_for(user)
      theme = upload(user, "Draft")
      assert {:ok, _} = Themes.install_theme(site, theme)
    end

    test "another user's unpublished theme cannot be installed", %{user: user, author: author} do
      site = site_for(user)
      theme = upload(author, "Draft")
      assert {:error, :not_installable} = Themes.install_theme(site, theme)
    end

    test "the site's active theme cannot be uninstalled", %{user: user, author: author} do
      site = site_for(user)
      theme = published(author, "Active")
      {:ok, _} = Themes.install_theme(site, theme)
      {:ok, site} = Masthead.Sites.update_settings(site, %{"theme_id" => theme.id})

      assert {:error, :in_use} = Themes.uninstall_theme(site, theme.id)
    end
  end

  describe "gallery images" do
    test "add appends in order, url is public, delete removes", %{user: user} do
      theme = upload(user, "Gallery")

      {:ok, first} = Themes.add_theme_image(theme, image_attrs("a.png"))
      {:ok, second} = Themes.add_theme_image(theme, image_attrs("b.png"))

      assert first.position == 0
      assert second.position == 1
      assert Themes.image_url(first) =~ "/uploads/theme-previews/#{theme.id}/"

      {:ok, _} = Themes.delete_theme_image(first)
      assert Themes.list_theme_images(theme.id) |> Enum.map(& &1.id) == [second.id]
    end

    test "reorder_theme_images rewrites positions to match the given order", %{user: user} do
      theme = upload(user, "Gallery")
      {:ok, a} = Themes.add_theme_image(theme, image_attrs("a.png"))
      {:ok, b} = Themes.add_theme_image(theme, image_attrs("b.png"))
      {:ok, c} = Themes.add_theme_image(theme, image_attrs("c.png"))

      :ok = Themes.reorder_theme_images(theme.id, [c.id, a.id, b.id])

      assert Themes.list_theme_images(theme.id) |> Enum.map(& &1.id) == [c.id, a.id, b.id]
    end

    test "reorder ignores ids from other themes", %{user: user} do
      theme = upload(user, "Gallery")
      other = upload(user, "Other")
      {:ok, a} = Themes.add_theme_image(theme, image_attrs("a.png"))
      {:ok, foreign} = Themes.add_theme_image(other, image_attrs("x.png"))

      :ok = Themes.reorder_theme_images(theme.id, [foreign.id, a.id])

      # `a` is the only image actually belonging to `theme`.
      assert Themes.list_theme_images(theme.id) |> Enum.map(& &1.id) == [a.id]
    end
  end

  defp image_attrs(filename) do
    tmp = Path.join(System.tmp_dir!(), "ti-#{System.unique_integer([:positive])}-#{filename}")
    File.write!(tmp, "bytes")
    %{filename: filename, path: tmp}
  end
end

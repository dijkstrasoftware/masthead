defmodule Masthead.Themes.ThemeTagsTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Themes}

  setup do
    Themes.Seed.run()

    {:ok, author} =
      Accounts.register_user(%{
        "email" => "tags-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    %{author: author}
  end

  defp tag(name) do
    {:ok, tag} =
      Themes.create_theme_tag(%{"name" => "#{name} #{System.unique_integer([:positive])}"})

    tag
  end

  defp published(user, name, tags) do
    {:ok, theme} =
      Themes.create_upload(%{
        slug: "tt#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id
      })

    {:ok, theme} = Themes.publish_theme(theme)
    {:ok, theme} = Themes.set_theme_tags(theme, Enum.map(tags, & &1.id))
    theme
  end

  test "starter tags are seeded" do
    assert Themes.get_theme_tag_by_slug("blog")
    assert Themes.get_theme_tag_by_slug("landing-page")
  end

  test "a theme takes up to three tags", %{author: author} do
    [a, b, c, d] = Enum.map(~w(A B C D), &tag/1)
    theme = published(author, "Three", [a, b, c])
    assert theme.tags |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([a.id, b.id, c.id])

    assert {:error, changeset} = Themes.set_theme_tags(theme, [a.id, b.id, c.id, d.id])
    assert "pick at most 3 tags" in errors_on(changeset).tags
  end

  test "renaming a tag keeps its slug" do
    tag = tag("Old")
    {:ok, renamed} = Themes.update_theme_tag(tag, %{"name" => "New name"})
    assert renamed.name == "New name"
    assert renamed.slug == tag.slug
  end

  test "deleting a tag removes it from themes", %{author: author} do
    doomed = tag("Doomed")
    theme = published(author, "Tagged", [doomed])

    {:ok, _} = Themes.delete_theme_tag(doomed)

    assert Masthead.Repo.preload(Themes.get_theme!(theme.id), :tags).tags == []
    refute Themes.get_theme_tag_by_slug(doomed.slug)
  end

  test "related themes rank by shared tags, published only", %{author: author} do
    [a, b, c] = Enum.map(~w(A B C), &tag/1)
    theme = published(author, "Base", [a, b])
    two = published(author, "Shares two", [a, b, c])
    one = published(author, "Shares one", [b])
    _none = published(author, "Shares none", [c])
    hidden = published(author, "Hidden", [a, b])
    {:ok, _} = Themes.unpublish_theme(hidden)

    assert Enum.map(Themes.related_themes(theme), & &1.id) == [two.id, one.id]
  end

  test "the marketplace filters and searches by tag", %{author: author} do
    wanted = tag("Brutalist")
    match = published(author, "Concrete", [wanted])
    _other = published(author, "Soft", [tag("Pastel")])

    assert Enum.map(Themes.list_marketplace(nil, :all, nil, nil, wanted.id), & &1.id) == [
             match.id
           ]

    assert Enum.map(Themes.list_marketplace(nil, :all, "brutal"), & &1.id) == [match.id]
  end
end

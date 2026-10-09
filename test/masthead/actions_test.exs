defmodule Masthead.ActionsTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Content, Sites, Actions}
  alias Masthead.Actions.Action

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "act-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    %{user: user}
  end

  # A new site is seeded with onboarding actions: customize_theme,
  # create_first_post, and import_site (+ create_first_page when its theme has
  # no page templates). (set_description is staggered in
  # later, once the site has its first post or page.)
  defp new_site(user, attrs \\ %{}) do
    {:ok, site} =
      Sites.create_site(
        Map.merge(
          %{
            "slug" => "act#{System.unique_integer([:positive])}",
            "name" => "Act Test",
            "owner_id" => user.id
          },
          attrs
        )
      )

    site
  end

  # A site with its seeded onboarding actions cleared, for exercising the
  # action mechanics in isolation.
  defp blank_site(user) do
    site = new_site(user, %{"description" => "blank"})
    Repo.delete_all(from a in Action, where: a.site_id == ^site.id)
    site
  end

  defp pending_keys(site), do: site |> Actions.list_pending() |> Enum.map(& &1.key)
  defp pending?(site, key), do: key in pending_keys(site)

  describe "create_action/2" do
    test "creates a known action from the registry", %{user: user} do
      site = blank_site(user)

      assert {:ok, %Action{} = action} = Actions.create_action(site, "set_description")
      assert action.key == "set_description"
      assert action.status == "pending"
      assert action.priority == 100
      assert action.path == "/#{site.slug}/settings"
      assert is_binary(action.message)
    end

    test "is idempotent — a duplicate (site, key) is a no-op", %{user: user} do
      site = blank_site(user)

      assert {:ok, %Action{}} = Actions.create_action(site, "set_description")
      assert {:ok, :exists} = Actions.create_action(site, "set_description")
      assert Actions.count_pending(site) == 1
    end

    test "rejects an unknown key", %{user: user} do
      site = blank_site(user)
      assert {:error, :unknown_key} = Actions.create_action(site, "does_not_exist")
    end
  end

  describe "complete_action/2" do
    test "completes a pending action and is idempotent", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")
      assert Actions.count_pending(site) == 1

      assert :ok = Actions.complete_action(site, "set_description")
      assert Actions.count_pending(site) == 0

      # completing again is safe
      assert :ok = Actions.complete_action(site, "set_description")
      assert Actions.count_pending(site) == 0
    end

    test "accepts a bare site id", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")

      assert :ok = Actions.complete_action(site.id, "set_description")
      assert Actions.count_pending(site) == 0
    end

    test "is a no-op when the action is absent", %{user: user} do
      site = blank_site(user)
      assert :ok = Actions.complete_action(site, "set_description")
      assert Actions.count_pending(site) == 0
    end
  end

  describe "dismiss_action/2" do
    test "dismisses a pending action so it leaves pending queries", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")
      assert pending?(site, "set_description")

      assert :ok = Actions.dismiss_action(site, "set_description")
      refute pending?(site, "set_description")
      assert Actions.count_pending(site) == 0
    end

    test "is idempotent and safe when absent", %{user: user} do
      site = blank_site(user)
      assert :ok = Actions.dismiss_action(site, "set_description")

      {:ok, _} = Actions.create_action(site, "set_description")
      assert :ok = Actions.dismiss_action(site, "set_description")
      assert :ok = Actions.dismiss_action(site, "set_description")
      assert Actions.count_pending(site) == 0
    end

    test "leaves an already-completed action untouched", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")
      :ok = Actions.complete_action(site, "set_description")

      :ok = Actions.dismiss_action(site, "set_description")

      action = Repo.get_by!(Action, site_id: site.id, key: "set_description")
      assert action.status == "completed"
    end
  end

  describe "querying" do
    test "top_action returns the highest-priority pending action", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")

      Repo.insert!(%Action{
        site_id: site.id,
        key: "low_priority",
        status: "pending",
        message: "later",
        priority: 1
      })

      assert %Action{key: "set_description"} = Actions.top_action(site)
      assert length(Actions.list_pending(site)) == 2
    end

    test "completed actions are excluded from pending queries", %{user: user} do
      site = blank_site(user)
      {:ok, _} = Actions.create_action(site, "set_description")
      :ok = Actions.complete_action(site, "set_description")

      assert Actions.list_pending(site) == []
      assert Actions.top_action(site) == nil
    end
  end

  describe "site lifecycle hooks" do
    test "a new site is seeded with the onboarding actions", %{user: user} do
      site = new_site(user)

      assert Enum.sort(pending_keys(site)) ==
               ["create_first_post", "customize_theme", "import_site"]
    end

    test "top_action for a new site is to customize the theme", %{user: user} do
      site = new_site(user)
      assert %Action{key: "customize_theme"} = Actions.top_action(site)
    end

    test "set_description is staggered in once the site gets its first post", %{user: user} do
      site = new_site(user)
      refute pending?(site, "set_description")

      {:ok, _post} = Content.create_post(site.id, %{"title" => "Hello", "slug" => "hello"})
      assert pending?(site, "set_description")
    end

    test "creating the first page also unlocks set_description", %{user: user} do
      site = new_site(user)
      refute pending?(site, "set_description")

      {:ok, _page} = Content.create_page(site.id, %{"title" => "About", "slug" => "about"})
      assert pending?(site, "set_description")
    end

    test "the description nudge is skipped when one is already set", %{user: user} do
      site = new_site(user, %{"description" => "Already described"})

      {:ok, _post} = Content.create_post(site.id, %{"title" => "Hello", "slug" => "hello"})
      refute pending?(site, "set_description")
    end

    test "saving a description completes the unlocked set_description action", %{user: user} do
      site = new_site(user)
      {:ok, _post} = Content.create_post(site.id, %{"title" => "Hello", "slug" => "hello"})
      assert pending?(site, "set_description")

      {:ok, site} = Sites.update_settings(site, %{"description" => "Now described"})
      refute pending?(site, "set_description")
    end

    test "creating the first post completes create_first_post", %{user: user} do
      site = new_site(user)
      assert pending?(site, "create_first_post")

      {:ok, _post} = Content.create_post(site.id, %{"title" => "Hello", "slug" => "hello"})
      refute pending?(site, "create_first_post")
    end

    test "creating the first page completes create_first_page", %{user: user} do
      site = new_site(user)
      {:ok, _} = Actions.create_action(site, "create_first_page")
      assert pending?(site, "create_first_page")

      {:ok, _page} = Content.create_page(site.id, %{"title" => "About", "slug" => "about"})
      refute pending?(site, "create_first_page")
    end
  end

  defp theme_with_pages(user, pages) do
    {:ok, theme} =
      Masthead.Themes.create_upload(%{
        slug: "tp#{System.unique_integer([:positive])}",
        name: "Aurora",
        version: "1.0.0",
        storage_path: "themes/uploaded/1.0.0",
        owner_id: user.id,
        manifest: %{
          "name" => "Aurora",
          "page_templates" => pages,
          "page_configs" => %{
            "gallery" => %{"label" => "Gallery", "description" => "Show photos."}
          },
          "tokens" => [
            %{"key" => "accent", "label" => "Accent color", "type" => "color"},
            %{"key" => "font", "label" => "Font", "type" => "string"}
          ]
        }
      })

    theme
  end

  defp keys_like(site, prefix),
    do: site |> pending_keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()

  describe "theme onboarding" do
    test "a theme with page templates seeds no page todos up front", %{user: user} do
      site = new_site(user, %{"theme_id" => theme_with_pages(user, ["gallery"]).id})

      assert Enum.sort(pending_keys(site)) ==
               ["create_first_post", "customize_theme", "import_site"]

      action = Repo.get_by!(Action, site_id: site.id, key: "customize_theme")
      assert action.message =~ "Aurora has 2 settings"
      assert action.path == "/#{site.slug}/theme"
    end

    test "a theme without page templates gets create_first_page", %{user: user} do
      site = new_site(user, %{"theme_id" => theme_with_pages(user, []).id})
      assert pending?(site, "create_first_page")
    end

    test "saving tokens completes customize_theme and adds page todos (max 3)", %{user: user} do
      theme = theme_with_pages(user, ["gallery", "a", "b", "c"])
      site = new_site(user, %{"theme_id" => theme.id})

      {:ok, site} = Sites.update_settings(site, %{"theme_tokens" => %{"accent" => "#000000"}})

      refute pending?(site, "customize_theme")

      assert keys_like(site, "theme_page:") == [
               "theme_page:a",
               "theme_page:b",
               "theme_page:gallery"
             ]

      action = Repo.get_by!(Action, site_id: site.id, key: "theme_page:gallery")
      assert action.title == "Your theme can build a Gallery page"
      assert action.message == "Show photos."
      assert action.path == "/#{site.slug}/pages/new?template=gallery"
    end

    test "dismissing customize_theme unlocks the page todos", %{user: user} do
      site = new_site(user, %{"theme_id" => theme_with_pages(user, ["gallery"]).id})
      :ok = Actions.dismiss_action(site, "customize_theme")
      assert keys_like(site, "theme_page:") == ["theme_page:gallery"]
    end

    test "switching theme swaps pending page todos and keeps completed ones", %{user: user} do
      site = new_site(user, %{"theme_id" => theme_with_pages(user, ["gallery", "old"]).id})
      :ok = Actions.dismiss_action(site, "customize_theme")
      :ok = Actions.complete_action(site, "theme_page:gallery")

      {:ok, site} =
        Sites.update_settings(site, %{"theme_id" => theme_with_pages(user, ["new"]).id})

      assert keys_like(site, "theme_page:") == ["theme_page:new"]
      assert Repo.get_by!(Action, site_id: site.id, key: "theme_page:old").status == "dismissed"

      assert Repo.get_by!(Action, site_id: site.id, key: "theme_page:gallery").status ==
               "completed"
    end

    test "creating a theme page completes its todo", %{user: user} do
      site = new_site(user, %{"theme_id" => theme_with_pages(user, ["gallery"]).id})
      :ok = Actions.dismiss_action(site, "customize_theme")

      {:ok, _page} =
        Content.create_page(site.id, %{
          "title" => "Photos",
          "slug" => "photos",
          "format" => "theme",
          "template" => "gallery"
        })

      refute pending?(site, "theme_page:gallery")
    end
  end
end

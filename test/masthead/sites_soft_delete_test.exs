defmodule Masthead.SitesSoftDeleteTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Sites}

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "sd-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "sd#{System.unique_integer([:positive])}",
        "name" => "SD Site",
        "owner_id" => user.id
      })

    %{user: user, site: site}
  end

  test "a soft-deleted site is hidden from its owner and the public", %{user: user, site: site} do
    assert Enum.any?(Sites.list_sites_for_user(user.id), &(&1.id == site.id))
    assert Sites.get_site_by_slug(site.slug)

    {:ok, _} = Sites.soft_delete_site(site)

    refute Enum.any?(Sites.list_sites_for_user(user.id), &(&1.id == site.id))
    refute Sites.get_site_by_slug(site.slug)

    # Restoring brings it back.
    {:ok, _} = Sites.restore_site(Sites.get_site!(site.id))
    assert Sites.get_site_by_slug(site.slug)
  end

  test "deleting frees the slug for a new site", %{user: user, site: site} do
    {:ok, deleted} = Sites.soft_delete_site(site)

    assert deleted.slug =~ ~r/^#{site.slug}-deleted-[0-9a-f]{8}$/

    assert {:ok, replacement} =
             Sites.create_site(%{"slug" => site.slug, "name" => "Reuse", "owner_id" => user.id})

    assert replacement.slug == site.slug
  end

  test "restoring keeps the suffixed slug when the original was taken", %{
    user: user,
    site: site
  } do
    {:ok, deleted} = Sites.soft_delete_site(site)

    {:ok, _} =
      Sites.create_site(%{"slug" => site.slug, "name" => "Reuse", "owner_id" => user.id})

    {:ok, restored} = Sites.restore_site(Sites.get_site!(deleted.id))

    assert restored.slug == deleted.slug
    assert Sites.get_site_by_slug(restored.slug).id == site.id
  end

  test "a disabled site stays visible to its owner but stops resolving", %{user: user, site: site} do
    {:ok, _} = Sites.disable_site(site)

    assert Enum.any?(Sites.list_sites_for_user(user.id), &(&1.id == site.id))
    refute Sites.get_site_by_slug(site.slug)
  end
end

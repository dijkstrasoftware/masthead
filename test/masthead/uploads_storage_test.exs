defmodule Masthead.UploadsStorageTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Sites, Uploads}
  alias Masthead.Uploads.Upload

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "us-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "us#{System.unique_integer([:positive])}",
        "name" => "Storage",
        "owner_id" => user.id
      })

    %{site: site}
  end

  defp tmp_file(bytes) do
    path = Path.join(System.tmp_dir!(), "us-#{System.unique_integer([:positive])}.jpg")
    File.write!(path, :binary.copy("x", bytes))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp store(site, bytes) do
    Uploads.store_image(site, %{
      filename: "a.jpg",
      content_type: "image/jpeg",
      path: tmp_file(bytes)
    })
  end

  test "an upload that would pass the limit is refused", %{site: site} do
    {:ok, site} = Sites.set_storage_limit(site, 100)

    assert {:ok, _} = store(site, 60)
    assert {:error, :storage_full} = store(site, 60)
    assert {:ok, _} = store(site, 40)
    assert Uploads.storage_used(site.id) == 100
  end

  test "the default limit is 1 GB until an admin overrides it", %{site: site} do
    assert Uploads.storage_limit(site) == 1024 * 1024 * 1024

    {:ok, site} = Sites.set_storage_limit(site, 5_000)
    assert Uploads.storage_limit(site) == 5_000

    {:ok, site} = Sites.set_storage_limit(site, nil)
    assert Uploads.storage_limit(site) == 1024 * 1024 * 1024
  end

  test "replacing a file keeps its path and updates its size", %{site: site} do
    {:ok, upload} = store(site, 500)
    {:ok, replaced} = Uploads.replace_file(site, upload, tmp_file(120))

    assert replaced.path == upload.path
    assert replaced.byte_size == 120
    assert {:ok, body} = Masthead.Storage.read(upload.path)
    assert byte_size(body) == 120
  end

  test "a replacement is measured against the space the old file frees", %{site: site} do
    {:ok, site} = Sites.set_storage_limit(site, 100)
    {:ok, upload} = store(site, 90)

    assert {:ok, _} = Uploads.replace_file(site, upload, tmp_file(95))
    assert {:error, :storage_full} = Uploads.replace_file(site, upload, tmp_file(101))
  end

  test "only large web images count as too large" do
    big = 2 * 1024 * 1024

    assert Uploads.too_large?(%Upload{content_type: "image/jpeg", byte_size: big})
    assert Uploads.too_large?(%Upload{content_type: "image/png", byte_size: big})
    assert Uploads.too_large?(%Upload{content_type: "image/webp", byte_size: big})
    refute Uploads.too_large?(%Upload{content_type: "image/gif", byte_size: big})
    refute Uploads.too_large?(%Upload{content_type: "application/pdf", byte_size: big})
    refute Uploads.too_large?(%Upload{content_type: "image/jpeg", byte_size: 500_000})
  end
end

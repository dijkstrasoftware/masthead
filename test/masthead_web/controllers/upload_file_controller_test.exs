defmodule MastheadWeb.UploadFileControllerTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Sites, Uploads}

  defp user do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "uf-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    user
  end

  defp log_in(user) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  setup do
    owner = user()

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "uf#{System.unique_integer([:positive])}",
        "name" => "Files",
        "owner_id" => owner.id
      })

    tmp = Path.join(System.tmp_dir!(), "uf-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "png-bytes")

    {:ok, upload} =
      Uploads.store_image(site, %{filename: "a.png", content_type: "image/png", path: tmp})

    File.rm(tmp)

    %{owner: owner, site: site, upload: upload}
  end

  test "a member gets the file's bytes", %{owner: owner, site: site, upload: upload} do
    conn = get(log_in(owner), ~p"/#{site.slug}/uploads/#{upload.id}/file")

    assert response(conn, 200) == "png-bytes"
    assert response_content_type(conn, :png)
  end

  test "someone outside the site gets a 404", %{site: site, upload: upload} do
    assert_error_sent 404, fn ->
      get(log_in(user()), ~p"/#{site.slug}/uploads/#{upload.id}/file")
    end
  end
end

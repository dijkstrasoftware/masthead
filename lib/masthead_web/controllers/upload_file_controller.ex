defmodule MastheadWeb.UploadFileController do
  @moduledoc """
  Serves an upload's bytes from the admin host, so the admin's browser can read
  them into a canvas (compressing an image) without a cross-origin request to
  object storage. Scoped like the admin LiveViews: members of the site, or any
  platform admin.
  """
  use MastheadWeb, :controller

  alias Masthead.{Sites, Storage, Uploads}

  def show(conn, %{"site_slug" => slug, "id" => id}) do
    site = Sites.get_site_for_user_by_slug!(conn.assigns.current_user, slug)
    upload = Uploads.get_upload!(site.id, id)

    case Storage.read(upload.path) do
      {:ok, body} ->
        conn |> put_resp_content_type(upload.content_type, nil) |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 404, "")
    end
  end
end

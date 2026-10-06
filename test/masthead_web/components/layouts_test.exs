defmodule MastheadWeb.LayoutsTest do
  use MastheadWeb.ConnCase, async: false

  alias MastheadWeb.Layouts

  test "chatwoot_user is null when signed out" do
    assert Layouts.chatwoot_user(nil) == "null"
  end

  test "chatwoot_user escapes a hostile display name and signs the email" do
    System.put_env("CHATWOOT_HMAC_TOKEN", "key")
    on_exit(fn -> System.delete_env("CHATWOOT_HMAC_TOKEN") end)

    json = Layouts.chatwoot_user(%{display_name: "</script>", email: "a@b.co"})

    refute json =~ "</script>"

    assert Jason.decode!(json)["identifier_hash"] ==
             Base.encode16(:crypto.mac(:hmac, :sha256, "key", "a@b.co"), case: :lower)
  end

  test "the support chat widget only loads when CHATWOOT_WEBSITE_TOKEN is set", %{conn: conn} do
    System.delete_env("CHATWOOT_WEBSITE_TOKEN")
    assert chatwoot_loader(get(conn, ~p"/login")) == ""

    System.put_env("CHATWOOT_WEBSITE_TOKEN", "inbox-token")
    on_exit(fn -> System.delete_env("CHATWOOT_WEBSITE_TOKEN") end)
    assert chatwoot_loader(get(build_conn(), ~p"/login")) =~ ~s(websiteToken: "inbox-token")
  end

  defp chatwoot_loader(conn) do
    conn
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("#chatwoot-loader")
    |> LazyHTML.text()
  end
end

defmodule MastheadWeb.LayoutsTest do
  use ExUnit.Case, async: false

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
end

defmodule MastheadWeb.LayoutsTest do
  use ExUnit.Case, async: false

  alias MastheadWeb.Layouts

  test "tawk_visitor is undefined when signed out" do
    assert Layouts.tawk_visitor(nil) == "undefined"
  end

  test "tawk_visitor escapes a hostile display name and signs the email" do
    System.put_env("TAWK_API_KEY", "key")
    on_exit(fn -> System.delete_env("TAWK_API_KEY") end)

    json = Layouts.tawk_visitor(%{display_name: "</script>", email: "a@b.co"})

    refute json =~ "</script>"

    assert Jason.decode!(json)["hash"] ==
             Base.encode16(:crypto.mac(:hmac, :sha256, "key", "a@b.co"), case: :lower)
  end
end

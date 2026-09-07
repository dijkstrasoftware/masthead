defmodule SortDbgTest do
  use MastheadWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Masthead.Accounts

  test "sort flips" do
    {:ok, admin} = Accounts.register_user(%{"email" => "admin-x@example.com", "password" => "password1234"})
    {:ok, admin} = Accounts.set_admin(admin, true)
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, admin.id)
    {:ok, lv, _} = live(conn, ~p"/admin")

    for n <- 1..2 do
      html = lv |> element(~s(button[phx-value-scope="users"][phx-value-field="email"])) |> render_click()
      arrows = Regex.scan(~r/th-sort-arrow[^>]*>([^<]*)</, html) |> Enum.map(&List.last/1)
      IO.inspect({n, arrows}, label: "click")
    end
  end
end

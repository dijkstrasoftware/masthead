defmodule Masthead.AccountsOAuthTest do
  use Masthead.DataCase

  alias Masthead.Accounts
  alias Masthead.Accounts.User

  defp info(attrs) do
    Map.merge(
      %{
        provider: :google,
        uid: "uid-#{System.unique_integer([:positive])}",
        email: nil,
        email_verified: true
      },
      attrs
    )
  end

  test "creates a fresh, already-confirmed account + identity" do
    email = "new-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, user, :created} =
             Accounts.get_or_create_user_from_oauth(info(%{email: email, uid: "g1#{email}"}))

    assert user.email == email
    assert User.confirmed?(user)
  end

  test "a returning identity resolves to the same user" do
    email = "ret-#{System.unique_integer([:positive])}@example.com"
    i = info(%{email: email, uid: "g-ret-#{email}"})

    assert {:ok, u1, :created} = Accounts.get_or_create_user_from_oauth(i)
    assert {:ok, u2, :existing} = Accounts.get_or_create_user_from_oauth(i)
    assert u1.id == u2.id
  end

  test "links to an existing password account when the email is verified" do
    {:ok, existing} =
      Accounts.register_user(%{
        "email" => "link-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    assert {:ok, user, :existing} =
             Accounts.get_or_create_user_from_oauth(
               info(%{email: existing.email, uid: "gh-link", provider: :github})
             )

    assert user.id == existing.id
  end

  test "refuses to link to an existing account when the email is unverified" do
    {:ok, existing} =
      Accounts.register_user(%{
        "email" => "unv-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    assert {:error, :email_unverified} =
             Accounts.get_or_create_user_from_oauth(
               info(%{email: existing.email, uid: "g-unv", email_verified: false})
             )
  end

  test "a disabled account cannot sign in via OAuth (matched by email or identity)" do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "dis-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, _} = Accounts.disable_user(user)

    assert {:error, :disabled} =
             Accounts.get_or_create_user_from_oauth(info(%{email: user.email, uid: "g-dis"}))
  end

  test "no email from the provider is rejected" do
    assert {:error, :no_email} =
             Accounts.get_or_create_user_from_oauth(info(%{email: nil, uid: "g-noemail"}))
  end
end

defmodule Masthead.Workers.CreateContactTest do
  use Masthead.DataCase
  use Oban.Testing, repo: Masthead.Repo

  alias Masthead.{Accounts, Sites}
  alias Masthead.Workers.CreateContact

  defmodule CapturingContacts do
    @behaviour Masthead.Mailer

    @impl true
    def create_contact(contact, config) do
      send(config[:test_pid], {:contact, contact})
      :ok
    end
  end

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "cc-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    %{user: user}
  end

  defp create_site(user) do
    {:ok, site} =
      Sites.create_site(
        %{"slug" => "cc#{System.unique_integer([:positive])}", "name" => "CC"},
        user
      )

    site
  end

  test "creating sites enqueues one contact job per user", %{user: user} do
    create_site(user)
    create_site(user)

    assert [_one] = all_enqueued(worker: CreateContact, args: %{user_id: user.id})
  end

  test "sends the creator as a contact, unsubscribed when opted out", %{user: user} do
    config = Application.get_env(:masthead, Masthead.Mailer)
    on_exit(fn -> Application.put_env(:masthead, Masthead.Mailer, config) end)

    Application.put_env(
      :masthead,
      Masthead.Mailer,
      config ++ [contacts: CapturingContacts, test_pid: self()]
    )

    {:ok, user} = user |> Accounts.User.onboarding_emails_changeset(false) |> Repo.update()

    assert :ok = perform_job(CreateContact, %{user_id: user.id})

    assert_received {:contact, %{email: email, first_name: first_name, unsubscribed: true}}

    assert email == user.email
    assert first_name == user.display_name
  end
end

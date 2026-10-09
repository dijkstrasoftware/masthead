defmodule Masthead.Workers.OnboardingReminderTest do
  use Masthead.DataCase
  use Oban.Testing, repo: Masthead.Repo

  alias Masthead.{Accounts, Content, Sites, Actions}
  alias Masthead.Accounts.User
  alias Masthead.Actions.Action
  alias Masthead.Workers.{Email, OnboardingReminder}

  setup do
    Masthead.Themes.Seed.run()
    :ok
  end

  defp confirmed_user do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "or-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, user} = user |> User.confirm_changeset() |> Repo.update()
    user
  end

  defp site_for(user) do
    {:ok, site} =
      Sites.create_site(%{
        "slug" => "or#{System.unique_integer([:positive])}",
        "name" => "OR Test",
        "owner_id" => user.id
      })

    site
  end

  # Push an action's inserted_at into the past so it's older than the cutoff.
  defp backdate(site, key, days) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(a in Action, where: a.site_id == ^site.id and a.key == ^key),
      set: [inserted_at: cutoff]
    )
  end

  # In these tests the worker is the only thing that enqueues mail, so every
  # queued Email job is a reminder (no need to match on subject wording).
  defp reminder_emails, do: all_enqueued(worker: Email)

  test "reminds the owner about an action open for over a week" do
    user = confirmed_user()
    site = site_for(user)
    backdate(site, "create_first_post", 8)

    assert :ok = perform_job(OnboardingReminder, %{})

    assert [job] = reminder_emails()
    assert job.args["to"] == user.email
    refute is_nil(Repo.get_by!(Action, site_id: site.id, key: "create_first_post").reminded_at)
  end

  test "never reminds twice for the same action" do
    user = confirmed_user()
    site = site_for(user)
    backdate(site, "create_first_post", 8)

    perform_job(OnboardingReminder, %{})
    perform_job(OnboardingReminder, %{})

    assert length(reminder_emails()) == 1
  end

  test "ignores actions younger than a week" do
    user = confirmed_user()
    _site = site_for(user)

    perform_job(OnboardingReminder, %{})
    assert reminder_emails() == []
  end

  test "ignores non-remindable action types" do
    # set_description is not remindable; unlock it via content, then clear the
    # remindable content actions so only set_description remains pending.
    user = confirmed_user()
    site = site_for(user)
    {:ok, _post} = Content.create_post(site.id, %{"title" => "Hi", "slug" => "hi"})
    :ok = Actions.dismiss_action(site, "create_first_page")
    backdate(site, "set_description", 8)

    perform_job(OnboardingReminder, %{})
    assert reminder_emails() == []
  end

  test "ignores completed or dismissed actions" do
    user = confirmed_user()
    site = site_for(user)
    backdate(site, "create_first_post", 8)
    :ok = Actions.dismiss_action(site, "create_first_post")

    perform_job(OnboardingReminder, %{})
    assert reminder_emails() == []
  end

  test "skips unconfirmed owners" do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "unconf-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    site = site_for(user)
    backdate(site, "create_first_post", 8)

    perform_job(OnboardingReminder, %{})
    assert reminder_emails() == []
  end

  test "skips owners who unsubscribed" do
    user = confirmed_user()
    site = site_for(user)
    backdate(site, "create_first_post", 8)
    :ok = Accounts.unsubscribe_onboarding_emails(user.id)

    perform_job(OnboardingReminder, %{})
    assert reminder_emails() == []
  end

  test "sends one email per site (grouped by site)" do
    user = confirmed_user()
    s1 = site_for(user)
    s2 = site_for(user)
    backdate(s1, "create_first_post", 8)
    backdate(s2, "create_first_post", 8)

    perform_job(OnboardingReminder, %{})
    assert length(reminder_emails()) == 2
  end

  test "groups a single site's multiple due actions into one email" do
    user = confirmed_user()
    site = site_for(user)
    # both content actions are remindable; make both due (default-theme sites
    # don't seed create_first_page, so add it here)
    {:ok, _} = Actions.create_action(site, "create_first_page")
    backdate(site, "create_first_post", 8)
    backdate(site, "create_first_page", 8)

    perform_job(OnboardingReminder, %{})

    assert [job] = reminder_emails()
    assert job.args["text_body"] =~ "Create your first post"
    assert job.args["text_body"] =~ "Create your first page"
  end
end

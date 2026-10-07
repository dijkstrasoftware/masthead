defmodule Masthead.Workers.CreateContact do
  @moduledoc """
  Adds a site creator to the mail provider's contacts (see
  `Masthead.Mailer.create_contact/1`) so templates/broadcasts can reach them.
  Enqueued by `Masthead.Sites.create_site/2`; unique per user, so a second
  site doesn't create the contact again (until Oban prunes the old job).

  `unsubscribed` mirrors the user's onboarding-email opt-out at enqueue time.
  """
  use Oban.Worker, queue: :mailers, max_attempts: 5, unique: [keys: [:user_id], period: :infinity]

  import Ecto.Query

  alias Masthead.Accounts.User
  alias Masthead.Mailer
  alias Masthead.Repo
  alias Masthead.Sites.SiteMembership

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.get(User, user_id) do
      # Deleted (e.g. unconfirmed-account sweep) before the job ran.
      nil ->
        :ok

      user ->
        Mailer.create_contact(%{
          email: user.email,
          first_name: user.display_name,
          unsubscribed: not user.wants_onboarding_emails
        })
    end
  end

  @doc """
  One-off backfill for users who created a site before contacts existed.
  Needs the running app (Oban), so in prod:

      fly ssh console -C '/app/bin/masthead rpc "Masthead.Workers.CreateContact.backfill()"'

  Safe to re-run: the unique constraint skips users already enqueued.
  """
  def backfill do
    from(m in SiteMembership, distinct: true, select: m.user_id)
    |> Repo.all()
    |> Enum.each(&Oban.insert!(new(%{user_id: &1})))
  end
end

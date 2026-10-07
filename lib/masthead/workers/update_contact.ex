defmodule Masthead.Workers.UpdateContact do
  @moduledoc """
  Pushes a user's email opt-in/out to the mail provider's contact (see
  `Masthead.Accounts.set_product_emails/2`). Reads the user when it runs, so
  a quick on/off/on lands on the latest choice whatever order jobs finish in.
  """
  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias Masthead.Accounts.User
  alias Masthead.Mailer
  alias Masthead.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Repo.get(User, user_id) do
      nil ->
        :ok

      user ->
        Mailer.update_contact(%{
          email: user.email,
          unsubscribed: not user.wants_onboarding_emails
        })
    end
  end
end

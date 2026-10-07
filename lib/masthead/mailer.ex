defmodule Masthead.Mailer do
  @moduledoc """
  Transactional mailer. Adapter is environment-specific (configured in
  `config/*.exs`): `Swoosh.Adapters.Local` in dev, `Swoosh.Adapters.Test`
  in test, `Swoosh.Adapters.Resend` in prod.

  Mail is not sent directly from request paths — `Masthead.Accounts.UserNotifier`
  enqueues an `Masthead.Workers.Email` Oban job so a transient provider failure
  retries instead of losing a confirmation/reset email.

  Contacts (the provider's audience list, used for templates/broadcasts) sit
  next to the Swoosh adapter in the same config:

      config :masthead, Masthead.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: "...",
        contacts: Masthead.Mailer.ResendContacts

  No `:contacts` key (dev, test, self-hosters on another provider) makes the
  contact functions no-ops. Switching provider means swapping both modules.
  """
  use Swoosh.Mailer, otp_app: :masthead

  @type contact :: %{
          required(:email) => String.t(),
          optional(:first_name) => String.t() | nil,
          optional(:last_name) => String.t() | nil,
          optional(:unsubscribed) => boolean()
        }

  @doc """
  Creates `contact` at the provider. `config` is this mailer's config (so
  the adapter can reuse the API key). `{:cancel, reason}` = don't retry.
  """
  @callback create_contact(contact(), config :: keyword()) ::
              :ok | {:error, term()} | {:cancel, term()}

  @doc "Updates the existing contact with `contact.email`. Same return contract."
  @callback update_contact(contact(), config :: keyword()) ::
              :ok | {:error, term()} | {:cancel, term()}

  def create_contact(contact), do: contacts(:create_contact, contact)
  def update_contact(contact), do: contacts(:update_contact, contact)

  defp contacts(fun, contact) do
    config = Application.get_env(:masthead, __MODULE__, [])

    case config[:contacts] do
      nil -> :ok
      adapter -> apply(adapter, fun, [contact, config])
    end
  end

  @doc """
  The `{name, address}` tuple all Masthead mail is sent from.
  Overridden in prod via the `MAIL_FROM` env var (see runtime.exs).
  """
  def from do
    Application.fetch_env!(:masthead, :mail_from)
  end
end

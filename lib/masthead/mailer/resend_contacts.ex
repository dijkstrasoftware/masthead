defmodule Masthead.Mailer.ResendContacts do
  @moduledoc """
  Resend contacts (`POST https://api.resend.com/contacts`). Reuses the
  mailer's `:api_key`, which needs full access — a sending-only key gets 401.
  """
  @behaviour Masthead.Mailer

  @endpoint "https://api.resend.com/contacts"

  @impl true
  def create_contact(contact, config) do
    body =
      contact
      |> Map.take([:email, :first_name, :last_name, :unsubscribed])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Jason.encode!()

    headers = [
      {"Authorization", "Bearer #{Keyword.fetch!(config, :api_key)}"},
      {"Content-Type", "application/json"}
    ]

    case :hackney.request(:post, @endpoint, headers, body, [:with_body, recv_timeout: 15_000]) do
      {:ok, status, _headers, _resp} when status in 200..299 ->
        :ok

      # Rate limit: worth retrying. Other 4xx (bad key, invalid email,
      # existing contact) won't fix themselves.
      {:ok, 429, _headers, resp} ->
        {:error, "Resend rate limited: #{resp}"}

      {:ok, status, _headers, resp} when status in 400..499 ->
        {:cancel, "Resend returned HTTP #{status}: #{resp}"}

      {:ok, status, _headers, resp} ->
        {:error, "Resend returned HTTP #{status}: #{resp}"}

      {:error, reason} ->
        {:error, "could not reach Resend: #{inspect(reason)}"}
    end
  end
end

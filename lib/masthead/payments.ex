defmodule Masthead.Payments do
  @moduledoc """
  Behaviour for the payment provider. The real adapter (`Stripe`) talks to
  Stripe Checkout and the Stripe billing portal; dev/test use `Stub`.

  Three callbacks, which is the whole surface a hosted-checkout provider needs:

    * `checkout_url/1` — the only way money enters.
    * `portal_url/1` — cancel, update card, invoice history. This is why there
      is no `cancel_subscription/1` or `update_payment_method/1`.
    * `parse_event/2` — verifies the webhook signature *and* normalises the
      payload, because you cannot normalise what you have not authenticated.
      It takes the raw header list so the signature header's name stays a
      provider detail.

  Params and events are plain maps, never `%Site{}` — the adapter has no
  business knowing about Ecto schemas.
  """

  @type event :: %{
          type: :active | :canceled,
          site_id: integer(),
          plan: String.t() | nil,
          status: String.t(),
          customer_id: String.t() | nil,
          subscription_id: String.t() | nil,
          cancels_at_period_end: boolean(),
          expires_at: DateTime.t() | nil
        }

  @callback checkout_url(map()) :: {:ok, String.t()} | {:error, String.t()}
  @callback portal_url(map()) :: {:ok, String.t()} | {:error, String.t()}
  @callback parse_event(binary(), [{String.t(), String.t()}]) ::
              {:ok, event()} | :ignore | {:error, String.t()}

  def adapter do
    Application.get_env(:masthead, :payments, Masthead.Payments.Stripe)
  end

  def checkout_url(params), do: adapter().checkout_url(params)
  def portal_url(params), do: adapter().portal_url(params)
  def parse_event(body, headers), do: adapter().parse_event(body, headers)
end

defmodule Masthead.Payments.Stripe do
  @moduledoc """
  Real Stripe client, over `:hackney` (the app's only HTTP client). Stripe's
  REST API is form-encoded in, JSON out. Requires:

    * `STRIPE_SECRET_KEY` — the secret API key
    * `STRIPE_WEBHOOK_SECRET` — the endpoint's signing secret (`whsec_…`)

  Neither is required at boot: an install without them runs fine and simply
  cannot sell, the same posture as custom domains without `FLY_API_TOKEN`.

  Two Stripe quirks are handled here so nothing else has to know about them.
  A `Stripe-Signature` header carries more than one `v1=` while a signing
  secret is being rotated, so any one of them matching is enough. And Stripe
  moved `current_period_end` from the subscription root onto each item in API
  version 2025-03-31, so both locations are read — which one arrives depends
  on the version pinned by the account sending the webhook.
  """
  @behaviour Masthead.Payments

  @base "https://api.stripe.com/v1"
  @tolerance 300

  @impl true
  def checkout_url(%{site_id: site_id, amount: amount, interval: interval} = params) do
    body =
      [
        {"mode", "subscription"},
        {"success_url", params.return_url <> "?checkout=success"},
        {"cancel_url", params.return_url},
        {"client_reference_id", to_string(site_id)},
        {"subscription_data[metadata][site_id]", to_string(site_id)},
        {"subscription_data[metadata][plan]", params.plan},
        {"line_items[0][quantity]", "1"},
        {"line_items[0][price_data][currency]", params.currency},
        {"line_items[0][price_data][unit_amount]", to_string(amount)},
        {"line_items[0][price_data][recurring][interval]", interval},
        {"line_items[0][price_data][product_data][name]", params.product_name}
      ] ++ customer_param(params)

    with {:ok, session} <- post("/checkout/sessions", body), do: fetch_url(session)
  end

  @impl true
  def portal_url(%{customer_id: nil}), do: {:error, "this site has no billing account yet"}

  def portal_url(%{customer_id: customer_id, return_url: return_url}) do
    body = [{"customer", customer_id}, {"return_url", return_url}]

    with {:ok, session} <- post("/billing_portal/sessions", body), do: fetch_url(session)
  end

  @impl true
  def parse_event(raw_body, headers) do
    with {:ok, secret} <- webhook_secret(),
         {:ok, timestamp, signatures} <- split_signature(headers),
         :ok <- check_freshness(timestamp),
         :ok <- check_mac(secret, timestamp, raw_body, signatures),
         {:ok, json} <- Jason.decode(raw_body) do
      normalize(json)
    end
  end

  defp customer_param(%{customer_id: id}) when is_binary(id), do: [{"customer", id}]
  defp customer_param(_params), do: []

  defp fetch_url(%{"url" => url}) when is_binary(url), do: {:ok, url}
  defp fetch_url(_body), do: {:error, "the payment provider returned no checkout link"}

  defp split_signature(headers) do
    parts =
      for {"stripe-signature", value} <- headers,
          pair <- String.split(value, ","),
          [key, part] <- [String.split(String.trim(pair), "=", parts: 2)],
          do: {key, part}

    case {List.keyfind(parts, "t", 0), for({"v1", part} <- parts, do: part)} do
      {{"t", timestamp}, [_ | _] = signatures} -> {:ok, timestamp, signatures}
      _ -> {:error, "missing or malformed signature header"}
    end
  end

  defp check_freshness(timestamp) do
    case Integer.parse(timestamp) do
      {sent, ""} -> within_tolerance(sent)
      _ -> {:error, "malformed webhook timestamp"}
    end
  end

  defp within_tolerance(sent) do
    if abs(sent - System.system_time(:second)) <= @tolerance,
      do: :ok,
      else: {:error, "webhook timestamp outside the tolerance window"}
  end

  defp check_mac(secret, timestamp, raw_body, signatures) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, secret, timestamp <> "." <> raw_body)
      |> Base.encode16(case: :lower)

    if Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
      do: :ok,
      else: {:error, "invalid webhook signature"}
  end

  defp normalize(%{"type" => "customer.subscription." <> _, "data" => %{"object" => object}}) do
    case site_id(object) do
      nil -> :ignore
      site_id -> {:ok, subscription_event(object, site_id)}
    end
  end

  defp normalize(_json), do: :ignore

  defp subscription_event(object, site_id) do
    status = object["status"]

    %{
      type: if(status in ~w(active trialing past_due), do: :active, else: :canceled),
      site_id: site_id,
      plan: get_in(object, ["metadata", "plan"]),
      status: status,
      customer_id: object["customer"],
      subscription_id: object["id"],
      cancels_at_period_end: object["cancel_at_period_end"] == true,
      expires_at: period_end(object)
    }
  end

  defp site_id(object) do
    case Integer.parse(get_in(object, ["metadata", "site_id"]) || "") do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp period_end(object) do
    seconds =
      object["current_period_end"] ||
        get_in(object, ["items", "data", Access.at(0), "current_period_end"])

    case seconds do
      n when is_integer(n) -> n |> DateTime.from_unix!() |> DateTime.truncate(:second)
      _ -> nil
    end
  end

  defp post(path, params) do
    with {:ok, key} <- secret_key() do
      headers = [
        {"Authorization", "Bearer " <> key},
        {"Content-Type", "application/x-www-form-urlencoded"}
      ]

      request(@base <> path, headers, URI.encode_query(params))
    end
  end

  defp request(url, headers, body) do
    case :hackney.request(:post, url, headers, body, [:with_body, recv_timeout: 15_000]) do
      {:ok, status, _headers, resp} when status in 200..299 -> Jason.decode(resp)
      {:ok, _status, _headers, resp} -> {:error, error_message(resp)}
      {:error, reason} -> {:error, "could not reach the payment provider: #{inspect(reason)}"}
    end
  end

  defp error_message(resp) do
    case Jason.decode(resp) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> "the payment provider rejected the request"
    end
  end

  defp secret_key, do: env("STRIPE_SECRET_KEY")
  defp webhook_secret, do: env("STRIPE_WEBHOOK_SECRET")

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "billing is not configured"}
    end
  end
end

defmodule Masthead.Payments.Stub do
  @moduledoc """
  Dev/test payment adapter. Returns canned links and decodes webhook bodies
  without checking a signature. Scripted per test through
  `Application.put_env(:masthead, :payments_stub, %{...})`.
  """
  @behaviour Masthead.Payments

  @impl true
  def checkout_url(_params), do: stub(:checkout_url, "https://checkout.test/session")

  @impl true
  def portal_url(%{customer_id: nil}), do: {:error, "this site has no billing account yet"}
  def portal_url(_params), do: stub(:portal_url, "https://billing.test/portal")

  @impl true
  def parse_event(raw_body, _headers) do
    case Application.get_env(:masthead, :payments_stub, %{}) do
      %{event: event} -> event
      _ -> decode(raw_body)
    end
  end

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => "active"} = event} -> {:ok, build(event, :active)}
      {:ok, %{"type" => "canceled"} = event} -> {:ok, build(event, :canceled)}
      {:ok, _other} -> :ignore
      {:error, _reason} -> {:error, "invalid webhook body"}
    end
  end

  defp build(event, type) do
    %{
      type: type,
      site_id: event["site_id"],
      plan: event["plan"],
      status: event["status"] || to_string(type),
      customer_id: event["customer_id"],
      subscription_id: event["subscription_id"],
      cancels_at_period_end: event["cancels_at_period_end"] == true,
      expires_at: expires_at(event["expires_at"])
    }
  end

  defp expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _reason} -> nil
    end
  end

  defp expires_at(_value), do: nil

  defp stub(key, default) do
    case Map.get(Application.get_env(:masthead, :payments_stub, %{}), key, default) do
      {:error, _reason} = error -> error
      url -> {:ok, url}
    end
  end
end

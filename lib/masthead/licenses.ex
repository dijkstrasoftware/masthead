defmodule Masthead.Licenses do
  @moduledoc """
  Per-site licensing. A site is either *free* (forever, no expiry) or
  *licensed* — an active subscription with a period end.

  `paid?/1` is the single source of truth: every gate and every badge routes
  through it, so there is exactly one definition of "is this site paid".

  Prices come from the environment as amounts in cents, so a deployment sets
  a number rather than provisioning products at the provider (the Stripe
  adapter mints the price inline per checkout).
  """
  import Ecto.Query

  alias Masthead.{Payments, Realtime, Repo}
  alias Masthead.Sites.Site

  @plans %{
    "monthly" => %{
      interval: "month",
      var: "LICENSE_PRICE_MONTHLY_CENTS",
      default: 500,
      label: "month"
    },
    "yearly" => %{
      interval: "year",
      var: "LICENSE_PRICE_YEARLY_CENTS",
      default: 5000,
      label: "year"
    }
  }

  @product_name "Masthead site license"

  @doc "True while the site has an active subscription that has not run out."
  def paid?(%Site{license_status: status, license_expires_at: %DateTime{} = at})
      when status in ~w(active canceling),
      do: DateTime.after?(at, DateTime.utc_now())

  def paid?(%Site{}), do: false

  @doc """
  Cancelling leaves the site licensed until the period it already paid for
  runs out, so `paid?/1` stays true and this is what flags the wind-down.
  """
  def canceled?(%Site{license_status: "canceling"} = site), do: paid?(site)
  def canceled?(%Site{}), do: false

  @doc "Plans keyed by name, each with its price in cents. Ordered monthly first."
  def plans do
    Enum.map(~w(monthly yearly), fn name ->
      plan = @plans[name]
      {name, %{plan | var: nil} |> Map.put(:amount, amount(name)) |> Map.put(:name, name)}
    end)
  end

  def amount(name) do
    %{var: var, default: default} = @plans[name]

    case Integer.parse(System.get_env(var) || "") do
      {cents, ""} when cents > 0 -> cents
      _ -> default
    end
  end

  def currency, do: System.get_env("LICENSE_CURRENCY", "eur")

  @doc "Formats an amount in cents for display, e.g. `500` -> `\"€5\"`."
  def format(cents) do
    symbol() <>
      if rem(cents, 100) == 0,
        do: Integer.to_string(div(cents, 100)),
        else: :erlang.float_to_binary(cents / 100, decimals: 2)
  end

  @doc """
  Cents saved over a year by paying yearly instead of monthly, or nil when
  the yearly plan is not actually cheaper.
  """
  def yearly_saving do
    saving = 12 * amount("monthly") - amount("yearly")
    if saving > 0, do: saving
  end

  @doc "Short status word for the overview chip and the settings section."
  def label(%Site{} = site), do: if(paid?(site), do: "Paid", else: "Free")

  def pill_class(%Site{} = site) do
    cond do
      canceled?(site) -> "pill-warn"
      paid?(site) -> "pill-ok"
      true -> "pill-draft"
    end
  end

  @doc "Starts a checkout for `plan`, returning the provider's hosted URL."
  def checkout_url(%Site{} = site, plan, return_url) when is_map_key(@plans, plan) do
    Payments.checkout_url(%{
      site_id: site.id,
      plan: plan,
      interval: @plans[plan].interval,
      amount: amount(plan),
      currency: currency(),
      product_name: @product_name,
      customer_id: site.payment_customer_id,
      return_url: return_url
    })
  end

  @doc "Opens the provider's hosted billing portal to cancel or update a card."
  def portal_url(%Site{} = site, return_url) do
    Payments.portal_url(%{customer_id: site.payment_customer_id, return_url: return_url})
  end

  @doc """
  Verifies and applies one provider webhook. `:ok` for events we deliberately
  ignore, so the provider is never told to retry them.
  """
  def handle_webhook(raw_body, headers) do
    case Payments.parse_event(raw_body, headers) do
      {:ok, event} -> apply_event(event)
      :ignore -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes a normalised subscription event onto its site. Every field is an
  absolute overwrite of derived state and `license_expires_at` self-expires,
  so a replayed or out-of-order delivery heals itself — which is why there is
  no processed-events table.
  """
  def apply_event(%{site_id: site_id} = event) do
    case Repo.get(Site, site_id) do
      nil -> {:error, "webhook for unknown site #{site_id}"}
      site -> write(site, event)
    end
  end

  defp write(site, event) do
    changes = [
      license_status: status_for(event),
      license_expires_at: event.expires_at,
      license_plan: event.plan || site.license_plan,
      payment_customer_id: event.customer_id,
      payment_subscription_id: event.subscription_id
    ]

    site |> Ecto.Changeset.change(changes) |> Repo.update() |> announce()
  end

  defp announce({:ok, site} = result) do
    Realtime.settings_changed(site.id)
    result
  end

  defp announce(result), do: result

  defp status_for(%{type: :canceled}), do: "canceled"
  defp status_for(%{status: "past_due"}), do: "past_due"
  defp status_for(%{cancels_at_period_end: true}), do: "canceling"
  defp status_for(%{type: :active}), do: "active"

  @doc """
  Extends a site's license by `months` without a provider subscription.

  Adds onto the existing expiry when the site is already paid, so gifting a
  paying customer tops them up rather than cutting them short. Calendar
  months, not 30-day blocks.
  """
  def gift(%Site{} = site, months) when is_integer(months) and months > 0 do
    base = if paid?(site), do: site.license_expires_at, else: DateTime.utc_now()

    site
    |> Ecto.Changeset.change(
      license_status: "active",
      license_plan: site.license_plan || "gift",
      license_expires_at: base |> DateTime.shift(month: months) |> DateTime.truncate(:second)
    )
    |> Repo.update()
    |> announce()
  end

  @doc "True when the site has a provider customer, so the billing portal can open."
  def billable?(%Site{payment_customer_id: id}), do: not is_nil(id)

  @doc "Licenses `site` until `expires_at` without touching a provider. Seeds and tests."
  def grant(%Site{} = site, plan \\ "yearly", expires_at \\ nil) do
    expires_at =
      expires_at || DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.truncate(:second)

    site
    |> Ecto.Changeset.change(
      license_status: "active",
      license_plan: plan,
      license_expires_at: expires_at
    )
    |> Repo.update()
    |> announce()
  end

  @doc "Sites whose license lapsed before `at`. Not used in-app yet; handy from IEx."
  def expired(at \\ DateTime.utc_now()) do
    Repo.all(from s in Site, where: s.license_expires_at < ^at and is_nil(s.deleted_at))
  end

  defp symbol do
    %{"eur" => "€", "usd" => "$", "gbp" => "£"}[currency()] || String.upcase(currency()) <> " "
  end
end

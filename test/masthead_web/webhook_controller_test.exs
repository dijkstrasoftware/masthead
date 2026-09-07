defmodule MastheadWeb.WebhookControllerTest do
  use MastheadWeb.ConnCase

  alias Masthead.{Accounts, Licenses, Sites}

  @secret "whsec_test_secret"

  setup do
    Masthead.Themes.Seed.run()
    Application.put_env(:masthead, :payments, Masthead.Payments.Stripe)
    System.put_env("STRIPE_WEBHOOK_SECRET", @secret)

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "wh-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "wh#{System.unique_integer([:positive])}",
        "name" => "Webhook Test",
        "owner_id" => user.id
      })

    on_exit(fn ->
      Application.put_env(:masthead, :payments, Masthead.Payments.Stub)
      System.delete_env("STRIPE_WEBHOOK_SECRET")
    end)

    %{site: site}
  end

  defp subscription_body(site, overrides \\ %{}) do
    object =
      Map.merge(
        %{
          "id" => "sub_live",
          "status" => "active",
          "customer" => "cus_live",
          "current_period_end" =>
            DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix(),
          "cancel_at_period_end" => false,
          "metadata" => %{"site_id" => to_string(site.id), "plan" => "yearly"}
        },
        overrides
      )

    Jason.encode!(%{"type" => "customer.subscription.updated", "data" => %{"object" => object}})
  end

  defp sign(body, timestamp \\ nil, secret \\ @secret) do
    timestamp = timestamp || Integer.to_string(System.system_time(:second))

    signature =
      :hmac
      |> :crypto.mac(:sha256, secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp post_webhook(conn, body, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> post(~p"/webhooks/payments", body)
  end

  test "a correctly signed subscription event licenses the site", %{conn: conn, site: site} do
    body = subscription_body(site)

    assert post_webhook(conn, body, sign(body)).status == 200

    site = Sites.get_site!(site.id)
    assert Licenses.paid?(site)
    assert site.license_plan == "yearly"
    assert site.payment_customer_id == "cus_live"
    assert site.payment_subscription_id == "sub_live"
  end

  test "the period end is also read from the subscription item", %{conn: conn, site: site} do
    ends = DateTime.utc_now() |> DateTime.add(60, :day) |> DateTime.to_unix()

    body =
      subscription_body(site, %{
        "current_period_end" => nil,
        "items" => %{"data" => [%{"current_period_end" => ends}]}
      })

    assert post_webhook(conn, body, sign(body)).status == 200
    assert Licenses.paid?(Sites.get_site!(site.id))
  end

  test "a tampered body is rejected", %{conn: conn, site: site} do
    body = subscription_body(site)
    signature = sign(body)

    assert post_webhook(conn, body <> " ", signature).status == 400
    refute Licenses.paid?(Sites.get_site!(site.id))
  end

  test "a signature from the wrong secret is rejected", %{conn: conn, site: site} do
    body = subscription_body(site)

    assert post_webhook(conn, body, sign(body, nil, "whsec_wrong")).status == 400
    refute Licenses.paid?(Sites.get_site!(site.id))
  end

  test "a stale timestamp is rejected", %{conn: conn, site: site} do
    body = subscription_body(site)
    stale = Integer.to_string(System.system_time(:second) - 3600)

    assert post_webhook(conn, body, sign(body, stale)).status == 400
    refute Licenses.paid?(Sites.get_site!(site.id))
  end

  test "a missing signature header is rejected", %{conn: conn, site: site} do
    body = subscription_body(site)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/payments", body)

    assert response.status == 400
  end

  test "an event type we ignore is accepted and changes nothing", %{conn: conn, site: site} do
    body = Jason.encode!(%{"type" => "invoice.paid", "data" => %{"object" => %{}}})

    assert post_webhook(conn, body, sign(body)).status == 200
    refute Licenses.paid?(Sites.get_site!(site.id))
  end

  test "a subscription without our site metadata is ignored", %{conn: conn, site: site} do
    body = subscription_body(site, %{"metadata" => %{}})

    assert post_webhook(conn, body, sign(body)).status == 200
    refute Licenses.paid?(Sites.get_site!(site.id))
  end
end

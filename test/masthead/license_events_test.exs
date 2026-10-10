defmodule Masthead.LicenseEventsTest do
  use Masthead.DataCase

  import Ecto.Query

  alias Masthead.{Accounts, Licenses, Sites}
  alias Masthead.Licenses.Event

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "lev-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "lev#{System.unique_integer([:positive])}",
        "name" => "License Events Test",
        "owner_id" => user.id
      })

    %{site: site}
  end

  defp at(days), do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)

  defp event(site, overrides) do
    Map.merge(
      %{
        type: :active,
        site_id: site.id,
        plan: "monthly",
        status: "active",
        customer_id: "cus_1",
        subscription_id: "sub_1",
        cancels_at_period_end: false,
        expires_at: at(30)
      },
      overrides
    )
  end

  defp events(site) do
    Repo.all(from e in Event, where: e.site_id == ^site.id, order_by: e.id)
  end

  defp kinds(site), do: Enum.map(events(site), & &1.kind)

  test "the first active webhook records a started stripe event", %{site: site} do
    {:ok, _} = Licenses.apply_event(event(site, %{}))

    assert [%Event{kind: "started", source: "stripe", plan: "monthly", status: "active"} = e] =
             events(site)

    assert e.amount_cents == Licenses.amount("monthly")
    assert e.currency == Licenses.currency()
  end

  test "an identical redelivery writes no new row", %{site: site} do
    payload = event(site, %{})
    {:ok, _} = Licenses.apply_event(payload)
    {:ok, _} = Licenses.apply_event(payload)

    assert kinds(site) == ["started"]
  end

  test "cancel at period end, then cancellation", %{site: site} do
    {:ok, _} = Licenses.apply_event(event(site, %{}))
    {:ok, _} = Licenses.apply_event(event(site, %{cancels_at_period_end: true}))

    {:ok, _} =
      Licenses.apply_event(
        event(site, %{type: :canceled, status: "canceled", expires_at: at(-1)})
      )

    assert kinds(site) == ["started", "canceling", "canceled"]
  end

  test "a renewal records renewed", %{site: site} do
    {:ok, _} = Licenses.apply_event(event(site, %{expires_at: at(1)}))
    {:ok, _} = Licenses.apply_event(event(site, %{expires_at: at(31)}))

    assert kinds(site) == ["started", "renewed"]
  end

  test "gift records gifted, not stripe", %{site: site} do
    {:ok, _} = Licenses.gift(site, 3)

    assert [%Event{kind: "gifted", source: "gift", amount_cents: 0}] = events(site)
  end

  test "grant records granted", %{site: site} do
    {:ok, _} = Licenses.grant(site)

    assert [%Event{kind: "granted", source: "grant", amount_cents: 0, plan: "yearly"}] =
             events(site)
  end
end

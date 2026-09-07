defmodule Masthead.LicensesTest do
  use Masthead.DataCase

  alias Masthead.{Accounts, Licenses, Sites}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "lic-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "lic#{System.unique_integer([:positive])}",
        "name" => "License Test",
        "owner_id" => user.id
      })

    on_exit(fn ->
      System.delete_env("LICENSE_PRICE_MONTHLY")
      System.delete_env("LICENSE_PRICE_YEARLY")
      System.delete_env("LICENSE_CURRENCY")
    end)

    %{site: site, user: user}
  end

  defp at(days), do: DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)

  defp with_license(site, attrs) do
    site |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  describe "paid?/1" do
    test "a fresh site is free", %{site: site} do
      refute Licenses.paid?(site)
      assert Licenses.chip(site) == "Free"
      assert Licenses.label(site) == "Free"
    end

    test "active with a future expiry is paid", %{site: site} do
      site = with_license(site, license_status: "active", license_expires_at: at(30))

      assert Licenses.paid?(site)
      assert Licenses.chip(site) == "Licensed"
    end

    test "active with a past expiry is free again", %{site: site} do
      site = with_license(site, license_status: "active", license_expires_at: at(-1))

      refute Licenses.paid?(site)
    end

    test "active with no expiry is free", %{site: site} do
      refute Licenses.paid?(with_license(site, license_status: "active"))
    end

    test "a cancellation stays paid until the period it bought runs out", %{site: site} do
      site = with_license(site, license_status: "canceling", license_expires_at: at(10))

      assert Licenses.paid?(site)
      assert Licenses.canceled?(site)
      assert Licenses.pill_class(site) == "pill-warn"
    end

    test "a cancellation past its expiry is free", %{site: site} do
      site = with_license(site, license_status: "canceling", license_expires_at: at(-10))

      refute Licenses.paid?(site)
      refute Licenses.canceled?(site)
    end

    test "past_due is not paid", %{site: site} do
      refute Licenses.paid?(
               with_license(site, license_status: "past_due", license_expires_at: at(5))
             )
    end
  end

  describe "apply_event/1" do
    defp event(site, overrides) do
      Map.merge(
        %{
          type: :active,
          site_id: site.id,
          plan: "monthly",
          status: "active",
          customer_id: "cus_1",
          subscription_id: "sub_#{System.unique_integer([:positive])}",
          cancels_at_period_end: false,
          expires_at: at(30)
        },
        overrides
      )
    end

    test "an active event licenses the site", %{site: site} do
      assert {:ok, site} = Licenses.apply_event(event(site, %{}))

      assert Licenses.paid?(site)
      assert site.license_plan == "monthly"
      assert site.payment_customer_id == "cus_1"
      assert Licenses.label(site) == "Licensed — monthly"
    end

    test "a renewal pushes the expiry out", %{site: site} do
      {:ok, site} = Licenses.apply_event(event(site, %{expires_at: at(1)}))
      {:ok, renewed} = Licenses.apply_event(event(site, %{expires_at: at(31)}))

      assert DateTime.after?(renewed.license_expires_at, site.license_expires_at)
    end

    test "past_due keeps the plan but drops paid status", %{site: site} do
      {:ok, site} = Licenses.apply_event(event(site, %{status: "past_due"}))

      assert site.license_status == "past_due"
      refute Licenses.paid?(site)
    end

    test "cancel-at-period-end keeps the site licensed until it lapses", %{site: site} do
      {:ok, site} = Licenses.apply_event(event(site, %{cancels_at_period_end: true}))

      assert site.license_status == "canceling"
      assert Licenses.paid?(site)
      assert Licenses.canceled?(site)
    end

    test "a deleted subscription ends the license", %{site: site} do
      {:ok, site} =
        Licenses.apply_event(
          event(site, %{type: :canceled, status: "canceled", expires_at: at(-1)})
        )

      assert site.license_status == "canceled"
      refute Licenses.paid?(site)
    end

    test "a replayed stale event cannot resurrect an expired license", %{site: site} do
      {:ok, _site} = Licenses.apply_event(event(site, %{type: :canceled, expires_at: at(-1)}))
      {:ok, site} = Licenses.apply_event(event(site, %{expires_at: at(-1)}))

      refute Licenses.paid?(site)
    end

    test "an event for an unknown site is an error", %{site: site} do
      assert {:error, _reason} = Licenses.apply_event(event(site, %{site_id: -1}))
    end
  end

  describe "prices" do
    test "default to 5 a month and 50 a year" do
      assert Licenses.amount("monthly") == 500
      assert Licenses.amount("yearly") == 5000
      assert Licenses.format(500) == "€5"
    end

    test "come from the environment when set" do
      System.put_env("LICENSE_PRICE_MONTHLY", "900")
      System.put_env("LICENSE_CURRENCY", "usd")

      assert Licenses.amount("monthly") == 900
      assert Licenses.format(900) == "$9"
      assert Licenses.format(1250) == "$12.50"
    end

    test "fall back to the default when unparseable" do
      System.put_env("LICENSE_PRICE_MONTHLY", "free please")

      assert Licenses.amount("monthly") == 500
    end

    test "plans/0 lists monthly first, then yearly" do
      assert [{"monthly", monthly}, {"yearly", yearly}] = Licenses.plans()
      assert monthly.label == "month"
      assert yearly.amount == 5000
    end
  end

  describe "gating" do
    test "a free site cannot set a custom domain", %{site: site} do
      assert {:error, :requires_license} =
               Masthead.CustomDomains.set_domain(site, "blog.example.com")
    end

    test "a licensed site can set a custom domain", %{site: site} do
      {:ok, site} = Licenses.grant(site)

      assert {:ok, site} = Masthead.CustomDomains.set_domain(site, "blog.example.com")
      assert site.custom_domain == "blog.example.com"
    end

    test "a free site cannot invite collaborators", %{site: site} do
      assert {:error, :requires_license} =
               Sites.invite_to_site(site, "friend@example.com", fn t -> "u/#{t}" end)
    end

    test "a licensed site can invite collaborators", %{site: site} do
      {:ok, site} = Licenses.grant(site)

      assert {:ok, :invited} =
               Sites.invite_to_site(site, "friend@example.com", fn t -> "u/#{t}" end)
    end
  end
end

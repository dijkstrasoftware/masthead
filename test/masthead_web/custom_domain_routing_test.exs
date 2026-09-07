defmodule MastheadWeb.CustomDomainRoutingTest do
  use Masthead.DataCase

  import Plug.Test, only: [conn: 3]

  alias Masthead.{Accounts, Sites, CustomDomains}
  alias MastheadWeb.{Plugs, CheckOrigin}

  setup do
    Masthead.Themes.Seed.run()

    {:ok, user} =
      Accounts.register_user(%{
        "email" => "route-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "route#{System.unique_integer([:positive])}",
        "name" => "Route Test",
        "owner_id" => user.id
      })

    {:ok, site} = Masthead.Licenses.grant(site)

    %{site: site}
  end

  defp activate(site, domain) do
    {:ok, site} = CustomDomains.set_domain(site, domain)

    {:ok, site} =
      site
      |> Masthead.Sites.Site.custom_domain_state_changeset(%{custom_domain_status: "active"})
      |> Masthead.Repo.update()

    site
  end

  describe "Subdomain plug custom-domain fallback" do
    test "resolves an active custom domain to its site", %{site: site} do
      site = activate(site, "blog.example.com")

      conn =
        conn(:get, "/", "")
        |> Map.put(:host, "blog.example.com")
        |> Plugs.Subdomain.call([])

      assert conn.assigns[:current_site].id == site.id
    end

    test "does not resolve a non-active custom domain", %{site: site} do
      {:ok, _site} = CustomDomains.set_domain(site, "blog.example.com")

      conn =
        conn(:get, "/", "")
        |> Map.put(:host, "blog.example.com")
        |> Plugs.Subdomain.call([])

      refute conn.assigns[:current_site]
      refute conn.halted
    end
  end

  describe "CheckOrigin.allowed?/2" do
    @config %{host: "masthead.site", app_hosts: ["masthead.site"]}

    # Phoenix invokes the {M,F,A} check_origin callback with the
    # request %URI{} FIRST, then the configured args. These tests call
    # it in that exact order so the argument contract can't regress
    # (getting it wrong rejected every origin in prod).
    test "allows the bare app host and its subdomains" do
      assert CheckOrigin.allowed?(URI.parse("https://masthead.site"), @config)
      assert CheckOrigin.allowed?(URI.parse("https://acme.masthead.site"), @config)
    end

    test "rejects an unknown foreign host" do
      refute CheckOrigin.allowed?(URI.parse("https://evil.example.com"), @config)
    end

    test "allows an active custom domain", %{site: site} do
      activate(site, "blog.example.com")
      assert CheckOrigin.allowed?(URI.parse("https://blog.example.com"), @config)
    end
  end
end

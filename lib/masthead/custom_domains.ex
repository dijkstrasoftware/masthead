defmodule Masthead.CustomDomains do
  @moduledoc """
  Custom-domain lifecycle for a site.

      unconfigured → pending_dns → verified → cert_provisioning → active
                          ↑
                        failed ←── (any step, with last_error)

  - `set_domain/2`         — store + normalize a domain, generate the
                             ownership token, move to `pending_dns`.
  - `verify/1`             — confirm the TXT token and the CNAME
                             delegation, then request the cert.
  - `refresh_status/1`     — poll Fly; promote to `active` once issued.
  - `clear_domain/1`       — remove the Fly cert and reset to
                             `unconfigured`.

  DNS and Fly access go through swappable adapters
  (`Masthead.CustomDomains.DnsResolver`, `Masthead.CustomDomains.FlyClient`)
  so tests and dev never touch the network.
  """
  import Ecto.Changeset

  alias Masthead.Repo
  alias Masthead.Sites.Site
  alias Masthead.CustomDomains.{DnsResolver, FlyClient}
  alias Masthead.Licenses

  @doc """
  Set or change the site's custom domain. Moves it to `pending_dns`.

  Custom domains are a paid feature: an unlicensed site gets
  `{:error, :requires_license}`.
  """
  def set_domain(%Site{} = site, domain) do
    if Licenses.paid?(site), do: do_set_domain(site, domain), else: {:error, :requires_license}
  end

  defp do_set_domain(%Site{} = site, domain) do
    changeset = Site.custom_domain_changeset(site, %{"custom_domain" => domain})

    if changeset.valid? do
      changeset
      |> put_change(:custom_domain_status, "pending_dns")
      |> put_change(:custom_domain_token, generate_token())
      |> put_change(:custom_domain_verified_at, nil)
      |> put_change(:custom_domain_last_checked_at, nil)
      |> put_change(:custom_domain_last_error, nil)
      |> Repo.update()
    else
      {:error, %{changeset | action: :validate}}
    end
  end

  @doc """
  Verify ownership (TXT token) and delegation (CNAME → Fly edge). On
  success, transitions to `verified` and immediately requests the cert.
  """
  def verify(%Site{custom_domain: domain} = site) when is_binary(domain) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with :ok <- check_txt(site),
         :ok <- check_delegation(site) do
      site
      |> state_changeset(%{
        custom_domain_status: "verified",
        custom_domain_verified_at: now,
        custom_domain_last_checked_at: now,
        custom_domain_last_error: nil
      })
      |> Repo.update()
      |> case do
        {:ok, verified} -> request_certificate(verified)
        other -> other
      end
    else
      {:error, reason} ->
        fail(site, reason, now)
    end
  end

  def verify(%Site{} = site), do: {:error, "no custom domain set", site}

  @doc """
  Poll Fly for the certificate status and promote to `active` once the
  cert has been issued. Powers the manual "Refresh status" button.
  """
  def refresh_status(%Site{custom_domain: domain} = site) when is_binary(domain) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case FlyClient.get_certificate(domain) do
      {:ok, %{ready?: true}} ->
        site
        |> state_changeset(%{
          custom_domain_status: "active",
          custom_domain_last_checked_at: now,
          custom_domain_last_error: nil
        })
        |> Repo.update()

      {:ok, %{ready?: false, status: status}} ->
        site
        |> state_changeset(%{
          custom_domain_status: "cert_provisioning",
          custom_domain_last_checked_at: now,
          custom_domain_last_error: "Certificate not ready yet (status: #{status})"
        })
        |> Repo.update()

      {:error, reason} ->
        fail(site, "Certificate status check failed: #{inspect(reason)}", now)
    end
  end

  def refresh_status(%Site{} = site), do: {:error, "no custom domain set", site}

  @doc "Remove the Fly cert (best effort) and reset to `unconfigured`."
  def clear_domain(%Site{custom_domain: domain} = site) do
    if is_binary(domain), do: FlyClient.delete_certificate(domain)

    site
    |> state_changeset(%{
      custom_domain: nil,
      custom_domain_status: "unconfigured",
      custom_domain_token: nil,
      custom_domain_verified_at: nil,
      custom_domain_last_checked_at: nil,
      custom_domain_last_error: nil
    })
    |> Repo.update()
  end

  @doc """
  The DNS records the user must create, for display in the admin UI.
  """
  def dns_instructions(site, fly_ips \\ [])

  def dns_instructions(
        %Site{custom_domain: domain, custom_domain_token: token},
        fly_ips
      )
      when is_binary(domain) do
    %{
      txt: %{type: "TXT", name: "#{txt_prefix()}.#{domain}", value: token},
      # Subdomain setups use the CNAME; apex setups use the A/AAAA
      # records. The UI shows both and the user picks the one their
      # domain allows.
      cname: %{type: "CNAME", name: domain, value: cname_target()},
      a_records:
        Enum.map(fly_ips, fn ip ->
          %{type: ip_record_type(ip), name: domain, value: ip}
        end)
    }
  end

  def dns_instructions(_site, _fly_ips), do: nil

  @doc """
  The Fly app's public IPs (for apex A/AAAA instructions). Returns []
  on any failure — missing credentials, network error, or unexpected
  exception — so callers never crash on the apex-instructions path.
  """
  def fly_ips do
    case FlyClient.get_ips() do
      {:ok, ips} -> ips
      _ -> []
    end
  rescue
    _ -> []
  end

  defp ip_record_type(ip), do: if(String.contains?(ip, ":"), do: "AAAA", else: "A")

  # --- internals ---------------------------------------------------------

  defp request_certificate(%Site{custom_domain: domain} = site) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case FlyClient.add_certificate(domain) do
      :ok ->
        site
        |> state_changeset(%{
          custom_domain_status: "cert_provisioning",
          custom_domain_last_checked_at: now,
          custom_domain_last_error: nil
        })
        |> Repo.update()

      {:error, reason} ->
        fail(site, "Certificate request failed: #{inspect(reason)}", now)
    end
  end

  defp check_txt(%Site{custom_domain: domain, custom_domain_token: token}) do
    name = "#{txt_prefix()}.#{domain}"

    if token in DnsResolver.lookup_txt(name) do
      :ok
    else
      {:error, "TXT record #{name} not found or does not match the verification token"}
    end
  end

  # A subdomain delegates via CNAME → the Fly edge. An apex domain
  # cannot hold a CNAME (RFC 1034/2181), so it instead points A/AAAA
  # records at the Fly app's IPs. Either is acceptable.
  defp check_delegation(%Site{custom_domain: domain}) do
    if cname_target() in DnsResolver.lookup_cname(domain) do
      :ok
    else
      check_apex_delegation(domain)
    end
  end

  defp check_apex_delegation(domain) do
    case FlyClient.get_ips() do
      {:ok, []} ->
        {:error,
         "#{domain} has no CNAME to #{cname_target()}, and there are no IP " <>
           "addresses available to point an apex domain at"}

      {:ok, fly_ips} ->
        resolved = DnsResolver.lookup_a(domain) ++ DnsResolver.lookup_aaaa(domain)

        cond do
          resolved == [] ->
            {:error, "#{domain} has no CNAME to #{cname_target()} and no A/AAAA records yet"}

          ips_subset?(resolved, fly_ips) ->
            :ok

          true ->
            {:error,
             "#{domain} points at #{Enum.join(resolved, ", ")} but the required " <>
               "IP addresses are #{Enum.join(fly_ips, ", ")} — update the A/AAAA records to match"}
        end

      {:error, reason} ->
        {:error, "Couldn't confirm apex delegation: #{reason}"}
    end
  end

  # IPv6 (and IPv4) addresses have several valid textual forms, so
  # compare parsed addresses rather than strings — `:inet.ntoa` (our
  # resolved value) and Fly's API string can render the same address
  # differently (`::` placement, leading zeros, case).
  defp ips_subset?(resolved, fly_ips) do
    fly = MapSet.new(fly_ips, &parse_ip/1)
    Enum.all?(resolved, &MapSet.member?(fly, parse_ip(&1)))
  end

  defp parse_ip(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, addr} -> addr
      _ -> str
    end
  end

  defp fail(site, reason, now) do
    {:ok, updated} =
      site
      |> state_changeset(%{
        custom_domain_status: "failed",
        custom_domain_last_checked_at: now,
        custom_domain_last_error: reason
      })
      |> Repo.update()

    {:error, reason, updated}
  end

  defp state_changeset(site, attrs), do: Site.custom_domain_state_changeset(site, attrs)

  defp generate_token do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp cname_target do
    Application.get_env(:masthead, :custom_domain, [])
    |> Keyword.get(:cname_target, "masthead.site")
  end

  defp txt_prefix do
    Application.get_env(:masthead, :custom_domain, [])
    |> Keyword.get(:txt_prefix, "_masthead-verify")
  end
end

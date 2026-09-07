defmodule MastheadWeb.AdminLive.DomainSetup do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.CustomDomains
  alias Masthead.Licenses

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site

    {:ok,
     socket
     |> assign(page_title: "Custom domain — #{site.name}")
     |> assign_domain(site)}
  end

  @impl true
  def handle_event("set_domain", %{"custom_domain" => domain}, socket) do
    case CustomDomains.set_domain(socket.assigns.site, domain) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign_domain(site)
         |> put_flash(:info, "Domain saved. Add the DNS records below, then verify.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, domain_error(changeset))}
    end
  end

  def handle_event("verify_domain", _params, socket) do
    case CustomDomains.verify(socket.assigns.site) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign_domain(site)
         |> put_flash(:info, "Domain verified. Requesting an SSL certificate…")}

      {:error, _reason, site} ->
        # The failure is shown inline (persistent, contextual) via the
        # site's last_error — no transient flash, which would duplicate it.
        {:noreply, assign_domain(socket, site)}
    end
  end

  def handle_event("refresh_domain", _params, socket) do
    case CustomDomains.refresh_status(socket.assigns.site) do
      {:ok, %{custom_domain_status: "active"} = site} ->
        {:noreply,
         socket
         |> assign_domain(site)
         |> put_flash(:info, "Certificate issued — your domain is live.")}

      {:ok, site} ->
        {:noreply,
         socket
         |> assign_domain(site)
         |> put_flash(:info, "Still provisioning — check back in a minute.")}

      {:error, _reason, site} ->
        {:noreply, assign_domain(socket, site)}
    end
  end

  def handle_event("clear_domain", _params, socket) do
    {:ok, site} = CustomDomains.clear_domain(socket.assigns.site)

    {:noreply, socket |> assign_domain(site) |> put_flash(:info, "Custom domain removed.")}
  end

  # Fly IPs (for apex A/AAAA records) are only fetched when a domain is
  # set, so the unconfigured path makes no Fly API call.
  defp assign_domain(socket, site) do
    dns =
      if site.custom_domain,
        do: CustomDomains.dns_instructions(site, CustomDomains.fly_ips()),
        else: nil

    assign(socket, site: site, dns: dns, step: step_for(site.custom_domain_status))
  end

  defp domain_error(changeset) do
    case changeset.errors[:custom_domain] do
      {msg, _} -> "Domain: #{msg}"
      _ -> "Could not save the domain."
    end
  end

  defp step_for("unconfigured"), do: 1
  defp step_for(status) when status in ["pending_dns", "failed"], do: 2
  defp step_for(_), do: 3

  defp step_class(i, current) when i < current, do: "step step-done"
  defp step_class(i, current) when i == current, do: "step step-current"
  defp step_class(_, _), do: "step step-future"

  defp humanize_status("pending_dns"), do: "awaiting DNS records"
  defp humanize_status("verified"), do: "verified, requesting certificate"
  defp humanize_status("cert_provisioning"), do: "certificate provisioning"
  defp humanize_status("active"), do: "active and secured"
  defp humanize_status("failed"), do: "verification failed"
  defp humanize_status(other), do: other

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Custom domain"
      site={@site}
      current_user={@current_user}
      action_count={@action_count}
      present_users={@present_users}
      flash={@flash}
      active={:settings}
    >
      <div class="wizard">
        <ol class="stepper">
          <li
            :for={{label, i} <- Enum.with_index(["Domain", "DNS records", "SSL"], 1)}
            class={step_class(i, @step)}
          >
            <span class="step-num">{i}</span>
            <span class="step-label">{label}</span>
          </li>
        </ol>

        <%= case @step do %>
          <% 1 -> %>
            <h2 class="wizard-heading">Add a custom domain</h2>
            <div :if={not Licenses.paid?(@site)} class="domain-summary">
              <span class="muted">
                Custom domains are part of a paid license. This site is on the free plan.
              </span>
              <.link navigate={~p"/#{@site.slug}/settings"} class="btn btn-primary">
                View license options
              </.link>
            </div>

            <form :if={Licenses.paid?(@site)} phx-submit="set_domain" class="form">
              <label>
                Domain
                <input
                  type="text"
                  name="custom_domain"
                  placeholder="blog.example.com"
                  autocomplete="off"
                  autofocus
                />
                <small>
                  A subdomain (<code>blog.example.com</code>) or an apex/root
                  domain (<code>example.com</code>) you control.
                </small>
              </label>
              <div class="wizard-footer">
                <.link navigate={~p"/#{@site.slug}/settings"} class="btn">Cancel</.link>
                <button type="submit" class="btn btn-primary">Continue &rarr;</button>
              </div>
            </form>
          <% 2 -> %>
            <h2 class="wizard-heading">
              Point <code>{@site.custom_domain}</code> at Masthead
            </h2>

            <p :if={@site.custom_domain_last_error} class="domain-error">
              {@site.custom_domain_last_error}
            </p>

            <div :if={@dns} class="dns-card">
              <p class="dns-intro">
                Add these records at your DNS provider, then click <strong>Verify</strong>. Changes can take a few minutes to
                propagate.
              </p>

              <div class="dns-record">
                <div class="dns-record-head">
                  <span class="dns-type">{@dns.txt.type}</span>
                  <span class="dns-purpose">Proves you own this domain.</span>
                </div>
                <dl class="dns-fields">
                  <div>
                    <dt>Name</dt>
                    <dd><code>{@dns.txt.name}</code></dd>
                  </div>
                  <div>
                    <dt>Value</dt>
                    <dd><code>{@dns.txt.value}</code></dd>
                  </div>
                </dl>
              </div>

              <div class="dns-record">
                <div class="dns-record-head">
                  <span class="dns-type">{@dns.cname.type}</span>
                  <span class="dns-purpose">
                    Points the domain at Masthead (for <code>blog.example.com</code>-style subdomains).
                  </span>
                </div>
                <dl class="dns-fields">
                  <div>
                    <dt>Name</dt>
                    <dd><code>{@dns.cname.name}</code></dd>
                  </div>
                  <div>
                    <dt>Value</dt>
                    <dd><code>{@dns.cname.value}</code></dd>
                  </div>
                </dl>
              </div>

              <details class="dns-apex">
                <summary>Using a root/apex domain (<code>example.com</code>) instead?</summary>
                <p class="dns-apex-note">
                  A <code>CNAME</code> can't be set on a root domain — add
                  these A/AAAA records <em>instead of</em> the CNAME above.
                </p>

                <div :for={rec <- @dns.a_records} class="dns-record">
                  <div class="dns-record-head">
                    <span class="dns-type">{rec.type}</span>
                    <span class="dns-purpose">Points the root domain at Masthead.</span>
                  </div>
                  <dl class="dns-fields">
                    <div>
                      <dt>Name</dt>
                      <dd><code>{rec.name}</code></dd>
                    </div>
                    <div>
                      <dt>Value</dt>
                      <dd><code>{rec.value}</code></dd>
                    </div>
                  </dl>
                </div>

                <p :if={@dns.a_records == []} class="domain-error">
                  Could not load the apex IP addresses — use the subdomain
                  (CNAME) option above, or retry later.
                </p>
              </details>
            </div>

            <div class="wizard-footer">
              <button
                type="button"
                class="btn"
                phx-click="clear_domain"
                data-confirm="Remove this domain and start over?"
              >
                Change domain
              </button>
              <button type="button" class="btn btn-primary" phx-click="verify_domain">
                Verify &rarr;
              </button>
            </div>
          <% 3 -> %>
            <%= if @site.custom_domain_status == "active" do %>
              <h2 class="wizard-heading">Your domain is live</h2>
              <div class="dns-card">
                <p class="domain-status domain-status-active">
                  <strong>{@site.custom_domain}</strong> is serving traffic over HTTPS.
                </p>
                <p>
                  <a href={"https://#{@site.custom_domain}"} target="_blank" rel="noopener">
                    Open https://{@site.custom_domain} &rarr;
                  </a>
                </p>
              </div>
              <div class="wizard-footer">
                <.link navigate={~p"/#{@site.slug}/settings"} class="btn">Back to settings</.link>
                <button
                  type="button"
                  class="btn btn-danger"
                  phx-click="clear_domain"
                  data-confirm="Remove this custom domain? The SSL certificate will be deleted."
                >
                  Remove domain
                </button>
              </div>
            <% else %>
              <h2 class="wizard-heading">Issuing your SSL certificate</h2>
              <div class="dns-card">
                <p class="domain-status">
                  <strong>{@site.custom_domain}</strong>
                  — {humanize_status(@site.custom_domain_status)}.
                </p>
                <p class="muted">
                  Your SSL certificate is being provisioned. This usually takes
                  a minute or two after DNS has propagated.
                </p>
                <p :if={@site.custom_domain_last_error} class="domain-error">
                  {@site.custom_domain_last_error}
                </p>
              </div>
              <div class="wizard-footer">
                <button
                  type="button"
                  class="btn"
                  phx-click="clear_domain"
                  data-confirm="Remove this domain and start over?"
                >
                  Start over
                </button>
                <button type="button" class="btn btn-primary" phx-click="refresh_domain">
                  Refresh status
                </button>
              </div>
            <% end %>
        <% end %>
      </div>
    </.shell>
    """
  end
end

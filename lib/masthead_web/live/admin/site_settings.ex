defmodule MastheadWeb.AdminLive.SiteSettings do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.{Actions, Licenses, Realtime, Sites, Content}
  alias Masthead.Content.Tag

  @impl true
  def mount(_params, _session, socket) do
    site = socket.assigns.site
    if connected?(socket), do: Realtime.subscribe(Realtime.settings_topic(site.id))
    changeset = Sites.change_settings(site)

    {:ok,
     socket
     |> assign(
       page_title: "Settings — #{site.name}",
       published_pages: Content.list_published_pages(site.id),
       action_count: Actions.count_pending(site),
       show_errors: false,
       tags: Content.list_tags(site.id),
       tag_modal?: false,
       editing_tag: nil,
       tag_form: nil,
       tag_slug_touched: false,
       plans: Licenses.plans(),
       upgrade_modal?: false
     )
     |> assign_form(changeset)}
  end

  # A settings/tag change elsewhere: refresh the ancillary collaborative data
  # (tag list + homepage options) without touching the form, so a viewer's
  # unsaved edits are never clobbered.
  @impl true
  def handle_info({:realtime, :settings}, socket) do
    site = socket.assigns.site

    {:noreply,
     assign(socket,
       site: Sites.get_site!(site.id),
       tags: Content.list_tags(site.id),
       published_pages: Content.list_published_pages(site.id)
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"site" => params}, socket) do
    changeset =
      socket.assigns.site
      |> Sites.change_settings(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("open_upgrade", _params, socket) do
    {:noreply, assign(socket, upgrade_modal?: true)}
  end

  def handle_event("close_upgrade", _params, socket) do
    {:noreply, assign(socket, upgrade_modal?: false)}
  end

  def handle_event("checkout", %{"plan" => plan}, socket) do
    site = socket.assigns.site
    leave_for(socket, Licenses.checkout_url(site, plan, settings_url(site)))
  end

  def handle_event("billing_portal", _params, socket) do
    site = socket.assigns.site
    leave_for(socket, Licenses.portal_url(site, settings_url(site)))
  end

  def handle_event("save", %{"site" => params}, socket) do
    case Sites.update_settings(socket.assigns.site, params) do
      {:ok, site} ->
        changeset = Sites.change_settings(site)

        {:noreply,
         socket
         |> assign(
           site: site,
           published_pages: Content.list_published_pages(site.id),
           action_count: Actions.count_pending(site)
         )
         |> put_flash(:info, "Settings saved.")
         |> assign_form(changeset)}

      {:error, changeset} ->
        {:noreply, socket |> assign(show_errors: true) |> assign_form(changeset)}
    end
  end

  def handle_event("delete_site", _params, socket) do
    # The site is owner-scoped by the :load_site hook, so the current user is
    # authorized. Soft-delete keeps the row recoverable (by an admin); the
    # owner can no longer reach it, so send them back to their site list.
    {:ok, _} = Sites.soft_delete_site(socket.assigns.site)

    {:noreply,
     socket
     |> put_flash(:info, "Site deleted. Contact support if you need it back.")
     |> push_navigate(to: ~p"/sites")}
  end

  # ---- Tags ----

  def handle_event("new_tag", _params, socket) do
    # Seed the site_id so live validation doesn't immediately complain that
    # it's required (the form never includes site_id — it's set server-side).
    {:noreply, open_tag_modal(socket, %Tag{site_id: socket.assigns.site.id})}
  end

  def handle_event("edit_tag", %{"id" => id}, socket) do
    {:noreply, open_tag_modal(socket, Content.get_tag!(socket.assigns.site.id, id))}
  end

  def handle_event("close_tag_modal", _params, socket) do
    {:noreply, assign(socket, tag_modal?: false, editing_tag: nil, tag_form: nil)}
  end

  def handle_event("validate_tag", %{"tag" => params} = payload, socket) do
    target = List.last(payload["_target"] || [])
    slug_touched = socket.assigns.tag_slug_touched or target == "slug"

    # While the user hasn't hand-edited the slug, blank it on each name change
    # so the changeset re-derives it from the (updated) name. Otherwise the
    # slug input echoes its previous value back and sticks after one keystroke.
    params =
      if not slug_touched and target == "name" do
        Map.put(params, "slug", "")
      else
        params
      end

    changeset =
      socket.assigns.editing_tag
      |> Content.change_tag(params)
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket, tag_form: to_form(changeset, as: :tag), tag_slug_touched: slug_touched)}
  end

  def handle_event("save_tag", %{"tag" => params}, socket) do
    result =
      case socket.assigns.editing_tag do
        %Tag{id: nil} -> Content.create_tag(socket.assigns.site.id, params)
        tag -> Content.update_tag(tag, params)
      end

    case result do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> assign(
           tags: Content.list_tags(socket.assigns.site.id),
           tag_modal?: false,
           editing_tag: nil,
           tag_form: nil
         )
         |> put_flash(:info, "Tag saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, tag_form: to_form(changeset, as: :tag))}
    end
  end

  def handle_event("delete_tag", %{"id" => id}, socket) do
    tag = Content.get_tag!(socket.assigns.site.id, id)
    {:ok, _} = Content.delete_tag(tag)
    {:noreply, assign(socket, tags: Content.list_tags(socket.assigns.site.id))}
  end

  defp open_tag_modal(socket, tag) do
    assign(socket,
      tag_modal?: true,
      editing_tag: tag,
      tag_form: to_form(Content.change_tag(tag), as: :tag),
      # New tags auto-derive the slug from the name; existing tags keep their
      # slug (it's referenced by themes) unless the user edits it directly.
      tag_slug_touched: not is_nil(tag.id)
    )
  end

  defp settings_url(site), do: url(~p"/#{site.slug}/settings")

  defp leave_for(socket, {:ok, url}), do: {:noreply, redirect(socket, external: url)}
  defp leave_for(socket, {:error, reason}), do: {:noreply, put_flash(socket, :error, reason)}

  defp license_detail(site) do
    if Licenses.canceled?(site),
      do: "Ends #{on_date(site.license_expires_at)}",
      else: "Renews #{on_date(site.license_expires_at)}"
  end

  defp on_date(at), do: Calendar.strftime(at, "%-d %B %Y")

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :site), changeset: changeset)
  end

  defp homepage_value(form), do: form[:homepage_page_id].value

  defp domain_status_label("pending_dns"), do: "awaiting DNS"
  defp domain_status_label("verified"), do: "verified"
  defp domain_status_label("cert_provisioning"), do: "issuing SSL"
  defp domain_status_label("active"), do: "active"
  defp domain_status_label("failed"), do: "needs attention"
  defp domain_status_label(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Settings"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:settings}
      action_count={@action_count}
      present_users={@present_users}
    >
      <div class="wizard">
        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="form settings-form"
          id="site-settings-form"
        >
          <.error_list changeset={@changeset} show={@show_errors} />

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Identity</h2>
              <p>Name and presentation shown across the public site.</p>
            </header>

            <div class="settings-fields">
              <div class="form-row">
                <label class="flex-1">
                  Name <input type="text" name="site[name]" value={@form[:name].value} required />
                </label>

                <label class="flex-1">
                  Title <input type="text" name="site[title]" value={@form[:title].value} />
                  <small>Used in the browser tab and as the homepage heading.</small>
                </label>
              </div>

              <label>
                Description <textarea name="site[description]" rows="3">{@form[:description].value}</textarea>
                <small>Shown on the default homepage and in the &lt;meta&gt; description.</small>
              </label>
            </div>
          </div>

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Public site</h2>
              <p>Control what visitors see at the root URL.</p>
            </header>

            <div class="settings-fields">
              <label>
                Homepage
                <select name="site[homepage_page_id]">
                  <option value="" selected={is_nil(homepage_value(@form))}>
                    Default — list of posts
                  </option>
                  <option
                    :for={page <- @published_pages}
                    value={page.id}
                    selected={to_string(page.id) == to_string(homepage_value(@form))}
                  >
                    {page.title} ({page.format})
                  </option>
                </select>
                <small>Pick a page to override the default post list.</small>
              </label>
            </div>
          </div>

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Tags</h2>
              <p>Group posts so you can filter them in the admin and pull them into your theme.</p>
            </header>

            <div class="settings-fields">
              <div class="tag-manage-list">
                <span :for={t <- @tags} class="tag-chip">
                  <button
                    type="button"
                    class="tag-chip-label"
                    phx-click="edit_tag"
                    phx-value-id={t.id}
                  >
                    {t.name}
                  </button>
                  <button
                    type="button"
                    class="tag-chip-remove"
                    phx-click="delete_tag"
                    phx-value-id={t.id}
                    data-confirm={"Delete tag \"" <> t.name <> "\"? Posts keep their other tags."}
                    aria-label={"Delete " <> t.name}
                  >
                    &times;
                  </button>
                </span>
                <span :if={@tags == []} class="muted">No tags yet.</span>
                <button type="button" phx-click="new_tag" class="tag-chip-add">
                  <span aria-hidden="true">+</span> New tag
                </button>
              </div>
            </div>
          </div>

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Custom domain</h2>
              <p>Serve this site from your own domain instead of a Masthead subdomain.</p>
            </header>

            <div class="settings-fields">
              <div :if={@site.custom_domain} class="domain-summary">
                <span>
                  <strong>{@site.custom_domain}</strong>
                  <span class={"domain-badge domain-badge-" <> @site.custom_domain_status}>
                    {domain_status_label(@site.custom_domain_status)}
                  </span>
                </span>
                <.link navigate={~p"/#{@site.slug}/domain"} class="btn">Manage</.link>
              </div>

              <div :if={is_nil(@site.custom_domain)} class="domain-summary">
                <span class="muted">No custom domain configured.</span>
                <.link
                  :if={Licenses.paid?(@site)}
                  navigate={~p"/#{@site.slug}/domain"}
                  class="btn btn-primary"
                >
                  Set up a custom domain
                </.link>

                <button
                  :if={not Licenses.paid?(@site)}
                  type="button"
                  phx-click="open_upgrade"
                  class="btn btn-primary"
                >
                  Set up a custom domain
                </button>
              </div>
            </div>
          </div>

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>Import site</h2>
              <p>Import posts, pages, and images from an existing site.</p>
            </header>

            <div class="settings-fields">
              <div class="domain-summary">
                <span class="muted">Hugo exports (.zip) are supported.</span>
                <.link navigate={~p"/#{@site.slug}/import"} class="btn btn-primary">
                  Import a site
                </.link>
              </div>
            </div>
          </div>

          <div class="settings-section">
            <header class="settings-section-head">
              <h2>License</h2>
              <p>Each site is licensed separately.</p>
            </header>

            <div class="settings-fields">
              <div class="domain-summary">
                <span class="license-state">
                  <span class="license-state-head">
                    <strong>{Licenses.label(@site)}</strong>
                    <span
                      :if={Licenses.paid?(@site) and not is_nil(@site.license_plan)}
                      class="pill pill-ok"
                    >
                      {@site.license_plan}
                    </span>
                  </span>
                  <span :if={Licenses.paid?(@site)} class="muted">{license_detail(@site)}</span>

                  <.link
                    :if={not Licenses.paid?(@site)}
                    href={~p"/pricing"}
                    target="_blank"
                    rel="noopener"
                  >
                    See what's included
                  </.link>
                </span>

                <button
                  :if={Licenses.paid?(@site) and Licenses.billable?(@site)}
                  type="button"
                  phx-click="billing_portal"
                  class="btn"
                >
                  Manage billing
                </button>

                <span :if={not Licenses.paid?(@site)} class="license-plans">
                  <button
                    :for={{name, plan} <- @plans}
                    type="button"
                    phx-click="checkout"
                    phx-value-plan={name}
                    class={if name == "yearly", do: "btn btn-primary", else: "btn"}
                  >
                    Upgrade — {Licenses.format(plan.amount)}/{plan.label}
                  </button>
                </span>
              </div>
            </div>
          </div>

          <div class="settings-section danger-zone">
            <header class="settings-section-head">
              <h2>Danger zone</h2>
              <p>Permanently remove this site from your account.</p>
            </header>
            <div class="danger-row">
              <div>
                <strong>Delete this site</strong>
                <p class="muted">
                  Takes <code>{@site.slug}</code> offline and removes it from your sites.
                  The data is retained for recovery — contact support if you delete it by mistake.
                </p>
              </div>
              <button
                type="button"
                phx-click="delete_site"
                class="btn btn-danger"
                data-confirm={"Delete #{@site.name}? It will go offline immediately and disappear from your sites."}
              >
                Delete site
              </button>
            </div>
          </div>

          <div class="wizard-footer">
            <.link navigate={~p"/#{@site.slug}"} class="btn">Cancel</.link>
            <button type="submit" class="btn btn-primary" data-shortcut="save">
              Save settings
            </button>
          </div>
        </.form>
      </div>

      <div
        :if={@tag_modal?}
        class="dialog-backdrop"
        phx-window-keydown="close_tag_modal"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_tag_modal"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>{if @editing_tag && @editing_tag.id, do: "Edit tag", else: "New tag"}</h2>
            <button
              type="button"
              phx-click="close_tag_modal"
              class="dialog-close"
              aria-label="Close"
            >
              &times;
            </button>
          </header>

          <form phx-submit="save_tag" phx-change="validate_tag" class="dialog-form">
            <label>
              Name
              <input
                type="text"
                name="tag[name]"
                value={@tag_form[:name].value}
                autocomplete="off"
                required
                autofocus
              />
            </label>
            <label>
              Slug
              <input
                type="text"
                name="tag[slug]"
                value={@tag_form[:slug].value}
                placeholder="auto from name"
                autocomplete="off"
              />
              <small>
                Used in theme queries: <code>{@tag_form[:slug].value || "your-tag"}</code>
              </small>
            </label>
            <ul :if={@tag_form.errors != []} class="errors">
              <li :for={{field, {msg, _}} <- @tag_form.errors}>{field}: {msg}</li>
            </ul>
            <div class="dialog-footer">
              <button type="button" phx-click="close_tag_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary">Save tag</button>
            </div>
          </form>
        </div>
      </div>

      <.upgrade_modal
        show={@upgrade_modal?}
        plans={@plans}
        feature="A custom domain"
      />
    </.shell>
    """
  end
end

defmodule MastheadWeb.AdminLive.SiteIndex do
  use MastheadWeb, :live_view
  import MastheadWeb.AdminLive.Components
  alias Masthead.Sites
  alias Masthead.Themes
  alias Masthead.Sites.Site

  @impl true
  def mount(_params, _session, socket) do
    sites = Sites.list_sites_for_user(socket.assigns.current_user.id)
    changeset = Sites.change_site(%Site{})

    {:ok,
     socket
     |> assign(
       sites: sites,
       page_title: "Your sites",
       host: site_host(),
       modal_open?: false,
       show_errors: false,
       slug_edited?: false,
       step: :details,
       dir: "forward",
       purpose_tags: [],
       purpose: nil,
       starter_themes: [],
       selected_theme: nil
     )
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    purpose_tags = Themes.list_purpose_tags()

    {:noreply,
     socket
     |> assign(
       modal_open?: true,
       show_errors: false,
       slug_edited?: false,
       step: if(purpose_tags == [], do: :details, else: :purpose),
       dir: "forward",
       purpose_tags: purpose_tags,
       purpose: nil,
       starter_themes: [],
       selected_theme: nil
     )
     |> assign_form(Sites.change_site(%Site{}))}
  end

  def handle_event("pick_purpose", %{"slug" => slug}, socket) do
    case Enum.find(socket.assigns.purpose_tags, fn {tag, _} -> tag.slug == slug end) do
      {tag, _count} ->
        {:noreply,
         assign(socket,
           step: :template,
           dir: "forward",
           purpose: tag,
           starter_themes: Themes.list_starter_themes(tag.id)
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("pick_theme", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.starter_themes, &(Integer.to_string(&1.id) == id)) do
      nil -> {:noreply, socket}
      theme -> {:noreply, assign(socket, step: :details, dir: "forward", selected_theme: theme)}
    end
  end

  def handle_event("skip", _params, socket) do
    {:noreply, assign(socket, step: :details, dir: "forward", selected_theme: nil)}
  end

  def handle_event("back", _params, socket) do
    step =
      if socket.assigns.step == :details and socket.assigns.purpose, do: :template, else: :purpose

    {:noreply, assign(socket, step: step, dir: "back")}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: false, show_errors: false)}
  end

  def handle_event("validate", %{"site" => params}, socket) do
    # Auto-derive the slug from the name until the user edits the slug field
    # directly, after which we leave their value alone.
    prev_slug = socket.assigns.form[:slug].value || ""
    incoming_slug = params["slug"] || ""

    slug_edited? =
      socket.assigns.slug_edited? or (incoming_slug != "" and incoming_slug != prev_slug)

    params =
      if slug_edited?,
        do: params,
        else: Map.put(params, "slug", slugify(params["name"] || ""))

    changeset =
      %Site{}
      |> Sites.change_site(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(slug_edited?: slug_edited?)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"site" => params}, socket) do
    # The template lives in assigns, never in params; re-check it on submit.
    params =
      params
      |> Map.delete("theme_id")
      |> Map.put("title", params["name"])
      |> put_starter_theme(socket.assigns.selected_theme)

    case Sites.create_site(params, socket.assigns.current_user) do
      {:ok, site} ->
        {:noreply, push_navigate(socket, to: ~p"/#{site.slug}")}

      {:error, changeset} ->
        {:noreply, socket |> assign(show_errors: true) |> assign_form(changeset)}
    end
  end

  defp put_starter_theme(params, nil), do: params

  defp put_starter_theme(params, theme) do
    case Themes.get_theme(theme.id) do
      nil ->
        params

      fresh ->
        if Themes.starter_theme?(fresh), do: Map.put(params, "theme_id", fresh.id), else: params
    end
  end

  defp step_index(:purpose), do: 0
  defp step_index(:template), do: 1
  defp step_index(:details), do: 2

  defp assign_form(socket, changeset) do
    assign(socket, form: to_form(changeset, as: :site), changeset: changeset)
  end

  # Turn a free-form name into a valid slug: lowercase, non-alphanumeric runs
  # collapsed to hyphens, trimmed, capped at the schema's 32-char limit.
  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 32)
    |> String.trim("-")
  end

  defp site_host do
    cfg = Application.get_env(:masthead, :site_url, [])
    host = Keyword.get(cfg, :host, "lvh.me")
    port = Keyword.get(cfg, :port)
    scheme = Keyword.get(cfg, :scheme, "http")

    suffix =
      cond do
        is_nil(port) -> ""
        scheme == "http" and port == 80 -> ""
        scheme == "https" and port == 443 -> ""
        true -> ":#{port}"
      end

    "#{host}#{suffix}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell title="Your sites" current_user={@current_user} flash={@flash} active={:sites}>
      <:actions>
        <button type="button" phx-click="open_modal" class="btn btn-primary btn-add btn-shimmer">
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New site</span>
        </button>
      </:actions>

      <ul :if={@sites != []} class="card-list site-card-list">
        <li :for={{s, idx} <- Enum.with_index(@sites)} style={"--i: #{idx}"}>
          <span class={"pill card-pill " <> site_chip_class(s)}>{site_chip_label(s)}</span>
          <.link navigate={~p"/#{s.slug}"}>
            <strong>{s.name}</strong>
            <span class="muted">{s.slug}.{@host}</span>
          </.link>
        </li>
      </ul>

      <div :if={@sites == []} class="empty-state empty-state-illustrated empty-state-animated">
        <img src={~p"/images/illustrations/empty-sites.svg"} alt="" class="empty-illustration" />
        <h2>No sites yet</h2>
        <p>
          Each site is a separate brand or product on its own subdomain. Create your first one to start publishing.
        </p>
        <button type="button" phx-click="open_modal" class="btn btn-primary empty-state-cta">
          + New site
        </button>
      </div>

      <div
        :if={@modal_open?}
        class="dialog-backdrop"
        phx-window-keydown="close_modal"
        phx-key="Escape"
      >
        <button
          type="button"
          phx-click="close_modal"
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div
          id="new-site-dialog"
          phx-hook=".MorphSize"
          class={["dialog dialog-wizard", @step == :template && "dialog-wide"]}
        >
          <header class="dialog-header">
            <h2>Create a new site</h2>
            <ol :if={@purpose_tags != []} class="wizard-dots" aria-label="Progress">
              <li
                :for={i <- 0..2}
                class={["wizard-dot", i <= step_index(@step) && "is-done"]}
                aria-current={i == step_index(@step) && "step"}
              >
              </li>
            </ol>
            <button type="button" phx-click="close_modal" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <div :if={@step == :purpose} id="new-site-purpose" class="wizard-step" data-dir={@dir}>
            <div class="dialog-scroll">
              <p class="wizard-question">What do you want to build?</p>
              <div class="purpose-grid">
                <button
                  :for={{{tag, count}, idx} <- Enum.with_index(@purpose_tags)}
                  type="button"
                  id={"purpose-#{tag.slug}"}
                  class="purpose-chip"
                  style={"--i: #{idx}"}
                  phx-click="pick_purpose"
                  phx-value-slug={tag.slug}
                >
                  <strong>{tag.name}</strong>
                  <span class="muted">
                    {count} {if count == 1, do: "template", else: "templates"}
                  </span>
                </button>
              </div>
            </div>
            <footer class="dialog-footer">
              <button type="button" id="new-site-skip" phx-click="skip" class="wizard-skip">
                Skip — use the default theme
              </button>
            </footer>
          </div>

          <div :if={@step == :template} id="new-site-templates" class="wizard-step" data-dir={@dir}>
            <div class="dialog-scroll">
              <p class="wizard-question">
                Pick a template for your {String.downcase(@purpose.name)} site
              </p>
              <ul class="starter-grid">
                <li
                  :for={{t, idx} <- Enum.with_index(@starter_themes)}
                  id={"starter-theme-#{t.id}"}
                  class={[
                    "marketplace-card starter-card",
                    @selected_theme && @selected_theme.id == t.id && "is-selected"
                  ]}
                  style={"--i: #{idx}"}
                >
                  <button
                    type="button"
                    class="starter-card-pick"
                    phx-click="pick_theme"
                    phx-value-id={t.id}
                  >
                    <span class="marketplace-thumb">
                      <img
                        :if={first_image(t)}
                        src={Themes.image_url(first_image(t))}
                        alt={"#{t.name} preview"}
                      />
                      <img
                        :if={is_nil(first_image(t))}
                        class="marketplace-thumb-placeholder"
                        src={placeholder_image(t)}
                        alt=""
                        aria-hidden="true"
                        loading="lazy"
                      />
                      <span class="marketplace-card-tags"><.theme_badge theme={t} /></span>
                    </span>
                    <span class="starter-card-body">
                      <strong class="starter-card-name">{t.name}</strong>
                      <span :if={t.description not in [nil, ""]} class="starter-card-desc">
                        {t.description}
                      </span>
                    </span>
                  </button>
                  <footer class="starter-card-foot">
                    <a
                      href={~p"/marketplace/themes/#{t.id}"}
                      target="_blank"
                      rel="noopener"
                      class="starter-card-view"
                    >
                      View details ↗
                    </a>
                  </footer>
                </li>
              </ul>
            </div>
            <footer class="dialog-footer">
              <button type="button" id="new-site-skip" phx-click="skip" class="wizard-skip">
                Skip — use the default theme
              </button>
              <button type="button" phx-click="back" class="btn">Back</button>
            </footer>
          </div>

          <.form
            :if={@step == :details}
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="dialog-form wizard-step"
            id="new-site-form"
            data-dir={@dir}
          >
            <div class="dialog-scroll">
              <.error_list changeset={@changeset} show={@show_errors} />

              <p :if={@selected_theme} class="wizard-summary">
                Template: {@selected_theme.name} ·
                <button type="button" phx-click="back" class="wizard-summary-change">change</button>
              </p>

              <label>Name</label>
              <small>Shown in nav and as default page title.</small>
              <input type="text" name="site[name]" value={@form[:name].value} required autofocus />

              <label>Slug (subdomain)</label>
              <input type="text" name="site[slug]" value={@form[:slug].value} required />
              <small>
                Public URL: <code>{(@form[:slug].value || "your-slug") <> "." <> @host}</code>
              </small>
            </div>

            <footer class="dialog-footer">
              <button :if={@purpose_tags != []} type="button" phx-click="back" class="btn">
                Back
              </button>
              <button type="button" phx-click="close_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary btn-create" phx-disable-with="Creating…">
                Create site
              </button>
            </footer>
          </.form>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".MorphSize">
          // Step changes resize the dialog (the template step is near-fullscreen).
          // Morph the box from its old size to the new one, then fade the new
          // step in, so content never reflows while the box is growing.
          export default {
            beforeUpdate() {
              this.from = this.el.getBoundingClientRect()
            },
            updated() {
              const from = this.from
              const to = this.el.getBoundingClientRect()
              if (!from || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
              if (Math.abs(from.width - to.width) < 2 && Math.abs(from.height - to.height) < 2) return

              const ms = 300
              const easing = "cubic-bezier(0.2, 0.8, 0.2, 1)"
              this.el.animate(
                [
                  {width: `${from.width}px`, maxWidth: `${from.width}px`, height: `${from.height}px`},
                  {width: `${to.width}px`, maxWidth: `${to.width}px`, height: `${to.height}px`}
                ],
                {duration: ms, easing}
              )
              this.el.querySelector(".wizard-step")?.animate(
                [{opacity: 0, transform: "translateY(8px)"}, {opacity: 1, transform: "none"}],
                {duration: 220, delay: ms - 40, easing, fill: "backwards"}
              )
            }
          }
        </script>
      </div>
    </.shell>
    """
  end
end

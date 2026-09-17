defmodule MastheadWeb.AdminLive.SiteImport do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.Actions
  alias Masthead.Content.HugoImport

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Import site", import_summary: nil)
     |> allow_upload(:site_archive,
       accept: ~w(.zip),
       max_entries: 1,
       max_file_size: 50_000_000
     )}
  end

  @impl true
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_import", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :site_archive, ref)}
  end

  def handle_event("import_site", _params, socket) do
    site = socket.assigns.site
    author_id = socket.assigns.current_user.id

    [result] =
      consume_uploaded_entries(socket, :site_archive, fn %{path: path}, _entry ->
        {:ok, HugoImport.run(site, path, author_id)}
      end)

    case result do
      {:ok, summary} ->
        Actions.complete_action(site, "import_site")

        {:noreply,
         socket
         |> assign(import_summary: summary)
         |> put_flash(:info, import_flash(summary))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, import_error(reason))}
    end
  end

  # Skips of section list pages (`_index.md`) are expected, not problems —
  # only surface genuinely skipped content.
  defp problem_skips(skipped), do: Enum.reject(skipped, &(elem(&1, 1) == :section_index))

  defp import_flash(%{posts: posts, pages: pages, uploads: uploads} = summary) do
    base = "Imported #{length(posts)} posts, #{length(pages)} pages and #{uploads} assets."

    case problem_skips(summary.skipped_content) do
      [] -> base
      problems -> base <> " #{length(problems)} files couldn't be imported."
    end
  end

  defp import_error(:no_content_dir),
    do: "That archive doesn't look like a site we can import (no content/ folder)."

  defp import_error(:too_many_files), do: "That archive has too many files."
  defp import_error(:archive_too_large), do: "That archive is too large."
  defp import_error({:archive_invalid, _}), do: "That file isn't a valid zip archive."
  defp import_error({:unzip_failed, _}), do: "Couldn't unzip that archive."
  defp import_error(_), do: "Import failed."

  defp upload_error_message(:too_large), do: "That file is too large (50MB max)."
  defp upload_error_message(:not_accepted), do: "Please choose a .zip archive."
  defp upload_error_message(:too_many_files), do: "Import one archive at a time."
  defp upload_error_message(other), do: to_string(other)

  defp problem_reason({:invalid, msg}), do: msg
  defp problem_reason(other), do: to_string(other)

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Import site"
      site={@site}
      current_user={@current_user}
      action_count={@action_count}
      present_users={@present_users}
      flash={@flash}
      active={:settings}
    >
      <div class="wizard">
        <h2 class="wizard-heading">Import a site</h2>
        <p class="wizard-intro muted">
          Upload a site export as a <code>.zip</code>. Posts, pages, and images
          are imported; your theme is left untouched. Hugo sites are supported today.
        </p>

        <%= if @import_summary do %>
          <.summary summary={@import_summary} site_slug={@site.slug} />

          <div class="wizard-footer">
            <.link navigate={~p"/#{@site.slug}/settings"} class="btn">Back to settings</.link>
            <.link navigate={~p"/#{@site.slug}/posts"} class="btn btn-primary">
              View posts &rarr;
            </.link>
          </div>
        <% else %>
          <form id="import-form" phx-submit="import_site" phx-change="validate_import" class="form">
            <label class="dropzone" phx-drop-target={@uploads.site_archive.ref}>
              <.live_file_input upload={@uploads.site_archive} />
              <p class="dropzone-headline">Drop a .zip here, or click to browse</p>
              <p class="muted">A single .zip, up to 50MB.</p>
            </label>

            <ul :if={@uploads.site_archive.entries != []} class="upload-entries">
              <li :for={entry <- @uploads.site_archive.entries}>
                <span class="filename">{entry.client_name}</span>
                <button
                  type="button"
                  phx-click="cancel_import"
                  phx-value-ref={entry.ref}
                  class="btn btn-sm"
                >
                  Remove
                </button>
                <p
                  :for={err <- upload_errors(@uploads.site_archive, entry)}
                  class="error entry-error"
                >
                  {upload_error_message(err)}
                </p>
              </li>
            </ul>

            <p :for={err <- upload_errors(@uploads.site_archive)} class="error">
              {upload_error_message(err)}
            </p>
          </form>

          <div class="wizard-footer">
            <.link navigate={~p"/#{@site.slug}/settings"} class="btn">Cancel</.link>
            <button
              type="submit"
              form="import-form"
              class="btn btn-primary"
              disabled={@uploads.site_archive.entries == []}
            >
              Import site &rarr;
            </button>
          </div>
        <% end %>
      </div>
    </.shell>
    """
  end

  attr :summary, :map, required: true
  attr :site_slug, :string, required: true

  defp summary(assigns) do
    assigns = assign(assigns, :problems, problem_skips(assigns.summary.skipped_content))

    ~H"""
    <div class="import-summary">
      <p>
        <strong>Imported</strong>
        {length(@summary.posts)} posts, {length(@summary.pages)} pages and {@summary.uploads} assets.
        <span :if={@summary.skipped_assets > 0} class="muted">
          {@summary.skipped_assets} unsupported asset files were skipped.
        </span>
      </p>
      <p class="import-summary-links">
        <.link navigate={~p"/#{@site_slug}/posts"}>View posts</.link>
        <.link navigate={~p"/#{@site_slug}/pages"}>View pages</.link>
      </p>
      <details :if={@problems != []} class="import-problems">
        <summary>{length(@problems)} files couldn't be imported</summary>
        <ul>
          <li :for={{path, reason} <- @problems}>
            <code>{path}</code> — {problem_reason(reason)}
          </li>
        </ul>
      </details>
    </div>
    """
  end
end

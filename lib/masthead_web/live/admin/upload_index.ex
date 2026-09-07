defmodule MastheadWeb.AdminLive.UploadIndex do
  use MastheadWeb, :live_view
  on_mount {MastheadWeb.AdminLive.Hooks, :load_site}

  import MastheadWeb.AdminLive.Components
  alias Masthead.Uploads

  # Three rows of six on a wide screen. Images are heavy, so the grid is
  # capped rather than paginated — past the cap the user searches.
  defp list_limit, do: 18

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Uploads — #{socket.assigns.site.name}",
       modal_open?: false,
       renamed_names: %{},
       search: "",
       type_filter: :all
     )
     |> allow_upload(:image,
       accept: ~w(.png .jpg .jpeg .gif .webp .svg .ico .pdf),
       max_entries: 8,
       max_file_size: 8_000_000
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # `?new=1` opens the upload dialog on arrival, so the command palette's
    # "New upload" lands on the thing it names rather than next to it.
    {:noreply,
     socket
     |> assign(
       search: params["q"] || "",
       type_filter: parse_filter(params),
       modal_open?: params["new"] == "1" or socket.assigns[:modal_open?] == true
     )
     |> reload_uploads()}
  end

  @impl true
  def handle_event("search_list", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: uploads_path(socket, socket.assigns.type_filter, query))}
  end

  def handle_event("switch_filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: uploads_path(socket, filter, socket.assigns.search))}
  end

  def handle_event("open_modal", _params, socket) do
    {:noreply, assign(socket, modal_open?: true)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, cancel_all_uploads(socket)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, renamed_names: Map.get(params, "renames", %{}))}
  end

  def handle_event("save", params, socket) do
    renames = Map.get(params, "renames", socket.assigns.renamed_names)

    results =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        attrs = %{
          filename: final_filename(entry, renames),
          content_type: entry.client_type,
          path: path
        }

        case Uploads.store_image(socket.assigns.site, attrs) do
          {:ok, _upload} -> {:ok, :stored}
          {:error, reason} -> {:postpone, reason}
        end
      end)

    stored = Enum.count(results, &(&1 == :stored))

    flash_msg =
      case stored do
        0 -> "No files uploaded."
        n -> "#{n} file(s) uploaded."
      end

    {:noreply,
     socket
     |> put_flash(:info, flash_msg)
     |> assign(modal_open?: stored > 0, renamed_names: %{})
     |> reload_uploads()
     |> maybe_close_modal(stored)}
  end

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  defp reload_uploads(socket) do
    uploads =
      Uploads.list_uploads(socket.assigns.site.id,
        search: socket.assigns.search,
        filter: socket.assigns.type_filter,
        limit: list_limit()
      )

    assign(socket,
      uploads_list: uploads,
      uploads_total:
        Uploads.count_uploads(socket.assigns.site.id,
          search: socket.assigns.search,
          filter: socket.assigns.type_filter
        )
    )
  end

  # Keep the filter and search in the URL so they survive a reload and stay
  # shareable, dropping each param when it's back at its default.
  defp uploads_path(socket, filter, query) do
    params =
      %{}
      |> maybe_put("type", to_string(filter), &(&1 in ["", "all"]))
      |> maybe_put("q", query, &(&1 in [nil, ""]))

    ~p"/#{socket.assigns.site.slug}/uploads?#{params}"
  end

  defp maybe_put(params, key, value, drop?) do
    if drop?.(value), do: params, else: Map.put(params, key, value)
  end

  defp parse_filter(%{"type" => "images"}), do: :images
  defp parse_filter(%{"type" => "documents"}), do: :documents
  defp parse_filter(_params), do: :all

  defp filtering?(filter, search), do: filter != :all or search != ""

  defp maybe_close_modal(socket, 0), do: socket
  defp maybe_close_modal(socket, _), do: assign(socket, modal_open?: false)

  defp cancel_all_uploads(socket) do
    refs = Enum.map(socket.assigns.uploads.image.entries, & &1.ref)

    socket =
      Enum.reduce(refs, socket, fn ref, acc ->
        cancel_upload(acc, :image, ref)
      end)

    assign(socket, modal_open?: false, renamed_names: %{})
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      title="Uploads"
      site={@site}
      current_user={@current_user}
      flash={@flash}
      active={:uploads}
      action_count={@action_count}
      present_users={@present_users}
    >
      <:actions>
        <button
          type="button"
          phx-click="open_modal"
          class="btn btn-primary btn-add"
          data-shortcut="new"
        >
          <span class="btn-add-icon" aria-hidden="true">+</span>
          <span class="btn-add-label">New upload</span>
        </button>
      </:actions>

      <.list_toolbar
        :if={@uploads_list != [] or filtering?(@type_filter, @search)}
        scope={:uploads}
        filter={@type_filter}
        options={Uploads.filter_options()}
        search={@search}
        placeholder="Search uploads…"
        limit={list_limit()}
        truncated?={length(@uploads_list) == list_limit()}
        total={@uploads_total}
      />

      <div
        :if={@uploads_list == [] and not filtering?(@type_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-uploads.svg"} alt="" class="empty-illustration" />
        <h2>Nothing uploaded yet</h2>
        <p>Upload an image to embed it in posts and pages using Markdown or HTML snippets.</p>
        <button type="button" phx-click="open_modal" class="btn btn-primary">+ New upload</button>
      </div>

      <div
        :if={@uploads_list == [] and filtering?(@type_filter, @search)}
        class="empty-state empty-state-illustrated"
      >
        <img src={~p"/images/illustrations/empty-uploads.svg"} alt="" class="empty-illustration" />
        <h2>No uploads match</h2>
        <p>No uploads match this filter.</p>
        <.link patch={~p"/#{@site.slug}/uploads"} class="btn">Clear filter</.link>
      </div>

      <ul :if={@uploads_list != []} class="upload-grid">
        <li :for={u <- @uploads_list}>
          <.link navigate={~p"/#{@site.slug}/uploads/#{u.id}"} class="upload-card">
            <div class="upload-thumb">
              <img :if={Uploads.preview_url(u)} src={Uploads.preview_url(u)} alt={u.filename} />
              <span :if={is_nil(Uploads.preview_url(u))} class="file-badge">
                {file_ext(u.filename)}
              </span>
            </div>
            <div class="upload-meta">
              <div class="filename" title={u.filename}>{u.filename}</div>
              <div class="muted">{format_bytes(u.byte_size)}</div>
            </div>
          </.link>
        </li>
      </ul>

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
        <div class="dialog">
          <header class="dialog-header">
            <h2>New upload</h2>
            <button type="button" phx-click="close_modal" class="dialog-close" aria-label="Close">
              &times;
            </button>
          </header>

          <form id="upload-form" phx-submit="save" phx-change="validate" class="dialog-form">
            <label class="dropzone" phx-drop-target={@uploads.image.ref}>
              <svg
                class="dropzone-icon"
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 7.5m0 0L7.5 12m4.5-4.5v12"
                />
              </svg>
              <.live_file_input upload={@uploads.image} />
              <p class="dropzone-headline">Drop images here, or click to browse</p>
              <p class="muted">Up to 8MB each. PNG, JPG, GIF, WebP, SVG, ICO, PDF.</p>
            </label>

            <ul :if={@uploads.image.entries != []} class="upload-entries">
              <li :for={entry <- @uploads.image.entries}>
                <input
                  type="text"
                  name={"renames[#{entry.ref}]"}
                  value={Map.get(@renamed_names, entry.ref, entry.client_name)}
                  spellcheck="false"
                  autocomplete="off"
                  phx-debounce="200"
                  class="rename-input"
                />
                <span class="muted entry-progress">{entry.progress}%</span>
                <button type="button" phx-click="cancel" phx-value-ref={entry.ref} class="btn btn-sm">
                  Remove
                </button>
                <p :for={err <- upload_errors(@uploads.image, entry)} class="error entry-error">
                  {error_to_string(err)}
                </p>
              </li>
            </ul>

            <p :for={err <- upload_errors(@uploads.image)} class="error">{error_to_string(err)}</p>

            <footer class="dialog-footer">
              <button type="button" phx-click="close_modal" class="btn">Cancel</button>
              <button type="submit" class="btn btn-primary" disabled={@uploads.image.entries == []}>
                Upload
              </button>
            </footer>
          </form>
        </div>
      </div>
    </.shell>
    """
  end

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "Too many files"
  defp error_to_string(:not_accepted), do: "Unsupported file type"
  defp error_to_string(other), do: inspect(other)

  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"

  defp file_ext(filename) do
    filename |> Path.extname() |> String.trim_leading(".") |> String.upcase()
  end

  # Apply the user's inline rename if present. Strip slashes, trim, and
  # re-attach the original extension when missing — same safety rules as
  # `Masthead.Uploads.rename/2` for an existing upload.
  defp final_filename(entry, renames) do
    case Map.get(renames || %{}, entry.ref) do
      name when is_binary(name) ->
        cleaned =
          name
          |> String.trim()
          |> String.replace(~r{[/\\]}, "")

        cond do
          cleaned == "" -> entry.client_name
          Path.extname(cleaned) == "" -> cleaned <> Path.extname(entry.client_name)
          true -> cleaned
        end

      _ ->
        entry.client_name
    end
  end
end

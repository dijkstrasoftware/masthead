defmodule MastheadWeb.AdminLive.FilePicker do
  @moduledoc """
  Shared modal upload picker. Used by the site-settings file-token chooser
  and the content editor's "Insert image" tool, so there is one picker, not
  two copies.

  Pick an existing upload or upload a new one. The chosen upload (or `nil`
  for the optional "No file" choice) is sent back to the parent LiveView as:

      {:file_picked, upload_or_nil, context}

  `context` is the map of `phx-value-*` params passed to the "open" event, so
  the parent can remember *why* it opened the picker (which token, which
  editor, ...). The parent decides what to do with the result.

  Render once per LiveView and open it from anywhere on the page:

      <.live_component
        module={MastheadWeb.AdminLive.FilePicker}
        id="settings-file-picker"
        site={@site}
        accept={~w(.png .jpg .jpeg .gif .webp .svg .ico .pdf)}
        clearable
      />

      <button phx-click="open" phx-target="#settings-file-picker"
              phx-value-token="logo" phx-value-current={current}>Choose…</button>
  """
  use MastheadWeb, :live_component

  alias Masthead.Uploads

  # The grid is a fixed 3x3. The "Upload new" card always takes a slot, and
  # the optional "No file" card takes another, so the number of *files* we
  # load is whatever is left. Images are heavy — past that, the user searches.
  @grid_slots 9

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       view: :grid,
       files: [],
       search: "",
       context: %{},
       ready?: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.put_new(assigns, :clearable, false))
      |> assign_new(:images_only, fn -> false end)
      |> assign_new(:title, fn -> "Choose a file" end)

    # allow_upload needs the parent-provided `accept`, so set it up on the
    # first update rather than in mount/1 (which has no assigns). Once only.
    socket =
      if socket.assigns.ready? do
        socket
      else
        socket
        |> allow_upload(:file,
          accept: socket.assigns.accept,
          max_entries: 1,
          max_file_size: 8_000_000
        )
        |> assign(ready?: true)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("open", params, socket) do
    {:noreply,
     socket
     |> assign(open?: true, view: :grid, context: params, search: "")
     |> load_files()}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(search: query) |> load_files()}
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}
  def handle_event("show_upload", _params, socket), do: {:noreply, assign(socket, view: :upload)}

  def handle_event("show_grid", _params, socket),
    do: {:noreply, socket |> cancel_all() |> assign(view: :grid)}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_entry", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("clear", _params, socket), do: {:noreply, pick(socket, nil)}

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, pick(socket, Uploads.get_upload(socket.assigns.site.id, id))}
  end

  def handle_event("upload", _params, socket) do
    uploaded =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        attrs = %{filename: entry.client_name, content_type: entry.client_type, path: path}

        case Uploads.store_image(socket.assigns.site, attrs) do
          {:ok, upload} -> {:ok, upload}
          {:error, reason} -> {:postpone, reason}
        end
      end)

    case uploaded do
      [%Uploads.Upload{} = upload | _] ->
        # The entry is already consumed (its process is gone), so close
        # without cancelling — cancel_all/1 would call a dead process.
        send(self(), {:file_picked, upload, socket.assigns.context})
        {:noreply, assign(socket, open?: false, view: :grid)}

      _ ->
        {:noreply, socket}
    end
  end

  # Report the choice to the parent and close (cancelling any pending entry).
  defp pick(socket, upload) do
    send(self(), {:file_picked, upload, socket.assigns.context})
    close(socket)
  end

  defp load_files(socket) do
    %{site: site, images_only: images_only, search: search} = socket.assigns

    files =
      Uploads.list_uploads(site.id,
        search: search,
        filter: if(images_only, do: :images, else: :all),
        limit: file_limit(socket.assigns.clearable)
      )

    assign(socket, files: files)
  end

  # Leave a slot for "Upload new", and one more for "No file" when the
  # parent asked for it, so the grid stays exactly 3x3 either way.
  defp file_limit(true), do: @grid_slots - 2
  defp file_limit(_clearable), do: @grid_slots - 1

  defp close(socket), do: socket |> assign(open?: false, view: :grid) |> cancel_all()

  defp cancel_all(socket) do
    Enum.reduce(socket.assigns.uploads.file.entries, socket, fn entry, acc ->
      cancel_upload(acc, :file, entry.ref)
    end)
  end

  defp current(context), do: context["current"] || ""

  defp selected_class(current, value),
    do: if(to_string(current) == to_string(value), do: " is-selected", else: "")

  defp file_ext(filename),
    do: filename |> Path.extname() |> String.trim_leading(".") |> String.upcase()

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "Too many files"
  defp error_to_string(:not_accepted), do: "Unsupported file type"
  defp error_to_string(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open?}
        class="dialog-backdrop"
        phx-window-keydown="close"
        phx-key="Escape"
        phx-target={@myself}
      >
        <button
          type="button"
          phx-click="close"
          phx-target={@myself}
          class="dialog-close-overlay"
          aria-label="Close"
          tabindex="-1"
        >
        </button>
        <div class="dialog">
          <header class="dialog-header">
            <h2>{if @view == :upload, do: "Upload a file", else: @title}</h2>
            <button
              type="button"
              phx-click="close"
              phx-target={@myself}
              class="dialog-close"
              aria-label="Close"
            >
              &times;
            </button>
          </header>

          <div :if={@view == :grid} class="dialog-body">
            <form
              :if={@files != [] or @search != ""}
              phx-change="search"
              phx-submit="search"
              phx-target={@myself}
              class="picker-search"
            >
              <input
                type="search"
                name="query"
                value={@search}
                placeholder="Search files…"
                phx-debounce="300"
                autocomplete="off"
              />
            </form>

            <ul class="picker-grid">
              <li :if={@clearable}>
                <button
                  type="button"
                  class={"picker-card" <> selected_class(current(@context), "")}
                  phx-click="clear"
                  phx-target={@myself}
                >
                  <span class="picker-thumb">
                    <span class="picker-none-icon" aria-hidden="true">⊘</span>
                  </span>
                  <span class="picker-name">No file</span>
                </button>
              </li>
              <li :for={u <- @files}>
                <button
                  type="button"
                  class={"picker-card" <> selected_class(current(@context), to_string(u.id))}
                  phx-click="select"
                  phx-value-id={u.id}
                  phx-target={@myself}
                >
                  <span class="picker-thumb">
                    <img :if={Uploads.preview_url(u)} src={Uploads.preview_url(u)} alt={u.filename} />
                    <span :if={is_nil(Uploads.preview_url(u))} class="file-badge">
                      {file_ext(u.filename)}
                    </span>
                  </span>
                  <span class="picker-name" title={u.filename}>{u.filename}</span>
                </button>
              </li>
              <li>
                <button
                  type="button"
                  class="picker-card picker-card-add"
                  phx-click="show_upload"
                  phx-target={@myself}
                >
                  <span class="picker-thumb">
                    <span class="picker-add-icon" aria-hidden="true">+</span>
                  </span>
                  <span class="picker-name">Upload new</span>
                </button>
              </li>
            </ul>

            <p :if={length(@files) == file_limit(@clearable)} class="picker-hint">
              Showing the first {file_limit(@clearable)}. Search to find more.
            </p>
            <p :if={@files == [] and @search != ""} class="picker-hint">
              No files match “{@search}”.
            </p>
          </div>

          <form
            :if={@view == :upload}
            id={@id <> "-upload-form"}
            phx-submit="upload"
            phx-change="validate"
            phx-target={@myself}
            class="dialog-body"
          >
            <label class="dropzone" phx-drop-target={@uploads.file.ref}>
              <.live_file_input upload={@uploads.file} />
              <p class="dropzone-headline">Drop a file here, or click to browse</p>
              <p class="muted">Up to 8MB.</p>
            </label>

            <ul :if={@uploads.file.entries != []} class="upload-entries">
              <li :for={entry <- @uploads.file.entries}>
                <span class="filename">{entry.client_name}</span>
                <span class="muted entry-progress">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_entry"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  class="btn btn-sm"
                >
                  Remove
                </button>
                <p :for={err <- upload_errors(@uploads.file, entry)} class="error entry-error">
                  {error_to_string(err)}
                </p>
              </li>
            </ul>

            <p :for={err <- upload_errors(@uploads.file)} class="error">{error_to_string(err)}</p>

            <div class="dialog-footer">
              <button type="button" phx-click="show_grid" phx-target={@myself} class="btn">
                Back
              </button>
              <button type="submit" class="btn btn-primary" disabled={@uploads.file.entries == []}>
                Upload &amp; use
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end

defmodule MastheadWeb.AdminLive.CompressDialog do
  @moduledoc """
  Warns that an image upload is very large for the web and offers to shrink
  it. The `CompressUpload` hook re-encodes the image in the browser (same
  format, at most 2560px), reports the before/after size, and hands the
  result to this component's upload, which then overwrites the original file
  in place — same path, same URL — via `Masthead.Uploads.replace_file/3`.

  Render once and open it with `size_warning/1` or:

      JS.push("open", target: "#compress-dialog", value: %{id: upload.id})

  With `notify`, the parent LiveView receives `{:upload_replaced, upload}`.
  """
  use MastheadWeb, :live_component

  import MastheadWeb.AdminLive.Components, only: [format_bytes: 1, storage_full_message: 1]
  alias Masthead.Uploads

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(upload: nil, result: nil, error: nil)
     |> allow_upload(:replacement,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 20_000_000,
       auto_upload: true
     )}
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    upload = Uploads.get_upload!(socket.assigns.site.id, id)
    {:noreply, socket |> cancel_entries() |> assign(upload: upload, result: nil, error: nil)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> cancel_entries() |> assign(upload: nil)}
  end

  def handle_event("compressed", %{"before" => before, "after" => after_size}, socket) do
    {:noreply, assign(socket, result: %{before: before, after: after_size})}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("replace", _params, socket) do
    %{site: site, upload: upload} = socket.assigns

    socket
    |> consume_uploaded_entries(:replacement, &replace_entry(&1, &2, site, upload))
    |> replaced(socket)
  end

  defp replace_entry(%{path: path}, _entry, site, upload),
    do: {:ok, Uploads.replace_file(site, upload, path)}

  defp replaced([{:ok, upload}], socket) do
    if socket.assigns[:notify], do: send(self(), {:upload_replaced, upload})
    {:noreply, assign(socket, upload: nil)}
  end

  defp replaced([{:error, :storage_full}], socket),
    do: {:noreply, assign(socket, error: storage_full_message(socket.assigns.site))}

  defp replaced(_results, socket),
    do: {:noreply, assign(socket, error: "The file couldn't be replaced. Try again.")}

  defp cancel_entries(socket) do
    Enum.reduce(socket.assigns.uploads.replacement.entries, socket, &cancel_entry/2)
  end

  defp cancel_entry(entry, socket), do: cancel_upload(socket, :replacement, entry.ref)

  defp ready?(uploads, %{before: before, after: after_size}),
    do: after_size < before and Enum.any?(uploads.replacement.entries, & &1.done?)

  defp ready?(_uploads, nil), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@upload}
        class="dialog-backdrop compress-backdrop"
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
            <h2>Very large image</h2>
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

          <form
            id={"#{@id}-form"}
            phx-submit="replace"
            phx-change="validate"
            phx-target={@myself}
            class="dialog-body"
          >
            <p>
              <strong>{@upload.filename}</strong>
              is {format_bytes(@upload.byte_size)}. Images this large slow down every page
              they're on, especially on phones.
            </p>
            <p class="muted">
              Compressing resizes it to at most 2560 pixels wide and re-saves it in the same
              format. The file keeps its URL, so posts and pages that use it stay as they are.
            </p>

            <div
              id={"#{@id}-work-#{@upload.id}"}
              phx-hook="CompressUpload"
              phx-target={@myself}
              data-src={~p"/#{@site.slug}/uploads/#{@upload.id}/file"}
              data-type={@upload.content_type}
              data-name={@upload.filename}
              class="compress-result"
            >
              <.live_file_input upload={@uploads.replacement} hidden />
              <p :if={is_nil(@result)} class="muted">Compressing…</p>
              <p :if={@result && @result.after < @result.before} class="compress-sizes">
                {format_bytes(@result.before)} → <strong>{format_bytes(@result.after)}</strong>
              </p>
              <p :if={@result && @result.after >= @result.before} class="muted">
                This image can't be made smaller than it already is.
              </p>
            </div>

            <p :if={@error} class="error">{@error}</p>

            <div class="dialog-footer">
              <button type="button" phx-click="close" phx-target={@myself} class="btn">
                Not now
              </button>
              <button
                :if={is_nil(@result) or @result.after < @result.before}
                type="submit"
                class="btn btn-primary"
                disabled={not ready?(@uploads, @result)}
              >
                Replace file
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end
end

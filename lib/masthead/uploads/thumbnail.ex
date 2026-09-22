defmodule Masthead.Uploads.Thumbnail do
  @moduledoc """
  Renders a small preview of an upload, so the uploads grid and the picker
  never load the full file: page 1 of a PDF as a PNG (instead of a bare file
  badge), or a photo downscaled to a WebP (instead of the multi-megabyte
  original). Photos are resized with libvips (`Vix`), in-process.

  Rendering happens out of band (`Masthead.Workers.PdfThumbnail`), never in
  the upload request: `pdftoppm` is a subprocess on user-supplied bytes and
  has no place on the hot path.

  ## Why `pdftoppm`

  Poppler, not ImageMagick/Ghostscript — the latter's PDF delegate has a
  long history of sandbox escapes on untrusted input. The invocation is
  pinned to a single page (`-f 1 -l 1 -singlefile`) so a thousand-page
  document costs the same as a one-page one, and the job carries an Oban
  `timeout/1` so a pathological file cannot pin a worker.

  Every failure path returns `{:error, reason}`. A PDF that will not
  rasterize is not an error worth retrying forever — the caller drops it and
  the UI keeps showing the file badge.
  """

  require Logger

  alias Masthead.Storage
  alias Masthead.Uploads.Upload
  alias Vix.Vips.Operation

  # Wide enough for the 220px grid card on a 2x display, small enough that a
  # page of dense text stays a cheap thumbnail.
  @width 600

  @image_types ~w(image/jpeg image/png image/webp image/gif)

  @doc "Content types `generate/2` can preview."
  def types, do: ["application/pdf" | @image_types]

  @doc "True when this upload is a type we know how to preview."
  def thumbnailable?(%Upload{content_type: type}), do: type in types()

  @doc "True when `pdftoppm` is installed. False in dev boxes without poppler."
  def available?, do: System.find_executable("pdftoppm") != nil

  @doc """
  Renders page 1 of `upload` and stores the PNG, returning
  `{:ok, thumbnail_path}`. Does not touch the DB — the worker owns that.

  The thumbnail key is derived from the upload id rather than its stored
  path, so `Masthead.Uploads.rename/2` (which rewrites `path`) never has to
  move the thumbnail alongside it.
  """
  def generate(%Upload{} = upload, site_slug) do
    cond do
      not thumbnailable?(upload) -> {:error, :unsupported_type}
      upload.content_type in @image_types -> render_image(upload, site_slug)
      not available?() -> {:error, :pdftoppm_missing}
      true -> render(upload, site_slug)
    end
  end

  defp render_image(upload, site_slug) do
    with {:ok, bytes} <- Storage.read(upload.path),
         {:ok, image} <- Operation.thumbnail_buffer(bytes, @width, size: :VIPS_SIZE_DOWN),
         {:ok, webp} <- Vix.Vips.Image.write_to_buffer(image, ".webp[Q=80]") do
      Storage.put(site_slug, thumbnail_key(upload), webp)
    end
  end

  defp render(upload, site_slug) do
    with {:ok, bytes} <- Storage.read(upload.path) do
      in_tmp_dir(fn dir ->
        source = Path.join(dir, "in.pdf")
        prefix = Path.join(dir, "out")
        File.write!(source, bytes)

        case rasterize(source, prefix) do
          :ok -> store(prefix <> ".png", upload, site_slug)
          {:error, _} = err -> err
        end
      end)
    end
  end

  # `-singlefile` makes the output exactly `<prefix>.png` instead of poppler's
  # default `<prefix>-1.png` / `<prefix>-01.png` (the page-number padding
  # varies with the page count, which would leave us guessing the filename).
  defp rasterize(source, prefix) do
    args = ["-png", "-singlefile", "-f", "1", "-l", "1", "-scale-to", "#{@width}", source, prefix]

    case System.cmd("pdftoppm", args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning("pdftoppm exited #{status}: #{String.trim(output)}")
        {:error, :rasterize_failed}
    end
  catch
    # System.cmd raises if the binary vanishes between the availability check
    # and the call; treat it like any other failed render.
    :error, reason ->
      Logger.warning("pdftoppm could not run: #{inspect(reason)}")
      {:error, :rasterize_failed}
  end

  defp store(png_path, upload, site_slug) do
    if File.exists?(png_path) do
      Storage.stream_into(site_slug, thumbnail_key(upload), png_path)
    else
      {:error, :no_output}
    end
  end

  @doc "Storage key for an upload's thumbnail, stable across renames."
  def thumbnail_key(%Upload{id: id, content_type: "application/pdf"}), do: "thumbs/#{id}.png"
  def thumbnail_key(%Upload{id: id}), do: "thumbs/#{id}.webp"

  defp in_tmp_dir(fun) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "masthead-thumb-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end
end

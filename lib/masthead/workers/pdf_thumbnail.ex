defmodule Masthead.Workers.PdfThumbnail do
  @moduledoc """
  Generates the preview for one upload (page 1 of a PDF, or a downscaled
  photo), off the request path.

  Enqueued by `Masthead.Uploads.store_image/2` and by the
  `masthead.backfill_thumbnails` task for uploads that predate the feature.

  A file that will not render is not worth retrying to exhaustion — a
  corrupt or encrypted file fails the same way every attempt — so a render
  failure is discarded rather than retried. A *missing upload* is likewise
  fine: the row was deleted between enqueue and run.
  """
  use Oban.Worker, queue: :thumbnails, max_attempts: 3

  require Logger

  alias Masthead.Uploads

  # Bounded so one pathological document cannot hold a worker indefinitely.
  # Oban kills the job process, which closes the port and reaps pdftoppm.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upload_id" => upload_id}}) do
    case Uploads.get_upload(upload_id) do
      nil ->
        :ok

      upload ->
        case Uploads.generate_thumbnail(upload) do
          {:ok, _upload} ->
            :ok

          {:error, reason} ->
            Logger.info("no thumbnail for upload #{upload.id}: #{inspect(reason)}")
            # `:discard` — the same bytes will fail the same way next attempt.
            {:discard, reason}
        end
    end
  end
end

defmodule Mix.Tasks.Masthead.BackfillThumbnails do
  @shortdoc "Queues preview generation for uploads that have no thumbnail yet"

  @moduledoc """
  Queues a `Masthead.Workers.PdfThumbnail` job for every PDF or photo upload
  that has no thumbnail yet, and reports how many were queued.

      mix masthead.backfill_thumbnails

  Safe to re-run: uploads that already have a thumbnail are skipped, so a
  second run only picks up whatever failed or arrived since. The jobs run on
  the `thumbnails` queue like any freshly uploaded PDF, so a large backlog
  drains at the same bounded rate rather than all at once.

  In a release (where Mix isn't available) call the underlying function
  instead: `Masthead.Uploads.enqueue_missing_thumbnails/0`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    unless Masthead.Uploads.Thumbnail.available?() do
      Mix.shell().info([
        :yellow,
        "warning: pdftoppm not found — jobs will queue but every render will fail.\n",
        "install poppler-utils (Debian) or poppler (brew) first.",
        :reset
      ])
    end

    count = Masthead.Uploads.enqueue_missing_thumbnails()
    Mix.shell().info("queued #{count} thumbnail job(s)")
  end
end

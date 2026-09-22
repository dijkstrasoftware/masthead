defmodule Masthead.Uploads.ThumbnailTest do
  use Masthead.DataCase
  use Oban.Testing, repo: Masthead.Repo

  alias Masthead.{Accounts, Sites, Storage, Uploads}
  alias Masthead.Uploads.Thumbnail
  alias Masthead.Workers.PdfThumbnail

  @fixture Path.expand("../../support/fixtures/sample.pdf", __DIR__)

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "th-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234"
      })

    {:ok, site} =
      Sites.create_site(%{
        "slug" => "th#{System.unique_integer([:positive])}",
        "name" => "Thumb Site",
        "owner_id" => user.id
      })

    %{site: site}
  end

  defp store_pdf(site, filename \\ "handbook.pdf") do
    tmp = Path.join(System.tmp_dir!(), "th-#{System.unique_integer([:positive])}.pdf")
    File.cp!(@fixture, tmp)

    {:ok, upload} =
      Uploads.store_image(site, %{
        filename: filename,
        content_type: "application/pdf",
        path: tmp
      })

    File.rm(tmp)
    upload
  end

  defp store_png(site, filename \\ "pic.png") do
    tmp = Path.join(System.tmp_dir!(), "th-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, "bytes")

    {:ok, upload} =
      Uploads.store_image(site, %{filename: filename, content_type: "image/png", path: tmp})

    File.rm(tmp)
    upload
  end

  defp store_svg(site) do
    tmp = Path.join(System.tmp_dir!(), "th-#{System.unique_integer([:positive])}.svg")
    File.write!(tmp, "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")

    {:ok, upload} =
      Uploads.store_image(site, %{filename: "logo.svg", content_type: "image/svg+xml", path: tmp})

    File.rm(tmp)
    upload
  end

  defp store_photo(site) do
    tmp = Path.join(System.tmp_dir!(), "th-#{System.unique_integer([:positive])}.png")
    :ok = Vix.Vips.Operation.black!(1600, 1200) |> Vix.Vips.Image.write_to_file(tmp)

    {:ok, upload} =
      Uploads.store_image(site, %{filename: "photo.png", content_type: "image/png", path: tmp})

    File.rm(tmp)
    upload
  end

  defp absolute(rel), do: Path.join(Storage.root_path(), rel)

  describe "thumbnailable?/1" do
    test "PDFs and photos are, SVGs are not", %{site: site} do
      assert Thumbnail.thumbnailable?(store_pdf(site))
      assert Thumbnail.thumbnailable?(store_png(site))
      refute Thumbnail.thumbnailable?(store_svg(site))
    end
  end

  describe "generate/2" do
    @tag :requires_poppler
    test "renders page 1 of a PDF into stored PNG bytes", %{site: site} do
      upload = store_pdf(site)

      assert {:ok, thumb_path} = Thumbnail.generate(upload, site.slug)

      # Keyed by upload id, not by the file's path — see rename test below.
      assert thumb_path == Path.join(site.slug, "thumbs/#{upload.id}.png")
      assert File.exists?(absolute(thumb_path))

      # A real PNG, not an empty or truncated file.
      assert <<137, "PNG", 13, 10, 26, 10, _rest::binary>> = File.read!(absolute(thumb_path))
      assert File.stat!(absolute(thumb_path)).size > 0
    end

    test "refuses a type it cannot rasterize", %{site: site} do
      assert {:error, :unsupported_type} = Thumbnail.generate(store_svg(site), site.slug)
    end

    test "downscales a photo into a small WebP", %{site: site} do
      upload = store_photo(site)

      assert {:ok, thumb_path} = Thumbnail.generate(upload, site.slug)
      assert thumb_path == Path.join(site.slug, "thumbs/#{upload.id}.webp")

      {:ok, thumb} = Vix.Vips.Image.new_from_file(absolute(thumb_path))
      assert Vix.Vips.Image.width(thumb) == 600
      assert Vix.Vips.Image.height(thumb) == 450
    end

    test "reports a failure instead of raising on bytes that are not an image", %{site: site} do
      assert {:error, _reason} = Thumbnail.generate(store_png(site), site.slug)
    end

    @tag :requires_poppler
    test "reports a failure instead of raising on bytes that are not a PDF", %{site: site} do
      upload = store_pdf(site)
      # Corrupt the stored object behind the row's back.
      File.write!(absolute(upload.path), "this is definitely not a pdf")

      assert {:error, reason} = Thumbnail.generate(upload, site.slug)
      assert reason in [:rasterize_failed, :no_output]
    end

    test "reports a failure when the stored object is gone", %{site: site} do
      upload = store_pdf(site)
      File.rm!(absolute(upload.path))

      assert {:error, _reason} = Thumbnail.generate(upload, site.slug)
    end
  end

  describe "store_image/2 enqueueing" do
    test "a PDF upload queues a thumbnail job", %{site: site} do
      upload = store_pdf(site)

      assert_enqueued(worker: PdfThumbnail, args: %{upload_id: upload.id})
    end

    test "a photo upload queues a thumbnail job", %{site: site} do
      upload = store_png(site)

      assert_enqueued(worker: PdfThumbnail, args: %{upload_id: upload.id})
    end

    test "an SVG upload queues nothing", %{site: site} do
      store_svg(site)

      refute_enqueued(worker: PdfThumbnail)
    end

    test "the upload itself is stored even though the preview is deferred", %{site: site} do
      upload = store_pdf(site)

      # Thumbnail generation has not run yet, so there is no preview to show.
      assert upload.thumbnail_path == nil
      assert Uploads.preview_url(upload) == nil
      assert File.exists?(absolute(upload.path))
    end
  end

  describe "preview_url/1" do
    test "an image previews as itself until its thumbnail exists", %{site: site} do
      upload = store_png(site)
      assert Uploads.preview_url(upload) == Uploads.url(upload)
    end

    test "a photo previews as its thumbnail once generated", %{site: site} do
      upload = store_photo(site)
      {:ok, upload} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))

      assert Uploads.preview_url(upload) == Storage.url(upload.thumbnail_path)
      refute Uploads.preview_url(upload) == Uploads.url(upload)
    end

    test "a PDF has no preview until one is generated", %{site: site} do
      assert Uploads.preview_url(store_pdf(site)) == nil
    end

    @tag :requires_poppler
    test "a PDF previews as its thumbnail once generated", %{site: site} do
      upload = store_pdf(site)
      {:ok, upload} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))

      assert upload.thumbnail_path != nil
      assert Uploads.preview_url(upload) == Storage.url(upload.thumbnail_path)
      # The preview is the thumbnail, never the PDF itself.
      refute Uploads.preview_url(upload) == Uploads.url(upload)
    end

    @tag :requires_poppler
    test "a PDF is still not an image, thumbnail or not", %{site: site} do
      upload = store_pdf(site)
      {:ok, upload} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))

      # `images_only` pickers must keep excluding it: having a preview is not
      # the same as being usable as an image.
      refute Uploads.image?(upload)
      assert Uploads.list_uploads(site.id, filter: :images) == []
      assert [_] = Uploads.list_uploads(site.id, filter: :documents)
    end
  end

  describe "lifecycle" do
    @tag :requires_poppler
    test "renaming the file leaves the thumbnail in place", %{site: site} do
      upload = store_pdf(site)
      {:ok, upload} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))
      thumb_path = upload.thumbnail_path

      {:ok, renamed} = Uploads.rename(upload, "employee-handbook.pdf")

      # The thumbnail key is derived from the id, so a rename never moves it.
      assert renamed.thumbnail_path == thumb_path
      assert File.exists?(absolute(thumb_path))
      assert Uploads.preview_url(renamed) == Storage.url(thumb_path)
    end

    @tag :requires_poppler
    test "deleting the upload deletes its thumbnail too", %{site: site} do
      upload = store_pdf(site)
      {:ok, upload} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))
      thumb_abs = absolute(upload.thumbnail_path)
      assert File.exists?(thumb_abs)

      {:ok, _} = Uploads.delete_upload(upload)

      refute File.exists?(thumb_abs)
      refute File.exists?(absolute(upload.path))
      assert Uploads.get_upload(upload.id) == nil
    end

    test "deleting a PDF that never got a thumbnail still works", %{site: site} do
      upload = store_pdf(site)

      assert {:ok, _} = Uploads.delete_upload(upload)
      assert Uploads.get_upload(upload.id) == nil
    end
  end

  describe "enqueue_missing_thumbnails/0" do
    test "queues PDFs and photos without a thumbnail and skips the rest", %{site: site} do
      pdf = store_pdf(site, "one.pdf")
      png = store_png(site)
      store_svg(site)

      # Oban.Testing leaves the store_image jobs in the table; count only the
      # ones this call adds by draining the table first.
      Masthead.Repo.delete_all(Oban.Job)

      assert Uploads.enqueue_missing_thumbnails() == 2
      assert_enqueued(worker: PdfThumbnail, args: %{upload_id: pdf.id})
      assert_enqueued(worker: PdfThumbnail, args: %{upload_id: png.id})
    end

    @tag :requires_poppler
    test "skips a PDF that already has a thumbnail", %{site: site} do
      upload = store_pdf(site)
      {:ok, _} = Uploads.generate_thumbnail(Uploads.get_upload(upload.id))
      Masthead.Repo.delete_all(Oban.Job)

      assert Uploads.enqueue_missing_thumbnails() == 0
    end
  end

  describe "PdfThumbnail worker" do
    @tag :requires_poppler
    test "sets the thumbnail path on the row", %{site: site} do
      upload = store_pdf(site)

      assert :ok = perform_job(PdfThumbnail, %{"upload_id" => upload.id})

      assert Uploads.get_upload(upload.id).thumbnail_path != nil
    end

    test "an upload deleted before the job runs is not an error", %{site: site} do
      upload = store_pdf(site)
      {:ok, _} = Uploads.delete_upload(upload)

      assert :ok = perform_job(PdfThumbnail, %{"upload_id" => upload.id})
    end

    @tag :requires_poppler
    test "a file that cannot be rendered is discarded, not retried forever", %{site: site} do
      upload = store_pdf(site)
      File.write!(absolute(upload.path), "not a pdf at all")

      assert {:discard, _reason} = perform_job(PdfThumbnail, %{"upload_id" => upload.id})
    end
  end
end

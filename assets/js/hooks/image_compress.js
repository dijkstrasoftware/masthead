// LiveView hook: compress images in the browser before they upload.
//
// The dropzone holds two file inputs: a plain `.js-image-picker` the user
// actually clicks/drops onto, and the LiveView `live_file_input` that does the
// real upload. On selection or drop we resize each image to at most
// data-max-dim px on its longest side, re-encode as JPEG at data-quality, then
// hand the compressed files to the live_file_input (via a DataTransfer) and let
// LiveView upload them. Non-raster files (and GIFs) pass through untouched.
//
//   <label class="dropzone" id="…" phx-hook="ImageCompress"
//          data-max-dim="1600" data-quality="0.8">
//     <input type="file" multiple accept="image/*" class="js-image-picker" />
//     <.live_file_input upload={@uploads.preview} />
//   </label>
export const ImageCompress = {
  mounted() {
    this.maxDim = parseInt(this.el.dataset.maxDim || "1600", 10)
    this.quality = parseFloat(this.el.dataset.quality || "0.8")
    this.picker = this.el.querySelector(".js-image-picker")
    this.liveInput = this.el.querySelector("input[type='file']:not(.js-image-picker)")

    if (this.picker) {
      this.picker.addEventListener("change", () => this.handle(this.picker.files))
    }

    this.el.addEventListener("dragover", (e) => e.preventDefault())
    this.el.addEventListener("drop", (e) => {
      e.preventDefault()
      this.handle(e.dataTransfer && e.dataTransfer.files)
    })
  },

  async handle(fileList) {
    const files = Array.from(fileList || [])
    if (files.length === 0 || !this.liveInput) return

    const out = []
    for (const file of files) {
      out.push(await compress(file, this.maxDim, this.quality))
    }

    // Feed the compressed files to LiveView's own file input and let it upload.
    feedInput(this.liveInput, out)

    if (this.picker) this.picker.value = "" // allow re-selecting the same file
  },
}

export function feedInput(input, files) {
  const dt = new DataTransfer()
  files.forEach((f) => dt.items.add(f))
  input.files = dt.files
  input.dispatchEvent(new Event("input", {bubbles: true}))
  input.dispatchEvent(new Event("change", {bubbles: true}))
}

export async function compress(file, maxDim, quality, type = "image/jpeg") {
  // Only re-encode raster photos; leave GIFs (animation) and non-images alone.
  if (!file.type.startsWith("image/") || file.type === "image/gif") return file

  try {
    const bitmap = await createImageBitmap(file)
    const scale = Math.min(1, maxDim / Math.max(bitmap.width, bitmap.height))
    const width = Math.round(bitmap.width * scale)
    const height = Math.round(bitmap.height * scale)

    const canvas = document.createElement("canvas")
    canvas.width = width
    canvas.height = height
    canvas.getContext("2d").drawImage(bitmap, 0, 0, width, height)

    const blob = await new Promise((resolve) =>
      canvas.toBlob(resolve, type, quality)
    )

    // Keep the original if compression didn't actually shrink it.
    if (!blob || blob.size >= file.size) return file

    const name = type === file.type ? file.name : file.name.replace(/\.[^.]+$/, "") + ".jpg"
    return new File([blob], name, {type, lastModified: Date.now()})
  } catch (_err) {
    return file
  }
}

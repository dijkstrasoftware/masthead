import {compress, feedInput} from "./image_compress"

export const CompressUpload = {
  async mounted() {
    const {src, type, name} = this.el.dataset

    try {
      const blob = await fetch(src).then((response) => response.blob())
      const original = new File([blob], name, {type})
      const result = await compress(original, 2560, 0.8, type)
      if (result !== original) feedInput(this.el.querySelector("input[type='file']"), [result])
      this.pushEventTo(this.el, "compressed", {before: original.size, after: result.size})
    } catch (_error) {
      this.pushEventTo(this.el, "compressed", {before: 0, after: 0})
    }
  },
}

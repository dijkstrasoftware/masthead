// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/masthead"
import topbar from "../vendor/topbar"
import {CodeEditor} from "./hooks/code_editor"
import {FlashToast} from "./hooks/flash_toast"
import {BadgePulse} from "./hooks/badge_pulse"
import {SaveShortcut} from "./hooks/save_shortcut"
import {SortableList} from "./hooks/sortable_list"
import {ImageCompress} from "./hooks/image_compress"
import {CompressUpload} from "./hooks/compress_upload"
import {CommandPalette} from "./hooks/command_palette"

try {
  if (localStorage.getItem("masthead:feature:stats") === "1") document.documentElement.classList.add("feature-stats")
} catch (_error) {}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    CodeEditor,
    FlashToast,
    BadgePulse,
    SaveShortcut,
    SortableList,
    ImageCompress,
    CompressUpload,
    CommandPalette,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// A live navigation never reloads the page, so gtag has to be told by hand.
// No-op on every page where the analytics snippet wasn't rendered.
window.addEventListener("phx:navigate", ({detail}) => {
  window.gtag && gtag("event", "page_view", {page_location: detail.href})
})

// Global clipboard handler — buttons can do
// phx-click={JS.dispatch("masthead:copy", detail: %{text: "..."})}
// and the button label briefly flips to "Copied!".
window.addEventListener("masthead:copy", e => {
  const text = e.detail && e.detail.text
  if (!text) return
  navigator.clipboard.writeText(text).then(() => {
    const btn = e.target
    if (btn && btn.classList && btn.classList.contains("copy-btn")) {
      const original = btn.textContent
      btn.textContent = "Copied!"
      btn.classList.add("copy-btn-success")
      setTimeout(() => {
        btn.textContent = original
        btn.classList.remove("copy-btn-success")
      }, 1400)
    }
  })
})

// Confetti burst, pushed from the server as `push_event("celebrate", …)`.
// Web Animations API on a handful of divs — a celebration isn't worth a
// dependency. `detail.from` is a selector to fire from; defaults to the
// element that most recently caused it.
const CONFETTI_COLORS = ["#2563eb", "#22c55e", "#f59e0b", "#ec4899", "#8b5cf6", "#06b6d4"]

window.addEventListener("phx:celebrate", e => {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

  const anchor = document.querySelector((e.detail && e.detail.from) || "body")
  if (!anchor) return

  const box = anchor.getBoundingClientRect()
  confettiBurst(box.left + box.width / 2, box.top + box.height / 2)
})

function confettiBurst(x, y) {
  const layer = document.createElement("div")
  layer.className = "confetti-layer"
  document.body.appendChild(layer)

  for (let i = 0; i < 36; i++) {
    const piece = document.createElement("i")
    piece.className = "confetti-piece"
    piece.style.left = `${x}px`
    piece.style.top = `${y}px`
    piece.style.background = CONFETTI_COLORS[i % CONFETTI_COLORS.length]
    layer.appendChild(piece)

    // Fan out in a full circle, then let gravity pull everything down.
    const angle = (Math.PI * 2 * i) / 36 + Math.random() * 0.3
    const distance = 80 + Math.random() * 140
    const dx = Math.cos(angle) * distance
    const dy = Math.sin(angle) * distance

    piece.animate(
      [
        {transform: "translate(0, 0) rotate(0deg) scale(1)", opacity: 1, offset: 0},
        {transform: `translate(${dx * 0.8}px, ${dy * 0.8}px) rotate(180deg) scale(1)`, opacity: 1, offset: 0.45},
        {transform: `translate(${dx}px, ${dy + 160}px) rotate(${540 + Math.random() * 360}deg) scale(0.6)`, opacity: 0, offset: 1},
      ],
      {duration: 1100 + Math.random() * 600, easing: "cubic-bezier(.15,.7,.4,1)", fill: "forwards"}
    )
  }

  setTimeout(() => layer.remove(), 1800)
}

// Relative timestamps (.rel-time) server-render their exact-date tooltip in
// UTC as a no-JS fallback; on hover, rewrite it to the viewer's local
// timezone. Delegated so it survives LiveView patches without per-element
// hooks, and recomputed on every hover so a patch can't leave it stale.
const tooltipDate = new Intl.DateTimeFormat(undefined, {month: "short", day: "numeric", year: "numeric"})
const tooltipTime = new Intl.DateTimeFormat(undefined, {hour: "numeric", minute: "2-digit"})
document.addEventListener("pointerover", e => {
  const el = e.target.closest && e.target.closest(".rel-time[datetime]")
  if (!el) return
  const at = new Date(el.getAttribute("datetime"))
  if (isNaN(at)) return
  el.dataset.tooltip = `${tooltipDate.format(at)} at ${tooltipTime.format(at)}`
})

// Sign-up: block submit unless the two password fields match. Uses the
// native validity bubble — no server round-trip, no LiveView needed.
function wirePasswordConfirm(form) {
  const pw = form.querySelector("input[name='user[password]']")
  const confirm = form.querySelector("input[name='user[password_confirmation]']")
  if (!pw || !confirm) return
  const check = () => {
    const mismatch = confirm.value && confirm.value !== pw.value
    confirm.setCustomValidity(mismatch ? "Passwords do not match" : "")
  }
  pw.addEventListener("input", check)
  confirm.addEventListener("input", check)
}
document.querySelectorAll("form[data-confirm-password]").forEach(wirePasswordConfirm)

// Keyboard shortcuts. Pages opt in by adding data-shortcut="save",
// "publish", "new", or "search" to the relevant element.
//   - Cmd/Ctrl+S        → save
//   - Cmd/Ctrl+Shift+S  → publish (falls back to save if absent)
//   - Cmd/Ctrl+F        → focus the list's search box (browser find otherwise)
//   - Cmd/Ctrl+K        → open the command palette
//   - c (no modifier)   → new (ignored while typing in an input)
function isEditableTarget(el) {
  if (!el) return false
  const tag = el.tagName
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || el.isContentEditable
}

window.addEventListener("keydown", e => {
  const mod = e.metaKey || e.ctrlKey

  if (mod && (e.key === "s" || e.key === "S")) {
    const target =
      (e.shiftKey && document.querySelector("[data-shortcut='publish']")) ||
      document.querySelector("[data-shortcut='save']")
    if (!target) return
    e.preventDefault()
    target.click()
    return
  }

  if (mod && (e.key === "k" || e.key === "K")) {
    const target = document.querySelector("[data-shortcut='palette']")
    if (!target) return
    e.preventDefault()
    target.click()
    return
  }

  // Only hijack find on pages that actually have a search box — everywhere
  // else Cmd/Ctrl+F must still open the browser's own find bar.
  if (mod && (e.key === "f" || e.key === "F")) {
    const target = document.querySelector("[data-shortcut='search']")
    if (!target) return
    e.preventDefault()
    target.focus()
    target.select()
    return
  }

  if (!mod && !e.altKey && (e.key === "c" || e.key === "C") && !isEditableTarget(e.target)) {
    const target = document.querySelector("[data-shortcut='new']")
    if (!target) return
    e.preventDefault()
    target.click()
  }

  // Escape closes the mobile sidebar drawer (opened via the hamburger).
  if (e.key === "Escape") {
    const shell = document.getElementById("admin-shell")
    if (shell && shell.classList.contains("nav-open")) {
      shell.classList.remove("nav-open")
    }
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


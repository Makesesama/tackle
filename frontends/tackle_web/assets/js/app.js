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
import {hooks as colocatedHooks} from "phoenix-colocated/tackle_web"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Asking the assistant about a range of lines is the reviewer's selection, not
// the browser's. The gutter is the handle: a click selects one line, dragging
// over numbers extends it, and a shift-click grows the selection that is already
// there. The lines are painted immediately so the drag tracks the pointer, then
// the range is handed to the server, which owns the selection and sends it back
// to every viewer of the review.
const LineSelection = {
  mounted() {
    this.drag = null

    this.onMouseDown = (e) => this.mouseDown(e)
    this.onMouseMove = (e) => this.mouseMove(e)
    this.onMouseUp = (e) => this.mouseUp(e)
    this.onKeyDown = (e) => {
      if (e.key === "Escape") this.clear()
    }

    this.el.addEventListener("mousedown", this.onMouseDown)
    this.el.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup", this.onMouseUp)
    document.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    document.removeEventListener("mouseup", this.onMouseUp)
    document.removeEventListener("keydown", this.onKeyDown)
  },

  // Keeps the local highlight alive across a re-render that happens mid-drag,
  // such as a streamed token arriving while a range is still being drawn.
  updated() {
    if (this.drag) this.paint(this.drag)
  },

  // Only the gutter, the marker and the action rail start a selection. The code
  // itself stays the browser's to select and copy.
  mouseDown(e) {
    if (e.button !== 0) return
    if (!e.target.closest(".diff-gutter, .diff-marker, .diff-action")) return
    if (e.target.closest("button, a, input, select, textarea")) return

    const at = this.lineFrom(e.target)
    if (!at) return

    e.preventDefault()

    let from = at.line
    let extend = false

    if (e.shiftKey) {
      const existing = this.selectedRange(at.path, at.side)
      if (existing) {
        from = existing.from
        extend = true
      }
    }

    this.drag = {path: at.path, side: at.side, from, to: at.line, extend}
    this.paint(this.drag)
  },

  mouseMove(e) {
    if (!this.drag) return

    const at = this.lineFrom(e.target)
    if (!at || at.path !== this.drag.path || at.side !== this.drag.side) return

    this.drag.to = at.line
    this.paint(this.drag)
  },

  mouseUp() {
    if (!this.drag) return

    const drag = this.drag
    this.drag = null

    this.pushEvent("select_lines", {
      path: drag.path,
      side: drag.side,
      from: String(drag.from),
      to: String(drag.to),
      extend: drag.extend,
    })
  },

  clear() {
    this.drag = null
    this.el.querySelectorAll(".diff-line--selected").forEach((line) => {
      line.classList.remove("diff-line--selected")
    })
    this.pushEvent("clear_selection", {})
  },

  lineFrom(target) {
    const line = target.closest(".diff-line[data-path]")
    if (!line || !this.el.contains(line)) return null

    const number = parseInt(line.dataset.line, 10)
    if (!Number.isInteger(number)) return null

    return {path: line.dataset.path, side: line.dataset.side, line: number}
  },

  selectedRange(path, side) {
    const numbers = [...this.el.querySelectorAll(".diff-line--selected[data-path]")]
      .filter((line) => line.dataset.path === path && line.dataset.side === side)
      .map((line) => parseInt(line.dataset.line, 10))
      .filter(Number.isInteger)

    if (numbers.length === 0) return null

    return {from: Math.min(...numbers), to: Math.max(...numbers)}
  },

  paint({path, side, from, to}) {
    const low = Math.min(from, to)
    const high = Math.max(from, to)

    this.el.querySelectorAll(".diff-line[data-path]").forEach((line) => {
      const number = parseInt(line.dataset.line, 10)
      const selected =
        line.dataset.path === path &&
        line.dataset.side === side &&
        number >= low &&
        number <= high

      line.classList.toggle("diff-line--selected", selected)
    })
  },
}

// The conversation panel follows its own tail while a reader is at the bottom of
// it, and stays where the reader left it when they have scrolled up to read.
const AutoScroll = {
  mounted() {
    this.stick = true
    this.el.addEventListener("scroll", () => {
      this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 48
    })
  },

  updated() {
    if (this.stick) this.el.scrollTop = this.el.scrollHeight
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LineSelection, AutoScroll},
  // Shift-clicking a line's number extends a question to a range, so the server
  // has to know whether the modifier was held. LiveView does not send it
  // otherwise.
  metadata: {
    click: (e, _el) => ({shiftKey: e.shiftKey}),
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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


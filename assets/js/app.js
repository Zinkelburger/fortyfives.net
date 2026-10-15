// Browser entry point: connects the LiveView socket and registers the
// client-side hooks the game and lobby pages rely on (card selection,
// Turnstile, the private-lobby share link, and flash auto-dismissal).

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {record} from "../vendor/rrweb-record"
import {CardSelection} from "./card_selection.mjs"
import {ResumeAnywhere} from "./resume_anywhere.mjs"
import {Turnstile} from "./turnstile_hook.mjs"
import {createSessionRecorder} from "./session_recorder.mjs"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {};

Hooks.Turnstile = Turnstile;

// Copies text to the clipboard. `navigator.clipboard` only exists in secure
// contexts (https / localhost), so plain-http deployments fall back to the
// legacy selection-based copy instead of throwing.
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text)
  }

  return new Promise((resolve, reject) => {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    let copied = false
    try {
      copied = document.execCommand("copy")
    } finally {
      document.body.removeChild(textarea)
    }
    copied ? resolve() : reject(new Error("copy unsupported"))
  })
}

Hooks.CopyShareLink = {
  mounted() {
    this.copy = () => {
      const shareLink = document.getElementById("share_link")
      if (!shareLink) return

      copyText(shareLink.textContent.trim())
        .then(() => {
          this.el.classList.add("copied")
          this.timeout = setTimeout(() => this.el.classList.remove("copied"), 1500)
        })
        .catch(() => {
          // Leave the URL selectable so the user can copy it by hand.
          const range = document.createRange()
          range.selectNodeContents(shareLink)
          const selection = window.getSelection()
          selection.removeAllRanges()
          selection.addRange(range)
        })
    }

    this.el.addEventListener("click", this.copy)
  },
  destroyed() {
    this.el.removeEventListener("click", this.copy)
    if (this.timeout) clearTimeout(this.timeout)
  },
}

Hooks.CardSelection = CardSelection
Hooks.ResumeAnywhere = ResumeAnywhere

// Drains the progress bar of a flash message and then clicks it away. Only
// real, visible flashes get this hook (see CoreComponents.flash/1); the
// hidden connection-error flashes must not dismiss themselves.
Hooks.AutoDismissFlash = {
  mounted() {
    const progressBar = this.el.querySelector('.progress-bar');
    let width = 100;
    this.interval = setInterval(() => {
      width -= 2;
      if (progressBar) progressBar.style.width = width + '%';
      if (width <= 0) {
        this.stop();
        this.el.click();
      }
    }, 120);
  },
  destroyed() {
    this.stop();
  },
  stop() {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }
};

Hooks.ScoringCountdown = {
  mounted() {
    this.seconds = parseInt(this.el.dataset.seconds || "0")
    this.el.innerText = this.seconds
    this.interval = setInterval(() => {
      this.seconds--
      if (this.seconds >= 0) {
        this.el.innerText = this.seconds
      } else {
        clearInterval(this.interval)
      }
    }, 1000)
  },
  destroyed() {
    if (this.interval) clearInterval(this.interval)
  }
}

// Counts down the last seconds before a bot takes over the seat. The server
// renders how long is left (data-ms-left) whenever the game state changes;
// only a new reading re-anchors the count. Unrelated patches (the session
// recorder's, say) re-render the same stale reading and must not reset it.
Hooks.TurnClock = {
  mounted() { this.start() },
  updated() {
    if (this.el.dataset.msLeft !== this.reading) this.start()
    else this.tick()
  },
  destroyed() { clearInterval(this.interval) },
  start() {
    clearInterval(this.interval)
    this.reading = this.el.dataset.msLeft
    const left = parseInt(this.reading || '', 10)
    this.endsAt = Number.isNaN(left) ? null : Date.now() + left
    this.tick()
    if (this.endsAt) this.interval = setInterval(() => this.tick(), 250)
  },
  tick() {
    const seconds = this.endsAt ? Math.ceil((this.endsAt - Date.now()) / 1000) : 0
    this.show(seconds > 0 && seconds <= 10 ? seconds : null)
    if (this.endsAt && seconds <= 0) clearInterval(this.interval)
  },
  show(seconds) {
    const text = seconds ? `Bot in ${seconds}s` : ''
    if (this.el.textContent !== text) this.el.textContent = text
    const label = seconds ? `A bot plays for you in ${seconds} seconds` : ''
    if (this.el.getAttribute('aria-label') !== label) this.el.setAttribute('aria-label', label)
  },
}

Hooks.GameDialog = {
  mounted() {
    this.opener = document.activeElement
    // Native modal inertness survives LiveView patches to the game behind it.
    this.el.showModal()
    this.cancel = event => {
      event.preventDefault()
      this.pushEvent('close_game_dialog', {})
    }
    this.el.addEventListener('cancel', this.cancel)
    this.previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    this.trap = event => {
      if (event.key !== 'Tab') return
      const controls = [...this.el.querySelectorAll('button:not(:disabled), a[href], [tabindex="0"]')]
      const first = controls[0], last = controls[controls.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault(); last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault(); first.focus()
      }
    }
    this.el.addEventListener('keydown', this.trap)
    this.el.querySelector('#close-score-overlay').focus()
  },
  updated() {
    if (!this.el.open) this.el.showModal()
  },
  destroyed() {
    this.el.close()
    this.el.removeEventListener('cancel', this.cancel)
    document.body.style.overflow = this.previousOverflow
    this.el.removeEventListener('keydown', this.trap)
    if (this.opener?.isConnected) this.opener.focus()
  },
}

Hooks.ShareGame = {
  mounted() {
    this.el.hidden = !navigator.share
    this.share = async () => {
      try {
        await navigator.share({title: 'Play Forty Fives', url: document.getElementById('share_link').textContent.trim()})
      } catch (_) { /* Dismissal leaves the Copy action available. */ }
    }
    this.el.addEventListener('click', this.share)
  },
  updated() { this.el.hidden = !navigator.share },
  destroyed() { this.el.removeEventListener('click', this.share) },
}

Hooks.SessionRecorder = createSessionRecorder(record)

// Viewport and referrer feed the site analytics (Website45sV3Web.SiteTracking).
let liveSocket = new LiveSocket("/live", Socket, {
  params: {
    _csrf_token: csrfToken,
    _vw: window.innerWidth,
    _vh: window.innerHeight,
    _ref: document.referrer
  },
  hooks: Hooks
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

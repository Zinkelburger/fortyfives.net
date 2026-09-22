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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {};

// Renders a Cloudflare Turnstile widget (api.js is loaded with
// ?render=explicit in the root layout, so nothing auto-renders). Turnstile
// tokens are single-use: the server pushes "turnstile:reset" after a failed
// submit so the retry gets a fresh token instead of timeout-or-duplicate.
Hooks.Turnstile = {
  mounted() {
    this.widgetId = null;
    this.handleEvent("turnstile:reset", () => {
      if (this.widgetId !== null && window.turnstile) {
        window.turnstile.reset(this.widgetId);
      }
    });
    this.renderWidget();
  },
  destroyed() {
    if (this.widgetId !== null && window.turnstile) {
      window.turnstile.remove(this.widgetId);
      this.widgetId = null;
    }
  },
  renderWidget() {
    if (this.widgetId !== null) return;
    if (window.turnstile) {
      this.widgetId = window.turnstile.render(this.el, {
        sitekey: this.el.dataset.sitekey,
        action: this.el.dataset.action,
        theme: "dark",
        "response-field-name": "cf-turnstile-response",
      });
    } else if (document.body.contains(this.el)) {
      setTimeout(() => this.renderWidget(), 100);
    }
  },
};

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

Hooks.CardSelection = {
  mounted() {
    this.selectedCards = new Set();
    this.discardLimit = 5;
    this.handleCardClickRef = (event) => this.handleCardClick(event);
    this.handleDiscardConfirmedRef = () => {
      this.locked = true;
      this.clearSelection();
    };

    this.syncStateFromDataset();
    this.el.addEventListener('click', this.handleCardClickRef);
    this.el.addEventListener('discard-confirmed', this.handleDiscardConfirmedRef);
    this.sync();
    this.render();
  },

  updated() {
    const previousPhase = this.phase;
    const previousSelectionVersion = this.selectionVersion;
    const previousAutoPlaying = this.autoPlaying;

    this.syncStateFromDataset();

    if (
      previousPhase !== this.phase ||
      previousSelectionVersion !== this.selectionVersion ||
      previousAutoPlaying !== this.autoPlaying
    ) {
      this.clearSelection();
    } else {
      this.render();
      this.sync();
    }
  },

  destroyed() {
    this.el.removeEventListener('click', this.handleCardClickRef);
    this.el.removeEventListener('discard-confirmed', this.handleDiscardConfirmedRef);
  },

  handleCardClick(event) {
    if (this.locked) return;

    const card = event.target.closest('img[data-card-value]');
    if (!card || card.classList.contains('grayed-out')) return;

    const cardValue = card.dataset.cardValue;
    if (this.phase === 'Discard') {
      this.toggleDiscardSelection(cardValue);
    } else if (this.phase === 'Playing') {
      this.togglePlaySelection(cardValue);
    }

    this.render();
    this.sync();
  },

  toggleDiscardSelection(cardValue) {
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.delete(cardValue);
    } else {
      if (this.selectedCards.size >= this.discardLimit) {
        const first = this.selectedCards.values().next().value;
        this.selectedCards.delete(first);
      }
      this.selectedCards.add(cardValue);
    }
  },

  togglePlaySelection(cardValue) {
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.clear();
    } else {
      this.selectedCards.clear();
      this.selectedCards.add(cardValue);
    }
  },

  syncStateFromDataset() {
    this.phase = this.el.dataset.phase;
    this.selectionVersion = this.el.dataset.selectionVersion || '';
    this.autoPlaying = this.el.dataset.autoPlaying === 'true';
    this.updateLockState();
  },

  updateLockState() {
    this.locked = this.autoPlaying || !['Discard', 'Playing'].includes(this.phase);
  },

  clearSelection() {
    this.selectedCards.clear();
    this.render();
    this.sync();
  },

  render() {
    this.el.querySelectorAll('img[data-card-value]').forEach(img => {
      const isSelected = this.selectedCards.has(img.dataset.cardValue);
      img.classList.toggle('selected-card', isSelected);
    });
  },

  sync() {
    this.el.dataset.selectedCards = JSON.stringify(Array.from(this.selectedCards));
  }
};

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
    }, 30);
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

Hooks.PlayCardButton = {
  mounted() {
    this.handleClick = () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length === 1) {
        this.pushEvent('play-card', {cards: cards})
      }
    }

    this.el.addEventListener('click', this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener('click', this.handleClick)
  }
}

Hooks.ConfirmDiscardButton = {
  mounted() {
    this.handleClick = () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length > 0 && cards.length <= 5) {
        this.pushEvent('confirm_discard', {cards: cards})
        hand.dispatchEvent(new CustomEvent('discard-confirmed'))
      }
    }

    this.el.addEventListener('click', this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener('click', this.handleClick)
  }
}

// Records the game page with rrweb (DOM, clicks, sampled mouse movement)
// and ships the events to the server in batches over the LiveView socket,
// where they are stored gzipped (see Website45sV3.Analytics). Only the game
// page is recorded, inputs are masked, and the server can switch recording
// off with data-record="false". Each click is also described (what was
// clicked, did it do anything) and sent alongside the batch, which is what
// the analysis reads: rrweb's own click events only carry node ids.
Hooks.SessionRecorder = {
  FLUSH_MS: 10000,
  MAX_BUFFER: 400,

  mounted() {
    if (this.el.dataset.record !== "true") return
    this.seq = 0
    this.buffer = []
    this.clicks = []
    this.stopRecording = record({
      emit: (event) => {
        this.buffer.push(event)
        if (this.buffer.length >= this.MAX_BUFFER) this.flush()
      },
      maskAllInputs: true,
      slimDOMOptions: "all",
      sampling: {mousemove: 50, mouseInteraction: true, scroll: 150, input: "last"},
    })
    this.onClick = (event) => this.logClick(event)
    document.addEventListener("click", this.onClick, true)
    this.onVisibility = () => {
      if (document.visibilityState === "hidden") this.flush()
    }
    document.addEventListener("visibilitychange", this.onVisibility)
    this.timer = setInterval(() => this.flush(), this.FLUSH_MS)
  },

  // The server sets data-record="false" once it stops accepting batches
  // (the recording hit its cap, or storing it failed). Stop then, rather
  // than recording on and shipping batches it will only discard.
  updated() {
    if (this.stopRecording && this.el.dataset.record !== "true") this.stop(false)
  },

  logClick(event) {
    const target = event.target instanceof Element ? event.target : null
    if (!target) return
    const interactive = target.closest(
      "button, a, input, select, label, [phx-click], [phx-hook], [role=button]"
    )
    const el = interactive || target
    const phx = el.getAttribute("phx-click")
    const card = target.closest("[data-card-value]")
    const phase = this.el.dataset.phase
    const auto = this.el.dataset.autoPlaying === "true"
    // Cards only respond while discarding or playing and no bot has the
    // seat (see CardSelection.updateLockState); a click on one at any other
    // time is a dead click even though the card is a button.
    const cardsLocked = auto || !["Discard", "Playing"].includes(phase)
    const click = {
      // What was clicked, as a short selector-ish label.
      el: el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
        (el.className && typeof el.className === "string"
          ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".")
          : ""),
      phx: phx || null,
      card: card ? card.dataset.cardValue : null,
      text: interactive ? (interactive.textContent || "").trim().slice(0, 40) : null,
      // A click that does nothing: the classic "I thought that did something".
      dead: !interactive || (card !== null && cardsLocked),
      phase,
      turn: this.el.dataset.currentTurn === "true",
      auto,
    }
    // In the recording for the player, and with the batch for the timeline.
    record.addCustomEvent("click", click)
    this.clicks.push({ts: Date.now(), ...click})
  },

  flush() {
    if (!this.buffer || this.buffer.length === 0) return
    const events = this.buffer
    const clicks = this.clicks
    this.buffer = []
    this.clicks = []
    // `now` lets the server put the click times on its own clock.
    const payload = {seq: this.seq++, data: JSON.stringify(events), clicks, now: Date.now()}
    if (payload.seq === 0) {
      payload.device = /Mobi|Android|iPhone|iPad/.test(navigator.userAgent) ? "mobile" : "desktop"
      payload.w = window.innerWidth
      payload.h = window.innerHeight
    }
    try {
      this.pushEvent("replay_chunk", payload)
    } catch (_error) {
      // The view is gone (navigation, disconnect); the tail of the
      // recording is lost, which is fine.
    }
  },

  // Ends the recording; `flush` says whether to ship what is buffered
  // (leaving the page) or drop it (the server stopped listening).
  stop(flush) {
    clearInterval(this.timer)
    document.removeEventListener("click", this.onClick, true)
    document.removeEventListener("visibilitychange", this.onVisibility)
    if (flush) this.flush()
    this.stopRecording()
    this.stopRecording = null
    this.buffer = []
    this.clicks = []
  },

  destroyed() {
    if (this.stopRecording) this.stop(true)
  },
}

let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks})

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

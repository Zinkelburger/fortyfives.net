// Records the game page with rrweb (DOM, clicks, sampled mouse movement)
// and ships the events to the server in batches over the LiveView socket,
// where they are stored gzipped (see Website45sV3.Analytics). Only the game
// page is recorded, inputs are masked, and the server can switch recording
// off with data-record="false". Each click is also described (what was
// clicked, did it do anything) and sent alongside the batch, which is what
// the analysis reads: rrweb's own click events only carry node ids.
export function createSessionRecorder(record) {
  return {
    FLUSH_MS: 10000,
    MAX_BUFFER: 400,

    mounted() {
      this.start()
    },

    // LiveView retains the hook across a reconnect, but the new server view
    // has no replay identity. Start a new stream with metadata and a full DOM.
    disconnected() {
      this.stop(false)
    },

    reconnected() {
      this.start()
    },

    start() {
      if (this.stopRecording || this.el.dataset.record !== "true") return
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
      this.flush()
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
      const card = target.closest("[data-card-value], [data-card]")
      const phase = this.el.dataset.phase
      const auto = this.el.dataset.autoPlaying === "true"
      // Cards only respond while discarding or playing and no bot has the
      // seat (see CardSelection.locked); a click on one at any other
      // time is a dead click even though the card is a button.
      const cardsLocked = auto || !["Discard", "Playing"].includes(phase)
      const click = {
        // What was clicked, as a short selector-ish label.
        el: el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
          (el.className && typeof el.className === "string"
            ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".")
            : ""),
        phx: phx || null,
        card: card ? (card.dataset.cardValue || card.dataset.card) : null,
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
      if (!this.stopRecording) return
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
}

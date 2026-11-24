// The clock before a bot takes over the seat, shown twice: the hand panel's
// top edge drains over the whole turn, and a pill counts the last seconds.

export const LAST_SECONDS = 10
const HELD = 'turn-clock-held'

// What both show with `left` of `total` milliseconds to go. `part` is how
// much of the edge remains; with reduced motion it moves once a second
// instead of gliding.
export function clockView(left, total, still = false) {
  if (!(left > 0)) return {seconds: 0, part: 0, last: false}
  const seconds = Math.ceil(left / 1000)
  const shown = still ? seconds * 1000 : left
  const part = total > 0 ? Math.min(shown / total, 1) : 0
  return {seconds, part, last: seconds <= LAST_SECONDS}
}

// The server renders how long is left (data-ms-left) whenever the game state
// changes; only a new reading re-anchors the count. Unrelated patches (the
// session recorder's, say) re-render the same stale reading and must not
// reset it, but they do strip what the hook set, so every patch redraws.
// The edge is the element that also carries the full timeout (data-ms-total).
export const TurnClock = {
  mounted() {
    this.still = window.matchMedia('(prefers-reduced-motion: reduce)')
    this.fit = () => { this.hold(); this.tick() }
    window.addEventListener('resize', this.fit)
    this.start()
  },
  updated() {
    if (this.el.dataset.msLeft !== this.reading) this.start()
    else this.tick()
  },
  destroyed() {
    clearInterval(this.interval)
    window.removeEventListener('resize', this.fit)
  },
  start() {
    clearInterval(this.interval)
    this.reading = this.el.dataset.msLeft
    const left = parseInt(this.reading || '', 10)
    this.endsAt = Number.isNaN(left) ? null : Date.now() + left
    this.hold()
    this.tick()
    if (this.endsAt) this.interval = setInterval(() => this.tick(), 250)
  },
  tick() {
    const total = parseInt(this.el.dataset.msTotal || '', 10)
    const left = this.endsAt ? this.endsAt - Date.now() : 0
    const view = clockView(left, total, this.still.matches)
    if (Number.isNaN(total)) this.show(view.last ? view.seconds : null)
    else this.drain(view)
    if (this.endsAt && left <= 0) clearInterval(this.interval)
  },
  // The empty pill keeps its place if that costs the line beside it no extra
  // row; the text then wraps the same before and after the pill appears.
  hold() {
    if (this.el.dataset.msTotal || this.el.textContent) return
    const line = this.el.parentElement
    this.el.classList.remove(HELD)
    const bare = line.offsetHeight
    this.el.classList.add(HELD)
    this.held = line.offsetHeight <= bare
  },
  show(seconds) {
    this.el.classList.toggle(HELD, !!this.held)
    const text = seconds ? `Bot in ${seconds}s` : ''
    if (this.el.textContent !== text) this.el.textContent = text
    const label = seconds ? `A bot plays for you in ${seconds} seconds` : ''
    if (this.el.getAttribute('aria-label') !== label) this.el.setAttribute('aria-label', label)
  },
  drain({part}) {
    this.el.style.transform = `scaleX(${part})`
  },
}

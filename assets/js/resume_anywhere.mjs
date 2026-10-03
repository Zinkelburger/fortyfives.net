// A returning player's first tap belongs only to resuming, including taps
// on disabled cards or inside an open dialog. Swipes still scroll normally.
export const ResumeAnywhere = {
  mounted() {
    this.connected = true
    this.pending = false
    this.onPointerDown = event => {
      this.tap = this.active() && event.isPrimary && event.button === 0 ?
        {id: event.pointerId, x: event.clientX, y: event.clientY} : null
    }
    this.onPointerMove = event => {
      if (this.tap && (Math.abs(event.clientX - this.tap.x) > 10 || Math.abs(event.clientY - this.tap.y) > 10)) this.tap = null
    }
    this.onPointerCancel = () => { this.tap = null }
    this.onPointerUp = event => {
      if (!this.tap || this.tap.id !== event.pointerId) return
      this.tap = null
      this.consumeClick = true
      clearTimeout(this.clickTimer)
      this.clickTimer = setTimeout(() => { this.consumeClick = false }, 500)
      this.resume(event)
    }
    this.onClick = event => {
      if (this.consumeClick) {
        this.consumeClick = false
        this.stop(event)
      } else if (this.active()) {
        // Also handles keyboard activation of the visible Resume button.
        this.resume(event)
      }
    }
    this.listeners = {pointerdown: this.onPointerDown, pointermove: this.onPointerMove,
      pointercancel: this.onPointerCancel, pointerup: this.onPointerUp, click: this.onClick}
    this.document = this.el.ownerDocument
    for (const [name, handler] of Object.entries(this.listeners)) this.document.addEventListener(name, handler, true)
  },
  active() { return this.connected && this.el.dataset.autoPlaying === 'true' },
  stop(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
  },
  resume(event) {
    if (!this.active()) return
    this.stop(event)
    if (this.pending) return
    this.pending = true
    this.pushEvent('resume_control', {}, () => { this.pending = false })
  },
  disconnected() { this.connected = false; this.pending = false; this.tap = null },
  reconnected() { this.connected = true },
  destroyed() {
    clearTimeout(this.clickTimer)
    for (const [name, handler] of Object.entries(this.listeners)) this.document.removeEventListener(name, handler, true)
  },
}

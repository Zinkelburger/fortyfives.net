// Renders a Cloudflare Turnstile widget (api.js is loaded with
// ?render=explicit in the root layout, so nothing auto-renders). Turnstile
// tokens are single-use: the server pushes "turnstile:reset" after a failed
// submit so the retry gets a fresh token instead of timeout-or-duplicate.
export const Turnstile = {
  mounted() {
    this.widgetId = null
    this.handleEvent("turnstile:reset", () => {
      if (this.widgetId !== null && window.turnstile) {
        window.turnstile.reset(this.widgetId)
      }
    })
    this.renderWidget()
    this.resizeObserver = new ResizeObserver(() => {
      // Flexible widgets still have a 300px minimum. Once a form becomes
      // narrower, retain compact sizing through later rotations so we don't
      // repeatedly invalidate a completed challenge.
      if (this.widgetId !== null && this.widgetSize === 'flexible' && this.el.clientWidth < 300) {
        window.turnstile.remove(this.widgetId)
        this.widgetId = null
        this.renderWidget()
      }
    })
    this.resizeObserver.observe(this.el)
  },
  destroyed() {
    this.resizeObserver.disconnect()
    clearTimeout(this.retryTimer)
    if (this.widgetId === null) return
    // A plain form POST (the sign-in form) makes LiveView destroy every hook
    // inside the submit event, before the browser reads the form. Removing
    // the widget there took its token out of the POST. Only remove it once
    // the form has been read, and only if LiveView took the element away.
    const widgetId = this.widgetId
    this.widgetId = null
    setTimeout(() => {
      if (!this.el.isConnected && window.turnstile) window.turnstile.remove(widgetId)
    }, 0)
  },
  // Callbacks can fire during render(), before "rendered" would overwrite them.
  setState(state) {
    if (state !== "rendered" || !this.el.dataset.turnstileState) {
      this.el.dataset.turnstileState = state
    }
  },
  renderWidget() {
    if (this.widgetId !== null) return
    if (window.turnstile) {
      this.widgetSize = this.widgetSize === 'compact' || this.el.clientWidth < 300 ? 'compact' : 'flexible'
      this.widgetId = window.turnstile.render(this.el, {
        sitekey: this.el.dataset.sitekey,
        action: this.el.dataset.action,
        theme: "dark",
        size: this.widgetSize,
        "response-field-name": "cf-turnstile-response",
        // data-turnstile-state lets python/live_check.py see whether the
        // widget loaded: a script-driven browser is shown the interactive
        // challenge, a wrong site key or domain reports an error code.
        callback: () => this.setState("solved"),
        "before-interactive-callback": () => this.setState("interactive"),
        "expired-callback": () => this.setState("expired"),
        "unsupported-callback": () => this.setState("unsupported"),
        "error-callback": (code) => this.setState(`error ${code}`),
      })
      this.setState("rendered")
    } else if (document.body.contains(this.el)) {
      this.retryTimer = setTimeout(() => this.renderWidget(), 100)
    }
  },
}

// Selection stays local for immediate touch feedback. Submission is followed
// by an authoritative refresh; a transport acknowledgement is not a game move.
export const CardSelection = {
  mounted() {
    this.selectedCards = new Set()
    this.pending = false
    this.connected = true
    this.version = this.el.dataset.selectionVersion
    this.onClick = event => {
      const action = event.target.closest('[data-hand-action]')
      if (action && this.el.contains(action)) return this.submit(action)
      const button = event.target.closest('button[data-card]')
      if (!button || !this.el.contains(button) || button.disabled || this.locked()) return
      this.notice = ''
      const value = button.dataset.card
      if (this.selectedCards.has(value)) {
        this.selectedCards.delete(value)
      } else if (this.el.dataset.phase === 'Discard' && this.selectedCards.size === 5) {
        this.notice = 'Up to 5. Deselect one first.'
      } else {
        if (this.el.dataset.phase === 'Playing') this.selectedCards.clear()
        this.selectedCards.add(value)
      }
      this.render()
    }
    this.el.addEventListener('click', this.onClick)
    this.render()
  },
  updated() {
    if (this.version !== this.el.dataset.selectionVersion) {
      this.version = this.el.dataset.selectionVersion
      this.selectedCards.clear()
      this.pending = false
      this.notice = ''
    }
    this.render()
  },
  disconnected() {
    this.connected = false
    this.pending = false
    this.selectedCards.clear()
    this.render()
  },
  reconnected() {
    this.pushEvent('refresh_hand', {}, () => {
      this.connected = true
      this.render()
    })
  },
  destroyed() {
    this.el.removeEventListener('click', this.onClick)
    clearTimeout(this.pendingTimer)
  },
  locked() {
    return !this.connected || this.pending || this.el.dataset.locked === 'true'
  },
  submit(button) {
    if (button.disabled || this.locked() || !this.selectedCards.size) return
    const cards = [...this.selectedCards]
    this.pending = true
    this.notice = ''
    this.render()
    const version = this.version
    const refresh = () => this.pushEvent('refresh_hand', {}, () => {
      if (this.version === version && this.pending) {
        this.pending = false
        this.notice = 'Move not applied. Check your selection and try again.'
      }
      this.render()
    })
    this.pushEvent(button.dataset.handAction, {cards}, refresh)
    // If an acknowledgement is lost without a disconnect, fetch state before
    // allowing a retry. Never blindly resend an irreversible game action.
    clearTimeout(this.pendingTimer)
    this.pendingTimer = setTimeout(() => {
      if (this.pending && this.connected) refresh()
    }, 5000)
  },
  render() {
    this.el.dataset.selectedCards = JSON.stringify([...this.selectedCards])
    this.el.querySelectorAll('button[data-card]').forEach(button => {
      const selected = this.selectedCards.has(button.dataset.card)
      button.setAttribute('aria-pressed', String(selected))
      button.querySelector('img').classList.toggle('selected-card', selected)
    })
    const action = this.el.querySelector('[data-hand-action]')
    if (!action) return
    const confirmed = this.el.dataset.confirmed === 'true'
    const count = this.selectedCards.size
    const total = this.el.querySelectorAll('button[data-card]').length
    action.disabled = this.locked() || !this.selectedCards.size
    action.textContent = this.pending ? 'Sending…' : confirmed ? 'Cards kept' :
      this.el.dataset.phase === 'Discard' ?
        (count ? (count === total ? `Keep all ${count} cards` : `Keep ${count} · Discard ${total - count}`) : 'Choose cards to keep') : 'Play Card'
    const summary = this.el.querySelector('#selection-summary')
    if (!summary) return
    // The status line already says whose turn it is and when the table is
    // reconnecting; the summary only describes the current selection.
    if (this.notice && this.connected && !this.pending) summary.textContent = this.notice
    else if (this.locked() || confirmed) summary.textContent = ''
    else if (this.el.dataset.phase === 'Discard') {
      summary.textContent = count ? 'Checked cards stay in your hand' : 'Select 1–5 cards; the rest will be discarded'
    } else {
      const selected = [...this.el.querySelectorAll('button[data-card]')].find(b => this.selectedCards.has(b.dataset.card))
      summary.textContent = selected ? `Play ${selected.getAttribute('aria-label')}?` : ''
    }
  },
}

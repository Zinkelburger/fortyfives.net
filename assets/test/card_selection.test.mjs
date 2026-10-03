import test from 'node:test'
import assert from 'node:assert/strict'
import {CardSelection} from '../js/card_selection.mjs'

function fixture(t, phase = 'Discard') {
  const cards = Array.from({length: 8}, (_, i) => ({
    dataset: {card: `${i + 1}_hearts`}, disabled: false,
    attrs: {'aria-label': `Card ${i + 1}`},
    setAttribute(k, v) { this.attrs[k] = v },
    getAttribute(k) { return this.attrs[k] },
    querySelector() { return {classList: {toggle() {}}} },
  }))
  const action = {disabled: true, dataset: {handAction: phase === 'Discard' ? 'confirm_discard' : 'play-card'}}
  const summary = {}
  const events = []
  const el = {
    dataset: {phase, locked: 'false', selectionVersion: 'hand1'},
    contains: () => true, addEventListener() {}, removeEventListener() {},
    querySelectorAll: () => cards,
    querySelector: s => s === '[data-hand-action]' ? action : summary,
  }
  const hook = {...CardSelection, el, pushEvent: (name, payload, callback) => events.push({name, payload, callback})}
  hook.mounted()
  t.after(() => hook.destroyed())
  return {hook, cards, action, summary, events, click(i) {
    hook.onClick({target: {closest: s => s === 'button[data-card]' ? cards[i] : null}})
  }}
}

test('an eight-card hand keeps at most five without silently replacing a choice', t => {
  const f = fixture(t)
  assert.equal(f.action.disabled, true)
  for (let i = 0; i < 5; i++) f.click(i)
  const selected = [...f.hook.selectedCards]
  f.click(7)
  assert.deepEqual([...f.hook.selectedCards], selected)
  assert.match(f.summary.textContent, /Deselect/)
  f.click(0); f.click(7)
  assert.equal(f.cards[7].attrs['aria-pressed'], 'true')
  assert.equal(f.cards[0].attrs['aria-pressed'], 'false')
  assert.equal(f.action.disabled, false)
})

test('discard confirmation distinguishes the kept cards from the discarded cards', t => {
  const f = fixture(t)
  assert.equal(f.action.textContent, 'Choose cards to keep')
  f.click(0)
  assert.equal(f.action.textContent, 'Keep 1 · Discard 7')
  f.click(1); f.click(2)
  assert.equal(f.action.textContent, 'Keep 3 · Discard 5')
  assert.equal(f.summary.textContent, 'Checked cards stay in your hand')
  f.cards.splice(5)
  f.click(3); f.click(4)
  assert.equal(f.action.textContent, 'Keep all 5 cards')
})

test('playing selects exactly one card and toggling it off disables confirmation', t => {
  const f = fixture(t, 'Playing')
  f.click(0); f.click(1)
  assert.deepEqual([...f.hook.selectedCards], ['2_hearts'])
  f.click(1)
  assert.equal(f.action.disabled, true)
})

test('unrelated patches retain selection; a new turn or hand clears it', t => {
  const f = fixture(t)
  f.click(0); f.hook.updated()
  assert.equal(f.hook.selectedCards.size, 1)
  f.hook.el.dataset.selectionVersion = 'next-turn'
  f.hook.updated()
  assert.equal(f.hook.selectedCards.size, 0)
  assert.equal(f.action.disabled, true)
})

test('double submission sends one action and waits for authoritative state', t => {
  const f = fixture(t)
  f.click(0); f.hook.submit(f.action); f.hook.submit(f.action)
  assert.equal(f.events.length, 1)
  assert.equal(f.action.disabled, true)
  f.events[0].callback()
  assert.equal(f.events[1].name, 'refresh_hand')
  f.hook.el.dataset.selectionVersion = 'confirmed'
  f.hook.el.dataset.confirmed = 'true'
  f.hook.el.dataset.locked = 'true'
  f.hook.updated(); f.events[1].callback()
  assert.match(f.action.textContent, /Cards kept/)
  assert.equal(f.summary.textContent, '')
  assert.equal(f.action.disabled, true)
})

test('a rejected move unlocks selection only after the refreshed state arrives', t => {
  const f = fixture(t)
  f.click(0); f.hook.submit(f.action)
  f.events[0].callback()
  assert.equal(f.action.disabled, true)
  f.events[1].callback()
  assert.equal(f.action.disabled, false)
  assert.match(f.summary.textContent, /Move not applied/)
})

test('disconnect clears stale selection and reconnect waits for the server', t => {
  const f = fixture(t)
  f.click(0); f.hook.disconnected(); f.click(1)
  assert.equal(f.hook.selectedCards.size, 0)
  assert.equal(f.action.disabled, true)
  f.hook.reconnected()
  assert.equal(f.hook.connected, false)
  f.events[0].callback()
  assert.equal(f.hook.connected, true)
  assert.equal(f.action.disabled, true)
  f.click(1)
  assert.equal(f.action.disabled, false)
})

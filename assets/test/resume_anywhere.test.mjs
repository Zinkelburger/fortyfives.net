import test from 'node:test'
import assert from 'node:assert/strict'
import {ResumeAnywhere} from '../js/resume_anywhere.mjs'

function fixture(t) {
  const listeners = new Map()
  const events = []
  const el = {dataset: {autoPlaying: 'true'}, ownerDocument: {
    addEventListener(name, handler) { listeners.set(name, handler) },
    removeEventListener(name) { listeners.delete(name) },
  }}
  const hook = {...ResumeAnywhere, el, pushEvent: (name, payload, callback) => events.push({name, callback})}
  hook.mounted()
  t.after(() => hook.destroyed())
  return {hook, events, listeners, fire(name, props = {}) {
    const event = {isPrimary: true, button: 0, pointerId: 1, clientX: 20, clientY: 20,
      preventDefault() { this.prevented = true }, stopImmediatePropagation() { this.stopped = true }, ...props}
    listeners.get(name)(event)
    return event
  }}
}

test('a tap resumes once and consumes the following click even after the server unlocks cards', t => {
  const f = fixture(t)
  f.fire('pointerdown')
  assert.equal(f.fire('pointerup').stopped, true)
  assert.equal(f.events[0].name, 'resume_control')
  f.hook.el.dataset.autoPlaying = 'false'
  f.events[0].callback()
  assert.equal(f.fire('click').prevented, true)
  assert.equal(f.events.length, 1)
  assert.equal(f.fire('click').stopped, undefined)
})

test('swipes, cancelled touches and right clicks do not resume', t => {
  const f = fixture(t)
  f.fire('pointerdown'); f.fire('pointermove', {clientY: 60}); f.fire('pointerup')
  f.fire('pointerdown'); f.fire('pointercancel'); f.fire('pointerup')
  f.fire('pointerdown', {button: 2}); f.fire('pointerup', {button: 2})
  assert.equal(f.events.length, 0)
})

test('keyboard activation resumes; repeated activation waits for acknowledgement', t => {
  const f = fixture(t)
  assert.equal(f.fire('click').stopped, true)
  assert.equal(f.fire('click').stopped, true)
  assert.equal(f.events.length, 1)
})

test('normal play and disconnected taps are untouched; listeners are removed on navigation', t => {
  const f = fixture(t)
  f.hook.el.dataset.autoPlaying = 'false'
  assert.equal(f.fire('click').stopped, undefined)
  f.hook.el.dataset.autoPlaying = 'true'
  f.hook.disconnected()
  f.fire('pointerdown'); f.fire('pointerup'); f.fire('click')
  assert.equal(f.events.length, 0)
  f.hook.reconnected(); f.fire('click')
  assert.equal(f.events.length, 1)
  f.hook.destroyed()
  assert.equal(f.listeners.size, 0)
})

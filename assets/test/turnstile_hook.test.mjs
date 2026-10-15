import test from 'node:test'
import assert from 'node:assert/strict'
import {setTimeout as tick} from 'node:timers/promises'
import {Turnstile} from '../js/turnstile_hook.mjs'

function fixture(t) {
  const calls = []
  const options = {}
  globalThis.window = {turnstile: {
    render(el, opts) { Object.assign(options, opts); calls.push('render'); return 'widget-1' },
    remove(id) { calls.push(`remove ${id}`) },
    reset(id) { calls.push(`reset ${id}`) },
  }}
  globalThis.ResizeObserver = class { observe() {} disconnect() {} }
  t.after(() => { delete globalThis.window; delete globalThis.ResizeObserver })

  const el = {dataset: {sitekey: 'key', action: 'turnstile-spin-v2'}, clientWidth: 400, isConnected: true}
  const hook = {...Turnstile, el, handleEvent() {}}
  hook.mounted()
  return {hook, el, calls, options}
}

test('a plain form POST keeps the widget, and its token, in the form', async t => {
  const f = fixture(t)
  // LiveView destroys hooks inside the submit event while the page is still there.
  f.hook.destroyed()
  await tick(5)
  assert.deepEqual(f.calls, ['render'])
})

test('the widget is removed once LiveView takes the element away', async t => {
  const f = fixture(t)
  f.el.isConnected = false
  f.hook.destroyed()
  assert.deepEqual(f.calls, ['render'])
  await tick(5)
  assert.deepEqual(f.calls, ['render', 'remove widget-1'])
})

test('the widget state is recorded on the element', t => {
  const f = fixture(t)
  assert.equal(f.el.dataset.turnstileState, 'rendered')
  f.options['before-interactive-callback']()
  assert.equal(f.el.dataset.turnstileState, 'interactive')
  f.options.callback('token')
  assert.equal(f.el.dataset.turnstileState, 'solved')
  f.options['error-callback'](110200)
  assert.equal(f.el.dataset.turnstileState, 'error 110200')
})

test('a hook remounted on a kept element reuses its widget', async t => {
  const f = fixture(t)
  f.hook.destroyed()
  const again = {...Turnstile, el: f.el, handleEvent() {}}
  again.mounted()
  await tick(5)
  assert.deepEqual(f.calls, ['render'])
  assert.equal(again.widgetId, 'widget-1')
})

test('a reset clears the previous widget state', t => {
  let reset
  const f = fixture(t)
  const hook = {...Turnstile, el: f.el, handleEvent(_name, fn) { reset = fn }}
  f.hook.destroyed()
  hook.mounted()
  f.options['error-callback']('110200')
  assert.equal(f.el.dataset.turnstileState, 'error 110200')
  reset()
  assert.equal(f.el.dataset.turnstileState, 'rendered')
})

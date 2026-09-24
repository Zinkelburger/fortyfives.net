import test from "node:test"
import assert from "node:assert/strict"
import {createSessionRecorder} from "../js/session_recorder.mjs"

function setup(t, enabled = true) {
  const document = new EventTarget()
  document.visibilityState = "visible"
  t.mock.method(globalThis, "setInterval", () => 1)
  t.mock.method(globalThis, "clearInterval", () => {})
  const restore = []
  const globals = {document, window: {innerWidth: 390, innerHeight: 844}, navigator: {userAgent: "iPhone"}}
  for (const [key, value] of Object.entries(globals)) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, {value, configurable: true})
    restore.push(() => descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key])
  }
  const starts = []
  const sent = []
  const record = (options) => {
    const session = {options, stopped: false}
    starts.push(session)
    options.emit({type: 4, timestamp: Date.now(), data: {width: 390, height: 844}})
    options.emit({type: 2, timestamp: Date.now(), data: {node: {id: starts.length}}})
    return () => { session.stopped = true }
  }
  const hook = {
    ...createSessionRecorder(record),
    el: {dataset: {record: String(enabled)}},
    pushEvent: (event, payload) => sent.push({event, ...payload}),
  }
  t.after(() => {
    hook.destroyed()
    restore.forEach(reset => reset())
  })
  return {hook, starts, sent, document}
}

test("reconnect opens a fresh stream with a full snapshot and device metadata", t => {
  const {hook, starts, sent} = setup(t)
  hook.mounted()
  assert.equal(sent[0].seq, 0)
  starts[0].options.emit({type: 3, timestamp: Date.now(), data: {source: 0}})
  hook.flush()
  assert.equal(sent[1].seq, 1)
  starts[0].options.emit({type: 3, timestamp: Date.now(), data: {source: 1}})
  hook.disconnected()
  assert.equal(starts[0].stopped, true)
  hook.flush()
  assert.equal(sent.length, 2)

  hook.reconnected()
  assert.equal(starts.length, 2)
  assert.equal(sent[2].seq, 0)
  assert.equal(sent[2].device, "mobile")
  assert.equal(sent[2].w, 390)
  assert.equal(sent[2].h, 844)
  assert.deepEqual(JSON.parse(sent[2].data).map(e => e.type), [4, 2])
  assert.equal(JSON.parse(sent[2].data)[1].data.node.id, 2)
  hook.reconnected()
  assert.equal(starts.length, 2)
})

test("disconnect drops pending clicks and removes the visibility handler", t => {
  const {hook, starts, sent, document} = setup(t)
  hook.mounted()
  starts[0].options.emit({type: 3, timestamp: Date.now()})
  hook.clicks.push({ts: Date.now(), dead: true})
  hook.disconnected()
  document.visibilityState = "hidden"
  document.dispatchEvent(new Event("visibilitychange"))
  assert.equal(sent.length, 1)
  hook.reconnected()
  assert.deepEqual(sent[1].clicks, [])
})

test("server recording limits stop capture and do not flush rejected data", t => {
  const {hook, starts, sent} = setup(t)
  hook.mounted()
  starts[0].options.emit({type: 3, timestamp: Date.now()})
  hook.el.dataset.record = "false"
  hook.updated()
  hook.disconnected()
  hook.reconnected()
  hook.destroyed()
  assert.equal(starts[0].stopped, true)
  assert.equal(starts.length, 1)
  assert.equal(sent.length, 1)
})

test("disabled recording stays off; navigation flushes an enabled recording once", t => {
  const {hook, starts, sent} = setup(t, false)
  hook.mounted()
  assert.equal(starts.length, 0)
  hook.el.dataset.record = "true"
  hook.reconnected()
  starts[0].options.emit({type: 3, timestamp: Date.now()})
  hook.destroyed()
  hook.destroyed()
  assert.equal(sent.length, 2)
  assert.equal(sent[1].seq, 1)
})

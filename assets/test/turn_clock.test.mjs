import test from 'node:test'
import assert from 'node:assert/strict'
import {clockView, LAST_SECONDS} from '../js/turn_clock.mjs'

test('the edge is full at the start of a turn and empty at its end', () => {
  assert.deepEqual(clockView(30000, 30000), {seconds: 30, part: 1, last: false})
  assert.equal(clockView(15000, 30000).part, 0.5)
  assert.deepEqual(clockView(0, 30000), {seconds: 0, part: 0, last: false})
})

test('the last seconds are the ones the pill counts', () => {
  assert.equal(clockView(LAST_SECONDS * 1000 + 1, 30000).last, false)
  assert.deepEqual(clockView(LAST_SECONDS * 1000, 30000), {seconds: 10, part: 1 / 3, last: true})
  assert.deepEqual(clockView(1, 30000), {seconds: 1, part: 1 / 30000, last: true})
})

test('with reduced motion the edge moves once a second', () => {
  assert.equal(clockView(14999, 30000, true).part, 0.5)
  assert.equal(clockView(14001, 30000, true).part, 0.5)
  assert.equal(clockView(14000, 30000, true).part, 14 / 30)
})

test('a missing or late reading shows nothing', () => {
  for (const left of [NaN, -250, undefined]) {
    assert.deepEqual(clockView(left, 30000), {seconds: 0, part: 0, last: false})
  }
})

test('a reading longer than the timeout, or no timeout, cannot overdraw the edge', () => {
  assert.equal(clockView(31000, 30000).part, 1)
  assert.equal(clockView(5000, NaN).part, 0)
  assert.equal(clockView(5000, 0).part, 0)
})

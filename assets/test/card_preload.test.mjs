import test from 'node:test'
import assert from 'node:assert/strict'
import {existsSync} from 'node:fs'
import {fileURLToPath} from 'node:url'
import {cardImageUrls, preloadCards, resetPreload} from '../js/card_preload.mjs'

function fakeImage(created) {
  return class {
    set src(url) { this.url = url; created.push(this) }
  }
}

test('every preloaded face is a file the site serves', () => {
  const urls = cardImageUrls()
  assert.equal(new Set(urls).size, 52)
  for (const url of urls) {
    const file = fileURLToPath(new URL(`../../priv/static${url}`, import.meta.url))
    assert.ok(existsSync(file), `${url} is missing`)
  }
})

test('loads a few at a time, each face once, and keeps them', t => {
  t.after(resetPreload)
  const created = []
  const kept = preloadCards({ImageCtor: fakeImage(created), connection: null, parallel: 4})
  assert.equal(created.length, 4)
  created[0].onload()
  assert.equal(created.length, 5)
  // A face that fails to load must not stall the rest.
  for (let i = 1; i < created.length; i++) created[i].onerror()
  assert.equal(created.length, 52)
  assert.equal(new Set(created.map(image => image.url)).size, 52)
  assert.equal(kept.length, 52)
  assert.equal(preloadCards({ImageCtor: fakeImage(created)}), kept)
  assert.equal(created.length, 52)
})

test('waits for cards to appear when the visitor is saving data', t => {
  t.after(resetPreload)
  const created = []
  assert.deepEqual(preloadCards({ImageCtor: fakeImage(created), connection: {saveData: true}}), [])
  assert.equal(created.length, 0)
})

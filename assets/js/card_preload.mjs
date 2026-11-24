// Card faces are fetched once per table, in the background, so a card that
// is dealt or played is already in memory when it reaches the screen. The
// images are kept so the browser does not drop them between hands.
const RANKS = ['2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K', 'A']
const SUITS = ['C', 'D', 'H', 'S']

export const cardImageUrls = () =>
  RANKS.flatMap(rank => SUITS.map(suit => `/images/cards/${rank}${suit}.png`))

let kept = null

// A few at a time, so a slow connection still gives the cards already on
// screen their share. Skipped when the visitor has asked to save data; the
// cards then load as they appear.
export function preloadCards({
  ImageCtor = globalThis.Image,
  connection = globalThis.navigator?.connection,
  parallel = 4,
} = {}) {
  if (kept) return kept
  if (!ImageCtor || connection?.saveData) return []
  const queue = cardImageUrls()
  kept = []
  const next = () => {
    const url = queue.shift()
    if (!url) return
    const image = new ImageCtor()
    image.onload = image.onerror = next
    image.src = url
    kept.push(image)
  }
  for (let i = 0; i < parallel; i++) next()
  return kept
}

export const resetPreload = () => { kept = null }

export const CardPreload = {
  mounted() { preloadCards() },
}

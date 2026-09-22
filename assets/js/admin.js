// Admin-only bundle: the rrweb player for /admin/replays/:id. Kept out of
// app.js so visitors never download it. Loaded with `defer` after app.js, so
// the DOM is parsed when this runs.

import Player from "../vendor/rrweb-player"
import "../vendor/rrweb-player.css"

const mount = document.getElementById("replay-player")

if (mount) {
  const status = document.getElementById("replay-status")
  const url = mount.dataset.url

  fetch(url, {credentials: "same-origin"})
    .then((response) => {
      if (!response.ok) throw new Error("HTTP " + response.status)
      return response.json()
    })
    .then((events) => {
      if (events.length < 2) {
        status.textContent = "This recording has too few events to play."
        return
      }
      status.textContent = events.length + " events"
      const width = Math.min(mount.clientWidth || 1000, 1200)
      new Player({
        target: mount,
        props: {
          events,
          width,
          height: Math.round(width * 0.62),
          autoPlay: false,
          skipInactive: true,
          showController: true,
          mouseTail: true,
          // Recordings come from players' browsers. Keep the replay iframe
          // sandboxed without scripts (rrweb's default), never the canvas
          // mode that turns scripts on.
          UNSAFE_replayCanvas: false,
        },
      })
    })
    .catch((error) => {
      status.textContent = "Could not load the recording: " + error.message
    })
}

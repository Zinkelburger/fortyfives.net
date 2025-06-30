// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let Hooks = {};

Hooks.CardSelection = {
  // Called when the hook is first mounted. Initializes local state and
  // binds click handlers on each card in the player's hand.
  mounted() {
    this.discardLimit = 5
    this.phase = null
    this.locked = false
    this.selectedCards = []

    this.handlePhaseChange()
    this.bindClicks()
    this.render()
    this.sync()

    this.el.addEventListener('discard-confirmed', () => {
      this.locked = true
      this.clear()
    })
  },

  // Called whenever the DOM element is patched by LiveView. We simply
  // rebind any new card elements and react to possible phase changes.
  updated() {
    this.handlePhaseChange()
    this.bindClicks()
    this.render()
    this.sync()
  },

  // Check for a phase transition. When entering the Discard or Playing phase
  // we reset the local selection and unlock the hand.
  handlePhaseChange() {
    const newPhase = this.el.dataset.phase
    if (newPhase !== this.phase) {
      this.phase = newPhase
      if (['Discard', 'Playing'].includes(this.phase)) {
        this.locked = false
        this.clear()
      } else {
        this.locked = true
      }
    }
  },

  bindClicks() {
    this.el.querySelectorAll('img[data-card-value]').forEach(img => {
      if (img.dataset.bound !== 'true') {
        img.dataset.bound = 'true'
        img.addEventListener('click', () => this.toggle(img))
      }
    })
  },

  // Toggle the provided card depending on the current phase.
  toggle(img) {
    if (this.locked || !['Discard', 'Playing'].includes(this.phase)) return

    const value = img.dataset.cardValue
    if (this.phase === 'Discard') {
      if (this.selectedCards.includes(value)) {
        this.selectedCards = this.selectedCards.filter(v => v !== value)
      } else {
        if (this.selectedCards.length >= this.discardLimit) {
          const removed = this.selectedCards.shift()
          const old = this.el.querySelector(`img[data-card-value="${removed}"]`)
          if (old) old.classList.remove('selected-card')
        }
        this.selectedCards.push(value)
      }
    } else {
      this.selectedCards = this.selectedCards.includes(value) ? [] : [value]
    }

    this.render()
    this.sync()
  },

  // Update card CSS classes based on the current selection.
  render() {
    this.el.querySelectorAll('img[data-card-value]').forEach(img => {
      if (this.selectedCards.includes(img.dataset.cardValue)) {
        img.classList.add('selected-card')
      } else {
        img.classList.remove('selected-card')
      }
    })
  },

  clear() {
    this.selectedCards = []
    this.render()
    this.sync()
  },

  sync() {
    this.el.dataset.selectedCards = JSON.stringify(this.selectedCards)
  }
}

Hooks.AutoDismissFlash = {
    mounted() {
      let progressBar = this.el.querySelector('.progress-bar');
      let width = 100;
      let interval = setInterval(() => {
        width -= 2;
        progressBar.style.width = width + '%';
        if (width <= 0) {
          clearInterval(interval);
          this.el.click();
        }
      }, 30);
    }
  };

Hooks.ScoringCountdown = {
  mounted() {
    this.seconds = parseInt(this.el.dataset.seconds || "0")
    this.el.innerText = this.seconds
    this.interval = setInterval(() => {
      this.seconds--
      if (this.seconds >= 0) {
        this.el.innerText = this.seconds
      } else {
        clearInterval(this.interval)
      }
    }, 1000)
  },
  destroyed() {
    if (this.interval) clearInterval(this.interval)
  }
}

Hooks.PlayCardButton = {
  mounted() {
    this.el.addEventListener('click', () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length === 1) {
        this.pushEvent('play-card', {cards: cards})
      }
    })
  }
}

Hooks.ConfirmDiscardButton = {
  mounted() {
    this.el.addEventListener('click', () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length > 0 && cards.length <= 5) {
        this.pushEvent('confirm_discard', {cards: cards})
        hand.dispatchEvent(new CustomEvent('discard-confirmed'))
      }
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

window.addEventListener("load", function() {
        document.querySelectorAll(".password-visibility-button").forEach(function(button) {
          button.addEventListener("click", function() {
        var passwordInput = this.parentNode.querySelector("input[type='password'], input[type='password-text']");
            var icon = this.querySelector("i");
            if (passwordInput && icon) {
              if (passwordInput.type === "password") {
                passwordInput.type = "password-text";
                icon.classList.remove("fa-eye");
                icon.classList.add("fa-eye-slash");
              } else {
                passwordInput.type = "password";
                icon.classList.remove("fa-eye-slash");
                icon.classList.add("fa-eye");
              }
            }
          });
        });
      });
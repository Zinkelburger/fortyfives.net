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
  mounted() {
    this.selectedCards = new Set();
    this.discardLimit = 5;
    this.handleCardClickRef = (event) => this.handleCardClick(event);
    this.handleDiscardConfirmedRef = () => {
      this.locked = true;
      this.clearSelection();
    };

    this.syncStateFromDataset();
    this.el.addEventListener('click', this.handleCardClickRef);
    this.el.addEventListener('discard-confirmed', this.handleDiscardConfirmedRef);
    this.sync();
    this.render();
  },

  updated() {
    const previousPhase = this.phase;
    const previousSelectionVersion = this.selectionVersion;
    const previousAutoPlaying = this.autoPlaying;

    this.syncStateFromDataset();

    if (
      previousPhase !== this.phase ||
      previousSelectionVersion !== this.selectionVersion ||
      previousAutoPlaying !== this.autoPlaying
    ) {
      this.clearSelection();
    } else {
      this.render();
      this.sync();
    }
  },

  destroyed() {
    this.el.removeEventListener('click', this.handleCardClickRef);
    this.el.removeEventListener('discard-confirmed', this.handleDiscardConfirmedRef);
  },

  handleCardClick(event) {
    if (this.locked) return;

    const card = event.target.closest('img[data-card-value]');
    if (!card || card.classList.contains('grayed-out')) return;

    const cardValue = card.dataset.cardValue;
    if (this.phase === 'Discard') {
      this.toggleDiscardSelection(cardValue);
    } else if (this.phase === 'Playing') {
      this.togglePlaySelection(cardValue);
    }

    this.render();
    this.sync();
  },

  toggleDiscardSelection(cardValue) {
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.delete(cardValue);
    } else {
      if (this.selectedCards.size >= this.discardLimit) {
        const first = this.selectedCards.values().next().value;
        this.selectedCards.delete(first);
      }
      this.selectedCards.add(cardValue);
    }
  },

  togglePlaySelection(cardValue) {
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.clear();
    } else {
      this.selectedCards.clear();
      this.selectedCards.add(cardValue);
    }
  },

  syncStateFromDataset() {
    this.phase = this.el.dataset.phase;
    this.selectionVersion = this.el.dataset.selectionVersion || '';
    this.autoPlaying = this.el.dataset.autoPlaying === 'true';
    this.updateLockState();
  },

  updateLockState() {
    this.locked = this.autoPlaying || !['Discard', 'Playing'].includes(this.phase);
  },

  clearSelection() {
    this.selectedCards.clear();
    this.render();
    this.sync();
  },

  render() {
    this.el.querySelectorAll('img[data-card-value]').forEach(img => {
      const isSelected = this.selectedCards.has(img.dataset.cardValue);
      img.classList.toggle('selected-card', isSelected);
    });
  },

  sync() {
    this.el.dataset.selectedCards = JSON.stringify(Array.from(this.selectedCards));
  }
};

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
    this.handleClick = () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length === 1) {
        this.pushEvent('play-card', {cards: cards})
      }
    }

    this.el.addEventListener('click', this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener('click', this.handleClick)
  }
}

Hooks.ConfirmDiscardButton = {
  mounted() {
    this.handleClick = () => {
      const hand = document.getElementById('player-hand')
      if (!hand) { return }
      const cards = JSON.parse(hand.dataset.selectedCards || '[]')
      if (cards.length > 0 && cards.length <= 5) {
        this.pushEvent('confirm_discard', {cards: cards})
        hand.dispatchEvent(new CustomEvent('discard-confirmed'))
      }
    }

    this.el.addEventListener('click', this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener('click', this.handleClick)
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
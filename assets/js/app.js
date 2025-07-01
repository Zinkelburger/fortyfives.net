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
  // --------------------------------------------------------------------------
  // HOOK LIFECYCLE
  // --------------------------------------------------------------------------

  mounted() {
    // Initialize component state from DOM attributes
    this.phase = this.el.dataset.phase;
    this.selectedCards = new Set();
    this.discardLimit = 5;
    this.locked = true; // Locked by default

    // Set initial lock state based on the current phase
    this.updateLockState();
    console.log(`[CardSelection] mounted: phase=${this.phase}, locked=${this.locked}`);

    // --- EVENT LISTENERS ---
    // Use event delegation: one click listener on the container
    this.el.addEventListener('click', (e) => this.handleCardClick(e));

    // Lock the hand when the discard is confirmed by the parent LiveView
    this.el.addEventListener('discard-confirmed', () => {
      this.locked = true;
      this.clearSelection();
      console.log('[CardSelection] Discard confirmed, hand locked.');
    });
  },

  updated() {
    const newPhase = this.el.dataset.phase;

    // React only when the game phase has actually changed
    if (newPhase !== this.phase) {
      console.log(`[CardSelection] phase changed: ${this.phase} -> ${newPhase}`);
      this.phase = newPhase;

      // Update lock status and clear any previous selections
      this.updateLockState();
      this.clearSelection();
    }
  },

  // --------------------------------------------------------------------------
  // EVENT HANDLING
  // --------------------------------------------------------------------------

  /**
   * Handles all clicks within the hook's element (`this.el`).
   */
  handleCardClick(event) {
    // Ignore clicks if the hand is locked
    if (this.locked) return;

    const card = event.target.closest('img[data-card-value]');

    // Ignore clicks that are not on a playable card
    if (!card || card.classList.contains('grayed-out')) return;

    const cardValue = card.dataset.cardValue;

    // Delegate to the correct selection logic based on the current phase
    if (this.phase === 'Discard') {
      this.toggleDiscardSelection(cardValue);
    } else if (this.phase === 'Playing') {
      this.togglePlaySelection(cardValue);
    }

    // After any change, update the DOM and sync state with the server
    this.render();
    this.sync();
  },

  // --------------------------------------------------------------------------
  // SELECTION LOGIC
  // --------------------------------------------------------------------------

  /**
   * Manages multi-card selection during the 'Discard' phase.
   */
  toggleDiscardSelection(cardValue) {
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.delete(cardValue);
    } else {
      // When the limit is reached, remove the oldest selected card
      if (this.selectedCards.size >= this.discardLimit) {
        const first = this.selectedCards.values().next().value;
        this.selectedCards.delete(first);
      }
      this.selectedCards.add(cardValue);
    }
  },

  /**
   * Manages single-card selection during the 'Playing' phase.
   */
  togglePlaySelection(cardValue) {
    // If the clicked card is already selected, clear the selection.
    // Otherwise, clear the old selection and select the new card.
    if (this.selectedCards.has(cardValue)) {
      this.selectedCards.clear();
    } else {
      this.selectedCards.clear();
      this.selectedCards.add(cardValue);
    }
  },

  // --------------------------------------------------------------------------
  // STATE & DOM MANAGEMENT
  // --------------------------------------------------------------------------

  /**
   * Updates the lock state based on the current game phase.
   * The hand is interactive only during 'Discard' and 'Playing' phases.
   */
  updateLockState() {
    this.locked = !['Discard', 'Playing'].includes(this.phase);
  },

  /**
   * Clears the current selection and updates the view.
   */
  clearSelection() {
    this.selectedCards.clear();
    this.render();
    this.sync();
  },

  /**
   * Visually updates cards by adding/removing the 'selected-card' class.
   */
  render() {
    this.el.querySelectorAll('img[data-card-value]').forEach(img => {
      const isSelected = this.selectedCards.has(img.dataset.cardValue);
      img.classList.toggle('selected-card', isSelected);
    });
  },

  /**
   * Pushes the current selection state to the DOM for LiveView to access.
   */
  sync() {
    // A Set must be converted to an array before JSON serialization
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
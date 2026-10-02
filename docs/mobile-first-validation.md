# Mobile-first validation

Portrait phone is the base layout; landscape and desktop build on it.

## Changes

- Header: logo, team scores, Scores, rules.
- Bidding and keeping: the four seats sit where the trick is played, with bids
  or Ready in each seat. Short screens collapse to one row of the other three.
- Hand: five cards in one row; eight in 4×2 on portrait, one row in landscape.
  No overlapping fan.
- Cards are buttons: tap to select, checkmark when selected, confirm to send.
  Selection survives rotation and live updates and is cleared on reconnect.
- Controls are at least 44px; main actions 48px.
- Scores and rules open in a dialog with Close, Escape and focus return.
- Safe areas, dynamic viewport units, long names, reduced motion, 200% text.

## Checks

| Check | Command |
|---|---|
| Elixir suite | `mix test` |
| Card selection (JS) | `node --test assets/test/*.test.mjs` |
| Game on 10 viewports, 320×480 to 1400×900 | `python python/mobile_check.py --url http://localhost:4000 --out /tmp/ui/game` |
| Public pages at 320, 390 and desktop | `python python/ui_check.py --url http://localhost:4000 --out /tmp/ui/pages --check` |

`mobile_check.py` plays full games with four browsers. It checks element bounds
against the requested viewport, hit-tests control centers, every card in the
eight-card keep, the five-card limit, Space activation, rotation, dialogs during
live updates, disconnect/reconnect, and the return to the lobby.

Screenshots: `docs/mobile-after/`, from `mobile_check.py`.

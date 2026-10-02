# Plan: make portrait phone play the default

The implementation and automated checks are now recorded in
[mobile-first validation](mobile-first-validation.md), including screenshots and
the remaining physical-device and production measurement checks.

## Outcome

A player can open a private invitation or join the queue, bid, choose among all eight cards when they win the kitty, play a complete game, inspect scores, and recover from a brief interruption while holding a phone vertically.

At normal text size, the active hand and required actions must fit the available portrait viewport without horizontal scrolling, zooming out, or rotating. Longer rules, score history, and account forms may scroll. With enlarged text or unusually constrained height, accessible vertical scrolling is preferable to hiding content or reducing touch targets.

This plan builds on [the mobile audit](mobile-experience-audit.md). The current workspace also contains ongoing presence, analytics, and replay changes; implementation must preserve those changes and build on their final interfaces. The audit's line numbers describe the earlier snapshot.

## Design decisions

Use one responsive game UI and the existing Phoenix LiveView game engine. Portrait is the base layout; larger screens add space and rearrange secondary information. Preserve the server's rules, legal-move validation, and authoritative game state.

The portrait screen has four stable regions:

| Region | Contents | Behavior |
|---|---|---|
| Compact header | Your team's score, opponents' score, Scores/menu access | Large touch targets; small branding |
| Status | Turn, current bid/trump, brief connection notice | Reserved space; names cannot push controls off-screen |
| Phase area | Bid choices, keep instructions, current trick, or results | Uses remaining space; no empty table during bidding/discard |
| Hand and action area | Your cards, selection summary, confirmation | Lower part of the screen; stays in normal layout so it cannot cover cards |

Keep the hand and confirmation together. The action occupies a consistent bottom region as the middle changes. Prefer a grid/flex page structure over a fixed overlay toolbar. Apply safe-area padding, reserve space for any sticky element, and permit a scroll fallback when content cannot fit.

### Each phase needs an explicit design

| Phase | Phone behavior |
|---|---|
| Bidding | Five visible hand cards; four number choices and four suit choices in clear groups; separate Pass and Confirm Bid actions. Preserve bagged-dealer and hold behavior. Disable unavailable choices. |
| Discard, ordinary player | Five visible cards; “Select cards to keep”; count of selected cards; Confirm Keep below the hand. |
| Discard, bid winner | **Four columns × two rows for eight cards** on narrow portrait screens. All cards fully visible and independently tappable. |
| Waiting after discard | Keep the confirmed state visible and show “Waiting for other players.” Disable further edits. |
| Playing | Stable four-seat table with separate name and card areas; five-card hand in one row; tap a legal card then confirm. Retain seat positions as the hand shrinks. |
| Scoring | Current totals and last-hand change first; full history in a scrollable area; visible next-hand status. |
| Final scoring | Explicit result and a clearly reachable return-to-lobby action. |
| Bot takeover/reconnect | Persistent explanation with an explicit Resume action when applicable; reconcile with the server before enabling play. |

Use selection outlines/checkmarks plus accessible pressed state; do not rely on color or a 20px card lift. Reserve room for any lift that remains. A sixth keep selection should explain the five-card maximum instead of silently dropping an earlier choice.

## Implementation sequence

### 1. Establish gameplay checks and build the portrait foundation

**Work**

- Extend the existing Selenium tooling to reach actual game phases locally, including the eight-card winner. Reuse existing game fixtures/helpers where practical; keep scenario controls in test/development code.
- Capture fixed-viewport screenshots and element bounds before changing the layout. Store requested viewport dimensions independently of `window.innerWidth`.
- Refactor `GameLive` rendering into clear header/status, phase, hand, action, and score-panel components. Preserve event names and stable IDs where possible.
- Replace the game root's ad hoc logo sizing and inline/negative offsets with a scoped game layout.
- Make phone styles the default. Give hand cards and played cards separate sizing rules, based on their containers and available space.
- Implement the five-card row and eight-card four-by-two grid. Keep selection and all confirmation controls visible together.
- Replace the score overlay with one bounded dialog containing its own Close button and scrolling score body. Remove nested full-viewport scoring height. Support Escape, keyboard focus containment, focus restoration, and deliberate backdrop dismissal.

**Primary files:** `game_live.ex`, `layouts/game_root.html.heex`, `assets/css/app.css`, gameplay browser checks, relevant LiveView tests.

**Done when:** a complete hand can be played at 320×568 and 390×844 in portrait; every one of the eight cards can be selected; scores can be opened and closed; no card or required control is clipped or overlapped. Add 320×480 and 360×640 checks for reduced available height. Controls stay usable without imposing a rotation requirement.

### 2. Make touch interaction clear and reliable

**Work**

- Give primary actions approximately 48px height and secondary controls at least 44×44px hit areas. Keep card faces readable and full-card selection targets available.
- Keep tap-to-select followed by explicit confirmation. Show the selected card or a keep count in the action area.
- Disable Play Card/Confirm Keep until the selection is valid. Represent pending submission separately from server-confirmed success; prevent repeated submissions and recover from rejection/disconnection.
- Move click handling to semantic card buttons so image, button, touch, keyboard, and assistive-technology activation follow the same path. Synchronize `aria-pressed`, disabled state, and visible selection.
- Preserve selection across harmless updates and rotation; clear it when the turn, hand, phase, or control ownership changes.
- Allocate space for long names, keep player identity/position stable, and show concise current activity. Put detailed history behind a secondary control.
- Respect reduced-motion preferences and avoid hover-dependent instructions.

**Primary files:** `assets/js/app.js`, `game_live.ex`, game CSS, hook tests and browser interaction checks. Preserve the ongoing recorder extraction and replay lifecycle behavior.

**Done when:** selections respond immediately, invalid actions have clear feedback, double taps cannot produce duplicate game actions, and touch/keyboard selection agree. Test all eight card buttons, bagged/hold bidding, out-of-turn play, keep limits, and selection through rotation and server updates.

### 3. Expand the layout and verify phone interruptions

**Work**

- Add a short-height/landscape arrangement, using a table beside the hand/actions where necessary. Do not infer “desktop” from width alone.
- Expand the portrait design for tablets and desktop: larger table space, capped card sizes, and optional persistent secondary information. Avoid separate game logic or duplicated interactive hands.
- Use small/dynamic viewport sizing appropriately and verify behavior with browser toolbars expanded and collapsed. Apply safe-area insets to edge controls.
- Replace the invisible full-screen resume click catcher with a clear Resume button. Keep connection state and bot ownership distinct.
- Exercise background/foreground, temporary connection loss, reload, rejoin, and a second tab against the existing recovery behavior. Explain an expired game and provide a route back to the lobby.
- Evaluate timeout policy from these results. Any change to game lifetime or multiplayer turn timing is a separate product decision, not an incidental layout edit. If a turn countdown is introduced, base it on server timing rather than a new independent client timer.

**Done when:** portrait-to-landscape-to-portrait retains valid selection/state; essential controls remain reachable at 568×320 and 844×390; browser chrome does not cover actions; reconnect produces the correct hand and turn with no stale confirmation or duplicate action. Desktop remains fully playable.

### 4. Complete the surrounding phone journey

**Work**

- Keep the home page's Play action easy to find and reduce oversized navigation/branding where useful.
- Verify public queue, private invitation, four long player names, bot filling, rejoin/abandon, and expired-link states. Enlarge Copy and add native sharing with a Copy fallback if worthwhile.
- Fix shared form sizing and negative error spacing. Enlarge password visibility controls; check login, registration, settings, reset, and confirmation with the keyboard and validation errors visible.
- Replace the missing/outdated tutorial images, correct the scoring explanation, and provide a brief phone-readable rules reference accessible during a game.
- Give admin tables contained horizontal scrolling and make replay sizing respond to viewport changes; schedule after player-facing defects.

**Done when:** a new visitor can enter and finish a game on a phone, and account/rules tasks remain usable with text enlargement and the keyboard open.

### 5. Verify on devices and release with evidence

Begin this verification throughout implementation; this milestone is the release gate, not the first time testing starts.

- Run a full game on iOS Safari and Android Chrome. Include winning the bid, both discard layouts, all four played cards, score history, final scoring, and a brief interruption.
- Check 320/360/390/430px portrait, short-height portrait, 600/601px boundaries, landscape, and desktop. Include 30-character names, 200% text enlargement, selected cards, disabled controls, and long score histories.
- Assert card/control bounds against the intended viewport and use hit testing to detect overlays. Do not accept a screenshot or `scrollWidth == innerWidth` as sufficient evidence of usability.
- Retain fixed-height screenshots alongside full-page captures. Include the actual game in CI, rather than only home/lobby/forms.
- Run the repository's required checks for the implementation changes and existing game-rule/reconnect tests.
- Measure production page load and tap feedback on a representative phone/network. Optimize measured bottlenecks; treat replay loading/recording cost as a candidate to investigate.
- Compare before/after mobile game entry, first discard/trick completion, full-game completion, abandonment by phase, and idle takeovers. Compare similar game types and inspect replay examples; raw traffic totals are not the success metric.

**Release gate:** no unreachable card, hidden required action, inaccessible dialog exit, or state corruption during the tested phone journeys. Record screenshots and device/browser coverage with each implementation change.

## Suggested change boundaries

1. Gameplay layout regression checks and portrait foundation, including eight-card discard and contained scores.
2. Touch selection, confirmation state, accessibility, and stable labels.
3. Landscape/large-screen layouts and interruption UI, with recovery checks.
4. Lobby, forms, and learning-page fixes.

Keep each change reviewable and playable. Add relevant checks with each implementation rather than deferring all testing to a final change. Real-device validation spans all four.

## Later enhancements

After the browser experience passes the release gate, consider home-screen installation, static-asset caching, richer in-game help, and additional visual polish. Installation should not be a prerequisite for playing successfully in portrait. The online game's connection requirements must remain clear.

## Design reference

Use [Mobile First by Luke Wroblewski](https://www.lukew.com/resources/mobile_first.asp) as the organizing principle: prioritize the content and actions needed on a constrained screen, then expand. The audit links current touch-target, viewport, and accessibility references for implementation details.

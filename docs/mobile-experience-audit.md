# Mobile experience audit — September 24, 2026

The app is partly responsive already. Normal five-card play fits a portrait phone. However, winning a bid produces an eight-card hand that clips cards off-screen, and landscape play puts the hand and action button below the visible screen. Fix these gameplay failures before polishing the rest of the site.

## Scope and evidence

Reviewed the current checkout's layouts, CSS, LiveView game phases, client hooks, lobby, learning pages, account forms, reconnect/autoplay behavior, and admin templates. This is not a claim about which commit is deployed to production.

Ran the actual application locally against a separate audit database. Four isolated Chrome sessions joined a private game, bid, discarded, played all five tricks, and reached scoring. Captured game layouts at requested device sizes of 320×568, 390×844, 600×800, 601×800, and 844×390. The existing `python/ui_check.py --check` passed all its desktop and 390px phone checks. Also inspected public pages at 320px and 390px.

These are Chrome mobile-emulation results, not physical iPhone/Safari tests. Authenticated settings, final scoring, long score histories, unusually long names, screen readers, OS keyboards, and network interruptions were reviewed in source but were not exercised end to end. Idle/discard timeouts were extended only in the audit process to allow inspection. Product behavior and styling were not changed.

Evidence is in [mobile-audit/](mobile-audit/). `measurements.json` contains game element bounds; `form-measurements.json` contains public-page measurements. A subtle measurement issue matters: during eight-card overflow Chrome reported `innerWidth=473` for a requested 390px device width. The screenshots and element positions relative to the requested viewport reveal clipping that a `scrollWidth > innerWidth` check can miss.

## Findings, in priority order

### 1. High: winning the bid hides cards during discard — reproduced

`assets/css/app.css:700` makes the hand a centered, nonwrapping flex row. Images have explicit widths and `max-width: none`. The mobile rule at line 910 explicitly budgets for **five** cards using `17vw`. But `lib/website_45s_v3/game/game_controller.ex:1030` adds three kitty cards to the winner's five-card hand.

At 390px, eight cards plus margins need approximately 554px. The first card began at x=-82px and ended at x=-16px: completely outside the visible left edge. The last card also extends beyond the right edge. Global `overflow-x: hidden` does not fix this and removes the normal way to reach the overflow.

[Screenshot: eight-card discard at 390px](mobile-audit/discard-eight-390.png).

**Fix:** give the eight-card discard state a deliberate layout, preferably a four-by-two grid on narrow portrait screens. Keep ordinary five-card hands in one row. Preserve large readable cards rather than fitting eight by shrinking them to tiny targets. Allow enough space for the selected-card lift so it cannot overlap another row or the action button.

### 2. High: short/landscape screens lose the play controls — reproduced

The only game breakpoint is width ≤600px (`assets/css/app.css:872`). A landscape phone exceeds that width and gets 100×160px desktop cards, larger typography, and the desktop table grid. Nothing budgets the game against available height.

At 844×390, Play Card began at y≈494px and the hand began at y≈558px, ending at ≈718px. Neither was visible without scrolling. In contrast, the five-card hand ended at ≈502px on a 390×844 portrait screen, and ≈437px at 320×568.

[Screenshot: landscape first screen](mobile-audit/playing-844.png).

**Fix:** use an app layout with compact status, flexible table area, and a stable hand/action area. Include a short-height/landscape layout, potentially with controls beside the table. Size played cards separately from selectable hand cards. Account for browser toolbars and safe areas; allow scrolling as a fallback for enlarged text rather than clipping controls.

### 3. High: scores are not a contained mobile dialog — reproduced; long-history risk from source

`.score-overlay` is a flex **row** (`assets/css/app.css:803`); the scoring wrapper and Close button are separate children (`game_live.ex:387`). The scoring wrapper has `height: 100vh` (`game_live.ex:736`). There is no bounded scrollable dialog panel.

Opening scores from the overflowing eight-card hand at 390px placed Close at x≈386–473px, almost entirely outside the visible screen. The screenshot shows scores across the top and a sliver of the button on the right. Tapping the backdrop still dismisses it, so this is not a complete trap, but the explicit escape control fails. Long histories can extend outside the fixed overlay without a dedicated scroll area. Normal scoring also adds a whole viewport below existing page chrome (933px document at 844px height).

[Screenshot: score overlay](mobile-audit/scores-overlay-390.png).

**Fix:** one bounded panel containing a header, visible Close button, and scrollable score body. Use “Your team” / “Opponents” headings with names as secondary text. Preserve focus within the dialog and return it to its opener. Handle backdrop clicks separately from panel clicks.

### 4. Medium: touch targets and selection feedback need work — measured/source

At phone width, Play Card, Confirm Keep, and number-bid buttons are about 35px tall; View Scores during play is about 28px. The password eye is 36×20px. Main lobby actions are already generous at about 64px tall.

Play Card is enabled on the user's turn even with no selection; Confirm Keep is enabled before any card is selected. Their hooks silently do nothing with an empty selection (`assets/js/app.js:260–294`). Cards move upward to show selection, but the wrapping button does not expose selection with `aria-pressed`. Selecting a sixth keep card silently deselects the oldest selection.

**Fix:** target 44–48 CSS pixels for frequent touch controls. Keep tap-to-select followed by explicit confirmation; this is a useful protection against accidental plays. Disable confirmation until valid, show “Keep 3 of 8,” distinguish kept/discarded cards clearly, and expose selection to assistive technology. Avoid silently changing an earlier selection at the limit. Make hand and confirmation positions stable across phases.

### 5. Medium: fixed offsets cause label collisions — reproduced; long-name risk from source

The table combines proportional card tracks with fixed/negative offsets (`app.css:729–800`, `game_live.ex:691`). At 390px, the top player name starts at y≈77px while the turn message ends at ≈81px; the labels visibly crowd/overlap. Registered usernames can be 30 characters, but names lack a deliberate wrapping or truncation policy. Actions also join all messages into one running string.

[Screenshot: three cards played](mobile-audit/playing-three-cards-390.png).

**Fix:** allocate separate space for names, turn status, and cards. Keep seat identities stable even before someone plays. Show the latest action briefly and put detailed history behind a secondary control. Test maximum-length names and increased text size.

### 6. Medium: account-form spacing has visible defects — reproduced

Login's username input has a measured 45px box, but the next field's painted background covers its lower portion. The combination of zero input bottom margin and the common input component's `margin-top: -20px` error wrapper pulls the following field upward (`app.css:181`, `core_components.ex:394`). The reset-email input is 322px wide on a 320px viewport: the shared rule uses `box-sizing: content-box`, 90% width, and added padding/borders (`app.css:167`). Password visibility controls are small.

[Screenshot: login](mobile-audit/phone-log-in.png).

**Fix:** use normal-flow field/error spacing and border-box input sizing, consistent page padding, and larger eye-button hit areas. Input text measured 16px on portrait phones, which is a useful existing baseline. Still test real mobile keyboards, autofill, and error messages. Settings and confirmation/reset-token forms share components and should be included in that pass.

### 7. Lower priority: learning and secondary pages

- **Home:** readable, buttons stack, and tested widths fit. The 140px logo creates a ~129px header, and generous hero spacing makes the page long. Reduce chrome if conversion data suggests it helps; this is not a game blocker.
- **Public/private lobby:** cards and actions wrap and the share URL truncates. These are useful responsive foundations. Consider a native share-sheet button alongside Copy; enlarge the Copy target. Test four long names and the active-game banner.
- **Learn:** `learn.html.heex:134` requests `/images/learn/bidding.gif`, which is absent and visibly fails to load. Tutorial images are 75% of the content width, leaving desktop UI examples small on phones. Replace outdated captures with phone-readable examples and a concise in-game reference. The scoring explanation also describes total/change columns while the current table has one column per team.
- **Admin:** wide multi-column analytics tables lack their own horizontal scroll containers; global overflow hiding risks clipping columns. The timeline already scrolls locally. The replay player computes width once at creation, with no resize handler in the app hook. These are source-review risks, not reproduced authenticated-screen findings.

## Recommended phone interaction model

Make portrait the primary design target. A responsive browser game is a suitable starting point; a native rewrite is not required to fix these issues.

Use a compact top area for score, trump/bid, turn, and connection state. Keep the current trick in the middle. Put the player's hand and one contextual confirmation action together in the lower reachable area. Use the eight-card grid during discard and a single row during ordinary play. Keep secondary rules/history/scores in an accessible panel. Do not force rotation or shrink the whole desktop surface with a transform.

Use layout space, not negative margins, to reserve labels and selection movement. Use viewport-height-aware layout (`svh`/`dvh` as appropriate) and safe-area padding for edge controls. Distinguish mouse hover from touch using input-capability queries. Retain browser zoom and keyboard operation.

Mobile interruption handling deserves a separate real-device check. The app already has reconnect notices, rejoin, bot takeover, and resume behavior. Defaults include 30-second idle/discard timeouts and a 60-second unattended timeout when all non-bot players are absent. A solo player switching apps can therefore lose a game after sufficient absence. Explain takeover/recovery clearly, consider a visible turn timer, and use an explicit Resume button instead of a transparent whole-screen click catcher. Choose timeout policy deliberately; do not simply lengthen every multiplayer timer.

Installability can follow a good browser experience. A web-app manifest and suitable icon/display settings could support a home-screen experience. Cache static assets if useful, but an online multiplayer game must still communicate that live play needs a connection. Native packaging alone will not correct CSS or touch behavior.

## Verification and rollout

1. First fix eight-card discard, short-screen controls, and the score dialog.
2. Then stabilize the game layout, enlarge controls, and improve selection feedback.
3. Fix shared forms/tutorial defects and extend the existing browser checks.

Add real gameplay coverage for bidding, five/eight-card discard, selected cards, all four played cards, short/long score histories, final scoring, takeover, and reconnect. Test 320/360/390/430px portrait, 600/601px boundaries, and phone landscape. Check actual control/card rectangles and hit testing against the requested viewport: page scroll width alone is insufficient. Include long names, enlarged text, and errors. The existing screenshot helper temporarily increases viewport height for full-page capture; keep separate fixed-viewport screenshots to test what is visible without scrolling.

Complete a physical-device pass on iOS Safari and Android Chrome with browser bars expanded, keyboard open on forms, rotation mid-selection, background/foreground, and a connection interruption. Measure production asset/network and input latency separately: rrweb is imported into the common bundle even though recording runs only in games, making lazy-loading a candidate, but no performance regression was measured in this audit.

Use analytics to compare mobile vs desktop game starts, first completed discard/trick, completion, abandonments by phase, and idle takeovers, preferably by viewport range. Traffic share alone does not show whether visitors can finish games. Replays from bid winners are particularly valuable given the reproduced eight-card defect.

## References

- [Mobile First — Luke Wroblewski](https://www.lukew.com/resources/mobile_first.asp). The best initial book for this project: organize content, actions, input, and layout around the constrained screen. The author provides free reading/downloads. Published in 2011; use its design principles alongside current implementation guidance.
- [Designing for Touch — Josh Clark, author excerpt](https://alistapart.com/article/how-we-hold-our-gadgets/). Useful for hand position, reach, and arranging controls for touch.
- [Google: responsive web design basics](https://web.dev/articles/responsive-web-design-basics). Content fitting, flexible images, and breakpoints based on content/device capabilities.
- [W3C: target size minimum](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum). WCAG 2.2 AA specifies 24×24 CSS pixels with exceptions, including spacing; 44–48px here is a usability recommendation, not a claim that every smaller control automatically fails WCAG.
- [W3C: WCAG 2.2](https://www.w3.org/TR/WCAG22/). Enhanced target size is 44×44 CSS pixels. Reflow has exceptions for content that requires two-dimensional layout; the app should still keep essential game controls usable.
- [Google: accessible responsive design](https://web.dev/articles/accessible-responsive-design). Recommends 48px touch targets and addresses text scaling and focus order.
- [Google: CSS sizing units](https://web.dev/learn/css/sizing) and [MDN: env()](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Values/env). Current viewport units and safe-area insets.

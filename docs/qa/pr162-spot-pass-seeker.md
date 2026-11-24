# PR #162 Spot Pass seeker flow (C1) - QA, 2026-11-23

**Reviewed:** `feat/spot-pass-c1-seeker` (PR #162) built Debug on iPhone 17 (iOS 26.5) and a temp iPhone SE (3rd gen), against `docs/specs/qr-spot-handoff.md` Rev 2 and `docs/design/spot-pass-design.md`. Live, fake API (`-spotPassUseFakeAPI YES`).
**Verdict: MERGE-WITH-FOLLOWUPS.** No blocker found. Flag-off is inert, the flag-on flow works end to end and the QR decodes. Follow-ups are copy/layout polish plus two decisions the builder already flagged.

## Per-check table

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Flag OFF, main defaults | PASS | `assets/pr162/off-launch.png`: ASP banner, legacy toolbar (locate, Park Until clock), Report + "?" pills, persistent browse sheet all render. No crash. |
| 1b | Flag OFF, More sheet has no Spot Pass row | PASS | The More sheet is only reachable when `driveModeDefaultEnabled` is true (main default is false), so I built once with that flipped and `spotHandoffEnabled` false: `off-more2.png` shows Report, What the colors mean, Parking 101, palette toggle. No Spot Pass. |
| 2a | Flag ON: row directly below Report | PASS | `on-more.png`; AX tree order Report, "Spot Pass, Ask a neighbor for their spot", What the colors mean. |
| 2b | Explainer, create, full-screen cover over browse sheet | PASS | `on-explainer.png` (indigo, "Pass the spot.", 3 steps, first-name toggle off by default, "Off: neighbors see Bodega Cat"). Cover replaces the whole screen incl. browse sheet. |
| 2c | Badge: QR, countdown, alias, glyph, karma chip | PASS | `on-badge.png`: "Leaving soon? / Scan to pass me your spot.", QR with 3 indigo-centred eyes + center pin mark, cat glyph + "Bodega Cat", "good for 19:41" + TTL bar, chip "Helped a few" (bucket, no number). AX label "Spot Pass for Bodega Cat. Good for 19 minutes 42 seconds." |
| 2d | Armed | PASS | `on-badge2.png`: "A neighbor's on it. / Leaving in about 30 min." (band, no clock time), checkmark on avatar, QR replaced by avatar plate. AX tree changed to "A neighbor scanned your Spot Pass." Haptic not feelable (device-only). |
| 2e | Departed, "heads-up" copy | PASS | `on-departed.png`: "Spot opening up. / Your neighbor is pulling out now." + "It's a courtesy, not a promise. Stay alert when you head over." Buttons "Got it, thanks!" / "Didn't work out". No "ping". |
| 2f | Outcome confirm shows karma only when seeker_points > 0 | PASS (live +3) / code | `on-outcome.png`: "+3 karma" chip. Zero-points path verified by code read only (PR tests cover it, not run locally). |
| 2g | Expired | NOT VERIFIED live | Fake demo has no expiry script (20 min TTL). Code: reducer + `finishTerminal`. Recommend a device pass. |
| 2h | Stop waiting | PASS | Tap returns to map immediately; reopening More then offers a fresh pass. |
| 2i | Relaunch mid-pass restores active pass | PASS with caveat | Cold relaunch, More > Spot Pass reopens the same live pass (alias Bodega Cat, 18:11 remaining). Caveat: the fake's armed/departed script is keyed to an in-memory `createdAt`, so a restored pass stays "open" under the fake; that is a fake limitation, not a product bug. A relaunch does not auto-present the cover (only the More row or a push tap does; see F4). |
| 2j | Parking a car / ending drive ends open/armed pass, not departed | CODE ONLY | `ContentView` hooks call `endBecauseSeekerParked/DriveEnded` -> `autoEnd` guarded by `phase.isCancellable` (`.open, .armed` only; departed explicitly excluded). Not driven live (no parked-car path scripted on sim). |
| 3 | QR decode | PASS | CoreImage `CIDetector` on the 3x screenshot (`on-badge.png`, full res) returned `https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-` (48 bytes, under 62). The fake token is shorter than a real one; builder's URL-budget test covers the real length. Decoded despite rounded modules, indigo eye centers and the center mark. |
| 4a | iPhone 17 default | PASS | screenshots above. |
| 4b | AX5 (QR first) | PASS with nits | `ax5-badge.png`: Done / sun button scale, QR fully visible and first, "Leaving soon?" headline. Alias/countdown scroll below the pinned "Stop waiting" button. See F5. |
| 4c | SE default and XXXL | PASS | `se-badge.png` fits everything incl. countdown; `se-xxxl.png` QR full, countdown scrolls behind the pinned Stop button (F5). |
| 4d | Landscape | DEVICE-ONLY | simctl/AXe cannot rotate. Code has a `landscapeContent` branch (plate left, info right) keyed on `verticalSizeClass == .compact`. Not seen. |
| 4e | No green/orange/red in Spot Pass chrome | PASS for chrome, one miss on the rationale sheet | Grep of `Views/SpotPass` and `Services/SpotPass` for `.green/.red/.orange/systemGreen...`: no hits. Visuals indigo/lavender. The reused notification rationale is orange (F2). |
| 4f | Reduce Motion | CODE ONLY | `simctl ui` has no reduce-motion option. `accessibilityReduceMotion` read in Badge (entrance spring -> 0.2 s ease-out, offset removed, pulse ring off) and Departed (rings suppressed). |
| 5 | Brightness / keep-awake exit paths | CODE REVIEW, no defect, one device note | `SpotPassScreenController.apply(boost:)`: boost only when `scenePhase == .active && phase == .open` (`SpotPassBrightnessPolicy.shouldBoost`). Armed / departed / settled, background (scenePhase change -> `syncScreen`), Done and Stop (cover dismissal -> `.onDisappear { controller.end() }`) all route to `apply(false)`, which clears `isIdleTimerDisabled`, removes the observer and ramps back to `savedBrightness`. Manual slider override respected after 2 s. Device note: the restore is a 250 ms async ramp; verify on hardware that backgrounding mid-pass leaves brightness at the user's level (F6). |
| 6 | Notification categories merge | CODE REVIEW | `NotificationCategoryRegistry.register` reads existing categories, merges by identifier, writes the union; launch path builds both categories from the flags and writes in one call. `registerAddressCategory()` in `NotificationScheduler` now delegates (no other `setNotificationCategories` caller in WePark/Shared/Clip; grep clean). Both-flags-off registers nothing. Live read of registered categories not possible without a debug hook. Backend `send-handoff-push` source is not on this branch, so the category id the server sends (if any) vs `wepark_spot_pass_seeker` is not verified here. |

## Findings

### Blocking
None.

### Significant
- **F1: Notification rationale appears on every pass create, with street-cleaning copy and an orange bell.**
  - What: After "Create my Spot Pass" a bottom sheet "Stay ahead of street cleaning / Get a reminder before alternate-side parking starts..." with an orange bell appears over the pass (`rationale-orange-bell-ax5.png`; seen on every create, including after "Not now"). It is the builder's known gap #3, but it is the first thing every seeker sees and contradicts the design (indigo-only, Spot Pass voice) and the ban on irrelevant content. At AX5 it truncates ("Stay ahead of...").
  - Expected: a Spot Pass specific rationale ("We'll tell you when they pull out"), indigo, shown once (or only until answered), not each create.
  - Owner: `@ios-engineer`. Fine to ship dark (flag off); must be fixed before the flag flips.
- **F2: Seeker APNs token never reaches the backend (builder gap #1).** `armed`/`departed` pushes cannot arrive until `PushRegistrationService` registers for Spot Pass; only polling works, and only while the screen is open. Needs an orchestrator decision before the flag flips. Owner: `@ios-engineer` + `@backend-data`.

### Minor
- **F3:** Design 9.2 "ping" vs 10.1 ban resolved as "heads-up" (explainer step 3 and departed screen). Agree. Design doc should be corrected. Owner: `@designer`.
- **F4:** No auto-resume entry: after cold relaunch or Done on an armed pass there is no map card; the pass is reachable only through More > Spot Pass (builder gap #4). A seeker who tapped Done on an armed pass has no visible cue it is still live. Follow-up before flag flip.
- **F5:** AX5 / SE XXXL: the pinned "Stop waiting" button covers the alias row and countdown until scrolled (`ax5-badge.png`, `se-xxxl.png`); at AX5 the "WePark" wordmark wraps to "WePar / k". SE default has "Stop waiting" touching the card's bottom edge. QR stays first and unclipped, so this is polish. Owner: `@ios-engineer`.
- **F6:** Brightness restore is a 250 ms async ramp (`SpotPassScreenController.ramp`) started on scene deactivation. If iOS suspends the app before it finishes, brightness could stay partly raised. Not measurable on sim; confirm on device, or snap (no ramp) to the saved value when releasing on backgrounding.
- **F7:** More sheet is cramped at AX5 (pre-existing layout: rows wrap one word per line); Spot Pass row is below the fold and needs scrolling. Not caused by this PR.

### Out of scope (logged)
- Seeker Live Activity, auto-advance (design 7.3), "Share my karma", compact map-sheet card (2.8): not in C1.
- `profiles` RLS assumption for the first-name toggle (toggle simply stays disabled if denied).

## Device-only (listed, not failed)
- Through-glass scan distances (design 1.5 table), real haptics (success on armed), actual brightness/auto-lock behavior, landscape layout, VoiceOver spoken order and the armed announcement, Reduce Motion toggled in Settings, expired state with a real 20-minute TTL, real APNs delivery, parked-car / drive-mode auto-end.

## What's working
- Flag-off is genuinely inert: no row, no cover, no crash, toolbar / ASP banner / browse sheet unchanged.
- Mount-chain smoke passed: toolbar layer, ASP banner and persistent browse sheet render with the new `fullScreenCover`/`onChange`/`onReceive` in ContentView, and the cover presents cleanly over the browse sheet and dismisses back to it.
- The QR is robust: rounded modules, custom eyes and center mark still decode with CoreImage at 48 bytes.
- Copy follows the voice rules (no banned words seen, "courtesy, not a promise"); karma is bucketed on the badge and exact only on the confirmed outcome.
- State machine behaves: created -> armed (band only) -> departed -> settled(+3), Stop and relaunch restore all work.

## Cleanup performed
`Constants.swift` reverted (never committed), `Config.xcconfig` removed, app uninstalled, simulators shut down, temp SE device deleted, derived data deleted.

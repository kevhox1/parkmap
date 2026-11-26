# PR #214 Stoop 6a follow-ups QA, 2026-11-26

**Reviewed:** `fix/stoop-6a-followups` @ `176d12d2` (base `dcf61661`), also merged with #213 onto main `6283cc6a` (clean merge). Source findings: `docs/qa/pr212-stoop-phase6a-qa.md`.
**Verdict:** MERGE-WITH-FOLLOWUPS (flag defaults off; nothing blocking)

## Summary
The "token not visible" finding is explained and the builder's "works as designed" is right: on my sim the only condition blocking the token was a persisted saved car, and the rules on `ContentView.v2ShowsRestingToken` are sound. Coach 3 copy now follows the token (verified live), coach 2 never put a ring on a control, the location prompt only appears after Allow (re-verified at normal load), and the remaining items are correct in code and tests. Combined merge: 3182 tests, 1 skipped, 0 failures; all four schemes build.

## Checklist
- [x] Token rules (`ContentView.swift` `v2ShowsRestingToken`, doc comment) sanity-checked: Stoop on + `driveModeDefaultEnabled`; not AX size; no saved car; no trip plan; no sheet; not drive/block/spot/curb placement; not outside Manhattan coverage; no-fix / denied / unloaded tiles do not hide it. All reasonable ("nothing outside coverage may look parkable", the token must not compete with a saved car). Caveat in finding #1.
- [x] Reproduced QA's "no token" live: fresh install, flags on (Stoop + `driveModeDefaultEnabled` + `onboardingStoryEnabled`, local only), Times Square fix, light mode. No "Car token" in the AX tree, not drawn. Temporary NSLog of every gate input (removed): `parked=1`, all others 0, `outside=0`, `ax=0`. The simulator's iCloud key-value store restored a saved car after uninstall/reinstall, so the card is a leftover-state artifact, not a wrong-firing condition. Builder's `coach-3-token.png` / `token-manhattan-*.png` (read) show the token + hint on a clean state.
- [x] Coach 3 copy follows token visibility: live, with the token hidden, coach 3 read "Tap a green curb, then Park here / WePark saves where you parked and can remind you before it changes." and the card layout stopped reserving token room. With the token drawn the copy is "Drag the car to park" (builder shot, read; logic `tokenCopyApplies` + tests).
- [x] Coach 2 ring: live at Times Square the user dot sits under the search row, every candidate curb failed `WPCoachAnchorLogic.isClear`, so no ring and the card sat at the top. Ring never lands on the search row, chrome, sheet, edges or token by construction. Residual (card touching the search row with no ring): not reproduced, card bottom was about 137 pt above the search row in my run. Rate nit.
- [x] Story copy: card 1 now reads "WePark reads NYC's posted parking signs, curb by curb, so you don't have to." and card 2 "Tap a curb to see how long you can stay and the sign behind it." No "every curb". Card 3 "until morning" / "several days" unchanged.
- [x] Settings notification status re-reads on `scenePhase == .active` (`WPSettingsV2.swift`, `WPSettingsLogic.shouldRefreshNotificationStatus`), plus the initial `.task`. Code and tests only, not live (needs toggling iOS Settings).
- [x] Night-before time row hidden when the toggle is off (`showsNightBeforeTime`). Code and tests only.
- [x] Location prompt (fresh install, flag on, load about 12): deck 1, 3, then "Let WePark see where you are" screen with NO system prompt; tapped Allow location, prompt appeared; Allow While Using; coach 1 showed. Matches builder.
- [x] Flag-off identical: new params default to the old behavior (`tokenVisible = true`), changes are in Stoop-only views and pure helpers; the one ContentView edit adds an argument and a Stoop-only function.
- [x] DEBUG launch args: nothing new in #214 (6a showcase is already `#if DEBUG`).
- [x] `SuggestNeighborhoodSheet` "Manhattan" literal: TODO comment only (dark-shipped).

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1: With a saved car the home screen has no draggable token and no visible car marker in my run, so a returning tester sees an empty map-center.** By design (My Car owns that state) and "More > Find my car" exists, but I did not locate a saved-car indicator on the home screen in this state (the car's coordinate was not on screen; not investigated further). Worth a designer glance, not a defect in this PR. Also note for QA hygiene: the sim's iCloud KVS keeps the saved car across uninstalls, so "clean install" is not clean for this feature. Owner `@ios-engineer` / `@designer`.
- **#2 (nit): Coach 2 no-ring card position near top is fine here, but the "touches the search row" residual stays unverified on a device where the card lands low.** Logic reserves `toolbarRowHeight`, so a collision would need the `fitsBelow` branch to be wrong; unit tests cover `isClear`.

### Out of scope
- Onboarding, location screen and the More replay are still gated by dark-shipped `onboardingStoryEnabled` / `driveModeDefaultEnabled`; a Stoop-on build must flip all of them (the token also needs `driveModeDefaultEnabled`).
- "For days until ..." date label differed between runs (Fri 11/27 vs Sun 11/29): time-of-day / holiday dependent, not part of this PR.

## Smoke tests run
- Merge of #213 + #214 onto origin/main: clean. All four schemes build. Full WePark suite `-parallel-testing-enabled NO -jobs 4`: 3182 tests, 1 skipped, 0 failures.
- Live flag-on walk on iPhone 17 Pro sim: fresh install, deck cards 1 and 3 (screens read), location screen, Allow + prompt ordering, coach 1 (ring on tile row), tile tap to coach 2, coach 3, Got it, post-coach map, AX tree check for the token, gate-input log. Flags reverted, tree clean before commit.
- Not run: Settings foreground refresh live, night-before row live, Release `strings` check.

## What's working
- Doc comment on `v2ShowsRestingToken` plus the rule "anything asking whether the token is on screen must call this" is the right fix for copy drifting from reality.
- `WPCoachAnchorLogic` is pure and tested, and the failure mode is "no ring", never "ring on a control".
- Honest, narrower story copy.

**MERGE-WITH-FOLLOWUPS**

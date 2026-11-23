# First-run onboarding QA follow-ups (open item #41) QA — PR #150

**Reviewed:** branch `fix/onboarding-qa-followups` at `79ddf56e`, against `docs/qa/pr149-first-run-onboarding.md` (findings #1-#11), the PR body, and `docs/design/first-run-onboarding-design.md` (incl. the dated "Set when" note).
**Verdict:** MERGE-WITH-FOLLOWUPS. Every 🟡 from the PR #149 report that was supposed to be fixed is fixed and was re-verified LIVE. Nothing regressed. Two items remain open by design (#10, #11, both ruled non-blocking below), plus four 🟢 nits.
**Env:** Kevin's MacBook, Xcode 26.6, "iPhone 17 smoke" sim, iOS 26.5. `driveModeDefaultEnabled` and `onboardingStoryEnabled` flipped LOCALLY, then reverted with `git checkout -- ios/WePark/WePark`, rebuilt flags-off, fresh-installed. Driven with AXe. Screenshots in `/tmp/q150` (not committed, deleted after). Full test suite NOT run locally (disk), per instructions.
**CI:** `Build and XCTest (Xcode 26)` was still `pending` on run 45119287671 when this report was written (see the final message for the last value).

## Summary

The coach now waits for the priming card, survives the first-grant recentre with no touch, reacts only to real user gestures, stays inside the safe area at standard, AX3 and AX5, tracks the selected tile for all three tiles, and anchors mark 3's ring to a real on-screen curb through a new projection seam (ring verified on a W 34th St curb; no ring on the Great Lawn). The mid-deck force-quit now re-shows the deck, and the upgrade path is still coach-only. Flags-off renders like main. The remaining gaps are cosmetic or verification-only (#10 dot clipped by the bubble, #11 VoiceOver unverified in the sim), and neither is a flip-blocker.

## Per-finding table (PR #149 findings)

| # | Finding | Status | How | Notes |
|---|---|---|---|---|
| 1 | Coach over priming card | FIXED | LIVE | Fresh: cards -> priming (screenshot read, no coach behind it) -> Allow -> coach appears only after. Upgrade seed also: priming alone, coach after Allow. |
| 2 | Programmatic recentre kills mark 1 | FIXED | LIVE | Fresh, Allow -> While Using, no touch: mark 1 present at +7s after the Apple Park -> MSG recentre. |
| 3 | AX3/AX5 clipping | FIXED | LIVE | Marks 1, 2, 3 at AX3 AND AX5 all inside the safe area, headline/body/Got it/Done/Skip visible. See 🟢 N1 (tiles covered). |
| 4 | Mark 3 left clip | FIXED | LIVE | Standard size, bubble left edge ~x=60/1185, Done fully visible, at two locations. |
| 5 | Mark 2 ring on wrong tile | FIXED | LIVE | Re-run with all 3 tiles: left (Overnight), middle (A Few Hours), right (Park & Forget); ring follows each. |
| 6 | Mark 3 ring points at empty space | FIXED | LIVE | At (40.7523,-73.9928) ring sits on a W 34th St curb line (green); at the earlier map position ring sits on a red curb line. Great Lawn (no curb in range): bubble only, no ring. Pan after mark 3 dismisses it (and writes the gate). |
| 7A | Force-quit mid-deck | FIXED | LIVE | Fresh, deck open, `simctl terminate`, relaunch: deck shows again. Upgrade (`wepark_has_launched_before` only): zero cards, coach only. Sentinel logic read: flags-off first launch never calls `markDeckBegun`, so a flags-off sentinel user is still pre-seeded as upgrading at flip. |
| 7B | Pre-sentinel -> flags-on build | NOT FIXED (release-plan) | CODE | Unchanged, correctly left as a release-plan item. Must be on the flip checklist. |
| 8 | Gate write on pan | FIXED (ruling applied) | LIVE | Pan on mark 1 dismisses and `wepark_has_seen_onboarding_coach = true` appears in the app plist. Replay path skips the write (CODE, `finishOnboardingCoach`). |
| 9 | Deck Skip vs illustration at AX5 | FIXED | LIVE | AX5 card 1: Skip sits clear above the illustration. |
| 10 | Bubble clips the user dot | NOT FIXED (deferred) | LIVE | Still reproduces at standard size on mark 1. Ruled non-blocking, see below. |
| 11 | Map controls behind cover (AX tree) | NOT CHANGED (deferred) | CODE | Ruled non-blocking, see below. |

## Acceptance checklist (PR smoke checklist)

- [x] Flags off: nothing new renders — LIVE (fresh install screenshot: legacy toolbar, Parking 101 banner, search sheet, yellow ASP banner, as main). `OnboardingFlagOffGuardTests` not run locally; relies on CI.
- [x] Fresh install std: cards -> priming -> coach only after priming — LIVE.
- [x] First-grant recentre does not dismiss mark 1 — LIVE.
- [x] User pan clears the coach and writes the gate — LIVE. Relaunch showing no coach after the gate: CODE (gate read in `scheduleOnboardingCoach`); the relaunch after a pan was not separately screenshotted. More replay still works — LIVE (deck -> Skip -> coach mark 1 appears).
- [x] Mark 2 ring follows each of 3 tiles — LIVE.
- [x] Mark 3 with a curb on screen: ring on the curb — LIVE. "Pan/zoom while shown -> dismissed": pan LIVE; pinch CODE only (see below).
- [x] AX3/AX5/std inside safe area, Got it/Skip/Done tappable — LIVE (Got it tapped at both AX sizes; Skip tapped at AX5 deck... Skip visible at all sizes; tapped at std).
- [x] Force-quit mid-deck -> deck again; upgrade sim -> coach, no deck — LIVE.
- [x] Drive start / block tap handoffs: Start Driving during mark 3 cleared the mark and engaged drive (LIVE). Block-tap handoff not re-run (untouched code path; CODE).
- [x] More -> Parking 101 — LIVE (guide screenshot read). Replay keys unchanged — consistent with the keys in the plist; replay path does not write the gate (CODE).

## Deviation rulings

- **#2 plumbing via `onAmbientUserAdjusted`, dismissal on gesture settle:** ACCEPTED. Pan confirmed LIVE. Pinch: the observer `UIPinchGestureRecognizer` feeds the same `wasUserInteracting` flag (read at `MapViewRepresentable.swift` ~L3120-3130), so a pinch dismisses in code; AXe in this environment cannot send multi-touch (`axe gesture pinch` errors with a capabilities decode failure), so a live pinch is NOT verified. A bubble lingering during an in-flight gesture and vanishing on settle is acceptable (🟢 N3); it is also the user's own gesture, and the bubbles do not intercept map touches. Note the guard `placementController == nil` / `!driveModeActive` means no dismissal during a placement session or drive, consistent with the coach not mounting there.
- **#7 sentinel interplay:** CORRECT. `markDeckBegun()` writes an explicit `false` only when `showOnboardingStoryCover` is true and only if the key is absent. The sentinel's `object(forKey:) == nil` guard then holds on the next launch. Genuine upgraders (launched a flags-off sentinel build) never reach `markDeckBegun`, so they are still pre-seeded `true` at the flip.
- **`screenPointForCoordinate` seam (mount-chain file):** ACCEPTED. 14 added lines, pure read, `[weak mapView]` (no retain cycle, no stale capture), returns nil when the map has no window or the point is off-map. Called only from ContentView handlers (main actor), never from `updateUIView`. Flags-off it is assigned once with the other coordinator closures and never invoked (the only call sites are `onboardingNearestCurbScreenPoint()`, reached from onboarding-only paths, and `handleRegionChanged` gated on `onboardingCoachMark == .tapABlock`). The flags-off live screenshot confirms no visual change. The Swift change to `mapZStack`: the diff does not touch `mapZStack`; the coach overlay was already a child and its call site only gained parameters, so the top-level child count is unchanged (CODE).
- **#10 (bubble covers the dot):** NON-BLOCKER. Cosmetic: the dot is half hidden for the few seconds mark 1 is up, the user is told nothing wrong, and Got it/Skip both work. File as a pre-flip polish follow-up (dot-aware bubble placement), not a gate.
- **#11 (VoiceOver behind the cover):** NON-BLOCKER, with a condition. A UIKit `.fullScreen` presentation removes the presenter's view from the accessibility hierarchy, so the `axe describe-ui` listing is very likely a simulator artifact, and adding `.accessibilityHidden` would touch the mount chain. The one-time on-device VoiceOver pass the builder recommends must be a line on the flip checklist (it is a flip-time verification, not a merge gate for dark code).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None new.

### 🟢 Minor / nit

- **N1: At AX3/AX5 the coach bubble covers two of the three goal tiles during marks 1 and 2.**
  - Where: `OnboardingCoachOverlay` bubble region overlapping the dock top (the builder's stated tradeoff).
  - What: at AX3 and AX5 the tiles stack vertically; the bubble sits over Overnight and A Few Hours, so mark 1's "tap a tile" and mark 2's ring (on the selected tile) point at a hidden tile. Only Park & Forget stays tappable. The Skip pill also overlaps the top of Start Driving. No tile is permanently unreachable: Got it (always visible) advances, and Skip/Got it clear the bubble.
  - Repro: AX3 or AX5, upgrade seed or fresh, reach mark 1 (screenshots `e2`, `f1`).
  - Owner: `@ios-engineer` (follow-up: at AX sizes, anchor the bubble above the dock instead of over it, or collapse marks 1-2 to the Got it path).
- **N2: Tapping a tile while mark 2 is showing advances straight to mark 3.** Observed LIVE; plausibly intended (a tile tap counts as acting on the highlighted control) but not stated in the design doc. Confirm and document. Owner: `@ios-engineer` / design.
- **N3: Pinch dismissal is code-verified only.** AXe cannot do multi-touch here. Recommend one live pinch during the next device drive-test. Owner: Kevin / next drive test.
- **N4: Mark 1 bubble covers the lower half of the user dot (restating #10).** See ruling.

### 💡 Out of scope (logged)
- #7B pre-sentinel -> flags-on build remains a release-plan item (the sentinel build must reach everyone first).
- Pre-existing: legacy "New to NYC parking?" banner overlaps the Report button flags-off (visible in `m1` again); priming "Allow" hyphenation and goal-tile truncation at AX5.

## Smoke tests run

- Built ONCE flags-on (`-derivedDataPath ~/Library/Caches/wepark-qa150-dd`), one simulator, `df` 7.3 GB -> 6.6 GB after build.
- Fresh install std: deck card 1 (screenshot read), `simctl terminate` mid-deck, relaunch: deck present again. Continue x2 -> Let's go -> priming screenshot (no coach). Allow -> Allow While Using App, no touch, +7s: mark 1 present (screenshot).
- Simulated location moved to W 34th St mid-block; mark 1 -> tile tap middle -> mark 2 ring on middle; tile tap left at mark 2 advanced to mark 3 (N2). Mark 3 screenshot: ring over a curb, bubble inside the safe area.
- Pan on mark 3 -> bubble gone and gate written (plist read). Pan on mark 1 (separate run) -> gone and gate written.
- Upgrade seed (`wepark_has_launched_before` only): zero cards, priming, then coach after Allow. AX3 and AX5: marks 1, 2, 3 screenshots read (AX3: all three; AX5: marks 1 and 3 read, mark 2 not separately screenshotted at AX5, the layout is shared).
- Standard size, fresh coach per run: mark 2 ring for left and right tiles (screenshots read). Mark 3 at W 34th St (ring on green curb). Great Lawn: no ring.
- Start Driving during mark 3 cleared it. More -> How WePark works (deck, Skip, coach appeared). More -> Parking 101 (guide read).
- AX5 fresh deck card 1: Skip clear of illustration.
- Flags reverted (`git checkout -- ios/WePark/WePark`, tree clean), rebuilt, fresh install flags-off: legacy UI only (screenshot read).
- NOT run: full test suite (per instructions); live pinch; VoiceOver; block-tap handoff.

## What's working

- The coach now gates correctly on the priming card and the first-grant recentre; the `handleRegionChanged` change is small and the dismissal path is a single, well-commented hook.
- The projection seam is minimal, weakly captured, and produced a ring on a real curb at a real Manhattan location, with a clean nil path (Great Lawn).
- The per-tile frame reporting is the right root-cause fix for the stale ring (#5).
- `markDeckBegun()` is a precise, flag-correct fix that preserves the sentinel's flag-independence.
- Flags-off is indistinguishable from main.

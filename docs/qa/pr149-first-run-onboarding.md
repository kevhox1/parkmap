# First-run onboarding (open item #41) QA — PR #149

**Reviewed:** branch `feat/first-run-onboarding` at `2030588c`, against `docs/design/first-run-onboarding-design.md` (§6 acceptance checks) and the PR body.
**Verdict:** MERGE-WITH-FOLLOWUPS (dark-ship merge is safe; items 1-5 below must be fixed before either flag flips)
**Env:** Kevin's MacBook, Xcode 26.6, iPhone 17 sim, iOS 26.5. Flags flipped LOCALLY (`driveModeDefaultEnabled`, `onboardingStoryEnabled` = true) for the live pass, then reverted (`git checkout -- ios/WePark/WePark`) and rebuilt flags-off for the regression pass. Driven with AXe. Screenshots in `~/Library/Caches/wepark-qa149-shots/` (not committed).

## Summary

Flag-off, the app renders like main (screenshot checked): no new chrome, legacy toolbar and search sheet, Parking 101 prompt banner. Flag-on, the story deck, upgrade path, replay and Parking 101 row all work. The coach layer has real defects on the primary first-run path: it appears on top of the LocationPrimingCard instead of after it, it is silently killed by the post-permission camera recentre, and its bubbles clip off-screen at AX3/AX5 and (mark 3) even at standard size. None of this reaches users while dark, and the sentinel needs to ship early to be useful, so I recommend merging and filing the follow-ups as flip-blockers.

## 2,099 vs 2,100

UNEXPLAINED, but benign. CI run 42156754233 is on head `2030588c` and prints `Executed 2100 tests, with 0 failures` and zero skips. Only 2,098 unique `Test Case ... passed` lines are in the log, so even CI's own log is not self-consistent by line count (most likely parallel-runner interleaving). I could not tell whether the local 2,099 was a filtered or un-run test, or a counting method difference, within the time budget. 0 failures on both sides.

## Acceptance criteria (design doc §6)

LIVE = driven on simulator with AXe/screenshots. CODE = code/test read only.

- [ ] **1. Fresh install order: 3 cards, then priming, then 3 marks, zero dialogs before Tier 2** — PARTIAL, LIVE. Three cards render with exact copy and zero permission dialogs through "Let's go". The system dialog appears only after tapping Allow on the priming card. FAILED on ordering: coach mark 1 is visible AT THE SAME TIME as the LocationPrimingCard (finding #1).
- [x] **2. Skip on a card jumps to Tier 2/3, coach layer not skipped** — LIVE (Skip on card 1 at AX5; priming + coach mark 1 appeared).
- [ ] **3. Tile tap dismisses mark 1 and advances; pan clears all** — LIVE. Tile tap -> mark 2 appears, OK, but its ring is on the wrong tile (finding #5). Pan during mark 1 clears all marks: OK.
- [x] **4. Upgrade install: coach, zero cards** — LIVE. Clean state (sim defaults domain deleted, only `wepark_has_launched_before` seeded): 0 cards, coach shown, and `wepark_has_seen_onboarding_story = true` written to the app's own plist afterwards.
- [x] **5. "How WePark works" replays cards + coach, one-shot keys untouched, no priming** — LIVE for deck + coach and keys unchanged (`defaults read` before/after identical; coach gate started at 0 and stayed 0). Priming not re-shown: CODE only (priming is set once at launch; a launch with priming eligible was not combined with a replay).
- [x] **6. "Parking 101" row opens unchanged ParkingGuideView** — LIVE (screenshot of the guide).
- [x] **7. No coach in drive/blockSelect/spotPlacement** — LIVE for drive: tapping Start Driving during mark 1 cleared it and Cruise engaged. blockSelect/spotPlacement: CODE + unit tests only.
- [ ] **8. AX3/AX5** — FAILED for the coach, LIVE. Story cards pass (text scrolls above fixed Continue, illustration holds size, Skip stays reachable). Coach bubble overflows the top of the screen (finding #3).
- [x] **9. Colour discipline in new chrome** — LIVE visual (screenshots). Only blue/white/neutral chrome; green/red only in illustrations and live map/tile colours.

Additional live items from the dispatch: tap-a-block during mark 3 dismisses the bubble AND opens BlockDetailView (LIVE, OK; coach gate then written). Story and coach both seen: zero onboarding chrome (LIVE). Flags off: nothing new renders (LIVE).

## Findings

### 🔴 Blocking
None for a dark merge.

### 🟡 Significant (fix before flipping the flags)

- **#1: Coach mark 1 mounts on top of the LocationPrimingCard.**
  - Where: `ContentView.swift` `handleOnboardingStoryCoverDismissed` -> `scheduleOnboardingCoach` (~L4310-4340); `onboardingCoachOverlayVisible` only checks `activeSheet == nil` etc., and priming is a plain overlay, not a sheet.
  - What: 400ms after the deck closes, "Pick what you need." + the white ring + Skip pill render concurrently with the priming card (screenshot `04-priming.png`). Spec order is cards -> priming -> coach.
  - Repro: fresh install, Continue x2, "Let's go".
  - Owner: `@ios-engineer` (gate the coach on `!showLocationPrimingCard`, schedule it from `dismissLocationPrimingCard`).
- **#2: A programmatic camera move dismisses mark 1 with no user input (suspicion CONFIRMED).**
  - Where: `ContentView.swift` `handleRegionChanged` -> `dismissOnboardingCoachForMapInteraction()` (~L3359, ~L4404); no distinction between user gesture and programmatic region change.
  - What: fresh install, Allow -> Allow While Using App with no touch: mark 1 is present at t+1s and gone by t+2s, when the launch recentre moves the camera. The coach gate is not written, so it re-appears on the next launch. Not reproduced when location was already authorized (mark survived 12s idle, a simctl location change and a cold-launch recentre), so it is specific to the first-grant recentre, which is exactly the first-run path.
  - Expected: only user pan/zoom clears the marks (§2.3).
  - Repro: fresh install (or revoke location, seed story seen), Allow in priming, Allow While Using App, wait 3s.
  - Owner: `@ios-engineer` (use `regionWillChange` user-gesture flag / `wasUserAction`, or suppress during `recenterOnUserAtLaunch`).
- **#3: Coach bubbles clip off the top of the screen at AX3 and AX5.**
  - Where: `OnboardingCoachOverlay` mark 1 (also hits mark 2/3 by the same layout).
  - What: at AX5 the headline "Pick what you need." and the Skip pill are pushed above the safe area, under the status bar/Dynamic Island, and are unreachable (`23-ax5-after-skip.png`, `24-ax5-coach-alone.png`). Seen at AX3 too. "Got it" stays reachable. Spec AC8 says no clipping.
  - Repro: set content size AX5, fresh install, Skip the deck.
  - Owner: `@ios-engineer`.
- **#4: Mark 3 bubble clips off the LEFT edge at standard Dynamic Type.**
  - Where: mark 3 bubble placement (`13-mark3.png`): "Tap any block to see why." reads "Tap any block..." cut at x=0 and the Done button is cropped at the screen edge.
  - What: the bubble is offset horizontally by the bearing-derived anchor with no clamp to the screen.
  - Repro: reach mark 3 via Got it, Got it (any location where the nearest curb is west of the user).
  - Owner: `@ios-engineer`.
- **#5: Mark 2's ring highlights the wrong goal tile.**
  - Where: `12-mark2.png`. After tapping "A Few Hours" (now selected, blue), the white ring frames Overnight (left tile), not the selected tile. Spec says anchored to the selected tile.
  - What: single observation, not re-run with a third tile; likely stale tile-frame capture. Treat as unverified-but-observed.
  - Owner: `@ios-engineer`.
- **#6: Mark 3 ring anchor (deviation 1) points at empty space.**
  - What: ring renders ~30pt WNW of the user dot on the Madison Square Garden roof, not on a curb (`13-mark3.png`). Fixed 70pt bearing vector assumes user at map centre, north-up. Acceptable dark-shipped; needs a `MapViewRepresentable` coordinate-converter seam or removal before the flip.
  - Owner: `@ios-engineer`.
- **#7: Sentinel gaps (the previous agent's A and B, both confirmed by code read).**
  - A: story gate is written only on cover dismissal (`handleOnboardingStoryCoverDismissed`), so a fresh user who force-quits mid-deck is pre-seeded as "upgrading" next launch and never sees the cards.
  - B: users going from a pre-sentinel build straight to a flags-on build look fresh and get the full deck. The flip-build plan must ensure the sentinel build ships to everyone first.
  - Owner: `@ios-engineer` (A); Kevin/release plan (B).

### 🟢 Minor
- **#8:** Pan/zoom dismissal does not write the one-shot gate (matches the doc's "Set when" table), but the doc also says "never auto-replays". A user who always pans first sees the coach every launch. Spec ambiguity; decide and align.
- **#9:** At AX5 the story-deck Skip pill overlaps the top of the illustration (`22-ax5-card1.png`). Still tappable.
- **#10:** Mark 1 bubble covers the user's blue dot at standard size.
- **#11:** AX tree: while the deck was visible, `axe describe-ui` listed the map's controls under the cover. Not verified whether VoiceOver can reach them; recommend a VoiceOver pass.
- **#12 (deviation rulings):** `.onGeometryChange` instead of `anchorPreference` -> 🟢 accepted. `restricted` vs `restrictedNow` naming -> 🟢 accepted.
- **#13 (Skip vs ASP banner):** no collision. At standard size the Skip pill sits ~60pt below the banner (`06`/`07` screenshots). At AX5 it is pushed behind the Dynamic Island (see #3).

### 💡 Out of scope (logged)
- Priming card "Allow" button hyphenates to "Al-low" at AX5 and the goal tiles truncate at AX5 (both pre-existing).
- Legacy "New to NYC parking?" banner overlaps the Report button flags-off (pre-existing, visible in `30-flagsoff.png`).

## Rulings

- Mark 3 bearing anchor: 🟡 (#6), fix or add seam before flip.
- `.onGeometryChange`: 🟢. `restricted` naming: 🟢.
- Sentinel unconditional write: acceptable and correct to ship now (two synchronous UserDefaults writes), with the 🟡 A/B caveats above.

## Smoke tests run

- Flag-on build, fresh install, location reset: deck cards 1-3 (screenshots read), priming, system dialog order, coach mark 1/2/3.
- Idle 12s with mark 1 showing, simctl location change, cold-launch recentre: mark survived. First-grant recentre: mark killed (#2).
- Pan (AXe swipe) cleared all marks. Start Driving cleared the mark and engaged Cruise.
- Block tap during mark 3 opened BlockDetailView; gate written.
- More -> How WePark works (deck + coach, keys unchanged), More -> Parking 101.
- Upgrade path with a clean seeded defaults domain; both-seen path.
- AX3/AX5 on deck and coach.
- Flags reverted, rebuilt, fresh install: legacy UI only.
- Tooling note: `simctl spawn defaults` writes the sim-level domain, which survives uninstall; I deleted the domain between runs. An early "upgrade" reading was a stale-domain artifact and was redone cleanly.
- Not run: full test suite (per instructions).

## What's working

- Flag-off is clean; the one flag-independent change (sentinel) behaves correctly.
- Upgrade path and the pre-seed write work exactly as designed.
- Story cards: exact copy, progress bar, Skip, fixed Continue, text scrolling at AX sizes, no early permission dialogs.
- Replay bypasses both one-shot gates; Parking 101 entry is correct; drive-start and block-tap handoffs are clean.

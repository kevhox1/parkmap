# PR #193 (no-sign-data label / empty rules) QA — 2026-11-25

**Reviewed:** branch `fix/ios-nodata-label-empty-rules` at `ce1477b9`, against the PR's stated claims (no spec doc).
**Verdict:** MERGE (one pre-existing 🟡 launch-perf issue found, not caused by this PR)

## Summary
The engine change is correct and complete: every goal/ladder/drive/Plan-a-Trip path funnels through `ParkingRulesEngine.isFree`, which now returns false for empty rules and the synthetic NO DATA rule. Live on the simulator, a real no-data curb shows "We don't know / No sign data / Read the posted signs..." plus the plain reason, no "No Parking" badge, no fake sign rows, red band kept. WeParkTests: 2954 passed, 0 failed, 1 skipped. The "black screen is just a MapKit tile load" claim is wrong: it is an app-side main-thread stall (finding #1).

## Acceptance checklist
- [x] `isFree` false for empty rules and NO DATA rule — code read + NoSignDataTests + ParkUntilTests.
- [x] `safetyLabel` = "No sign data", severity unknown — tests + live (park-confirm).
- [x] No goal path can show no-data as free — all callers go through `isFree`: ParkingGoals (match/ladder/`nextMoveForcingDate`), `resolveParkAndForgetViewport`, ContentView overlay classification (2924/2943), DrivingContextService (798 / `safetyLabel` severity .unknown never counted free), TripPlanning.isFree/planTrip (185/235). My Car "free until" is replaced by the advice line for no-data. Reminders: NO DATA rule is an always-on NO_PARKING so `nextRestriction.isActiveNow` -> NotificationScheduler returns early; empty rules -> `isUnrestricted` -> returns early.
- [x] Three changed tests are legitimate. ParkUntilTests: spec flip (empty = unknown, not free). ParkingGoalsTests and DriveCardChipAgreementTests: the fixtures used `rules: []` as a stand-in for "nothing restricts"; swapped for a FREE-category rule, which preserves the original intent (nil goodThroughLabel; chip .free). No assertion was weakened.
- [x] NO DATA prefix cannot catch a real sign — scanned all 47,696 tile segments: 52 segments contain a rule starting "NO DATA"; every one is the synthetic string "NO DATA - ONLY A SUPERSEDED SIGN ON RECORD - TREATED AS NOT PARKABLE" (NO_PARKING, anytime). Zero other descriptions contain "NO DATA" anywhere. No empty-rules segments exist in tiles. Bundled `Resources/tiles` matches `tiles/`.
- [x] UI: block detail, park-confirm, parked-car detail (My Car) — verified live (screenshots below). Map line unchanged red (Park Until active, line stays red).
- [ ] Black-screen claim — NOT confirmed as stated. See finding #1.

## Findings

### 🟡 Significant
- **#1: First-launch "black screen" is an app-side main-thread stall, not a MapKit tile load**
  - Where: `ContentView.handleSegmentsChanged` -> `rebuildOverlays(at:)` (ContentView.swift:2978) -> `ParkingRulesEngine.currentState` -> `nextRestriction` -> `computeHoursUntilASP` -> `ASPSuspensionService.isSuspended` -> `Date.toETDateString()` (Services/Date+ET.swift:58), which allocates a new `DateFormatter` on every call.
  - What: fresh-erased sim, install, launch: springboard until ~8 s, then the WHOLE window is pure black (no toolbar, banner or overlays, so not just missing base tiles) from ~15 s to >30 s, content by ~60 s (cold-15s.png vs cold-90s.png). Warm relaunch: black through at least 20 s, content by ~23-25 s. A `sample` of the process at ~5 s shows the main thread inside `rebuildOverlays` for 89 of 92 samples, 51 of them in `DateFormatter` creation inside `isSuspended`. MapKit was not the blocker.
  - Caveat: Debug build (unoptimized, `WePark.debug.dylib`) and the Mac was at load average 100-500 from other agents, so absolute times are inflated. Release timing not measured. The PR's own first-launch-1.png actually shows overlays rendered over a black map, which is a different state from what I reproduced.
  - Expected: overlay classification must not block the main thread for tens of seconds; a cached `DateFormatter` (or ET calendar day components) in `toETDateString`, plus off-main classification, would fix it.
  - Pre-existing, unrelated to #193's diff. Not a merge blocker for this PR; file as a follow-up.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit
- **#2:** On a no-data curb, park-confirm and My Car still show "Remind me before parking changes" (default on) plus 15 min / 1 hr offsets. No reminder can ever fire (restriction is always active), so the toggle promises something that won't happen. Consider hiding it when `hasNoSignData`. Owner: `@ios-engineer`
- **#3:** `DriveModeBottomCard.swift:336` has a literal "No parking" but only inside `#Preview`; not user-facing.

### Out of scope
- The 4 superseded-only ASP/NO_STANDING rules attached to the NO DATA segments are intentionally hidden from the UI; fine, but they are also dropped from Plan-a-Trip detail text.

## Smoke tests run
- `xcodebuild build-for-testing` (own DerivedData in ~/Library/Caches, deleted afterward): succeeded.
- Full WeParkTests via xcresult: **2954 passed, 0 failed, 1 skipped (2955 total)**. All 8 NoSignDataTests pass; the 3 amended tests pass.
- Fresh-erased sim, simulated location at Broadway/W 125th: found `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1` by projecting its coordinates to screen. Tap output (AXe): "Broadway - East side between Tiemann Pl and W 125th St / We don't know / No sign data / Read the posted signs on this curb before you park. / The only sign on file here was replaced, and we don't have the new one." No No Parking badge, no rule rows. Neighboring Broadway segments correctly still say "No standing" with their real sign row (no regression to real signs).
- Park-confirm: "No sign data" + "Read the posted signs..." Parked-car detail / My Car: same block, no sign list.
- Park Until "Tonight" confirmed (clock turns green); map lines remain red/green per classification, and the no-data curb stays red. Not separately run for A-few-hours / Park & Forget live; covered by shared `isFree` code path and tests.
- Metered (yellow) and ASP curbs are visibly unchanged on the map; I did not open their detail sheets live (their code is untouched by the diff; 2954 tests pass).
- Mount-chain live smoke: toolbar buttons, ASP banner, search bar, Report/help render once the stall clears.
- Sim shut down; DerivedData and the copied Config.xcconfig deleted.

## What's working
- Single shared signal (`hasNoSignData`) feeding every surface; copy centralized in `NoSignData`.
- Conservative: red on the map, not-free everywhere, never mislabeled as a posted sign.
- Tests assert both directions (a real "NO PARKING ANYTIME" still says "No parking"; an UNKNOWN real sign is not no-data).

## Evidence
`docs/qa/assets/pr193/`: `blockdetail-nodata.png`, `park-confirm-nodata.png`, `parked-car-detail-nodata.png`, `goal-tonight.png`, `goal-park-until-confirmed.png`, `cold-15s.png` (all-black at 15 s), `cold-90s.png`.

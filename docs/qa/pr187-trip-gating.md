# PR #187 QA: trip mode live gating (Spot Pass, Report pill, deep link, AX date)

**Reviewed:** branch `fix/trip-mode-live-gating-2`, against `docs/qa/pr185-goals-trip-followups.md` (follow-ups #1, #2, minors)
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
Build is clean (local `xcodebuild build`, iOS 26.5 sim; CI `Build and XCTest` green). Spot Pass and Report More rows are verified hidden during a trip in the live app. The AX5 banner fix does NOT work: the time still splits ("10:00 / AM") at AX5. The push and parked-car deep-link paths could not be exercised live (no notification banner in sim); code read looks correct.

## Claims
- [x] 1. Spot Pass / Your Spot Pass hidden during a trip. Live: More with no trip shows Report + Spot Pass (04-more-live.png); More with trip active shows only colors / Parking 101 / sign details / Plan a trip / Settings (07-more-trip.png). Report row also hidden.
- [~] 2. Report pill hidden + handler guarded. Code correct (`communityMapFloatingChromeVisible(tripActive:)`, guard + toast in `handleReportPillTap`). Live: see "Flag combos" below. Handler guard not live-exercised (unreachable once the pill is hidden).
- [ ] 3. AX5 banner no mid-time wrap. FAILED, finding #1.
- [~] 4. Parked-car notification deep link. Not verified live (needs a parked car with matching id plus a tappable notification banner; none appeared). Code read: `exitTripPlan(toast:)` runs after the `parkedCar.id == carID` guard and before camera recenter / detail open. OK.
- [~] 5. Spot Pass push opened exits trip before cover. Not verified live: `simctl push` (category `wepark_spot_pass_seeker`, kind `armed`) produced no banner (notification permission could not be granted via simctl privacy: "Operation not permitted"), so no tap was possible. Code read: `exitTripPlan` precedes `showSpotPassCover = true`, after the store guard. OK.

## Flag combos (live)
Flags flipped locally only: planTrip, spotHandoff, spotHandoffAutoDetect, curbPin, addressAnchored ON; driveModeDefault toggled.
- planTrip ON, driveModeDefault OFF (01-launch.png): legacy chrome, Report pill + "?" + recenter + Park Until render, layout intact. Plan a trip is only reachable from the More sheet, which exists only when driveModeDefault is ON (`recenterButtonStack`), so a trip cannot start in this combo. The PR test-plan item "planTrip on, driveModeDefault off: no Report pill in trip mode" is therefore vacuous: the pill gate is defense in depth, not observable.
- planTrip ON, driveModeDefault ON (03, 06, 07): ambient chrome (Search, More, Start Driving, goal pill), no floating Report pill (already hidden by drive mode). Trip banner (06-trip-active.png) renders with Edit / Exit trip plan; no overlap.
- planTrip OFF regression: NOT run (would need another rebuild; disk ~4.7 GB). All new gates key off `tripPlan != nil`, which is unreachable with the flag off, so no behavior change expected. Not verified.

## Findings

### Significant
- **#1: AX5 trip banner still splits mid-time**
  - Where: `TripPlanning.displayWindowLabel` / `TripPlannerSheet.swift:211`
  - What: at accessibility-extra-extra-extra-large the banner renders "Sat 11/28 10:00" then "AM" on the next line (08-ax5-banner.png). Text does contain U+00A0 (confirmed via accessibility label), but each stamp ("Sat 11/28 10:00 AM") as one unbreakable run is wider than the line, so SwiftUI force-breaks inside it. This is the same symptom ("8:28 / PM") as follow-up in PR #185. The CI unit test only checks the string, not layout.
  - Expected: no split between time and AM/PM at AX5.
  - Suggested: NBSP only between time and AM/PM; ordinary spaces between weekday, date and time so the line can wrap there.
  - Owner: `@ios-engineer`

### Minor
- **#2:** PR test-plan item for planTrip ON / driveModeDefault OFF cannot be exercised (see above); drop or reword.

### Not verified
Items 4 and 5 live, planTrip OFF regression, toast "Trip plan closed" appearance. Recommend Kevin tap a real Spot Pass alert and parked-car reminder on device with a trip active.

## Smoke tests run
- `xcodebuild build` (sim, CODE_SIGNING_ALLOWED=NO): BUILD SUCCEEDED, twice (flag combos).
- `gh pr checks 187`: Build and XCTest pass.
- Live screenshots read: 01, 03, 04, 06, 07, 08, 10 (assets/pr187/). 10-push-banner.png shows no banner after `simctl push`.

## What's working
Row gating is clean and tested by truth tables; banner and More sheet layout are intact with trip active; live-wins ordering is placed correctly in both handlers.

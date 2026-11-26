# PR #199 QA: design system Phase 2b (curb sheet, search, drag-to-park) — 2026-11-25

**Reviewed:** branch `feat/ds-phase2b-curb-search-park` at `4736c32c`, against `docs/design/wepark-design-system-v0.1/DECISIONS.md` (accuracy adjustments 1-6).
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The accuracy rules hold in code: every green gate goes through `WPCurbVerdict.isParkable`, unclear and no-data curbs can never reach `park` or the primary "Park here", and no flag-off path changed. No blockers. Follow-ups are copy and consistency issues, plus one undercount case in the free-curb count. Live flag-on sim screenshots were not re-taken (Mac overload); I relied on code reading, the 20 new unit tests, and the builder's screenshots.

## Acceptance checks
- [x] 1. Count: `WPFreeCurbCounter.count` uses `isParkable` (rejects no-data, UNKNOWN, metered via strict meter rule, anytime/restricted). Radius 160 m, coverage probe 400 m, returns nil (card hidden) when no loaded segment is within 400 m. Outside Manhattan shows "Not covered yet", no count. See finding 1 for the partial-tile caveat.
- [x] 2. `.unclear` / `.nodata` / plan variants: `offersPrimaryPark` is false; CTA is the flat outline "Park here anyway". Unclear copy is "Check the posted sign"; never names a restriction. A known active restriction correctly still names itself.
- [x] 3. `WPNeighborVerdict.apply` only lowers `greenRank` (to `.dont`); swept/confirm notes are informational. See finding 3 for surface inconsistency.
- [x] 4. `WPOpenSpotGate.filter` drops open-spot pins unless `isParkable` for the window; pins with an unloaded segment are dropped. Applied via `v2MapCommunityPins` (flag-gated).
- [x] 5. Arrow signs read "Arrow sign. Applies near the corner. Check the sign on the street." Grep for "first 20", "past it" in views/logic: only in comments.
- [x] 6. Times use `ParkingRulesEngine` labels; `midnightized` rewrites "12:00 AM" to "midnight"; `WPGoalCopy.clock` already does. No "12 AM" literals.
- [~] 7. Drag-to-park snaps via existing `CurbSnapIndex` (40 m acquire), warns (haptic, "Park here anyway", warning text) on non-park curbs; no snap means the token returns home. `soon` judgment in finding 4.
- [x] 8. Flag OFF: every new branch is behind `AppConstants.designSystemV2Enabled` (ContentView sheet routing, search, park layer, callout, pin filter, zoom-scale rescale, car-pin view, hit-test widening). `carCalloutText` defaults nil; `v2ParkFlow` idle. The one unguarded edit is `&& v2ParkFlow.phase == .idle && !Self.v2ShowcaseActive` on dock visibility: idle is always true flag off and `v2ShowcaseActive` is false unless the DEBUG launch arg is set, so no behavior change.
- [x] 9. `WPPhase2bShowcase.swift` is wholly inside `#if DEBUG` (lines 18-175); the ContentView use is under `#if DEBUG`, and `v2ShowcaseActive` has a Release `false` branch. Release build of WePark succeeded and the binary contains no `wp2bShowcase` string.

## Findings

### Blocking
None.

### Significant
- **#1: Free-curb count can undercount (false "No free curbs") when tiles are only partly loaded.** `WPCurbSheetLogic.swift` `WPFreeCurbCounter.count`. The coverage probe is "any segment within 400 m" but the count radius is 160 m. If only an adjacent tile has loaded, the card can show a low number or "No free curbs within 2 blocks" plus a "nearest" line: a false statement, though not a fake spot. Expected: hide unless coverage is plausible around the count radius (it already recomputes as `segments.count` changes). Owner: `@ios-engineer`.

### Minor
- **#2: Drag bubble reads "Free until 7+ days"** for a curb with no restriction in 7 days (`WPDragBubble.make`, `.park` case uses `model.big`). The car callout (`ContentView.swift` `v2CarCalloutText`) does the same. Should read "Free for 7+ days". Owner: `@ios-engineer`.
- **#3: Drag flow and car callout skip `WPNeighborVerdict.apply`** (only `v2CurbSheetContent` applies it). A curb with an active filming/construction report shows "Park" while dragging but "don't" in the curb sheet. Not greener than the signs, so rule 3 holds, but the surfaces disagree. Owner: `@ios-engineer`.
- **#4: `soon` curb keeps amber block plus yellow raised "Park here"** (`WPCurbSheetV2.parkButton`, `WPParkConfirmCard.actions`, via `offersPrimaryPark`). Parking is legal right now and the block states the restriction time, so it is not a fake spot, but a raised yellow primary on an amber curb reads as an endorsement when the window is not covered. Recommend following mock B6.5 (outline) when a goal window is active and the restriction lands inside it. Owner: `@ios-engineer` / design call.
- **#5: Curb sheet with no goal window** shows green `park` ("Free to stay until ...") from engine state only; a metered curb off meter hours reads park while the map's strict meter rule could color it differently. Not verified on device; check consistency with base-map color.

### Out of scope
- `-wp2bShowcase` screenshots are builder-only; not re-run.

## Build and tests
- Builds: WePark (Debug and Release), WeParkClip, ClipLiveActivities, WeParkLiveActivities all BUILD SUCCEEDED (serial, `-jobs 4`).
- Full WePark suite: first run (parallel clones) reached 3012 passes, then the Mac overloaded (xcodebuild "server died") and 5 tests failed from load/crash: `FT15Channel3RequestTests.testChannel3Request_apikeyHeaderPresent`, `ParkingAddressCoordinatorTests.testMovingToAnotherBlock_clearsTheStaleAddressImmediately`, `CommunityPinServiceRequestTests.testBuildRequest_apiKeyHeader_present`, `DesignSystemGallerySnapshotTests.testRenderGallerySections`, `MapViewRepresentableZoneBoundaryTests...nilHomeZone...`; the run did not complete cleanly. Serial rerun (parallel off) of those suites plus `W7ToastServiceTests`, `SpotPassCountdownTests` and all 20 `Phase2bCurbSearchParkTests`: 59 tests, 0 failures, 1 skipped.
- `W7ToastServiceTests` passed on the serial rerun on the PR branch, so the builder's single failure is a load-sensitive timing flake (350 ms sleep), not a PR regression. I did not run it on `origin/main` (load constraints); the file is not touched by this diff.
- Compile-failure classes: none hit in new code.

## What's working
Single green gate reused everywhere, strong unit coverage of the product rules (never-greener, open-spot gate, unclear never primary), disciplined flag gating, DEBUG aid fully compiled out of Release.

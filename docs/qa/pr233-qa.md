# PR #233 (R35-3 Locate zoom 0.008) QA - 2026-11-28

**Reviewed:** `ios/r35-3-locate-zoom` at `09184b52`, against `docs/specs/r35-map-polish-and-trip-destination.md` (PR3) and field log R35-3.
**Verdict:** PASS with follow-ups (no blocking findings; one unverified-on-device item).

## Summary
Small, correct change: `AmbientDrivingLook.span(for:cruiseSpan:stoop:)` returns 0.008 / 0.012 when the Stoop flag is on and the old values when off; `applyAmbientDrivingLook` passes `AppConstants.designSystemV2Enabled`. Drive Mode never goes through this function (its 0.003 reads `driveModeCameraSpan` directly at ContentView lines ~6362 and ~8620), so it is unchanged. Full suite is green on an erased sim and Locate/search framing looks right in a live flag-on build.

## Acceptance criteria
- [x] Stoop spans 0.008 / 0.012, tight < wide, inside `fullMaxDelta` - unit tests plus code read.
- [x] Flag off byte-identical - `span(... stoop:false)` delegates to the old function; test asserts 0.003/0.006.
- [x] Drive Mode unchanged - `driveModeCameraSpan` still 0.003, not touched; only `applyAmbientDrivingLook` uses the new spans.
- [x] Locate in Midtown shows about 2-3 blocks with readable curbs - live, `docs/qa/pr233-assets/midtown-launch.png` (launch tight step at 34th St; about 3 cross streets tall, dashed red and solid green clearly legible).
- [x] Locate on the LES - live, `les-launch.png` (about 6 streets tall incl. Orchard/Ludlow/Essex/Norfolk/Suffolk, readable curbs, street labels visible).
- [x] Search result frames at the same span - live, `penn-search-frame.png` (Penn Station from the LES, same zoom). Note this PR alone still has the build-35 sheet gap, which is PR #231's job.
- [x] Parked car and trip framing use the same funnel (`recenterMap` -> `applyAmbientDrivingLook`, step `.tight`) - code read only, not exercised live (no parked car).
- [x] No fight with free-drag reveal: `v2RevealPendingCar` uses `panToCenter` (pan only, keeps zoom), and does not touch `applyAmbientDrivingLook`. Code read.
- [x] No fight with Recenter: Recenter goes through the same `applyAmbientDrivingLook`, which resets `ambientLookUserAdjusted`; `shouldTighten` still works since 0.008 < 0.012. Code read.
- [ ] Poor-GPS cold launch opens at 0.012 then tightens to 0.008 - NOT verified live (the sim fix is always good). Logic read only; see finding 1.

## Findings
### Blocking
None.

### Significant
None.

### Minor
- **#1 (unverified): the wide span sits exactly on the full-band edge.** `stoopWideSpan` (0.012) equals `WPCurbZoomConstants.fullMaxDelta`; the check is `<=`. The camera is set by altitude (`altitudeForSpan`), so the latitudeDelta MapKit reports can differ slightly from 0.012. On a poor-fix cold launch it could land just over and show green-only until the good fix tightens it. Short lived and only in the poor-GPS case. Recommend a quick look on a device with Wi-Fi-only/indoor launch. Owner `@ios-engineer`.
- **#2: Locate after a pan was not driven live.** My simulated swipe did not register, so "pan away, then Locate" was verified by code only (same funnel as above). Low risk.

### Out of scope
- The tests assert the pure function only; nothing asserts that `recenterMap` passes `stoop:` through. A flag-on wiring test would catch a regression.

## Smoke tests run
- Full `WeParkTests`, shipped flags, freshly erased `wepark-qa231-sim`, `-parallel-testing-enabled NO -jobs 4`: 3,452 tests, 0 failures, 1 skipped (the pre-existing skip).
- Dry-run merges (real `git merge --no-commit`, aborted, nothing pushed): PR is already up to date with `origin/main` (which includes #228/#229); clean with #231 and with #232's branch (`ios/f1-trip-destination`). Combined result was not compiled.
- Live, with `StoopFlag.designSystemV2Enabled`, `driveModeDefaultEnabled` flipped locally (reverted, not committed), light mode, iPhone 17 Pro iOS 26.5: Midtown launch, LES launch, Penn Station search framing, all screenshot-inspected. AX5 was run for the PR #231 sheet, not repeated here (this PR does not change layout).
- Mount-chain files (`MapViewRepresentable`, `ContentView` overlay attachment) are not touched beyond one call-site hunk; overlay layer, toolbar, banner, dock and polylines all rendered in the live app.

## What's working
- Tight spans: curbs are easy to read at 0.008 with #227's thinner lines; this is a clear improvement over the building-level shot in Kevin's screenshot.
- Minimal, well-scoped diff; flag-off path delegates to the original function.

## Kevin on device
1. Midtown and the LES: tap Locate. You should see your block plus 2-3 streets each way and about 1.5 avenues, with curbs readable. If it feels too wide or tight, the single constant is `AmbientDrivingLook.stoopTightSpan`.
2. Pan away, then Locate or Recenter: it should come back to the same zoom.
3. Cold launch indoors / poor GPS: it should open a little wider, then tighten when the fix improves, with red and green both visible.
4. Search a place, park a car and tap the parked-car recenter: same zoom each time. Start Drive Mode: unchanged close zoom.

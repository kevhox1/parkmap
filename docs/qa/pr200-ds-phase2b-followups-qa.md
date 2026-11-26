# PR #200 QA: Phase 2b follow-ups (flag on only) — 2026-11-26

**Reviewed:** branch `fix/ds-phase2b-followups` at `5315063e`, against `docs/qa/pr199-ds-phase2b-qa.md`.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
All five PR #199 findings are fixed in code and covered by new tests. Flag-off behavior is unchanged: no engine file is touched, and the only shared-code changes (`WPCurbVerdict.currentState`, `WPFreeCurbCounter`) are reached only behind `designSystemV2Enabled`. One significant copy bug in a rare new fallback (`.soon` "Meter on this curb" reads "Free until Meter on this curb" on two surfaces). Everything else is minor. Live flag-on sim screenshots were not taken (Mac load 100+ from a parallel build); verification is code reading plus the unit suite.

## Checks
- [x] 1. Free-curb count. `WPTileCoverage.covers` uses `TileLoader.tileKeys(buffer: 0)` over the circle's bounding box (lat/lng deltas, cos-lat corrected), so every EXISTING tile under the 160 m radius must be in `loadedTileKeys`, else `count` returns nil (card hidden). Boundary math is floor-based over the box, so a circle straddling a tile edge needs both tiles; a circle crossing 4 tiles needs 4. No existing tile under the box means not covered (nil). A tile that exists but failed to load or was evicted is absent from `loadedTileKeys`, so it hides rather than undercounts. "Nearest" is dropped unless the 400 m box is also loaded (`nearestCovered`). Count "0" is only reachable with the 160 m area fully loaded, so "No free curbs" is a true statement. Residual: the destination must be inside the loaded viewport+2 tile buffer, otherwise hidden (conservative). Not hit: `CountKey` uses `loadedTiles.count`, so a swap of loaded tiles with the same count and same `segments.count` would not retrigger a recompute (very unlikely, see finding 3).
- [x] 2. Wording. `freeLine` ("Free for 7+ days" when `isOpenEnded`) is used by the drag bubble and car callout. Grep of app code finds no "until \(…7+…)" phrasing; neighbor sign line also uses `isOpenEnded`. Exception: finding 1.
- [x] 3. `WPNeighborVerdict.resolve` (sign verdict then `apply`) is the only path in `v2CurbSheetContent`, `WPParkFlowController.update/placeAt` (via `reports` closure through `resolveContext`) and `v2CarCalloutText`. `apply` only changes a variant with `greenRank > 0` to `.dont`; plan variants untouched; Plan a Trip passes no reports. Never greener. Test `testThreeSurfaces_agree_onAnActiveFilmingReport` covers it. Note: the car callout now passes `v2WindowEnd` (was nil), see finding 2.
- [x] 4. Metered fix. `nextRestriction` is unchanged; `WPCurbCopy.nextMeterStart` scans `currentState == .meteredActive` in 15 min steps with a 1 min refine over 7 days. Sheet `park` requires `!legalButNotGreen`: with a window that is `isParkable` (same gate as the map's window mode); with no window it requires no meter rule at all. `currentState` (no goal) turns `.freeComfortably` plus a meter rule into `.freeButRestrictionSoon` (amber), matching the sheet's `.soon`. Window modes: map and sheet both call `isParkable`, so they agree; a meter fully outside the window gives park with "then the meter" (nextChange honest); a meter inside gives soon/amber. `testSheetPark_alwaysImpliesMapGreen_forEveryWindow` and `testMeteredCurb_offMeterHours_...` cover it. Engine files unchanged; engine tests are in the full suite and pass.
- [x] 5. Flag OFF. `currentState` swap is already gated in `ContentView` (lines 3055, 3075 use `engine.currentState` when flag off). `TileLoader.loadedTileKeys` is an extra Set built per rebuild (negligible, additive, no behavior change). `tileCoverage`, `resolve`, `reports` are used only from v2 views. No flag-off logic diff.

## Findings

### Blocking
None.

### Significant
- **#1: `.soon` fallback reads "Free until Meter on this curb".** `WPCurbSheetLogic.swift:241` (new fallback for a metered curb with no meter start found in 7 days) sets `big: "Meter on this curb"`, but the shared surfaces assume `big` is a time: drag bubble headline `WPCurbSheetLogic.swift:736` ("Free until Meter on this curb"), car callout via `calloutText` (`freeLine`, "Free until Meter on this curb"), and `apply`'s sign line ("free until Meter on this curb") when a neighbor report applies. Not a fake spot (it is amber, not green), but a garbled and imprecise statement about parking. Trigger is rare (meter rule exists, state free, no `.meteredActive` in 7 days, e.g. meter windows shorter than 15 min or all-days-excluded rules). Fix: give the fallback its own handling in bubble/callout/apply (e.g. "Meter on this curb" headline). Owner: `@ios-engineer`.

### Minor
- **#2: Car callout now uses the goal window** (`ContentView.swift:4305`, `windowEnd: v2WindowEnd`; was nil). The saved car is judged against a search window that may not be the car's. It is stricter only (never greener), but the text may say "Free until X" where X is the first restriction rather than the window. Consider nil as before. Owner: `@ios-engineer`.
- **#3: Search count recompute key** `CountKey.loadedTiles` is a count, not the set (`WPSearchV2.swift` task id). Equal-count tile swaps would not recompute. Use a hash of the set. Owner: `@ios-engineer`.
- **#4: `nextMeterStart` 15 min step** (`WPCurbSheetLogic.swift:280`) misses a meter window shorter than 15 min, and is O(672) engine calls per metered curb per resolve (drag updates only on segment change, so fine in practice). Owner: `@ios-engineer`.

### Out of scope
- #199 findings 4 (`soon` yellow primary CTA) and 5 are design calls; finding 5 is now resolved by the map/sheet agreement above.

## Smoke tests run
- WePark build-for-testing: BUILD SUCCEEDED. WeParkClip, ClipLiveActivities, WeParkLiveActivities: BUILD SUCCEEDED (own DerivedData, own sim).
- Full WePark suite, `-parallel-testing-enabled NO -jobs 4`: Executed 3024 tests, 1 skipped, 0 failures (includes 7 new Phase2b tests). No known flakes hit.
- Compile-failure classes: none seen in new code (builds clean, `nonisolated` on new statics).
- Live flag-on UI screenshots: not run (load). Not verified on device.

## What's working
One verdict function across surfaces, tile-coverage gating that fails closed (hidden, never a low number), meter handling that keeps the sheet and the map on the same `isParkable` gate, and no engine edits.

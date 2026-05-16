# Viewport Polish QA Pass 1 — 2026-05-16

**Reviewed:** branch `viewport-polish/wide-zoom-and-auto-center` at `289f4ab`, against
`docs/viewport-polish-spec.md` (status: "Spec locked, amended 2026-05-16").
**Base:** `main` at `ff6efad`.
**Files changed:** 3 (2 modified, 1 new)
- `ios/WePark/WePark/ContentView.swift` (modified)
- `ios/WePark/WePark/Services/Constants.swift` (modified)
- `ios/WePark/WeParkTests/ViewportPolishTests.swift` (new)

**Verdict: SHIP WITH CAVEATS**

---

## Summary

The core implementation is correct and complete. Part A (threshold `0.1 → 0.04`) and Part B
(launch auto-center with three-priority decision) are both faithfully implemented per the spec.
The `isInManhattanCoverage` bounding-box bounds match `tiles/index.json` exactly. The two-flag
design (`recenterOnUserRequested` vs `recenterOnUserAtLaunch`) is correctly wired and the W5.1
"Find me" button regression check passes in code review. Three caveats prevent a clean ship:
(1) the engineer's claimed test count of 12 new tests (79 → 91 total) does not match the 13
test methods I count in `ViewportPolishTests.swift` — the actual total is likely 92, not 91;
(2) the `xcodebuild test` run could not be independently verified because the Bash tool was
denied in this QA session; and (3) a stale ContentView.swift header comment still references
the old `0.1` threshold. None of these affect runtime behavior.

---

## Acceptance Criteria Checklist

| AC | Description | Result | How Verified |
|---|---|---|---|
| AC-A1 | `polylineHideSpanThreshold` is `0.04` in ContentView.swift | PASS | Read `ContentView.swift:206` — `private let polylineHideSpanThreshold: Double = 0.04` |
| AC-A2 | At span ≤ 0.04, overlays render normally | PASS | `rebuildOverlays` guard at line 595: `guard region.span.latitudeDelta <= polylineHideSpanThreshold` — passes when span is 0.0036 (post-auto-center) |
| AC-A3 | Default launch span 0.07 → overlays hidden | PASS | `0.07 <= 0.04` is false → guard fails → empty OverlayPayload returned; launch region is `latitudeDelta: 0.07` per `ContentView.swift:130` |
| AC-A4 | Zoom-in to 0.03 → overlays re-render | PASS | Guard passes at 0.03 ≤ 0.04; code path verified in `rebuildOverlays`; driven by `.onChange(of: tileLoader.segments.count)` |
| AC-A5 | Threshold transition clean (no per-frame flicker) | NOT VERIFIED | Requires simulator run — clean by design (overlays rebuild on region-change event, not per-frame) |
| AC-A6 / AC-B9 | Unit tests pass | NOT INDEPENDENTLY VERIFIED | Bash denied; xcodebuild could not be run. See Finding #1. |
| AC-B1 | No auth → stays on manhattanCenter, no location dialog | PASS (code) | `.task` block: `if let carID = pendingID … else if locationService.isAuthorized` — entire Part B skipped when `isAuthorized == false`. `requestWhenInUseAuthorization()` not called. |
| AC-B2 | Authorized + cached in-coverage fix → snaps in <200ms | PASS (code) | Priority 2a branch at `ContentView.swift:331-337`: reads `locationService.userLocation`, checks `isInManhattanCoverage`, calls `recenterMap(on: cachedLoc)` synchronously inside `.task`. Sets `recenterOnUserAtLaunch = true` for refresh. |
| AC-B3 | Authorized + no cached fix → defer via requestAndFetchLocation | PASS (code) | Priority 2b branch at `ContentView.swift:339-343`: `recenterOnUserAtLaunch = true` + `locationService.requestAndFetchLocation()`. `.onChange(of: locationUpdateCount)` fires on fix arrival, coverage-checked. |
| AC-B4 | Deep-link + resolvable car → camera on parkedCar, sheet presents | PASS (code) | Priority 1 branch at lines 323-329: guards on `pendingID != nil && car.id == carID`, calls `recenterMap(on: car.coordinate)`. No coverage check applied. Sheet routing is unchanged W6.1 path. |
| AC-B5 | Out-of-coverage user → stays on manhattanCenter | PASS (code + tests) | Hoboken and Yonkers test cases in `ViewportPolishTests.swift`. Priority 2a else-branch (line 338): `// cached fix outside coverage → Priority 3 (manhattanCenter stays)`. |
| AC-B6 | Cached-then-fresh refresh → re-snaps on locationUpdateCount | PASS (code) | Priority 2a sets `recenterOnUserAtLaunch = true`. `.onChange(of: locationUpdateCount)` at lines 409-420 checks flag, applies coverage check, recenters, clears flag. |
| AC-B-DL1 | Deep-link with out-of-coverage parked car → centers on parked car | PASS (code) | Priority 1 bypasses `isInManhattanCoverage` — recenters on `parkedCar.coordinate` unconditionally. Correct. |
| AC-B-DL2 | Deep-link + pin cleared → falls through to Priority 2/3 | PASS (code) | Priority 1 guard: `let car = parkPinService.parkedCar` fails if no pin → falls through to `else if locationService.isAuthorized` chain. W6.1 sheet-routing guard independently prevents sheet. |
| AC-B-DL3 | Sheet dismiss → camera holds, no second auto-center | PASS (code) | `recenterOnUserAtLaunch` is cleared after the first fix fires. No re-snap on sheet dismiss. No second camera snap path exists. |
| AC-B7 (W5.1 regression) | "Find me" button still works at any zoom, no coverage check | PASS (code) | `recenterOnUser()` at lines 689-700 calls `recenterMap` on cached fix immediately (no coverage check) OR sets `recenterOnUserRequested`. `.onChange` handler acts on `recenterOnUserRequested` unconditionally. |

---

## Engineer's Three Self-Flagged Findings

**Self-flagged #1: Roosevelt Island (40.762, -73.953) inside bounds → auto-centers there.**

Assessment: Correctly characterized as non-blocking. Spec §5 explicitly lists Roosevelt Island
among the areas the tile grid covers and accepts ("Roosevelt Island, Marble Hill, and the sliver
of the Bronx/Queens that touch the tile grid edge — all of which is fine to auto-center on").
The unit test `testCoverage_rooseveltIsland_isInside` confirms the behavior is intentional.
Verdict: non-blocker, no action needed.

**Self-flagged #2: Hoboken Pier A (~40.738, -74.019) is 0.001° inside lngMin boundary (-74.020).**

Assessment: Genuine edge case, correctly characterized as narrow enough to defer. At -74.019
longitude, Pier A is approximately 75m east of the lngMin boundary — a waterfront pier
projecting from NJ into the Hudson River. Street parkers in Hoboken are located further west
(typical Hoboken parking streets are -74.027 to -74.035), well outside the tile grid boundary.
The scenario where a real user is at exactly Pier A is extremely rare. The confusing UX
(auto-center to Pier A with no overlays) is real but the exposure is minimal. Engineer's
follow-up filing is appropriate. Verdict: non-blocker, appropriate deferral.

**Self-flagged #3: Dual-flag race — both `recenterOnUserRequested` and `recenterOnUserAtLaunch` true simultaneously.**

Assessment: Correctly characterized as idempotent. Traced through `.onChange(of: locationUpdateCount)` at lines 409-421: the handler uses two independent `if` blocks (not `else if`), so if both flags are true and the user is in-coverage, `recenterMap` is called twice with the same coordinate and span. SwiftUI batches synchronous state updates in the same render cycle — one animation fires. If user is out-of-coverage: `recenterOnUserRequested` fires unconditionally (correct — "Find me" button has no coverage restriction), `recenterOnUserAtLaunch` checks coverage and skips. Both flags are cleared. No crash, no double-animation, no stuck state. Verdict: non-blocker, correctly characterized.

Note: the spec §8 edge case table says "recenters once if in coverage, clears both flags." The code may fire `recenterMap` twice in the in-coverage case (both `if` blocks execute), but the result is correct — both calls use the same coordinate, final state is correct, no visual artifact. Minor spec/code prose discrepancy only.

---

## Findings

### Blocking

None.

### Significant

**#1: Test count discrepancy — header claims 12 new tests, I count 13; xcodebuild not independently verified.**

- Where: `ViewportPolishTests.swift` line 20 (file header); engineer's PR commit message and claimed total `79 → 91`.
- What: The file header says "Test count added by this file: 12" and lists "IsInManhattanCoverageInsideTests (7)". I count 8 distinct test methods in `IsInManhattanCoverageInsideTests` (including `testCoverage_exactBoundaryLatMax_isInside` at line 94, which is in the class but not reflected in the "(7)" count). 8 inside + 5 outside = 13 test methods total. If correct, the actual post-PR total is 92, not 91.
- Expected: Header, PR description, and xcodebuild output should all agree on the test count.
- Impact: If xcodebuild actually reports 91 (not 92), one of the 13 test methods may be silently not collected (e.g., naming issue or compilation guard). If it reports 92, the header is a harmless off-by-one. Either way the discrepancy needs explanation.
- Bash tool was denied in this QA session — xcodebuild could not be run to independently verify the count or confirm 91/0 vs 92/0 pass result.
- Repro: Run `xcodebuild test -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and compare reported count to 91 vs 92.
- Owner: `@ios-engineer` to confirm. If 92, update the header comment. If 91, investigate which test method is not being collected.

### Minor / Nit

**#2: Stale ContentView.swift file header — references old `polylineHideSpanThreshold = 0.1`.**

- Where: `ContentView.swift` line 25.
- What: The file header comment block (unchanged since W4) reads `//    - Kept: polylineHideSpanThreshold = 0.1 (zoom gating — hides overlays when zoomed out)`. The actual constant at line 206 is `0.04`. The W4-era header was not updated.
- Expected: Line 25 should read `polylineHideSpanThreshold = 0.04` or a note that it was lowered.
- Impact: Documentation only. Future readers of the header may expect the threshold to be 0.1 and be confused.
- Owner: `@ios-engineer`

**#3: Test coverage gap — no explicit boundary tests for lngMin (-74.020) or lngMax (-73.907) exact boundaries.**

- Where: `ViewportPolishTests.swift` — `IsInManhattanCoverageInsideTests` / `IsInManhattanCoverageOutsideTests`.
- What: The test suite covers exact-boundary inclusivity for `latMin` (both the inclusive case at `40.700` and the exclusive case at `40.700 - 0.000001`). It does NOT have equivalent tests for `lngMin: -74.020` or `lngMax: -73.907` exact boundaries. Given the Hoboken Pier A finding (#SF2 above) where the lngMin boundary is the critical dimension, an explicit lngMin boundary test would be reassuring.
- Expected: At minimum, a `testCoverage_exactBoundaryLngMin_isInside` at longitude -74.020 and a `testCoverage_justWestOfLngMin_isOutside` at longitude -74.020 - epsilon.
- Impact: Trivially testable (same four-comparison function). No production bug — the function is three lines and correct. Coverage gap only.
- Owner: `@ios-engineer`

**#4: `Constants.swift` is `Services/Constants.swift` — spec file table says `ios/WePark/WePark/Constants.swift`.**

- Where: `docs/viewport-polish-spec.md` §3, file table.
- What: The spec says the file is at `ios/WePark/WePark/Constants.swift`; the actual file is `ios/WePark/WePark/Services/Constants.swift`.
- Impact: Docs-only discrepancy. No correctness issue. Future readers of the spec may look in the wrong directory.
- Owner: `@ios-engineer` or tech-lead to update the spec path.

### Out of Scope (Logged, Not Fixed)

- **Dynamic tile loading on pan** — correct post-W8 architectural fix for LRU patchwork. Explicitly deferred per spec §9.
- **`maxCachedTiles` increase** — memory tradeoff needs real-device measurement post-W8. Explicitly deferred.
- **lngMax boundary (Flushing, -73.907)** — no user parking east of Flushing Meadows in normal WePark usage. Low-priority gap.

---

## Smoke Tests Run

1. **Spec read:** `docs/viewport-polish-spec.md` read in full. Status line confirms "Spec locked, amended 2026-05-16" with OD-1 and OD-2 resolved. Matches PR claims.

2. **`tiles/index.json` bounds verification:** Read `tiles/index.json` lines 1-14. `latMin: 40.7`, `latMax: 40.882`, `lngMin: -74.02`, `lngMax: -73.907`. Match `Constants.swift` exactly (40.700 = 40.7, -74.020 = -74.02 with trailing zero — same value).

3. **`Constants.swift` diff read:** `Services/Constants.swift` read in full. `manhattanCoverageBounds` tuple added with correct values. `isInManhattanCoverage(_:)` function uses `>=` and `<=` for all four comparisons (inclusive). No `Calendar.current`. Spec formula matches implementation.

4. **`ContentView.swift` Part A verification:** `polylineHideSpanThreshold` at line 206 is `0.04`. `rebuildOverlays` guard at line 595 uses `<= polylineHideSpanThreshold`. Default launch region `latitudeDelta: 0.07` verified at line 130. `0.07 <= 0.04` is false → launch shows clean basemap. Correct.

5. **`ContentView.swift` Part B priority logic trace:** `.task` block at lines 292-348 read in full. Priority order: (1) deep-link with matching car → `recenterMap` on car coordinate, no coverage check; (2a) authorized + cached in-coverage → immediate `recenterMap` + set flag; (2b) authorized + no cached + no pending deep-link → set flag + `requestAndFetchLocation`; (3) fallback → no action. Matches spec §5 priority ordering exactly.

6. **`.onChange(of: locationUpdateCount)` handler trace:** Lines 409-421 read. Two independent `if` blocks for `recenterOnUserRequested` (W5.1, unconditional) and `recenterOnUserAtLaunch` (new, coverage-checked). Both flags cleared after acting. W5.1 recenter button regression check: `recenterOnUserRequested` path has no `isInManhattanCoverage` call — correct.

7. **`recenterMap` span verification:** `MKCoordinateRegion(center:latitudinalMeters: 400, longitudinalMeters: 400)` at line 713. At Manhattan latitude ~40.75, 400m N-S ≈ 0.0036° latitudeDelta. `0.0036 <= 0.04` → overlays render after auto-center. Correct per spec math in §4.

8. **W7 invariants check:** Single `.sheet(item: $activeSheet, ...)` at line 470 — no new sheet modifiers. `ToastService.swift`, `NotificationScheduler.swift`, `ParkConfirmView.swift`, `ParkedCar.swift` not modified by this PR. `notifyOnRestriction` toggle flow intact.

9. **`Calendar.current` grep (manual):** Read `Constants.swift` (no Calendar import), `ContentView.swift` new additions (no Calendar usage), `ViewportPolishTests.swift` (imports XCTest + CoreLocation only). No `Calendar.current` in new code.

10. **`ViewportPolishTests.swift` read:** All 13 test methods read. Logic of each test case verified against `isInManhattanCoverage` implementation. Roosevelt Island inside test: `(40.7620, -73.9530)` → lat in [40.700, 40.882] yes, lon in [-74.020, -73.907] yes → true. Correct. Hoboken outside test: `(40.7440, -74.0324)` → lon -74.0324 < -74.020 → false. Correct. latMin exact boundary: `(40.700, -73.970)` → lat 40.700 >= 40.700 → true (inclusive). Correct.

11. **xcodebuild test:** NOT RUN. Bash tool denied in this QA session. Test count and pass/fail cannot be independently confirmed. This is the most significant gap in this QA pass.

12. **`routePendingDeepLink` idempotency check (W6.1 regression):** Function at lines 863-870 unchanged from W6.1. Clears `pendingDeepLinkCarID = nil` before routing. Two onChange paths (scenePhase + pendingDeepLinkCarID value) both call `routePendingDeepLink` — no change in this PR.

---

## What's Working

- **Implementation is spec-faithful.** The three-priority decision tree in `.task` exactly matches the spec §5 pseudocode ordering. No priority reordering, no missing branches.

- **Bounding box constants verified against source.** `latMin 40.700 / latMax 40.882 / lngMin -74.020 / lngMax -73.907` in `Constants.swift` match `tiles/index.json` exactly. No manual derivation — pulled directly from the tile pipeline output.

- **Coverage check is minimal and correct.** `isInManhattanCoverage` is a four-comparison bounding box. No haversine, no polygon math, no external dependency. Implements the OD-2 resolution correctly.

- **W5.1 "Find me" regression is clean.** The two-flag design correctly isolates launch auto-center from the existing "Find me" button. `recenterOnUserRequested` path has no coverage check (correct — button is unconditional). `recenterOnUserAtLaunch` path applies coverage check (correct — launch is automatic).

- **Deep-link Priority 1 correctly bypasses coverage check.** Parked car coordinate is auto-centered even if outside tile bounds. This is the right call — the user explicitly parked there.

- **`recenterMap` span (400m) is always below the 0.04 threshold.** After any auto-center, `latitudeDelta ≈ 0.0036 <= 0.04` → `rebuildOverlays` renders overlays immediately. The spec's "overlays visible after auto-center" requirement is structurally guaranteed.

- **New test file is well-structured.** Two XCTestCase classes with clear MARK comments, meaningful test names, and accurate assertions. The boundary inclusivity tests for latMin/latMax are particularly good. The comments correctly attribute spec references (e.g., `// spec §5` for Roosevelt Island).

- **No scope creep.** This PR does not touch `LocationService.swift`, `TileLoader.swift`, `MapViewRepresentable.swift`, any Model files, `WeParkApp.swift`, or any W6/W7 service files. Scope is surgical.

---

## Manual Smoke Checklist (for Kevin before merge)

| Scenario | Steps | Expected | Notes |
|---|---|---|---|
| AC-A3: Wide zoom → clean basemap | Cold launch simulator. Observe initial state. | Map shows clean Apple Maps with NO colored polylines (default span 0.07 > 0.04 threshold) | The original bug scenario — should be visually clean |
| AC-A2 + AC-SMOKE: Auto-center → overlays visible | Cold launch, authorized, with Manhattan location set. | Camera snaps to neighborhood, colored polylines cover visible streets | Combine test with AC-B2 |
| AC-A4: Zoom-in → overlays re-render | From wide zoom (0.07), pinch in to street level (~0.03). | Colored polylines appear as you cross the 0.04 threshold | Watch for the snap |
| AC-B1: No auth → manhattanCenter | Reset simulator location permission. Cold launch. | No permission dialog, map stays at Manhattan overview. | Critical — must not prompt at launch |
| AC-B2: Authorized + cached fix | Set simulator location to 40.750, -73.985 (Midtown). Grant permission in prior session. Cold launch. | Camera snaps to Midtown in <200ms, overlays render | Verify span is street-level |
| AC-B3: Authorized + no cached fix | Reset simulator location to None. Grant permission in Settings app. Cold launch. | Map initially on manhattanCenter, then snaps to location when fix arrives | Timing may be slow in simulator |
| AC-B4: Deep-link cold-kill | Park car. Force-quit. Tap notification. | `ParkedCarDetailView` presents AND map centers on parked car block | Verify map behind sheet shows correct block, not wide Manhattan |
| AC-B5: Hoboken → stays on Manhattan | Set simulator location to 40.7440, -74.0324. Cold launch with authorization. | Camera stays on manhattanCenter (no auto-center). | Confirm lon -74.032 correctly excluded |
| AC-B7 regression: Find-me button | After auto-center to location, tap Find-me button. | Button still works; camera moves to current location. | Any zoom level, regardless of coverage |
| Test suite | Run `xcodebuild test -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | All tests pass; note the actual count (91 or 92 — see Finding #1). | REQUIRED before merge — QA session could not independently verify |

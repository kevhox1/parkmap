# Tier 3 Sub-PR #2 (Universal Community Reporting) QA Pass 1 — 2026-06-06

**Reviewed:** branch `ios/tier3-universal-report` at `78582f7`, against `docs/tier3-patrol-report-spec.md` (AC-R1–R40) and `docs/design/tier3-marker-icons.md`
**Verdict:** PASS-WITH-NITS (ship with minor caveats)

---

## Summary

The PR correctly implements both universal reporting entry paths (resting long-press confirmationDialog + in-drive Report button), the shared ReportSheet with correct type-to-meta mapping, the timeSinceBadge pure function, DriveModeStyle.patrol removal, and the correct SF Symbol / color assignments from the designer's note. Build is clean, 351 tests pass with 0 failures, RegionSyncGuardTests 2/2 pass, and no #31-class overlay regression is visible in the live-app smoke screenshot. Two non-blocking findings: a misleading stale comment in ReportSheet.swift's file header (marker icon fallback claim that no longer reflects the code), and a primary row label deviation from AC-R13 ("Street sweeper" vs. spec's "Sweeper passed"). Both are nit-level; neither affects runtime behavior.

---

## Acceptance criteria checklist

- [x] AC-R1 — `handleLongPress` sets `showRestingActionMenu = true` when `driveModeActive == false`. Verified by code review: `ContentView.swift:1848–1857` guard `!driveModeActive`, then sets `pendingLongPressCoord` + `showRestingActionMenu = true`.
- [x] AC-R2 — "Park my car here" builds PinDropIntent from the long-press coordinate. Verified by code review of the `Button("Park my car here")` handler at `ContentView.swift:506–527` which calls `findCandidateSegments(lat: coord.latitude, lng: coord.longitude, ...)` and constructs the intent from `pendingLongPressCoord`.
- [x] AC-R3 — "Report enforcement or sweeper" sets `ActiveSheet.reportPin(coord: pendingLongPressCoord)`. Verified by code review at `ContentView.swift:532–537`.
- [x] AC-R4 — Cancel clears `pendingLongPressCoord` and leaves `activeSheet` nil. Verified by code review at `ContentView.swift:539–541`.
- [x] AC-R5 — `driveModeActive == true` long-press is a no-op. Verified: `handleLongPress` has `guard !driveModeActive else { return }` as its first statement. Tests pass for this path.
- [x] AC-R6 — W5 ParkConfirmView behavior functionally unchanged; candidate detection logic moved verbatim into the "Park my car here" action handler. Verified by diff: the `findCandidateSegments` + `PinDropIntent` construction is identical to the prior implementation, just relocated.
- [x] AC-R7 — Report button (`flag.fill`, orange) is in `driveModeOverlayLayer`. Verified by code review at `ContentView.swift:1282–1309`. The button is unconditional within `driveModeOverlayLayer`, which is gated by `if driveModeActive` at the call site (`ContentView.swift:949`).
- [x] AC-R8 — In-drive Report tap uses `locationService.userLocation` coordinate. Verified: `guard let loc = locationService.userLocation else { return }; activeSheet = .reportPin(coord: loc)`. `locationService.userLocation` is `CLLocationCoordinate2D?`, so `loc` is already the coordinate type.
- [x] AC-R9 — Report button not rendered when `driveModeActive == false`. Verified: `driveModeOverlayLayer` is only rendered when `driveModeActive == true` (`ContentView.swift:949`).
- [x] AC-R10 — Button present in both `.destination` and `.cruise` styles; no `driveModeStyle` gate on the button. Verified by code review: the button has no style-specific conditional inside `driveModeOverlayLayer`.
- [x] AC-R11 — Silent no-op when `userLocation == nil`. Verified: the `guard let loc` at the call site returns early without touching `activeSheet`.
- [x] AC-R12 — End pill label is `driveModeStyle == .cruise ? "End Cruise" : "End Drive"`. No "End Patrol" path. Verified at `ContentView.swift:1253`.
- [x] AC-R13 — Two primary type rows present. PARTIAL: "Enforcement active" label is correct. Second row uses "Street sweeper" instead of spec's "Sweeper passed." See Finding #1 (nit).
- [x] AC-R14 — Sub_tag picker row appears when enforcement active is selected; four options in correct order: Cleaning truck, Parking agent, Tow truck, Not sure. Default nil. Verified by code review at `ReportSheet.swift:257–278`.
- [x] AC-R15 — "Sweeper approaching" sets `direction = "coming_soon"` in the payload. Verified: `SweeperDirection.approaching.directionRawValue == "coming_soon"` and `buildMeta` uses `sweeperDirection.directionRawValue`. Test `testBuildMeta_sweeper_approaching_directionIsComingSoon` passes.
- [x] AC-R16 — Report CTA disabled when `selectedType == nil`, enabled on any selection, not gated by sub_tag. Verified: `isEnabled(selectedType:isSubmitting:)` static function + 3 tests in `ReportSheetEnabledTests`.
- [x] AC-R17 — No "avoid", "ticket", "fine", "evasion", "dodge" in `ReportSheet.swift`. Verified by grep: zero matches on production code text.
- [x] AC-R18 — Enforcement active + Cleaning truck maps to `["sub_tag": "cleaning_truck"]`. Verified: `EnforcementActiveMeta.SubTag.cleaningTruck.rawValue == "cleaning_truck"`. Test `testBuildMeta_enforcementActive_cleaningTruck_hasSubTag` passes.
- [x] AC-R19 — In-drive path uses GPS coordinate. Verified by code review (same `guard let loc = locationService.userLocation` path).
- [x] AC-R20 — "Sweeper passed" maps to `direction: "passed"`. Test `testBuildMeta_sweeper_passed_directionIsPassed` passes.
- [x] AC-R21 — "Sweeper approaching" maps to `direction: "coming_soon"`. Test `testBuildMeta_sweeper_approaching_directionIsComingSoon` passes.
- [x] AC-R22 — Report CTA disabled while `isSubmitting == true`. Verified: `isEnabled(selectedType:isSubmitting:)` returns `false` when `isSubmitting == true`. `ProgressView` renders in CTA body when `isSubmitting`. Test `testIsEnabled_enforcementSelected_isSubmitting_isFalse` passes.
- [x] AC-R23 — On success: sheet dismisses via `onDismiss()`. On error: `submitError` set, sheet stays open. Verified by code review of `submitReport()` async function.
- [ ] AC-R24 — End-to-end Realtime delivery within 5 seconds. Not verified — requires two live clients with Supabase credentials. Cannot exercise in sandbox.
- [x] AC-R25 — `timeSinceBadge` returns "Just now" for age < 60s. Tests `testTimeSinceBadge_under60s_returnsJustNow`, `testTimeSinceBadge_exactlyZero_returnsJustNow`, `testTimeSinceBadge_59s_returnsJustNow` all pass.
- [x] AC-R26 — `timeSinceBadge` returns "5m ago" at 300s. Test `testTimeSinceBadge_5min_returns5mAgo` passes.
- [x] AC-R27 — `timeSinceBadge` returns "1h ago" at 3600s. Test `testTimeSinceBadge_60min_returns1hAgo` passes.
- [x] AC-R28 — No `Calendar.current` or `Calendar.easternTime` in `timeSinceBadge`. Verified by grep: `timeSinceBadge` uses only `timeIntervalSince` arithmetic. Test `testTimeSinceBadge_isCalendarIndependent` passes.
- [ ] AC-R29 — Tap enforcement_active pin → PinDetailSheet with ReactionsRow. Not verified — no live crowd pins in DB; cannot exercise tap-to-detail flow in sandbox. Architecture is unchanged from sub-PR #1; code-verified the `mapView(_:didSelect:)` → `CommunityPinAnnotation` → `ActiveSheet.pinDetail` path is intact.
- [x] AC-R30 — `DriveModeStyle.patrol` case does not exist. Verified: `grep -rn "case patrol" ios/WePark/WePark/` returns zero results.
- [x] AC-R31 — No stale `.patrol` references. Verified: `grep -rn "\.patrol" ios/WePark/WePark/` returns zero production-code hits (one comment-only hit: "REMOVED" doc note).
- [x] AC-R32 — End pill ternary produces correct labels for `.inactive`, `.destination`, `.cruise`. No "End Patrol" path. Verified at `ContentView.swift:1253`.
- [x] AC-R33 — No new `setRegion` calls in the diff. Verified: `MapViewRepresentable.swift` is not in the diff; `setRegion` exists in that file only (pre-existing, gated by `shouldSyncRegionToBinding`). RegionSyncGuardTests 2/2 pass.
- [x] AC-R34 — No mutation of UIKit state inside `updateUIView` beyond the pre-existing `syncCommunityPinAnnotations` (add/remove only, no camera). `ReportSheet.swift` and the ContentView changes don't touch `MapViewRepresentable.updateUIView`. Verified by code review.
- [x] AC-R35 — No `headlessWindow` in new or modified production code. Verified: `grep -rn "headlessWindow" ios/WePark/WePark/` returns zero hits in the PR's touched files; the only match is a comment in `PinDetailSheet.swift` (unchanged pre-existing note).
- [x] AC-R36 — `CommunityPin.swift` NOT modified. Verified: not in `git diff main --name-only`.
- [x] AC-R37 — `CruiseVoicePolicy.swift`, `DrivingContextService.swift`, `FinalApproachService.swift` NOT modified. Verified by diff.
- [x] AC-R38 — `driveEntryButton` Menu has exactly two items: "Drive to a destination" and "Find Parking nearby". Verified at `ContentView.swift:1200–1220`.
- [x] AC-R39 — Live-UI smoke: screenshot `/tmp/qa-tier3-pr40-smoke.png` taken and read. Confirms: (a) ASP banner renders at top (green "ASP in Effect Today"), (b) toolbar cluster (gear, find-me, find-car, clock, drive-entry) fully visible, (c) no overlay elements dropped, (d) DriveModeBottomCard NOT visible in idle state, (e) parking polylines render correctly. #31-class regression absent.
- [ ] AC-R40 — In-drive Report button visible with driveModeActive == true. Cannot verify via simctl (no tap injection to enter Cruise/Drive Mode). Code-verified: button is present unconditionally in `driveModeOverlayLayer`, which is guarded by `if driveModeActive`. Not fabricated.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / nit

**#1: AC-R13 label deviation — "Street sweeper" vs. spec's "Sweeper passed"**

- Where: `ReportSheet.swift:133`
- What: The second primary type row label reads "Street sweeper" with sublabel "Sweeping truck on or near this block." The spec AC-R13 says the row should be labeled "Sweeper passed."
- Expected (per spec): Row label = "Sweeper passed"
- Observed: Row label = "Street sweeper" (direction deferred to the sub-picker showing "Sweeper passed" / "Sweeper approaching")
- Note: The engineer's choice has UX merit — the primary row can't truthfully say "Sweeper passed" if the user hasn't yet chosen a direction. However, it deviates from the literal AC. If Kevin accepts the reasoning (neutral primary label + direction sub-picker), update AC-R13 to reflect as-shipped. If not, rename the row.
- Owner: `@ios-engineer` (code change) or `@tech-lead` (spec amendment to match the rationale)

**#2: Stale file header comment in ReportSheet.swift**

- Where: `ReportSheet.swift:21–25`
- What: File header still reads "enforcement_active: shield.fill (blue) — placeholder" and "sweeper_passed: exclamationmark.triangle.fill (orange) — placeholder. truck.box.fill is not available pre-iOS 18." These were from the initial commit before commit `faa6883` updated `PinMarkerAnnotation.swift` with the correct symbols. The comment also incorrectly claims marker icons live in `ReportSheet.swift` — they do not; they live in `PinMarkerAnnotation.swift`.
- Expected: Comment either removed (marker icons are not a ReportSheet concern) or updated to say "see PinMarkerAnnotation.markerStyle(for:) — updated to person.badge.clock.fill / truck.box.fill per tier3-marker-icons.md"
- Owner: `@ios-engineer`

**#3: ReportSheetTests.swift baseline comment is stale**

- Where: `ReportSheetTests.swift:40–41`
- What: Comment reads "Baseline before this suite: 258 tests. After: 258 + 20 = 278 tests." Actual baseline before this PR was 331 (sub-PR #1 shipped 331/0 per HANDOFF.md). Actual total is 351 (331 + 20 = 351). The arithmetic is correct (20 new tests), only the baseline number is wrong.
- Owner: `@ios-engineer`

### Out of scope (logged, not fixed)

- **Sweeper direction opacity differentiation** (design doc §3 "coming_soon" at 70% opacity): the design note explicitly defers this to sub-PR #3 ("When sub-PR #3 implements opacity fade..."). Not a finding for this PR; recorded here for sub-PR #3 scoping.
- **AC-R24 end-to-end Realtime delivery** and **AC-R29 tap-to-PinDetailSheet**: cannot be mechanically verified without live Supabase crowd pins and tap-injection capability. Architectural path is unchanged from sub-PR #1 (which was QA'd). Owner: Kevin's manual smoke.
- **AC-R40 in-drive Report button visual**: cannot enter Drive Mode headlessly. Code-verified the button renders correctly per the `driveModeActive` guard. Owner: Kevin's next Drive Mode smoke.

---

## Smoke tests run

1. **Build** — `xcodebuild ... build` — PASSED (exit 0). No warnings about undefined symbols, missing resources, or type errors.
2. **Full test suite** — `xcodebuild ... test` — 351 tests, 0 failures. Confirmed by counting "Test case '...' passed" lines across two independent runs.
3. **RegionSyncGuardTests** — both `testRegionSync_driveModeActive_returnsFalse` and `testRegionSync_driveModeInactive_returnsTrue` PASSED.
4. **ReportSheetMetaTests** (8 tests) — all PASSED. Spot-checked: `testBuildMeta_enforcementActive_cleaningTruck_hasSubTag` asserts `meta?["sub_tag"] == "cleaning_truck"`. `testBuildMeta_sweeper_approaching_directionIsComingSoon` asserts `meta?["direction"] == "coming_soon"`.
5. **TimeSinceBadgeTests** (9 tests) — all PASSED. Confirmed pure arithmetic, no Calendar dependency.
6. **ReportSheetEnabledTests** (3 tests) — all PASSED.
7. **Live-UI smoke** — Simulator F0820726-15F4-4FA3-8602-A5D7B479A277 (iPhone 17 Pro), screenshot at `/tmp/qa-tier3-pr40-smoke.png`, read via Read tool. Confirms: ASP banner present, toolbar cluster (5 buttons) fully rendered, parking polylines visible, no drive overlay in idle state. #31-class regression absent.
8. **Secrets check** — `grep -r "pk.eyJ" ios/` returns zero results. No Mapbox token committed.
9. **Patrol removal** — `grep -rn "case patrol\|\.patrol" ios/WePark/WePark/` returns zero production-code hits. Exhaustive switch compiles cleanly.
10. **Calendar.current check** — `grep "Calendar.current" PinMarkerAnnotation.swift` and `ReportSheet.swift` return zero hits in production code bodies.
11. **headlessWindow check** — zero hits in touched files.

---

## What's working

- The universal-reporting architecture is clean and correctly replaces the patrol-mode design. The `confirmationDialog` approach for resting users is the right call — large tap targets, native appearance, no fragile UIViewRepresentable gesture overlay.
- The `buildMeta` static pure function design is good engineering: it decouples the meta construction from SwiftUI `@State` and makes it trivially testable without constructing a view.
- `DriveModeStyle.patrol` removal is complete and compile-verified (exhaustive switch catches any stale reference at build time).
- The fix commit (`78582f7`) correctly resolves the SweeperPassedMeta.Direction comparison bug from the initial implementation (which used string comparison `m.direction == "coming_soon"` instead of the enum case `.comingSoon`). The current code uses `m.direction == .comingSoon` — correct.
- Icon assignments match the design doc precisely: `person.badge.clock.fill` / `systemTeal` for enforcement, `truck.box.fill` / `systemCyan` for sweeper. The design doc's prohibition on `shield.fill` fallback is respected, and the "truck.box.fill is iOS 17+" claim in the design doc is honored (both symbols are SF Symbols 5 / iOS 17 minimum).
- The `timeSinceBadge` pure function is exactly per spec §5: injects `now: Date`, uses only `timeIntervalSince` arithmetic, no calendar, correct boundaries at 60s / 60min / 120min.
- The Report button in `driveModeOverlayLayer` correctly adds the "Report" caption2 text label per the designer's refinement in `tier3-marker-icons.md §4`. This is an improvement over the spec sketch.
- No new `setRegion` calls, no `headlessWindow` guard, no mutation in `updateUIView`, `MapViewRepresentable.swift` untouched — all architecture invariants from prior PRs preserved.

# TF2-7: Simplified Cruise Guidance + Sign-Check Confirmation QA Pass 1 — 2026-06-11

**Reviewed:** branch `ios/tf2-7-cruise-guidance` at `e4d1dcc`, against `docs/tf2-7-cruise-guidance-spec.md`
**Verdict:** PASS-WITH-NOTES

## Summary

The core implementation is sound: `aggregateSide` is a correct pure-function implementing the spec §3.5 algorithm, all copy strings match the spec character-for-character, the sign-check sheet is static and pass-through with correct wiring, `ParkConfirmView` is untouched, and the test suite runs 504/0. Two items require attention before merging. First, the heading=0 (due north) tie-break is a real production defect that mislabels one side as `.unknown` when driving due north or due south — it is pre-existing in main and was not introduced by TF2-7, but the engineer's own test comments document it explicitly, making this the right moment to classify it and decide disposition. Second, the test `testDestinationMode_restrictedBlock_stillSpeaks` has an inverted name (it now asserts silence, not speech) — minor but a maintenance trap. Kevin's manual smoke (items TF2-7.20–TF2-7.22) remains required before closing.

---

## Acceptance criteria checklist

- [x] **TF2-7.1** `aggregateSide` with a free segment >= 6m returns `.free` — verified by test `testAggregateSide_singleFreeSegmentLong_returnsFree` (A-1) and code review of the short-circuit path.
- [x] **TF2-7.2** `aggregateSide` with a free segment < 6m and no other free segment returns `.restricted` — verified by test A-2, A-9, and code review confirming `.free` segments below threshold fall through to `hasMetered` check then `.restricted`.
- [x] **TF2-7.3** `aggregateSide` with mixed free+restricted where free >= 6m returns `.free` — verified by test A-3.
- [x] **TF2-7.4** `aggregateSide` with no segments for the given side returns `.unknown` — verified by test A-6 and the `guard !sideSegments.isEmpty` early return.
- [x] **TF2-7.5** `aggregateSide` with only metered segments returns `.metered` — verified by test A-4 (with injected timeRanges to force `.metered` severity at test date — see Finding #2).
- [x] **TF2-7.6** Left side `.free` → `CruiseVoicePolicy.utteranceText` contains `"sections on the left"` and `"check signs"` — verified by code inspection of `CruiseVoicePolicy.utteranceText` lines 126-128 and tests B-1, CruiseVoicePolicyTests.swift test #8, #11.
- [x] **TF2-7.7** Right side `.free` → contains `"sections on the right"` and `"check signs"` — verified by tests B-2 and CruiseVoicePolicyTests #11.
- [x] **TF2-7.8** Both sides `.free` → contains `"both sides"` and `"check signs"` — verified by tests B-3 and CruiseVoicePolicyTests #9.
- [x] **TF2-7.9** Neither side `.free`, left `.metered` → contains `"Metered on the left."`, not `"sections"` or `"check signs"` — verified by CruiseVoicePolicyTests #13 and `utteranceText` `else if leftMetered` branch.
- [x] **TF2-7.10** `buildUtteranceText` (destination mode) produces same catch-all templates as `CruiseVoicePolicy.utteranceText` for equivalent inputs — verified by tests C-1, C-2, and W85cTests updated tests 9 and 10.
- [x] **TF2-7.11** Destination mode, both sides `.restricted` → produces `"No parking on either side."` — verified by test `testDestinationMode_bothRestricted_speaks` and `buildUtteranceText` line 367.
- [x] **TF2-7.12** "Park here" button visible whenever `driveModeActive == true` — verified by code inspection of `driveModeOverlayLayer` in `ContentView.swift` at line ~1384; button is inside the `if driveModeActive` block with no additional conditions.
- [x] **TF2-7.13** Tapping "Park here" with `locationService.userLocation == nil` is a no-op — verified by `guard let loc = locationService.userLocation else { return }` at line ~1388.
- [x] **TF2-7.14** Tapping "Park here" with `activeSheet != nil` is a no-op — verified by `guard activeSheet == nil else { return }` at line ~1387.
- [x] **TF2-7.15** `SignCheckConfirmView` presents exactly 5 checklist items matching §5.2 text — verified by code inspection of `SignCheckConfirmView.swift` lines 69-98; all 5 text strings match spec verbatim.
- [x] **TF2-7.16** Sheet title `"Check before you park"`, subtitle `"Take 10 seconds — the signs are the final word."` — verified by lines 135 and 61 of `SignCheckConfirmView.swift`.
- [x] **TF2-7.17** "I checked — Park here" dismisses `SignCheckConfirmView` and opens `ParkConfirmView` with same `PinDropIntent` — verified by `onConfirm: { confirmedIntent in activeSheet = .parkConfirm(confirmedIntent) }` in `ContentView.swift` sheetContent switch.
- [x] **TF2-7.18** Cancel or swipe-down dismisses without presenting `ParkConfirmView` — verified by `onCancel: { activeSheet = nil }` in sheetContent and `confirmed` state tracking in `SignCheckConfirmView.onDisappear`.
- [x] **TF2-7.19** W8.5d arrival prompt path (`ActiveSheet.arrivalPrompt`) does NOT present `SignCheckConfirmView` — verified: `ArrivalPromptSheet.swift` has zero diff in this PR; the arrival confirm closure in `ContentView` calls `parkPinService.save(car)` + `endDriveMode()` + `activeSheet = .parkUntil` — no `signCheckConfirm` in that path.
- [ ] **TF2-7.20** Simulator screenshot (resting state): toolbar layer intact — NOT VERIFIED. Sandbox blocked `/tmp` screenshots from the `Read` tool. Test suite passed 504/0 and no `MapViewRepresentable.swift` was touched, but the live-UI smoke is mandatory for `ContentView.swift` changes per post-W8.5c-polish-revert hard gate. Kevin must take this screenshot.
- [ ] **TF2-7.21** Simulator screenshot (driveModeActive): "End Drive" pill, "Park here" button, Report button, ASP banner all visible — NOT VERIFIED for same reason. Kevin's manual smoke is the gate here per the spec §6.4.
- [ ] **TF2-7.22** Kevin's manual smoke (on-device): all four sub-checks — DEFERRED to Kevin. Sandbox cannot drive the multi-tap Drive Mode flow.
- [x] **TF2-7.23** All existing ACs pass; `xcodebuild test` exits 0 with 504 tests. No new `Calendar.current`. No `import SwiftUI` in service files — verified: `Calendar.current` grep returns nothing in changed files; `CruiseVoicePolicy.swift` and `DrivingContextService.swift` have only `import Foundation` / `import CoreLocation`.

---

## Findings

### Significant

**#1: Heading=0 (due north/south) tie-break produces `.unknown` right side in production**

- Where: `DrivingContextService.swift` `sideRelativeToHeading(heading:side:)` via the side-classification loop in `update()`, lines 240-246.
- What: When `heading == 0.0` exactly, both N and S cardinal sides produce `dLeft == dRight == 90`, so `sideRelativeToHeading` returns "left" for both. The loop assigns N to `leftCardinalSide` (first match) and silently drops S because the `else if` branch only fires for "right". Result: `rightCardinalSide` stays `nil`, `rightOpp` is forced to `.unknown`, and the right chip shows "—" regardless of actual parking conditions. The same happens at heading ≈ 180 (due south): E and W both resolve `dLeft == dRight == 90` and both map to "right" (E takes it, W is dropped), leaving `leftCardinalSide == nil`. When driving due south, the left chip shows "—".
- Severity: Significant, not Blocking. The defect existed on main before TF2-7 (same loop logic with `leftSeg`/`rightSeg` instead of `leftCardinalSide`/`rightCardinalSide`). TF2-7 did not introduce it. However, the engineer's own test comment in `DrivingContextServiceCruiseModeTests.swift` explicitly documents the tie-break and worked around it with heading=90. This makes it visible and logworthy. The real-world frequency is low (driving at exactly 0° or 180° heading is an edge, not a normal state), and the EMA stabilizer prevents instantaneous snaps to exactly 0.
- Expected per spec: §3.4 and §3.6 expect left/right sides to be correctly classified relative to travel direction. A driver heading due north on a two-way street (e.g., 5th Ave) would see the right chip show "—" even when there is valid data for the right (south) side.
- Repro: Drive due north on a block with parking data on both N and S sides. The right-side chip will show "—" rather than the actual south-side classification.
- Owner: `@ios-engineer`. Fix: when `dLeft == dRight` (exact tie), prefer the cardinal side that is to the RIGHT of the heading direction (i.e., add a tiebreaker: if dLeft==dRight, the side whose bearing == rightBearing maps to "right"). This makes heading=0 produce N→left, S→right correctly. Alternatively, the fix is a single comparison change from `<=` to `<` on the "left" arm: `if which == "left" && leftCardinalSide == nil` plus a final `else` that treats unresolved sides as "right".
- Note: This is pre-existing. If Kevin is comfortable deferring to a follow-up PR rather than holding TF2-7, that is reasonable. The defect only manifests at exactly heading≈0° or 180°, and the EMA makes exact-0 rare in practice.

### Minor / Nit

**#2: Test name `testDestinationMode_restrictedBlock_stillSpeaks` now asserts silence**

- Where: `DrivingContextServiceCruiseModeTests.swift` line 138.
- What: The test name says "stillSpeaks" but the assertion is `speakCallCount == 0` (silence). This is correct behavior per TF2-7 §4.3 (one-restricted + one-unknown is silent), but the name is now a maintenance trap — a future engineer reading "stillSpeaks" and the assertion `== 0` will be confused.
- Expected: Test name should reflect actual behavior, e.g., `testDestinationMode_oneRestrictedOneUnknown_isSilent`.
- Owner: `@ios-engineer`. Rename only — no behavior change.

**#3: Test A-8 boundary assertion is slightly indirect**

- Where: `TF27Tests.swift` lines 207-225.
- What: To test the inclusive 6m boundary, the test reads back `segmentLengthMeters(seg)` and injects it as `minimumFreeLength`. The comment explains this is because `tf27MakeSeg(lengthMeters: 6.0)` produces ~5.97m by haversine (cosine approximation rounding). The test works and the mechanism is sound, but the fixture helper's `±2%` accuracy warning is slightly loose — if a future platform change widens the error, `length < 5.85` assertion could mask a broken fixture. Not actionable for TF2-7 but worth noting.
- Owner: `@ios-engineer`. No action needed for this PR.

---

### Engineer test fixes — assessment

Three test changes the engineer listed:

1. **Metered timeRanges injection (A-4):** Legitimate. Without time ranges, a metered segment during off-peak hours returns severity `.free` (free until 9am). The injection forces `.metered` severity at 8am test date. This is correct test design that accurately exercises the `aggregateSide` metered path. Not masking.

2. **Heading=90 for side separation (test 4b):** Legitimate workaround for the heading=0 tie-break (Finding #1 above). The test comment is explicit and accurate. The workaround correctly isolates the both-restricted announcement path. The underlying production issue is filed as Finding #1.

3. **6m boundary via injected length (A-8):** Legitimate floating-point precision workaround. The `segmentLengthMeters` helper is exposed as `internal` specifically for this use, which is clean.

---

## Smoke tests run

1. `xcodebuild test` on the TF2-7 worktree (`e4d1dcc`) against simulator `F0820726-15F4-4FA3-8602-A5D7B479A277`: **504 passed, 0 failed** (verified via `grep -c "passed on"` and `grep -c "failed on"`).
2. Code inspection of all spec copy strings against `SignCheckConfirmView.swift` string literals — exact match on all 5 checklist items, title, subtitle, and CTA.
3. Code inspection of `CruiseVoicePolicy.utteranceText` against §4.1 table — exact match.
4. Code inspection of `DrivingContextService.buildUtteranceText` against §4.1 table — exact match including the destination-mode-only "No parking on either side." branch.
5. `aggregateSide` algorithm traced against spec §3.5 steps 1-6 — correct, including the step-3 short-circuit and step-5 fallback to `.restricted`.
6. `SafetyLabel(for: SideOpportunity)` bridge verified against spec §3.2 chip text labels.
7. `ActiveSheet.signCheckConfirm` `id` value — `"signCheckConfirm-\(intent.id)"` matches spec §5.3.
8. `ParkConfirmView.swift` diff against `main..e4d1dcc` = 0 lines changed. Confirmed untouched.
9. `ArrivalPromptSheet.swift` diff = 0 lines. No `signCheckConfirm` reference.
10. `MapViewRepresentable.swift` diff = 0 lines. No #31 regression risk from this PR.
11. `project.pbxproj`, `Info.plist`, `Config.xcconfig*` — none appear in the commit stat. Confirmed.
12. No `Calendar.current` in any new or modified service file. No `import SwiftUI` in service files. `SignCheckConfirmView.swift` correctly omits `import MapKit` and `import CoreLocation`.
13. `aggregateSide` declared `static` with no `@Observable` or `@MainActor` — pure function contract upheld.
14. Heading=0 tie-break math traced by hand: N and S both produce `dLeft == dRight == 90`, both return "left", right side gets `nil`. Confirmed production defect (pre-existing, classified as Significant/non-blocking, logged as Finding #1).
15. FT-9 metered-active regression check: `aggregateSide` switch handles `.metered` with `hasMetered = true`; short-circuit only fires on `.free`. A metered-active segment (severity `.metered`) cannot be classified `.free` by `aggregateSide`. No regression.
16. OQ-1 (always shown): no `UserDefaults` key read or written in `SignCheckConfirmView.swift`. No dismiss flag anywhere in the sign-check path.
17. Live-UI screenshot: **NOT VERIFIED** — sandbox blocked `/tmp` screenshots from `Read`. This is a mandatory pre-merge gate per spec §6.4 and the post-W8.5c-polish-revert rule. Kevin must confirm.

---

## What's working

- The `aggregateSide` pure function is clean, well-commented, and correctly implements all 6 steps of the spec §3.5 algorithm. The injectable `minimumFreeLength` parameter makes it trivially testable at any threshold.
- Copy strings across `CruiseVoicePolicy.utteranceText` and `buildUtteranceText` are byte-identical to spec §4.1 for all cases covered. The "sections" + "check signs" phrasing is consistent between Cruise and Destination modes.
- `SignCheckConfirmView` is a model static-content sheet: no MapKit, no CoreLocation, no service dependencies. The `confirmed` state flag cleanly distinguishes swipe-to-dismiss from explicit cancel without needing `interactiveDismissDisabled`.
- The `activeSheet == nil` guard on the "Park here" button is the correct pattern (same as the Report button). No race condition with the arrival prompt — both guards are synchronous on the main thread.
- `ParkConfirmView` is provably untouched (zero diff lines).
- The `SideOpportunity → SafetyLabel` bridge extension is placed correctly in `SafetyLabel.swift` without disturbing the compiler-synthesized `init(text:severity:)`.
- Test count: 504/0 — net +24 from baseline 480. All three categories (aggregation, copy strings, sheet wiring) are covered. The `SafetyLabel(for:)` bridge tests (D-1 through D-4) are a bonus not in the spec inventory.
- Architecture invariants upheld: `.onChange`-driven only, no mutation in `updateUIView`, no `setRegion` in drive-active path.

---

*QA Pass 1 — 2026-06-11. Reviewer: @qa-verifier. Did not build this feature. Pre-merge gate: Kevin must (a) take simulator screenshot confirming overlay layer intact and (b) confirm "Park here" button visible in Drive Mode and (c) confirm sign-check sheet presents with all 5 items before this PR is closed. Finding #1 (heading tie-break) is pre-existing and non-blocking but should be triaged for a follow-up PR.*

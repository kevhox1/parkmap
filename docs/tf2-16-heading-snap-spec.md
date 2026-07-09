# TF2-16: Drive Mode Heading Snap-to-Street at Low Speed

**Feature:** Stop the heading arrow/camera from spinning and hunting near intersections at low speed, by snapping to the matched street's known travel bearing when GPS course confidence is low.
**Owner:** @ios-engineer (after Kevin approves this spec); @qa-verifier per pass; Kevin's on-device drive-test is the final gate.
**Created:** 2026-07-09
**Status:** SPEC — awaiting Kevin review before engineering starts (all open questions below are resolved with a recommendation; nothing is strictly blocking, but this is the #31-sensitive camera path so Kevin should skim before code starts).

---

## Decisions Kevin Needs Before Engineering Starts

All open questions below are **resolved with a recommendation** — engineering can start on the recommended defaults. Flag here only because this touches the #31-sensitive camera/heading path and Kevin may want to weigh in before a worktree opens.

**OQ-1 (non-blocking): Drop the "raw-course-vs-EMA disagreement" signal from the low-confidence trigger.**
Kevin's diagnosis lists three low-confidence signals: slow speed, poor course accuracy, and high disagreement between raw course and the EMA. This spec uses only the first two (speed + `CLLocation.courseAccuracy`). Reason: a large course/EMA disagreement is also the literal signature of the car actually executing a turn — using it as a "low confidence → snap" trigger risks holding the snapped heading through the turn itself, which is exactly the failure mode item #6 asks us to avoid. Speed and course accuracy already degrade together at a stopped/slow intersection approach (the reported scenario), so dropping the third signal costs little discrimination while removing the turn-fight risk entirely. Revisit only if on-device testing shows speed+accuracy insufficient. See §6.2.

**OQ-2 (non-blocking): Named threshold defaults.**
`HEADING_SNAP_ENTER_SPEED_MPS = 1.5`, `HEADING_SNAP_EXIT_SPEED_MPS = 3.0`, `HEADING_SNAP_ENTER_COURSE_ACCURACY_DEG = 45`, `HEADING_SNAP_EXIT_COURSE_ACCURACY_DEG = 25`. Shipped as named tunables with Kevin-tunable doc comments, same pattern as `driveModePitch` / `driveModeCameraSpan`. Recommend shipping with these defaults and calibrating on Kevin's next drive-test rather than blocking engineering on exact values now.

**OQ-3 (non-blocking): Left/Right chip classification stays on raw course — not touched this pass.**
`DrivingContextService.update(heading:)`'s existing signature and side-classification behavior (`sideRelativeToHeading`) are **unchanged**. The snapped heading only feeds the camera/puck. Reason: touching `update()`'s heading semantics risks the 18 existing test call sites across `DrivingContextServiceCruiseModeTests.swift` / `W85cTests.swift`, and Kevin's report is specifically about the camera arrow spinning, not the chip text flipping. Revisit as a follow-up only if on-device testing separately surfaces chip flip-flop at low speed.

**OQ-4 (non-blocking): Divided/median streets.**
No special handling. The matched segment's own polyline bearing is used as-is (same tile geometry the map already renders from — TF2-12/TF2-14 already improved divided-street curb accuracy). Flag as a follow-up only if Kevin's drive-test surfaces a specific bad case (e.g., Houston/Bowery).

---

## 1. Problem and User Story

**The problem (Kevin, build 13 drive-test, TF2-16):** "heading not synced properly all the time; sometimes it will spin and look for its direction" — specifically **at low speed when approaching an intersection or turn.**

**Root cause (confirmed in code, `ios/WePark/WePark/Services/LocationService.swift:35-46`):** Drive Mode heading is GPS course only (magnetometer intentionally dropped, FT-7), stabilized by an EMA (`headingEMA`, `DRIVING_HEADING_EMA_ALPHA = 0.35`), gated by `DRIVING_HEADING_MIN_SPEED_MPS = 0.5` (lowered from 1.8 in the TF2-3/build-7 fix so cruise-crawl parking-hunt speeds — often 0.5–1.5 m/s — don't freeze the arrow). Below ~2–3 m/s, GPS course is inherently noisy (it's derived by comparing successive fixes, which is unreliable when barely moving). At the 0.5 m/s gate, that noise passes through and the EMA turns it into the visible slow swing Kevin is seeing — exactly at intersection-approach speeds.

**Kevin's approved direction:** when the user is matched to a street segment and course confidence is low, default the heading to the segment's own travel-direction bearing (derived from `oneway` / `onewayToward`, shipped on segments since the FT-11 regen — `ios/WePark/WePark/Models/Segment.swift:61-75`) instead of trusting the noisy raw GPS course.

**User story:** "As a WePark driver approaching an intersection at low speed, I want the heading-up map and arrow to hold steady on the street I'm actually on, instead of visibly hunting/spinning — and I want it to hand back to my actual turn cleanly once I'm moving again, not fight the turn I'm making."

**Why now:** This is the one substantive camera/heading regression left from an otherwise-clean build-13 drive-test (TF2-11's zoom fix verified on-device same session). It's a small, well-scoped fix on a path the team already has strong process discipline around (#31 regression class).

---

## 2. Scope — In / Out

### In
- iOS only.
- New pure decision file: heading-source selection (course vs. street-snap) + snapped-bearing computation.
- Small additive exposure: `LocationService.driveCourseAccuracy`, `DrivingContextService.matchedSegment`.
- Wiring in `ContentView.handleLocationUpdate()` — the existing `.onChange(of: locationService.locationUpdateCount)` path (outside `updateUIView`).
- Hysteresis so the source doesn't flip-flop at the confidence boundary.
- Turn-recovery: exit back to course purely on speed + course accuracy recovering (not on course/EMA agreement), so an in-progress turn is never fought.

### Out
- Any change to `DrivingContextService.update()`'s public signature, `heading:` parameter semantics, or left/right side classification (OQ-3).
- Any change to `MapViewRepresentable.syncDriveHeading` itself, camera pitch/zoom/altitude, `.follow`, or any other TF2-11 Option A machinery. This spec changes **what value flows into** the existing `driveHeading` binding, not how that binding is consumed.
- Voice/commentary changes (TF2-7 territory, not touched).
- Wiring the dangling `selectDriveHeadingSource` function in `LocationService.swift` into production — that is a **different, pre-existing, unrelated** function (course vs. magnetometer selection, FT-7-followup tech debt) and is not part of this spec. Do not conflate the two; naming in this spec deliberately avoids reusing that identifier.
- Divided/median street special-casing (OQ-4).
- Backend/tile changes. PWA changes.

---

## 3. Architecture

### Codebases touched
iOS only:
- `ios/WePark/WePark/Services/LocationService.swift` (additive)
- `ios/WePark/WePark/Services/DrivingContextService.swift` (additive)
- `ios/WePark/WePark/Services/DriveHeadingSnap.swift` (**new** — pure decision functions)
- `ios/WePark/WePark/ContentView.swift` (wiring)
- `ios/WePark/WeParkTests/DriveHeadingSnapTests.swift` (**new**)
- `MapViewRepresentable.swift` is **not touched** — `syncDriveHeading` remains the sole pre-vetted camera-mutation-inside-`updateUIView` exception; this spec adds no new mutation surface there.

PWA: no changes. Backend: no changes.

### Current data flow (today)

```
CLLocationManagerDelegate.didUpdateLocations
  → LocationService.stabilizedHeading(rawHeading: course, speed, current)
     → speed gate (0.5 m/s) + EMA → driveHeading published

ContentView .onChange(of: locationService.locationUpdateCount)
  → handleLocationUpdate()
     → coordinatorActions.setDriveCamera?(coord, nil, altitude)      // position, Option A
     → drivingContextService.update(coordinate:, heading: locationService.driveHeading, …)
        → currentContext published (left/right chips)

ContentView.body → mapRepresentable
  → MapViewRepresentable(driveHeading: locationService.driveHeading, …)
     → updateUIView → syncDriveHeading(driveHeading) → camera.heading = h  [pre-vetted exception]
```

The camera's heading input is `locationService.driveHeading` directly — raw-course-EMA, with no awareness of the matched street.

### New data flow

```
ContentView .onChange(of: locationService.locationUpdateCount)
  → handleLocationUpdate()
     → coordinatorActions.setDriveCamera?(coord, nil, altitude)      // UNCHANGED (Option A position)
     → drivingContextService.update(coordinate:, heading: locationService.driveHeading, …)   // UNCHANGED signature/semantics
        → currentContext published (left/right chips — UNCHANGED)
        → drivingContextService.matchedSegment published (NEW — same closest-segment lookup update() already runs internally, exposed as a side-channel property; no second matcher)
     → NEW: driveHeadingSource = DriveHeadingSnap.nextHeadingSource(
           current: driveHeadingSource,
           hasBlockMatch: drivingContextService.matchedSegment != nil,
           speed: locationService.driveSpeed ?? 0,
           courseAccuracy: locationService.driveCourseAccuracy
       )
     → NEW: effectiveDriveHeading =
           switch driveHeadingSource {
           case .course:      locationService.driveHeading
           case .streetSnap:  DriveHeadingSnap.snappedHeading(
                                   segment: drivingContextService.matchedSegment!,
                                   lastGoodHeading: locationService.driveHeading)
           }

ContentView.body → mapRepresentable
  → MapViewRepresentable(driveHeading: effectiveDriveHeading, …)     // CHANGED source, same binding
     → updateUIView → syncDriveHeading(driveHeading) → camera.heading = h   [UNCHANGED — still the only exception]
```

Everything new executes inside `handleLocationUpdate()`, which is already the established, pre-vetted, `.onChange`-driven, outside-`updateUIView` location for Option A per-tick decisions (same pattern as `currentDriveAltitude`, `followPaused`). No new camera-mutation surface is introduced.

### Why `matchedSegment` doesn't need a second matcher

`DrivingContextService.update()` already computes the single closest segment to the driver's GPS position every tick (`findClosestSegment`, used for block identity). This spec exposes that same result as a new `private(set) var matchedSegment: Segment?`, set at the point `update()` already computes it — purely additive, zero change to `update()`'s existing control flow, return value, or the 18 existing test call sites that construct/assert on `DrivingContext`.

### New / changed symbols

**New file — `Services/DriveHeadingSnap.swift`** (pure Foundation only, no CoreLocation/UIKit/SwiftUI import — matches the `SegmentBearing.swift` house style):

| Symbol | Purpose |
|---|---|
| `enum HeadingSourceKind: Equatable { case course, streetSnap }` | Which source currently drives the camera heading. |
| `enum DriveHeadingSnapConstants` | Named tunables: `enterSpeedMPS`, `exitSpeedMPS`, `enterCourseAccuracyDeg`, `exitCourseAccuracyDeg`. |
| `static func nextHeadingSource(current:hasBlockMatch:speed:courseAccuracy:) -> HeadingSourceKind` | Pure hysteresis state-machine step. See §5. |
| `static func snappedHeading(segment:lastGoodHeading:) -> Double` | Pure bearing-selection. Uses `SegmentBearing.bearing(segment:toward:)` (existing FT-11 utility). See §5. |

**`LocationService.swift`:**

| Symbol | Change |
|---|---|
| `private(set) var driveCourseAccuracy: CLLocationDirection?` | NEW. Raw `CLLocation.courseAccuracy` from the same `didUpdateLocations` tick that sets `driveSpeed`. `nil` when the value is negative (CoreLocation's "invalid" sentinel), matching the existing `course >= 0 ? course : nil` pattern used for `courseHeading`. Cleared to `nil` in `endDriveMode()` alongside the other drive-session state. |

**`DrivingContextService.swift`:**

| Symbol | Change |
|---|---|
| `private(set) var matchedSegment: Segment?` | NEW. Set from the existing closest-segment lookup already inside `update()`. `nil` when `update()` finds no segment (mirrors `currentContext == nil`). |

**`ContentView.swift`:**

| Symbol | Change |
|---|---|
| `@State private var driveHeadingSource: HeadingSourceKind = .course` | NEW. Reset to `.course` in `handleDriveModeChange(true)` (entry) and `handleDriveModeChange(false)` (exit) — same reset pattern as `followPaused` / `currentDriveAltitude`. |
| `@State private var effectiveDriveHeading: Double? = nil` | NEW. Reset to `nil` on Drive Mode exit (mirrors `locationService.driveHeading` resetting to `nil` in `endDriveMode()`). |
| `handleLocationUpdate()` | Add the source-selection + snapped-heading computation described above, after the existing `drivingContextService.update(...)` call. |
| `mapRepresentable` (`@ViewBuilder`, line ~1145) | `driveHeading: locationService.driveHeading` → `driveHeading: effectiveDriveHeading`. This is the **only** change to the `MapViewRepresentable` call site — no other parameter changes. |
| `handleDriveModeChange(_:)` | Add `driveHeadingSource = .course` and (on exit) `effectiveDriveHeading = nil` to the existing entry/exit reset blocks. |

### Tables / RPCs
None. Pure client-side, iOS-only.

---

## 4. Work Streams

Single iOS-only stream. No parallel agent execution needed (no backend/PWA/design surface).

| Stream | Agent | Notes |
|---|---|---|
| Pure decision functions + unit tests (`DriveHeadingSnap.swift`) | @ios-engineer | Framework-independent, write first — this is the testable core. |
| `LocationService` / `DrivingContextService` additive exposure | @ios-engineer | Small, additive, zero-regression-risk changes. |
| `ContentView` wiring | @ios-engineer | Inside `handleLocationUpdate()` / `handleDriveModeChange()` only — no `MapViewRepresentable.swift` diff. |
| Full test suite + `RegionSyncGuardTests` regression check | @ios-engineer (self-check) | Must stay green — this is the standing #31-class gate. |
| Live-UI smoke (sim screenshot, read it) | @ios-engineer, then re-verified by @qa-verifier | Mandatory before merge per the #31-regression-class discipline. |
| QA pass (fresh agent, not the builder) | @qa-verifier | `docs/qa/tf2-16-heading-snap-pass-1-<date>.md`. |
| On-device drive-test | Kevin | Irreducible final gate — the sim has no moving GPS/magnetometer to exercise the actual hunt-then-turn scenario. |

All work goes in a single isolated worktree (e.g. `ios/tf2-16-heading-snap`). Sequential: functions+tests → wiring → suite+RegionSyncGuardTests → smoke → QA → fix findings → Kevin drive-test → merge.

---

## 5. Decision Logic (Precise Behavior)

### 5.1 Source selection (hysteresis)

```swift
static func nextHeadingSource(
    current: HeadingSourceKind,
    hasBlockMatch: Bool,
    speed: Double,            // m/s, clamped >= 0
    courseAccuracy: Double?   // degrees; nil = unavailable/invalid
) -> HeadingSourceKind {
    guard hasBlockMatch else { return .course }   // item 5: no match → always course (freeze-on-stop unchanged)

    let lowConfidence =
        speed < DriveHeadingSnapConstants.enterSpeedMPS
        || courseAccuracy == nil
        || courseAccuracy! > DriveHeadingSnapConstants.enterCourseAccuracyDeg

    let highConfidence =
        speed >= DriveHeadingSnapConstants.exitSpeedMPS
        && courseAccuracy != nil
        && courseAccuracy! <= DriveHeadingSnapConstants.exitCourseAccuracyDeg

    switch current {
    case .course:     return lowConfidence  ? .streetSnap : .course
    case .streetSnap: return highConfidence ? .course      : .streetSnap
    }
}
```

- **Item 2 (fast + clean course wins):** at speed ≥ `exitSpeedMPS` with good `courseAccuracy`, the function only ever returns `.course` — matches today's behavior exactly, zero change at cruising speed.
- **Item 4 (hysteresis):** the enter/exit thresholds are asymmetric (1.5 vs 3.0 m/s; 45° vs 25°) and the function is state-dependent (`current` matters) — a value oscillating near a single threshold cannot flip the source every tick; it must cross the *wider* gap to switch direction.
- **Item 5 (no block match):** `hasBlockMatch == false` short-circuits to `.course` unconditionally. The `.course` branch then flows straight into `locationService.driveHeading`, which already implements freeze-on-stop (`LocationService.stabilizedHeading` returns the last good `driveHeading` when speed is below `DRIVING_HEADING_MIN_SPEED_MPS`). **No change to this path at all.**

### 5.2 Bearing selection

```swift
static func snappedHeading(segment: Segment, lastGoodHeading: Double?) -> Double {
    let towardBearing = SegmentBearing.bearing(segment: segment, toward: .toward_to)  // line[0] → line.last
    let reverseBearing = (towardBearing + 180).truncatingRemainder(dividingBy: 360)

    if segment.oneway == true {
        switch segment.onewayToward {
        case "to":   return towardBearing
        case "from": return reverseBearing
        default:     break  // malformed data — fall through to two-way logic
        }
    }

    // Item 3: two-way (or oneway data missing/malformed) — pick whichever direction
    // is closer to the last known good heading. Circular distance, not linear.
    guard let last = lastGoodHeading else { return towardBearing }  // stable, documented default
    return circularDelta(towardBearing, last) <= circularDelta(reverseBearing, last)
        ? towardBearing : reverseBearing
}
```

- **Item 1 (one-way default):** `segment.oneway == true` with a valid `onewayToward` ("from"/"to" — the segment's own endpoint literals, per `Segment.swift:70-75`, **not** cross-street names) returns exactly that direction's bearing, unconditionally — matches Kevin's explicit direction.
- **Item 3 (two-way ambiguity):** resolved via circular distance to `lastGoodHeading` (i.e., `locationService.driveHeading` at the moment of the call — the last trustworthy EMA value before confidence dropped).
- No `lastGoodHeading` available (first-ever tick in snap mode with no prior EMA) → defaults to `towardBearing`, a stable, deterministic, arbitrary-but-consistent choice (never oscillates on its own).

### 5.3 Item 6 — turn handling (the exact scenario Kevin reported)

This is the part most likely to go wrong, so it's stated explicitly:

- **Entering snap** is gated on speed and course accuracy only (§5.1) — **not** on course/EMA disagreement. A real turn produces a large course swing, which is the correct, trustworthy signal that the car IS turning — it must never be misread as "noise, snap to the old street."
- **Exiting snap** requires speed ≥ `exitSpeedMPS` **and** `courseAccuracy` ≤ `exitCourseAccuracyDeg` — again, no disagreement check. As the driver accelerates out of a turn, GPS course legitimately swings toward the new heading; requiring "low disagreement" to exit would be self-defeating (disagreement is elevated precisely because the turn is happening) and would hold the snap on the *old* street's bearing exactly while the car is executing the turn — the failure this spec exists to prevent.
- **Mid-turn, still slow:** if the driver is still below `exitSpeedMPS` while turning (e.g., a slow, tight turn), `matchedSegment` updates automatically as soon as the GPS position crosses onto the new street's nearest segment (existing haversine closest-segment search, unchanged) — so the snap target itself re-targets to the new street's bearing, it does not stay locked to the pre-turn street.
- **Net effect:** the moment speed/course recover post-turn, the source flips back to `.course` in that same tick (no artificial multi-tick delay, no dependency on the turn "settling" first) — verified by Test Inventory #6 below.

---

## 6. Analysis

### 6.1 Why speed + course accuracy, not disagreement (OQ-1 detail)

`CLLocation.courseAccuracy` (available since iOS 13.4, within our iOS 17 minimum) is CoreLocation's own confidence signal for `course` — a direct, already-computed quality measure that doesn't require deriving anything new. At the reported low-speed intersection-approach scenario, both speed and course accuracy degrade together (GPS course is derived by comparing successive fixes; both signals are direction-of-travel-uncertainty measures, just from different math). A disagreement-based third signal is largely redundant with these two in the reported scenario, while uniquely risky in the turn-recovery scenario (§5.3). Recommendation: ship without it; add only if on-device testing in a future TF round shows speed+accuracy insufficient (unlikely given the reported symptom is specifically "at low speed").

### 6.2 `#31` safety

No new mutation is added inside `updateUIView`. `syncDriveHeading` remains the single pre-vetted exception (unchanged in this spec — `MapViewRepresentable.swift` has zero diff). The new decision logic runs entirely inside `handleLocationUpdate()`, the same `.onChange(of: locationService.locationUpdateCount)`-driven, outside-`updateUIView` location Option A already uses for `setDriveCamera`. The only change to the `MapViewRepresentable` call site is which `@State` variable feeds the existing `driveHeading:` parameter — the binding itself, and everything downstream of it in `MapViewRepresentable`, is untouched.

The @ios-engineer must confirm in the PR description that `grep -n "setCamera\|setRegion\|userTrackingMode =" MapViewRepresentable.swift` shows no new call sites, and that `RegionSyncGuardTests` pass unmodified.

### 6.3 Test-regression risk on `DrivingContextService.update()`

Because `update()`'s signature, `heading:` parameter semantics, and `currentContext` (left/right classification) output are explicitly **unchanged** (OQ-3), all 18 existing call sites in `DrivingContextServiceCruiseModeTests.swift`, `W85cTests.swift` continue to compile and pass with zero modification. The only addition to `DrivingContextService` is a new published property with no interaction with any existing code path.

---

## 7. Acceptance Criteria

- [ ] **AC-1.** `DriveHeadingSnap.swift` exists, imports only `Foundation`, and contains `nextHeadingSource(current:hasBlockMatch:speed:courseAccuracy:)` and `snappedHeading(segment:lastGoodHeading:)` exactly per §5. 100% covered by the Test Inventory (§8).
- [ ] **AC-2.** `LocationService.driveCourseAccuracy` publishes `CLLocation.courseAccuracy` from the same tick as `driveSpeed`, `nil` when CoreLocation reports an invalid (negative) value, cleared in `endDriveMode()`.
- [ ] **AC-3.** `DrivingContextService.matchedSegment` is set from the exact same closest-segment lookup `update()` already performs — verified by code review that no second distance-search algorithm was introduced.
- [ ] **AC-4.** `DrivingContextService.update()`'s signature, `heading:` parameter semantics, and `currentContext` output are byte-identical to pre-spec behavior. All 18 existing `DrivingContextServiceCruiseModeTests.swift` / `W85cTests.swift` call sites pass unmodified.
- [ ] **AC-5.** `ContentView`'s `MapViewRepresentable(driveHeading:)` argument is `effectiveDriveHeading`, computed in `handleLocationUpdate()`. `driveHeadingSource` resets to `.course` and `effectiveDriveHeading` resets to `nil` in `handleDriveModeChange(_:)` on both entry and exit.
- [ ] **AC-6.** Matched to a `oneway == true` segment at low confidence → `effectiveDriveHeading` equals the one-way travel bearing per `onewayToward`.
- [ ] **AC-7.** Matched to a two-way (or `oneway` nil) segment at low confidence → `effectiveDriveHeading` equals whichever of the segment's two direction bearings is circularly closer to the last good heading.
- [ ] **AC-8.** Fast + accurate course (≥ `exitSpeedMPS`, ≤ `exitCourseAccuracyDeg`) → `effectiveDriveHeading` equals `locationService.driveHeading` unchanged — zero behavior change from today at cruising speed.
- [ ] **AC-9.** No block match → `effectiveDriveHeading` equals `locationService.driveHeading` (freeze-on-stop preserved, unchanged from today).
- [ ] **AC-10.** Hysteresis: unit tests (Test Inventory #5) confirm the source does not oscillate when speed/accuracy hover at or near a single threshold.
- [ ] **AC-11.** Turn-recovery: a single tick where speed and course accuracy both cross the exit thresholds returns `.course` in that same tick — no artificial lag (Test Inventory #6).
- [ ] **AC-12.** `RegionSyncGuardTests` pass unmodified (2/2 or current count).
- [ ] **AC-13.** No new camera-mutation call site inside `updateUIView` — `MapViewRepresentable.swift` has zero diff in this PR.
- [ ] **AC-14.** Full test suite green; @ios-engineer reports the exact before/after count in the PR.
- [ ] **AC-15 (live-UI smoke).** Sim screenshot confirms the full overlay chain (toolbar, ASP banner, bottom card, Park Until pill) still renders after Drive Mode entry — standard #31-class regression check.
- [ ] **AC-16.** Independent QA pass (`@qa-verifier`, not the builder) filed at `docs/qa/tf2-16-heading-snap-pass-1-<date>.md` before merge.
- [ ] **AC-17 (Kevin on-device — irreducible gate).** At a known one-way street with a turn: (a) heading no longer visibly spins/hunts while stopped/slow near the intersection, (b) heading correctly and promptly reflects the new direction once the turn is executed and speed picks back up — no fighting the turn, (c) no regression to fast-cruise heading-up smoothness (re-verify TF2-11/build-13 "zoom is working better" / heading-up feel is preserved).

---

## 8. Test Inventory

**New file: `DriveHeadingSnapTests.swift`** (pure, no XCTest UIKit dependency needed):

1. `testNextHeadingSource_highSpeedCleanCourse_staysOnCourse`
2. `testNextHeadingSource_lowSpeed_entersSnapWhenBlockMatched`
3. `testNextHeadingSource_lowSpeed_noBlockMatch_staysOnCourse`
4. `testNextHeadingSource_poorCourseAccuracy_entersSnapEvenAtModerateSpeed`
5. `testNextHeadingSource_hysteresis_hoveringNearSingleThreshold_doesNotOscillate` — while already `.course`, values between `exitSpeedMPS` and `enterSpeedMPS` alone don't force a flip either way inconsistently; while already `.streetSnap`, values in that same band stay `.streetSnap` until the exit threshold is actually crossed.
6. `testNextHeadingSource_turnRecovery_speedAndAccuracyJumpTogether_exitsInSameTick` — simulate speed 0.3→4.0 m/s and courseAccuracy 90°→10° in a single call → returns `.course` immediately, no multi-tick dependency.
7. `testNextHeadingSource_nilCourseAccuracy_treatedAsLowConfidence`
8. `testSnappedHeading_onewayTowardTo_returnsForwardBearing`
9. `testSnappedHeading_onewayTowardFrom_returnsReverseBearing`
10. `testSnappedHeading_twoWay_picksDirectionClosestToLastGoodHeading` (two cases: last-good near forward, last-good near reverse)
11. `testSnappedHeading_twoWay_noLastGoodHeading_defaultsToForwardBearing`
12. `testSnappedHeading_onewayDataMalformed_fallsBackToTwoWayLogic` (`onewayToward` not `"to"`/`"from"`)
13. `testSnappedHeading_circularDelta_wrapsCorrectlyAcrossZero` (e.g. bearing near 359° vs. last-good near 2°)

**`LocationServiceTests` (extend existing file):**
14. `testDriveCourseAccuracy_publishesRawValue`
15. `testDriveCourseAccuracy_negativeValue_publishesNil`
16. `testDriveCourseAccuracy_clearedOnEndDriveMode`

**`DrivingContextServiceCruiseModeTests.swift` / `W85cTests.swift` (regression, no new assertions needed — just confirm unmodified):**
17. Existing 18 `update(...)` call sites compile and pass unmodified — explicit regression note in the PR, not a new test.

**Regression gates (existing suites, must stay green):**
18. `RegionSyncGuardTests` — full pass.
19. Full `xcodebuild test` suite — net count increase reported in PR (≈ +16 new tests per above).

**Not unit-testable (smoke/manual only):**
- Live overlay-chain rendering after Drive Mode entry (AC-15, sim screenshot).
- The actual visual "spin/hunt" symptom and its resolution (AC-17, Kevin's irreducible on-device gate — sim has no magnetometer/moving-GPS to reproduce it).

---

## 9. Open Decisions (Summary)

| ID | Question | Resolution | Blocks |
|---|---|---|---|
| OQ-1 | Include course/EMA disagreement as a third low-confidence signal? | **No** — speed + courseAccuracy only, to avoid fighting real turns (§5.3, §6.1). | Nothing — ship as specified. |
| OQ-2 | Exact threshold values? | Ship named-constant defaults (§listed above); calibrate on Kevin's next drive-test, same pattern as `driveModePitch`. | Nothing. |
| OQ-3 | Should left/right chip classification also use the snapped heading? | **No**, out of scope this pass — zero regression risk to 18 existing tests; revisit only if chip flip-flop is separately observed. | Nothing. |
| OQ-4 | Special-case divided/median streets? | **No** — rely on existing tile geometry (TF2-12/14); revisit only if Kevin's drive-test surfaces a bad case. | Nothing. |

No item in this table blocks engineering start.

---

## 10. Out-of-Scope Follow-Ups

- **Left/right chip stability at low speed** — deferred (OQ-3). If Kevin's drive-test shows the chips themselves flipping (not just the arrow), that's a `DrivingContextService.update()` signature change and deserves its own small follow-up spec, not a silent bundle into this one.
- **Disagreement-based confidence signal** — deferred (OQ-1). Only revisit if speed+accuracy prove insufficient on-device.
- **Divided/median street bearing correctness** — deferred (OQ-4), inherits whatever TF2-12/14 shipped.
- **FT-7-followup** (wiring the *other*, pre-existing `selectDriveHeadingSource` function into production) — unrelated tech debt, explicitly not touched here; do not conflate with this spec's new `DriveHeadingSnap` functions.
- **Threshold calibration** — ships with reasoned defaults; expected follow-up tuning after Kevin's drive-test, same as every other Drive Mode camera constant to date.

---

## 11. Related Specs and Docs

- `docs/field-testing-log.md` — TF2-16 entry (source of this spec's direction).
- `docs/qa/tf2-11-option-a-qa.md` — current camera-ownership architecture (Option A custom follow) this spec's heading value flows into.
- `docs/qa/build7-rotation-qa.md` — TF2-3 puck/heading-source fix history (speed gate 1.8→0.5, puck double-rotation fix) — the regression this spec is refining, not replacing.
- `ios/WePark/WePark/Services/SegmentBearing.swift` — FT-11 bearing utility reused by `snappedHeading`.
- `ios/WePark/WePark/Views/ReportSheet.swift:142-149` — existing precedent for interpreting `onewayToward` as `"from"`/`"to"` literals (not cross-street names).

# FT-7 — Drive Mode Follow Smoothness + Correct Arrow Heading

**Spec version:** 1.0  
**Date:** 2026-06-08  
**Author:** Tech Lead / Planner  
**Status:** Ready for implementation  
**Agent owner:** `@ios-engineer`  
**Related:** `docs/w8.5c-drive-mode-active-spec.md`, `docs/w8.5c-polish-pr3-spec.md`, #31-regression class

---

## Open Decisions — Kevin Must Confirm Before Code Starts

These three items are the only genuine ambiguities. Everything else in this spec is a direct design call.

**OQ-FT7-1 (Dead-band value).** The spec recommends lowering from 5° to 2°. Given that camera rotation is now animated, the feedback-loop risk of a lower threshold is substantially reduced. Confirm: 2°, keep 5°, or a different value? If Kevin has no opinion the engineer should ship 2° per this spec's recommendation.

**OQ-FT7-2 (startUpdatingHeading in Drive Mode).** The spec recommends calling `stopUpdatingHeading()` entirely during Drive Mode (option i). The side effect is that `mapView.showsCompass` will not show a live heading indicator, but the arrow puck already provides that signal. Confirm acceptable.

**OQ-FT7-3 (Animation duration).** The spec recommends 0.3 s for all three animation sites. If Kevin's real-device drive-test (the long-pending smoke) finds it still feels snappy/abrupt, bump to 0.5 s. The engineer should ship 0.3 s and annotate the constant so Kevin can tune it without a spec revision.

---

## 1. Problem and User Story

**Symptom A — Askew arrow.** The directional puck arrow in Drive Mode does not point along the road. On a straight block heading north the arrow may read 30–50° east of north because the phone is sitting at an angle in a cup holder. The arrow reflects where the phone is physically pointing (magnetometer), not where the car is traveling (GPS course).

**Symptom B — Jerky follow.** The map camera and puck rotation both step in discrete visible jumps at approximately 1 Hz GPS cadence. Between GPS fixes the camera is motionless; on each fix it teleports to the new heading and position with no animation. At 35 mph this produces an uncanny, video-game-like feel.

**User story:**  
*As a driver using Drive Mode in a cup-holder-mounted iPhone, I want the arrow puck to point in the direction I am actually driving, and I want the map to pan and rotate fluidly, so the app feels like a navigation app rather than a slideshow.*

---

## 2. Scope — In / Out

### In scope

- Change the heading source fed to `driveHeading` from the blended magnetometer+GPS-course path to GPS course only (while speed is above the gate).
- Animate `syncDriveHeading` camera rotation.
- Animate the puck `CGAffineTransform` rotation with shortest-angular-path handling.
- Animate `syncDriveRegion` follow-recentering.
- Lower the heading dead-band from 5° to 2° (conditional on OQ-FT7-1).
- Add the pure-logic heading-source-selection function and unit tests for it.
- Add the shortest-arc rotation helper and its unit test.
- Verify all existing tests still pass (RegionSyncGuardTests, W85cTests, DriveCameraTiltTests).
- Live-UI smoke gate before merge.

### Out of scope (deferred, Phase 2)

- **Display-link interpolation.** Full 60-fps interpolation between GPS fixes via a `CADisplayLink` that tween-interpolates `driveHeading` every frame. This is the "full smoothness" upgrade; it is explicitly deferred. Note it in out-of-scope follow-ups below.
- **Street-bearing / one-way snap.** Snapping the arrow to the nearest one-way street bearing to eliminate residual GPS course wobble on straight blocks. Deferred pending the real-device drive-test calibration.
- **EMA alpha re-tuning.** The existing `DRIVING_HEADING_EMA_ALPHA = 0.35` is unchanged in this spec. The drive-test may reveal it needs tightening; that is a one-line follow-up.
- **Magnetometer use cases outside Drive Mode.** `didUpdateHeading` behavior when Drive Mode is not active is unchanged.

---

## 3. Architecture

### Codebase touch points

Only iOS. No PWA, no backend changes.

| File | Change |
|---|---|
| `ios/WePark/WePark/Services/LocationService.swift` | Part A: stop feeding `didUpdateHeading` into `driveHeading` while moving; optionally stop calling `startUpdatingHeading` entirely in Drive Mode |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | Part B: animate `syncDriveHeading`, puck transform, and `syncDriveRegion`; lower dead-band; add `shortestArcDelta` helper |
| `ios/WePark/WeParkTests/FT7Tests.swift` | New test file: heading-source pure-logic tests, shortest-arc helper test |
| `ios/WePark/WeParkTests/W85cTests.swift` | Update expectations in `EMAStabilizerTests` that currently test `stabilizedHeading` with a `rawHeading` parameter that will now be treated as course-only (see §4.A below) |

### Data flow — current (broken)

```
didUpdateLocations → loc.course → stabilizedHeading(rawHeading: course) → headingEMA → driveHeading
didUpdateHeading  → trueHeading → stabilizedHeading(rawHeading: magHeading) → headingEMA → driveHeading
                                                   ^--- BOTH paths write headingEMA simultaneously
```

GPS course (~1 Hz) and magnetometer (~10 Hz) alternate writes to `headingEMA`. At any given moment the last writer wins. The magnetometer fires far more frequently, so it dominates even when GPS course is available. Since the magnetometer reflects phone-mount angle (not travel direction), the puck arrow is askew.

### Data flow — target

```
didUpdateLocations → loc.course → stabilizedHeading(rawHeading: course) → headingEMA → driveHeading
didUpdateHeading   → [ignored while driveModeActiveInternal && speed >= gate]
```

The magnetometer is shut out of `driveHeading` entirely while moving in Drive Mode. All existing stabilizer logic (EMA, circular wrap, course-from-movement fallback, freeze-on-stop) continues to operate; the only change is the source of `rawHeading`.

### Animation data flow — current (jerky)

```
GPS fix (1 Hz) → driveHeading published → updateUIView called → syncDriveHeading:
    setCamera(animated: false)                    ← instant teleport
    view.transform = CGAffineTransform(...)       ← instant teleport
syncDriveRegion:
    setCamera(animated: false)                    ← instant teleport
```

### Animation data flow — target (smooth)

```
GPS fix (1 Hz) → driveHeading published → updateUIView called → syncDriveHeading:
    setCamera(animated: true, duration: 0.3s)     ← smooth ease
    UIView.animate(duration: 0.3s):
        view.transform = CGAffineTransform(shortestArc)   ← smooth ease, correct arc
syncDriveRegion:
    setCamera(animated: true, duration: 0.3s)     ← smooth ease
```

---

## 4. Work Streams

Only one agent (`@ios-engineer`) is involved. The two parts (A and B) can be committed in sequence or together in a single PR. They are not independently deployable — a PR with Part A but not Part B would have correct heading but still jerky animation. Ship them together.

### Part A — Heading source change (`LocationService.swift`)

**Owner:** `@ios-engineer`

#### A.1 — Introduce `driveHeadingSource` pure-logic function

Add a new **pure, static, free function** (not a method on `LocationService` — no `self` captures, no framework types beyond `Double` and `Bool`). Place it outside any type at the top of `LocationService.swift` or in a small adjacent `DriveHeadingSourceLogic.swift` file if preferred.

```
// Pseudocode — engineer writes the Swift signature:
func selectDriveHeadingSource(
    course: Double?,          // loc.course; nil if < 0
    magnetometerHeading: Double?,  // trueHeading or magneticHeading; nil if unavailable
    speed: Double,            // m/s
    driveModeActive: Bool
) -> Double?                  // chosen raw heading to feed into stabilizedHeading
```

Decision logic (all four branches must be unit-testable):

1. **Moving in Drive Mode** (`driveModeActive && speed >= DRIVING_HEADING_MIN_SPEED_MPS`): return `course`. If `course` is nil, return `nil` (the existing course-from-movement fallback inside `stabilizedHeading` handles the nil case via `prevDriveCoordinate`). **Magnetometer is not returned, period.**
2. **Stopped in Drive Mode** (`driveModeActive && speed < DRIVING_HEADING_MIN_SPEED_MPS`): return `nil`. The existing speed-gate freeze-on-stop in `stabilizedHeading` will return `driveHeading` (last good value). Magnetometer is still not returned.
3. **Not in Drive Mode, magnetometer available**: return `magnetometerHeading` (unchanged non-Drive-Mode behavior — not actually called in production today, but the function should be complete).
4. **Not in Drive Mode, no magnetometer**: return `nil`.

The function signature is trivially unit-testable with `XCTAssertEqual`. The engineer must implement this as a pure function, not as a conditional buried inside the delegate callback, so the QA agent can verify it in isolation.

#### A.2 — Wire the function into `didUpdateLocations` (lines 294–321)

Current `didUpdateLocations` (lines 299–313) calls `stabilizedHeading(rawHeading: courseHeading, ...)` where `courseHeading = loc.course >= 0 ? loc.course : nil`. This part is already correct — it passes GPS course. **No change needed to `didUpdateLocations`.**

#### A.3 — Gate `didUpdateHeading` (lines 323–342)

Current `didUpdateHeading` (lines 323–342) feeds `trueHeading`/`magneticHeading` into `stabilizedHeading` while `driveModeActiveInternal` is true. This is the root cause.

**Change:** Add a speed gate inside `didUpdateHeading`. If `driveModeActiveInternal && (driveSpeed ?? 0) >= DRIVING_HEADING_MIN_SPEED_MPS`, return immediately without calling `stabilizedHeading`. Specifically:

```
// In didUpdateHeading, after the existing "guard driveModeActiveInternal else { return }" line:
// Gate: while moving in Drive Mode, GPS course owns driveHeading; magnetometer is ignored.
if driveModeActiveInternal && (driveSpeed ?? 0) >= DRIVING_HEADING_MIN_SPEED_MPS {
    return
}
// Below this gate: only reached when stopped in Drive Mode, or outside Drive Mode.
// Freeze-on-stop behavior is already handled by stabilizedHeading's speed gate.
// So returning here while moving is safe — it delegates completely to didUpdateLocations.
```

The `selectDriveHeadingSource` pure function (A.1) documents the same logic but is not literally called here — the function exists for unit testing the decision, not for runtime dispatch (to avoid the overhead of an extra function call on every magnetometer tick, and to keep the code readable at the call site). The engineer may choose to call the function if they prefer consistency — either approach is acceptable, but the pure function must exist regardless.

#### A.4 — Consider stopping `startUpdatingHeading` in Drive Mode (OQ-FT7-2)

If Kevin confirms OQ-FT7-2, change `startDriveMode()` to NOT call `manager.startUpdatingHeading()`, and change `endDriveMode()` to NOT call `manager.stopUpdatingHeading()`. The `didUpdateHeading` gate in A.3 becomes moot (no callbacks fire). This is the cleaner solution but has the side effect that `MKMapView.showsCompass` will not receive a live heading update (the compass rose will be stale). The directional puck arrow is a more prominent signal so this is acceptable.

If Kevin cannot confirm before code starts, the engineer should implement A.3 (gate within `didUpdateHeading`) as the safe default and note A.4 as a follow-up.

#### A.5 — EMA alpha re-evaluation

The existing `DRIVING_HEADING_EMA_ALPHA = 0.35` applies EMA smoothing to the GPS course. With course as the sole source, the EMA may need to be slightly less aggressive (GPS course is already lower-noise than magnetometer in a moving car). The spec recommends **keeping 0.35 unchanged** for this PR, pending real-device drive-test calibration. Document the constant's purpose clearly in a comment so Kevin can tune it post-drive-test.

#### A.6 — W8.5c test impact

The `EMAStabilizerTests` class in `W85cTests.swift` tests `stabilizedHeading(rawHeading:speed:current:)` directly and is unaffected by the `didUpdateHeading` gate — those tests call the function with whatever `rawHeading` the test supplies, which is the GPS course path. **No test expectations change for `EMAStabilizerTests`.**

However, `HeadingUpRotationTests.testSyncDriveHeading_*` tests the `syncDriveHeading` coordinator method, which is modified in Part B below. Those tests exercise the dead-band logic directly on a headless `MKMapView`, which continues to work. The only expectation change needed is if the dead-band threshold changes from 5° to 2° (OQ-FT7-1): tests asserting `guard diff > 5` behavior must be updated to `guard diff > 2`. Specifically:

- `testStabilizedHeading_deadBand_noMapUpdate_below5deg` (W85cTests.swift line 171): if dead-band moves to 2°, this test's name and threshold must update to 2°.
- `testHeadingDiff_below5degrees_shouldNotTriggerUpdate` (W85cTests.swift line 818): same update needed.
- `testSyncDriveHeading_belowDeadBand_skipsUpdate` (W85cTests.swift line 908): sets `lastAppliedHeading = 90.0` and calls `syncDriveHeading(92.0, ...)` expecting no update. At 2°, the 2° change (90→92) still falls below the 2° threshold — wait, 92-90 = 2°, and the guard is `guard diff > 2`. So `diff == 2.0` does NOT pass the guard (2 is not > 2). This test still passes. Confirm `headingDiff(92.0, 90.0) == 2.0` and the guard `> threshold` (strict greater-than) is preserved.
- `DriveCameraTiltTests.testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped` (DriveCameraTiltTests.swift line 89): this test sets `lastAppliedHeading = 90` and calls `syncDriveHeading(90, ...)` with diff = 0°. Passes regardless of dead-band value.

**Summary:** if dead-band changes to 2°, three test names/comments need updating to say "2°" instead of "5°". The assertions themselves pass without change because the test inputs (diff = 0° or diff = 2°) fall at or below the 2° threshold in the strict `> 2` guard.

---

### Part B — Animation change (`MapViewRepresentable.swift`)

**Owner:** `@ios-engineer`

#### B.1 — Animation duration constant

Add a single constant at the struct level (alongside `driveModePitch` and `driveModeCameraSpan`):

```
// Pseudocode:
static let driveAnimationDuration: TimeInterval = 0.3
```

Justification (see §5 — Duration / Cadence for full reasoning): 0.3 s chosen to stay under the ~1 Hz GPS fix cadence (1.0 s). At 0.3 s, each animation completes in roughly the first third of the interval between fixes. MKMapView handles mid-animation retargeting gracefully (new `setCamera` cancels and replaces the in-flight animation from the same origin). The constant is annotated with a comment pointing Kevin to tune it post-drive-test. 0.5 s is the suggested fallback if 0.3 s still feels abrupt on real hardware.

#### B.2 — Animate `syncDriveHeading` camera rotation (lines 925–951)

Current code (Coordinator.syncDriveHeading, line 935):
```swift
mapView.setCamera(camera, animated: false)
```

Change to:
```swift
mapView.setCamera(camera, animated: true)  // duration controlled by MKMapView default (~0.3s)
```

MKMapView's `setCamera(animated: true)` uses an internal animation that is not directly duration-configurable via the public API. The default duration is approximately 0.3–0.5 s at reasonable zoom levels, which matches the target. If precise duration control is needed, the engineer may use `MKMapView.setCamera(_:animated:)` wrapped in `UIView.animate(withDuration: driveAnimationDuration)` — but this is only needed if the default MapKit duration proves unsatisfactory on real hardware. Ship the simpler `animated: true` first.

**Safety:** animated `setCamera` fires `regionWillChangeAnimated` and `regionDidChangeAnimated`. In `regionWillChangeAnimated`, the FT-5 guard (lines 1280–1284) checks `mapView.gestureRecognizers?.contains(where: { $0.state == .began || .changed || .ended })`. A programmatic animated `setCamera` has no active gesture recognizer, so `isUserInteracting` stays false. In `regionDidChangeAnimated`, `isUserInteracting` is cleared unconditionally, which is correct and harmless. The `onRegionChanged` callback fires, which triggers tile loading in ContentView — this is existing behavior for all camera changes and is intentional.

The existing `driveFollowEnabled`/`onDrivePanDetected` path in `regionWillChangeAnimated` (lines 1287–1294) is gated on `parent.driveHeading != nil` first, then on `isUserGesture`. An animated programmatic `setCamera` does not set `isUserGesture = true` (no active recognizer), so `onDrivePanDetected` is not called. **Animated follow-recenters are not mistaken for user pans.** See AC-FT7.9 for the required assertion.

**Dead-band after animation:** The `guard diff > [threshold]` check at lines 929–931 still applies. With `animated: true`, a heading that changes by 1° (below the dead-band) is still skipped entirely — no animation fires. A heading that changes by 3° (above a 2° dead-band) fires one short animation. The dead-band is still valuable because it prevents spurious camera animations when the GPS course oscillates within noise. At 2°, the dead-band eliminates animations for sub-2° jitter, which is appropriate.

**Feedback-loop analysis:** `setCamera(animated: true)` → `regionWillChangeAnimated` (no gesture → `isUserInteracting` stays false) → `regionDidChangeAnimated` → `onRegionChanged` (tile load, does not call `syncDriveHeading`) → next `updateUIView` is triggered only by a SwiftUI re-render, not by the camera change itself. `syncDriveHeading` is called in `updateUIView` only when `driveHeading` changes — the `regionDidChangeAnimated` callback does not change `driveHeading`. Therefore the animated camera change cannot create a feedback loop. The existing dead-band provides a second layer of protection: if `updateUIView` does fire before the animation completes, the heading has not changed by >threshold, so `syncDriveHeading` returns early.

**Boundary case — Drive Mode exit:** The `else` branch (lines 943–950) resets to north-up:
```swift
mapView.setCamera(camera, animated: false)
```
This exit path should **remain `animated: false`** — the exit transition is handled by `applyDriveCameraState` (lines 991–1028) which uses `animated: true` already and is outside `updateUIView`. The `syncDriveHeading` exit path fires only once (guarded by `guard lastAppliedHeading != nil else { return }`) and resets heading to 0. Animating this would create a visual conflict with the exit camera restoration. Keep it `animated: false`.

#### B.3 — Animate puck rotation with shortest-arc (lines 937–942)

Current code (inside syncDriveHeading, lines 940–942):
```swift
let headingRad = CGFloat(h * .pi / 180.0)
mapView.view(for: mapView.userLocation)?.transform =
    CGAffineTransform(rotationAngle: headingRad)
```

This has two bugs:
1. Instant transform — no animation.
2. Does not use shortest-arc. If `lastAppliedHeading` was 359° and new heading is 1°, `CGAffineTransform(rotationAngle: 1° * pi/180)` rotates the view from its current state (359°) counter-clockwise by 358° instead of clockwise by 2°. The view spins the long way.

**Fix:**

Add a pure static helper function on `MapViewRepresentable`:

```
// Pseudocode:
static func shortestArcDelta(from currentAngleRad: CGFloat, to targetAngleRad: CGFloat) -> CGFloat
```

The function returns the angular delta in radians that produces the shortest rotation (in [-pi, +pi]). The puck's new transform is `currentTransform.rotated(by: delta)` rather than replacing the transform with an absolute angle.

Then wrap the puck rotation in `UIView.animate`:

```
// Pseudocode:
UIView.animate(withDuration: MapViewRepresentable.driveAnimationDuration,
               delay: 0,
               options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
    if let puckView = mapView.view(for: mapView.userLocation) {
        let currentAngle = atan2(puckView.transform.b, puckView.transform.a)
        let targetAngle = CGFloat(h * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: currentAngle, to: targetAngle)
        puckView.transform = puckView.transform.rotated(by: delta)
    }
}
```

`.beginFromCurrentState` is important: if the puck animation is already in flight from the previous GPS fix and a new fix arrives mid-animation, this option starts the new animation from wherever the view currently is, not from its pre-animation target. Combined with MKMapView's own `setCamera(animated: true)` retargeting, this produces fluid continuous animation rather than snap-restart.

`.allowUserInteraction` keeps the puck tappable during animation, consistent with other map annotations.

The engineer must implement `shortestArcDelta` as a pure static function (no `self`, no UIKit types, just `CGFloat` arithmetic) so it can be unit-tested independently.

**Puck rotation at Drive Mode entry:** `mapView(_:viewFor:)` sets the initial transform at line 1108 as `CGAffineTransform(rotationAngle: headingRad)`. This is correct for the initial render and does not need animation (the puck is appearing for the first time). No change needed there.

**Puck rotation at Drive Mode exit:** When `driveHeading` becomes nil, `syncDriveHeading` enters the `else` branch and resets the camera heading to 0. The puck's `transform` is not explicitly reset in the nil branch. When `endDriveMode()` is called, `ContentView` triggers `refreshUserLocationPuck` which toggles `showsUserLocation`, causing MapKit to re-query `mapView(_:viewFor:)`. At that point `parent.driveModeActive` is false, so the delegate returns `nil` and MapKit renders the default blue dot — the custom puck view is removed entirely. The stale `CGAffineTransform` on the old puck view is irrelevant. No change needed.

#### B.4 — Animate `syncDriveRegion` follow-recenter (lines 1064–1074)

Current code (Coordinator.syncDriveRegion, line 1073):
```swift
mapView.setCamera(camera, animated: false)
```

Change to:
```swift
mapView.setCamera(camera, animated: true)
```

Same analysis as B.2. This `setCamera` only changes `centerCoordinate` (pitch and heading are preserved from the camera copy). The resulting `regionWillChangeAnimated` / `regionDidChangeAnimated` cycle is the same as B.2 — no active gesture recognizer, `isUserInteracting` stays false, `onDrivePanDetected` is not triggered.

Note: `syncDriveRegion` is called from the else-branch of `shouldSyncRegionToBinding` inside `updateUIView` (lines 634–638). The threshold guard at lines 1066–1068 (`latDiff > 0.0001 || lngDiff > 0.0001`) ensures a recenter animation fires only when the map center has meaningfully diverged from the user's position. At typical GPS cadence (1 Hz) and 35 mph (~15.6 m/s), the center diverges by ~15.6 m/tick, which is well above the 0.0001° threshold (~11 m). The guard remains appropriate.

#### B.5 — Dead-band value decision (OQ-FT7-1)

Current dead-band: `guard diff > 5` at `syncDriveHeading` line 930.

**Recommendation: lower to 2°.** Rationale: with `animated: false`, a 3° update fired a visible camera jerk. With `animated: true`, a 3° update fires a ~0.3 s smooth rotation — visually unnoticeable. The dead-band's primary purpose is feedback-loop prevention (R-1), not visual smoothing. 2° is still safely above GPS course noise (typically ±0.5–1° at highway speed) and well above the animation-duration-based feedback-loop floor. A 2° dead-band means the camera heading will be within 2° of true course at all times, which is visually indistinguishable from 0° error at Drive Mode zoom levels.

If Kevin prefers to keep 5°, the spec is still valid — just note the dead-band value in the acceptance criteria update.

The dead-band check is in `syncDriveHeading` at lines 929–931. The engineer updates the constant and the related test file references (see A.6 above).

---

## 5. Duration and Cadence Justification

**Why 0.3 s?**

GPS fix cadence in automotive navigation mode (`kCLLocationAccuracyBestForNavigation`, `pausesLocationUpdatesAutomatically = false`) is approximately 1 Hz on iPhone hardware, occasionally 0.5 Hz in weak signal areas.

At 0.3 s animation duration and 1 Hz cadence, each animation completes with 0.7 s to spare before the next GPS fix triggers the next animation. There is no stacking or accumulation.

At 0.5 Hz cadence (weak signal), the interval is 2 s. A 0.3 s animation is even more comfortable.

**What if a GPS fix arrives mid-animation?**

MKMapView handles this correctly. Calling `setCamera(animated: true)` while a previous animated `setCamera` is still running cancels the in-flight animation and starts a new one from the camera's **current visual position** (not the animation's origin). This is built-in MapKit behavior and produces natural retargeting, like a navigation app smoothing a noisy GPS signal. There is no need to guard against this case in code.

For the puck `UIView.animate`, `.beginFromCurrentState` achieves the same effect: the new animation starts from wherever the puck currently is, not from the start of the previous animation.

**What about large heading jumps (turns)?**

On a left or right turn, the GPS course may change by 60–90° in one fix. With `animated: true`, MKMapView animates the 90° camera rotation over 0.3 s. This is fast but not jarring — at 0.3 s, a 90° rotation completes at 300°/s, which is noticeably but not excessively fast. The user is turning their car; the map turning quickly to match is the expected and appropriate behavior.

The shortest-arc fix for the puck (B.3) ensures that the puck does not spin 270° counter-clockwise on a 90° clockwise turn. A 90° clockwise turn is animated as 90° clockwise.

**Why not longer (0.5 s or 1.0 s)?**

At 0.5 s and 1 Hz GPS cadence, animations are back-to-back with no pause. At 1.0 s they would stack (animation starts while the previous is still 70% complete). With `.beginFromCurrentState` this is safe but produces a lag: the camera lags the user's actual position by up to one full second. At 35 mph that is ~15 m of positional lag, which is acceptable for heading rotation (it is a smooth lag, not a step) but potentially disorienting. 0.3 s produces ~5 m of lag, which is imperceptible.

**Tune point:** The `driveAnimationDuration` constant is annotated with a comment pointing Kevin to adjust post-drive-test. 0.5 s is the suggested alternative if 0.3 s feels too fast.

---

## 6. Acceptance Criteria

### Group 1 — Heading Source Pure Logic (unit tests in `FT7Tests.swift`)

**AC-FT7.1** — `selectDriveHeadingSource(course: 45.0, magnetometerHeading: 90.0, speed: 5.0, driveModeActive: true)` returns `45.0` (course chosen, magnetometer ignored while moving in Drive Mode).

**AC-FT7.2** — `selectDriveHeadingSource(course: nil, magnetometerHeading: 90.0, speed: 5.0, driveModeActive: true)` returns `nil` (no course available above speed gate → course-from-movement fallback will handle it inside `stabilizedHeading`; magnetometer still not returned).

**AC-FT7.3** — `selectDriveHeadingSource(course: 45.0, magnetometerHeading: 90.0, speed: 0.5, driveModeActive: true)` returns `nil` (stopped in Drive Mode → freeze-on-stop path; magnetometer not returned).

**AC-FT7.4** — After establishing `lastGoodHeading` via a moving tick, calling `stabilizedHeading(rawHeading: nil, speed: 0.5, current: coord)` returns the last good heading (freeze-on-stop preserved).

**AC-FT7.5** — `stabilizedHeading(rawHeading: nil, speed: 5.0, current: coord)` with a prior coordinate ~111 m to the south returns a heading of approximately 0° (course-from-movement fallback fires when course is nil above speed gate). Existing test `testStabilizedHeading_courseFromMovement_whenHeadingNil` (W85cTests.swift line 155) covers this and must still pass.

**AC-FT7.6** — The `didUpdateHeading` delegate method, when called with a magnetometer heading of 200° while `driveModeActiveInternal = true` and `driveSpeed = 10.0 m/s`, does NOT change `driveHeading`. (Test: inject a LocationService; call `stabilizedHeading(rawHeading: 90.0, speed: 10.0, current: coord)` to establish `headingEMA`; then call the magnetometer-gate logic directly and assert `driveHeading` is unchanged. Note: `didUpdateHeading` itself is a CLLocationManagerDelegate method and cannot be called directly in unit tests; the engineer should test the gate condition logic or extract it into a testable helper.)

### Group 2 — Shortest-Arc Rotation Helper (unit tests in `FT7Tests.swift`)

**AC-FT7.7** — `shortestArcDelta(from: 0, to: CGFloat(3° * pi/180))` returns approximately `+3° * pi/180` (forward small rotation, positive delta).

**AC-FT7.8** — `shortestArcDelta(from: CGFloat(359° * pi/180), to: CGFloat(1° * pi/180))` returns approximately `+2° * pi/180`, not `-358° * pi/180`. The long-way-around spin must not occur.

**AC-FT7.8b** — `shortestArcDelta(from: CGFloat(1° * pi/180), to: CGFloat(359° * pi/180))` returns approximately `-2° * pi/180` (counter-clockwise 2°, not clockwise 358°).

**AC-FT7.8c** — `shortestArcDelta(from: CGFloat(90° * pi/180), to: CGFloat(270° * pi/180))` returns `+pi` or `-pi` with absolute value == pi (180° — either direction is acceptable at exact halfway point; spec does not dictate the tiebreak).

### Group 3 — Dead-Band (unit tests update in `W85cTests.swift` and `DriveCameraTiltTests.swift`)

**AC-FT7.9-band** — The dead-band constant is 2° (or the value confirmed by OQ-FT7-1). `headingDiff(90.0, 91.5)` returns 1.5, which is below the threshold, and `syncDriveHeading` does not update `lastAppliedHeading`. `headingDiff(90.0, 93.0)` returns 3.0, which is above the threshold, and `syncDriveHeading` does update `lastAppliedHeading`. Update `testStabilizedHeading_deadBand_noMapUpdate_below5deg` in W85cTests.swift and `testHeadingDiff_below5degrees_shouldNotTriggerUpdate` in W85cTests.swift to reflect the new threshold.

### Group 4 — Region-Sync / Feedback-Loop Guard (existing tests must still pass)

**AC-FT7.10** — `RegionSyncGuardTests` (all four tests in `DriveCameraTiltTests.swift` lines 181–245) still pass. No change to `shouldSyncRegionToBinding` logic.

**AC-FT7.11** — No `setRegion` call on the Drive Mode active path. The `shouldSyncRegionToBinding(driveModeActive: true, ...)` gate returns `false` and the `setRegion` branch is not reached. Existing tests cover this.

### Group 5 — FT-5 Non-Interference

**AC-FT7.12** — An animated `syncDriveHeading` camera change does not set `isUserInteracting = true`. Verify by asserting: after `coordinator.syncDriveHeading(90.0, on: mapView)`, `coordinator.isUserInteracting == false`. (The `regionWillChangeAnimated` callback fires, but since no gesture recognizer is active, the `isUserGesture` check returns false.)

**AC-FT7.13** — An animated `syncDriveRegion` recenter does not trigger `onDrivePanDetected`. Verify by providing a non-nil `onDrivePanDetected` closure that sets a flag, calling `coordinator.syncDriveRegion(region, on: mapView)`, and asserting the flag is not set.

### Group 6 — No Regression

**AC-FT7.14** — Full test suite passes: 0 failures, count equal to or greater than the pre-FT7 baseline (currently 243 tests per the W8.5d row in HANDOFF.md).

**AC-FT7.15** — `DriveCameraTiltTests` all pass (including `testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped`).

**AC-FT7.16** — `W85cTests` all pass, with updated dead-band threshold comments.

**AC-FT7.17** — `DriveZoomStyleTests` all pass (no changes to zoom/style logic).

### Group 7 — Live-UI Smoke Gate (mandatory before merge)

**AC-FT7.18 (MANDATORY — blocks merge):** Build and launch the app in the simulator. Navigate to Drive Mode. Use `simctl location replay` with a simulated route (or manually fire repeated `simctl location set` calls at 1-second intervals along a known NYC block). Capture simulator screenshots or screen recording. Verify:

(a) The arrow puck does not point in a direction inconsistent with the simulated travel bearing. At simulated travel heading 0° (north), the arrow must point up. At simulated travel heading 90° (east), the arrow must point right. The magnetometer gate means the simulator (which has no magnetometer) will now use GPS course exclusively — the course-from-movement fallback handles the nil course case from `loc.course`. If `loc.course` is provided by the sim route, it should be used directly.

(b) The camera rotation is visually animated (smooth pan), not stepping. A screen recording or side-by-side before/after screenshot comparison is acceptable evidence.

(c) The toolbar (gear / find-me / find-car / clock / Drive button), ASP banner, and Park Until pill all still render. This is the #31 regression check. Take a screenshot showing these overlays with Drive Mode active.

**AC-FT7.19 (Kevin real-device gate):** Kevin's on-device drive-test is the final gate for visual smoothness and correct arrow heading. The simulator can verify the absence of the #31 regression and that the code path compiles and runs. Real heading-up rotation correctness and animation feel can only be verified on real hardware with a mounted phone and GPS. This gate is explicitly acknowledged as irreducible per the pattern established in W8.5c-polish PR-3 notes in HANDOFF.md.

---

## 7. Out of Scope Follow-ups

**FT-7 Phase 2 — Display-link interpolation.** Full 60 fps interpolation between GPS fixes: a `CADisplayLink` timer that extrapolates `driveHeading` forward between fixes using the last-known angular velocity. This would eliminate all visible stepping even at 0.5 Hz GPS cadence. Deferred because it requires maintaining angular velocity state, handling the non-uniform GPS fix interval, and careful anti-windup logic (don't keep rotating if fixes stop coming). Estimated 1–2 additional sessions. Worth doing post-drive-test once the current fix is calibrated on real hardware.

**FT-7 Phase 2 — Street-bearing snap.** Snap `driveHeading` to the nearest one-way street bearing to eliminate GPS course wobble on straight blocks. The bearing data is already in the tile segments. Requires identifying the current segment (already done in `DrivingContextService`), extracting its bearing, and blending it with GPS course at a tunable weight. Deferred pending drive-test to understand whether GPS course wobble is a real problem post-EMA-smoothing.

**EMA alpha calibration.** After the drive-test, Kevin may find the EMA is too aggressive (heading lags turns visibly) or not aggressive enough (heading still wobbles on straight roads). The `DRIVING_HEADING_EMA_ALPHA = 0.35` constant in `LocationService.swift` line 31 is the single tuning knob. This is a one-line change post-drive-test.

**W8.5c `headlessWindow` test-infrastructure guard.** The accepted tech-debt note from W8.5c-polish in HANDOFF.md documents a `headlessWindow` guard in `syncDriveCamera` that should eventually be removed by restructuring those tests. Not touched here. Address in a future cleanup PR.

---

## 8. Implementation Checklist (for `@ios-engineer`)

Use this as a PR description checklist:

- [ ] `selectDriveHeadingSource` pure static function added and placed in a location visible to tests
- [ ] `didUpdateHeading` gate added (A.3) or `startUpdatingHeading` removed (A.4 per OQ-FT7-2)
- [ ] `driveAnimationDuration` constant added to `MapViewRepresentable`
- [ ] `syncDriveHeading` camera `setCamera` changed to `animated: true` (exit path stays `animated: false`)
- [ ] `shortestArcDelta` pure static helper added to `MapViewRepresentable`
- [ ] Puck `CGAffineTransform` wrapped in `UIView.animate` with shortest-arc delta
- [ ] `syncDriveRegion` `setCamera` changed to `animated: true`
- [ ] Dead-band updated to 2° (or OQ-FT7-1 confirmed value)
- [ ] `FT7Tests.swift` created with AC-FT7.1–AC-FT7.8c
- [ ] `W85cTests.swift` dead-band references updated (3 locations)
- [ ] All existing tests pass
- [ ] Live-UI smoke (AC-FT7.18) screenshot/recording captured and included in PR description
- [ ] `docs/ft7-drive-mode-smoothness-heading-spec.md` referenced in PR description
- [ ] NOT touched: `project.pbxproj`, `Info.plist`, `Config.xcconfig*`, any non-Drive-Mode path

---

## 9. Files Referenced by Line Number

All line numbers are from the state of `main` as of commit `d25ccbe` (TF1 shipped).

| Symbol | File | Lines |
|---|---|---|
| `didUpdateLocations` | `LocationService.swift` | 294–321 |
| `didUpdateHeading` | `LocationService.swift` | 323–342 |
| `stabilizedHeading` | `LocationService.swift` | 192–234 |
| `DRIVING_HEADING_MIN_SPEED_MPS` | `LocationService.swift` | 30 |
| `DRIVING_HEADING_EMA_ALPHA` | `LocationService.swift` | 31 |
| `startDriveMode` | `LocationService.swift` | 119–140 |
| `headingDiff` | `MapViewRepresentable.swift` | 412–415 |
| `shouldSyncRegionToBinding` | `MapViewRepresentable.swift` | 443–444 |
| `syncDriveHeading` | `MapViewRepresentable.swift` | 925–951 |
| `syncDriveRegion` | `MapViewRepresentable.swift` | 1064–1074 |
| `regionWillChangeAnimated` | `MapViewRepresentable.swift` | 1270–1295 |
| `regionDidChangeAnimated` | `MapViewRepresentable.swift` | 1297–1313 |
| `driveModePitch` | `MapViewRepresentable.swift` | 214 |
| `driveModeCameraSpan` | `MapViewRepresentable.swift` | 222 |
| Dead-band guard | `MapViewRepresentable.swift` | 929–931 |
| Puck transform (instant) | `MapViewRepresentable.swift` | 940–942 |
| `EMAStabilizerTests` | `W85cTests.swift` | 64–176 |
| Dead-band test | `W85cTests.swift` | 171–175 |
| `HeadingUpRotationTests` | `W85cTests.swift` | 816–943 |
| `RegionSyncGuardTests` | `DriveCameraTiltTests.swift` | 181–245 |

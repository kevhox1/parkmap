# FT-7/8/10 — Drive Mode Camera & Interaction

**Spec version:** 2.0 (supersedes v1.0 FT-7-only)  
**Date:** 2026-06-08  
**Author:** Tech Lead / Planner  
**Status:** Ready for implementation  
**Agent owner:** `@ios-engineer`  
**Related:** `docs/w8.5c-drive-mode-active-spec.md`, `docs/w8.5c-polish-pr3-spec.md`, `docs/w8.5c-polish-pr2-spec.md`, #31-regression class  
**v1.0 scope preserved:** All FT-7 content below is unchanged from v1.0. FT-8 and FT-10 are additive.

---

## Open Decisions — Kevin Must Confirm Before Code Starts

**OQ-FT7-1 (Dead-band value).** Spec recommends lowering from 5° to 2°. With animated camera transitions the feedback-loop risk of a lower threshold is substantially reduced. Confirm: 2°, keep 5°, or another value? If Kevin has no opinion, ship 2°.

**OQ-FT7-2 (startUpdatingHeading in Drive Mode).** Spec recommends calling `stopUpdatingHeading()` entirely during Drive Mode (option i in §4.A). The side effect is that `mapView.showsCompass` will not show a live heading indicator, but the arrow puck already provides that signal. Confirm acceptable.

**OQ-FT7-3 (Animation duration).** Spec recommends 0.3 s for all three animation sites. Engineer ships 0.3 s and annotates the constant; Kevin tunes post-drive-test. 0.5 s is the suggested fallback if 0.3 s feels abrupt.

**OQ-FT8-1 (Drive zoom tightening).** Spec recommends `driveModeCameraSpan` = 0.003° (altitude ~621 m, roughly the current block) as the primary target, with 0.0025° (~518 m) as the tighter alternative. Kevin will fine-tune on-device. The constant is annotated for easy tuning. Confirm: 0.003°, 0.0025°, or another value? If Kevin has no opinion, ship 0.003° and tune after drive-test.

**OQ-FT10-1 (Follow-pause property name).** The new bool that gates `syncDriveRegion` needs to be threaded through `MapViewRepresentable`'s initializer. Spec proposes `driveFollowEnabled: Bool` (matching the existing ContentView state var name) as a new parameter on `MapViewRepresentable`. Confirm: acceptable, or use a different name?

---

## 1. Problem and User Story

### FT-7: Askew arrow and jerky follow

**Symptom A — Askew arrow.** The directional puck arrow in Drive Mode does not point along the road. On a straight block heading north the arrow may read 30–50° east of north because the phone is sitting at an angle in a cup holder. The arrow reflects where the phone is physically pointing (magnetometer), not where the car is traveling (GPS course).

**Symptom B — Jerky follow.** The map camera and puck rotation both step in discrete visible jumps at approximately 1 Hz GPS cadence. Between GPS fixes the camera is motionless; on each fix it teleports to the new heading and position with no animation. At 35 mph this produces an uncanny, video-game-like feel.

### FT-8: Default drive/cruise zoom too wide

**Symptom C — Too many streets visible.** The Drive/Cruise Mode camera shows ~1–2 Manhattan blocks at `driveModeCameraSpan = 0.005°` (~1,036 m altitude), which was calibrated at the PR-2 zoom. Field-testing reveals the camera is still too wide — the user sees several surrounding streets rather than being focused on the current block. A tighter span (~0.003°, altitude ~621 m) would better match the "current block" UX intent without the app feeling zoomed so far in that cross-street context is lost.

### FT-10: Drive/Cruise mode locks the map

**Symptom D — Cannot zoom or pan.** While in Drive/Cruise mode the user cannot zoom in or pan away from their current position. Pinch-zoom does nothing visible because `syncDriveRegion` fires on every `updateUIView` and re-centers the camera even when the user is trying to look ahead. This makes the app feel locked. Waze and Apple Maps both let users zoom or pan while driving and show a "Re-center" button to return to follow mode.

**Root cause identified.** The existing `driveFollowEnabled` flag in ContentView correctly sets to `false` when the user pans (via `onDrivePanDetected` → `handleDrivePanDetected`), but this flag is not passed into `MapViewRepresentable`. The `else` branch of `shouldSyncRegionToBinding` at `MapViewRepresentable.swift:634–638` calls `syncDriveRegion` unconditionally whenever `driveModeActive == true`, regardless of whether follow is paused. Every `updateUIView` therefore re-centers the camera, counteracting the user's gesture and making the map feel locked.

**User story (unified):**  
*As a driver using Drive Mode with a cup-holder-mounted iPhone, I want the arrow puck to point in the direction I am actually driving, the map to pan and rotate fluidly, the camera to focus tightly on my current block, and I want to be able to zoom or pan the map while driving without the camera snapping back — with a "Re-center" button to resume follow mode — so the app feels like Apple Maps or Waze, not a slideshow.*

---

## 2. Scope — In / Out

### In scope

**FT-7 (heading source + animation):**
- Change the heading source fed to `driveHeading` from the magnetometer-dominant path to GPS course only while moving.
- Animate `syncDriveHeading` camera rotation (0.3 s).
- Animate puck `CGAffineTransform` rotation with shortest-angular-path handling.
- Animate `syncDriveRegion` follow-recentering (0.3 s).
- Lower heading dead-band from 5° to 2° (conditional on OQ-FT7-1).
- Add pure-logic heading-source-selection function and unit tests.
- Add shortest-arc rotation helper and its unit test.
- Verify all existing tests still pass.

**FT-8 (default drive zoom):**
- Lower `driveModeCameraSpan` from `0.005°` to `0.003°` (pending OQ-FT8-1).
- Document the resulting altitude via `altitudeForSpan()` formula.
- Annotate the constant for Kevin's on-device fine-tuning.
- Update `DriveZoomStyleTests` expectations that reference the old constant value.
- Confirm the new span flows through `applyDriveCameraState` / `centerCoordinateDistance`.

**FT-10 (gesture-pause follow + Re-center):**
- Add `driveFollowEnabled: Bool` as a new property on `MapViewRepresentable` (passed from ContentView).
- Gate `syncDriveRegion` on `driveFollowEnabled` so it does not re-center when follow is paused.
- Ensure both pan AND pinch-zoom gestures pause follow (both already detected via `isUserGesture` check in `regionWillChangeAnimated`; `onDrivePanDetected` closure name is preserved but semantically covers both gesture types — no rename required).
- The existing Re-center button (`ContentView:1337–1350`) and `recenterDriveMode()` function are already correct; the only missing link is the `syncDriveRegion` gate.
- Re-center resumes follow: `driveFollowEnabled = true`, recenters with FT-7 animation, restores heading-up + FT-8 drive zoom.
- Update `shouldSyncRegionToBinding` signature to accept `driveFollowEnabled` (or gate `syncDriveRegion` inline without changing the existing pure function — see §4.C for the preferred approach).

### Out of scope (deferred)

- **Display-link interpolation.** Full 60-fps interpolation between GPS fixes via `CADisplayLink`. Deferred — requires maintaining angular velocity state. See §7 follow-ups.
- **Street-bearing / one-way snap.** Snapping the arrow to the nearest one-way street bearing. Deferred pending real-device drive-test.
- **EMA alpha re-tuning.** `DRIVING_HEADING_EMA_ALPHA = 0.35` unchanged. Post-drive-test calibration.
- **onDrivePanDetected rename.** The closure is semantically misnamed (it detects both pan and pinch) but renaming touches ContentView's parameter label and is cosmetic. Deferred.
- **Magnetometer use cases outside Drive Mode.** Unchanged.

---

## 3. Architecture

### Codebase touch points

iOS only. No PWA, no backend changes.

| File | FT | Change |
|---|---|---|
| `ios/WePark/WePark/Services/LocationService.swift` | 7 | Stop feeding `didUpdateHeading` into `driveHeading` while moving; optionally stop `startUpdatingHeading` in Drive Mode |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | 7, 8, 10 | Animate `syncDriveHeading`, puck transform, `syncDriveRegion`; lower dead-band; lower `driveModeCameraSpan`; add `driveFollowEnabled` property; gate `syncDriveRegion` on it |
| `ios/WePark/WePark/ContentView.swift` | 10 | Pass `driveFollowEnabled` state into `MapViewRepresentable` initializer |
| `ios/WePark/WePark/Services/Constants.swift` | 8 | No change needed — `drivingZoomMeters` is only used by `recenterDriveMap` non-drive-mode zoom; `driveModeCameraSpan` is the Drive Mode constant and lives in `MapViewRepresentable.swift` |
| `ios/WePark/WeParkTests/FT7Tests.swift` | 7 | New test file: heading-source pure-logic tests, shortest-arc helper test |
| `ios/WePark/WeParkTests/FT8Tests.swift` | 8 | New test file: zoom altitude tests for the new span value |
| `ios/WePark/WeParkTests/FT10Tests.swift` | 10 | New test file: follow-pause state machine tests |
| `ios/WePark/WeParkTests/W85cTests.swift` | 7 | Update dead-band threshold comments/assertions (3 locations) |
| `ios/WePark/WeParkTests/DriveZoomStyleTests.swift` | 8 | Update span constant expectations after `driveModeCameraSpan` changes |

### Data flow — FT-7 heading source

**Current (broken):**
```
didUpdateLocations → loc.course → stabilizedHeading(rawHeading: course) → headingEMA → driveHeading
didUpdateHeading  → trueHeading → stabilizedHeading(rawHeading: magHeading) → headingEMA → driveHeading
                                                   ^--- BOTH paths write headingEMA simultaneously
```

GPS course (~1 Hz) and magnetometer (~10 Hz) alternate writes to `headingEMA`. The magnetometer fires far more frequently, so it dominates even when GPS course is available. Since the magnetometer reflects phone-mount angle (not travel direction), the puck arrow is askew.

**Target:**
```
didUpdateLocations → loc.course → stabilizedHeading(rawHeading: course) → headingEMA → driveHeading
didUpdateHeading   → [ignored while driveModeActiveInternal && speed >= gate]
```

### Animation data flow — FT-7

**Current (jerky):**
```
GPS fix (1 Hz) → driveHeading published → updateUIView → syncDriveHeading:
    setCamera(animated: false)                    ← instant teleport
    view.transform = CGAffineTransform(...)       ← instant teleport
syncDriveRegion:
    setCamera(animated: false)                    ← instant teleport
```

**Target (smooth):**
```
GPS fix (1 Hz) → driveHeading published → updateUIView → syncDriveHeading:
    setCamera(animated: true, duration: ~0.3s)    ← smooth ease
    UIView.animate(duration: 0.3s):
        view.transform = CGAffineTransform(shortestArc)   ← smooth ease, correct arc
syncDriveRegion (when driveFollowEnabled):
    setCamera(animated: true, duration: ~0.3s)    ← smooth ease
```

### Data flow — FT-8 zoom

The `driveModeCameraSpan` constant flows through `applyDriveCameraState` via `altitudeForSpan(driveModeCameraSpan)` → `camera.centerCoordinateDistance`. Lowering the span reduces the altitude, tightening the zoom. No structural changes to `applyDriveCameraState` are needed — just the constant value.

**Altitude computation (using `altitudeForSpan` formula: `halfHeightMeters / tan(15°)`):**

| Span | Half-height (m) | Altitude (m) | Context |
|---|---|---|---|
| 0.005° (current) | 277.5 | ~1,036 | 1–2 blocks — too wide (FT-8 complaint) |
| 0.003° (proposed default) | 166.5 | ~621 | ~1 block — focused on current street |
| 0.0025° (tighter alternative) | 138.75 | ~518 | Current block fills screen |
| 0.002° (very tight) | 111 | ~414 | Only the current block, no cross-street context |

Recommendation: ship 0.003°. Annotate the constant clearly for Kevin's on-device tuning. Kevin may bump to 0.0025° after the drive-test.

**Test impact.** `DriveZoomStyleTests.testAltitudeForSpan_driveMode_returnsPositiveAltitude` (DriveZoomStyleTests.swift line 85) calls `altitudeForSpan(driveModeCameraSpan)` and asserts the result is positive — this test still passes regardless of the constant value. `testTargetSpan_onEntry_returnsDriveModeCameraSpan` (line 56) asserts the returned value equals `driveModeCameraSpan` with accuracy 0.0001 — still passes because it compares against the same constant. No DriveZoomStyleTests assertions hard-code 0.005 by value; the tests compare against the constant. **No DriveZoomStyleTests expectations need updating when only the constant value changes.**

### Data flow — FT-10 follow-pause

**Current (broken — map feels locked):**
```
User pinch or pan gesture → regionWillChangeAnimated → isUserGesture=true
                          → isUserInteracting = true
                          → onDrivePanDetected fires → handleDrivePanDetected → driveFollowEnabled = false

Next updateUIView (triggered by any SwiftUI re-render or GPS fix):
    shouldSyncRegionToBinding(driveModeActive:true, ...) → false
    → ALWAYS calls syncDriveRegion(region, on: mapView)   ← BUG: ignores driveFollowEnabled
    → camera snaps back to user position
```

`driveFollowEnabled = false` in ContentView correctly hides the Re-center button but does not suppress `syncDriveRegion`. Every `updateUIView` snap-back counteracts the user's gesture, making zoom/pan feel inoperable.

**Target (correct):**
```
User pinch or pan gesture → same path → driveFollowEnabled = false

Next updateUIView:
    shouldSyncRegionToBinding(driveModeActive:true, ...) → false
    → syncDriveRegion guarded: if parent.driveFollowEnabled { syncDriveRegion(region, on: mapView) }
    → when false: NO recenter, camera stays where user left it

User taps Re-center:
    recenterDriveMode() → driveFollowEnabled = true → recenterDriveMap(on: loc)
    → region binding updates → next updateUIView → syncDriveRegion fires → smooth animated recenter
    → heading-up and FT-8 drive zoom already in effect (they are set at Drive Mode entry, not per-recenter)
```

**Reconciliation with FT-5 `isUserInteracting`.**  
`isUserInteracting` (Coordinator) and `driveFollowEnabled` (ContentView @State) are separate signals with separate purposes:

- `isUserInteracting` is a gesture-in-flight flag. It is `true` only for the duration of an active gesture (set in `regionWillChangeAnimated`, cleared in `regionDidChangeAnimated`). Its purpose is to suppress `setRegion` snap-back during an active pan in non-Drive-Mode (FT-5).
- `driveFollowEnabled` is a sticky follow-mode flag. It stays `false` after the gesture ends, until the user explicitly taps Re-center. It gates whether `syncDriveRegion` should recenter.

They must stay separate. `isUserInteracting` already handles the active-gesture snap-back for non-Drive-Mode (FT-5). `driveFollowEnabled` handles the Drive-Mode pause-until-explicit-recenter pattern. Merging them would require threading `driveFollowEnabled` into the Coordinator (UIKit layer), which is an unnecessary coupling.

**No conflict path.** During a Drive Mode gesture:
1. `regionWillChangeAnimated` fires → `isUserInteracting = true` (FT-5 guard active) AND `onDrivePanDetected` fires → `driveFollowEnabled = false` (FT-10 pause active).
2. `regionDidChangeAnimated` fires → `isUserInteracting = false` (FT-5 guard clears). `driveFollowEnabled` stays `false`.
3. Next `updateUIView`: `shouldSyncRegionToBinding` returns `false` (driveModeActive=true) → go to the else branch. `driveFollowEnabled == false` → `syncDriveRegion` is skipped. Camera stays put. Re-center button visible.

**Programmatic animated follow-recenter (FT-7) cannot falsely pause follow.** The FT-7 animated `setCamera` in `syncDriveRegion` fires `regionWillChangeAnimated`. The `isUserGesture` check in `regionWillChangeAnimated` finds no active gesture recognizer → `isUserGesture = false` → `onDrivePanDetected` is not called → `driveFollowEnabled` stays `true`. The animated recenter is not mistaken for a user gesture.

---

## 4. Work Streams

Single agent (`@ios-engineer`). All three FTs touch `MapViewRepresentable.swift`; they must ship in one PR to avoid merge conflicts and ensure no inconsistency between the follow-pause and animation changes. Recommended commit sequence within the PR: Part A (heading source) → Part C (FT-10 follow-pause fix, since it touches `syncDriveRegion` structurally) → Part B (FT-7 animations, which build on the corrected `syncDriveRegion`) → Part D (FT-8 zoom constant).

### Part A — Heading source change (`LocationService.swift`)

**Owner:** `@ios-engineer`

This section is unchanged from v1.0. Summarized:

#### A.1 — Introduce `driveHeadingSource` pure-logic function

Add a pure static function `selectDriveHeadingSource(course:magnetometerHeading:speed:driveModeActive:) -> Double?` outside any type at the top of `LocationService.swift` or in a small adjacent file. Four branches (unit-testable):

1. Moving in Drive Mode (`driveModeActive && speed >= DRIVING_HEADING_MIN_SPEED_MPS`): return `course` (magnetometer not returned).
2. Stopped in Drive Mode (`driveModeActive && speed < DRIVING_HEADING_MIN_SPEED_MPS`): return `nil` (freeze-on-stop path).
3. Not in Drive Mode, magnetometer available: return `magnetometerHeading`.
4. Not in Drive Mode, no magnetometer: return `nil`.

#### A.2 — No change to `didUpdateLocations`

Current `didUpdateLocations` lines 294–321 already passes `loc.course` correctly.

#### A.3 — Gate `didUpdateHeading` (lines 323–342)

Inside `didUpdateHeading`, after the existing guard: if `driveModeActiveInternal && (driveSpeed ?? 0) >= DRIVING_HEADING_MIN_SPEED_MPS`, return immediately. This is the root-cause fix.

#### A.4 — Consider stopping `startUpdatingHeading` in Drive Mode (OQ-FT7-2)

If Kevin confirms OQ-FT7-2: `startDriveMode()` does not call `manager.startUpdatingHeading()`, `endDriveMode()` does not call `manager.stopUpdatingHeading()`. The A.3 gate becomes moot. Side effect: `mapView.showsCompass` is stale during Drive Mode (acceptable since the puck provides heading signal).

#### A.5 — EMA alpha

Keep `DRIVING_HEADING_EMA_ALPHA = 0.35` unchanged. Post-drive-test calibration.

#### A.6 — W8.5c test impact

`EMAStabilizerTests` are unaffected. If dead-band changes to 2°, three test names/comments in `W85cTests.swift` need updating (lines 171, 818, 908). The assertions themselves still pass at the test input values (diffs of 0° and 2° fall at or below the strict `> 2` guard).

---

### Part B — Animation change (`MapViewRepresentable.swift`)

**Owner:** `@ios-engineer`

This section is unchanged from v1.0. Summarized:

#### B.1 — `driveAnimationDuration` constant

Add `static let driveAnimationDuration: TimeInterval = 0.3` alongside `driveModePitch` and `driveModeCameraSpan` (after line 222). Annotate with a tune-point comment for Kevin.

#### B.2 — Animate `syncDriveHeading` camera rotation (line 935)

Change `mapView.setCamera(camera, animated: false)` to `animated: true` in the heading-update branch. Keep `animated: false` in the Drive Mode exit branch (line 949). The programmatic animated `setCamera` fires `regionWillChangeAnimated` with no active gesture recognizer → `isUserInteracting` stays false → `onDrivePanDetected` not called → `driveFollowEnabled` unaffected.

#### B.3 — Animate puck rotation with shortest-arc (lines 940–942)

Add `static func shortestArcDelta(from:to:) -> CGFloat` pure static helper. Wrap puck transform update in `UIView.animate(duration: driveAnimationDuration, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState])` using `.rotated(by: delta)` rather than replacing the transform with an absolute angle.

#### B.4 — Animate `syncDriveRegion` follow-recenter (line 1073)

Change `mapView.setCamera(camera, animated: false)` to `animated: true`. This applies only when `driveFollowEnabled == true` (see Part C below — the guard comes before this call).

#### B.5 — Dead-band value decision (OQ-FT7-1)

Recommend: lower from `guard diff > 5` (line 930) to `guard diff > 2`. With animated transitions the feedback-loop risk is substantially reduced. 2° is above GPS noise (~0.5–1° at highway speed). Update three test names/comments in `W85cTests.swift`.

---

### Part C — Follow-pause gate (FT-10, `MapViewRepresentable.swift` + `ContentView.swift`)

**Owner:** `@ios-engineer`

This is the primary FT-10 change. It is architecturally simple — one new property, one guard — but it is the root cause fix for the "locked map" symptom.

#### C.1 — Add `driveFollowEnabled` property to `MapViewRepresentable`

Add alongside `driveModeActive` and `onDrivePanDetected` (around line 198):

```
// FT-10: Whether Drive Mode follow is currently active.
// ContentView sets this to false when onDrivePanDetected fires, and true on Re-center.
// When false, syncDriveRegion must NOT recenter — the user has manually panned/zoomed.
var driveFollowEnabled: Bool = true
```

This property is a pure SwiftUI binding pass-through (same pattern as `driveModeActive`). It carries no internal state.

#### C.2 — Gate `syncDriveRegion` on `driveFollowEnabled` (`updateUIView` else branch, lines 634–638)

Current code:
```
} else {
    context.coordinator.syncDriveRegion(region, on: mapView)
}
```

Change to:
```
} else if driveFollowEnabled {
    context.coordinator.syncDriveRegion(region, on: mapView)
}
// When driveFollowEnabled == false: Drive Mode is active but follow is paused.
// The user has manually panned/zoomed. syncDriveRegion is suppressed until Re-center tapped.
```

This is the one-line fix that resolves the "locked map" symptom. No changes to `shouldSyncRegionToBinding`, `syncDriveRegion` implementation, or the Coordinator's `isUserInteracting` flag.

**Why not add `driveFollowEnabled` to `shouldSyncRegionToBinding`?** The existing `shouldSyncRegionToBinding` pure function is referenced by two test classes and serves a narrower contract: it gates the `setRegion` path. The `driveFollowEnabled` gate is semantically different — it gates the `syncDriveRegion` path. Keeping them separate preserves test isolation and avoids changing the `RegionSyncGuardTests` contract.

#### C.3 — Thread `driveFollowEnabled` through `MapViewRepresentable` initializer in `ContentView.swift`

The `mapRepresentable` computed property at `ContentView.swift:1064–1083` constructs `MapViewRepresentable`. Add `driveFollowEnabled: driveFollowEnabled` to the initializer call (alongside the existing 12 parameters). The `driveFollowEnabled` `@State` var already exists at `ContentView.swift:368`.

#### C.4 — Re-center resumes follow with FT-7 animation + FT-8 zoom + heading-up

`recenterDriveMode()` at `ContentView.swift:1489–1494` already sets `driveFollowEnabled = true` then calls `recenterDriveMap(on: loc)`. `recenterDriveMap` updates the `region` binding, which triggers `updateUIView`, which with `driveFollowEnabled == true` calls `syncDriveRegion`. With the FT-7 animation change in Part B, that `setCamera` is now animated. The FT-8 drive zoom (set via `applyDriveCameraState` at Drive Mode entry) is already in effect on the camera — it is not reset by a pan/zoom gesture, only by Drive Mode exit. The heading-up rotation is maintained by `syncDriveHeading` on the next GPS fix. No additional changes to `recenterDriveMode()` or `recenterDriveMap()` are needed.

**What about the `region` binding during pause?** When the user pans or zooms while follow is paused, the `region` SwiftUI binding does NOT update — it still holds the user's last GPS position (set by the last `recenterDriveMap` call). The `mapView.region` (UIKit state) diverges from the `region` binding during the pause. When Re-center is tapped, `recenterDriveMap` writes the current GPS location to `region`, the binding update triggers `updateUIView`, and `syncDriveRegion` fires to reconcile the map camera. This is the correct and simple behavior — no special handling needed for the stale binding during pause.

#### C.5 — Pinch-zoom already triggers follow pause

`UIPinchGestureRecognizer` is in `mapView.gestureRecognizers` (added by UIKit automatically when `isZoomEnabled = true`, which is the default and is not disabled in `makeUIView`). The `isUserGesture` check in `regionWillChangeAnimated` at line 1280 checks `.began || .changed || .ended` across all gesture recognizers, including the pinch recognizer. A pinch-zoom therefore already sets `isUserGesture = true`, calls `onDrivePanDetected`, and sets `driveFollowEnabled = false`. No additional code is needed to handle pinch-zoom separately.

Confirm: `makeUIView` does not call `mapView.isZoomEnabled = false` anywhere. The grep for `isZoomEnabled` in `MapViewRepresentable.swift` returns no results. Pan (`isScrollEnabled`) is also default-true. The only gestures disabled at `makeUIView:451–452` are rotate and pitch. This is already the correct locked-interaction model for FT-10: rotate=off, pitch=off, zoom=on, pan=on.

---

### Part D — Drive zoom tightening (FT-8, `MapViewRepresentable.swift`)

**Owner:** `@ios-engineer`

#### D.1 — Lower `driveModeCameraSpan` constant (line 222)

Change:
```
static let driveModeCameraSpan: CLLocationDegrees = 0.005
```
To:
```
// FT-8: Tightened from 0.005° (~1,036m altitude) to 0.003° (~621m altitude).
// At 0.003°, the camera focuses on roughly one Manhattan block.
// Kevin: tune on-device — 0.0025° (~518m) if tighter, 0.004° if wider.
// Altitude computed via altitudeForSpan(_:): halfH = (span/2)*111,000 / tan(15°).
static let driveModeCameraSpan: CLLocationDegrees = 0.003
```

This change flows automatically through:
- `altitudeForSpan(driveModeCameraSpan)` called inside `applyDriveCameraState` (line 1008) → sets `camera.centerCoordinateDistance`.
- `targetSpan(forDriveModeActive:priorSpan:)` used in the zoom pure function.
- Re-center via `recenterDriveMap` uses `AppConstants.drivingZoomMeters = 300` (a different path — meters-based, not span-based). This creates a slight inconsistency: Re-center zooms to a ~300m-radius view, while Drive Mode entry zooms to the span-based ~621m altitude. The recenter zoom is somewhat tighter. This is acceptable behavior (Re-center gives a very close view; if it's too close Kevin can bump `drivingZoomMeters`). No code change needed.

#### D.2 — Verify `DriveZoomStyleTests` — no value-based assertions

As analyzed in §3, `DriveZoomStyleTests` compare against the constant, not a hardcoded float. All 13 tests still pass after the constant change. The engineer must verify this by running the test suite (part of the AC-FT8.4 regression check).

**New altitude assertion.** Add a test in `FT8Tests.swift` that asserts `altitudeForSpan(0.003)` is in the range `[550, 700]` m (using the formula with tolerance for FP precision). This confirms the engineering intent is captured as a test. See AC-FT8.2.

---

## 5. Duration and Cadence Justification (FT-7, unchanged from v1.0)

**Why 0.3 s?** GPS fix cadence in `kCLLocationAccuracyBestForNavigation` mode is approximately 1 Hz. At 0.3 s, each animation completes with 0.7 s to spare. At 0.5 Hz (weak signal), 2 s between fixes. No stacking.

**Mid-animation retargeting.** `setCamera(animated: true)` while a previous animated `setCamera` is running cancels in-flight and starts fresh from the current visual position — MapKit's built-in behavior. For the puck, `.beginFromCurrentState` achieves the same.

**Large heading jumps (turns).** 90° camera rotation animates at 300°/s over 0.3 s — fast but not jarring; the user is turning the car. Shortest-arc ensures the puck does not spin 270° the wrong way.

**Why not longer?** At 1.0 s, animations would stack. At 0.3 s the lag is ~5 m at 35 mph — imperceptible.

**Tune point.** `driveAnimationDuration` constant is annotated. 0.5 s is the fallback.

---

## 6. Acceptance Criteria

### Group 1 — FT-7: Heading Source Pure Logic (`FT7Tests.swift`)

**AC-FT7.1** — `selectDriveHeadingSource(course: 45.0, magnetometerHeading: 90.0, speed: 5.0, driveModeActive: true)` returns `45.0`.

**AC-FT7.2** — `selectDriveHeadingSource(course: nil, magnetometerHeading: 90.0, speed: 5.0, driveModeActive: true)` returns `nil`.

**AC-FT7.3** — `selectDriveHeadingSource(course: 45.0, magnetometerHeading: 90.0, speed: 0.5, driveModeActive: true)` returns `nil`.

**AC-FT7.4** — After establishing `lastGoodHeading` via a moving tick, calling `stabilizedHeading(rawHeading: nil, speed: 0.5, current: coord)` returns the last good heading (freeze-on-stop preserved).

**AC-FT7.5** — `stabilizedHeading(rawHeading: nil, speed: 5.0, current: coord)` with a prior coordinate ~111 m to the south returns heading approximately 0°. Existing test `testStabilizedHeading_courseFromMovement_whenHeadingNil` (W85cTests.swift line 155) must still pass.

**AC-FT7.6** — The `didUpdateHeading` gate: when called with a magnetometer heading of 200° while `driveModeActiveInternal = true` and `driveSpeed = 10.0 m/s`, `driveHeading` is not updated.

### Group 2 — FT-7: Shortest-Arc Rotation Helper (`FT7Tests.swift`)

**AC-FT7.7** — `shortestArcDelta(from: 0, to: CGFloat(3° * pi/180))` returns approximately `+3° * pi/180`.

**AC-FT7.8** — `shortestArcDelta(from: CGFloat(359° * pi/180), to: CGFloat(1° * pi/180))` returns approximately `+2° * pi/180` (not `-358° * pi/180`).

**AC-FT7.8b** — `shortestArcDelta(from: CGFloat(1° * pi/180), to: CGFloat(359° * pi/180))` returns approximately `-2° * pi/180`.

**AC-FT7.8c** — `shortestArcDelta(from: CGFloat(90° * pi/180), to: CGFloat(270° * pi/180))` returns absolute value pi (tiebreak direction not specified).

### Group 3 — FT-7: Dead-Band (`W85cTests.swift` + `DriveCameraTiltTests.swift`)

**AC-FT7.9-band** — Dead-band constant is 2° (or OQ-FT7-1 confirmed value). `headingDiff(90.0, 91.5)` = 1.5 (below threshold) → `syncDriveHeading` skips update. `headingDiff(90.0, 93.0)` = 3.0 (above threshold) → update fires. Update three test names/comments (W85cTests.swift lines 171, 818, 908).

### Group 4 — FT-8: Zoom Altitude (`FT8Tests.swift`)

**AC-FT8.1** — `MapViewRepresentable.driveModeCameraSpan` equals 0.003 (or OQ-FT8-1 confirmed value). Pure assertion on the constant.

**AC-FT8.2** — `MapViewRepresentable.altitudeForSpan(0.003)` is in the range [550, 700] m. Validates that the formula correctly computes altitude for the new span. (Formula: `(0.003/2 * 111,000) / tan(15°) ≈ 621 m`.)

**AC-FT8.3** — `MapViewRepresentable.altitudeForSpan(MapViewRepresentable.driveModeCameraSpan)` is strictly less than `MapViewRepresentable.altitudeForSpan(0.005)`. Confirms the new span produces a lower (tighter) altitude than the old one. This test remains valid regardless of which specific value Kevin tunes to.

**AC-FT8.4** — `DriveZoomStyleTests` all pass without modification (no value-based assertions on the span constant).

### Group 5 — FT-10: Follow-Pause State Machine (`FT10Tests.swift`)

These are pure-logic tests on a testable version of the gate condition. The engineer should extract the follow-pause gate logic into a static helper function analogous to `shouldSyncRegionToBinding`:

```
// Pseudocode:
static func shouldSyncDriveRegion(driveModeActive: Bool, driveFollowEnabled: Bool) -> Bool {
    driveModeActive && driveFollowEnabled
}
```

This function is directly unit-testable and makes the gate contract explicit.

**AC-FT10.1** — `shouldSyncDriveRegion(driveModeActive: true, driveFollowEnabled: true)` returns `true`.

**AC-FT10.2** — `shouldSyncDriveRegion(driveModeActive: true, driveFollowEnabled: false)` returns `false` (follow paused → no recenter).

**AC-FT10.3** — `shouldSyncDriveRegion(driveModeActive: false, driveFollowEnabled: true)` returns `false` (not in Drive Mode → non-drive path handles sync).

**AC-FT10.4** — `shouldSyncDriveRegion(driveModeActive: false, driveFollowEnabled: false)` returns `false`.

**AC-FT10.5** — An animated `syncDriveHeading` camera change does NOT call `onDrivePanDetected` and does NOT set `driveFollowEnabled = false`. Verify by providing a non-nil `onDrivePanDetected` closure that sets a flag; call `coordinator.syncDriveHeading(90.0, on: mapView)` while `driveFollowEnabled == true`; assert the flag is not set. (No active gesture recognizer → `isUserGesture = false` in `regionWillChangeAnimated` → `onDrivePanDetected` not called.)

**AC-FT10.6** — When `driveFollowEnabled == false` and `updateUIView` runs with `driveModeActive == true`, `syncDriveRegion` is NOT called. Verify by wrapping `syncDriveRegion` in a counted call (engineer's test infrastructure choice) or by asserting the camera center does not change after an `updateUIView`-equivalent call.

### Group 6 — FT-5 Non-Interference (existing + new)

**AC-FT7.12** — An animated `syncDriveHeading` camera change does not set `isUserInteracting = true`. After `coordinator.syncDriveHeading(90.0, on: mapView)`, `coordinator.isUserInteracting == false`.

**AC-FT7.13** — An animated `syncDriveRegion` recenter does not trigger `onDrivePanDetected`. Verified by non-nil closure flag assertion.

### Group 7 — Region Sync Guard (existing tests must still pass)

**AC-FT7.10** — `RegionSyncGuardTests` (DriveCameraTiltTests.swift lines 181–245) all pass. No changes to `shouldSyncRegionToBinding`.

**AC-FT7.11** — No `setRegion` on the Drive Mode active path. `shouldSyncRegionToBinding(driveModeActive: true, ...)` returns `false`. Existing tests cover this.

### Group 8 — No Regression

**AC-FT7.14** — Full test suite passes: 0 failures, count equal to or greater than 243 (pre-FT7/8/10 baseline).

**AC-FT7.15** — `DriveCameraTiltTests` all pass (including `testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped`).

**AC-FT7.16** — `W85cTests` all pass, with updated dead-band threshold comments.

**AC-FT7.17** — `DriveZoomStyleTests` all pass.

### Group 9 — Live-UI Smoke Gate (mandatory before merge)

**AC-SMOKE.1 (MANDATORY — blocks merge):** Build and launch in simulator. Navigate to Drive Mode. Use `simctl location replay` or repeated `simctl location set` at 1-second intervals along a simulated route. Verify:

(a) Arrow puck points in the direction of simulated travel. At heading 0° (north), arrow points up. At heading 90° (east), arrow points right.

(b) Camera rotation is visually animated (smooth pan), not stepping.

(c) The camera is noticeably tighter than before — the current block should fill most of the screen rather than showing 3–4 blocks in each direction.

(d) Pinch-zoom gesture changes the zoom level AND pauses follow (Re-center button appears).

(e) Pan gesture moves the camera AND pauses follow (Re-center button appears).

(f) While follow is paused, the camera does NOT snap back to the user's position on subsequent GPS fixes.

(g) Tapping Re-center: camera animates back to the user's position with heading-up and drive zoom.

(h) The toolbar (gear / find-me / find-car / clock / Drive button), ASP banner, and Park Until pill all still render. This is the #31 regression check. Screenshot required.

**AC-SMOKE.2 (Kevin real-device gate):** Kevin's on-device drive-test is the final gate for visual smoothness, correct arrow heading, tightened zoom feel, and zoom/pan usability while driving. Simulator verifies the absence of the #31 regression and that the code compiles and runs. Real heading-up rotation correctness, animation feel, and zoom tightness can only be verified on real hardware with a mounted phone. This gate is explicitly acknowledged as irreducible.

---

## 7. Out of Scope Follow-ups

**FT-7 Phase 2 — Display-link interpolation.** Full 60 fps interpolation between GPS fixes via `CADisplayLink`. Requires maintaining angular velocity state and non-uniform interval handling. Estimated 1–2 sessions. Worth doing post-drive-test.

**FT-7 Phase 2 — Street-bearing snap.** Snap `driveHeading` to the nearest one-way street bearing. Deferred pending drive-test to understand whether GPS course wobble is a real problem post-EMA-smoothing.

**EMA alpha calibration.** `DRIVING_HEADING_EMA_ALPHA = 0.35` at `LocationService.swift:31`. One-line post-drive-test.

**`onDrivePanDetected` rename.** The closure is triggered by both pan and pinch gestures; "Pan" is a misnomer. A future PR could rename to `onDriveUserGestureDetected` across ContentView and MapViewRepresentable.

**`recenterDriveMap` zoom vs. `driveModeCameraSpan` inconsistency.** `recenterDriveMap` uses `AppConstants.drivingZoomMeters = 300` (meters-based). Drive Mode entry zoom uses `driveModeCameraSpan` (span-based, ~621 m altitude at 0.003°). Effectively Re-center gives a slightly tighter zoom than Drive Mode entry. If Kevin finds this jarring post-drive-test, `recenterDriveMap` could be changed to use `altitudeForSpan(driveModeCameraSpan)` instead.

**W8.5c `headlessWindow` tech-debt.** Accepted note from HANDOFF.md. Not touched here.

---

## 8. Implementation Checklist (for `@ios-engineer`)

### FT-7: Heading Source

- [ ] `selectDriveHeadingSource` pure static function added and visible to tests
- [ ] `didUpdateHeading` gate added (A.3) or `startUpdatingHeading` removed (A.4 per OQ-FT7-2)
- [ ] `FT7Tests.swift` created with AC-FT7.1–AC-FT7.6

### FT-7: Animation

- [ ] `driveAnimationDuration` constant added to `MapViewRepresentable` (alongside `driveModePitch`, after line 222)
- [ ] `syncDriveHeading` camera `setCamera` changed to `animated: true` (exit path stays `animated: false`)
- [ ] `shortestArcDelta` pure static helper added to `MapViewRepresentable`
- [ ] Puck `CGAffineTransform` wrapped in `UIView.animate` with shortest-arc delta (AC-FT7.7–AC-FT7.8c)
- [ ] `syncDriveRegion` `setCamera` changed to `animated: true`
- [ ] Dead-band updated to 2° (or OQ-FT7-1 confirmed value) at line 930
- [ ] `W85cTests.swift` dead-band references updated (3 locations: lines 171, 818, 908)

### FT-8: Zoom

- [ ] `driveModeCameraSpan` lowered from 0.005 to 0.003 (or OQ-FT8-1 confirmed value) at line 222
- [ ] Constant annotated with tuning comment and altitude derivation
- [ ] `FT8Tests.swift` created with AC-FT8.1–AC-FT8.3
- [ ] `DriveZoomStyleTests` verified to still pass (no constant-value assertions)

### FT-10: Follow-Pause

- [ ] `driveFollowEnabled: Bool` property added to `MapViewRepresentable` (near line 198)
- [ ] `shouldSyncDriveRegion` pure static helper added (or inline gate equivalent)
- [ ] `syncDriveRegion` call in `updateUIView` (line 637) gated on `driveFollowEnabled`
- [ ] `driveFollowEnabled` threaded through `mapRepresentable` initializer in `ContentView.swift:1080`
- [ ] `FT10Tests.swift` created with AC-FT10.1–AC-FT10.6

### All FTs: Regression

- [ ] All existing tests pass
- [ ] Live-UI smoke (AC-SMOKE.1) screenshot/recording captured and included in PR description
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
| `driveModePitch` | `MapViewRepresentable.swift` | 214 |
| `driveModeCameraSpan` | `MapViewRepresentable.swift` | 222 |
| `altitudeForSpan` | `MapViewRepresentable.swift` | 260–268 |
| `targetSpan` | `MapViewRepresentable.swift` | 245–247 |
| `applyDriveCameraState` | `MapViewRepresentable.swift` | 991–1043 |
| `CoordinatorActions` | `MapViewRepresentable.swift` | 306–342 |
| `onDrivePanDetected` | `MapViewRepresentable.swift` | 198 |
| `driveModeActive` (property) | `MapViewRepresentable.swift` | 193 |
| `headingDiff` | `MapViewRepresentable.swift` | 412–415 |
| `shouldSyncRegionToBinding` | `MapViewRepresentable.swift` | 443–444 |
| `isRotateEnabled = false` | `MapViewRepresentable.swift` | 451 |
| `isPitchEnabled = false` | `MapViewRepresentable.swift` | 452 |
| `syncDriveHeading` | `MapViewRepresentable.swift` | 925–951 |
| Dead-band guard (`guard diff > 5`) | `MapViewRepresentable.swift` | 930 |
| Puck transform (instant, to animate) | `MapViewRepresentable.swift` | 940–942 |
| `syncDriveRegion` | `MapViewRepresentable.swift` | 1064–1074 |
| `syncDriveRegion` call in `updateUIView` | `MapViewRepresentable.swift` | 637 |
| `regionWillChangeAnimated` | `MapViewRepresentable.swift` | 1270–1295 |
| `isUserGesture` check | `MapViewRepresentable.swift` | 1280–1285 |
| `regionDidChangeAnimated` | `MapViewRepresentable.swift` | 1297–1313 |
| `driveFollowEnabled` (ContentView @State) | `ContentView.swift` | 368 |
| `handleDrivePanDetected` | `ContentView.swift` | 1039–1043 |
| `mapRepresentable` (initializer call) | `ContentView.swift` | 1064–1083 |
| `onDrivePanDetected` wire | `ContentView.swift` | 1080 |
| Re-center button render | `ContentView.swift` | 1337–1350 |
| `recenterDriveMode` | `ContentView.swift` | 1489–1494 |
| `recenterDriveMap` | `ContentView.swift` | 1497–1503 |
| `handleDriveModeChange` | `ContentView.swift` | 1582–1628 |
| Follow-mode recenter (location update) | `ContentView.swift` | 1704–1708 |
| `drivingZoomMeters` | `Constants.swift` | 84 |
| `EMAStabilizerTests` | `W85cTests.swift` | 64–176 |
| Dead-band test (5° ref) | `W85cTests.swift` | 171 |
| `HeadingUpRotationTests` | `W85cTests.swift` | 816–943 |
| Dead-band test (5° ref) | `W85cTests.swift` | 818 |
| Dead-band test (5° ref) | `W85cTests.swift` | 908 |
| `RegionSyncGuardTests` | `DriveCameraTiltTests.swift` | 181–245 |
| `DriveZoomStyleTests` class | `DriveZoomStyleTests.swift` | 47 |
| `testAltitudeForSpan_driveMode_returnsPositiveAltitude` | `DriveZoomStyleTests.swift` | 85 |
| `testTargetSpan_onEntry_returnsDriveModeCameraSpan` | `DriveZoomStyleTests.swift` | 56 |

# Native MapKit Map-Interaction Rebuild Spec

**Feature:** Native MapKit camera ownership — browse-mode liberation + Drive Mode native follow
**Owner:** @ios-engineer (Phase 1 PR, Phase 2 PR); @qa-verifier per phase
**Created:** 2026-06-08
**Status:** DRAFT — awaiting Kevin decisions on Open Questions 1–4 before Phase 2 begins

---

## Decisions Kevin Needs Before Code Starts

These are blocking for Phase 2. Phase 1 can start immediately.

**OQ-1 (BLOCKING Phase 2): Heading-mode choice.** Does Kevin accept "native `.follow` (position-only) + manual course heading" as the Drive Mode architecture, or does he want to evaluate `.followWithHeading` despite its compass-up limitation? The spec recommends the former. See §7 for the full analysis.

**OQ-2 (Phase 2 tuning): Recenter button threshold.** The current `MKUserTrackingModeNone` detection comes from the `mapView(_:didChange:animated:)` delegate callback. That callback is documented in iOS 17 but Kevin should confirm it fires reliably on real-device pan during Drive Mode before Phase 2 ships. Testable immediately once Phase 1 is on TestFlight.

**OQ-3 (Phase 2): Pitch/zoom during recenter.** When the Recenter button re-engages follow after a user pan, should the camera animate back to 45° pitch + 0.003° span, or silently re-follow from wherever pitch/zoom currently are? Recommended: restore drive defaults (better "back to nav mode" signal). Needs Kevin sign-off.

**OQ-4 (Phase 1 confirm): Compass visibility.** Enabling `isRotateEnabled = true` makes the map compass appear when the map is not north-up. Currently `mapView.showsCompass = true` is set (line 524). The standard iOS compass button auto-hides when north-up, which is correct behavior. Confirm Kevin is OK with compass appearing on rotate.

---

## 1. Problem and User Story

**The problem:** WePark's map browsing experience feels sluggish and constrained relative to Apple Maps because `isRotateEnabled = false` and `isPitchEnabled = false` are hardcoded at `MapViewRepresentable.swift:522–523`. Users cannot rotate or tilt. Additionally, the custom drive-follow system hand-rolls what MapKit does natively — with a `region` @State binding written back to the map in `updateUIView` (via `shouldSyncRegionToBinding` + `setRegion`), a manual `syncDriveRegion` recenter loop, and a bespoke pan-detection/pause circuit (`driveFollowEnabled`, `onDrivePanDetected`, `isUserInteracting`) — and it produces snapping and fighting that incremental patches FT-5, FT-7, FT-8, FT-10, TF2-1, and TF2-2 have partially ameliorated but not cured.

**User story:** "As a WePark user in browse mode, I want to freely rotate, tilt, pan, and zoom the map the same way I can in Apple Maps — without it snapping back. As a user in Drive Mode, I want the map to follow my car smoothly without fighting my hand when I pan away, and a single tap of Recenter to re-engage that follow — just like Apple Maps."

**Why now:** TF1 is live. The real-device drive-test is now the operative feedback loop. The non-frictionless browse and the snap-back follow are the most prominent UX gaps vs. Apple Maps class. This is the right moment to fix the root cause rather than add another patch.

---

## 2. Scope — In / Out

### Phase 1 (In)
- Enable `isRotateEnabled = true` and `isPitchEnabled = true` (two line changes in `makeUIView`).
- Stop writing the `region` binding to the map in browse mode (`setRegion` in `updateUIView`) except for explicitly user-initiated programmatic moves.
- Keep the `isUserInteracting` flag as the suppression gate but eliminate the entire `shouldSyncRegionToBinding` call to `setRegion` for all SwiftUI-driven (non-user-initiated) re-renders. The region binding becomes read-only (map → ContentView), not write-back.
- Specifically: `onRegionChanged` callback continues to fire so tile loading, ASP banner, and overlay culling keep working.
- Programmatic recenter (find-me button, find-my-car button, search-result centering, initial launch center) remains: these use `coordinatorActions` or write `region` intentionally from user-action handlers. These are explicitly user-initiated and must continue to work.
- Drive Mode is left AS-IS in Phase 1 — `syncDriveRegion`, `driveFollowEnabled`, `driveHeading`, `onDrivePanDetected` all untouched.
- Tests: update `RegionSyncGuardTests` to reflect the new simplified gate; FT-5/FT-10/FT-7/FT-8/DriveCameraTiltTests/DriveZoomStyleTests remain green unmodified.

### Phase 1 (Out / Deferred to Phase 2)
- `userTrackingMode` changes — any form of native follow.
- Replacement of `syncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`.
- Any change to `syncDriveHeading` or the `lastAppliedHeading` dead-band.
- Any change to `applyDriveCameraState` or `CoordinatorActions`.

### Phase 2 (In)
- Replace the hand-rolled drive-follow loop with MapKit native `userTrackingMode = .follow` (position follow, no compass rotation).
- Keep `syncDriveHeading` / `selectDriveHeadingSource` / EMA for course-up rotation (GPS course, not compass) — see §7.
- Implement the `mapView(_:didChange:animated:)` delegate callback to detect tracking-mode breaks (user pan) and show the Recenter button.
- Recenter button re-sets `userTrackingMode = .follow` and restores drive pitch + zoom.
- Remove: `syncDriveRegion`, `shouldSyncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`, the `recenterDriveMap(on:)` + `recenterDriveMode()` methods in ContentView, the manual location-update recenter block in `handleLocationUpdate`.
- Remove: `region` binding write in Drive Mode path entirely (including `recenterDriveMap`'s `region = MKCoordinateRegion(...)` assignment).
- Add: new `CoordinatorActions` closure `setDriveTrackingMode` called from `.onChange(of: driveModeActive)`.
- Pitch + zoom + map-style + puck logic via existing `applyDriveCameraState` path is preserved — no change to those.
- Recenter button wiring in `DriveModeBottomCard` / ContentView: unchanged in appearance; behavior changes from "write region binding" to "set userTrackingMode + restore pitch/zoom".

### Phase 2 (Out)
- Changing `driveModePitch` or `driveModeCameraSpan` constants.
- Any change to voice/commentary/context systems.
- PWA changes (PWA is maintenance mode).
- `@backend-data` changes.

---

## 3. Architecture

### Codebases touched
- **iOS only.** Files: `ios/WePark/WePark/Views/MapViewRepresentable.swift`, `ios/WePark/WePark/ContentView.swift`. Tests: `ios/WePark/WeParkTests/`.
- PWA: no changes.
- Backend: no changes.

### Current camera data flow (the problem)

```
ContentView @State region (MKCoordinateRegion)
    ↓ Binding write in updateUIView (shouldSyncRegionToBinding)
    → setRegion(_:animated:false) on every SwiftUI re-render (NOT user gesture)
    → camera snaps back to binding value during pan

Drive Mode:
    ContentView locationService.userLocation change
    → recenterDriveMap(on:) writes region binding
    → updateUIView fires → shouldSyncDriveRegion check
    → syncDriveRegion → camera.copy + setCamera
    → regionDidChangeAnimated → syncDriveHeading dead-band → setCamera again
    (multi-hop, race-prone)
```

### Target camera data flow (Phase 1)

```
ContentView @State region  ← READ-ONLY from map (regionDidChange → onRegionChanged → tile loading)
                           WRITTEN ONLY by explicit user-action handlers:
                               recenterMap(on:)  [find-me, find-car, search]
                               performLaunchSetup  [initial center]
                               handleDrivePanDetected-triggered recenter  [Phase 1: unchanged]

MKMapView camera owned by MapKit in browse mode.
isRotateEnabled = true, isPitchEnabled = true.
setRegion in updateUIView: REMOVED entirely (no conditional gate needed).
```

### Target camera data flow (Phase 2, Drive Mode)

```
Drive Mode entry:
    .onChange(of: driveModeActive) → handleDriveModeAndCamera(true)
        → handleDriveModeChange(true)  [unchanged: startDriveMode, voice, etc.]
        → handleDriveCameraChange(true)  [capture pitch/zoom/style, applyDriveCameraState]
        → NEW: coordinatorActions.setDriveTrackingMode?(true)
               → mapView.userTrackingMode = .follow  (smooth native position follow)

Location follow:
    MapKit CLLocationManager → MKMapView centers automatically (native follow, no GPS-tick recenter)
    locationService.driveHeading updates → driveHeading binding → updateUIView → syncDriveHeading
        → camera.heading = courseHeading, setCamera(animated:true)
        (heading is set manually on top of the native-follow center — they do not conflict,
         see §7 for the coupling analysis)

User pan in Drive Mode:
    MKMapView gesture → mapView(_:didChange:animated:) fires with mode = .none
        → DispatchQueue.main.async { onTrackingModeChanged?(.none) }
        → ContentView shows Recenter button (replaces driveFollowEnabled = false path)

Recenter button:
    coordinatorActions.setDriveTrackingMode?(true)
    → mapView.userTrackingMode = .follow
    → applyDriveCameraState(active:true, ...) to restore drive pitch + zoom
    → Recenter button hides (mapView(_:didChange:) fires with mode != .none)
```

### New/changed symbols

**Phase 1 — MapViewRepresentable.swift:**
- `makeUIView`: `isRotateEnabled = true`, `isPitchEnabled = true` (two lines changed).
- `updateUIView`: remove the `shouldSyncRegionToBinding` + `setRegion` block entirely (lines ~695–703). The `shouldSyncDriveRegion` + `syncDriveRegion` block is UNCHANGED (Phase 1 leaves Drive Mode as-is).
- `shouldSyncRegionToBinding` static function: **deleted** (no callers after the above).
- `RegionSyncGuardTests`: rewrite to replace `shouldSyncRegionToBinding` tests with a simpler check that `updateUIView` does not call `setRegion` at all in browse mode (see §5.1).

**Phase 1 — ContentView.swift:**
- `region` @State: remains. Still receives writes from `recenterMap(on:)`, `performLaunchSetup`, and `recenterDriveMap` (Drive Mode follow — Phase 1 unchanged).
- `handleRegionChanged(_:)` closure: remains, unchanged (reads region FROM map for tile loading).
- No removal of Drive Mode state in Phase 1.

**Phase 2 — MapViewRepresentable.swift:**
- Remove properties: `driveFollowEnabled`, `onDrivePanDetected`.
- Remove methods on Coordinator: `syncDriveRegion(_:on:)`.
- Remove static function: `shouldSyncDriveRegion(driveModeActive:driveFollowEnabled:isUserInteracting:)`.
- Remove `updateUIView` block: the `shouldSyncDriveRegion` + `syncDriveRegion` else-branch.
- Add to `CoordinatorActions`: `setDriveTrackingMode: ((Bool) -> Void)?` and `onTrackingModeChanged: ((MKUserTrackingMode) -> Void)?` (the latter is an OUTPUT: coordinator → ContentView, not ContentView → coordinator).
- Add `MKMapViewDelegate` method: `mapView(_:didChange:animated:)`.
- Existing `syncDriveHeading` and `applyDriveCameraState` are PRESERVED unchanged.

**Phase 2 — ContentView.swift:**
- Remove: `driveFollowEnabled` @State, `recenterDriveMode()`, `recenterDriveMap(on:)`, `handleDrivePanDetected` closure, `onDrivePanDetected` parameter in `mapRepresentable`.
- Remove: the `if driveFollowEnabled { recenterDriveMap(on: coord) }` block in `handleLocationUpdate`.
- Add: `onTrackingModeChanged` wired into `CoordinatorActions` at `makeUIView` time (or via a new `.onChange` pattern), which fires when MapKit breaks tracking on user pan → shows Recenter button.
- Recenter button's Drive Mode branch: calls `coordinatorActions.setDriveTrackingMode?(true)` + `coordinatorActions.applyDrivePitch?(true, preDrivePitch)` instead of setting `driveFollowEnabled = true` and writing `region`.

### Tables / RPCs / new files
None. This is a pure client-side camera refactor.

---

## 4. Work Streams

All work is single-codebase iOS. No parallel agent execution is needed — this is two sequential PRs, one per phase.

| Stream | Agent | Phase | Notes |
|---|---|---|---|
| P1-A: Enable rotate + tilt + remove browse setRegion | @ios-engineer | Phase 1 | Two-line makeUIView change + updateUIView surgical removal |
| P1-B: Rewrite RegionSyncGuardTests | @ios-engineer | Phase 1 | Part of same PR as P1-A |
| P1-QA: Live-UI smoke + test suite | @qa-verifier | Phase 1 | After P1 PR; mandatory screenshot gate |
| P2-A: Native follow + remove manual loop | @ios-engineer | Phase 2 | After Phase 1 merged |
| P2-B: Rewrite FT10Tests + add tracking-mode tests | @ios-engineer | Phase 2 | Part of same PR as P2-A |
| P2-QA: Live-UI smoke + Drive Mode real-device test | @qa-verifier | Phase 2 | Kevin manual Drive Mode smoke is irreducible |

P1-A and P1-B are the same PR. P2-A and P2-B are the same PR. P1 must merge before P2 starts.

---

## 5. Acceptance Criteria

### Phase 1

**P1-AC-1.** `makeUIView` sets `mapView.isRotateEnabled = true` and `mapView.isPitchEnabled = true`. Verified by reading the file.

**P1-AC-2.** `updateUIView` contains NO call to `mapView.setRegion(_:animated:)` (the browse-mode path). The only `setRegion` in the entire file is the one in `makeUIView` for initial camera placement (line 546). Verified by `grep "setRegion" MapViewRepresentable.swift` showing exactly one callsite.

**P1-AC-3.** The static function `shouldSyncRegionToBinding(driveModeActive:isUserInteracting:)` is deleted from `MapViewRepresentable`. Verified by grep.

**P1-AC-4 (Browse rotate).** Live-UI smoke: @ios-engineer or @qa-verifier launches in Simulator, performs a two-finger rotate gesture on the map, and screenshots the result showing the map rotated (compass not pointing north). Mandatory screenshot artifact in QA report.

**P1-AC-5 (Browse tilt).** Live-UI smoke: two-finger drag downward shows the map in 3D perspective (road labels visible at an angle). Screenshot artifact required.

**P1-AC-6 (No snap-back).** Live-UI smoke: pan the map while a Drive Mode is NOT active; hold pan for 3+ seconds. Map does not snap back. The SwiftUI toolbar (gear, find-me, find-car, clock), ASP banner, and Park Until pill are all still visible in the screenshot.

**P1-AC-7 (#31 regression check).** Launch the app fresh in Simulator. Screenshot immediately after launch shows: parking polylines rendered, toolbar buttons visible, ASP banner visible. Same check with Drive Mode active (enter destination mode, screenshot). This is the #31 non-regression gate.

**P1-AC-8 (Programmatic recenter still works).** Tap the find-me button (W5.1). In the Simulator with a simulated location, the map recenters. This path writes `region` from `recenterMap(on:)` — confirm it still fires `setRegion` via `updateUIView`'s existing programmatic-intent path OR confirm the engineer chose an equivalent `CoordinatorActions` closure path. Either is acceptable; document in PR.

**P1-AC-9 (Drive Mode camera unchanged).** With Drive Mode active (destination mode, sim GPS), set a heading via `LocationService.driveHeading`. The heading-up rotation fires via `syncDriveHeading`. `driveFollowEnabled` still exists and its Phase 1 behavior (Recenter button, syncDriveRegion) is unchanged. Verify by reading the unmodified Drive Mode test results: `RegionSyncGuardTests` may need rewrite (see AC-P1-10) but `FT10Tests`, `DriveCameraTiltTests`, `FT7Tests`, `FT8Tests`, `DriveZoomStyleTests` pass without modification.

**P1-AC-10 (RegionSyncGuardTests rewritten).** The existing `RegionSyncGuardTests` tests `shouldSyncRegionToBinding` which is being deleted. These tests must be rewritten. The replacement tests should verify: (a) `updateUIView` in the Coordinator does not call `setRegion` at all (or, if the implementation uses a different approach to suppress it, the tests cover whatever gate remains); (b) `isUserInteracting` still suppresses the Drive Mode `syncDriveRegion` path (that gate is in `FT10Tests` which must remain green). Test count must remain at or above current count.

**P1-AC-11 (Test suite green).** `xcodebuild test` passes 377/0 (current baseline) after adjusting for deleted/rewritten tests. The net test count must be >= 377 − (number of deleted RegionSyncGuardTests tests) + (number of replacement tests). No net deletion without replacement.

### Phase 2

**P2-AC-1.** `mapView.userTrackingMode = .follow` is set on Drive Mode entry, wired from `.onChange(of: driveModeActive)` via `CoordinatorActions.setDriveTrackingMode`. Verified by code review.

**P2-AC-2.** `userTrackingMode` is set to `.none` on Drive Mode exit (either explicitly in the exit path or naturally — confirm). Verified by code review.

**P2-AC-3.** `syncDriveRegion`, `shouldSyncDriveRegion`, `driveFollowEnabled`, `onDrivePanDetected`, `recenterDriveMap`, `recenterDriveMode` are all removed from the codebase. Verified by grep.

**P2-AC-4.** `FT10Tests.swift` is either deleted or fully rewritten to cover the new tracking-mode state machine. No old tests that reference removed symbols compile.

**P2-AC-5 (Heading coexistence).** `syncDriveHeading` still fires per GPS tick and sets `camera.heading` to the GPS course. The map both follows the car position (native `.follow`) AND rotates to course heading (manual `setCamera` on heading). No dead-lock between the two: specifically, `setCamera(animated:true)` with only heading changed does NOT reset `userTrackingMode` to `.none`. Verified: MapKit's `setCamera` does not affect `userTrackingMode` (only user gestures and `setUserTrackingMode` do). Document this assertion in the PR.

**P2-AC-6 (Pan breaks follow).** Live-UI smoke: enter Drive Mode (sim), manually pan the map. Recenter button appears. MapKit has set `userTrackingMode = .none` (confirmed via `mapView(_:didChange:animated:)` callback). Screenshot artifact required.

**P2-AC-7 (Recenter re-engages follow).** Tap Recenter. The map re-centers on the simulated GPS position and the Recenter button disappears. `userTrackingMode` is back to `.follow`. Screenshot artifact required.

**P2-AC-8 (Pitch/zoom survive follow transitions).** On Drive Mode entry, 45° pitch and drive zoom (altitude ~621m) are applied via `applyDriveCameraState`. After a follow-break + recenter cycle, pitch and zoom are restored to drive defaults (per OQ-3 recommendation). Verified by live-UI smoke screenshot showing the tilted view.

**P2-AC-9 (#31 regression check).** Same as P1-AC-7: fresh launch screenshot shows overlays + toolbar + banner intact. Drive Mode screenshot shows same.

**P2-AC-10 (Drive Mode position follow smooth).** Kevin manual real-device test (required, sim has no GPS movement): mount phone, drive 1 block, map follows. No snapping. Document outcome in QA report field-testing section.

**P2-AC-11 (Test suite green).** `xcodebuild test` passes at >= (Phase 1 count) − (deleted FT10/follow tests) + (new tracking-mode tests). Net test count does not decrease by more than the number of explicitly replaced tests.

**P2-AC-12 (No regression on existing Drive Mode features).** Voice commentary, pitch, zoom, puck rotation, map style swap, final-approach escalation all continue to work. @qa-verifier to verify via code review (all those code paths are in non-removed functions) and smoke-test of Drive Mode entry/exit transition.

---

## 6. The Hard Design Problems — Investigations and Recommendations

### 6.1 Problem 1: Heading Source Conflict (the crux)

**What `.followWithHeading` does:** MapKit's `MKUserTrackingModeFollowWithHeading` sets `userTrackingMode` to rotate the map to the device's CLHeading (compass-up: the magnetometer). It is NOT course-up. The magnetometer reflects the phone's physical orientation in 3D space, which is skewed when the phone is mounted at a cup-holder angle, a dash mount, or any non-upright position. This is precisely why FT-7 (`docs/ft7-drive-mode-smoothness-heading-spec.md`) switched from compass to GPS course: the FT-7 spec explicitly diagnoses "compass askew when mounted at angle" as the root cause of heading errors and routes around it by using `CLLocation.course` instead.

**Does `.followWithHeading` use course or compass?** It uses **compass (CLHeading.magneticHeading)**. Not course. Apple's documentation is explicit: "The map tracks the user's heading and location." In CoreLocation, "heading" means the magnetic heading from the magnetometer (what `CLLocationManager.startUpdatingHeading()` provides), not the direction of travel (`CLLocation.course`). This is confirmed by the fact that `CLLocation.course` is separate from `CLHeading.magneticHeading` in the API.

**Recommendation: Use `.follow` (not `.followWithHeading`) + manual course heading.**

The correct Phase 2 design is:
- `userTrackingMode = .follow` for smooth native position-centering with no heading rotation from MapKit.
- Keep the existing `syncDriveHeading` path intact: it reads `locationService.driveHeading` (which is the EMA-stabilized GPS course from `selectDriveHeadingSource`, not the magnetometer) and calls `setCamera` with only the heading changed.

**Why these two do not fight each other:**
MapKit's `.follow` tracking mode centers the map on the user's GPS position. It does NOT set camera heading. Setting `camera.heading` via `setCamera(animated:true)` does NOT reset `userTrackingMode`. The two are orthogonal in MapKit's model: tracking mode controls whether the center coordinate follows the GPS; camera heading is a separate camera property that can be mutated independently. This is verifiable by inspection of the `MKMapCamera` API: `heading`, `pitch`, and `centerCoordinateDistance` are all mutable independently from the tracking mode.

**What this means for Phase 2:** The Phase 1 + Phase 2 design preserves FT-7's GPS-course heading exactly as shipped. The only change in Phase 2 is that MapKit does the position-centering natively (`.follow`) instead of ContentView manually writing `region` and calling `syncDriveRegion`. Heading-up rotation remains manual and course-based.

**Edge case — `setCamera` with heading: does it break `.follow`?** Apple's documentation and behavior confirm: programmatic `setCamera` cancels animations but does NOT override `userTrackingMode`. The tracking mode resumes centering on the next location update. This is the same behavior MapKit uses when you set camera pitch while following (e.g., in Apple Maps tilt gesture during navigation). The existing `syncDriveHeading` path is exactly this pattern: it calls `setCamera` only with the heading changed, so the center will re-sync on the next GPS fix via `.follow`. At 1 Hz GPS cadence and 0.3s animation duration, this is imperceptible.

### 6.2 Problem 2: Tilt + Zoom in Native Follow Mode

**Current state:** `applyDriveCameraState` sets pitch (45°) and `centerCoordinateDistance` (~621m) in a single `setCamera(animated:true)` call on Drive Mode entry. This is wired via `CoordinatorActions.applyDrivePitch` called from `.onChange(of: driveModeActive)`. This path is entirely in `MapViewRepresentable`'s Coordinator and does not touch `userTrackingMode`.

**Will native `.follow` fight the pitch/zoom setCamera?** No. `.follow` mode centers the position but does not modify pitch or `centerCoordinateDistance`. After `applyDriveCameraState` fires on Drive Mode entry, native follow will continue to center on the user but preserve the pitch and distance. MapKit's follow mode in iOS 17 does not auto-reset pitch or altitude.

**After a follow-break + recenter:** When the user pans (follow breaks to `.none`), pitch and zoom stay wherever they are. When the Recenter button fires `setDriveTrackingMode(true)` + `applyDrivePitch(true, preDrivePitch)` (per OQ-3 recommendation), the pitch/zoom are explicitly restored to drive defaults as part of re-engaging follow.

**During `syncDriveHeading` per-tick camera.heading updates:** Each `syncDriveHeading` call copies the current camera, changes only `heading`, and calls `setCamera`. Pitch and `centerCoordinateDistance` are preserved by the `camera.copy()` mechanism (same pattern already in use since W8.5c-polish PR-3, line 1021).

### 6.3 Problem 3: Overlay / #31 Safety

**The #31 lesson in one sentence:** Any `setCamera` or `setRegion` call inside `updateUIView` races SwiftUI's mount cycle and can drop the entire `.safeAreaInset` overlay chain (toolbar, ASP banner, Park Until pill).

**How Phase 1 avoids #31:** Phase 1 removes `setRegion` from `updateUIView` entirely. No camera mutation happens in `updateUIView` after this change. The only remaining camera calls in the Coordinator are in:
- `syncDriveHeading` (called from `updateUIView`) — this call has existed since W8.5c and is already vetted as safe (the dead-band guard limits frequency, and the W8.5c-polish PR-3 bug analysis confirmed it does not cause the #31 regression as long as `setRegion` is not also in flight).
- `applyDriveCameraState` (called from `.onChange` via `CoordinatorActions`, NOT from `updateUIView`) — this is the correct pattern.
- `syncDriveRegion` (called from `updateUIView` in Drive Mode) — Phase 1 leaves this unchanged. Phase 2 removes it.

**How Phase 2 avoids #31 for the new tracking-mode calls:**
- `mapView.userTrackingMode = .follow` must NOT be set inside `updateUIView`. It must be called from `.onChange(of: driveModeActive)` via a new `CoordinatorActions.setDriveTrackingMode` closure, parallel to the existing `applyDrivePitch` pattern.
- The `mapView(_:didChange:animated:)` delegate callback fires from MapKit, not from SwiftUI's render cycle — it is safe to dispatch SwiftUI state updates from it via `DispatchQueue.main.async`.

**Overlay sync remains a pure mechanical sync in `updateUIView`:**
- `applyOverlayPayload` (parking polylines): unchanged, no camera calls, safe.
- `syncCarPin`, `syncRoutePolyline`, `syncDestinationPin`, `syncCommunityPinAnnotations`: unchanged, annotation add/remove only, no camera calls, safe.
- `syncDriveHeading`: unchanged, continues to be called from `updateUIView` (it is safe per above analysis).

### 6.4 Problem 4: Inventory of What Gets Removed / Replaced

| Symbol | Location | Phase 1 | Phase 2 | Notes |
|---|---|---|---|---|
| `isRotateEnabled = false` | `makeUIView:522` | CHANGED to `true` | — | |
| `isPitchEnabled = false` | `makeUIView:523` | CHANGED to `true` | — | |
| `shouldSyncRegionToBinding(driveModeActive:isUserInteracting:)` | `MapViewRepresentable` static | DELETED | — | No callers after Phase 1 |
| `setRegion` in `updateUIView` browse path | `updateUIView:695–703` | DELETED | — | The entire if-block |
| `@State region` in ContentView | ContentView | Kept, read-only from map | Kept | Still used for launch center + find-me |
| `recenterMap(on:)` writes `region` | ContentView | Kept | Kept | Intentional programmatic move |
| `shouldSyncDriveRegion(driveModeActive:driveFollowEnabled:isUserInteracting:)` | `MapViewRepresentable` static | Kept | DELETED | Phase 2 |
| `syncDriveRegion(_:on:)` | Coordinator | Kept | DELETED | Phase 2 |
| `driveFollowEnabled` @State | ContentView | Kept | DELETED | Phase 2 |
| `driveFollowEnabled` property | `MapViewRepresentable` | Kept | DELETED | Phase 2 |
| `onDrivePanDetected` | `MapViewRepresentable` + ContentView | Kept | DELETED | Phase 2 |
| `handleDrivePanDetected` | ContentView | Kept | DELETED | Phase 2 |
| `recenterDriveMode()` | ContentView | Kept | DELETED | Phase 2 |
| `recenterDriveMap(on:)` | ContentView | Kept | DELETED | Phase 2 |
| Follow block in `handleLocationUpdate` | ContentView | Kept | DELETED | Phase 2 — the `if driveFollowEnabled { recenterDriveMap }` block |
| `isUserInteracting` | Coordinator | Kept (still needed for FT-5 browse snap-back suppression) | Kept | Still used to gate `syncDriveHeading` / other programmatic paths |
| `syncDriveHeading` | Coordinator | Kept | Kept | Phase 2 keeps this exactly as-is |
| `applyDriveCameraState` | Coordinator | Kept | Kept | Phase 2 calls it from Recenter path |
| `CoordinatorActions.setDriveTrackingMode` | `MapViewRepresentable` | — | NEW | Phase 2 |
| `CoordinatorActions.onTrackingModeChanged` | `MapViewRepresentable` | — | NEW (output) | Phase 2: tells ContentView tracking mode changed |
| `mapView(_:didChange:animated:)` | Coordinator | — | NEW | Phase 2: detects user pan broke follow |

**Test inventory:**

| Test file | Phase 1 | Phase 2 | Notes |
|---|---|---|---|
| `RegionSyncGuardTests` (in `DriveCameraTiltTests.swift`) | REWRITE | — | Tests `shouldSyncRegionToBinding` which is deleted; replace with equivalent coverage |
| `FT10Tests.swift` | KEEP GREEN (unmodified) | REWRITE or DELETE | Tests `shouldSyncDriveRegion` and `driveFollowEnabled` which are deleted in Phase 2 |
| `FT7Tests.swift` | KEEP GREEN | KEEP GREEN | `syncDriveHeading`, `shortestArcDelta`, `selectDriveHeadingSource` all unchanged |
| `FT8Tests.swift` | KEEP GREEN | KEEP GREEN | Constants unchanged |
| `DriveCameraTiltTests.swift` | KEEP GREEN (minus RegionSyncGuardTests subclass) | KEEP GREEN | `targetPitch` etc. unchanged |
| `DriveZoomStyleTests.swift` | KEEP GREEN | KEEP GREEN | Pure function tests; no drive-follow dependency |
| `W85cTests.swift` | KEEP GREEN | KEEP GREEN | `syncDriveHeading` tests still valid |
| `W85bTests.swift` | KEEP GREEN | KEEP GREEN | Route/overlay Z-order tests; no camera dependency |
| `W85dTests.swift` | KEEP GREEN | KEEP GREEN | Final-approach tests; no camera dependency |
| New tracking-mode tests | — | ADD | Cover `setDriveTrackingMode` wiring, `mapView(_:didChange:animated:)` callback behavior |

### 6.5 Problem 5: Recenter UX

**Phase 1:** Unchanged from current. Recenter button appears when `driveFollowEnabled == false` (set by `onDrivePanDetected`). Tapping Recenter calls `recenterDriveMode()` → sets `driveFollowEnabled = true` → writes `region` → `syncDriveRegion`. This system is left completely intact.

**Phase 2:** The `driveFollowEnabled` state machine is replaced by tracking-mode state.

Recenter button visibility signal: `mapView(_:didChange:animated:)` fires when MapKit breaks tracking (user gesture during Drive Mode). This delegate callback provides `mode: MKUserTrackingMode`. When `mode == .none` and `driveModeActive == true`, ContentView should show the Recenter button. When `mode != .none`, hide it. This replaces the `driveFollowEnabled == false` signal.

Recenter button action:
1. `coordinatorActions.setDriveTrackingMode?(true)` → `mapView.userTrackingMode = .follow`
2. `coordinatorActions.applyDrivePitch?(true, preDrivePitch)` → restores 45° pitch + drive zoom (per OQ-3)
3. ContentView sets its "show recenter" state to false immediately on button tap (the delegate will confirm via callback, but the optimistic hide prevents flicker)

**Why the `mapView(_:didChange:animated:)` callback is reliable:** This is a standard `MKMapViewDelegate` method that fires when the tracking mode changes — MapKit guarantees it fires whenever `userTrackingMode` changes, including when a user gesture breaks it. It's the same mechanism Apple Maps uses. Contrast with the current approach of inspecting gesture recognizer states in `regionWillChangeAnimated`, which required careful ordering (the TF2-1 fix for the stationary-pan bug at line 1406).

---

## 7. Recommended Resolution: Design Problem 1 (Heading Source)

**Recommendation: `.follow` + manual course-up heading.**

The recommended design for Phase 2 Drive Mode is:

1. `mapView.userTrackingMode = .follow` for native position-centering on Drive Mode entry.
2. `syncDriveHeading` continues to set `camera.heading` per GPS tick using the EMA-stabilized GPS course (not compass). No change to `LocationService`, `selectDriveHeadingSource`, or the EMA constants.
3. On Drive Mode exit: `mapView.userTrackingMode = .none`, reset `camera.heading = 0` (existing `syncDriveHeading` nil-path already does this).

**Why not `.followWithHeading`:**
- It uses the compass (magnetometer), which FT-7 explicitly diagnosed as wrong when the phone is mounted at an angle. Using `.followWithHeading` would silently reintroduce the FT-7 bug.
- It also fights `syncDriveHeading`: MapKit would be rotating the map to compass-up while `syncDriveHeading` is rotating it to course-up. One of them would always win the last call, producing jitter.
- There is no public API to redirect `.followWithHeading` to use `CLLocation.course` instead of `CLHeading.magneticHeading`.

**The coupling between `.follow` and `setCamera(heading:)`:**
When `.follow` is active and `syncDriveHeading` fires `setCamera(animated:true)` with a new heading, MapKit will:
- Animate the heading change.
- On the NEXT location update, re-center the camera on the new GPS position (`.follow` resumes).
- NOT reset the heading or pitch (follow mode does not touch those properties).

At 1 Hz GPS update rate and 0.3s animation, each `syncDriveHeading` call animates heading for 0.3s and then the next location update fires a MapKit re-center (also animated, 0.3s). These are two orthogonal animations running back-to-back; they do not stack or fight. Apple Maps uses exactly this pattern internally.

**Alternative considered and rejected: Pure `.followWithHeading` + override heading source.** There is no public API in iOS 17 to replace MapKit's heading source for `.followWithHeading`. Private API would be required. Rejected.

**Alternative considered and rejected: `.follow` with no manual heading.** This gives a north-up Drive Mode — usable, but significantly inferior to course-up for driving. FT-7 specifically fixed this. Not appropriate.

---

## 8. Phase-by-Phase Acceptance Criteria (Concise Checklist)

### Phase 1 Checklist

- [ ] P1-AC-1: `isRotateEnabled = true`, `isPitchEnabled = true` in `makeUIView`
- [ ] P1-AC-2: No `setRegion` call in `updateUIView` (browse path removed)
- [ ] P1-AC-3: `shouldSyncRegionToBinding` function deleted
- [ ] P1-AC-4: Rotate gesture screenshot shows rotated map
- [ ] P1-AC-5: Tilt gesture screenshot shows 3D perspective
- [ ] P1-AC-6: Pan-and-hold does not snap back; all UI overlays visible
- [ ] P1-AC-7: #31 regression check: fresh launch screenshot shows overlays + toolbar + banner
- [ ] P1-AC-8: Find-me button still recenters map
- [ ] P1-AC-9: Drive Mode tests pass unmodified (FT7, FT8, FT10, DriveCameraTilt, DriveZoomStyle)
- [ ] P1-AC-10: RegionSyncGuardTests rewritten with equivalent replacement coverage
- [ ] P1-AC-11: `xcodebuild test` green, net count >= baseline minus deleted + added

### Phase 2 Checklist

- [ ] P2-AC-1: `userTrackingMode = .follow` on Drive Mode entry via `.onChange`/`CoordinatorActions`
- [ ] P2-AC-2: `userTrackingMode = .none` on Drive Mode exit
- [ ] P2-AC-3: All removed symbols gone (grep confirms)
- [ ] P2-AC-4: FT10Tests rewritten for new tracking-mode model
- [ ] P2-AC-5: Heading coexistence: `syncDriveHeading` fires without breaking `.follow` mode
- [ ] P2-AC-6: Pan in Drive Mode → Recenter button appears (screenshot)
- [ ] P2-AC-7: Tap Recenter → map re-centers + button disappears (screenshot)
- [ ] P2-AC-8: Pitch/zoom restored after recenter cycle (screenshot shows tilt)
- [ ] P2-AC-9: #31 regression check passed
- [ ] P2-AC-10: Kevin real-device Drive Mode smoke: position follows car, no snap
- [ ] P2-AC-11: Test suite green, net count maintained
- [ ] P2-AC-12: Voice, puck, map style, final approach all unaffected (code review + smoke)

---

## 9. #31 Safety Notes

The #31 regression (PR #31, reverted 2026-05-26) was caused by `setCamera` being called inside `updateUIView`, which raced SwiftUI's mount cycle and dropped the entire `.safeAreaInset` overlay chain. The architectural fix (`CoordinatorActions`, `.onChange`-driven camera mutations) was introduced in the W8.5c-polish PR-3 trilogy.

**Phase 1 safety:** Phase 1 REMOVES a camera call from `updateUIView` (the `setRegion` browse path). This is the safest possible change — no new camera calls are added. The risk of #31 regression from Phase 1 is zero.

**Phase 2 safety:**
- `mapView.userTrackingMode = .follow` must be called from `.onChange(of: driveModeActive)` via `CoordinatorActions`, NOT from `updateUIView`. The @ios-engineer must follow the `applyDrivePitch` pattern exactly.
- `mapView(_:didChange:animated:)` is a delegate callback (MapKit fires it), not SwiftUI — safe for dispatching to ContentView via `DispatchQueue.main.async { onTrackingModeChanged?(.none) }`.
- Recenter action writes no `region` binding — it calls `coordinatorActions.setDriveTrackingMode` + `applyDrivePitch`. Neither of these go through `updateUIView`.

**Invariant to state explicitly in the Phase 2 PR:** "No camera mutation (`setCamera`, `setRegion`, `userTrackingMode =`) happens inside `updateUIView`. All camera mutations are driven from `.onChange` handlers in ContentView or from MapKit delegate callbacks."

---

## 10. What Could Go Wrong

**Browse mode (Phase 1):**

1. **Programmatic recenter breaks.** The current browse recenter (`recenterMap(on:)`) writes `region` and then `updateUIView` calls `setRegion`. After Phase 1 removes `setRegion` from `updateUIView`, writing `region` alone does nothing. @ios-engineer must verify the recenter path and add a `CoordinatorActions.setRegion` closure OR retain a narrow "explicit programmatic recenter" path in `updateUIView` gated on a new `pendingProgrammaticRegion` sentinel. **Risk: HIGH. Must be resolved before merge.** The simplest fix is a `coordinatorActions.setRegion: ((MKCoordinateRegion) -> Void)?` closure that calls `mapView.setRegion(_:animated:true)` directly.

2. **Overlay culling regresses.** Tile loading and overlay culling depend on `onRegionChanged` being called when the map viewport changes. Phase 1 preserves `regionDidChangeAnimated → onRegionChanged`. No regression risk here.

3. **isUserInteracting state gets stuck.** The `isUserInteracting` flag is cleared in `regionDidChangeAnimated`. After Phase 1, if `updateUIView` no longer calls `setRegion`, there are no programmatic `setRegion` calls that could fire `regionDidChangeAnimated` outside of user gestures. The flag should become simpler to reason about. Low risk.

**Drive Mode (Phase 2):**

4. **`setCamera(heading:)` inadvertently resets `.follow` tracking.** This is the highest risk in Phase 2. If MapKit resets `userTrackingMode` to `.none` on any `setCamera` call, then `syncDriveHeading` (called every 1 Hz) would constantly break tracking. The MapKit documentation does NOT indicate `setCamera` affects tracking mode, and the behavior of Apple Maps (which does both follow and heading simultaneously) confirms they are orthogonal. However, this must be verified with Kevin's real-device test (P2-AC-10). If it does happen, mitigation: re-set `userTrackingMode = .follow` at the END of `syncDriveHeading` (after `setCamera`). This creates one extra tracking-mode set per GPS tick, which is low cost.

5. **Heading rotation jitter when combining `.follow` and `setCamera`.** The two animations (MapKit's follow re-center + `syncDriveHeading` heading rotation) could produce visible jitter if they fire close together. The 0.3s animation duration + `animated:true` cancel-and-restart behavior (confirmed by existing FT-7 design) should handle this. However, at high heading-change rates (highway merge, turn), both could fire within the same animation frame. Mitigation: the existing 2° dead-band in `syncDriveHeading` keeps heading updates sparse. Real-device test is the verification gate.

6. **`mapView(_:didChange:animated:)` not firing reliably.** This is the signal for showing/hiding the Recenter button in Phase 2. If MapKit doesn't fire it reliably on user pan during Drive Mode, the Recenter button won't appear. Low risk — this is a standard, well-documented delegate method. Mitigation: Kevin's OQ-2 real-device test (per §2 Decisions) before Phase 2 merges.

7. **Overlay drop on `userTrackingMode` set.** Setting `userTrackingMode` fires `regionWillChangeAnimated` + `regionDidChangeAnimated` (as the map animates to center on the user). This is a programmatic change (no active gesture recognizer), so `isUserInteracting` will NOT be set to true. The existing guard in `regionWillChangeAnimated` checks gesture recognizer state — no gesture, no flag set. Safe.

8. **Test-count regression.** Removing `shouldSyncDriveRegion` and `driveFollowEnabled` deletes the corresponding FT10 tests. If the replacement tests aren't written, the count drops. @ios-engineer must write replacement tracking-mode tests to maintain parity.

---

## 11. Open Decisions (Complete List)

| ID | Question | Who | Blocks |
|---|---|---|---|
| OQ-1 | Accept "`.follow` + manual course heading" vs. evaluate `.followWithHeading`? | Kevin | Phase 2 start |
| OQ-2 | Confirm `mapView(_:didChange:animated:)` fires reliably on real-device pan during Drive Mode. | Kevin (real-device test post-Phase-1) | Phase 2 merge |
| OQ-3 | On Recenter, restore drive pitch+zoom (45°, ~621m) or silently follow from current state? | Kevin | Phase 2 implementation detail |
| OQ-4 | OK with compass appearing during rotate (auto-hides when north-up)? | Kevin | Phase 1 start (minor) |

---

## 12. Out of Scope Follow-Ups

**Cruise Mode heading-up in Phase 2:** Cruise Mode (Find Parking) also uses Drive Mode camera (heading-up, 45° pitch). The Phase 2 native follow applies identically — `driveModeActive = true` regardless of `driveModeStyle`. No special handling needed; noted here to confirm the engineer doesn't need to branch on style.

**`.followWithHeading` with iOS 18 course-based API:** iOS 18 introduced changes to CLLocationUpdate including a `course` property on updates. There is no public API to redirect `.followWithHeading` to use course. The manual `syncDriveHeading` approach remains the correct path on iOS 17+.

**Tilt gesture in Drive Mode:** With `isPitchEnabled = true` (Phase 1), the user can also tilt the map in Drive Mode. Phase 1 doesn't restrict this. In Phase 2 with native `.follow`, the user tilting during Drive Mode will NOT break `.follow` (tilt is not a pan — MapKit only breaks tracking on pan/rotate gestures, not pitch). If Kevin wants to restrict tilt in Drive Mode, that's a separate feature not in scope here.

**Zoom gesture in Drive Mode:** With native `.follow`, a user pinch-zoom during Drive Mode changes the `centerCoordinateDistance` but does NOT break `.follow` (MapKit preserves follow on zoom). This is actually better UX than the current system. No action needed; noted for awareness.

**`isUserInteracting` scope in Phase 2:** After Phase 2, `isUserInteracting` is only used by `syncDriveHeading`'s programmatic animation non-interference check (the `isUserGesture` read in `regionWillChangeAnimated`). Consider removing it in a future cleanup if Phase 2 makes it dead code. Not in scope for this spec.

---

## 13. Related Specs and Docs

- `docs/ft5-region-sync-interaction-guard-spec.md` — the FT-5 `isUserInteracting` spec (the mechanism Phase 1 simplifies but does not fully replace)
- `docs/ft7-drive-mode-smoothness-heading-spec.md` — the GPS course heading design (Phase 2 preserves this exactly)
- `docs/w8.5c-polish-pr3-spec.md` — the W8.5c-polish PR-3 spec introducing `CoordinatorActions` and `.onChange`-driven camera (the architectural pattern Phase 2 extends)
- `docs/w8.5c-polish-pr2-spec.md` — the PR-2 spec for auto-zoom + directional puck (the `applyDriveCameraState` pattern Phase 2 reuses for Recenter)
- `docs/ios-rendering-architecture-decision.md` — the UIKit bridge architecture (context for why `MKMapView` via `UIViewRepresentable`, not SwiftUI Map)
- `docs/qa/w8.5c-polish-pass-1-2026-05-25.md` — the #31 regression QA report (the failure this spec is designed to prevent from recurring)

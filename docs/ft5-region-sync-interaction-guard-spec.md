# FT-5 — Region-Sync Interaction Guard

**Spec status:** Ready for implementation
**Field-testing entry:** `docs/field-testing-log.md` — "FT-5 Map snaps back to previous view while panning"
**Touches:** `ios/WePark/WePark/Views/MapViewRepresentable.swift` only (iOS, no backend, no PWA)
**Test target:** `ios/WePark/WeParkTests/DriveCameraTiltTests.swift` (extend `RegionSyncGuardTests`)

---

## Open Decisions (Kevin must confirm before code starts)

None. Root cause is fully diagnosed and the fix approach is specified below without ambiguity. No new API surface, no schema change, no product-behaviour change visible to the user beyond the bug being absent.

---

## 1. Problem Statement

While panning the map in free-browse mode (Drive Mode off), the camera frequently snaps back to its position before the pan began. The trigger is any background SwiftUI re-render that coincides with an active drag — the 8-second community-pin poll, the ASP banner clock tick, a location update, or an overlay refresh. Each of those re-renders calls `MapViewRepresentable.updateUIView`, which executes the non-Drive-Mode region-sync branch at `MapViewRepresentable.swift:615-621`. That branch compares the live map center to the stale SwiftUI `region` binding (stale because `regionDidChangeAnimated` — which writes the binding back via `ContentView.handleRegionChanged` at `ContentView.swift:1021-1026` — only fires when the drag gesture fully settles) and, finding them diverged by more than 0.0001°, calls `setRegion(region, animated:false)` with the stale value, yanking the camera back. Drive Mode is unaffected because its path is already gated out by `shouldSyncRegionToBinding(driveModeActive:)`.

---

## 2. Scope

**In:**
- Add an `isUserInteracting: Bool` flag to `Coordinator`.
- Set it `true` in `regionWillChangeAnimated` when the change is user-gesture-driven.
- Clear it `false` in `regionDidChangeAnimated` unconditionally.
- Add an `isUserInteracting` parameter to `shouldSyncRegionToBinding` (the existing pure static function) so the full suppression decision is unit-testable without a live map.
- Update the `updateUIView` call site to pass the new parameter.
- Extend `RegionSyncGuardTests` with cases for the new parameter combinations.

**Out (explicitly deferred):**
- Any change to the Drive Mode pan-detection path (`onDrivePanDetected`). It is unaffected by this fix and must not be modified.
- Any change to `ContentView.swift`.
- Any new overlay, annotation, or rendering logic.
- Anything in `WePark.xcodeproj`, `Info.plist`, or `Config.xcconfig`.

---

## 3. Fix Design

### 3.1 New Coordinator flag

Add to `Coordinator` (alongside the existing `lastAppliedHeading` and `lastCapturedPriorDistance` fields):

```
var isUserInteracting: Bool = false
```

This flag is set and cleared exclusively inside the two `MKMapViewDelegate` camera callbacks described below.

### 3.2 Set the flag in `regionWillChangeAnimated`

The existing implementation of `regionWillChangeAnimated` (line 1242 of `MapViewRepresentable.swift`) early-returns for non-Drive-Mode via:

```swift
guard parent.driveHeading != nil else { return }
```

This guard must be split so that:

- The Drive Mode pan-detection block (`onDrivePanDetected`) continues to be guarded by `parent.driveHeading != nil` exactly as today — no change to that logic.
- The new interaction-tracking block runs regardless of Drive Mode state (i.e., in free-browse mode too).

Concrete structure after the change:

1. Run the user-gesture check (reusing the existing gesture-recognizer pattern).
2. If the change is user-gesture-driven, set `isUserInteracting = true`.
3. Then, if `parent.driveHeading != nil`, run the existing Drive Mode pan-detection (`onDrivePanDetected`) dispatch.

The gesture check is the same pattern already in the file:

```
mapView.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed || $0.state == .ended }
```

Only set `isUserInteracting = true` when this check returns `true`. A programmatic `setRegion` fires `regionWillChangeAnimated` with no active gesture recognizer, so the flag will not be set spuriously by programmatic recenters (recenter button, `animateToCoordinate`, `syncDriveRegion`).

### 3.3 Clear the flag in `regionDidChangeAnimated`

In `mapView(_:regionDidChangeAnimated:)` (line 1258), add `isUserInteracting = false` synchronously, before the `DispatchQueue.main.async` block that calls `onRegionChanged`. Clear unconditionally — regardless of whether the change was user-driven or programmatic. This prevents the flag from getting stuck `true` if a programmatic recenter fires while the user is not touching the screen.

### 3.4 Extend the pure guard function

The existing signature:

```swift
static func shouldSyncRegionToBinding(driveModeActive: Bool) -> Bool
```

Extend to:

```swift
static func shouldSyncRegionToBinding(driveModeActive: Bool, isUserInteracting: Bool) -> Bool
```

Return `true` (allow sync) only when both `driveModeActive == false` AND `isUserInteracting == false`. Return `false` (suppress sync) when either flag is `true`.

The old two-parameter call site in `updateUIView` (line 615) becomes:

```swift
if MapViewRepresentable.shouldSyncRegionToBinding(
    driveModeActive: driveModeActive,
    isUserInteracting: context.coordinator.isUserInteracting
) {
```

The existing `RegionSyncGuardTests` call the pure function directly — they will need the new parameter added. The existing test cases (Drive Mode active → false, Drive Mode inactive → true) must both gain the `isUserInteracting: false` argument so they continue to compile and pass unchanged.

### 3.5 Programmatic recenter paths are unaffected

`recenterOnUser` (ContentView line 1500), `recenterMap` (line 1523), and `recenterDriveMap` (line 1487) all write to the `region` binding while the user is not touching the screen. Their `setRegion` calls fire `regionWillChangeAnimated` with no active gesture recognizer → `isUserInteracting` stays `false` → `shouldSyncRegionToBinding` returns `true` → the programmatic sync runs as before. No special handling required.

### 3.6 Drive Mode path is unaffected

When `driveModeActive == true`, `shouldSyncRegionToBinding` returns `false` regardless of `isUserInteracting`. The `syncDriveRegion` path (the else branch at line 622) is not modified. Drive Mode pan detection in `regionWillChangeAnimated` is not modified.

---

## 4. Files and Functions to Touch

| File | Location | Change |
|---|---|---|
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | `Coordinator` property list (~line 670) | Add `var isUserInteracting: Bool = false` |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | `shouldSyncRegionToBinding(driveModeActive:)` (~line 434) | Add `isUserInteracting: Bool` parameter; return `!driveModeActive && !isUserInteracting` |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | `updateUIView` call site (~line 615) | Pass `isUserInteracting: context.coordinator.isUserInteracting` |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | `regionWillChangeAnimated` (~line 1242) | Split guard; add gesture-driven `isUserInteracting = true` block outside Drive Mode guard |
| `ios/WePark/WePark/Views/MapViewRepresentable.swift` | `regionDidChangeAnimated` (~line 1258) | Add `isUserInteracting = false` before the async dispatch |
| `ios/WePark/WeParkTests/DriveCameraTiltTests.swift` | `RegionSyncGuardTests` (~line 177) | Update existing 2 tests to pass `isUserInteracting: false`; add 2 new test cases (see §5) |

No other files are touched.

---

## 5. Acceptance Criteria

### Unit tests (must pass before PR is opened)

**AC-FT5.1** — `testRegionSync_driveModeActive_notInteracting_returnsFalse`
Call `shouldSyncRegionToBinding(driveModeActive: true, isUserInteracting: false)`. Assert `false`. (Drive Mode active alone suppresses sync.)

**AC-FT5.2** — `testRegionSync_driveModeInactive_notInteracting_returnsTrue`
Call `shouldSyncRegionToBinding(driveModeActive: false, isUserInteracting: false)`. Assert `true`. (Neither flag set → sync runs. This is the existing test 8, updated signature.)

**AC-FT5.3** — `testRegionSync_driveModeInactive_userInteracting_returnsFalse`
Call `shouldSyncRegionToBinding(driveModeActive: false, isUserInteracting: true)`. Assert `false`. (This is the new suppression case — the bug fix.)

**AC-FT5.4** — `testRegionSync_driveModeActive_userInteracting_returnsFalse`
Call `shouldSyncRegionToBinding(driveModeActive: true, isUserInteracting: true)`. Assert `false`. (Both flags true → still suppressed. Belt-and-suspenders; Drive Mode wins regardless.)

**AC-FT5.5** — All pre-existing tests pass. Run the full `WeParkTests` suite. Zero regressions against the baseline of 243 tests (W8.5d as-shipped).

**AC-FT5.6** — `RegionSyncGuardTests` existing test 7 (`testRegionSync_driveModeActive_returnsFalse`) and test 8 (`testRegionSync_driveModeInactive_returnsTrue`) are updated to compile with the new two-parameter signature and still pass. Their assertions are unchanged; only the call site gains `isUserInteracting: false`.

### Structural / code constraints

**AC-FT5.7** — `shouldSyncRegionToBinding` remains a `static` pure function on `MapViewRepresentable` with no `MKMapView` dependency. It must be callable from a test without instantiating a map view.

**AC-FT5.8** — The Drive Mode `onDrivePanDetected` dispatch in `regionWillChangeAnimated` remains gated on `parent.driveHeading != nil`. The gate condition and dispatch body are unchanged.

**AC-FT5.9** — `isUserInteracting = false` appears in `regionDidChangeAnimated` unconditionally — not inside a conditional branch. The flag must clear on every call, whether the change was user-driven or programmatic.

**AC-FT5.10** — `setRegion` does not appear anywhere on the Drive Mode active code path. Search `MapViewRepresentable.swift` for `setRegion`; every call must be in a branch that can only be reached when `shouldSyncRegionToBinding` returned `true` (i.e., both `driveModeActive == false` and `isUserInteracting == false`), or in `makeUIView` (initial setup, not a re-render path).

**AC-FT5.11** — No new `@State`, `@Binding`, or `@Published` properties are added. The `isUserInteracting` flag lives on `Coordinator` only (a reference-type `NSObject` subclass) and does not cross the UIKit-SwiftUI boundary.

### Live-UI smoke gate (required before merge, same discipline as #31-regression)

**AC-FT5.12** — Build and run in the iOS simulator. Pan the map continuously for at least 10 seconds. The camera must not snap back to a prior position during the pan. (Previously snapped within 1-3 seconds due to the 8-second community-pin poll timer.) Engineer or orchestrator captures a screenshot or screen recording as evidence.

**AC-FT5.13** — With Drive Mode active (enter via DriveModeDestinationView), pan the map (to confirm follow-mode detection still works). `driveFollowEnabled` must flip to `false` after the pan. (Verifies the `onDrivePanDetected` path is unbroken.)

**AC-FT5.14** — Tap the recenter button (find-me) in free-browse mode. The map must snap to the user location. (Verifies programmatic recenters still work while `isUserInteracting` is not set.)

---

## 6. Required New Unit Test — Implementation Notes

The engineer should add the two new test cases (AC-FT5.3 and AC-FT5.4) to `RegionSyncGuardTests` in `DriveCameraTiltTests.swift` immediately after the existing test 8. Update the existing tests 7 and 8 in place (add `isUserInteracting:` argument label). All four cases are pure-function calls — no map view, no async, no XCTestExpectation required.

Suggested test names (engineer may vary wording but must preserve the assertion semantics):

- `testRegionSync_driveModeActive_notInteracting_returnsFalse`
- `testRegionSync_driveModeInactive_notInteracting_returnsTrue` (renamed from test 8)
- `testRegionSync_driveModeInactive_userInteracting_returnsFalse` (new — the key regression lock)
- `testRegionSync_driveModeActive_userInteracting_returnsFalse` (new — completeness)

The test description comment on the new `isUserInteracting` case should cite the FT-5 root cause in one sentence so future readers understand why the suppression exists.

---

## 7. Work Stream

Single stream. This is a surgical single-file iOS fix. No parallel work streams are needed. No backend, no PWA, no designer involvement.

Owner: `@ios-engineer` in a worktree (per HANDOFF.md agent isolation discipline).
Verifier: `@qa-verifier` (separate agent, read-only pass).
Live-UI smoke gate: required before merge per #31-regression discipline.

Estimated scope: small. One modified function signature, one new flag, four-line change to the two delegate methods, four test cases. The complexity is in understanding the existing code, not in the volume of change.

---

## 8. Out-of-Scope Follow-ups

- **Velocity-based snap-back suppression.** A more sophisticated fix would suppress the sync for some time window after the last gesture, not just while a gesture recognizer is active. Not needed: clearing on `regionDidChangeAnimated` (which fires when the gesture settles and the map coasts to rest) is sufficient. MapKit fires `regionDidChangeAnimated` only after the deceleration animation completes, so the flag is cleared at the correct moment.
- **Timeout guard for stuck `isUserInteracting`.** If MapKit ever fails to fire `regionDidChangeAnimated` (e.g., extreme edge case where the gesture is cancelled before the map moves), the flag could stay `true` permanently and suppress all programmatic recenters. A time-based reset (e.g., 5 seconds) would be defensive. Not specified here because: (a) MapKit reliably fires both callbacks in all documented gesture paths, (b) even if stuck, the user can work around it by tapping the recenter button once the gesture is done (which fires a new `setRegion` via the programmatic path that also clears the flag on the next `regionDidChangeAnimated`). Add a timeout only if Kevin reports persistent recenter failures after this fix ships.
- **Equivalent fix in the PWA.** The PWA (`index.html`) has a different map stack (Leaflet/Mapbox GL) and does not exhibit this bug in the same form. No PWA change is required.

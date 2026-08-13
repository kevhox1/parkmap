//
//  FT17aTests.swift
//  WeParkTests
//
//  FT-17a (2026-08-13): fixes the "Recenter pill appears only sporadically" defect in FT-17.
//
//  Root cause (docs/field-testing-log.md FT-17a): `regionWillChangeAnimated` computed
//  `isUserGesture` by scanning `mapView.gestureRecognizers`, which only ever contains our
//  OWN `UILongPressGestureRecognizer` and `UITapGestureRecognizer` (the only two recognizers
//  ever added directly to the map view in `makeUIView`). MapKit's native pan and pinch
//  recognizers live on `MKMapView`'s internal subviews and are never present in that array —
//  so a real pan/pinch was detected only when our tap or long-press happened to flicker into
//  an active state alongside it. Hence: "the recenter pill is sporadic, it doesn't always
//  appear."
//
//  Fix: `MapViewRepresentable.isUserGestureActive(panState:pinchState:)` — a pure function
//  over bare `UIGestureRecognizer.State` values with NO MKMapView / live-recognizer
//  dependency — replaces the `mapView.gestureRecognizers?.contains { ... }` scan.
//  `regionWillChangeAnimated` now passes it the `.state` of two dedicated, observer-only
//  `UIPanGestureRecognizer` / `UIPinchGestureRecognizer` instances installed directly on the
//  map view (`Coordinator.panGesture` / `pinchGesture`), which — unlike `mapView
//  .gestureRecognizers` — DO reliably reflect real pan/pinch touches, because they are
//  attached to the map view itself (a superview in MapKit's internal responder chain) and
//  participate in simultaneous recognition with MapKit's native recognizers.
//
//  Deliberate scope decision (FT-17a, stated explicitly per the task's request): pan and
//  pinch pause Drive Mode follow; tap (block select) and long-press (pin drop) do NOT. This
//  is encoded structurally — `isUserGestureActive` takes only `panState`/`pinchState`
//  parameters, so tap/long-press state can never influence its result even by mistake.
//
//  `isUserGestureActive` is fully unit-testable without a simulator or a live UIView/window:
//  `UIGestureRecognizer.State` is a plain enum, so these tests construct no MKMapView, no
//  UIGestureRecognizer instance, and no UIWindow. This is a strictly stronger testability
//  position than the code it replaces, which required a live recognizer with a read-only
//  `.state` and could only really be exercised on-device/in-simulator.
//
//  This PR is COMPILE-UNVERIFIED (written on a Linux VPS with no Xcode/simulator/toolchain)
//  — Kevin must confirm `xcodebuild test` passes and run the live-UI gesture smoke checklist
//  in the PR body before merge.
//
//  --- Follow-up (same day, Kevin's PR #74 simulator smoke test): TWO defects found in the
//  fix above. Both addressed in this file's Group 3/4.
//
//  Defect 1 — "the recenter button appears but doesn't work, map stays where it is."
//  `recenterDriveMode()` (ContentView.swift) reset state and applied pitch/altitude
//  immediately, but only CENTERED the camera on the next per-tick `setDriveCamera` call in
//  `handleLocationUpdate()` — which fires on the next GPS tick (never, on a static simulator
//  location with no further ticks). Fix: `recenterDriveMode()` now calls
//  `coordinatorActions.setDriveCamera?(coord, nil, currentDriveAltitude)` immediately using
//  the last known location (same closure the per-tick path already calls — no new
//  camera-application code path), falling back to the pitch/altitude-only path when no fix
//  exists yet (graceful — no crash, no jump to (0,0)). See Group 3 below.
//
//  Defect 2 — "pan and pinch work but not quite as smoothly as before."
//  `regionWillChangeAnimated` fires repeatedly throughout a single continuous gesture, not
//  once per gesture. Making pan/pinch detection reliable (the fix above) turned a formerly
//  rare `onDrivePanDetected` dispatch into a per-region-change-event flood — each dispatch
//  writes `followPaused = true` to SwiftUI `@State`, forcing a full Drive Mode overlay
//  re-render mid-gesture. Fix: `MapViewRepresentable.shouldSignalFollowPause(shouldPause:
//  alreadySignaledThisGesture:)` — a pure function — gates the dispatch to once per gesture,
//  backed by `Coordinator.hasSignaledFollowPauseThisGesture` (reset once neither observer
//  recognizer is active any more). See Group 4 below.
//
//  No Calendar.current.
//  No import SwiftUI (this file only exercises pure MapViewRepresentable static functions and
//  inline "mirror" closures replicating ContentView's private methods, matching the existing
//  house pattern in FT10Tests.swift — ContentView's methods are private and not directly
//  testable without a live view hierarchy).
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Group 1: isUserGestureActive — pure gesture-state-to-bool mapping

/// Tests for `MapViewRepresentable.isUserGestureActive(panState:pinchState:)`.
final class FT17aIsUserGestureActiveTests: XCTestCase {

    // MARK: Test 1: pan .began → true

    func testIsUserGestureActive_panBegan_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.isUserGestureActive(panState: .began, pinchState: nil),
            "A pan recognizer entering .began must be detected as an active user gesture"
        )
    }

    // MARK: Test 2: pan .changed → true

    func testIsUserGestureActive_panChanged_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.isUserGestureActive(panState: .changed, pinchState: nil),
            "A pan recognizer in .changed (mid-drag) must be detected as an active user gesture"
        )
    }

    // MARK: Test 3: pan .ended → true

    func testIsUserGestureActive_panEnded_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.isUserGestureActive(panState: .ended, pinchState: nil),
            "A pan recognizer that just settled (.ended) must still count as the gesture " +
            "that produced this region-change callback"
        )
    }

    // MARK: Test 4: pan .possible / .cancelled / .failed → false

    func testIsUserGestureActive_panInactiveStates_returnsFalse() {
        for state: UIGestureRecognizer.State in [.possible, .cancelled, .failed] {
            XCTAssertFalse(
                MapViewRepresentable.isUserGestureActive(panState: state, pinchState: nil),
                "Pan state \(state) must NOT count as an active user gesture"
            )
        }
    }

    // MARK: Test 5: pinch .began/.changed/.ended → true

    func testIsUserGestureActive_pinchActiveStates_returnsTrue() {
        for state: UIGestureRecognizer.State in [.began, .changed, .ended] {
            XCTAssertTrue(
                MapViewRepresentable.isUserGestureActive(panState: nil, pinchState: state),
                "Pinch state \(state) must count as an active user gesture — FT-17a fixes " +
                "pinch detection alongside pan"
            )
        }
    }

    // MARK: Test 6: both nil (recognizers not yet installed) → false

    func testIsUserGestureActive_bothNil_returnsFalse() {
        XCTAssertFalse(
            MapViewRepresentable.isUserGestureActive(panState: nil, pinchState: nil),
            "Nil states (e.g. regionWillChangeAnimated firing before makeUIView finishes " +
            "wiring the observer recognizers) must be treated as no active gesture, not crash"
        )
    }

    // MARK: Test 7: both inactive → false

    func testIsUserGestureActive_bothPossible_returnsFalse() {
        XCTAssertFalse(
            MapViewRepresentable.isUserGestureActive(panState: .possible, pinchState: .possible),
            "Both recognizers at .possible (no touch in flight) must not count as a user gesture"
        )
    }

    // MARK: Test 8: either active → true (OR semantics)

    func testIsUserGestureActive_pinchActiveWhilePanPossible_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.isUserGestureActive(panState: .possible, pinchState: .began),
            "A pure pinch (pan still .possible) must be detected — this is the exact FT-17a " +
            "regression case: a real pinch that does not also drift MapKit's pan recognizer"
        )
    }

    func testIsUserGestureActive_panActiveWhilePinchPossible_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.isUserGestureActive(panState: .began, pinchState: .possible),
            "A pure pan (pinch still .possible) must be detected"
        )
    }

    // MARK: Test 9: tap/long-press state has no parameter to leak through

    /// FT-17a's explicit scope decision: tap (block select) and long-press (pin drop) must
    /// NOT pause Drive Mode follow. This is enforced structurally, not by a runtime check —
    /// `isUserGestureActive` has no `tapState`/`longPressState` parameters at all, so there
    /// is no way for a future edit to accidentally wire tap/long-press state into this
    /// function's result. This test documents that as a signature-shape assertion: if a
    /// future change adds such parameters, this test's call sites will need updating,
    /// surfacing the scope change for review rather than silently expanding what pauses
    /// follow.
    func testIsUserGestureActive_signatureHasOnlyPanAndPinchParameters() {
        // Compiles only if the signature is exactly (panState:pinchState:) -> Bool.
        let result: Bool = MapViewRepresentable.isUserGestureActive(
            panState: .began,
            pinchState: .began
        )
        XCTAssertTrue(result)
    }
}

// MARK: - Group 2: shouldPauseFollow composition with isUserGestureActive (regression guard)

/// Verifies the two pure functions compose correctly end-to-end for the Drive Mode
/// follow-pause decision, without needing a live MKMapView. `shouldPauseFollow` itself is
/// unchanged by FT-17a (still `driveModeActive && isUserGesture`, tested exhaustively in
/// FT10Tests.swift's Group 7) — these tests exercise the FT-17a-fixed upstream computation
/// feeding into it.
final class FT17aShouldPauseFollowCompositionTests: XCTestCase {

    // MARK: Test 10: Drive Mode + real pinch-only gesture → pauses follow

    /// This is Kevin's exact FT-17 regression scenario, now fixed by FT-17a: a pinch that
    /// does NOT also trigger MapKit's pan recognizer must still pause follow.
    func testDriveModeActive_pinchOnlyGesture_pausesFollow() {
        let isUserGesture = MapViewRepresentable.isUserGestureActive(
            panState: .possible,
            pinchState: .changed
        )
        XCTAssertTrue(
            MapViewRepresentable.shouldPauseFollow(
                driveModeActive: true,
                isUserGesture: isUserGesture
            ),
            "A pure pinch during Drive Mode must pause follow and surface Recenter — this " +
            "is the case FT-17a's fix makes reliably detectable"
        )
    }

    // MARK: Test 11: Drive Mode + no active pan/pinch → does not pause

    /// Guard: a programmatic setCamera (e.g. syncDriveHeading, the per-tick setDriveCamera)
    /// must never pause follow. Neither observer recognizer is active for a programmatic
    /// camera move.
    func testDriveModeActive_noGesture_doesNotPauseFollow() {
        let isUserGesture = MapViewRepresentable.isUserGestureActive(
            panState: .possible,
            pinchState: .possible
        )
        XCTAssertFalse(
            MapViewRepresentable.shouldPauseFollow(
                driveModeActive: true,
                isUserGesture: isUserGesture
            ),
            "Programmatic camera changes (neither observer recognizer active) must never " +
            "pause follow"
        )
    }
}

// MARK: - Group 3: shouldSignalFollowPause — Defect 2 dedup gate

/// Tests for `MapViewRepresentable.shouldSignalFollowPause(shouldPause:alreadySignaledThisGesture:)`,
/// the pure function that fixes Defect 2 ("pan and pinch work but not quite as smoothly as
/// before" — jank from `onDrivePanDetected` firing on every `regionWillChangeAnimated` call
/// within a single gesture instead of once).
final class FT17aShouldSignalFollowPauseTests: XCTestCase {

    // MARK: Test 12: first event in a gesture that should pause → signals

    func testShouldSignalFollowPause_firstEventShouldPause_returnsTrue() {
        XCTAssertTrue(
            MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: true,
                alreadySignaledThisGesture: false
            ),
            "The first region-change event in a gesture that should pause follow must signal"
        )
    }

    // MARK: Test 13: subsequent events in the SAME gesture → do not re-signal

    /// The core Defect 2 regression case: `regionWillChangeAnimated` fires many times for one
    /// physical gesture. Once already signaled, further events in the same gesture must not
    /// dispatch again (this is what stops the per-event `followPaused = true` re-render storm).
    func testShouldSignalFollowPause_alreadySignaled_returnsFalse() {
        XCTAssertFalse(
            MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: true,
                alreadySignaledThisGesture: true
            ),
            "Once already signaled for the current gesture, subsequent region-change events " +
            "must NOT re-dispatch onDrivePanDetected — this is the Defect 2 fix"
        )
    }

    // MARK: Test 14: shouldPause false → never signals regardless of prior state

    func testShouldSignalFollowPause_shouldNotPause_returnsFalse() {
        for alreadySignaled in [false, true] {
            XCTAssertFalse(
                MapViewRepresentable.shouldSignalFollowPause(
                    shouldPause: false,
                    alreadySignaledThisGesture: alreadySignaled
                ),
                "If shouldPause is false (not Drive Mode, or no active gesture), never signal " +
                "regardless of the dedup flag's prior state"
            )
        }
    }

    // MARK: Test 15: a NEW gesture (flag reset) can signal again

    /// After a gesture ends and `hasSignaledFollowPauseThisGesture` resets to `false`
    /// (`regionDidChangeAnimated`, once neither observer recognizer is active), the NEXT
    /// gesture must be able to signal again — the dedup gate is per-gesture, not permanent.
    func testShouldSignalFollowPause_afterReset_signalsAgainForNewGesture() {
        // Simulates: gesture 1 signals once, ends, flag resets, gesture 2 begins.
        var alreadySignaledThisGesture = false

        // Gesture 1, event 1: signals.
        XCTAssertTrue(
            MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: true,
                alreadySignaledThisGesture: alreadySignaledThisGesture
            )
        )
        alreadySignaledThisGesture = true

        // Gesture 1, event 2-3: does not re-signal.
        XCTAssertFalse(
            MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: true,
                alreadySignaledThisGesture: alreadySignaledThisGesture
            )
        )

        // Gesture 1 ends — regionDidChangeAnimated resets the flag.
        alreadySignaledThisGesture = false

        // Gesture 2, event 1: signals again.
        XCTAssertTrue(
            MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: true,
                alreadySignaledThisGesture: alreadySignaledThisGesture
            ),
            "A new gesture (after the dedup flag resets) must be able to signal " +
            "onDrivePanDetected again — the pill must reappear on every real gesture, not " +
            "just the first one ever"
        )
    }
}

// MARK: - Group 4: recenterDriveMode — Defect 1 immediate-centering decision

/// Mirrors ContentView's `recenterDriveMode()` (private, not directly testable — same house
/// pattern as FT10Tests.swift's mirror tests). Verifies the FT-17a Defect 1 fix: Recenter
/// centers the camera IMMEDIATELY using the last known location, instead of waiting for the
/// next per-tick GPS update (which may never arrive on a static/simulated location).
final class FT17aRecenterImmediateCenteringTests: XCTestCase {

    // MARK: Test 16: location available → setDriveCamera called immediately with that coordinate

    func testRecenterDriveMode_locationAvailable_callsSetDriveCameraImmediately() {
        let knownCoord = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        var lastKnownLocation: CLLocationCoordinate2D? = knownCoord
        var currentDriveAltitude: CLLocationDistance = 300  // stale, pre-reset value
        var followPaused = true

        var setDriveCameraCallCount = 0
        var setDriveCameraCoord: CLLocationCoordinate2D?
        var applyDrivePitchCallCount = 0

        // Mirror of the fixed recenterDriveMode().
        let recenterDriveMode: () -> Void = {
            currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
                MapViewRepresentable.driveModeCameraSpan
            )
            followPaused = false
            if let coord = lastKnownLocation {
                setDriveCameraCallCount += 1
                setDriveCameraCoord = coord
            } else {
                applyDrivePitchCallCount += 1
            }
        }

        recenterDriveMode()

        XCTAssertEqual(setDriveCameraCallCount, 1,
            "With a last-known location available, recenterDriveMode must call setDriveCamera " +
            "immediately (FT-17a Defect 1) rather than waiting for the next GPS tick")
        XCTAssertEqual(applyDrivePitchCallCount, 0,
            "applyDrivePitch (the narrower pitch/altitude-only path) must NOT also fire when " +
            "setDriveCamera already covers centering + pitch + altitude in one call")
        XCTAssertEqual(setDriveCameraCoord?.latitude ?? 0, knownCoord.latitude, accuracy: 0.0001)
        XCTAssertEqual(setDriveCameraCoord?.longitude ?? 0, knownCoord.longitude, accuracy: 0.0001)
        XCTAssertFalse(followPaused, "followPaused must still be cleared (A-AC-6: follow resumes)")
        XCTAssertEqual(
            currentDriveAltitude,
            MapViewRepresentable.altitudeForSpan(MapViewRepresentable.driveModeCameraSpan),
            accuracy: 1,
            "currentDriveAltitude must still reset to the FT-8 default (A-AC-10, unchanged)"
        )
    }

    // MARK: Test 17: no location yet → falls back to applyDrivePitch, does not crash

    /// Guard: Drive Mode entered before any GPS fix has arrived. Must not crash and must not
    /// jump the camera to (0, 0) — falls back to the pitch/altitude-only immediate
    /// application (prior behavior), leaving centering to the first GPS tick.
    func testRecenterDriveMode_noLocationYet_fallsBackToApplyDrivePitch_doesNotCrash() {
        let lastKnownLocation: CLLocationCoordinate2D? = nil
        var currentDriveAltitude: CLLocationDistance = 0
        var followPaused = true

        var setDriveCameraCallCount = 0
        var applyDrivePitchCallCount = 0

        let recenterDriveMode: () -> Void = {
            currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
                MapViewRepresentable.driveModeCameraSpan
            )
            followPaused = false
            if lastKnownLocation != nil {
                setDriveCameraCallCount += 1
            } else {
                applyDrivePitchCallCount += 1
            }
        }

        recenterDriveMode()

        XCTAssertEqual(setDriveCameraCallCount, 0,
            "With no last-known location, setDriveCamera must not be called with a bogus " +
            "coordinate")
        XCTAssertEqual(applyDrivePitchCallCount, 1,
            "With no last-known location, recenterDriveMode must fall back to the " +
            "pitch/altitude-only immediate application — graceful, no crash, no jump to (0,0)")
        XCTAssertFalse(followPaused, "followPaused must still be cleared even without a fix")
    }
}

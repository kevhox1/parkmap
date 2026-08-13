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
//  No Calendar.current.
//  No import SwiftUI (this file only exercises a pure MapViewRepresentable static function).
//

import XCTest
import MapKit
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

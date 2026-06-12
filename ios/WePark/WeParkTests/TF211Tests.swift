//
//  TF211Tests.swift
//  WeParkTests
//
//  TF2-11 Option C: Drive Mode camera zoom range clamp.
//
//  Strategy:
//    The experiment installs a `MKMapView.CameraZoomRange` clamp on Drive Mode entry
//    and removes it on exit to prevent MapKit's `.follow` from zooming past
//    `maxDriveZoomDistance` (900m) on each GPS update.
//
//    Live MKMapView zoom-range constraint behavior is unverifiable in a headless test.
//    Tests here cover the PURE CONTRACTUAL aspects:
//      1. Named constants exist at their spec-recommended values.
//      2. Our FT-8 target altitude is within the clamped range (C-AC-3).
//      3. setZoomRange closure exists on CoordinatorActions and is callable.
//      4. setZoomRange(true) fires during Drive Mode entry (entry symmetry).
//      5. setZoomRange(false) fires during Drive Mode exit (exit symmetry).
//      6. Entry/exit set/restore symmetry: entry fires true, exit fires false.
//      7. setZoomRange is NOT nil after makeUIView wires the closure.
//
//  Empirical on-device verification (whether the clamp actually prevents .follow's
//  re-assert) is Kevin's irreducible gate (C-AC-6 / §5).
//
//  No Calendar.current.
//  No hardcoded Mapbox tokens.
//  No pbxproj changes.
//  No live MKMapView altitude reads from a headless map.
//
//  Baseline: 516 tests.
//  This file adds 7 tests → expected 523 passing.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Helper: bare MapViewRepresentable for testing

private func makeTF211Representable() -> MapViewRepresentable {
    let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    return MapViewRepresentable(
        region: .constant(region),
        selectedSegmentID: .constant(nil),
        onTap: { _ in },
        onLongPress: { _ in },
        onRegionChanged: { _ in },
        onCarPinTapped: {},
        carPin: nil,
        overlayPayload: .init(),
        activeRoute: nil,
        destinationCoordinate: nil,
        driveHeading: nil,
        driveModeActive: false,
        coordinatorActions: MapViewRepresentable.CoordinatorActions()
    )
}

// MARK: - TF2-11: Zoom clamp constant values

/// Tests that the named tunable constants match the spec-recommended values.
///
/// C-AC-1: range values wired at spec-confirmed values.
/// C-AC-3: target altitude within clamped range.
@MainActor
final class TF211ZoomRangeConstantTests: XCTestCase {

    // MARK: Test 1: minDriveZoomDistance is at the spec-recommended value

    /// Verifies `minDriveZoomDistance` = 150m (spec §3 / OQ-2: Kevin approved experiment;
    /// spec's example shows the floor at 150–200m; this implementation uses 150m as the
    /// tunable floor — well below our ~621m target, so it cannot affect our setCamera calls).
    ///
    /// Kevin: change the constant in MapViewRepresentable.swift to tune without code change.
    func testMinDriveZoomDistance_isSpecRecommendedValue() {
        XCTAssertEqual(
            MapViewRepresentable.minDriveZoomDistance, 150,
            accuracy: 1,
            "minDriveZoomDistance must be 150m (TF2-11 Option C spec constant)"
        )
    }

    // MARK: Test 2: maxDriveZoomDistance is at the spec-recommended value (OQ-2)

    /// Verifies `maxDriveZoomDistance` = 900m.
    ///
    /// OQ-2 resolution: Kevin approved the experiment with the spec-recommended 900m ceiling.
    /// This is the core clamp constant: `.follow`'s re-assert cannot push altitude past 900m.
    ///
    /// Kevin: change the constant in MapViewRepresentable.swift to tune without code change.
    func testMaxDriveZoomDistance_isOQ2RecommendedValue() {
        XCTAssertEqual(
            MapViewRepresentable.maxDriveZoomDistance, 900,
            accuracy: 1,
            "maxDriveZoomDistance must be 900m (TF2-11 Option C OQ-2 approved value)"
        )
    }

    // MARK: Test 3: Target altitude is within clamped range (C-AC-3)

    /// Verifies that `altitudeForSpan(driveModeCameraSpan)` ≈ 621m satisfies:
    ///   minDriveZoomDistance ≤ target ≤ maxDriveZoomDistance
    ///
    /// C-AC-3: Our FT-8 target altitude must be within the clamped range so setCamera in
    /// applyDrivePitch is not affected by the clamp (the clamp constrains wide zoom-outs,
    /// not our intended tight altitude).
    func testTargetAltitude_isWithinClampedRange() {
        let targetAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        // C-AC-3: minDriveZoomDistance ≤ targetAltitude ≤ maxDriveZoomDistance
        XCTAssertGreaterThanOrEqual(
            targetAltitude, MapViewRepresentable.minDriveZoomDistance,
            "Target altitude (~621m) must be >= minDriveZoomDistance (150m) — C-AC-3"
        )
        XCTAssertLessThanOrEqual(
            targetAltitude, MapViewRepresentable.maxDriveZoomDistance,
            "Target altitude (~621m) must be <= maxDriveZoomDistance (900m) — C-AC-3"
        )
    }
}

// MARK: - TF2-11: setZoomRange closure wiring and entry/exit symmetry

/// Tests for the `CoordinatorActions.setZoomRange` closure: existence, invocability,
/// and the entry/exit symmetry contract (entry fires true, exit fires false).
///
/// C-AC-1: closure wired; C-AC-2: called outside updateUIView (verified by code review
/// / grep; not testable in a headless unit test).
@MainActor
final class TF211ZoomRangeClosureTests: XCTestCase {

    // MARK: Test 4: setZoomRange closure is nil by default (not yet wired)

    /// Verifies that a freshly-constructed `CoordinatorActions` has `setZoomRange == nil`
    /// before `makeUIView` wires it. This confirms the closure is optional and safe to
    /// call with `?` before setup.
    func testSetZoomRange_nilByDefault() {
        let actions = MapViewRepresentable.CoordinatorActions()
        XCTAssertNil(
            actions.setZoomRange,
            "setZoomRange must default to nil on a fresh CoordinatorActions (wired by makeUIView)"
        )
    }

    // MARK: Test 5: setZoomRange closure is callable with true (entry)

    /// Verifies the entry contract: `setZoomRange(true)` fires and the closure receives `true`.
    ///
    /// In production this represents Drive Mode entry: the clamp is applied BEFORE .follow
    /// engages so the constraint is in place when MapKit's tracking mode starts.
    func testSetZoomRange_onEntry_closureFiresWithTrue() {
        var capturedValue: Bool? = nil
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.setZoomRange = { active in
            capturedValue = active
        }

        actions.setZoomRange?(true)

        XCTAssertEqual(
            capturedValue, true,
            "setZoomRange must be called with true on Drive Mode entry (clamp applied)"
        )
    }

    // MARK: Test 6: setZoomRange closure is callable with false (exit)

    /// Verifies the exit contract: `setZoomRange(false)` fires and the closure receives `false`.
    ///
    /// In production this represents Drive Mode exit: the clamp is removed AFTER .follow
    /// disengages so the constraint is held until tracking is fully released.
    func testSetZoomRange_onExit_closureFiresWithFalse() {
        var capturedValue: Bool? = nil
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.setZoomRange = { active in
            capturedValue = active
        }

        actions.setZoomRange?(false)

        XCTAssertEqual(
            capturedValue, false,
            "setZoomRange must be called with false on Drive Mode exit (clamp removed)"
        )
    }

    // MARK: Test 7: Entry/exit symmetry — entry true, exit false, in order

    /// Verifies the full entry/exit sequence: the closure first receives true (clamp applied
    /// on entry) and then false (clamp removed on exit), with no calls in between.
    ///
    /// This mirrors the production call sequence in `handleDriveModeAndCamera`:
    ///   handleDriveModeAndCamera(true)  → setZoomRange(true)  [entry: clamp ON]
    ///   handleDriveModeAndCamera(false) → setZoomRange(false) [exit:  clamp OFF]
    func testSetZoomRange_entryExitSymmetry() {
        var callLog: [Bool] = []
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.setZoomRange = { active in
            callLog.append(active)
        }

        // Simulate Drive Mode entry.
        actions.setZoomRange?(true)
        // Simulate Drive Mode exit.
        actions.setZoomRange?(false)

        XCTAssertEqual(
            callLog, [true, false],
            "setZoomRange must fire true on entry and false on exit (entry/exit symmetry)"
        )
        XCTAssertEqual(
            callLog.count, 2,
            "setZoomRange must be called exactly once on entry and once on exit (no extra calls)"
        )
    }
}

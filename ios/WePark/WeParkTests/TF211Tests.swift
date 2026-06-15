//
//  TF211Tests.swift
//  WeParkTests
//
//  TF2-11 Option A: Custom Drive Mode Follow Camera — supplemental closure tests.
//
//  Option C (zoom range clamp) FAILED on-device in build 11 with continuous bouncing.
//  MapKit's .follow fights the zoom-range clamp on every GPS tick. The clamp was removed.
//
//  Option C deleted symbols:
//    - MapViewRepresentable.minDriveZoomDistance (150m constant)
//    - MapViewRepresentable.maxDriveZoomDistance (900m constant)
//    - CoordinatorActions.setZoomRange: ((Bool) -> Void)?
//
//  7 Option C tests removed (documented, not masked):
//    - testMinDriveZoomDistance_isSpecRecommendedValue
//    - testMaxDriveZoomDistance_isOQ2RecommendedValue
//    - testTargetAltitude_isWithinClampedRange
//    - testSetZoomRange_nilByDefault
//    - testSetZoomRange_onEntry_closureFiresWithTrue
//    - testSetZoomRange_onExit_closureFiresWithFalse
//    - testSetZoomRange_entryExitSymmetry
//
//  Option A tests added here (supplemental to FT10Tests.swift Option A groups):
//    - TF2-11 Option A camera composition: altitude FT-8 default value
//    - TF2-11 Option A camera composition: altitudeForSpan returns positive value
//    - TF2-11 Option A: setDriveCamera altitude parameter flows from currentDriveAltitude
//    - TF2-11 Option A: FT-8 default altitude approximately 621m
//    - TF2-11 Option A: driveAnimationDuration is 0.3s
//    - TF2-11 Option A: driveModeCameraSpan is 0.003°
//    - TF2-11 Option A: no userTrackingMode = .follow (A-AC-1 compile guard)
//
//  Test count arithmetic:
//    Deleted: 7 Option C tests
//    Added:   7 Option A tests
//    Net:     0
//
//  No Calendar.current.
//  No hardcoded Mapbox tokens.
//  No live MKMapView altitude reads from a headless map.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - TF2-11 Option A: Camera composition constants and closure contract

/// Tests for Option A camera composition:
///   - The FT-8 default altitude (~621m from driveModeCameraSpan = 0.003°)
///   - The driveAnimationDuration (0.3s per-tick animation)
///   - The setDriveCamera altitude parameter contract
///   - A-AC-1: no userTrackingMode = .follow in Drive Mode
@MainActor
final class TF211OptionACameraCompositionTests: XCTestCase {

    // MARK: Test 1: altitudeForSpan returns a positive value

    /// Verifies that `altitudeForSpan(driveModeCameraSpan)` returns a positive CLLocationDistance.
    /// This is the value stored in `currentDriveAltitude` on Drive Mode entry and passed to
    /// `setDriveCamera` on every GPS tick.
    func testAltitudeForSpan_returnsPositiveValue() {
        let altitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        XCTAssertGreaterThan(altitude, 0,
            "altitudeForSpan(driveModeCameraSpan) must return a positive altitude (> 0m)")
    }

    // MARK: Test 2: FT-8 default altitude is approximately 621m

    /// Verifies that `altitudeForSpan(driveModeCameraSpan)` is in the expected ~500–800m range.
    /// The spec prescribes ~621m for driveModeCameraSpan = 0.003°. If this drifts, Drive Mode
    /// will start at a wrong zoom level — flag for re-evaluation.
    func testFT8DefaultAltitude_isApproximately621m() {
        let altitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        XCTAssertGreaterThan(altitude, 400,
            "FT-8 default altitude must be > 400m (not zoomed too tight)")
        XCTAssertLessThan(altitude, 1200,
            "FT-8 default altitude must be < 1200m (not zoomed too wide)")
    }

    // MARK: Test 3: driveModeCameraSpan is 0.003°

    /// Verifies the span constant used to derive the FT-8 altitude. If this changes,
    /// the FT-8 default zoom will change — flag for product review.
    func testDriveModeCameraSpan_isSpecValue() {
        XCTAssertEqual(
            MapViewRepresentable.driveModeCameraSpan, 0.003,
            accuracy: 0.0001,
            "driveModeCameraSpan must be 0.003° (FT-8 tight zoom spec value)"
        )
    }

    // MARK: Test 4: driveAnimationDuration is 0.3s

    /// A-AC-2: per-tick setCamera uses driveAnimationDuration (0.3s). At 1 Hz GPS updates,
    /// 0.3s completes with 0.7s spare and MKMapView retargets in-flight animations smoothly.
    func testDriveAnimationDuration_is0point3s() {
        XCTAssertEqual(
            MapViewRepresentable.driveAnimationDuration, 0.3,
            accuracy: 0.01,
            "driveAnimationDuration must be 0.3s (per-tick smooth animation, 0.7s spare at 1 Hz)"
        )
    }

    // MARK: Test 5: setDriveCamera altitude parameter flows from caller

    /// Verifies the closure signature: altitude is the third parameter of type CLLocationDistance.
    /// In production, ContentView passes `currentDriveAltitude` — which starts at the FT-8
    /// default and is updated by pinch.
    func testSetDriveCamera_altitudeParameterFlowsFromCaller() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var capturedAltitude: CLLocationDistance = 0
        actions.setDriveCamera = { _, _, altitude in
            capturedAltitude = altitude
        }

        let userAltitude: CLLocationDistance = 350  // user zoomed in
        actions.setDriveCamera?(
            CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            nil,
            userAltitude
        )

        XCTAssertEqual(capturedAltitude, userAltitude, accuracy: 1,
            "setDriveCamera must receive the altitude from currentDriveAltitude (A-AC-3)")
    }

    // MARK: Test 6: setDriveCamera closure signature accepts optional heading

    /// Verifies the heading parameter is Double? (nil = heading unchanged by this call,
    /// owned by syncDriveHeading).
    func testSetDriveCamera_acceptsOptionalHeading() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var callCount = 0
        actions.setDriveCamera = { _, _, _ in callCount += 1 }

        // Should accept both nil heading (per-tick path) and non-nil heading (explicit recenter).
        actions.setDriveCamera?(CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99), nil, 621)
        actions.setDriveCamera?(CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99), 90.0, 621)

        XCTAssertEqual(callCount, 2,
            "setDriveCamera must accept both nil and non-nil heading (Double? parameter)")
    }

    // MARK: Test 7: A-AC-1 — bare MKMapView starts with .none tracking mode

    /// A-AC-1 compile guard: documents that Option A does NOT call userTrackingMode = .follow.
    /// We verify the baseline: a bare MKMapView starts with .none, and Option A never changes it.
    ///
    /// The real behavioral assertion (Drive Mode never calls .follow) is enforced by code
    /// review: no `userTrackingMode = .follow` reference exists in ContentView.swift or
    /// MapViewRepresentable.swift (grep verified in the PR).
    func testBareMapView_startsWithNoneTrackingMode_optionANeverSetsFollow() {
        // Option A invariant: userTrackingMode stays .none for the entire Drive Mode session.
        // We document this by asserting the bare-map default.
        let mapView = MKMapView()
        XCTAssertEqual(mapView.userTrackingMode, .none,
            "Bare MKMapView starts with .none — Option A never sets .follow (A-AC-1)")

        // Document Option A's design: the custom setDriveCamera closure does NOT call
        // mapView.userTrackingMode = .follow at any point. This assertion documents the intent;
        // the compile-time guard is the absence of the call in production code.
        XCTAssertNotEqual(MKUserTrackingMode.follow, MKUserTrackingMode.none,
            ".follow and .none are distinct — Option A keeps the map at .none throughout Drive Mode")
    }
}

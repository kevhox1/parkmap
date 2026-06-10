//
//  FT7Tests.swift
//  WeParkTests
//
//  FT-7: Heading source + animation unit tests.
//
//  Test groups (per spec §6):
//    1. Heading-source pure-logic tests (AC-FT7.1–AC-FT7.6)
//    2. Shortest-arc rotation helper tests (AC-FT7.7–AC-FT7.8c)
//
//  Architecture note: tests follow the pure-function strategy.
//  `selectDriveHeadingSource` and `shortestArcDelta` have no framework dependencies
//  and are directly unit-testable.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//  No MKMapView camera reads (pure-function strategy).
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Group 1: Heading-source pure-logic tests

final class FT7HeadingSourceTests: XCTestCase {

    // MARK: AC-FT7.1 — Moving in Drive Mode → GPS course returned

    /// When driveModeActive=true and speed >= threshold, selectDriveHeadingSource returns
    /// the GPS course and ignores the magnetometer heading.
    /// Verifies the root-cause fix: magnetometer no longer dominates while driving.
    func testSelectDriveHeadingSource_movingInDriveMode_returnsCourse() {
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: 90.0,
            speed: 5.0,
            driveModeActive: true
        )
        XCTAssertNotNil(result, "Moving in Drive Mode should return a heading, not nil")
        XCTAssertEqual(result!, 45.0, accuracy: 0.001,
            "Moving in Drive Mode should return GPS course (45°), not magnetometer (90°). Got: \(result!)")
    }

    // MARK: AC-FT7.2 — Moving in Drive Mode, course unavailable → nil

    /// When driveModeActive=true, speed >= threshold, but GPS course is nil,
    /// selectDriveHeadingSource returns nil to trigger freeze-on-stop behavior.
    func testSelectDriveHeadingSource_movingInDriveMode_noCourse_returnsNil() {
        let result = selectDriveHeadingSource(
            course: nil,
            magnetometerHeading: 90.0,
            speed: 5.0,
            driveModeActive: true
        )
        XCTAssertNil(result,
            "Moving in Drive Mode with no GPS course should return nil (freeze on last good heading)")
    }

    // MARK: AC-FT7.3 — Stopped in Drive Mode → nil (freeze-on-stop)

    /// When driveModeActive=true but speed < threshold, selectDriveHeadingSource returns nil
    /// regardless of course availability, signaling the EMA stabilizer to freeze.
    ///
    /// Build-7: gate lowered from 1.8 → 0.5 m/s (TF2-3 #2 fix). A truly stopped car
    /// (0.0 m/s) must still freeze.
    func testSelectDriveHeadingSource_stoppedInDriveMode_returnsNil() {
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: 90.0,
            speed: 0.0,
            driveModeActive: true
        )
        XCTAssertNil(result,
            "Stopped in Drive Mode (speed 0.0 m/s < 0.5 threshold) should return nil (freeze-on-stop)")
    }

    // MARK: AC-FT7.1 variant — exact speed gate boundary (build-7: 0.5 m/s)

    /// Speed exactly at DRIVING_HEADING_MIN_SPEED_MPS (0.5 m/s after build-7 fix) should
    /// be treated as moving and return GPS course.
    func testSelectDriveHeadingSource_exactSpeedGate_returnsCourse() {
        let result = selectDriveHeadingSource(
            course: 180.0,
            magnetometerHeading: 270.0,
            speed: 0.5,
            driveModeActive: true
        )
        XCTAssertNotNil(result, "Speed exactly at gate (0.5 m/s) should return a heading, not nil")
        XCTAssertEqual(result!, 180.0, accuracy: 0.001,
            "Speed exactly at gate (0.5 m/s) should return GPS course (180°). Got: \(result!)")
    }

    // MARK: AC-FT7.3 variant — speed just below gate (build-7: below 0.5 m/s)

    /// Speed just below DRIVING_HEADING_MIN_SPEED_MPS (0.49 m/s) should freeze.
    func testSelectDriveHeadingSource_justBelowSpeedGate_returnsNil() {
        let result = selectDriveHeadingSource(
            course: 180.0,
            magnetometerHeading: 270.0,
            speed: 0.49,
            driveModeActive: true
        )
        XCTAssertNil(result,
            "Speed just below gate (0.49 m/s) should return nil (freeze-on-stop). Got: \(result as Any)")
    }

    // MARK: Build-7 TF2-3 #2 — cruise speed (0.8 m/s) stays live after gate lowered to 0.5

    /// Parking-hunt / cruise speeds (~0.5–1.5 m/s) should now return GPS course after the
    /// build-7 gate lowering from 1.8 → 0.5 m/s. This verifies the TF2-3 #2 fix.
    func testSelectDriveHeadingSource_cruiseSpeed_returnsGPSCourse_afterBuild7Fix() {
        // 0.8 m/s ≈ slow roll / parking creep. Was below the old 1.8 m/s gate (would freeze);
        // now above the new 0.5 m/s gate (should stay live).
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: 270.0,
            speed: 0.8,
            driveModeActive: true
        )
        XCTAssertNotNil(result,
            "Cruise speed 0.8 m/s should now return GPS course (above build-7 gate of 0.5 m/s)")
        XCTAssertEqual(result!, 45.0, accuracy: 0.001,
            "Cruise speed 0.8 m/s should return GPS course (45°). Got: \(result as Any)")
    }

    // MARK: Not in Drive Mode — magnetometer heading returned

    /// When driveModeActive=false, selectDriveHeadingSource returns the magnetometer heading
    /// for compass display (not affected by speed).
    func testSelectDriveHeadingSource_notInDriveMode_returnsMagnetometerHeading() {
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: 90.0,
            speed: 5.0,
            driveModeActive: false
        )
        XCTAssertNotNil(result, "Not in Drive Mode should return a heading, not nil")
        XCTAssertEqual(result!, 90.0, accuracy: 0.001,
            "Not in Drive Mode should return magnetometer heading (90°). Got: \(result!)")
    }

    // MARK: Not in Drive Mode, no magnetometer → nil

    /// When driveModeActive=false and magnetometerHeading=nil, returns nil.
    func testSelectDriveHeadingSource_notInDriveMode_noMagnetometer_returnsNil() {
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: nil,
            speed: 5.0,
            driveModeActive: false
        )
        XCTAssertNil(result,
            "Not in Drive Mode with no magnetometer should return nil. Got: \(result as Any)")
    }

    // MARK: AC-FT7.4 — Freeze-on-stop: stabilizedHeading preserves last good heading

    /// After establishing a lastGoodHeading via a moving tick,
    /// calling stabilizedHeading with speed below threshold preserves driveHeading.
    func testStabilizedHeading_freezeOnStop_preservesLastGoodHeading() {
        let service = LocationService()

        // First tick: moving at speed with a valid heading → establish lastGoodHeading.
        let coord1 = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.990)
        let coord2 = CLLocationCoordinate2D(latitude: 40.751, longitude: -73.990)

        // Prime prevDriveCoordinate by calling once.
        _ = service.stabilizedHeading(rawHeading: 45.0, speed: 5.0, current: coord1)
        // Second call with speed above gate should set driveHeading.
        let goodHeading = service.stabilizedHeading(rawHeading: 45.0, speed: 5.0, current: coord2)
        XCTAssertNotNil(goodHeading, "Should have a good heading after moving tick")

        // Now call with speed clearly below gate (0.0 m/s = fully stopped).
        // Build-7: gate is now 0.5 m/s; 0.5 is AT the gate (returns course), so use 0.0.
        let frozenHeading = service.stabilizedHeading(rawHeading: 45.0, speed: 0.0, current: coord2)
        XCTAssertNotNil(frozenHeading, "Freeze-on-stop should preserve last good heading (not nil)")
        XCTAssertEqual(frozenHeading!, goodHeading!, accuracy: 1.0,
            "Freeze-on-stop should return same heading as last good value")
    }

    // MARK: AC-FT7.5 — Course-from-movement fallback (existing W85cTests test preserved)

    /// Verifies that stabilizedHeading computes bearing from movement when rawHeading is nil.
    /// This test mirrors testStabilizedHeading_courseFromMovement_whenHeadingNil in W85cTests.swift.
    func testStabilizedHeading_courseFromMovement_nilHeading_northward() {
        let service = LocationService()
        let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.990)

        // Establish prev coordinate slightly south.
        let prevCoord = CLLocationCoordinate2D(latitude: anchor.latitude - 0.001, longitude: anchor.longitude)
        _ = service.stabilizedHeading(rawHeading: nil, speed: 5.0, current: prevCoord)

        // Move north (bearing ~0°) with nil heading.
        let result = service.stabilizedHeading(rawHeading: nil, speed: 5.0, current: anchor)
        XCTAssertNotNil(result, "Should compute bearing from movement when rawHeading is nil")
        let nearNorth = result! <= 15.0 || result! >= 345.0
        XCTAssertTrue(nearNorth,
            "Northward movement should produce ~0° bearing. Got \(result!)")
    }

    // MARK: AC-FT7.6 — didUpdateHeading gate: magnetometer ignored while moving in Drive Mode

    /// Verifies the intent of the didUpdateHeading gate: when driveModeActive and speed >= gate,
    /// the magnetometer heading is NOT used to update driveHeading.
    /// We test this via selectDriveHeadingSource (the pure extraction of the gate logic).
    func testDidUpdateHeadingGate_movingInDriveMode_magnetometerIgnored() {
        // Simulate: driveModeActive=true, speed=10.0 m/s (clearly above 1.8 m/s gate).
        // Magnetometer heading is 200° (what the phone thinks due to cup-holder angle).
        // GPS course is 45° (actual travel direction).
        // The gate should ignore the 200° magnetometer value.
        let result = selectDriveHeadingSource(
            course: 45.0,
            magnetometerHeading: 200.0,
            speed: 10.0,
            driveModeActive: true
        )
        // The magnetometer value (200°) should NOT appear in the result.
        XCTAssertNotEqual(result ?? -1, 200.0,
            "Magnetometer heading (200°) must NOT be used while moving in Drive Mode")
        // GPS course (45°) should be returned.
        XCTAssertNotNil(result, "GPS course should be returned while moving in Drive Mode")
        XCTAssertEqual(result!, 45.0, accuracy: 0.001,
            "GPS course (45°) must be the heading source while moving in Drive Mode. Got: \(result!)")
    }
}

// MARK: - Group 2: Shortest-arc rotation helper tests

@MainActor
final class FT7ShortestArcTests: XCTestCase {

    // MARK: AC-FT7.7 — Small positive delta

    /// shortestArcDelta(from: 0, to: 3° in radians) returns approximately +3°.
    func testShortestArcDelta_smallPositiveDelta() {
        let fromAngle: CGFloat = 0
        let toAngle: CGFloat = CGFloat(3.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: fromAngle, to: toAngle)
        XCTAssertEqual(delta, toAngle, accuracy: 0.0001,
            "0° to 3° should return +3° delta. Got: \(delta * 180 / .pi)°")
    }

    // MARK: AC-FT7.8 — Wrap-around: 359° to 1° should be +2°, not -358°

    /// Verifies the wrap-around case: rotating from 359° to 1° takes the short arc (+2°).
    func testShortestArcDelta_wraparound_positiveShortArc() {
        let from: CGFloat = CGFloat(359.0 * .pi / 180.0)
        let to: CGFloat = CGFloat(1.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: to)
        let expectedDeg: CGFloat = 2.0
        let expected = expectedDeg * .pi / 180.0
        XCTAssertEqual(delta, expected, accuracy: 0.001,
            "359° → 1° should take short arc (+2°). Got: \(delta * 180 / .pi)°")
    }

    // MARK: AC-FT7.8b — Wrap-around: 1° to 359° should be -2°

    /// Verifies the wrap-around case: rotating from 1° to 359° takes the short arc (-2°).
    func testShortestArcDelta_wraparound_negativeShortArc() {
        let from: CGFloat = CGFloat(1.0 * .pi / 180.0)
        let to: CGFloat = CGFloat(359.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: to)
        let expectedDeg: CGFloat = -2.0
        let expected = expectedDeg * .pi / 180.0
        XCTAssertEqual(delta, expected, accuracy: 0.001,
            "1° → 359° should take short arc (-2°). Got: \(delta * 180 / .pi)°")
    }

    // MARK: AC-FT7.8c — 90° to 270°: absolute value is π (tiebreak direction not specified)

    /// For the exact 180° case (90° to 270°), the delta absolute value is π.
    /// The tiebreak direction is implementation-defined; we only assert abs(delta) ≈ π.
    func testShortestArcDelta_exactHalfCircle() {
        let from: CGFloat = CGFloat(90.0 * .pi / 180.0)
        let to: CGFloat = CGFloat(270.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: to)
        XCTAssertEqual(abs(delta), .pi, accuracy: 0.001,
            "90° → 270° should produce abs(delta) = π (180°). Got: \(abs(delta) * 180 / .pi)°")
    }

    // MARK: Zero delta

    /// shortestArcDelta(from: x, to: x) should return 0.
    func testShortestArcDelta_zeroDelta() {
        let angle: CGFloat = CGFloat(45.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: angle, to: angle)
        XCTAssertEqual(delta, 0, accuracy: 0.0001, "Same angle should produce 0 delta")
    }

    // MARK: Large positive rotation (less than 180°)

    /// 45° to 135° should be +90°.
    func testShortestArcDelta_largePositive() {
        let from: CGFloat = CGFloat(45.0 * .pi / 180.0)
        let to: CGFloat = CGFloat(135.0 * .pi / 180.0)
        let expected: CGFloat = CGFloat(90.0 * .pi / 180.0)
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: to)
        XCTAssertEqual(delta, expected, accuracy: 0.001, "45° → 135° should be +90°. Got: \(delta * 180 / .pi)°")
    }

    // MARK: Build-7 TF2-3 #1 — Puck rotation target is identity (0) in drive mode

    /// The puck rotation target in drive mode is 0 (screen-up / identity).
    /// On a heading-up map the camera already rotates travel direction to screen-up,
    /// so the puck (which points north at rest) should stay at 0 screen rotation.
    ///
    /// This test verifies that shortestArcDelta(from: currentAngle, to: 0) produces the
    /// correct shortest-arc correction for any arbitrary non-zero puck angle — the
    /// mathematical core of the build-7 puck double-rotation fix.

    func testPuckRotation_target_isIdentity_fromNorth() {
        // Puck already at 0 (north) — delta should be 0.
        let delta = MapViewRepresentable.shortestArcDelta(from: 0, to: 0)
        XCTAssertEqual(delta, 0, accuracy: 0.0001,
            "Puck already at 0 (identity) should produce 0 delta")
    }

    func testPuckRotation_target_isIdentity_fromEast() {
        // Puck at 90° (east) — shortestArc to 0 should be -π/2 (CCW 90°).
        let from: CGFloat = CGFloat(90.0 * .pi / 180.0)
        let target: CGFloat = 0
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: target)
        let expected: CGFloat = CGFloat(-90.0 * .pi / 180.0)
        XCTAssertEqual(delta, expected, accuracy: 0.001,
            "Puck at 90° to target 0 should return -π/2 (CCW 90°). Got: \(delta * 180 / .pi)°")
    }

    func testPuckRotation_target_isIdentity_fromSouth() {
        // Puck at 180° — shortestArc to 0 is ±π (either 180° direction; abs = π).
        let from: CGFloat = .pi
        let target: CGFloat = 0
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: target)
        XCTAssertEqual(abs(delta), .pi, accuracy: 0.001,
            "Puck at 180° to target 0 should return abs = π. Got: \(abs(delta) * 180 / .pi)°")
    }

    func testPuckRotation_target_isIdentity_from359() {
        // Puck at 359° — shortestArc to 0 is +1° (1 degree CW), not -359°.
        let from: CGFloat = CGFloat(359.0 * .pi / 180.0)
        let target: CGFloat = 0
        let delta = MapViewRepresentable.shortestArcDelta(from: from, to: target)
        let expected: CGFloat = CGFloat(1.0 * .pi / 180.0)
        XCTAssertEqual(delta, expected, accuracy: 0.001,
            "Puck at 359° to target 0 should take short arc (+1°). Got: \(delta * 180 / .pi)°")
    }
}

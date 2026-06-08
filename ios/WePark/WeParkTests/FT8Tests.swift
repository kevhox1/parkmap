//
//  FT8Tests.swift
//  WeParkTests
//
//  FT-8: Drive zoom tightening unit tests.
//
//  Test groups (per spec §6 Group 4):
//    AC-FT8.1 — driveModeCameraSpan equals 0.003
//    AC-FT8.2 — altitudeForSpan(0.003) is in [550, 700] m
//    AC-FT8.3 — altitudeForSpan(driveModeCameraSpan) < altitudeForSpan(0.005)
//
//  Architecture note: tests follow the pure-function strategy.
//  All assertions are on static constants and pure static functions with no MKMapView dependency.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//  No MKMapView camera reads (pure-function strategy).
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

final class FT8ZoomTests: XCTestCase {

    // MARK: AC-FT8.1 — driveModeCameraSpan equals 0.003 (FT-8 tightened value)

    /// Verifies the span constant is exactly the FT-8 target value.
    /// If this fails, the constant was not updated from its previous value (0.005°).
    func testDriveModeCameraSpan_equalsFT8Value() {
        XCTAssertEqual(
            MapViewRepresentable.driveModeCameraSpan,
            0.003,
            accuracy: 0.00001,
            "driveModeCameraSpan must be 0.003° (FT-8 tightened from 0.005°). " +
            "Got: \(MapViewRepresentable.driveModeCameraSpan)°"
        )
    }

    // MARK: AC-FT8.2 — altitudeForSpan(0.003) in [550, 700] m

    /// Verifies that the altitude formula produces a value in the expected [550, 700] m range
    /// for the FT-8 target span (0.003°).
    ///
    /// Formula: altitude = (0.003/2 * 111,000) / tan(15°) = 166.5 / 0.2679 ≈ 621 m.
    /// Range [550, 700] gives tolerance for FP precision and any MapKit vertical-FOV variation.
    func testAltitudeForSpan_FT8Value_inExpectedRange() {
        let altitude = MapViewRepresentable.altitudeForSpan(0.003)
        XCTAssertGreaterThanOrEqual(altitude, 550,
            "altitudeForSpan(0.003°) should be >= 550m (FT-8 range). Got: \(altitude)m")
        XCTAssertLessThanOrEqual(altitude, 700,
            "altitudeForSpan(0.003°) should be <= 700m (FT-8 range). Got: \(altitude)m")
    }

    // MARK: AC-FT8.3 — New span produces lower (tighter) altitude than old 0.005° span

    /// Confirms the FT-8 tightening is correctly reflected in the altitude:
    /// driveModeCameraSpan (0.003°) must produce a lower altitude than 0.005°.
    /// This test remains valid regardless of which specific value Kevin tunes to — it just
    /// asserts the new constant is tighter than the old one.
    func testAltitudeForSpan_newSpan_tighterThanOld() {
        let newAltitude = MapViewRepresentable.altitudeForSpan(MapViewRepresentable.driveModeCameraSpan)
        let oldAltitude = MapViewRepresentable.altitudeForSpan(0.005)
        XCTAssertLessThan(newAltitude, oldAltitude,
            "FT-8: new span (\(MapViewRepresentable.driveModeCameraSpan)°) altitude (\(newAltitude)m) " +
            "must be less than old 0.005° altitude (\(oldAltitude)m)")
    }

    // MARK: Sanity: altitudeForSpan(driveModeCameraSpan) is positive

    /// Complementary to the range check — altitude must be positive.
    func testAltitudeForSpan_driveModeCameraSpan_isPositive() {
        let altitude = MapViewRepresentable.altitudeForSpan(MapViewRepresentable.driveModeCameraSpan)
        XCTAssertGreaterThan(altitude, 0,
            "altitudeForSpan(driveModeCameraSpan) must be positive. Got: \(altitude)m")
    }

    // MARK: driveAnimationDuration constant sanity check

    /// Verifies the FT-7 animation duration constant is set to the spec value (0.3s).
    /// Kevin can tune this on-device; this test anchors the shipped value.
    func testDriveAnimationDuration_isSpecValue() {
        XCTAssertEqual(
            MapViewRepresentable.driveAnimationDuration,
            0.3,
            accuracy: 0.001,
            "driveAnimationDuration must be 0.3s (spec §5). Got: \(MapViewRepresentable.driveAnimationDuration)s"
        )
    }
}

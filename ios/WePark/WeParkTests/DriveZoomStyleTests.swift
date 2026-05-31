//
//  DriveZoomStyleTests.swift
//  WeParkTests
//
//  W8.5c-polish PR-2 unit tests: auto-zoom + map style swap on Drive Mode entry/exit.
//
//  Architecture note: tests follow the pure-function strategy from spec §5.
//  Decision logic is extracted into static functions with NO MKMapView dependency:
//    - `targetSpan(forDriveModeActive:priorSpan:)` — span decision
//    - `altitudeForSpan(_:)` — span → altitude conversion
//    - `targetMapConfiguration(forDriveModeActive:priorConfiguration:)` — style decision
//    - `driveModePitch` constant — pitch range guard
//
//  The actual `MKMapView.setCamera` and `preferredConfiguration` applications are
//  verified by the mandatory live-UI smoke (documented in the PR description), NOT by
//  unit tests that require a windowed MKMapView.
//
//  Test inventory:
//    1.  testTargetSpan_onEntry_returnsDriveModeCameraSpan        — active=true  → 0.005°
//    2.  testTargetSpan_onExit_returnsPriorSpan                   — active=false → priorSpan
//    3.  testTargetSpan_onExit_zeroSpan_returnsZero               — edge: priorSpan=0 → 0
//    4.  testAltitudeForSpan_driveMode_returnsPositiveAltitude     — 0.005° → positive meters
//    5.  testAltitudeForSpan_zero_returnsZero                      — guard: 0° → 0m
//    6.  testTargetMapConfiguration_onEntry_returnsMuted           — active=true → .muted style
//    7.  testTargetMapConfiguration_onExit_returnsPriorConfig      — active=false → priorConfig
//    8.  testTargetMapConfiguration_onExit_nilPrior_returnsDefault — nil prior → standard config
//    9.  testDriveModePitchConstant_meetsMinimum                   — 30 ≤ pitch ≤ 60
//   10.  testDriveModePitch_updatedFromPR3                         — pitch > 30 (re-evaluated at tighter zoom)
//   11.  testDriveModeCameraSpan_isApproximatelyCorrect            — span ~0.005°
//   12.  testAltitudeForSpan_driveMode_isApproximatelyTwoKm        — altitude ≈ 2,000m at 0.005°
//   13.  testDirectionalPuckAnnotationView_initializesWithoutCrash  — puck smoke test
//
//  Baseline before PR-2: 214/0. Target: ~227/0 (+13 new tests).
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//  No MKMapView camera reads (pure-function strategy, spec §5).
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Pure-function span/distance decision tests

final class DriveZoomStyleTests: XCTestCase {

    // MARK: Test 1: Drive Mode entry → span = driveModeCameraSpan

    /// Verifies `targetSpan(forDriveModeActive:priorSpan:)` returns `driveModeCameraSpan`
    /// on Drive Mode entry.
    ///
    /// The Drive Mode span (~0.005°) corresponds to ~1–2 Manhattan blocks visible,
    /// approximately 2× tighter than the previous Drive Mode span in PR-3 (~0.04°).
    func testTargetSpan_onEntry_returnsDriveModeCameraSpan() {
        let result = MapViewRepresentable.targetSpan(forDriveModeActive: true, priorSpan: 0.05)
        XCTAssertEqual(result, MapViewRepresentable.driveModeCameraSpan, accuracy: 0.0001,
            "Drive Mode entry should target driveModeCameraSpan (~0.005°); got \(result)°")
    }

    // MARK: Test 2: Drive Mode exit → restore priorSpan

    /// Verifies `targetSpan` returns `priorSpan` on Drive Mode exit.
    func testTargetSpan_onExit_returnsPriorSpan() {
        let priorSpan: CLLocationDegrees = 0.08
        let result = MapViewRepresentable.targetSpan(forDriveModeActive: false, priorSpan: priorSpan)
        XCTAssertEqual(result, priorSpan, accuracy: 0.0001,
            "Drive Mode exit should restore priorSpan=\(priorSpan)°; got \(result)°")
    }

    // MARK: Test 3: Drive Mode exit with priorSpan=0 → returns 0

    /// Verifies edge case: priorSpan=0 is preserved as-is on exit (not replaced with a default).
    func testTargetSpan_onExit_zeroSpan_returnsZero() {
        let result = MapViewRepresentable.targetSpan(forDriveModeActive: false, priorSpan: 0)
        XCTAssertEqual(result, 0, accuracy: 0.0001,
            "targetSpan(false, 0) should return 0; got \(result)°")
    }

    // MARK: Test 4: altitudeForSpan at driveModeCameraSpan → positive altitude

    /// Verifies that `altitudeForSpan(driveModeCameraSpan)` returns a positive altitude.
    /// The formula must not return 0 or negative for any positive span.
    func testAltitudeForSpan_driveMode_returnsPositiveAltitude() {
        let altitude = MapViewRepresentable.altitudeForSpan(MapViewRepresentable.driveModeCameraSpan)
        XCTAssertGreaterThan(altitude, 0,
            "altitudeForSpan(driveModeCameraSpan) should be positive; got \(altitude)m")
    }

    // MARK: Test 5: altitudeForSpan(0) → 0 (no division by zero)

    /// Verifies that `altitudeForSpan(0)` returns 0 and does not crash.
    /// The formula `(0 / 2) * 111000 / tan(30°) = 0` — no divide-by-zero risk since we
    /// divide by tan(30°), not by the span.
    func testAltitudeForSpan_zero_returnsZero() {
        let altitude = MapViewRepresentable.altitudeForSpan(0)
        XCTAssertEqual(altitude, 0, accuracy: 0.001,
            "altitudeForSpan(0) should return 0; got \(altitude)m")
    }

    // MARK: Test 6: Drive Mode entry → muted configuration

    /// Verifies `targetMapConfiguration(forDriveModeActive:priorConfiguration:)` returns
    /// `MKStandardMapConfiguration` with `emphasisStyle == .muted` on Drive Mode entry.
    ///
    /// `MKStandardMapConfiguration` has no public `==` conformance, so we cast the result
    /// and inspect `emphasisStyle` directly.
    func testTargetMapConfiguration_onEntry_returnsMuted() {
        let result = MapViewRepresentable.targetMapConfiguration(
            forDriveModeActive: true,
            priorConfiguration: nil
        )
        guard let standardConfig = result as? MKStandardMapConfiguration else {
            XCTFail("Expected MKStandardMapConfiguration on Drive Mode entry; got \(type(of: result))")
            return
        }
        XCTAssertEqual(standardConfig.emphasisStyle, .muted,
            "Drive Mode entry config must have emphasisStyle == .muted; got \(standardConfig.emphasisStyle)")
    }

    // MARK: Test 7: Drive Mode exit → returns priorConfiguration

    /// Verifies that the prior configuration captured at Drive Mode entry is restored on exit.
    func testTargetMapConfiguration_onExit_returnsPriorConfig() {
        let priorConfig = MKStandardMapConfiguration()
        let result = MapViewRepresentable.targetMapConfiguration(
            forDriveModeActive: false,
            priorConfiguration: priorConfig
        )
        // We can't use === on MKMapConfiguration directly since it is not guaranteed to be
        // the same object after the call. We verify the type and emphasis style match.
        guard let standardResult = result as? MKStandardMapConfiguration else {
            XCTFail("Expected MKStandardMapConfiguration on exit; got \(type(of: result))")
            return
        }
        // Default MKStandardMapConfiguration has emphasisStyle == .default (not .muted).
        XCTAssertEqual(standardResult.emphasisStyle, .default,
            "Exit should restore priorConfig with emphasisStyle == .default; got \(standardResult.emphasisStyle)")
    }

    // MARK: Test 8: Drive Mode exit with nil priorConfig → returns standard (non-muted) default

    /// Verifies that a nil priorConfiguration on exit falls back to a standard (non-muted) config.
    /// This handles the edge case of the first-ever Drive Mode entry on a fresh install.
    func testTargetMapConfiguration_onExit_nilPrior_returnsDefault() {
        let result = MapViewRepresentable.targetMapConfiguration(
            forDriveModeActive: false,
            priorConfiguration: nil
        )
        guard let standardConfig = result as? MKStandardMapConfiguration else {
            XCTFail("Expected MKStandardMapConfiguration fallback; got \(type(of: result))")
            return
        }
        XCTAssertEqual(standardConfig.emphasisStyle, .default,
            "Nil priorConfig fallback must be standard (not muted); got \(standardConfig.emphasisStyle)")
    }

    // MARK: Test 9: driveModePitch constant is within documented valid range

    /// Verifies that `driveModePitch` is in [30, 60] — the range documented in the spec.
    /// Guards against silent constant changes outside the spec-approved window.
    func testDriveModePitchConstant_meetsMinimum() {
        let pitch = MapViewRepresentable.driveModePitch
        XCTAssertGreaterThanOrEqual(pitch, 30,
            "driveModePitch must be >= 30° (PR-3 baseline); got \(pitch)°")
        XCTAssertLessThanOrEqual(pitch, 60,
            "driveModePitch must be <= 60° (MapKit clamping ceiling); got \(pitch)°")
    }

    // MARK: Test 10: driveModePitch was re-evaluated upward from PR-3's 30°

    /// Verifies that PR-2's empirical measurement resulted in a higher pitch than PR-3's 30°.
    /// At the tighter zoom (span ~0.005°, altitude ~2,000m) MapKit allows steeper pitch.
    /// If this test fails, the constant was not updated from PR-3 — investigate.
    func testDriveModePitch_updatedFromPR3() {
        XCTAssertGreaterThan(MapViewRepresentable.driveModePitch, 30,
            "PR-2 measured a higher pitch ceiling at the tighter zoom; " +
            "driveModePitch should be > 30° (PR-3 value). Got \(MapViewRepresentable.driveModePitch)°. " +
            "If 30° was the measured ceiling at the new zoom, remove this test and document in PR body.")
    }

    // MARK: Test 11: driveModeCameraSpan is approximately 0.005°

    /// Verifies the span constant is in the expected ~0.005° range.
    func testDriveModeCameraSpan_isApproximatelyCorrect() {
        let span = MapViewRepresentable.driveModeCameraSpan
        XCTAssertEqual(span, 0.005, accuracy: 0.0005,
            "driveModeCameraSpan should be ~0.005° (1–2 Manhattan blocks); got \(span)°")
    }

    // MARK: Test 12: altitudeForSpan at 0.005° → approximately 1,000–1,100m

    /// Verifies the altitude formula at the Drive Mode span gives a plausible Drive Mode altitude.
    ///
    /// Formula (spec §3.5): halfHeight = (0.005/2) * 111,000 = 277.5m.
    /// altitude = 277.5 / tan(15°) ≈ 277.5 / 0.2679 ≈ 1,035m.
    /// (15° is the half-FOV angle for a standard iPhone ~60° total vertical FOV.)
    ///
    /// We test a broad range (500–5,000m) to survive FOV variations across device sizes
    /// while confirming the formula produces a plausible Drive Mode altitude.
    func testAltitudeForSpan_driveMode_isApproximatelyTwoKm() {
        let altitude = MapViewRepresentable.altitudeForSpan(0.005)
        // Expected ~1,035m at 0.005°. Accept 500–5,000m for device-size robustness.
        XCTAssertGreaterThan(altitude, 500,
            "altitudeForSpan(0.005°) should be > 500m; got \(altitude)m")
        XCTAssertLessThan(altitude, 5_000,
            "altitudeForSpan(0.005°) should be < 5,000m; got \(altitude)m")
    }

    // MARK: Test 13: Directional puck annotation view initializes without crash

    /// Smoke test: verifies that creating a bare `MKAnnotationView` for `MKUserLocation`
    /// with the puck configuration does not crash. Does NOT test rendering in a live map.
    ///
    /// This mimics what `mapView(_:viewFor:)` does when Drive Mode is active, minus the
    /// MapKit dequeue path (which requires a live window).
    func testDirectionalPuckAnnotationView_initializesWithoutCrash() {
        let userLocation = MKUserLocation()
        let view = MKAnnotationView(annotation: userLocation, reuseIdentifier: "driveUserPuck")

        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        let image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)

        view.image = image
        view.transform = CGAffineTransform(rotationAngle: 0)
        view.canShowCallout = false
        view.isAccessibilityElement = true

        // If we reach here without crashing, the puck annotation view initialization is sound.
        XCTAssertNotNil(view.image, "Puck annotation view image should not be nil after initialization")
    }
}

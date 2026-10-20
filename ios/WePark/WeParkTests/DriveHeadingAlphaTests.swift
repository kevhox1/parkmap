//
//  DriveHeadingAlphaTests.swift
//  WeParkTests
//
//  Open item #36 (Kevin, field feedback 2026-10-20): "can we have it update more
//  frequently? It lags sometimes." Root cause: the flat `DRIVING_HEADING_EMA_ALPHA = 0.35`
//  made post-turn heading convergence take ~3-4s. Fix: `driveHeadingEMAAlpha(speed:)`, a
//  pure, `nonisolated` function that speed-scales the EMA alpha (LocationService.swift).
//
//  Group 1: `driveHeadingEMAAlpha(speed:)` pure-function boundary/interpolation tests.
//  Group 2: regression — `stabilizedHeading`'s circular-wraparound math is unchanged at
//  both the low and high alpha (only the convergence RATE should differ, never the
//  wraparound correctness).
//
//  No Calendar.current use. No hardcoded Mapbox tokens.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Group 1: driveHeadingEMAAlpha(speed:) pure-function tests

final class DriveHeadingEMAAlphaTests: XCTestCase {

    // MARK: At/below the low speed knee → low alpha

    func testDriveHeadingEMAAlpha_atLowKnee_returnsLowAlpha() {
        let alpha = driveHeadingEMAAlpha(speed: 2.0)
        XCTAssertEqual(alpha, 0.35, accuracy: 0.0001,
                       "At the low speed knee (2.0 m/s), alpha should be exactly the low value")
    }

    func testDriveHeadingEMAAlpha_belowLowKnee_returnsLowAlpha() {
        let alpha = driveHeadingEMAAlpha(speed: 0.5)
        XCTAssertEqual(alpha, 0.35, accuracy: 0.0001,
                       "Below the low speed knee, alpha should clamp to the low value")
    }

    func testDriveHeadingEMAAlpha_atZeroSpeed_returnsLowAlpha() {
        let alpha = driveHeadingEMAAlpha(speed: 0.0)
        XCTAssertEqual(alpha, 0.35, accuracy: 0.0001,
                       "At zero speed, alpha should clamp to the low value")
    }

    // MARK: At/above the high speed knee → high alpha

    func testDriveHeadingEMAAlpha_atHighKnee_returnsHighAlpha() {
        let alpha = driveHeadingEMAAlpha(speed: 6.0)
        XCTAssertEqual(alpha, 0.65, accuracy: 0.0001,
                       "At the high speed knee (6.0 m/s), alpha should be exactly the high value")
    }

    func testDriveHeadingEMAAlpha_aboveHighKnee_returnsHighAlpha() {
        let alpha = driveHeadingEMAAlpha(speed: 20.0)
        XCTAssertEqual(alpha, 0.65, accuracy: 0.0001,
                       "Above the high speed knee, alpha should clamp to the high value")
    }

    // MARK: Midpoint interpolation

    func testDriveHeadingEMAAlpha_atMidpoint_returnsMidpointAlpha() {
        // Midpoint of the [2.0, 6.0] knee range is 4.0 m/s.
        let alpha = driveHeadingEMAAlpha(speed: 4.0)
        // Midpoint alpha should be the midpoint of [0.35, 0.65] = 0.50.
        XCTAssertEqual(alpha, 0.50, accuracy: 0.0001,
                       "At the midpoint speed, alpha should be the midpoint of the low/high range")
    }

    func testDriveHeadingEMAAlpha_atQuarterPoint_returnsQuarterInterpolatedAlpha() {
        // 25% of the way from 2.0 to 6.0 is 3.0 m/s.
        let alpha = driveHeadingEMAAlpha(speed: 3.0)
        // Expected: 0.35 + 0.25 * (0.65 - 0.35) = 0.425.
        XCTAssertEqual(alpha, 0.425, accuracy: 0.0001,
                       "At 25% between the knees, alpha should be 25% interpolated")
    }

    // MARK: Monotonicity

    func testDriveHeadingEMAAlpha_isMonotonicallyNonDecreasing() {
        let speeds: [CLLocationSpeed] = [0.0, 0.5, 1.0, 2.0, 2.5, 3.0, 4.0, 5.0, 5.5, 6.0, 8.0, 15.0]
        var previousAlpha = -Double.infinity
        for speed in speeds {
            let alpha = driveHeadingEMAAlpha(speed: speed)
            XCTAssertGreaterThanOrEqual(alpha, previousAlpha,
                "Alpha should never decrease as speed increases (speed=\(speed), alpha=\(alpha))")
            previousAlpha = alpha
        }
    }

    func testDriveHeadingEMAAlpha_staysWithinLowHighBounds() {
        let speeds: [CLLocationSpeed] = [-1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 100.0]
        for speed in speeds {
            let alpha = driveHeadingEMAAlpha(speed: speed)
            XCTAssertGreaterThanOrEqual(alpha, 0.35, "Alpha should never go below the low value (speed=\(speed))")
            XCTAssertLessThanOrEqual(alpha, 0.65, "Alpha should never exceed the high value (speed=\(speed))")
        }
    }
}

// MARK: - Group 2: Regression — circular wraparound unchanged at both alphas

final class DriveHeadingAlphaWraparoundRegressionTests: XCTestCase {

    var service: LocationService!

    override func setUp() {
        super.setUp()
        service = LocationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    /// Headings crossing the 0/360 boundary should converge near 0°, not jump to ~180°,
    /// regardless of which alpha (low, crawl speed) the speed-scaling selects. This is the
    /// same scenario as the pre-existing `EMAStabilizerTests.testStabilizedHeading_circularWrap_near0deg`
    /// (W85cTests.swift), re-run at a speed that selects the LOW alpha, to confirm the
    /// wraparound math itself (not just the convergence rate) is unaffected by open item #36.
    func testStabilizedHeading_circularWrap_near0deg_atLowAlphaSpeed() {
        // speed = 1.0 m/s is between DRIVING_HEADING_MIN_SPEED_MPS (0.5, so the EMA still
        // runs) and DRIVING_HEADING_EMA_LOW_SPEED_MPS (2.0) → selects the LOW alpha (0.35).
        let headings = [355.0, 5.0, 358.0, 2.0]
        var last: Double = 0
        for h in headings {
            if let r = service.stabilizedHeading(rawHeading: h, speed: 1.0, current: w85cAnchor) {
                last = r
            }
        }
        let nearZero = last <= 15.0 || last >= 345.0
        XCTAssertTrue(nearZero, "EMA near 0/360 boundary at low-alpha speed should stay near 0°, not average to 180°. Got \(last)")
    }

    /// Same scenario, at a speed that selects the HIGH alpha (0.65) — confirms the
    /// wraparound correctness holds at the fast-convergence end of the speed-scaling range too.
    func testStabilizedHeading_circularWrap_near0deg_atHighAlphaSpeed() {
        let headings = [355.0, 5.0, 358.0, 2.0]
        var last: Double = 0
        for h in headings {
            if let r = service.stabilizedHeading(rawHeading: h, speed: 8.0, current: w85cAnchor) {
                last = r
            }
        }
        let nearZero = last <= 15.0 || last >= 345.0
        XCTAssertTrue(nearZero, "EMA near 0/360 boundary at high-alpha speed should stay near 0°, not average to 180°. Got \(last)")
    }

    /// Same regression, approaching the boundary from the 360° side, at the low-alpha speed.
    /// Mirrors `EMAStabilizerTests.testStabilizedHeading_circularWrap_near360deg`.
    func testStabilizedHeading_circularWrap_near360deg_atLowAlphaSpeed() {
        let headings = [358.0, 1.0, 357.0, 3.0]
        var last: Double = 0
        for h in headings {
            if let r = service.stabilizedHeading(rawHeading: h, speed: 1.0, current: w85cAnchor) {
                last = r
            }
        }
        let nearZero = last <= 20.0 || last >= 340.0
        XCTAssertTrue(nearZero, "EMA near 360° boundary at low-alpha speed should stay near 0°. Got \(last)")
    }

    /// Same regression, approaching the boundary from the 360° side, at the high-alpha speed.
    func testStabilizedHeading_circularWrap_near360deg_atHighAlphaSpeed() {
        let headings = [358.0, 1.0, 357.0, 3.0]
        var last: Double = 0
        for h in headings {
            if let r = service.stabilizedHeading(rawHeading: h, speed: 8.0, current: w85cAnchor) {
                last = r
            }
        }
        let nearZero = last <= 20.0 || last >= 340.0
        XCTAssertTrue(nearZero, "EMA near 360° boundary at high-alpha speed should stay near 0°. Got \(last)")
    }

    /// At high speed (selecting the high alpha), a single large post-turn jump should
    /// converge MUCH closer to the raw heading in one tick than the old flat 0.35 alpha
    /// would have — this is the actual fix for Kevin's "it lags" complaint. Not a strict
    /// regression test (behavior is intentionally different from pre-#36), but documents the
    /// expected improvement so a future change to the knees doesn't silently undo it.
    func testStabilizedHeading_postTurn_convergesFasterAtHighSpeed() {
        // Establish an initial heading of 0° at high speed.
        _ = service.stabilizedHeading(rawHeading: 0.0, speed: 10.0, current: w85cAnchor)
        // Simulate a 90° turn: raw heading jumps to 90° at the same high speed.
        let afterOneTick = service.stabilizedHeading(rawHeading: 90.0, speed: 10.0, current: w85cAnchor)
        XCTAssertNotNil(afterOneTick)
        // With the high alpha (0.65), one tick should move at least 65% of the way (allowing
        // a small tolerance) — i.e. past 55°, well beyond what the old flat 0.35 alpha
        // (which would land at 31.5°) could reach in a single tick.
        XCTAssertGreaterThan(afterOneTick!, 55.0,
            "A single tick at high drive speed should converge well past the old flat-0.35 result. Got \(afterOneTick!)")
    }
}

//
//  DriveHeadingGuardTests.swift
//  WeParkTests
//
//  Wrong-way heading hardening (build-24 field report, Kevin, 2026-11-02: "the current app
//  direction is no good"). Covers the two pure guards in `DriveHeadingGuard.swift`:
//
//    1. `courseAccuracyQualifies` — the course-quality gate.
//    2. `DriveHeadingFlipGuard` — the large-flip confirmation state machine.
//
//  Plus integration coverage through `LocationService.stabilizedHeading`'s new
//  `courseAccuracy:` parameter, confirming the two guards are correctly wired into the
//  existing EMA pipeline without disturbing any below-threshold behavior.
//
//  No real CLLocationManager is ever started (`LocationService()`'s default init never
//  calls `startUpdatingLocation()`); `stabilizedHeading` is called directly, same pattern
//  as `EMAStabilizerTests` in W85cTests.swift.
//
//  No Calendar.current. No force-unwraps.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - 1. courseAccuracyQualifies (course-quality gate)

final class CourseAccuracyGateTests: XCTestCase {

    func testCourseAccuracyQualifies_nilAlwaysPasses() {
        // nil = CoreLocation's "unavailable" sentinel (driveCourseAccuracy's existing
        // contract) — NOT a positive signal of a bad course. Must pass so the Simulator and
        // any courseAccuracy-naive hardware/OS path doesn't brick heading entirely.
        XCTAssertTrue(courseAccuracyQualifies(nil),
            "nil (unavailable) courseAccuracy must pass the gate")
    }

    func testCourseAccuracyQualifies_zeroPasses() {
        XCTAssertTrue(courseAccuracyQualifies(0.0), "0° (perfect confidence) must pass")
    }

    func testCourseAccuracyQualifies_atThreshold_passes() {
        XCTAssertTrue(courseAccuracyQualifies(DriveHeadingGuardConstants.maxCourseAccuracyDeg),
            "Exactly at the threshold (45°) should still pass (inclusive)")
    }

    func testCourseAccuracyQualifies_justAboveThreshold_fails() {
        XCTAssertFalse(courseAccuracyQualifies(DriveHeadingGuardConstants.maxCourseAccuracyDeg + 0.1),
            "Just above the threshold should fail the gate")
    }

    func testCourseAccuracyQualifies_largeValue_fails() {
        XCTAssertFalse(courseAccuracyQualifies(90.0), "90° accuracy is garbage — must fail")
    }
}

// MARK: - 2. DriveHeadingFlipGuard (large-flip confirmation)

final class DriveHeadingFlipGuardTests: XCTestCase {

    func testFlipGuard_noCurrentHeading_blendsImmediately() {
        var guardState = DriveHeadingFlipGuard()
        let outcome = guardState.next(current: nil, candidate: 45.0)
        XCTAssertEqual(outcome, .blend(45.0), "Nothing to flip from yet — first heading always blends")
    }

    func testFlipGuard_smallDelta_blendsImmediately() {
        var guardState = DriveHeadingFlipGuard()
        // 20° change is well under the 120° flip threshold.
        let outcome = guardState.next(current: 90.0, candidate: 110.0)
        XCTAssertEqual(outcome, .blend(110.0), "A 20° change is ordinary tracking, not a flip")
    }

    func testFlipGuard_wraparound_350to10_isNotTreatedAsFlip() {
        var guardState = DriveHeadingFlipGuard()
        // 350° → 10° is a 20° turn (wraps through 360/0), not a 340° jump.
        let outcome = guardState.next(current: 350.0, candidate: 10.0)
        XCTAssertEqual(outcome, .blend(10.0),
            "350°→10° must be recognized as a small 20° wraparound change, not a large flip")
    }

    func testFlipGuard_singleGlitchMidCruise_isRejectedOutright() {
        var guardState = DriveHeadingFlipGuard()
        // Garbage 180° fix: held, not adopted.
        let glitchOutcome = guardState.next(current: 90.0, candidate: 270.0)
        XCTAssertEqual(glitchOutcome, .hold(90.0), "A single large flip must be held, not fed to the EMA")

        // Next real fix returns to the ORIGINAL direction (not the glitch) — this is the
        // "genuine real fix following a one-off glitch" case. Since 90→95 is NOT a flip
        // relative to the still-unmoved current heading (90), the hold clears and the
        // glitch is never adopted.
        let recoveryOutcome = guardState.next(current: 90.0, candidate: 95.0)
        XCTAssertEqual(recoveryOutcome, .blend(95.0),
            "The fix after a glitch should resume ordinary tracking near the pre-glitch heading")
    }

    func testFlipGuard_reversal_adoptedAfterConfirmFixes() {
        var guardState = DriveHeadingFlipGuard()
        XCTAssertEqual(DriveHeadingGuardConstants.flipConfirmFixes, 2,
            "This test's shape assumes N=2 — update if the tuning knob changes")

        // Backing into a spot: course flips ~180° and STAYS flipped across consecutive fixes.
        let fix1 = guardState.next(current: 90.0, candidate: 270.0)
        XCTAssertEqual(fix1, .hold(90.0), "First flip fix: held, not yet confirmed")

        let fix2 = guardState.next(current: 90.0, candidate: 268.0)  // agrees within tolerance
        XCTAssertEqual(fix2, .adopt(268.0),
            "Second consecutive agreeing fix confirms the reversal — adopted crisply")
    }

    func testFlipGuard_newChallenger_resetsConfirmCount() {
        var guardState = DriveHeadingFlipGuard()

        // First challenger: flip toward 270°.
        let fix1 = guardState.next(current: 90.0, candidate: 270.0)
        XCTAssertEqual(fix1, .hold(90.0))

        // Second fix flips to a DIFFERENT direction (220°) — more than
        // flipConfirmToleranceDeg away from the held 270° challenger — so it's a NEW
        // challenger, not a confirmation of the first. Must reset the count to 1, not adopt.
        let fix2 = guardState.next(current: 90.0, candidate: 220.0)
        XCTAssertEqual(fix2, .hold(90.0),
            "A non-agreeing second flip is a NEW challenger (count reset to 1), not confirmed")

        // Third fix agrees with the SECOND challenger (220°) — now confirmed (count reaches 2
        // on the 220° challenger specifically, not a stale count from the abandoned 270°).
        let fix3 = guardState.next(current: 90.0, candidate: 222.0)
        XCTAssertEqual(fix3, .adopt(222.0),
            "Confirms against the most recent challenger, not a leftover count from the first")
    }

    func testFlipGuard_uTurn_progressiveSweep_neverHolds() {
        var guardState = DriveHeadingFlipGuard()
        var current: CLLocationDirection = 0.0
        // Progressive U-turn: each step is an 80° change from the PREVIOUS heading — under
        // the 120° flip threshold every single tick, even though the cumulative turn is a
        // full 180°+ reversal by the end.
        let sweep: [CLLocationDirection] = [80.0, 160.0, 240.0, 320.0, 40.0]
        for candidate in sweep {
            let outcome = guardState.next(current: current, candidate: candidate)
            guard case .blend(let value) = outcome else {
                XCTFail("Progressive U-turn step (current=\(current), candidate=\(candidate)) " +
                    "must blend, not hold/adopt. Got \(outcome)")
                return
            }
            current = value
        }
    }

    func testFlipGuard_wraparoundFlip_confirmedAfterTwoFixes() {
        var guardState = DriveHeadingFlipGuard()
        // Large flip straddling the 0°/360° boundary: 350° → 170° is a 180° flip (not the
        // naive 180° linear difference misreading it as small).
        let fix1 = guardState.next(current: 350.0, candidate: 170.0)
        XCTAssertEqual(fix1, .hold(350.0), "Wraparound flip: held on first fix")

        let fix2 = guardState.next(current: 350.0, candidate: 172.0)
        XCTAssertEqual(fix2, .adopt(172.0), "Wraparound flip: adopted after second agreeing fix")
    }

    func testCircularDelta_wraparoundEdges() {
        XCTAssertEqual(DriveHeadingFlipGuard.circularDelta(10.0, 350.0), 20.0, accuracy: 0.001)
        XCTAssertEqual(DriveHeadingFlipGuard.circularDelta(350.0, 10.0), 20.0, accuracy: 0.001)
        XCTAssertEqual(DriveHeadingFlipGuard.circularDelta(0.0, 180.0), 180.0, accuracy: 0.001)
    }
}

// MARK: - 3. Integration: LocationService.stabilizedHeading wiring

final class DriveHeadingGuardIntegrationTests: XCTestCase {

    var service: LocationService!

    override func setUp() {
        super.setUp()
        service = LocationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    func testStabilizedHeading_poorCourseAccuracy_freezesOnLastGood() {
        // Establish a good heading first.
        _ = service.stabilizedHeading(rawHeading: 90.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        let established = service.stabilizedHeading(rawHeading: 90.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(established)

        // A fix with a garbage courseAccuracy (90°, well above the 45° threshold) must be
        // dropped entirely — frozen on the last good heading, exactly like below-speed.
        let frozen = service.stabilizedHeading(rawHeading: 275.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 90.0)
        XCTAssertNotNil(frozen)
        XCTAssertEqual(frozen!, established!, accuracy: 1.0,
            "Poor courseAccuracy fix should freeze on last good heading, not jump to 275°")
    }

    func testStabilizedHeading_unavailableCourseAccuracy_stillUsesHeading() {
        // nil courseAccuracy (the Simulator / pre-13.4-style "unavailable" case) must NOT
        // brick the heading — the course is still used normally.
        let result = service.stabilizedHeading(rawHeading: 90.0, speed: 5.0, current: w85cAnchor, courseAccuracy: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 90.0, accuracy: 0.001,
            "nil courseAccuracy must not block the course from establishing the heading")
    }

    func testStabilizedHeading_singleGlitchFix_doesNotSnapWrongWay() {
        // Establish cruising heading near 90° (east).
        _ = service.stabilizedHeading(rawHeading: 90.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        let cruising = service.stabilizedHeading(rawHeading: 90.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(cruising)

        // One-fix 180° garbage glitch — must NOT be adopted.
        let afterGlitch = service.stabilizedHeading(rawHeading: 270.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(afterGlitch)
        XCTAssertEqual(afterGlitch!, cruising!, accuracy: 1.0,
            "A single 180° glitch mid-cruise must not move the heading at all")

        // Driving resumes near the original direction — confirms the glitch never took hold.
        let afterRecovery = service.stabilizedHeading(rawHeading: 92.0, speed: 5.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(afterRecovery)
        XCTAssertTrue(abs(afterRecovery! - 90.0) < 20.0,
            "After the glitch, heading should resume tracking near 90°, not have drifted toward 270°. Got \(afterRecovery!)")
    }

    func testStabilizedHeading_reversing_adoptsFlipAfterConfirmFixes() {
        // Establish heading near 90° (east).
        _ = service.stabilizedHeading(rawHeading: 90.0, speed: 1.0, current: w85cAnchor, courseAccuracy: 5.0)
        _ = service.stabilizedHeading(rawHeading: 90.0, speed: 1.0, current: w85cAnchor, courseAccuracy: 5.0)

        // Backing into a spot: course flips to ~270° (west) and STAYS there across multiple
        // fixes at a low-but-above-gate speed.
        let fix1 = service.stabilizedHeading(rawHeading: 270.0, speed: 1.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(fix1)
        XCTAssertTrue(abs(fix1! - 90.0) < 10.0, "First reversed fix should still be held near 90°. Got \(fix1!)")

        let fix2 = service.stabilizedHeading(rawHeading: 270.0, speed: 1.0, current: w85cAnchor, courseAccuracy: 5.0)
        XCTAssertNotNil(fix2)
        XCTAssertTrue(abs(fix2! - 270.0) < 10.0,
            "After N=2 consecutive agreeing reversed fixes, the heading must adopt the reversal. Got \(fix2!)")
    }

    func testStabilizedHeading_uTurn_tracksSmoothly_neverFreezes() {
        // Progressive U-turn: raw course sweeps in 40°-per-fix steps (a believable fast
        // 3-point-turn cadence at 1Hz GPS) — each RAW fix-to-fix delta is well under the
        // 120° flip threshold. Comparison is against the current SMOOTHED heading (which
        // lags the raw course by design), so this also guards against the EMA's own lag
        // compounding across ticks into a false "flip" classification — 40°/tick keeps the
        // steady-state lag (~20° at the slowest alpha) far short of the 120° threshold.
        let sweep: [CLLocationDirection] = [0.0, 40.0, 80.0, 120.0, 160.0, 200.0]
        var lastResult: CLLocationDirection?
        for raw in sweep {
            lastResult = service.stabilizedHeading(rawHeading: raw, speed: 8.0, current: w85cAnchor, courseAccuracy: 5.0)
            XCTAssertNotNil(lastResult, "U-turn sweep should never freeze to nil mid-sweep")
        }
        // Final heading should have tracked the sweep (allowing for ordinary EMA lag), not
        // gotten stuck partway through (which would indicate the flip guard incorrectly held
        // it at some point in the sweep).
        XCTAssertNotNil(lastResult)
        XCTAssertTrue(DriveHeadingFlipGuard.circularDelta(lastResult!, 200.0) < 90.0,
            "U-turn should track within ordinary EMA lag of the final sweep heading (200°), not be stuck mid-turn. Got \(lastResult!)")
    }
}

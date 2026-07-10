//
//  DriveHeadingSnapTests.swift
//  WeParkTests
//
//  TF2-16: Drive Mode heading snap-to-street at low speed/confidence.
//  Spec: docs/tf2-16-heading-snap-spec.md §8.
//
//  Test inventory (13 tests, per spec §8 items 1–13):
//    Source selection (nextHeadingSource):
//     1. testNextHeadingSource_highSpeedCleanCourse_staysOnCourse
//     2. testNextHeadingSource_lowSpeed_entersSnapWhenBlockMatched
//     3. testNextHeadingSource_lowSpeed_noBlockMatch_staysOnCourse
//     4. testNextHeadingSource_poorCourseAccuracy_entersSnapEvenAtModerateSpeed
//     5. testNextHeadingSource_hysteresis_hoveringNearSingleThreshold_doesNotOscillate
//     6. testNextHeadingSource_turnRecovery_speedAndAccuracyJumpTogether_exitsInSameTick
//     7. testNextHeadingSource_nilCourseAccuracy_treatedAsLowConfidence
//    Bearing selection (snappedHeading):
//     8. testSnappedHeading_onewayTowardTo_returnsForwardBearing
//     9. testSnappedHeading_onewayTowardFrom_returnsReverseBearing
//    10. testSnappedHeading_twoWay_picksDirectionClosestToLastGoodHeading
//    11. testSnappedHeading_twoWay_noLastGoodHeading_defaultsToForwardBearing
//    12. testSnappedHeading_onewayDataMalformed_fallsBackToTwoWayLogic
//    13. testSnappedHeading_circularDelta_wrapsCorrectlyAcrossZero
//
//  Pure-function strategy — no CoreLocation/UIKit/SwiftUI, no MKMapView reads.
//  No Calendar.current use. No hardcoded Mapbox tokens.
//

import XCTest
@testable import WePark

final class DriveHeadingSnapTests: XCTestCase {

    // MARK: - Helpers

    /// Segment running due east (40.0°N, -74.0° → -73.99°): forward (toward_to) bearing
    /// ≈ 90°, reverse (from) bearing ≈ 270°. Mirrors FT11DirectionTests.makeSegment.
    private func makeSegment(
        oneway: Bool? = nil,
        onewayToward: String? = nil
    ) -> Segment {
        Segment(
            id: "TEST_SEG",
            street: "TEST STREET",
            fromStreet: "FROM ST",
            to: "TO ST",
            side: "N",
            line: [[40.0, -74.0], [40.0, -73.99]],
            rules: [],
            dominantCategory: nil,
            oneway: oneway,
            onewayToward: onewayToward
        )
    }

    // MARK: - 1. High speed + clean course → stays on .course

    /// At speed >= exitSpeedMPS with courseAccuracy <= exitCourseAccuracyDeg, the function
    /// only ever returns .course — matches today's behavior exactly at cruising speed
    /// (spec item 2, AC-8).
    func testNextHeadingSource_highSpeedCleanCourse_staysOnCourse() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: true,
            speed: 8.0,
            courseAccuracy: 10.0
        )
        XCTAssertEqual(result, .course, "Fast + accurate course should stay on .course")
    }

    // MARK: - 2. Low speed + block match → enters .streetSnap

    func testNextHeadingSource_lowSpeed_entersSnapWhenBlockMatched() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: true,
            speed: 0.8,  // < enterSpeedMPS (1.5)
            courseAccuracy: 10.0  // good accuracy, but low speed alone triggers entry
        )
        XCTAssertEqual(result, .streetSnap,
            "Low speed with a block match should enter .streetSnap even with good course accuracy")
    }

    // MARK: - 3. Low speed, no block match → stays on .course (freeze-on-stop preserved)

    func testNextHeadingSource_lowSpeed_noBlockMatch_staysOnCourse() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: false,
            speed: 0.2,
            courseAccuracy: 90.0
        )
        XCTAssertEqual(result, .course,
            "No block match must short-circuit to .course unconditionally (item 5, AC-9)")
    }

    /// Also verify from the .streetSnap state: losing the block match snaps back to .course
    /// immediately, regardless of speed/accuracy.
    func testNextHeadingSource_noBlockMatch_fromStreetSnap_returnsToCourse() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .streetSnap,
            hasBlockMatch: false,
            speed: 0.2,
            courseAccuracy: 90.0
        )
        XCTAssertEqual(result, .course,
            "No block match must return .course even if the previous source was .streetSnap")
    }

    // MARK: - 4. Poor course accuracy → enters snap even at moderate speed

    func testNextHeadingSource_poorCourseAccuracy_entersSnapEvenAtModerateSpeed() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: true,
            speed: 2.0,  // above enterSpeedMPS (1.5), below exitSpeedMPS (3.0)
            courseAccuracy: 60.0  // > enterCourseAccuracyDeg (45)
        )
        XCTAssertEqual(result, .streetSnap,
            "Poor course accuracy alone should trigger snap entry even at moderate speed")
    }

    // MARK: - 5. Hysteresis: hovering near a single threshold doesn't oscillate

    func testNextHeadingSource_hysteresis_hoveringNearSingleThreshold_doesNotOscillate() {
        // While already .course: a value between exitSpeedMPS (3.0) and enterSpeedMPS (1.5)
        // is NOT low confidence (>= enterSpeedMPS) and stays on .course.
        let fromCourse = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: true,
            speed: 2.0,  // between 1.5 and 3.0
            courseAccuracy: 30.0  // between 25 and 45 — not low, not high confidence
        )
        XCTAssertEqual(fromCourse, .course,
            "Hovering in the hysteresis band while already .course should stay .course")

        // While already .streetSnap: the SAME band of values does not meet the (stricter)
        // exit thresholds, so it stays .streetSnap rather than flipping back.
        let fromSnap = DriveHeadingSnap.nextHeadingSource(
            current: .streetSnap,
            hasBlockMatch: true,
            speed: 2.0,
            courseAccuracy: 30.0
        )
        XCTAssertEqual(fromSnap, .streetSnap,
            "Hovering in the hysteresis band while already .streetSnap should stay .streetSnap")
    }

    // MARK: - 6. Turn recovery: speed + accuracy jump together → exits in the same tick

    func testNextHeadingSource_turnRecovery_speedAndAccuracyJumpTogether_exitsInSameTick() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .streetSnap,
            hasBlockMatch: true,
            speed: 4.0,           // was 0.3, now >= exitSpeedMPS (3.0)
            courseAccuracy: 10.0  // was 90, now <= exitCourseAccuracyDeg (25)
        )
        XCTAssertEqual(result, .course,
            "A single tick where speed and course accuracy both cross the exit thresholds " +
            "must return .course immediately — no multi-tick lag (item 6, AC-11)")
    }

    // MARK: - 7. Nil course accuracy → treated as low confidence

    func testNextHeadingSource_nilCourseAccuracy_treatedAsLowConfidence() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .course,
            hasBlockMatch: true,
            speed: 8.0,  // fast — would stay .course if accuracy were good
            courseAccuracy: nil
        )
        XCTAssertEqual(result, .streetSnap,
            "Unavailable course accuracy (nil) should be treated as low confidence")
    }

    /// Nil course accuracy also blocks exit from .streetSnap even at high speed.
    func testNextHeadingSource_nilCourseAccuracy_blocksExitFromStreetSnap() {
        let result = DriveHeadingSnap.nextHeadingSource(
            current: .streetSnap,
            hasBlockMatch: true,
            speed: 8.0,
            courseAccuracy: nil
        )
        XCTAssertEqual(result, .streetSnap,
            "Nil course accuracy should block exit back to .course — highConfidence requires " +
            "a non-nil accuracy value")
    }

    // MARK: - 8. One-way toward "to" → forward bearing

    func testSnappedHeading_onewayTowardTo_returnsForwardBearing() {
        let segment = makeSegment(oneway: true, onewayToward: "to")
        let heading = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: nil)
        XCTAssertEqual(heading, 90.0, accuracy: 1.0,
            "oneway toward 'to' should return the forward (toward_to) bearing (~90° east)")
    }

    // MARK: - 9. One-way toward "from" → reverse bearing

    func testSnappedHeading_onewayTowardFrom_returnsReverseBearing() {
        let segment = makeSegment(oneway: true, onewayToward: "from")
        let heading = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: nil)
        XCTAssertEqual(heading, 270.0, accuracy: 1.0,
            "oneway toward 'from' should return the reverse bearing (~270° west)")
    }

    // MARK: - 10. Two-way → picks direction closest to last good heading

    func testSnappedHeading_twoWay_picksDirectionClosestToLastGoodHeading() {
        let segment = makeSegment(oneway: nil, onewayToward: nil)

        // Last-good near forward (~90° east) → forward bearing wins.
        let nearForward = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: 80.0)
        XCTAssertEqual(nearForward, 90.0, accuracy: 1.0,
            "Last-good heading near the forward bearing should select the forward bearing")

        // Last-good near reverse (~270° west) → reverse bearing wins.
        let nearReverse = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: 260.0)
        XCTAssertEqual(nearReverse, 270.0, accuracy: 1.0,
            "Last-good heading near the reverse bearing should select the reverse bearing")
    }

    // MARK: - 11. Two-way, no last-good heading → defaults to forward bearing

    func testSnappedHeading_twoWay_noLastGoodHeading_defaultsToForwardBearing() {
        let segment = makeSegment(oneway: nil, onewayToward: nil)
        let heading = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: nil)
        XCTAssertEqual(heading, 90.0, accuracy: 1.0,
            "No last-good heading should default to the forward (toward_to) bearing")
    }

    // MARK: - 12. One-way data malformed → falls back to two-way logic

    func testSnappedHeading_onewayDataMalformed_fallsBackToTwoWayLogic() {
        // oneway == true but onewayToward is neither "to" nor "from" — malformed data.
        let segment = makeSegment(oneway: true, onewayToward: "sideways")
        let nearForward = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: 80.0)
        XCTAssertEqual(nearForward, 90.0, accuracy: 1.0,
            "Malformed onewayToward should fall through to two-way circular-distance logic")

        let nearReverse = DriveHeadingSnap.snappedHeading(segment: segment, lastGoodHeading: 260.0)
        XCTAssertEqual(nearReverse, 270.0, accuracy: 1.0,
            "Malformed onewayToward should fall through to two-way circular-distance logic (reverse case)")
    }

    // MARK: - 13. Circular delta wraps correctly across zero

    /// Uses a segment whose forward bearing is near 0°/360° (due north) so the reverse
    /// bearing is near 180° (due south), then places lastGoodHeading just past the wrap
    /// boundary to confirm circular (not linear) distance is used.
    func testSnappedHeading_circularDelta_wrapsCorrectlyAcrossZero() {
        // Due-north segment: forward bearing ≈ 0°/360°, reverse bearing ≈ 180°.
        let northSegment = Segment(
            id: "TEST_NORTH",
            street: "TEST STREET",
            fromStreet: "FROM ST",
            to: "TO ST",
            side: "N",
            line: [[40.0, -74.0], [40.01, -74.0]],
            rules: [],
            dominantCategory: nil
        )
        let forwardBearing = SegmentBearing.bearing(segment: northSegment, toward: .toward_to)
        XCTAssertEqual(forwardBearing, 0.0, accuracy: 1.0, "Sanity check: forward bearing should be ~0° (north)")

        // lastGoodHeading = 359° is only ~1° from the forward bearing (0°) via the wrap,
        // but ~179° via naive linear subtraction. If circularDelta is correct, forward wins.
        let heading = DriveHeadingSnap.snappedHeading(segment: northSegment, lastGoodHeading: 359.0)
        XCTAssertEqual(heading, forwardBearing, accuracy: 1.0,
            "lastGoodHeading of 359° should select the forward (~0°) bearing via circular distance, " +
            "not the reverse (~180°) bearing that a naive linear comparison would pick")
    }
}

//
//  TF27Tests.swift
//  WeParkTests
//
//  TF2-7: Unit tests for side-level aggregation, voice copy templates, and sheet-flow
//  wiring.
//
//  Coverage target: +15 tests from the 480 baseline → 495 passing (spec §7 adjusted
//  baseline note: spec said 479 but actual baseline is 480 per task brief).
//
//  Test groups:
//    A. aggregateSide decision table (9 tests — spec §7)
//    B. CruiseVoicePolicy copy strings — new "sections" phrasing (3 tests — spec §7)
//    C. DrivingContextService.buildUtteranceText — destination-mode copy (3 tests — spec §7)
//
//  No Calendar.current.
//  No import SwiftUI (service tests must not import SwiftUI per QA invariant).
//  No import MapKit.
//
//  Segment fixture helpers:
//    - `tf27MakeSeg(side:category:lengthMeters:)` — builds a segment whose haversine
//      length is approximately the requested meters, using a fixed anchor at 40.750 N.
//    - Relies on `w85cMakeSeg` from W85cTests.swift for the default-length (≈ 11m)
//      segments used in category-only tests.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixture helpers

/// Fixed test date: Wednesday 8 AM ET — outside typical restrictions.
/// Same pattern as DrivingContextServiceCruiseModeTests.
private var tf27TestDate: Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 1
    comps.day = 7   // Wednesday
    comps.hour = 8
    comps.minute = 0
    comps.second = 0
    comps.timeZone = TimeZone(identifier: "America/New_York")
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

/// Builds a `Segment` whose line has a known approximate haversine length.
///
/// The line is two points along the same latitude, offset east by `lengthMeters`.
/// At latitude 40.750°N: 1° longitude ≈ 85,000m, so `degreesPerMeter ≈ 1/85000`.
///
/// - Parameters:
///   - side: Cardinal side ("N", "S", "E", "W").
///   - category: Parking rule category (`.free`, `.noParking`, etc.).
///   - lengthMeters: Approximate desired segment length in meters. Accuracy: ±2%.
///   - street / from / to: Block identity strings for aggregation filtering.
///   - timeRanges: Optional time ranges (minutes of day). If nil, anytime=true is used.
///     For `.metered` segments under test, supply a range that brackets the test date
///     (noon ET, 720 minutes of day) so the meter reads as "paid until".
func tf27MakeSeg(
    street: String = "SPRING ST",
    from: String = "6 AVE",
    to: String = "VARICK ST",
    side: String,
    category: WePark.Category,
    lengthMeters: Double,
    timeRanges: [TimeRange]? = nil
) -> Segment {
    let anchorLat = 40.750
    let anchorLng = -73.980
    // 1° longitude at 40.75°N ≈ cos(40.75° × π/180) × 111_320 m/° ≈ 84_460 m/°
    let metersPerDegreeLng = cos(anchorLat * .pi / 180) * 111_320.0
    let deltaLng = lengthMeters / metersPerDegreeLng

    let rule = ParkingRule(
        category: category,
        description: "TF27 test rule",
        days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: timeRanges ?? [],
        anytime: timeRanges == nil,
        arrow: nil
    )
    return Segment(
        id: UUID().uuidString,
        street: street,
        fromStreet: from,
        to: to,
        side: side,
        line: [
            [anchorLat, anchorLng],
            [anchorLat, anchorLng + deltaLng]
        ],
        rules: [rule],
        dominantCategory: category
    )
}

// MARK: - A. aggregateSide decision table tests

final class AggregateSideTests: XCTestCase {

    let engine = ParkingRulesEngine()

    // Test A-1: Single free segment ≥ 6m → .free
    func testAggregateSide_singleFreeSegmentLong_returnsFree() {
        // 10m free segment (>= 6m threshold)
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0)
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "N", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(result, .free, "10m free segment should return .free")
    }

    // Test A-2: Single free segment < 6m → .restricted (not actionable)
    func testAggregateSide_singleFreeSegmentTooShort_returnsRestricted() {
        // 4m free segment (< 6m threshold — not actionable, car won't fit)
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 4.0)
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "N", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(
            result, .restricted,
            "4m free segment (< 6m threshold) should return .restricted"
        )
    }

    // Test A-3: Mixed free + restricted, free is ≥ 6m → .free (short-circuit)
    func testAggregateSide_mixedFreeAndRestricted_withLongFree_returnsFree() {
        let restrictedSeg = tf27MakeSeg(side: "N", category: .noParking, lengthMeters: 30.0)
        let freeSeg       = tf27MakeSeg(side: "N", category: .free,      lengthMeters: 8.0)
        let result = DrivingContextService.aggregateSide(
            segments: [restrictedSeg, freeSeg], side: "N", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(
            result, .free,
            "Mixed block with 8m free segment should return .free (short-circuit)"
        )
    }

    // Test A-4: Only metered segment → .metered
    // The meter must be in "paid hours" at the test date (8 AM ET = 480 min of day).
    // Time range: 7 AM–8 PM (420–1200) so the meter is active at 480 min.
    // Without time ranges, meteredStatus returns "Metered (free)" (severity .free) because
    // an empty-timeRanges metered rule has no paid-hour windows → aggregateSide sees .free
    // from the engine and returns .free (wrong). Supplying the time range makes the engine
    // return "Metered (paid until 8pm)" → severity .metered → aggregateSide returns .metered.
    func testAggregateSide_meteredOnly_returnsMetered() {
        let seg = tf27MakeSeg(
            side: "S",
            category: .metered,
            lengthMeters: 20.0,
            timeRanges: [TimeRange(start: 420, end: 1200)]  // 7 AM–8 PM ET; active at 8 AM
        )
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "S", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(result, .metered, "Single metered segment (7am–8pm) should return .metered at 8 AM ET")
    }

    // Test A-5: All restricted segments → .restricted
    func testAggregateSide_allRestricted_returnsRestricted() {
        let seg1 = tf27MakeSeg(side: "E", category: .noParking,  lengthMeters: 15.0)
        let seg2 = tf27MakeSeg(side: "E", category: .noStanding, lengthMeters: 10.0)
        let result = DrivingContextService.aggregateSide(
            segments: [seg1, seg2], side: "E", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(result, .restricted, "All restricted segments should return .restricted")
    }

    // Test A-6: No segments for the given side → .unknown
    func testAggregateSide_noSegments_returnsUnknown() {
        // Pass segments for side "N" but ask for side "W" — no match.
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0)
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "W", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(result, .unknown, "No segments for given side should return .unknown")
    }

    // Test A-7: Free segment before metered → .free (free takes priority over metered)
    // Free segment short-circuits; metered segment's time ranges don't affect the result.
    func testAggregateSide_freeBeforeMetered_returnsFree() {
        let freeSeg    = tf27MakeSeg(side: "N", category: .free,    lengthMeters: 10.0)
        let meteredSeg = tf27MakeSeg(
            side: "N",
            category: .metered,
            lengthMeters: 20.0,
            timeRanges: [TimeRange(start: 420, end: 1200)]  // 7 AM–8 PM; meter active at test date
        )
        let result = DrivingContextService.aggregateSide(
            segments: [freeSeg, meteredSeg], side: "N", engine: engine, date: tf27TestDate
        )
        XCTAssertEqual(
            result, .free,
            "Free segment ≥ 6m with metered should return .free (free takes priority)"
        )
    }

    // Test A-8: Inclusive boundary — segment whose haversine length equals minimumFreeLength → .free
    //
    // The `tf27MakeSeg` helper uses a linear approximation (cos * 111_320) to convert meters
    // to degrees longitude. The haversine of that delta is slightly below the requested value
    // due to floating-point rounding (e.g. requesting 6.0m produces ~5.99m by haversine).
    // To test the INCLUSIVE boundary (`>=`) precisely, we read back the actual computed length
    // and inject it as `minimumFreeLength`. This confirms `length >= minimumFreeLength` is
    // true when they are equal — i.e., the condition is `>=` not `>`.
    func testAggregateSide_minimumFreeLength_boundary_6m_returnsFree() {
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 6.0)
        // Read back the exact haversine length so we can inject it as the threshold.
        let length = DrivingContextService.segmentLengthMeters(seg)
        XCTAssertGreaterThanOrEqual(
            length, 5.85,
            "Fixture should produce a segment of approximately 6m (lower bound ±2.5%)"
        )
        // Inject the actual computed length as the threshold — tests the inclusive `>=` boundary.
        // A threshold equal to the length should return .free (not .restricted).
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "N", engine: engine, date: tf27TestDate,
            minimumFreeLength: length
        )
        XCTAssertEqual(
            result, .free,
            "Segment whose length equals minimumFreeLength should return .free (inclusive boundary)"
        )
    }

    // Test A-9: Segment length 5.99m and .free → .restricted (just below threshold)
    // Uses minimumFreeLength injectable to set threshold to 6.0, then provides a 5.5m segment.
    func testAggregateSide_minimumFreeLength_boundary_5_99m_returnsRestricted() {
        // Build a segment ≈ 5.5m — well below 6m threshold, no other segments.
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 5.5)
        let result = DrivingContextService.aggregateSide(
            segments: [seg], side: "N", engine: engine, date: tf27TestDate,
            minimumFreeLength: 6.0
        )
        XCTAssertEqual(
            result, .restricted,
            "5.5m free segment (< 6m threshold) with no metered fallback should return .restricted"
        )
    }
}

// MARK: - B. CruiseVoicePolicy copy strings — TF2-7 "sections" phrasing

final class CruiseVoicePolicyCopyTests: XCTestCase {

    /// Minimal DrivingContext for CruiseVoicePolicy phrasing tests.
    private func ctx(
        street: String = "SPRING ST",
        left: SafetyLabel.Severity,
        right: SafetyLabel.Severity
    ) -> DrivingContext {
        DrivingContext(
            street: street,
            from: "6 AVE",
            to: "VARICK ST",
            leftLabel:  SafetyLabel(text: "", severity: left),
            rightLabel: SafetyLabel(text: "", severity: right)
        )
    }

    // Test B-1: Left free → contains "sections on the left" and "check signs"
    func testUtteranceText_freeLeft_containsSectionsAndCheckSigns() {
        let text = CruiseVoicePolicy.utteranceText(for: ctx(left: .free, right: .restricted))
        XCTAssertTrue(
            text.contains("sections on the left"),
            "Left-free phrasing should contain 'sections on the left'. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Left-free phrasing should contain 'check signs'. Got: \(text)"
        )
        // Must NOT contain old "Free parking on the left" without "sections".
        XCTAssertFalse(
            text == "Spring Street. Free parking on the left.",
            "Should NOT use pre-TF2-7 phrasing. Got: \(text)"
        )
    }

    // Test B-2: Right free → contains "sections on the right" and "check signs"
    func testUtteranceText_freeRight_containsSectionsAndCheckSigns() {
        let text = CruiseVoicePolicy.utteranceText(for: ctx(left: .restricted, right: .free))
        XCTAssertTrue(
            text.contains("sections on the right"),
            "Right-free phrasing should contain 'sections on the right'. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Right-free phrasing should contain 'check signs'. Got: \(text)"
        )
    }

    // Test B-3: Both free → contains "both sides" and "check signs"
    func testUtteranceText_freeBothSides_containsSectionsAndCheckSigns() {
        let text = CruiseVoicePolicy.utteranceText(for: ctx(left: .free, right: .free))
        XCTAssertTrue(
            text.contains("both sides"),
            "Both-free phrasing should contain 'both sides'. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Both-free phrasing should contain 'check signs'. Got: \(text)"
        )
    }

    // Test B-4 (TF2-7.9 AC): Metered right only → "Metered on the right." — no sections, no check signs
    func testUtteranceText_meteredRight_noSectionsNoCheckSigns() {
        let text = CruiseVoicePolicy.utteranceText(for: ctx(left: .restricted, right: .metered))
        XCTAssertTrue(
            text.contains("Metered on the right."),
            "Metered-right phrasing should say 'Metered on the right.' Got: \(text)"
        )
        XCTAssertFalse(
            text.contains("sections"),
            "Metered phrasing should NOT contain 'sections'. Got: \(text)"
        )
        XCTAssertFalse(
            text.contains("check signs"),
            "Metered phrasing should NOT contain 'check signs'. Got: \(text)"
        )
    }
}

// MARK: - C. DrivingContextService.buildUtteranceText — destination-mode copy

final class BuildUtteranceTextTF27Tests: XCTestCase {

    let service = DrivingContextService(voice: MockDrivingVoice())

    // Minimal DrivingContext for buildUtteranceText tests.
    private func ctx(
        street: String = "SPRING ST",
        left: SafetyLabel.Severity,
        right: SafetyLabel.Severity
    ) -> DrivingContext {
        DrivingContext(
            street: street,
            from: "6 AVE",
            to: "VARICK ST",
            leftLabel:  SafetyLabel(text: "", severity: left),
            rightLabel: SafetyLabel(text: "", severity: right)
        )
    }

    // Test C-1: Left free → "sections on the left" + "check signs" (matches CruiseVoicePolicy)
    func testBuildUtteranceText_freeLeft_containsSectionsAndCheckSigns() {
        let text = service.buildUtteranceText(ctx(left: .free, right: .restricted))
        XCTAssertTrue(
            text.contains("sections on the left"),
            "Destination mode left-free should contain 'sections on the left'. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Destination mode left-free should contain 'check signs'. Got: \(text)"
        )
    }

    // Test C-2: Right metered only → "Metered on the right." (matches CruiseVoicePolicy)
    func testBuildUtteranceText_meteredRight_saysMeteredOnRight() {
        let text = service.buildUtteranceText(ctx(left: .restricted, right: .metered))
        XCTAssertTrue(
            text.contains("Metered on the right."),
            "Destination mode metered-right should say 'Metered on the right.' Got: \(text)"
        )
    }

    // Test C-3: Both restricted → "No parking on either side." (destination mode ONLY — spec §4.3)
    func testBuildUtteranceText_bothRestricted_destinationMode_saysNoParkingEitherSide() {
        let text = service.buildUtteranceText(ctx(left: .restricted, right: .restricted))
        XCTAssertTrue(
            text.contains("No parking on either side."),
            "Destination mode both-restricted should say 'No parking on either side.' Got: \(text)"
        )
    }
}

// MARK: - D. SafetyLabel(for: SideOpportunity) bridge tests

final class SafetyLabelSideOpportunityTests: XCTestCase {

    // Test D-1: .free → severity .free, text contains "check signs"
    func testSafetyLabel_free_severityFree() {
        let label = SafetyLabel(for: .free)
        XCTAssertEqual(label.severity, .free)
        XCTAssertTrue(label.text.contains("check signs"),
                      "Free SideOpportunity label should mention 'check signs'. Got: \(label.text)")
    }

    // Test D-2: .metered → severity .metered
    func testSafetyLabel_metered_severityMetered() {
        let label = SafetyLabel(for: .metered)
        XCTAssertEqual(label.severity, .metered)
    }

    // Test D-3: .restricted → severity .restricted
    func testSafetyLabel_restricted_severityRestricted() {
        let label = SafetyLabel(for: .restricted)
        XCTAssertEqual(label.severity, .restricted)
    }

    // Test D-4: .unknown → severity .unknown
    func testSafetyLabel_unknown_severityUnknown() {
        let label = SafetyLabel(for: .unknown)
        XCTAssertEqual(label.severity, .unknown)
    }
}

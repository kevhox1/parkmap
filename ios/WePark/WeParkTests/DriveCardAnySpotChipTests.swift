//
//  DriveCardAnySpotChipTests.swift
//  WeParkTests
//
//  PR #179 QA finding 1 (Bug A still reproduced): E 2nd St, 2nd Ave to 1st Ave, N side,
//  Overnight goal, Tue 5:30 PM. Six green ASP Mon/Thu segments plus one short timed
//  NO STANDING stub (free now, >= 6 m, fails Wed 7 AM). `allSatisfy` turned the chip RED
//  over a mostly green map line. Owner rule: GREEN iff a driver can actually find a legal
//  spot on that side for the whole goal window; color, text and map must agree.
//
//  Fixtures below are the REAL tile segments (tiles/tile_10_13.json and tile_10_14.json,
//  ids EAST_2ND_STREET_2ND_AVENUE_1ST_AVENUE_N_0 ... _6), geometry and rules verbatim.
//
//  Reference time: Tue 2026-11-24 17:30 ET; window = [now, Thu 2026-11-26 00:00).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixtures (file-private, uniquely named)

private func asaMonThuRule() -> ParkingRule {
    ParkingRule(
        category: .aspMonThu,
        description: "NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9AM-10:30AM",
        days: [1, 4],
        timeRanges: [TimeRange(start: 540, end: 630)],
        anytime: false,
        arrow: nil
    )
}

private func asaTimedRule(_ category: WePark.Category) -> ParkingRule {
    ParkingRule(
        category: category,
        description: "TIMED 7AM-4PM Mon-Sat",
        days: [1, 2, 3, 4, 5, 6],
        timeRanges: [TimeRange(start: 420, end: 960)],
        anytime: false,
        arrow: nil
    )
}

private func asaSegment(_ suffix: Int, line: [[Double]], rules: [ParkingRule]) -> Segment {
    Segment(
        id: "EAST_2ND_STREET_2ND_AVENUE_1ST_AVENUE_N_\(suffix)",
        street: "EAST 2ND STREET",
        fromStreet: "2ND AVENUE",
        to: "1ST AVENUE",
        side: "N",
        line: line,
        rules: rules,
        dominantCategory: rules.first?.category
    )
}

/// The seven real north-side segments of E 2nd St between 2nd Ave and 1st Ave.
private func asaRealEast2ndNorthSide() -> [Segment] {
    [
        // _0 (tile_10_14): ~13.7 m, ASP + NO_STANDING school days 7AM-4PM
        asaSegment(0,
                   line: [[40.724027, -73.988047], [40.724038, -73.988078], [40.724085, -73.98819]],
                   rules: [asaMonThuRule(), asaTimedRule(.noStanding)]),
        // _1: ASP x2 + SPECIAL 7AM-4PM
        asaSegment(1,
                   line: [[40.724085, -73.98819], [40.724246, -73.988572]],
                   rules: [asaMonThuRule(), asaMonThuRule(), asaTimedRule(.special)]),
        asaSegment(2,
                   line: [[40.724246, -73.988572], [40.724362, -73.988846]],
                   rules: [asaMonThuRule(), asaMonThuRule()]),
        asaSegment(3,
                   line: [[40.724362, -73.988846], [40.724483, -73.989133]],
                   rules: [asaMonThuRule(), asaMonThuRule()]),
        asaSegment(4,
                   line: [[40.724483, -73.989133], [40.72471, -73.98967]],
                   rules: [asaMonThuRule(), asaMonThuRule()]),
        asaSegment(5,
                   line: [[40.72471, -73.98967], [40.724811, -73.98991]],
                   rules: [asaMonThuRule(), asaMonThuRule()]),
        asaSegment(6,
                   line: [[40.724811, -73.98991], [40.724928, -73.990187], [40.724937, -73.990212]],
                   rules: [asaMonThuRule()])
    ]
}

private func asaTueEvening() -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 11; comps.day = 24
    comps.hour = 17; comps.minute = 30; comps.second = 0
    comps.timeZone = TimeZone(identifier: "America/New_York")
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

final class DriveCardAnySpotChipTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private let now = asaTueEvening()
    private var overnightTarget: Date { now.startOfDayET(offsetDays: 2) }

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func chip(_ segments: [Segment]) -> DrivingContextService.GoalAwareChip? {
        DrivingContextService.goalAwareChip(
            sideSegments: segments,
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
    }

    private func overlayPasses(_ segment: Segment) -> Bool {
        engine.isFree(segment: segment, from: now, until: overnightTarget, ignoringMeteredPayment: true)
    }

    // The owner's block: at least one real segment passes the window, so the chip is green,
    // and the text is a "Free until ..." about a segment that passes.
    func testRealEast2ndNorthSide_greenWithFreeUntilText() {
        let segments = asaRealEast2ndNorthSide()
        XCTAssertTrue(segments.contains(where: { overlayPasses($0) }), "map shows green lines on this side")
        let result = chip(segments)
        XCTAssertEqual(result?.severity, .free)
        let text = result?.labelOverride?.text ?? ""
        XCTAssertTrue(text.hasPrefix("Free until"), "got: \(text)")
        // The text is the same as the one a passing segment's own label gives.
        let passingTexts = segments.filter { overlayPasses($0) }.map { engine.safetyLabel(for: $0, at: now).text }
        XCTAssertTrue(passingTexts.contains(text))
    }

    // End to end through update(): label severity and text come out consistent.
    func testRealEast2ndNorthSide_updateProducesGreenChipAndMatchingText() {
        let service = DrivingContextService(voice: MockDrivingVoice())
        service.update(
            coordinate: CLLocationCoordinate2D(latitude: 40.72436, longitude: -73.98885),
            heading: 270.0,   // westbound: north side is on the right
            segments: asaRealEast2ndNorthSide(),
            engine: engine,
            date: now,
            parkUntilMode: true,
            parkUntilTarget: overnightTarget,
            parkUntilIgnoresMeteredPayment: true
        )
        let ctx = service.currentContext
        XCTAssertNotNil(ctx)
        let sides = [(ctx?.leftLabel, ctx?.leftChipColorOverride), (ctx?.rightLabel, ctx?.rightChipColorOverride)]
        // Exactly one side has data (north); its chip must be green and its text "Free until".
        let withData = sides.filter { $0.0?.text != "\u{2014}" && $0.0?.text != "No data" }
        XCTAssertEqual(withData.count, 1)
        XCTAssertEqual(withData.first?.1, .free)
        XCTAssertTrue(withData.first?.0?.text.hasPrefix("Free until") ?? false)
    }

    // No false green: every >= 6 m free-now segment fails the window, so the chip is RED
    // and the text does not claim "Free until ...".
    func testEveryFreeNowSegmentFails_staysRed_noFreeUntilText() {
        let failing = [
            asaSegment(0,
                       line: [[40.724027, -73.988047], [40.724038, -73.988078], [40.724085, -73.98819]],
                       rules: [asaTimedRule(.noStanding)]),
            asaSegment(9,
                       line: [[40.7250, -73.9900], [40.7251, -73.9900]],
                       rules: [asaTimedRule(.noStanding)])
        ]
        XCTAssertFalse(failing.contains(where: { overlayPasses($0) }))
        let result = chip(failing)
        XCTAssertEqual(result?.severity, .restricted)
        XCTAssertFalse(result?.labelOverride?.text.hasPrefix("Free until") ?? false)
        XCTAssertEqual(result?.labelOverride?.severity, .restricted)
    }

    // Segments under 6 m never make a side green, even when they pass.
    func testShortPassingSliverDoesNotMakeGreen() {
        let failingLong = asaSegment(9,
                                     line: [[40.7250, -73.9900], [40.7251, -73.9900]],
                                     rules: [asaTimedRule(.noStanding)])
        let sliver = asaSegment(8,
                                line: [[40.7260, -73.9900], [40.72601, -73.9900]],
                                rules: [])
        XCTAssertLessThan(DrivingContextService.segmentLengthMeters(sliver), 6.0)
        XCTAssertEqual(chip([failingLong, sliver])?.severity, .restricted)
    }

    // No goal: the 5-state path is untouched (no chip override at all).
    func testNoGoal_returnsNil() {
        let result = DrivingContextService.goalAwareChip(
            sideSegments: asaRealEast2ndNorthSide(),
            parkUntilMode: false,
            target: nil,
            ignoringMeteredPayment: false,
            from: now,
            engine: engine
        )
        XCTAssertNil(result)
    }
}

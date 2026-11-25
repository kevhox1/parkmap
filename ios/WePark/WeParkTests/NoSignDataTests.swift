//
//  NoSignDataTests.swift
//  WeParkTests
//
//  "No usable sign data" (empty rules, or PR #192's synthetic NO DATA rule) must read as
//  unknown, never free and never as a posted "No parking" sign.
//

import XCTest
@testable import WePark

final class NoSignDataTests: XCTestCase {

    private let engine = ParkingRulesEngine(aspService: ASPSuspensionService())

    private func et(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = 0; c.second = 0
        c.timeZone = .easternTime
        return Calendar.easternTime.date(from: c)!
    }

    private func rule(_ category: String, _ description: String, anytime: Bool = true, days: [Int] = [0, 1, 2, 3, 4, 5, 6]) -> [String: Any] {
        ["category": category, "description": description, "days": days,
         "timeRanges": [[String: Int]](), "anytime": anytime, "arrow": "both"]
    }

    private func seg(_ rules: [[String: Any]], side: String = "N") -> Segment {
        let dict: [String: Any] = [
            "id": "NSD_TEST", "street": "MOTT STREET", "from": "GRAND STREET", "to": "HESTER STREET",
            "side": side, "line": [[40.7183, -73.9942], [40.7190, -73.9940]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private var noData: Segment {
        seg([rule("NO_PARKING", "NO DATA - ONLY A SUPERSEDED SIGN ON RECORD - TREATED AS NOT PARKABLE")])
    }

    func testHasNoSignData_signals() {
        XCTAssertTrue(seg([]).hasNoSignData)
        XCTAssertTrue(noData.hasNoSignData)
        XCTAssertFalse(seg([rule("NO_PARKING", "NO PARKING ANYTIME")]).hasNoSignData)
        // UNKNOWN-category rule with real sign text is NOT the no-data encoding.
        XCTAssertFalse(seg([rule("UNKNOWN", "PLATE-ONLY SIGN")]).hasNoSignData)
    }

    func testIsFree_emptyRules_isNotFree() {
        let from = et(2026, 5, 11, 8)
        XCTAssertFalse(engine.isFree(segment: seg([]), from: from, until: et(2026, 5, 11, 10)))
        XCTAssertFalse(engine.isFree(segment: seg([]), from: from, until: et(2026, 5, 12, 7), ignoringMeteredPayment: true))
    }

    func testIsFree_noDataRule_isNotFree() {
        XCTAssertFalse(engine.isFree(segment: noData, from: et(2026, 5, 11, 8), until: et(2026, 5, 11, 9)))
    }

    func testSafetyLabel_saysNoSignData_notNoParking() {
        for s in [seg([]), noData] {
            let label = engine.safetyLabel(for: s, at: et(2026, 5, 11, 8))
            XCTAssertEqual(label.text, "No sign data")
            XCTAssertEqual(label.severity, .unknown)
        }
    }

    func testMapStaysRed_forNoDataRule() {
        XCTAssertEqual(engine.currentState(for: noData, at: et(2026, 5, 11, 9)), .restrictedNow)
    }

    func testDriveSideLabel_noData_saysNoSignData_andStaysRestricted() {
        let agg = DrivingContextService.aggregateSideDetail(
            segments: [noData], side: "N", engine: engine, date: et(2026, 5, 11, 9))
        XCTAssertEqual(agg.opportunity, .restricted)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "No sign data")
        XCTAssertEqual(label.severity, .restricted)
    }

    func testDriveSideLabel_realNoParking_stillSaysNoParking() {
        let real = seg([rule("NO_PARKING", "NO PARKING ANYTIME")])
        let agg = DrivingContextService.aggregateSideDetail(
            segments: [real], side: "N", engine: engine, date: et(2026, 5, 11, 9))
        XCTAssertEqual(SafetyLabel(for: agg).text, "No parking")
    }

    func testReason_superseded_plainWords() {
        XCTAssertEqual(noData.noSignDataReason, "The only sign on file here was replaced, and we don't have the new one.")
        XCTAssertNil(seg([]).noSignDataReason)
    }
}

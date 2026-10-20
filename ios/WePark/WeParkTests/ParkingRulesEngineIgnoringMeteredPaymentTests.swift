//
//  ParkingRulesEngineIgnoringMeteredPaymentTests.swift
//  WeParkTests
//
//  DM-2e / AC-23 (docs/drive-mode-default-spec.md §0.8.4, §5): unit tests for the new
//  additive `ignoringMeteredPayment` parameter on `ParkingRulesEngine.isFree(...)`.
//
//  Deliberately a SEPARATE file from `ParkUntilTests.swift` — the existing tests
//  there stay green UNMODIFIED, proving the default (`false`) is byte-identical to
//  pre-amendment behavior. This file adds only the new-parameter coverage:
//    - testIsFree_defaultOmitted_meteredActiveInWindow_returnsFalse   (regression guard)
//    - testIsFree_ignoringMeteredPaymentTrue_meteredActiveInWindow_returnsTrue
//    - testIsFree_ignoringMeteredPaymentTrue_aspActiveInWindow_stillReturnsFalse
//    - testIsFree_ignoringMeteredPaymentTrue_noStandingAnytime_stillReturnsFalse
//    - testIsFree_ignoringMeteredPaymentTrue_noParkingAnytime_stillReturnsFalse
//    - testIsFree_ignoringMeteredPaymentTrue_truckLoadingAnytime_stillReturnsFalse
//
//  All dates constructed via Calendar.easternTime. Zero Calendar.current references.
//
//  Test reference date: 2026-05-11 (Monday), same reference date ParkUntilTests.swift
//  already uses — ASP_MON_THU day, not suspended in asp-2026.json.
//

import XCTest
@testable import WePark

// MARK: - ParkingRulesEngineIgnoringMeteredPaymentTests

final class ParkingRulesEngineIgnoringMeteredPaymentTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
    }

    // MARK: - Helpers (private to this class — no cross-file XCTestCase extension,
    // deliberately avoiding the helper-name-shadowing compile-failure class)

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }

    private func seg(rules: [ParkingRule]) -> Segment {
        let ruleData = try! JSONEncoder().encode(rules)
        let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
        let segDict: [String: Any] = [
            "id": "IGNM_TEST",
            "street": "MOTT STREET",
            "from": "GRAND STREET",
            "to": "HESTER STREET",
            "side": "N",
            "line": [[40.7183, -73.9942], [40.7190, -73.9940]],
            "rules": rulesJSON,
        ]
        let data = try! JSONSerialization.data(withJSONObject: segDict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private func r(
        category: WePark.Category,
        days: [Int],
        timeRanges: [(start: Int, end: Int)] = [],
        anytime: Bool = false
    ) -> ParkingRule {
        let ranges = timeRanges.map { TimeRange(start: $0.start, end: $0.end) }
        let ruleDict: [String: Any] = [
            "category": category.rawValue,
            "description": "",
            "days": days,
            "timeRanges": ranges.map { ["start": $0.start, "end": $0.end] },
            "anytime": anytime,
            "arrow": "both",
        ]
        let data = try! JSONSerialization.data(withJSONObject: ruleDict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    // MARK: - testIsFree_defaultOmitted_meteredActiveInWindow_returnsFalse
    // AC-23 regression guard: calling isFree WITHOUT the new parameter at all must
    // preserve pre-amendment behavior byte-for-byte — metered paid hours still
    // disqualify a match when the flag is omitted.

    func testIsFree_defaultOmitted_meteredActiveInWindow_returnsFalse() {
        // Metered Mon-Fri 8am-10pm (480-1320). Window is Mon 9am-noon (inside paid hours).
        let from  = et(2026, 5, 11, 9, 0)
        let until = et(2026, 5, 11, 12, 0)
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        XCTAssertFalse(
            engine.isFree(segment: segment, from: from, until: until),
            "Default (omitted) ignoringMeteredPayment must behave exactly as pre-amendment isFree — metered paid hours still disqualify"
        )
    }

    // MARK: - testIsFree_ignoringMeteredPaymentTrue_meteredActiveInWindow_returnsTrue
    // §0.8.4: ignoringMeteredPayment: true treats metered paid hours as non-blocking.

    func testIsFree_ignoringMeteredPaymentTrue_meteredActiveInWindow_returnsTrue() {
        let from  = et(2026, 5, 11, 9, 0)
        let until = et(2026, 5, 11, 12, 0)
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        XCTAssertTrue(
            engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: true),
            "ignoringMeteredPayment: true must treat metered paid hours as non-blocking (§0.8.4)"
        )
    }

    // MARK: - testIsFree_ignoringMeteredPaymentTrue_aspActiveInWindow_stillReturnsFalse
    // §0.8.4: the flag only touches the METERED branch — ASP must still disqualify.

    func testIsFree_ignoringMeteredPaymentTrue_aspActiveInWindow_stillReturnsFalse() {
        // ASP_MON_THU Mon/Thu 7:00-9:30am (420-570). Window Mon 6am-11am overlaps it.
        let from  = et(2026, 5, 11, 6, 0)
        let until = et(2026, 5, 11, 11, 0)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertFalse(
            engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: true),
            "ignoringMeteredPayment must NOT affect ASP — Mon 7-9:30am ASP inside window still disqualifies"
        )
    }

    // MARK: - testIsFree_ignoringMeteredPaymentTrue_noStandingAnytime_stillReturnsFalse

    func testIsFree_ignoringMeteredPaymentTrue_noStandingAnytime_stillReturnsFalse() {
        let segment = seg(rules: [r(category: .noStanding, days: [], anytime: true)])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertFalse(
            engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: true),
            "ignoringMeteredPayment must NOT affect NO_STANDING anytime — still disqualifies"
        )
    }

    // MARK: - testIsFree_ignoringMeteredPaymentTrue_noParkingAnytime_stillReturnsFalse

    func testIsFree_ignoringMeteredPaymentTrue_noParkingAnytime_stillReturnsFalse() {
        let segment = seg(rules: [r(category: .noParking, days: [], anytime: true)])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertFalse(
            engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: true),
            "ignoringMeteredPayment must NOT affect NO_PARKING anytime — still disqualifies"
        )
    }

    // MARK: - testIsFree_ignoringMeteredPaymentTrue_truckLoadingAnytime_stillReturnsFalse

    func testIsFree_ignoringMeteredPaymentTrue_truckLoadingAnytime_stillReturnsFalse() {
        let segment = seg(rules: [r(category: .truckLoading, days: [], anytime: true)])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertFalse(
            engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: true),
            "ignoringMeteredPayment must NOT affect TRUCK_LOADING anytime — still disqualifies"
        )
    }
}

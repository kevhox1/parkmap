//
//  ParkingGoalsTests.swift
//  WeParkTests
//
//  DM-2e unit tests for Services/ParkingGoals.swift (docs/drive-mode-default-spec.md
//  §0.8, §5 — AC-24, AC-25, AC-26 + supporting sanity coverage for target resolution,
//  the metered-tolerance wiring, and the date-only relative-day label formatter).
//
//  Test structure:
//    Sanity / wiring:
//      - testTarget_freeOvernight_isStartOfDayOffsetTwo
//      - testTarget_freeFewHours_isPlusThreeHours
//      - testIgnoresMeteredPayment_perGoal
//      - testMatch_freeOvernight_meteredOnlySegment_matchesDespitePaidHoursRightNow
//      - testMatch_freeFewHours_meteredActiveInWindow_nonMatching
//    AC-24 (Free Overnight day-boundary, any ASP start hour):
//      - testMatch_freeOvernight_aspTomorrowEarlyStart_nonMatching
//      - testMatch_freeOvernight_aspTomorrowLateStart_nonMatching
//      - testMatch_freeOvernight_nextAspDayDayAfterTomorrowOrLater_matching
//    AC-25 (Park & Forget ladder + ranking):
//      - testMatch_parkAndForget_clearsTopRung_meteredOnlySegment
//      - testMatch_parkAndForget_clearsMiddleRung_weekendGap
//      - testMatch_parkAndForget_clearsBottomRungOnly
//      - testMatch_parkAndForget_failsEvenBottomRung_nonMatching
//      - testMatch_parkAndForget_topRungRanksAboveBottomRung
//    AC-26 (suspended ASP day is a non-event):
//      - testMatch_freeOvernight_suspendedAspDayTomorrow_matching
//      - testGoodThroughLabel_suspendedAspDaySkipped_resolvesToNextRealRestriction
//    relativeDayLabel / goodThroughLabel formatter tiers:
//      - testRelativeDayLabel_today / _tomorrow / _withinWeek / _beyondWeek
//      - testGoodThroughLabel_noRulesAtAll_returnsNil
//
//  All dates constructed via Calendar.easternTime. Zero Calendar.current references.
//
//  Reference dates:
//    2026-05-11 (Monday):  ASP_MON_THU day, not suspended.
//    2026-05-14 (Thursday): Solemnity of the Ascension — suspended in asp-2026.json.
//    2026-05-18 (Monday):  not suspended — the "next REAL restriction" AC-26 resolves to.
//    2026-06-04 (Thursday) / 2026-06-07 (Sunday) / 2026-06-08 (Monday) / 2026-06-09
//    (Tuesday): all unsuspended, used for the AC-25 ladder tests (June has no
//    suspension entries near these dates in asp-2026.json other than Juneteenth 6/19).
//

import XCTest
@testable import WePark

// MARK: - ParkingGoalsTests

final class ParkingGoalsTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
    }

    // MARK: - Helpers (private to this class — no cross-file XCTestCase extension)

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
            "id": "PG_TEST",
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

    // MARK: - Sanity: target resolution

    func testTarget_freeOvernight_isStartOfDayOffsetTwo() {
        let from = et(2026, 5, 11, 15, 0)
        let expected = et(2026, 5, 13, 0, 0)
        XCTAssertEqual(ParkingGoals.target(for: .freeOvernight, from: from), expected,
                       "Free Overnight target must be startOfDayET(offsetDays: 2) — a calendar-day boundary, not a clock hour")
    }

    func testTarget_freeFewHours_isPlusThreeHours() {
        let from = et(2026, 5, 11, 15, 0)
        XCTAssertEqual(ParkingGoals.target(for: .freeFewHours, from: from),
                       from.addingTimeInterval(3 * 3600),
                       "Free a Few Hours target must be from + 3h (§0.8.5, RULED LOCKED)")
    }

    func testIgnoresMeteredPayment_perGoal() {
        XCTAssertTrue(ParkingGoals.ignoresMeteredPayment(for: .freeOvernight),
                      "Free Overnight must ignore metered payment (§0.8.4)")
        XCTAssertTrue(ParkingGoals.ignoresMeteredPayment(for: .parkAndForget),
                      "Park & Forget must ignore metered payment (§0.8.4)")
        XCTAssertFalse(ParkingGoals.ignoresMeteredPayment(for: .freeFewHours),
                       "Free a Few Hours must NOT ignore metered payment — strict, RULED LOCKED (§0.8.5)")
    }

    // MARK: - Sanity: metered-tolerance wiring

    func testMatch_freeOvernight_meteredOnlySegment_matchesDespitePaidHoursRightNow() {
        // Metered Mon-Fri 8am-10pm only, no ASP/no-standing/no-parking rules at all.
        // Free Overnight's job is "would I have to MOVE it" — paying a meter isn't
        // moving (§0.8.2's own worked example).
        let from = et(2026, 5, 11, 9, 0)   // Monday 9am — inside the metered paid window right now.
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: from, engine: engine)
        XCTAssertTrue(result.matches,
                      "A metered-only segment must match Free Overnight even while actively paid right now (§0.8.2)")
    }

    func testMatch_freeFewHours_meteredActiveInWindow_nonMatching() {
        // Metered Mon-Fri 8am-10pm. +3h window from 9am is [9am, noon] — inside paid hours.
        let from = et(2026, 5, 11, 9, 0)
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeFewHours, from: from, engine: engine)
        XCTAssertFalse(result.matches,
                       "Free a Few Hours is strict — an active meter inside the +3h window disqualifies (§0.8.5)")
    }

    // MARK: - AC-24: Free Overnight day-boundary, any ASP start hour

    func testMatch_freeOvernight_aspTomorrowEarlyStart_nonMatching() {
        // ASP_TUE_FRI, early start (7:00-9:30am). "Tomorrow" (Tuesday) is fully inside
        // the [now, day-after-tomorrow midnight) window regardless of the sweep's hour.
        let from = et(2026, 5, 11, 20, 0)  // Monday 8:00 PM
        let segment = seg(rules: [r(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: from, engine: engine)
        XCTAssertFalse(result.matches,
                       "ASP tomorrow (early start) must be non-matching — the car would have to move")
    }

    func testMatch_freeOvernight_aspTomorrowLateStart_nonMatching() {
        // Same window as above, but the ASP sweep starts LATE (11:30am-1pm, 690-780).
        // A naive "now → tomorrow 8am" cutoff would have MISSED this; the day-boundary
        // target must still catch it (§0.8.2's reason #1 for rejecting a clock-hour cutoff).
        let from = et(2026, 5, 11, 20, 0)  // Monday 8:00 PM
        let segment = seg(rules: [r(category: .aspTueFri, days: [2, 5], timeRanges: [(690, 780)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: from, engine: engine)
        XCTAssertFalse(result.matches,
                       "ASP tomorrow with a LATE start hour must still be non-matching — day boundary, not clock hour")
    }

    func testMatch_freeOvernight_nextAspDayDayAfterTomorrowOrLater_matching() {
        // ASP_MON_THU. `from` is just after Monday's own 9:30am window closes, so the
        // window [from, Wed midnight) contains neither the rest of Monday's (already
        // past) ASP nor any Tuesday ASP (not a Mon/Thu day) — matching. The next real
        // ASP day is Thursday (day-after-tomorrow-or-later).
        let from = et(2026, 5, 11, 10, 0)  // Monday 10:00 AM (ASP window closed at 9:30am)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: from, engine: engine)
        XCTAssertTrue(result.matches,
                      "Next ASP day (Thursday) is day-after-tomorrow or later → must be matching")
    }

    // MARK: - AC-25: Park & Forget ladder + ranking

    func testMatch_parkAndForget_clearsTopRung_meteredOnlySegment() {
        // No weekly move-forcing rule at all (metered-only) — clears any window once
        // meters are ignored, including the top rung (amendment banner ruling #1).
        let from = et(2026, 6, 4, 10, 0)  // Thursday
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let result = ParkingGoals.match(segment: segment, goal: .parkAndForget, from: from, engine: engine)
        XCTAssertTrue(result.matches)
        XCTAssertEqual(result.clearedRungOffsetDays, 8,
                       "A segment with no weekly move-forcing rule must clear the top rung (offsetDays: 8)")
    }

    func testMatch_parkAndForget_clearsMiddleRung_weekendGap() {
        // ASP_MON_THU, from Thursday 10am (that day's own 9:30am window already closed).
        // Clear through Fri/Sat/Sun into (but not including) the following Monday's
        // 00:00 boundary — clears offsetDays: 4 but fails offsetDays: 8 (which pulls
        // the following Monday's ASP window fully into scope). The classic Thu→Mon
        // weekend-gap case (§0.8.3's worked example).
        let from = et(2026, 6, 4, 10, 0)  // Thursday
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        let result = ParkingGoals.match(segment: segment, goal: .parkAndForget, from: from, engine: engine)
        XCTAssertTrue(result.matches)
        XCTAssertEqual(result.clearedRungOffsetDays, 4,
                       "Thu→Mon weekend gap must clear the middle rung (offsetDays: 4), not the top")
    }

    func testMatch_parkAndForget_clearsBottomRungOnly() {
        // ASP_TUE_FRI, from Sunday 10am. The window to the following Thursday
        // (offsetDays: 4) and the Monday-after-next (offsetDays: 8) both pull next
        // Tuesday's ASP fully into scope, but the offsetDays: 2 window ends exactly at
        // next Tuesday's midnight (excluded) — clears only the bottom rung.
        let from = et(2026, 6, 7, 10, 0)  // Sunday
        let segment = seg(rules: [r(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])])
        let result = ParkingGoals.match(segment: segment, goal: .parkAndForget, from: from, engine: engine)
        XCTAssertTrue(result.matches)
        XCTAssertEqual(result.clearedRungOffsetDays, 2,
                       "A block clearing only Free Overnight's own bar must land on the bottom rung (offsetDays: 2)")
    }

    func testMatch_parkAndForget_failsEvenBottomRung_nonMatching() {
        // NO_PARKING anytime:true fails every rung, including the bottom one.
        let from = et(2026, 6, 4, 10, 0)
        let segment = seg(rules: [r(category: .noParking, days: [], anytime: true)])
        let result = ParkingGoals.match(segment: segment, goal: .parkAndForget, from: from, engine: engine)
        XCTAssertFalse(result.matches)
        XCTAssertNil(result.clearedRungOffsetDays,
                     "A segment that fails even the bottom rung must report matches == false, clearedRungOffsetDays == nil")
    }

    func testMatch_parkAndForget_topRungRanksAboveBottomRung() {
        // §0.8.3a: "a block that clears the top rung is labeled/ranked above one that
        // only clears the bottom." clearedRungOffsetDays is directly comparable —
        // larger offsetDays == a stronger, further-out clearance.
        let topSegment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let bottomSegment = seg(rules: [r(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])])

        let topFrom = et(2026, 6, 4, 10, 0)     // Thursday
        let bottomFrom = et(2026, 6, 7, 10, 0)  // Sunday

        let topResult = ParkingGoals.match(segment: topSegment, goal: .parkAndForget, from: topFrom, engine: engine)
        let bottomResult = ParkingGoals.match(segment: bottomSegment, goal: .parkAndForget, from: bottomFrom, engine: engine)

        XCTAssertTrue(topResult.matches)
        XCTAssertTrue(bottomResult.matches)
        guard let topRung = topResult.clearedRungOffsetDays, let bottomRung = bottomResult.clearedRungOffsetDays else {
            return XCTFail("Both segments must report a cleared rung")
        }
        XCTAssertGreaterThan(topRung, bottomRung,
                             "Top-rung block's clearedRungOffsetDays must rank above bottom-rung block's")

        // The ranking label corroborates: the top-rung (no weekly rule) segment is
        // "indefinitely clear" (nextMoveForcingDate == nil), the bottom-rung segment
        // resolves to a real, bounded date — nil unambiguously outranks a bounded date.
        XCTAssertNil(ParkingGoals.nextMoveForcingDate(for: topSegment, from: topFrom, engine: engine))
        XCTAssertNotNil(ParkingGoals.nextMoveForcingDate(for: bottomSegment, from: bottomFrom, engine: engine))
    }

    // MARK: - AC-26: a suspended ASP day inside the window is a non-event

    func testMatch_freeOvernight_suspendedAspDayTomorrow_matching() {
        // Thursday 2026-05-14 (Ascension) is suspended. ASP_MON_THU's only occurrence
        // inside [Wed 10am, Fri midnight) is that suspended Thursday — a non-event.
        let from = et(2026, 5, 13, 10, 0)  // Wednesday
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        let result = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: from, engine: engine)
        XCTAssertTrue(result.matches,
                      "A suspended ASP day inside the window must be a non-event — segment still matches")
    }

    func testGoodThroughLabel_suspendedAspDaySkipped_resolvesToNextRealRestriction() {
        // Same segment/window as above. The ranking label must skip past the suspended
        // Thursday (05-14) and resolve to the next REAL restriction: Monday 05-18 7am —
        // not the suspended Thursday. No new suspension-handling code is required for
        // this (§0.8.3a) — nextRestriction's own 14-day ASP walker already skips
        // suspended dates; this test is the proof.
        let from = et(2026, 5, 13, 10, 0)  // Wednesday
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])

        let date = ParkingGoals.nextMoveForcingDate(for: segment, from: from, engine: engine)
        XCTAssertEqual(date, et(2026, 5, 18, 7, 0),
                       "Must resolve to Monday 05-18 7am, skipping the suspended Thursday 05-14 entirely")

        let label = ParkingGoals.goodThroughLabel(for: segment, from: from, engine: engine)
        XCTAssertEqual(label, "Good through Mon",
                       "Label must reflect the next REAL restriction day (Mon), not the suspended Thursday")
    }

    // MARK: - relativeDayLabel / goodThroughLabel formatter tiers

    func testRelativeDayLabel_today() {
        XCTAssertEqual(
            ParkingGoals.relativeDayLabel(for: et(2026, 5, 11, 15, 0), from: et(2026, 5, 11, 9, 0)),
            "Today"
        )
    }

    func testRelativeDayLabel_tomorrow() {
        XCTAssertEqual(
            ParkingGoals.relativeDayLabel(for: et(2026, 5, 12, 9, 0), from: et(2026, 5, 11, 9, 0)),
            "Tomorrow"
        )
    }

    func testRelativeDayLabel_withinWeek() {
        // 2026-05-14 is a Thursday, 3 days after Monday 2026-05-11.
        XCTAssertEqual(
            ParkingGoals.relativeDayLabel(for: et(2026, 5, 14, 9, 0), from: et(2026, 5, 11, 9, 0)),
            "Thu"
        )
    }

    func testRelativeDayLabel_beyondWeek() {
        // 2026-05-25 is 14 days after Monday 2026-05-11.
        XCTAssertEqual(
            ParkingGoals.relativeDayLabel(for: et(2026, 5, 25, 9, 0), from: et(2026, 5, 11, 9, 0)),
            "May 25"
        )
    }

    func testGoodThroughLabel_noRulesAtAll_returnsNil() {
        let segment = seg(rules: [])
        let label = ParkingGoals.goodThroughLabel(for: segment, from: et(2026, 5, 11, 9, 0), engine: engine)
        XCTAssertNil(label, "No rules at all → nextRestriction's sentinel → goodThroughLabel must be nil, not a fabricated string")
    }
}

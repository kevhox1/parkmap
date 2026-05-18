//
//  ParkUntilTests.swift
//  WeParkTests
//
//  W7.5 unit tests for ParkingRulesEngine.isFree(segment:from:until:).
//  Spec: docs/w7.5-park-until-x-spec.md §7.
//
//  Test structure:
//    - testIsFree_noRules_returnsTrue
//    - testIsFree_noParkingAnytime_returnsFalse
//    - testIsFree_noStandingAnytime_returnsFalse
//    - testIsFree_aspWindow_windowBeforeASP_returnsTrue          (AC-W7.5.3)
//    - testIsFree_aspWindow_windowOverlapsASPStart_returnsFalse  (AC-W7.5.4)
//    - testIsFree_aspWindow_windowAfterASP_returnsTrue           (AC-W7.5.5)
//    - testIsFree_aspWindow_suspendedDate_returnsTrue            (AC-W7.5.8)
//    - testIsFree_aspWindow_unsuspendedAdjacentDay_returnsFalse
//    - testIsFree_metered_paidHoursInWindow_returnsFalse         (AC-W7.5.6)
//    - testIsFree_metered_freeHoursOnly_returnsTrue              (AC-W7.5.7)
//    - testIsFree_noParkingScheduled_dayNotMatch_returnsTrue
//    - testIsFree_noParkingScheduled_dayMatch_timeOverlap_returnsFalse
//    - testIsFree_noParkingScheduled_dayMatch_timeNoOverlap_returnsTrue
//    - testIsFree_crossMidnightWindow_overnightRuleOverlap_returnsFalse (AC-W7.5.10)
//    - testIsFree_crossMidnightWindow_overnightRuleNoOverlap_returnsTrue
//    - testIsFree_multipleRules_oneConflicts_returnsFalse
//    - testIsFree_multipleRules_noneConflict_returnsTrue
//    - testIsFree_windowEqualsASPWindowExactly_returnsFalse
//    - testIsFree_windowEndsAtASPStart_returnsTrue
//    - testIsFree_usesEasternTimeCalendar_noCurrentCalendar (static review marker)
//
//  All dates constructed via Calendar.easternTime. Zero Calendar.current references.
//
//  Test reference dates:
//    2026-05-11 (Monday):  ASP_MON_THU day, not suspended in asp-2026.json.
//    2026-05-14 (Thursday): Ascension Day — suspended in asp-2026.json.
//    2026-05-12 (Tuesday): Not an ASP_MON_THU day.
//
//  ASP_MON_THU typical window: 7:00 AM – 9:30 AM (420 – 570 minutes).
//

import XCTest
@testable import WePark

// MARK: - ParkUntilTests

final class ParkUntilTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
    }

    // MARK: - Helpers

    /// Builds a Date at the given ET components.
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

    /// Builds a minimal Segment with the given rules.
    private func seg(rules: [ParkingRule]) -> Segment {
        let ruleData = try! JSONEncoder().encode(rules)
        let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
        let segDict: [String: Any] = [
            "id": "PU_TEST",
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

    /// Builds a ParkingRule.
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

    // MARK: - testIsFree_noRules_returnsTrue
    // Spec §7 / AC-W7.5.1: Empty rules → always free.

    func testIsFree_noRules_returnsTrue() {
        let segment = seg(rules: [])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "No rules → isFree must return true")
    }

    // MARK: - testIsFree_noParkingAnytime_returnsFalse
    // Spec §7 / AC-W7.5.2: NO_PARKING with anytime:true → always false.

    func testIsFree_noParkingAnytime_returnsFalse() {
        let segment = seg(rules: [r(category: .noParking, days: [], anytime: true)])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "NO_PARKING anytime:true → isFree must return false")
    }

    // MARK: - testIsFree_noStandingAnytime_returnsFalse
    // Spec §7: NO_STANDING with anytime:true → always false.

    func testIsFree_noStandingAnytime_returnsFalse() {
        let segment = seg(rules: [r(category: .noStanding, days: [], anytime: true)])
        let from  = et(2026, 5, 11, 8, 0)
        let until = et(2026, 5, 11, 10, 0)
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "NO_STANDING anytime:true → isFree must return false")
    }

    // MARK: - testIsFree_aspWindow_windowBeforeASP_returnsTrue
    // AC-W7.5.3: Window [Sunday 8pm, Monday 6am] — does NOT contain Monday 7am ASP start.
    // Correct result: true. The ASP window (Mon 7am–9:30am) starts AFTER until (Mon 6am).

    func testIsFree_aspWindow_windowBeforeASP_returnsTrue() {
        // 2026-05-10 (Sunday) 8pm to 2026-05-11 (Monday) 6am — window ends before Mon ASP.
        let from  = et(2026, 5, 10, 20, 0)  // Sunday 8:00 PM
        let until = et(2026, 5, 11, 6, 0)   // Monday 6:00 AM (ASP starts at 7am)
        // ASP_MON_THU: Mon, Thu; 7:00 AM – 9:30 AM.
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Window [Sun 8pm, Mon 6am] ends before Mon 7am ASP start → must be true")
    }

    // MARK: - testIsFree_aspWindow_windowOverlapsASPStart_returnsFalse
    // AC-W7.5.4: Window [Monday 6am, Monday 11am] overlaps Mon 7am–9:30am ASP.

    func testIsFree_aspWindow_windowOverlapsASPStart_returnsFalse() {
        // 2026-05-11 (Monday) 6am to 11am — overlaps Mon 7am ASP.
        let from  = et(2026, 5, 11, 6, 0)   // Monday 6:00 AM
        let until = et(2026, 5, 11, 11, 0)  // Monday 11:00 AM
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "Window [Mon 6am, Mon 11am] overlaps Mon 7am–9:30am ASP → must be false")
    }

    // MARK: - testIsFree_aspWindow_windowAfterASP_returnsTrue
    // AC-W7.5.5: Window [Monday 10am, Monday 2pm] — ASP ended at 9:30am.

    func testIsFree_aspWindow_windowAfterASP_returnsTrue() {
        // 2026-05-11 (Monday) 10am to 2pm — ASP ended at 9:30am.
        let from  = et(2026, 5, 11, 10, 0)  // Monday 10:00 AM
        let until = et(2026, 5, 11, 14, 0)  // Monday 2:00 PM
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Window [Mon 10am, Mon 2pm] is after Mon 9:30am ASP end → must be true")
    }

    // MARK: - testIsFree_aspWindow_suspendedDate_returnsTrue
    // AC-W7.5.8: ASP day is in the suspension calendar → isFree returns true.
    // 2026-05-14 (Thursday) is Ascension Day — suspended in asp-2026.json.

    func testIsFree_aspWindow_suspendedDate_returnsTrue() {
        // Thursday 2026-05-14 (Ascension — suspended). Window covers ASP hours.
        let from  = et(2026, 5, 14, 6, 0)   // Thursday 6:00 AM
        let until = et(2026, 5, 14, 11, 0)  // Thursday 11:00 AM
        // ASP_MON_THU applies Mon (1) and Thu (4).
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Suspended Thursday (Ascension 2026-05-14) → isFree must return true")
    }

    // MARK: - testIsFree_aspWindow_unsuspendedAdjacentDay_returnsFalse
    // Adjacent non-suspended Monday (2026-05-11) is in the window → false.

    func testIsFree_aspWindow_unsuspendedAdjacentDay_returnsFalse() {
        // Window crosses Sunday-Monday boundary — Monday is unsuspended.
        let from  = et(2026, 5, 10, 22, 0)  // Sunday 10:00 PM
        let until = et(2026, 5, 11, 8, 0)   // Monday 8:00 AM (inside Mon 7am–9:30am)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "Monday 2026-05-11 is unsuspended and window covers 7am ASP → must be false")
    }

    // MARK: - testIsFree_metered_paidHoursInWindow_returnsFalse
    // AC-W7.5.6: Metered segment with paid hours overlapping the window → false.

    func testIsFree_metered_paidHoursInWindow_returnsFalse() {
        // Metered Mon–Fri 8am–10pm (480–1320). Window is Mon 9am–noon.
        let from  = et(2026, 5, 11, 9, 0)   // Monday 9:00 AM
        let until = et(2026, 5, 11, 12, 0)  // Monday 12:00 PM
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "Metered paid hours overlap window → isFree must return false")
    }

    // MARK: - testIsFree_metered_freeHoursOnly_returnsTrue
    // AC-W7.5.7: Window falls entirely outside metered paid hours → true.

    func testIsFree_metered_freeHoursOnly_returnsTrue() {
        // Metered Mon–Fri 8am–6pm (480–1080). Window is Mon 7pm–9pm (after paid hours).
        let from  = et(2026, 5, 11, 19, 0)  // Monday 7:00 PM
        let until = et(2026, 5, 11, 21, 0)  // Monday 9:00 PM
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1080)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Window falls outside metered paid hours → isFree must return true")
    }

    // MARK: - testIsFree_noParkingScheduled_dayNotMatch_returnsTrue
    // NO_PARKING scheduled Mon only — window is on a Tuesday → no overlap.

    func testIsFree_noParkingScheduled_dayNotMatch_returnsTrue() {
        // NO_PARKING Mon 8am–10am. Window is Tue 8am–10am.
        let from  = et(2026, 5, 12, 8, 0)   // Tuesday 8:00 AM
        let until = et(2026, 5, 12, 10, 0)  // Tuesday 10:00 AM
        // day 1 = Monday; day 2 = Tuesday
        let segment = seg(rules: [r(category: .noParking, days: [1], timeRanges: [(480, 600)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "NO_PARKING on Mon only; window is Tue → isFree must return true")
    }

    // MARK: - testIsFree_noParkingScheduled_dayMatch_timeOverlap_returnsFalse
    // NO_PARKING on Monday, time overlaps window → false.

    func testIsFree_noParkingScheduled_dayMatch_timeOverlap_returnsFalse() {
        // NO_PARKING Mon 8am–10am. Window is Mon 9am–11am (overlaps).
        let from  = et(2026, 5, 11, 9, 0)   // Monday 9:00 AM
        let until = et(2026, 5, 11, 11, 0)  // Monday 11:00 AM
        let segment = seg(rules: [r(category: .noParking, days: [1], timeRanges: [(480, 600)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "NO_PARKING Mon 8am–10am overlaps [Mon 9am, 11am] → must be false")
    }

    // MARK: - testIsFree_noParkingScheduled_dayMatch_timeNoOverlap_returnsTrue
    // NO_PARKING on Monday morning — window is Monday afternoon.

    func testIsFree_noParkingScheduled_dayMatch_timeNoOverlap_returnsTrue() {
        // NO_PARKING Mon 8am–10am. Window is Mon 11am–1pm (no overlap).
        let from  = et(2026, 5, 11, 11, 0)  // Monday 11:00 AM
        let until = et(2026, 5, 11, 13, 0)  // Monday 1:00 PM
        let segment = seg(rules: [r(category: .noParking, days: [1], timeRanges: [(480, 600)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "NO_PARKING Mon 8am–10am; window [Mon 11am, 1pm] has no overlap → must be true")
    }

    // MARK: - testIsFree_crossMidnightWindow_overnightRuleOverlap_returnsFalse
    // AC-W7.5.10: Overnight rule (11pm–1am) overlaps cross-midnight window.

    func testIsFree_crossMidnightWindow_overnightRuleOverlap_returnsFalse() {
        // NO_PARKING Mon 11pm–Tue 1am (rule: start=1380, end=60). Window: Mon 11pm – Tue 12:30am.
        // 2026-05-11 (Monday) 11pm to 2026-05-12 (Tuesday) 12:30am.
        let from  = et(2026, 5, 11, 23, 0)  // Monday 11:00 PM
        let until = et(2026, 5, 12, 0, 30)  // Tuesday 12:30 AM
        // days: [1] = Monday; overnight rule start=1380(11pm), end=60(1am).
        let segment = seg(rules: [r(category: .noParking, days: [1], timeRanges: [(1380, 60)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "Overnight NO_PARKING rule 11pm–1am overlaps [Mon 11pm, Tue 12:30am] → false")
    }

    // MARK: - testIsFree_crossMidnightWindow_overnightRuleNoOverlap_returnsTrue
    // Overnight rule ends before the window starts → no overlap.

    func testIsFree_crossMidnightWindow_overnightRuleNoOverlap_returnsTrue() {
        // NO_PARKING Mon 11pm–Tue 1am. Window is Tue 2am–4am (rule already ended).
        let from  = et(2026, 5, 12, 2, 0)   // Tuesday 2:00 AM
        let until = et(2026, 5, 12, 4, 0)   // Tuesday 4:00 AM
        let segment = seg(rules: [r(category: .noParking, days: [1], timeRanges: [(1380, 60)])])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Overnight rule ends at 1am; window [Tue 2am, 4am] has no overlap → true")
    }

    // MARK: - testIsFree_multipleRules_oneConflicts_returnsFalse
    // Two rules: one ASP (no conflict in window), one NO_PARKING (conflict) → false.

    func testIsFree_multipleRules_oneConflicts_returnsFalse() {
        // ASP_TUE_FRI: applies Tue/Fri 7am–9:30am. Window is Mon 8am–10am (not a Tue/Fri).
        // NO_PARKING: Mon 8am–10am (480–600). Window overlaps.
        let from  = et(2026, 5, 11, 8, 0)   // Monday 8:00 AM
        let until = et(2026, 5, 11, 10, 0)  // Monday 10:00 AM
        let aspRule = r(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])
        let noPark  = r(category: .noParking, days: [1], timeRanges: [(480, 600)])
        let segment = seg(rules: [aspRule, noPark])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "NO_PARKING Mon 8am–10am conflicts with window → must be false even if ASP doesn't conflict")
    }

    // MARK: - testIsFree_multipleRules_noneConflict_returnsTrue
    // Two rules, both outside window → true.

    func testIsFree_multipleRules_noneConflict_returnsTrue() {
        // ASP_MON_THU: Mon 7am–9:30am. Window is Mon 10am–2pm (after ASP).
        // NO_PARKING: Tue 8am–10am (conflict only on Tuesday). Window is Monday.
        let from  = et(2026, 5, 11, 10, 0)  // Monday 10:00 AM
        let until = et(2026, 5, 11, 14, 0)  // Monday 2:00 PM
        let asp    = r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])
        let noPark = r(category: .noParking, days: [2], timeRanges: [(480, 600)])
        let segment = seg(rules: [asp, noPark])
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Neither rule conflicts with [Mon 10am, 2pm] → must be true")
    }

    // MARK: - testIsFree_windowEqualsASPWindowExactly_returnsFalse
    // Window exactly matches ASP time range (closed-interval overlap) → false.

    func testIsFree_windowEqualsASPWindowExactly_returnsFalse() {
        // Window [Mon 7:00 AM, Mon 9:30 AM] exactly equals ASP window.
        let from  = et(2026, 5, 11, 7, 0)   // Monday 7:00 AM (ASP start)
        let until = et(2026, 5, 11, 9, 30)  // Monday 9:30 AM (ASP end)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "Window exactly matching ASP [7am, 9:30am] → isFree must be false")
    }

    // MARK: - testIsFree_windowEndsAtASPStart_returnsTrue
    // Window's `until` equals ASP start — half-open interval [from, until) → no overlap.
    // Spec §7 note: "Window's `until` equals ASP `start` → true if half-open semantics."

    func testIsFree_windowEndsAtASPStart_returnsTrue() {
        // Window [Mon 5:00 AM, Mon 7:00 AM]. ASP starts at 7:00 AM.
        // Under half-open semantics, the window ends exactly when ASP begins → no overlap.
        let from  = et(2026, 5, 11, 5, 0)   // Monday 5:00 AM
        let until = et(2026, 5, 11, 7, 0)   // Monday 7:00 AM (= ASP start)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        // Half-open: restriction start (7:00 AM) == windowEnd → NOT a conflict.
        // This matches the PWA's behavior (strict < for end comparison at index.html:4347).
        XCTAssertTrue(engine.isFree(segment: segment, from: from, until: until),
                      "Window [Mon 5am, 7am] ends exactly at ASP start (7am) → no overlap → true")
    }

    // MARK: - testIsFree_usesEasternTimeCalendar_noCurrentCalendar
    // MARK: - Review: Static assertion — no Calendar.current in isFree implementation.
    //
    // This is a code-review check, not a runtime test. The grep command:
    //   grep -n "Calendar.current" ios/WePark/WePark/Services/ParkingRulesEngine.swift
    // must return zero hits in the isFree / timeRangeOverlaps methods.
    //
    // Runtime guard: verify the engine produces ET-correct output regardless of device TZ.

    func testIsFree_usesEasternTimeCalendar_noCurrentCalendar() {
        // Verify the engine gives the correct answer for a Monday-specific rule even when
        // the "local" interpretation might differ (e.g., if device were in Pacific time,
        // Mon 7am ET = Sun 4am PT — a Sunday — the rule should still fire as Monday).
        //
        // We can only verify behavior correctness here. The Calendar.current grep is done
        // as a CI / code-review static check per spec §7.
        let from  = et(2026, 5, 11, 6, 0)   // Monday 6:00 AM ET
        let until = et(2026, 5, 11, 11, 0)  // Monday 11:00 AM ET (overlaps Mon 7am ASP)
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        // Must be false — the engine must use ET calendar (Mon), not device-local.
        XCTAssertFalse(engine.isFree(segment: segment, from: from, until: until),
                       "isFree must use ET calendar — Mon ASP at 7am overlaps [Mon 6am, 11am]")
    }
}

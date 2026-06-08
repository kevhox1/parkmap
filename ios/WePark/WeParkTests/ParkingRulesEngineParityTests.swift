//
//  ParkingRulesEngineParityTests.swift
//  WeParkTests
//
//  Parity tests for ParkingRulesEngine — Swift output must match PWA behavior
//  for the same inputs. Required by docs/ios-mvp-spec.md §7 R2.
//
//  Test structure:
//    Group 1: R2 boundary cases (5 mandatory cases from spec §7)
//    Group 2: Happy-path parity cases using real tile data
//    Group 3: Option B currentState classification
//    Group 4: StreetNameNormalizer parity
//    Group 5: ASPSuspensionService correctness
//
//  Time reference: 2026-05-10 is the current date (Sunday, ET).
//  ASP suspended dates in 2026 near May: 2026-05-14 (Ascension), 2026-05-22/23 (Shavuoth),
//  2026-05-25 (Memorial Day), 2026-05-27/28 (Eid Al-Adha).
//
//  All dates constructed via Calendar.easternTime to ensure ET correctness.
//

import XCTest
@testable import WePark

// MARK: - Test helpers

extension XCTestCase {
    /// Builds a Date in America/New_York at the given components.
    func etDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
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
    func makeSegment(
        id: String = "TEST",
        street: String = "TEST ST",
        dominantCategory: WePark.Category? = nil,
        rules: [ParkingRule]
    ) -> Segment {
        // We use a minimal JSON-compatible initializer by constructing via reflection.
        // Since Segment is Codable, encode then decode with overrides.
        let ruleData = try! JSONEncoder().encode(rules)
        let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
        var segDict: [String: Any] = [
            "id": id,
            "street": street,
            "from": "A ST",
            "to": "B ST",
            "side": "N",
            "line": [[40.75, -73.99], [40.751, -73.991]],
            "rules": rulesJSON,
        ]
        if let dc = dominantCategory {
            segDict["dominantCategory"] = dc.rawValue
        }
        let data = try! JSONSerialization.data(withJSONObject: segDict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    /// Builds a ParkingRule.
    func rule(
        category: WePark.Category,
        days: [Int],
        timeRanges: [(start: Int, end: Int)] = [],
        anytime: Bool = false,
        arrow: String? = "both",
        description: String = ""
    ) -> ParkingRule {
        let ranges = timeRanges.map { TimeRange(start: $0.start, end: $0.end) }
        let ruleDict: [String: Any] = [
            "category": category.rawValue,
            "description": description,
            "days": days,
            "timeRanges": ranges.map { ["start": $0.start, "end": $0.end] },
            "anytime": anytime,
            "arrow": arrow as Any,
        ]
        let data = try! JSONSerialization.data(withJSONObject: ruleDict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }
}

// MARK: - Group 1: R2 Boundary Cases

final class R2BoundaryCaseTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
    }

    // MARK: BC-1: Saturday → Sunday rollover

    /// Rationale: An ASP_DAILY block at Saturday 11:55pm — what does the engine
    /// return for the upcoming Sunday 7am?
    ///
    /// ASP_DAILY applies Mon–Sat (dayOfWeek 1–6) per isASPDayForCategory.
    /// Sunday (0) is NOT an ASP_DAILY day. So a query on Saturday 11:55pm
    /// should walk to the next Mon and return hours to that Monday.
    ///
    /// 2026-05-09 is Saturday. ASP_DAILY rule with timeRanges [{420, 450}] (7:00–7:30am).
    /// At Sat 11:55pm (23:55 ET), next ASP is Monday 7am (2026-05-11) — skipping Sunday.
    ///
    /// Hours calculation:
    ///   5 min to midnight Sat + 24h Sun + 7h Mon = 5/60 + 24 + 7 = 31.0833...h
    func testBC1_SaturdayToSundayRollover() {
        // Saturday 2026-05-09 at 23:55 ET
        let now = etDate(year: 2026, month: 5, day: 9, hour: 23, minute: 55)
        // ASP_DAILY: applies Mon-Sat, 7:00–7:30am (420–450)
        let seg = makeSegment(
            dominantCategory: .aspDaily,
            rules: [rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(420, 450)])]
        )
        let result = engine.nextRestriction(for: seg, at: now)

        // Should NOT be active now (Saturday at 11:55pm is not ASP_DAILY time)
        XCTAssertFalse(result.isActiveNow, "ASP_DAILY should not be active at Sat 11:55pm")
        // Next ASP is Monday 7:00am
        // Hours: 5min to midnight + 24h Sunday + 7h Monday = 31.0833h (approx)
        XCTAssertGreaterThan(result.hours, 31.0, "Should be > 31h to next Mon 7am")
        XCTAssertLessThan(result.hours, 32.0, "Should be < 32h")
    }

    /// Safety label at Sat 11:55pm for ASP_DAILY: "Free until Monday <7:00 AM>"
    func testBC1_SaturdaySafetyLabel() {
        let now = etDate(year: 2026, month: 5, day: 9, hour: 23, minute: 55)
        let seg = makeSegment(
            dominantCategory: .aspDaily,
            rules: [rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(420, 450)])]
        )
        let label = engine.safetyLabel(for: seg, at: now)
        // Should say "Free until Monday 7:00 AM" (using getNextRestrictionTimeLabel format)
        XCTAssertEqual(label.severity, .free)
        XCTAssertTrue(label.text.hasPrefix("Free until"), "Label should be 'Free until ...'")
        XCTAssertTrue(label.text.contains("Monday"), "Label should reference Monday")
        XCTAssertTrue(label.text.contains("7:00 AM"), "Label should reference 7:00 AM")
    }

    // MARK: BC-2: End-of-month boundary (Jan 31 → Feb 1)

    /// Rationale: Jan 31 2026 is Saturday. Feb 1 2026 is Sunday.
    /// An ASP_MON_THU rule at Saturday 11pm: next ASP is Monday Feb 2.
    ///
    /// The "Tomorrow" detection in nextRestrictionTimeLabel must handle
    /// month rollover: targetDate (1) < etDate (31) but it IS the next calendar day.
    func testBC2_EndOfMonthBoundary() {
        // Saturday Jan 31 2026 at 23:00 ET
        let now = etDate(year: 2026, month: 1, day: 31, hour: 23, minute: 0)
        // ASP_MON_THU: Mon=1, Thu=4, 7:00–9:30am (420–570)
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let result = engine.nextRestriction(for: seg, at: now)

        // Not active at Sat 11pm
        XCTAssertFalse(result.isActiveNow)
        // Next ASP day is Mon Feb 2 at 7am
        // Hours: 1h to midnight + 24h Sun + 7h Mon = 32h
        XCTAssertGreaterThan(result.hours, 31.5)
        XCTAssertLessThan(result.hours, 33.0)
    }

    /// The time label for Jan 31 at 23:00 looking at Feb 2 should say "Monday 7:00 AM"
    /// (not "Tomorrow" — it's 2 days away).
    func testBC2_EndOfMonthTimeLabel() {
        let now = etDate(year: 2026, month: 1, day: 31, hour: 23, minute: 0)
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .free)
        // Feb 2 is Monday, 2 days away — should be "Monday" not "Tomorrow"
        XCTAssertTrue(label.text.contains("Monday"), "Should say Monday, got: \(label.text)")
        XCTAssertFalse(label.text.contains("Tomorrow"), "Should NOT say Tomorrow, got: \(label.text)")
    }

    // MARK: BC-3: Start-of-year boundary (Dec 31 2026 → Jan 1 2027)

    /// Rationale: The 2026 calendar ends Dec 31. Jan 1 2027 has no entry in asp-2026.json
    /// (it belongs to the hypothetical asp-2027.json). The 14-day walker must not crash,
    /// and should degrade gracefully — either treating Jan 1 2027 as unsuspended or
    /// finding no matching ASP day within 14 days.
    ///
    /// Dec 31 2026 is Thursday. Jan 1 2027 is a Friday (no data). Christmas 2026-12-25 IS
    /// suspended. So an ASP_TUE_FRI block at Dec 30 (Wednesday) should find Jan 2 (Friday)
    /// as its next ASP day (skipping Jan 1 which is unknown — treated as non-suspended).
    func testBC3_StartOfYearBoundary_NoCrash() {
        // Dec 31 2026, 10:00am ET (Thursday)
        let now = etDate(year: 2026, month: 12, day: 31, hour: 10, minute: 0)
        // ASP_TUE_FRI rule
        let seg = makeSegment(
            dominantCategory: .aspTueFri,
            rules: [rule(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])]
        )
        // This must not crash — result should be some finite hours value
        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertFalse(result.hours.isNaN, "Hours must not be NaN")
        XCTAssertFalse(result.hours.isInfinite, "Hours must not be infinite")
        // Dec 31 is Thursday (not Tue/Fri ASP day), next Tue/Fri is Jan 2 (Fri)
        // Jan 2 2027 is not in our 2026 calendar so not suspended → should return ~38h
        XCTAssertGreaterThan(result.hours, 0, "Should not be active now on Thursday")
    }

    func testBC3_StartOfYearBoundary_LabelDoesNotCrash() {
        let now = etDate(year: 2026, month: 12, day: 31, hour: 10, minute: 0)
        let seg = makeSegment(
            dominantCategory: .aspTueFri,
            rules: [rule(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])]
        )
        // Must not throw or return empty string
        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertFalse(label.text.isEmpty, "Label must not be empty")
        XCTAssertNotEqual(label.text, "—", "Label must not be the null sentinel")
    }

    // MARK: BC-4: Suspended-day adjacent to non-suspended day

    /// Rationale: Memorial Day 2026-05-25 is suspended. The day before (May 24, Sunday)
    /// is not suspended. May 25 is a Monday.
    /// An ASP_MON_THU block queried on May 23 (Saturday) at 6pm:
    ///   - May 25 (Mon) is suspended → walker SKIPS it
    ///   - Next Mon is Jun 1 → but there's also Thu May 28 (which IS suspended — Eid Al-Adha)
    ///   - Next non-suspended ASP day after May 23 Sat:
    ///       May 25 Mon → suspended
    ///       May 28 Thu → suspended (Eid Al-Adha)
    ///       Jun 1 Mon → NOT suspended → next ASP
    ///
    /// This verifies the 14-day walker correctly SKIPS Memorial Day AND Eid Al-Adha.
    func testBC4_SuspendedDayAdjacentToNonSuspended() {
        // Saturday May 23 2026 at 18:00 ET
        let now = etDate(year: 2026, month: 5, day: 23, hour: 18, minute: 0)
        // ASP_MON_THU: Mon=1, Thu=4, 7:00–9:30am
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let result = engine.nextRestriction(for: seg, at: now)

        // Verify the result is NOT hours 0 (not active now on Saturday)
        XCTAssertFalse(result.isActiveNow, "Should not be active on Saturday")

        // May 25 Mon is suspended, May 28 Thu is suspended.
        // Next unsuspended is Thu Jun 4 (another Thu after Jun 1 Mon):
        //   Actually Jun 1 is Mon (first unsuspended Mon).
        //   Hours from May 23 18:00 to Jun 1 7:00:
        //     = 6h (rest of May 23) + 24*8 days (May 24-31) + 7h = 6 + 192 + 7 = 205h
        // But also check if there's an earlier non-suspended Thu:
        //   May 28 = Thu but suspended.
        //   So next unsuspended Mon/Thu is Jun 1 Mon at 7am.
        // Give a range check, not exact, since we want to verify skipping behavior:
        XCTAssertGreaterThan(result.hours, 100, "Should skip suspended Mon May 25 and Thu May 28")

        // Verify the suspension service recognizes May 25 as suspended
        let may25 = etDate(year: 2026, month: 5, day: 25)
        XCTAssertTrue(aspService.isSuspended(may25), "May 25 should be suspended (Memorial Day)")

        // Verify May 24 (Sunday) is NOT suspended
        let may24 = etDate(year: 2026, month: 5, day: 24)
        XCTAssertFalse(aspService.isSuspended(may24), "May 24 should NOT be suspended")
    }

    // MARK: BC-5: Midnight ET exactly

    /// Rationale: A query at exactly 00:00 ET on a day with morning ASP.
    /// An ASP_MON_THU block queried at exactly Mon midnight (00:00): the rule
    /// has timeRanges [{420, 570}] = 7:00–9:30am.
    ///
    /// At midnight (minuteOfDay = 0), the rule is NOT active (0 < 420).
    /// hours until ASP: 420 / 60 = 7h exactly.
    ///
    /// Also test that isScheduleActive returns false at midnight for this rule.
    func testBC5_MidnightET_ASPNotActiveYet() {
        // Monday 2026-05-11 at 00:00 ET (midnight)
        let now = etDate(year: 2026, month: 5, day: 11, hour: 0, minute: 0)

        let aspRule = rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [aspRule]
        )

        // Should NOT be active at midnight
        let dayOfWeek = now.dayOfWeekET
        XCTAssertEqual(dayOfWeek, 1, "May 11 2026 should be Monday (1)")
        XCTAssertFalse(
            engine.isScheduleActive(rule: aspRule, dayOfWeek: dayOfWeek, minuteOfDay: 0),
            "Rule should NOT be active at midnight (minuteOfDay=0 < timeRange.start=420)"
        )

        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertFalse(result.isActiveNow, "Should not be active at midnight")

        // Hours until 7am on this Monday: 7.0 hours exactly
        XCTAssertEqual(result.hours, 7.0, accuracy: 0.01, "Should be 7h from midnight to 7am")

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .free)
        XCTAssertTrue(label.text.contains("Today"), "Midnight Mon → ASP at 7am same day → 'Today'")
        XCTAssertTrue(label.text.contains("7:00 AM"), "Should show 7:00 AM")
    }

    /// At 7:00am exactly on Monday, the ASP rule IS active.
    func testBC5_MidnightAdjacent_ASPActiveAtSevenAm() {
        // Monday 2026-05-11 at 07:00 ET
        let now = etDate(year: 2026, month: 5, day: 11, hour: 7, minute: 0)
        let aspRule = rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [aspRule]
        )

        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertTrue(result.isActiveNow, "Should be active at 7:00am (start of ASP window)")

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .restricted)
        XCTAssertTrue(label.text.contains("No parking"), "Should say 'No parking'")
    }
}

// MARK: - Group 2: Happy-path parity cases

final class HappyPathParityTests: XCTestCase {

    var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: HP-1: NO_STANDING anytime block

    /// Segment: SOUTH STREET (tile_0_3.json — NO_STANDING, anytime=true)
    /// At any time: "No standing", severity: restricted.
    /// PWA: actionableSafetyLabel → restriction.hours==0, cat==NO_STANDING → "No standing"
    func testHP1_NoStandingAnytime() {
        let seg = makeSegment(
            id: "SOUTH_STREET_WHITEHALL_STREET_OLD_SLIP_E_9",
            dominantCategory: .noStanding,
            rules: [rule(category: .noStanding, days: [0,1,2,3,4,5,6], timeRanges: [], anytime: true)]
        )
        // At any time, result should be "No standing"
        let now = etDate(year: 2026, month: 5, day: 10, hour: 10, minute: 0)
        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.text, "No standing")
        XCTAssertEqual(label.severity, .restricted)
    }

    // MARK: HP-2: TRUCK_LOADING active on weekday

    /// Segment from tile_6_7: LAFAYETTE ST, cat=TRUCK_LOADING, days=[1,2,3,4,5], 7am–7pm (420–1140)
    /// On Monday 10am (minute 600): active → "No parking (truck loading)"
    /// PWA: restriction.hours==0, cat==TRUCK_LOADING → "No parking (truck loading)"
    func testHP2_TruckLoadingActive() {
        let seg = makeSegment(
            id: "LAFAYETTE_STREET_DUANE_STREET_READE_STREET_W_0",
            dominantCategory: .truckLoading,
            rules: [rule(category: .truckLoading, days: [1,2,3,4,5], timeRanges: [(420, 1140)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 10, minute: 0) // Monday 10am
        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.text, "No parking (truck loading)")
        XCTAssertEqual(label.severity, .restricted)
    }

    // MARK: HP-3: TRUCK_LOADING inactive on weekend

    /// Same rule, but Saturday: not in days [1,2,3,4,5] → free
    /// PWA: isScheduleActiveAt returns false; computeHoursUntilActive → Monday 7am
    func testHP3_TruckLoadingNotActiveWeekend() {
        let seg = makeSegment(
            dominantCategory: .truckLoading,
            rules: [rule(category: .truckLoading, days: [1,2,3,4,5], timeRanges: [(420, 1140)])]
        )
        let now = etDate(year: 2026, month: 5, day: 9, hour: 10, minute: 0) // Saturday 10am
        let label = engine.safetyLabel(for: seg, at: now)
        // Should be "Free until Monday 7:00 AM" — the rule isn't active Sat but applies Mon
        XCTAssertEqual(label.severity, .free)
        XCTAssertTrue(label.text.hasPrefix("Free until"), "Got: \(label.text)")
        XCTAssertTrue(label.text.contains("Monday"), "Got: \(label.text)")
    }

    // MARK: HP-4: ASP_MON_THU currently free (not active, far from next restriction)

    /// Segment: LAFAYETTE ST (tile_7_8), ASP_MON_THU days=[1,4] 2am–6am (120–360)
    /// On Friday afternoon: ASP not active; next Mon at 2am is ~= Fri+3d+2h = ~74h → free comfortably
    func testHP4_ASPMonThu_CurrentlyFree() {
        let seg = makeSegment(
            id: "LAFAYETTE_STREET_CANAL_STREET_WALKER_STREET_W_1",
            dominantCategory: .aspMonThu,
            rules: [
                rule(category: .aspMonThu, days: [1, 4], timeRanges: [(120, 360)]),
                rule(category: .aspMonThu, days: [1, 4], timeRanges: [(120, 360)]),
            ]
        )
        // Friday 2026-05-08 at 14:00 ET
        let now = etDate(year: 2026, month: 5, day: 8, hour: 14, minute: 0)
        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertFalse(result.isActiveNow)
        // Next Mon is May 11 at 2am: 10h to midnight Fri + 48h Sat/Sun + 2h = 60h
        XCTAssertGreaterThan(result.hours, 59.0)
        XCTAssertLessThan(result.hours, 61.0)

        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeComfortably, "74h from next ASP → should be freeComfortably")

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .free)
        XCTAssertTrue(label.text.hasPrefix("Free until"))
        XCTAssertTrue(label.text.contains("Monday"), "Got: \(label.text)")
    }

    // MARK: HP-5: ASP_MON_THU active now

    /// Same rule, queried Monday at 3am (minute 180): 2am–6am window is open.
    func testHP5_ASPMonThu_ActiveNow() {
        let seg = makeSegment(
            id: "LAFAYETTE_STREET_CANAL_STREET_WALKER_STREET_W_1",
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(120, 360)])]
        )
        // Monday 2026-05-11 at 03:00am ET (minute 180)
        let now = etDate(year: 2026, month: 5, day: 11, hour: 3, minute: 0)
        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertTrue(result.isActiveNow, "ASP should be active Mon 3am (within 2am–6am)")
        XCTAssertEqual(result.category, .aspMonThu)

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .restricted)
        XCTAssertTrue(label.text.contains("No parking"))
    }

    // MARK: HP-6: METERED active during paid hours

    /// Segment from tile_7_8: METERED days=[1-6] 9am–7pm (540–1140)
    /// Monday 10am: metered active.
    func testHP6_MeteredActive() {
        let seg = makeSegment(
            id: "LAFAYETTE_STREET_WALKER_STREET_WHITE_STREET_W_2",
            dominantCategory: .metered,
            rules: [rule(category: .metered, days: [1,2,3,4,5,6], timeRanges: [(540, 1140)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 10, minute: 0) // Monday 10am
        let status = engine.meteredStatus(for: seg, at: now)
        XCTAssertEqual(status, "Metered (paid until 7pm)")

        let label = engine.safetyLabel(for: seg, at: now)
        // JS: lbl.replace(/^Metered \(|\)$/g, '') → "paid until 7pm"
        XCTAssertEqual(label.text, "paid until 7pm")
        XCTAssertEqual(label.severity, .metered)

        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .meteredActive)
    }

    // MARK: HP-7: METERED free now (off-peak)

    /// Same metered rule, but at 8am (before 9am): free
    func testHP7_MeteredFreeNow() {
        let seg = makeSegment(
            dominantCategory: .metered,
            rules: [rule(category: .metered, days: [1,2,3,4,5,6], timeRanges: [(540, 1140)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 8, minute: 0) // Monday 8am
        let status = engine.meteredStatus(for: seg, at: now)
        // Next meter activation is 9am, 60 minutes from now → "free until 9am"
        XCTAssertEqual(status, "Metered (free until 9am)")

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.text, "free until 9am")
        XCTAssertEqual(label.severity, .free)
    }

    // MARK: HP-8: NO_PARKING anytime

    /// Segment: NO_PARKING anytime (tile_7_8 W_3 example)
    func testHP8_NoParkingAnytime() {
        let seg = makeSegment(
            dominantCategory: .noParking,
            rules: [rule(category: .noParking, days: [0,1,2,3,4,5,6], timeRanges: [], anytime: true)]
        )
        let now = etDate(year: 2026, month: 5, day: 10, hour: 15, minute: 0)
        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertTrue(result.isActiveNow)

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.text, "No parking")
        XCTAssertEqual(label.severity, .restricted)
    }

    // MARK: HP-9: ASP_DAILY active — from tile_8_9

    /// Segment: ASP_DAILY days=[1-6] timeRanges=[(420,450)] (7:00–7:30am)
    /// Monday 7:15am: active now.
    func testHP9_ASPDailyActive() {
        let seg = makeSegment(
            id: "CENTRE_STREET_HESTER_STREET_GRAND_STREET_E_0",
            dominantCategory: .aspDaily,
            rules: [rule(category: .aspDaily, days: [1,2,3,4,5,6], timeRanges: [(420, 450)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 7, minute: 15) // Mon 7:15am
        let result = engine.nextRestriction(for: seg, at: now)
        XCTAssertTrue(result.isActiveNow)

        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .restricted)
        XCTAssertTrue(label.text.contains("No parking"))
    }

    // MARK: HP-10: "Tomorrow" label when restriction is next day

    /// ASP_MON_THU at Sunday 11pm (23:00): next Mon 7:00am is Tomorrow.
    func testHP10_TomorrowLabel() {
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        // Sunday 2026-05-10 at 23:00 ET
        let now = etDate(year: 2026, month: 5, day: 10, hour: 23, minute: 0)
        let label = engine.safetyLabel(for: seg, at: now)

        XCTAssertEqual(label.severity, .free)
        // 8h to Monday 7am → "Tomorrow 7:00 AM"
        XCTAssertTrue(label.text.contains("Tomorrow"), "Got: \(label.text)")
        XCTAssertTrue(label.text.contains("7:00 AM"), "Got: \(label.text)")
    }

    // MARK: HP-11: ASP suspended — skip to next unsuspended day

    /// ASP_TUE_FRI queried on Mon May 18 2026 at noon.
    ///
    /// The 14-day walker visits days in calendar order:
    ///   May 18 Mon  — not a Tue/Fri ASP day, skip.
    ///   May 19 Tue  — IS a Tue/Fri ASP day. Not in asp-2026.json (not suspended). STOP here.
    ///
    /// The engine finds Tue May 19 FIRST — it does NOT need to skip to May 22 (Fri/Shavuoth)
    /// because May 19 is a valid non-suspended Tuesday. The old comment was wrong: it assumed
    /// the walker would jump over May 19 to May 22, but May 19 is neither suspended nor skipped.
    ///
    /// Hours from Mon May 18 noon to Tue May 19 7:30am (450 min = 7h30m):
    ///   12h remaining May 18 + 7.5h to 7:30am May 19 = 19.5h
    ///
    /// As a secondary check: May 22 (Fri/Shavuoth) and May 25 (Memorial Day) ARE suspended.
    func testHP11_ASPSuspendedSkipToNext() {
        let seg = makeSegment(
            id: "BAXTER_STREET_GRAND_STREET_HESTER_STREET_E_0",
            dominantCategory: .aspTueFri,
            rules: [rule(category: .aspTueFri, days: [2, 5], timeRanges: [(450, 480)])]
        )
        // Monday 2026-05-18 at noon
        let now = etDate(year: 2026, month: 5, day: 18, hour: 12, minute: 0)
        let result = engine.nextRestriction(for: seg, at: now)

        XCTAssertFalse(result.isActiveNow)

        // Engine finds Tue May 19 7:30am as the next ASP window (~19.5h away).
        // Tight bound: must be > 19h and < 20h to confirm the walker stopped at May 19
        // and did not erroneously skip a valid Tuesday.
        XCTAssertGreaterThan(result.hours, 19.0, "Should find Tue May 19 7:30am (~19.5h from Mon May 18 noon)")
        XCTAssertLessThan(result.hours, 20.0, "Got: \(result.hours)h — expected ~19.5h to May 19 7:30am")

        // Confirm suspension service correctly identifies the suspended dates in this window.
        let aspSvc = ASPSuspensionService()
        let may22 = etDate(year: 2026, month: 5, day: 22) // Fri, Shavuoth — suspended
        XCTAssertTrue(aspSvc.isSuspended(may22), "May 22 (Shavuoth) should be suspended")
        let may25 = etDate(year: 2026, month: 5, day: 25) // Mon, Memorial Day — suspended
        XCTAssertTrue(aspSvc.isSuspended(may25), "May 25 (Memorial Day) should be suspended")
    }

    // MARK: HP-12: Bare FREE-category segment

    /// A segment whose only rule has category == .free and anytime == true should return
    /// SafetyLabel(text: "Free", severity: .free). This exercises the final fallthrough
    /// in safetyLabel(for:at:). Required explicitly by spec AC-3 (§6).
    ///
    /// The engine's safetyLabel path for a FREE-category segment:
    ///   - nextRestriction returns hours == 168 (sentinel — no move-your-car restriction)
    ///   - restriction.isActiveNow == false
    ///   - restriction.hours >= 168 → "Free until" branch not taken
    ///   - dominantCategory == .free → not .metered
    ///   - Falls through to the final return SafetyLabel(text: "Free", severity: .free)
    func testHP12_BareFreeBlock() {
        let seg = makeSegment(
            dominantCategory: .free,
            rules: [rule(category: .free, days: [], timeRanges: [], anytime: true)]
        )
        let anyTime = etDate(year: 2026, month: 5, day: 10, hour: 14, minute: 0)
        let label = engine.safetyLabel(for: seg, at: anyTime)
        XCTAssertEqual(label.text, "Free", "FREE-category segment should return 'Free'")
        XCTAssertEqual(label.severity, .free, "FREE-category segment should have .free severity")
    }
}

// MARK: - Group 3: Option B currentState classification

final class CurrentStateClassificationTests: XCTestCase {

    var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    func testCurrentState_NoRules_Unknown() {
        let seg = makeSegment(rules: [])
        let state = engine.currentState(for: seg, at: etDate(year: 2026, month: 5, day: 10, hour: 10))
        XCTAssertEqual(state, .unknown)
        XCTAssertEqual(engine.currentStateColor(for: seg, at: etDate(year: 2026, month: 5, day: 10, hour: 10)), ParkingColors.unknown)
    }

    func testCurrentState_NoStandingAnytime_RestrictedNow() {
        let seg = makeSegment(rules: [rule(category: .noStanding, days: [0,1,2,3,4,5,6], timeRanges: [], anytime: true)])
        let state = engine.currentState(for: seg, at: etDate(year: 2026, month: 5, day: 10, hour: 10))
        XCTAssertEqual(state, .restrictedNow)
        XCTAssertEqual(engine.currentStateColor(for: seg, at: etDate(year: 2026, month: 5, day: 10, hour: 10)), ParkingColors.restricted)
    }

    // W4.5: threshold lowered from 24h to 6h. A restriction 8h away (Sunday 11pm → Mon 7am)
    // was previously orange (within 24h). It is now green (beyond 6h). Test name updated
    // from "Within24h_RestrictionComingSoon" to "8hAway_FreeComfortably" to reflect the new
    // semantic: 8h > 6h threshold → freeComfortably.
    func testCurrentState_ASP8hAway_FreeComfortably() {
        // ASP_MON_THU: at Sunday 11pm, next Mon 7am is ~8h → green (beyond 6h threshold)
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let now = etDate(year: 2026, month: 5, day: 10, hour: 23, minute: 0) // Sunday 11pm
        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeComfortably,
            "8h to next ASP > 6h threshold → should be freeComfortably (W4.5: was freeButRestrictionSoon under 24h)")
        XCTAssertEqual(engine.currentStateColor(for: seg, at: now), ParkingColors.freeComfortably)
    }

    func testCurrentState_ASPBeyond24h_FreeComfortably() {
        // ASP_MON_THU: Friday noon → next Mon 7am is ~67h → green (well beyond 6h threshold)
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let now = etDate(year: 2026, month: 5, day: 8, hour: 12, minute: 0) // Friday noon
        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeComfortably)
        XCTAssertEqual(engine.currentStateColor(for: seg, at: now), ParkingColors.freeComfortably)
    }

    // MARK: W4.5 boundary tests — 6h threshold explicit coverage

    /// Lower boundary: restriction ~5.5h away → still orange (within 6h threshold).
    ///
    /// ASP_MON_THU with ASP at Mon 7am. Query at Mon 1:30am (01:30 ET).
    /// Hours to 7am = 5.5h → < 6h → freeButRestrictionSoon (orange).
    func testCurrentState_ASP5_5hAway_RestrictionComingSoon() {
        // Monday 2026-05-11 at 01:30 ET — 5.5h before Mon 7am ASP
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 1, minute: 30)
        let result = engine.nextRestriction(for: seg, at: now)
        // Verify the hours computation is indeed ~5.5h
        XCTAssertGreaterThan(result.hours, 5.4, "Should be ~5.5h to Mon 7am")
        XCTAssertLessThan(result.hours, 5.6, "Should be ~5.5h to Mon 7am")

        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeButRestrictionSoon,
            "5.5h to next ASP < 6h threshold → should be freeButRestrictionSoon (orange)")
        XCTAssertEqual(engine.currentStateColor(for: seg, at: now), ParkingColors.restrictionComingSoon)
    }

    /// Upper boundary: restriction ~6.5h away → green (just beyond 6h threshold).
    ///
    /// ASP_MON_THU with ASP at Mon 7am. Query at Mon 0:30am (00:30 ET).
    /// Hours to 7am = 6.5h → > 6h → freeComfortably (green).
    func testCurrentState_ASP6_5hAway_FreeComfortably() {
        // Monday 2026-05-11 at 00:30 ET — 6.5h before Mon 7am ASP
        let seg = makeSegment(
            dominantCategory: .aspMonThu,
            rules: [rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 0, minute: 30)
        let result = engine.nextRestriction(for: seg, at: now)
        // Verify the hours computation is indeed ~6.5h
        XCTAssertGreaterThan(result.hours, 6.4, "Should be ~6.5h to Mon 7am")
        XCTAssertLessThan(result.hours, 6.6, "Should be ~6.5h to Mon 7am")

        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeComfortably,
            "6.5h to next ASP > 6h threshold → should be freeComfortably (green)")
        XCTAssertEqual(engine.currentStateColor(for: seg, at: now), ParkingColors.freeComfortably)
    }

    func testCurrentState_MeteredDuringPaidHours_MeteredActive() {
        let seg = makeSegment(
            dominantCategory: .metered,
            rules: [rule(category: .metered, days: [1,2,3,4,5,6], timeRanges: [(540, 1140)])]
        )
        let now = etDate(year: 2026, month: 5, day: 11, hour: 10, minute: 0) // Mon 10am
        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .meteredActive)
        XCTAssertEqual(engine.currentStateColor(for: seg, at: now), ParkingColors.meteredActive)
    }

    func testCurrentState_MeteredDuringFreeHours_FreeComfortably() {
        let seg = makeSegment(
            dominantCategory: .metered,
            rules: [rule(category: .metered, days: [1,2,3,4,5,6], timeRanges: [(540, 1140)])]
        )
        // Sunday (day 0) — metered rule doesn't apply (days = [1-6])
        let now = etDate(year: 2026, month: 5, day: 10, hour: 14, minute: 0) // Sunday 2pm
        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .freeComfortably)
    }
}

// MARK: - Group 4: StreetNameNormalizer parity

final class StreetNameNormalizerTests: XCTestCase {

    func testOrdinalStrip() {
        XCTAssertEqual(StreetNameNormalizer.canonical("1ST AVENUE"), "1 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("2ND STREET"), "2 ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("3RD STREET"), "3 ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("4TH AVENUE"), "4 AVE")
    }

    func testSuffixNormalization() {
        XCTAssertEqual(StreetNameNormalizer.canonical("CHRYSTIE STREET"), "CHRYSTIE ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("BROADWAY"), "BROADWAY")  // no suffix
        XCTAssertEqual(StreetNameNormalizer.canonical("PARK AVENUE"), "PARK AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("FLATBUSH AVENUE"), "FLATBUSH AVE")
    }

    func testSpelledOutOrdinals() {
        XCTAssertEqual(StreetNameNormalizer.canonical("FIFTH AVENUE"), "5 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("THIRD AVENUE"), "3 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("FIRST STREET"), "1 ST")
    }

    func testAvenueOfAmericasAlias() {
        XCTAssertEqual(StreetNameNormalizer.canonical("AVE OF THE AMERICAS"), "6 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("AVE OF AMERICAS"), "6 AVE")
        // After suffix normalization, "AVENUE OF THE AMERICAS" → "AVE OF THE AMERICAS" → "6 AVE"
        XCTAssertEqual(StreetNameNormalizer.canonical("AVENUE OF THE AMERICAS"), "6 AVE")
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(StreetNameNormalizer.canonical(""), "")
        XCTAssertEqual(StreetNameNormalizer.canonical("  BROADWAY  "), "BROADWAY")
        XCTAssertEqual(StreetNameNormalizer.canonical("BOWERY  STREET"), "BOWERY ST")
    }

    func testMixedCase() {
        XCTAssertEqual(StreetNameNormalizer.canonical("bowery street"), "BOWERY ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("Chrystie Street"), "CHRYSTIE ST")
    }
}

// MARK: - Group 5: ASPSuspensionService correctness

final class ASPSuspensionServiceTests: XCTestCase {

    var service: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        service = ASPSuspensionService()
    }

    func testKnownSuspendedDates() {
        // All these dates are in asp-2026.json
        let knownDates: [(month: Int, day: Int, reason: String)] = [
            (1, 1, "New Year's Day"),
            (5, 25, "Memorial Day"),
            (11, 26, "Thanksgiving Day"),
            (12, 25, "Christmas Day"),
        ]
        for (month, day, reason) in knownDates {
            let date = makeDate(month: month, day: day)
            XCTAssertTrue(service.isSuspended(date), "\(month)/\(day) should be suspended")
            XCTAssertEqual(service.reasonForSuspension(date), reason, "Reason mismatch for \(month)/\(day)")
        }
    }

    func testNonSuspendedDates() {
        let nonsuspended: [(month: Int, day: Int)] = [
            (1, 2), (5, 10), (6, 1), (7, 1), (12, 24),
        ]
        for (month, day) in nonsuspended {
            let date = makeDate(month: month, day: day)
            XCTAssertFalse(service.isSuspended(date), "\(month)/\(day) should NOT be suspended")
            XCTAssertNil(service.reasonForSuspension(date))
        }
    }

    func testSuspensionBannerState_TodaySuspended() {
        // Pretend today is Memorial Day
        let today = makeDate(month: 5, day: 25)
        let state = service.suspensionState(at: today)
        if case .todaySuspended(let reason) = state {
            XCTAssertEqual(reason, "Memorial Day")
        } else {
            XCTFail("Expected todaySuspended, got \(state)")
        }
    }

    func testSuspensionBannerState_TomorrowSuspended() {
        // Day before Thanksgiving is Nov 25 (not suspended); Nov 26 is (Thanksgiving).
        let dayBefore = makeDate(month: 11, day: 25)
        let state = service.suspensionState(at: dayBefore)
        if case .tomorrowSuspended(let reason) = state {
            XCTAssertEqual(reason, "Thanksgiving Day")
        } else {
            XCTFail("Expected tomorrowSuspended, got \(state)")
        }
    }

    func testSuspensionBannerState_ASPInEffect() {
        // Random day not near a suspension
        let randomDay = makeDate(month: 6, day: 1)
        let state = service.suspensionState(at: randomDay)
        XCTAssertEqual(state, .aspInEffect)
    }

    private func makeDate(month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = month
        comps.day = day
        comps.hour = 10
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }
}

// MARK: - Group 6: nextRestrictionTimeLabel format parity

// MARK: - FT-9 Regression Tests: Metered-active pre-empts upcoming-ASP-free

/// Regression tests for the FT-9 branch-ordering fix.
///
/// Before the fix, `safetyLabel(for:at:)` evaluated "upcoming ASP → Free until X" before the
/// metered paid-hours check. Any segment with BOTH a METERED rule active now AND an upcoming
/// ASP restriction (the dominant config on NYC metered commercial streets, e.g. 2nd Avenue W-side)
/// returned `.free` / "Free until Tomorrow 8:30 AM" during the entire paid metered window.
///
/// After the fix, a metered-active segment correctly returns `.metered` / "paid until <end>".
/// The free-hours case (meter not running, ASP upcoming) must NOT regress.
///
/// Reference segment from investigation doc:
///   2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3
///   Rules: ASP_DAILY 8:30-9:00 AM (510-540, days 1-6), METERED 9AM-10PM (540-1320, days 1-6)

final class FT9MeteredLabelFixTests: XCTestCase {

    var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    /// The ASP_DAILY + METERED segment from 2nd Avenue. At 1:00 PM on a Wednesday (day=3,
    /// minute=780), the METERED rule is active (540–1320). The engine must return .metered
    /// severity and "paid until 10pm", NOT .free / "Free until Tomorrow 8:30 AM".
    ///
    /// This is the exact scenario described in docs/qa/ft9-bowery-2ndave-investigation.md §4.2.
    func testFT9_MeteredActiveDuringPaidHours_NotFree() {
        // Reproduce the 2nd Ave W-side segment: ASP_DAILY 8:30-9am + METERED 9am-10pm
        let seg = makeSegment(
            id: "2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3",
            street: "2ND AVENUE",
            dominantCategory: .metered,
            rules: [
                rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(510, 540)]),
                rule(category: .metered,  days: [1, 2, 3, 4, 5, 6], timeRanges: [(540, 1320)]),
            ]
        )

        // Wednesday 2026-06-03 at 1:00 PM ET (day=3, minute=780)
        let now = etDate(year: 2026, month: 6, day: 3, hour: 13, minute: 0)

        let label = engine.safetyLabel(for: seg, at: now)

        // Must NOT return .free or "Free until …" (the bug)
        XCTAssertNotEqual(label.severity, .free,
            "METERED active at 1pm must NOT return .free severity — got \(label.severity)")
        XCTAssertFalse(label.text.hasPrefix("Free until"),
            "METERED active at 1pm must NOT return 'Free until …' — got: \(label.text)")

        // Must return .metered with the "paid until 10pm" label
        XCTAssertEqual(label.severity, .metered,
            "METERED active at 1pm must return .metered severity — got \(label.severity)")
        XCTAssertEqual(label.text, "paid until 10pm",
            "METERED active at 1pm must return 'paid until 10pm' — got: \(label.text)")

        // Confirm currentState is still correct and UNCHANGED by the fix
        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .meteredActive,
            "currentState must be .meteredActive at 1pm — got \(state)")
    }

    /// Boundary: at exactly 9:00 AM (minute=540), the METERED window starts (540 is inclusive).
    /// Must return .metered, NOT .free.
    func testFT9_MeteredActiveBoundary_9am() {
        let seg = makeSegment(
            id: "2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3",
            street: "2ND AVENUE",
            dominantCategory: .metered,
            rules: [
                rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(510, 540)]),
                rule(category: .metered,  days: [1, 2, 3, 4, 5, 6], timeRanges: [(540, 1320)]),
            ]
        )

        // Wednesday 2026-06-03 at 9:00 AM ET exactly (minute=540)
        let now = etDate(year: 2026, month: 6, day: 3, hour: 9, minute: 0)

        let label = engine.safetyLabel(for: seg, at: now)

        XCTAssertEqual(label.severity, .metered,
            "At 9:00 AM (metered window start) must return .metered — got \(label.severity)")
        XCTAssertFalse(label.text.hasPrefix("Free until"),
            "At 9:00 AM must NOT return 'Free until …' — got: \(label.text)")

        let state = engine.currentState(for: seg, at: now)
        XCTAssertEqual(state, .meteredActive, "currentState must be .meteredActive at 9:00 AM")
    }

    /// Non-regression: a metered-INACTIVE segment with an upcoming ASP must still return the
    /// "Free until <ASP time>" label. The fix must not break the off-peak metered + ASP case.
    ///
    /// Same segment at 8:00 AM (before 9AM metered start, after the ASP window 8:30-9AM but
    /// queried before it). At 8:00 AM, metered is NOT active (540 > 480). ASP_DAILY 8:30-9AM
    /// is upcoming in 30 min → should show "Free until Today 8:30 AM" / .free.
    func testFT9_MeteredInactive_UpcomingASP_StillShowsFreeUntil() {
        let seg = makeSegment(
            id: "2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3",
            street: "2ND AVENUE",
            dominantCategory: .metered,
            rules: [
                rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(510, 540)]),
                rule(category: .metered,  days: [1, 2, 3, 4, 5, 6], timeRanges: [(540, 1320)]),
            ]
        )

        // Wednesday 2026-06-03 at 8:00 AM ET (minute=480)
        // Metered starts at 540 (9am) → not active yet.
        // ASP_DAILY is at 510-540 (8:30-9am), which is 30 minutes away.
        let now = etDate(year: 2026, month: 6, day: 3, hour: 8, minute: 0)

        let label = engine.safetyLabel(for: seg, at: now)

        // Metered is free right now, ASP is upcoming — must return .free / "Free until …"
        XCTAssertEqual(label.severity, .free,
            "At 8:00 AM (metered inactive) must return .free severity — got \(label.severity)")
        XCTAssertTrue(label.text.hasPrefix("Free until") || label.text == "free until 8:30am",
            "At 8:00 AM must return a 'Free until …' style label — got: \(label.text)")

        // currentState should NOT be .meteredActive (meter is off)
        let state = engine.currentState(for: seg, at: now)
        XCTAssertNotEqual(state, .meteredActive,
            "currentState must NOT be .meteredActive at 8:00 AM (before metered start)")
    }

    /// Confirm that a purely ASP-only segment (no METERED rules) still works correctly
    /// after the fix. The new metered-check block must be a no-op for pure-ASP segments.
    func testFT9_PureASPSegment_Unaffected() {
        let seg = makeSegment(
            dominantCategory: .aspDaily,
            rules: [
                rule(category: .aspDaily, days: [1, 2, 3, 4, 5, 6], timeRanges: [(510, 540)]),
            ]
        )

        // Wednesday 2026-06-03 at 1:00 PM — ASP not active, upcoming tomorrow
        let now = etDate(year: 2026, month: 6, day: 3, hour: 13, minute: 0)

        let label = engine.safetyLabel(for: seg, at: now)

        // Pure ASP with no METERED must still return "Free until <next ASP>" / .free
        XCTAssertEqual(label.severity, .free,
            "Pure ASP segment at 1pm must return .free — got \(label.severity)")
        XCTAssertTrue(label.text.hasPrefix("Free until"),
            "Pure ASP segment at 1pm must return 'Free until …' — got: \(label.text)")
    }
}



final class TimeLabelFormatTests: XCTestCase {

    var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    /// "No upcoming restrictions" for hours >= 168.
    func testNoUpcomingRestrictions() {
        let now = etDate(year: 2026, month: 5, day: 10, hour: 10)
        let label = engine.nextRestrictionTimeLabel(hours: 168, now: now)
        XCTAssertEqual(label, "No upcoming restrictions")
    }

    /// "Today" when the restriction is less than one day away on the same calendar day.
    func testTodayLabel() {
        // Now: Sunday May 10 10am. Restriction in 4h = Sunday May 10 2pm.
        let now = etDate(year: 2026, month: 5, day: 10, hour: 10)
        let label = engine.nextRestrictionTimeLabel(hours: 4, now: now)
        XCTAssertTrue(label.hasPrefix("Today"), "Got: \(label)")
        XCTAssertTrue(label.contains("2:00 PM"), "Got: \(label)")
    }

    /// "Tomorrow" when the restriction is the next calendar day.
    func testTomorrowLabel() {
        // Now: Sunday May 10 11pm. Restriction in 8h = Monday May 11 7am.
        let now = etDate(year: 2026, month: 5, day: 10, hour: 23)
        let label = engine.nextRestrictionTimeLabel(hours: 8, now: now)
        XCTAssertEqual(label, "Tomorrow 7:00 AM")
    }

    /// "Monday 7:00 AM" style for multi-day future (not today/tomorrow).
    func testWeekdayLabel() {
        // Now: Friday May 8 noon. Restriction in 67h = Monday May 11 7am.
        let now = etDate(year: 2026, month: 5, day: 8, hour: 12)
        let label = engine.nextRestrictionTimeLabel(hours: 67, now: now)
        XCTAssertTrue(label.contains("Monday"), "Got: \(label)")
        XCTAssertTrue(label.contains("7:00 AM"), "Got: \(label)")
    }

    /// Time with non-zero minutes: "9:30 AM"
    func testTimeWithMinutes() {
        // Now: Monday 7am. Restriction in 2.5h = Monday 9:30am.
        let now = etDate(year: 2026, month: 5, day: 11, hour: 7)
        let label = engine.nextRestrictionTimeLabel(hours: 2.5, now: now)
        XCTAssertTrue(label.contains("Today"), "Got: \(label)")
        XCTAssertTrue(label.contains("9:30 AM"), "Got: \(label)")
    }

    private func etDate(year: Int, month: Int, day: Int, hour: Int = 10) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }
}

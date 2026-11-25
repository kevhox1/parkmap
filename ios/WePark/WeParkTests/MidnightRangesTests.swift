//
//  MidnightRangesTests.swift
//  WeParkTests
//
//  Regression coverage for the midnight bug: the tile pipeline stores "9AM-MIDNIGHT" as
//  {start: 540, end: 0}, and the engine's metered paths read end 0 as "never active", so a
//  running meter showed GREEN "free until 9am" at 10:42 PM (QA PR #188 finding 1).
//
//  Table-driven over REAL tile rules (picked from the bundled tiles): for each fixture rule,
//  for every day of a Sunday-anchored week, at minutes just before / at / during / after the
//  window edges, the engine's schedule check, current state, safety label, metered label,
//  `isFree` (no-goal state) and all three goals are compared against an independent
//  absolute-minute oracle. Every call site that compares minutes-of-day is exercised so the
//  map, chips, labels and My Car hero cannot disagree.
//
//  Helpers are private to this class (no cross-file XCTestCase extension).
//

import XCTest
@testable import WePark

final class MidnightRangesTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: - Calendar helpers

    /// Sunday 2026-12-06 00:00 ET. No DST transition in the following 3 months, so one
    /// minute index == one minute of wall-clock time and `(idx / 1440) % 7` is the weekday.
    private func baseSunday() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 12; comps.day = 6
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    private func date(atMinuteIndex idx: Int) -> Date {
        baseSunday().addingTimeInterval(Double(idx) * 60)
    }

    private func minuteIndex(of date: Date) -> Int {
        Int((date.timeIntervalSince(baseSunday()) / 60).rounded())
    }

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    // MARK: - Fixtures from the real tiles

    private struct SampleTileIndex: Decodable {
        struct Entry: Decodable { let row: Int; let col: Int }
        let tiles: [Entry]
    }

    private struct Fixture {
        let name: String
        let segment: Segment      // real segment identity, ONE real rule
        let rule: ParkingRule
    }

    private enum Shape: String { case endsAtMidnight, startsAtMidnight, wrapsPastMidnight }

    private static var cachedSegments: [Segment]?

    private func allTileSegments() throws -> [Segment] {
        if let cached = Self.cachedSegments { return cached }
        let indexURL = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "json"))
        let index = try JSONDecoder().decode(SampleTileIndex.self, from: Data(contentsOf: indexURL))
        var segments: [Segment] = []
        for tile in index.tiles {
            guard let url = Bundle.main.url(forResource: "tile_\(tile.row)_\(tile.col)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Segment].self, from: data) else { continue }
            segments.append(contentsOf: decoded)
        }
        segments.sort { $0.id < $1.id }
        Self.cachedSegments = segments
        return segments
    }

    private func single(_ segment: Segment, rule: ParkingRule) throws -> Segment {
        let ruleData = try JSONEncoder().encode(rule)
        let ruleObject = try JSONSerialization.jsonObject(with: ruleData)
        let object: [String: Any] = [
            "id": segment.id,
            "street": segment.street,
            "from": segment.fromStreet,
            "to": segment.to,
            "side": segment.side,
            "line": segment.line,
            "rules": [ruleObject],
            "dominantCategory": rule.category.rawValue,
        ]
        let out = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Segment.self, from: out)
    }

    private func matches(_ tr: TimeRange, _ shape: Shape) -> Bool {
        switch shape {
        case .endsAtMidnight: return tr.end == 0 && tr.start > 0
        case .startsAtMidnight: return tr.start == 0 && tr.end > 0
        case .wrapsPastMidnight: return tr.end > 0 && tr.start >= tr.end
        }
    }

    /// First real rule (sorted by segment id) of a category and shape with explicit days.
    private func fixture(_ category: WePark.Category, _ shape: Shape) throws -> Fixture {
        for seg in try allTileSegments() {
            for rule in seg.rules where rule.category == category && !rule.anytime
                && (!rule.days.isEmpty || category == .metered)
                && rule.timeRanges.count == 1
                && matches(rule.timeRanges[0], shape) {
                return Fixture(name: "\(category.rawValue)/\(shape.rawValue)/\(seg.id)",
                               segment: try single(seg, rule: rule), rule: rule)
            }
        }
        throw XCTSkip("no real tile rule for \(category.rawValue) \(shape.rawValue)")
    }

    private func fixtureTable() throws -> [Fixture] {
        var table: [Fixture] = []
        for category in [WePark.Category.metered, .noParking, .noStanding, .special, .truckLoading] {
            table.append(try fixture(category, .endsAtMidnight))
        }
        for category in [WePark.Category.noStanding, .truckLoading] {
            table.append(try fixture(category, .startsAtMidnight))
        }
        for category in [WePark.Category.noStanding, .noParking] {
            table.append(try fixture(category, .wrapsPastMidnight))
        }
        return table
    }

    // MARK: - Independent oracle (absolute minutes, no engine code)

    private func oracleActive(_ rule: ParkingRule, atIndex idx: Int) -> Bool {
        let day = idx / 1440
        for tr in rule.timeRanges {
            let closes = tr.end == 0 ? 1440 : tr.end
            let length = closes > tr.start ? closes - tr.start : closes + 1440 - tr.start
            for anchor in [day - 1, day] {
                let weekday = ((anchor % 7) + 7) % 7
                let dayOK = rule.days.isEmpty ? true : rule.days.contains(weekday)
                guard dayOK else { continue }
                let opens = anchor * 1440 + tr.start
                if idx >= opens && idx < opens + length { return true }
            }
        }
        return false
    }

    private func oracleFree(_ rule: ParkingRule, fromIndex: Int, untilIndex: Int) -> Bool {
        guard untilIndex > fromIndex else { return true }
        for idx in fromIndex..<untilIndex where oracleActive(rule, atIndex: idx) { return false }
        return true
    }

    /// Minutes of day around a range's edges: just before / at / just after / middle.
    private func probeMinutes(for rule: ParkingRule) -> [Int] {
        guard let tr = rule.timeRanges.first else { return [0] }
        let close = tr.end == 0 ? 1440 : tr.end
        var set: Set<Int> = [0, 1, 1439, 1380, 720]
        for edge in [tr.start, close] {
            for delta in [-1, 0, 1] { set.insert(((edge + delta) % 1440 + 1440) % 1440) }
        }
        set.insert((tr.start + (close > tr.start ? close - tr.start : close + 1440 - tr.start) / 2) % 1440)
        return set.sorted()
    }

    // MARK: - The table

    func testRealTileRules_everyProbe_engineAgreesWithOracle_allSurfacesAndGoals() throws {
        let table = try fixtureTable()
        XCTAssertGreaterThanOrEqual(table.count, 8)

        for fx in table {
            for day in 0..<7 {
                for minute in probeMinutes(for: fx.rule) {
                    let idx = day * 1440 + minute
                    let now = date(atMinuteIndex: idx)
                    let ctx = "\(fx.name) day=\(day) minute=\(minute)"
                    let active = oracleActive(fx.rule, atIndex: idx)

                    // Schedule check (non-metered) and metered label / current state / hero.
                    if fx.rule.category == .metered {
                        let status = engine.meteredStatus(for: fx.segment, at: now)
                        XCTAssertEqual(status.contains("paid until"), active, "meteredStatus \(ctx): \(status)")
                        XCTAssertEqual(
                            engine.currentState(for: fx.segment, at: now) == .meteredActive, active,
                            "currentState \(ctx)")
                        let severity = engine.safetyLabel(for: fx.segment, at: now).severity
                        XCTAssertEqual(severity == .metered, active, "safetyLabel \(ctx)")
                        XCTAssertEqual(
                            MyCarSheetV2Logic.meterUntil(rules: fx.segment.rules, dayOfWeek: day, minuteOfDay: minute) != nil,
                            active, "My Car meter line \(ctx)")
                        XCTAssertEqual(engine.isMeteredActive(for: fx.segment, at: now), active, "isMeteredActive \(ctx)")
                    } else {
                        XCTAssertEqual(
                            engine.isScheduleActive(rule: fx.rule, dayOfWeek: day, minuteOfDay: minute), active,
                            "isScheduleActive \(ctx)")
                        XCTAssertEqual(
                            engine.currentState(for: fx.segment, at: now) == .restrictedNow, active,
                            "currentState \(ctx)")
                        XCTAssertEqual(
                            engine.safetyLabel(for: fx.segment, at: now).severity == .restricted, active,
                            "safetyLabel \(ctx)")
                    }

                    // No-goal state: a one-minute and a one-hour window.
                    XCTAssertEqual(
                        engine.isFree(segment: fx.segment, from: now, until: now.addingTimeInterval(60),
                                      ignoringMeteredPayment: false),
                        !active, "isFree(1 min) \(ctx)")
                    XCTAssertEqual(
                        engine.isFree(segment: fx.segment, from: now, until: now.addingTimeInterval(3600),
                                      ignoringMeteredPayment: false),
                        oracleFree(fx.rule, fromIndex: idx, untilIndex: idx + 60), "isFree(1 h) \(ctx)")

                    // Every goal, against the oracle over the goal's own window.
                    for goal in [ParkingGoal.freeOvernight, .freeFewHours] {
                        let end = ParkingGoals.target(for: goal, from: now)
                        let expected = oracleFree(fx.rule, fromIndex: idx, untilIndex: minuteIndex(of: end))
                        let result = ParkingGoals.match(segment: fx.segment, goal: goal, from: now, engine: engine)
                        XCTAssertEqual(result.matches, expected, "goal \(goal.rawValue) \(ctx)")
                    }
                    var expectedRung: Int?
                    for rung in ParkingGoals.parkAndForgetLadderOffsetDays {
                        let until = minuteIndex(of: now.startOfDayET(offsetDays: rung))
                        if oracleFree(fx.rule, fromIndex: idx, untilIndex: until) { expectedRung = rung; break }
                    }
                    let forget = ParkingGoals.match(segment: fx.segment, goal: .parkAndForget, from: now, engine: engine)
                    XCTAssertEqual(forget.matches, expectedRung != nil, "goal parkAndForget \(ctx)")
                    XCTAssertEqual(forget.clearedRungOffsetDays, expectedRung, "rung parkAndForget \(ctx)")
                }
            }
        }
    }

    // MARK: - The reported repro, on the real segment

    func testStMarksMetered9AMToMidnight_tuesday1042PM_heroAndLineAgree() throws {
        let seg = try XCTUnwrap(try allTileSegments().first { $0.id == "ST_MARKS_PLACE_1ST_AVENUE_AVENUE_A_N_4" })
        let now = et(2026, 11, 24, 22, 42)   // Tuesday

        XCTAssertEqual(engine.currentState(for: seg, at: now), .meteredActive)
        let label = engine.safetyLabel(for: seg, at: now)
        XCTAssertEqual(label.severity, .metered)
        XCTAssertEqual(label.text, "paid until 12am")
        XCTAssertEqual(
            MyCarSheetV2Logic.meterUntil(rules: seg.rules, dayOfWeek: now.dayOfWeekET, minuteOfDay: now.minuteOfDayET),
            "meter until midnight")
        // Never "free" across the running meter.
        XCTAssertFalse(engine.isFree(segment: seg, from: now, until: now.addingTimeInterval(1800),
                                     ignoringMeteredPayment: false))

        // 11:59 PM still paid; Wednesday 12:00 AM is free until 9 AM.
        XCTAssertEqual(engine.currentState(for: seg, at: et(2026, 11, 24, 23, 59)), .meteredActive)
        let after = et(2026, 11, 25, 0, 0)
        XCTAssertNotEqual(engine.currentState(for: seg, at: after), .meteredActive)
        XCTAssertEqual(engine.safetyLabel(for: seg, at: after).text, "free until 9am")
    }

    func testEndsAtMidnightFixture_stillRestrictedAtOneMinuteToMidnight() throws {
        let fx = try fixture(.noStanding, .endsAtMidnight)
        let day = try XCTUnwrap(fx.rule.days.first)
        let justBeforeMidnight = date(atMinuteIndex: day * 1440 + 1439)
        XCTAssertEqual(engine.currentState(for: fx.segment, at: justBeforeMidnight), .restrictedNow)
    }

    // MARK: - Display: midnight wording

    func testTimeRangeWording_midnightSpelledOut() {
        XCTAssertEqual(MyCarSheetV2Logic.timeRange(TimeRange(start: 0, end: 180)), "midnight\u{2013}3 AM")
        XCTAssertEqual(MyCarSheetV2Logic.timeRange(TimeRange(start: 540, end: 0)), "9 AM\u{2013}midnight")
        XCTAssertEqual(MyCarSheetV2Logic.timeRange(TimeRange(start: 540, end: 630)), "9\u{2013}10:30 AM")
        XCTAssertEqual(MyCarSheetV2Logic.timeRange(TimeRange(start: 480, end: 1080)), "8 AM\u{2013}6 PM")
    }

    // MARK: - Display: non-breaking meridiem only

    func testNonBreakingMeridiem_onlyBetweenTimeAndAMPM() {
        let text = ParkingGoals.nonBreakingMeridiem("Now \u{2192} 7:00 AM tomorrow")
        XCTAssertEqual(text, "Now \u{2192} 7:00\u{00A0}AM tomorrow")
        XCTAssertEqual(text.filter { $0 == " " }.count, 3)
    }

    // MARK: - Leaving soon "min left"

    func testLeavingSoonMinutesLeft_dropsServerGrace() {
        let created = et(2026, 11, 24, 22, 0)
        for chosen in [5, 10, 15, 20] {
            let expires = created.addingTimeInterval(Double(chosen + 3) * 60)
            XCTAssertEqual(
                MyCarSheetV2Logic.leavingSoonMinutesLeft(
                    expiresAt: expires, now: created.addingTimeInterval(4), leavingMinutes: chosen),
                chosen)
        }
        let expires = created.addingTimeInterval(13 * 60)
        XCTAssertEqual(MyCarSheetV2Logic.leavingSoonMinutesLeft(
            expiresAt: expires, now: created.addingTimeInterval(6 * 60), leavingMinutes: 10), 4)
        XCTAssertEqual(MyCarSheetV2Logic.leavingSoonMinutesLeft(
            expiresAt: expires, now: created.addingTimeInterval(12 * 60), leavingMinutes: 10), 0)
        XCTAssertEqual(MyCarSheetV2Logic.leavingSoonMinutesLeft(
            expiresAt: expires, now: created.addingTimeInterval(60), leavingMinutes: nil), 12)
    }

    // MARK: - "Next:" skips the suspended Thanksgiving Thursday

    func testNextLine_skipsSuspendedAspDay() throws {
        let ruleJSON = """
        {"category":"ASP_MON_THU","description":"","days":[1,4],"timeRanges":[{"start":540,"end":630}],"anytime":false,"arrow":"both"}
        """
        let rule = try JSONDecoder().decode(ParkingRule.self, from: Data(ruleJSON.utf8))
        let now = et(2026, 11, 24, 12)   // Tuesday; Thursday 11/26 (Thanksgiving) is suspended
        let sample = try XCTUnwrap(try allTileSegments().first)
        let restriction = engine.nextRestriction(for: try single(sample, rule: rule), at: now)
        XCTAssertEqual(restriction.category, .aspMonThu)
        let line = MyCarSheetV2Logic.nextMoveLine(
            restriction: restriction, rules: [rule],
            dayOfWeek: now.dayOfWeekET, minuteOfDay: now.minuteOfDayET, now: now)
        XCTAssertEqual(line, "Next: street cleaning Mon 9\u{2013}10:30 AM")
    }
}

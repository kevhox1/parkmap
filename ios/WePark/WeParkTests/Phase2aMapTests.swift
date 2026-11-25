//
//  Phase2aMapTests.swift
//  WeParkTests
//
//  Design system Phase 2a (flag-on main map). Pins the accuracy rules:
//    - base-map green = free for the WHOLE selected window AND readable signs
//    - green nests: A few hours ⊇ Overnight ⊇ For days (every ladder rung)
//    - no-data, unknown, metered, commercial-only and plate-only never draw green in base mode
//    - `freeButRestrictionSoon` is never green in base mode
//  plus the copy ("midnight", real For-days span) and the appearance decision.
//

import XCTest
@testable import WePark

final class Phase2aMapTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: Fixtures (private to this class)

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    private func makeRule(
        _ category: WePark.Category,
        days: [Int] = [],
        ranges: [(Int, Int)] = [],
        anytime: Bool = false
    ) -> ParkingRule {
        let dict: [String: Any] = [
            "category": category.rawValue,
            "description": "",
            "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime,
            "arrow": "both",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    private func makeSegment(_ rules: [ParkingRule]) -> Segment {
        let ruleJSON = rules.map { rule -> [String: Any] in
            [
                "category": rule.category.rawValue,
                "description": "",
                "days": rule.days,
                "timeRanges": rule.timeRanges.map { ["start": $0.start, "end": $0.end] },
                "anytime": rule.anytime,
                "arrow": "both",
            ]
        }
        let dict: [String: Any] = [
            "id": "P2A", "street": "MOTT STREET", "from": "GRAND STREET", "to": "HESTER STREET",
            "side": "N", "line": [[40.7183, -73.9942], [40.7190, -73.9940]], "rules": ruleJSON,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    // Wed 11/25/2026 10:11 PM ET (the design mocks' clock).
    private var now: Date { et(2026, 11, 25, 22, 11) }

    private func parkable(_ segment: Segment, goal: ParkingGoal) -> Bool {
        WPCurbVerdict.isParkable(
            segment: segment, engine: engine, from: now,
            until: ParkingGoals.target(for: goal, from: now)
        )
    }

    // MARK: Never a fake spot

    func testNoData_neverParkable() {
        let empty = makeSegment([])
        XCTAssertTrue(WPCurbVerdict.hasUnreadableSigns(empty))
        for goal in ParkingGoal.allCases { XCTAssertFalse(parkable(empty, goal: goal)) }
    }

    func testUnknownRule_neverParkable_evenWithOtherClearRules() {
        let onlyUnknown = makeSegment([makeRule(.unknown)])
        let mixed = makeSegment([makeRule(.unknown), makeRule(.noParking, days: [1], ranges: [(480, 540)])])
        for goal in ParkingGoal.allCases {
            XCTAssertFalse(parkable(onlyUnknown, goal: goal))
            XCTAssertFalse(parkable(mixed, goal: goal))
        }
    }

    func testMetered_runningInWindow_neverParkable() {
        // Metered 7 AM-7 PM every day: the Overnight window (to 7 AM) is clear of it, but the
        // few-hours and for-days windows must respect it per the engine; at minimum, a meter
        // running inside the window is never green.
        let meteredNow = makeSegment([makeRule(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(0, 1439)])])
        for goal in ParkingGoal.allCases { XCTAssertFalse(parkable(meteredNow, goal: goal)) }
    }

    func testCommercialAndPlateOnly_reclassifiedAsSpecialOrNoParking_neverParkable() {
        let plateOnly = makeSegment([makeRule(.special, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)])
        let commercial = makeSegment([makeRule(.noParking, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)])
        for goal in ParkingGoal.allCases {
            XCTAssertFalse(parkable(plateOnly, goal: goal))
            XCTAssertFalse(parkable(commercial, goal: goal))
        }
    }

    func testReadableAndClear_isParkable() {
        // No Parking Mon 8-9 AM only: clear for Wed night -> Thu 7 AM, and for the 3-hour window.
        let clear = makeSegment([makeRule(.noParking, days: [1], ranges: [(480, 540)])])
        XCTAssertTrue(parkable(clear, goal: .freeOvernight))
        XCTAssertTrue(parkable(clear, goal: .freeFewHours))
        XCTAssertFalse(parkable(clear, goal: .parkAndForget), "Monday 8 AM falls inside the 7 clear days")
    }

    func testDetailTag_neverGreenForUnreadableOrRestricted() {
        let noData = makeSegment([])
        XCTAssertEqual(WPCurbVerdict.detailTag(segment: noData, engine: engine, from: now, until: now.addingTimeInterval(3600)), .unknown)
        let restricted = makeSegment([makeRule(.noParking, anytime: true)])
        XCTAssertEqual(WPCurbVerdict.detailTag(segment: restricted, engine: engine, from: now, until: now.addingTimeInterval(3600)), .restrictedNow)
    }

    // MARK: Curb-line mapping (base mode)

    func testBaseMode_onlyFreeComfortablyDrawsPark() {
        let states: [CurrentState] = [.freeComfortably, .freeButRestrictionSoon, .meteredActive, .restrictedNow, .unknown]
        for state in states {
            let kind = CurbLineStyleV2.kind(for: state, detailMode: false)
            XCTAssertEqual(kind == .park, state == .freeComfortably, "\(state) in base mode")
            XCTAssertTrue(kind == .park || kind == .dont, "base mode is two-state")
        }
    }

    func testDetailMode_freeButRestrictionSoon_isSoon_notPark() {
        XCTAssertEqual(CurbLineStyleV2.kind(for: .freeButRestrictionSoon, detailMode: true), .soon)
    }

    // MARK: Nesting over real tiles

    func testGreenNests_overRealSegments_atSeveralTimes() throws {
        struct Index: Decodable { struct E: Decodable { let row: Int; let col: Int }; let tiles: [E] }
        let indexURL = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "json"))
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        var segments: [Segment] = []
        for (i, tile) in index.tiles.enumerated() where i % 40 == 0 {
            guard let url = Bundle.main.url(forResource: "tile_\(tile.row)_\(tile.col)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Segment].self, from: data) else { continue }
            segments.append(contentsOf: decoded)
            if segments.count >= 4000 { break }
        }
        XCTAssertGreaterThan(segments.count, 500)

        let times = [et(2026, 11, 24, 13), et(2026, 11, 22, 10), et(2026, 11, 25, 22, 11), et(2026, 11, 25, 5), et(2026, 11, 28, 15)]
        for from in times {
            let fewEnd = ParkingGoals.target(for: .freeFewHours, from: from)
            let overnightEnd = ParkingGoals.target(for: .freeOvernight, from: from)
            for segment in segments {
                let few = WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: fewEnd)
                let overnight = WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: overnightEnd)
                if overnight { XCTAssertTrue(few, "Overnight green must be inside A few hours green: \(segment.id) at \(from)") }
                for offset in ParkingGoals.parkAndForgetLadderOffsetDays {
                    let days = WPCurbVerdict.isParkable(
                        segment: segment, engine: engine, from: from, until: from.startOfDayET(offsetDays: offset)
                    )
                    if days { XCTAssertTrue(overnight, "For days (\(offset)) green must be inside Overnight: \(segment.id) at \(from)") }
                }
                // Never green when unreadable.
                if WPCurbVerdict.hasUnreadableSigns(segment) { XCTAssertFalse(few) }
            }
        }
    }

    // MARK: Copy

    func testClock_midnight_and_noLeadingZeroOnTheHour() {
        XCTAssertEqual(WPGoalCopy.clock(et(2026, 11, 26, 0, 0)), "midnight")
        XCTAssertEqual(WPGoalCopy.clock(et(2026, 11, 26, 7, 0)), "7\u{00A0}AM")
        XCTAssertEqual(WPGoalCopy.clock(et(2026, 11, 26, 1, 11)), "1:11\u{00A0}AM")
        XCTAssertEqual(WPGoalCopy.clock(et(2026, 11, 26, 12, 5)), "12:05\u{00A0}PM")
    }

    func testHeadlines_matchMocks() {
        let overnight = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertEqual(WPGoalCopy.headlineEnd(goal: .freeOvernight, end: overnight, now: now), "7\u{00A0}AM tomorrow")
        XCTAssertEqual(WPGoalCopy.countdown(goal: .freeOvernight, end: overnight, now: now), "8 h 49 min from now")
        XCTAssertEqual(WPGoalCopy.tileUntil(goal: .freeOvernight, end: overnight), "until 7\u{00A0}AM")
        let few = ParkingGoals.target(for: .freeFewHours, from: now)
        XCTAssertEqual(WPGoalCopy.tileUntil(goal: .freeFewHours, end: few), "until 1:11\u{00A0}AM")
        XCTAssertEqual(WPGoalCopy.countdown(goal: .freeFewHours, end: few, now: now), "3 h from now")
    }

    func testForDays_usesTheRealLadderEnd_notAHardCodedWeek() {
        // Rung 8 -> through Wed 12/2 (7 days), rung 4 -> through Sat 11/28 (3 days), rung 2 -> Thu 11/26 (1 day).
        let expected: [(Int, String, Int)] = [(8, "Wed, Dec 2", 7), (4, "Sat, Nov 28", 3), (2, "Thu, Nov 26", 1)]
        for (offset, headline, span) in expected {
            let end = now.startOfDayET(offsetDays: offset)
            XCTAssertEqual(WPGoalCopy.headlineEnd(goal: .parkAndForget, end: end, now: now), headline)
            XCTAssertEqual(WPGoalCopy.spanDays(forDaysEnd: end, from: now), span)
        }
        let rung4 = now.startOfDayET(offsetDays: 4)
        XCTAssertEqual(
            WPGoalCopy.guardLine(kind: .sparse, forDaysEnd: rung4, now: now),
            "Only a few blocks nearby are clear for 3 days."
        )
        XCTAssertEqual(
            WPGoalCopy.guardLine(kind: .sparse, forDaysEnd: now.startOfDayET(offsetDays: 2), now: now),
            "Only a few blocks nearby are clear for 1 day."
        )
        XCTAssertEqual(WPGoalCopy.tileUntil(goal: .parkAndForget, end: now.startOfDayET(offsetDays: 8)), "until Wed 12/2")
    }

    func testGoalNames_renameParkAndForget() {
        XCTAssertEqual(WPGoalCopy.goalName(.parkAndForget), "For days")
        XCTAssertEqual(WPGoalCopy.tileOrder, [.freeFewHours, .freeOvernight, .parkAndForget])
    }

    func testStreetCleaningPill() {
        XCTAssertEqual(wpStreetCleaningPill(state: .aspInEffect, now: now), .streetCleaningInEffect)
        XCTAssertEqual(wpStreetCleaningPill(state: .todaySuspended(reason: "Thanksgiving"), now: now), .streetCleaningSuspended)
        // Sunday: street cleaning does not run, so never claim "in effect today".
        XCTAssertEqual(wpStreetCleaningPill(state: .aspInEffect, now: et(2026, 11, 22, 10)), WPTopPill.none)
    }

    // MARK: Appearance

    func testBaseInterfaceStyle_flagOffIsDark_flagOnFollowsSystem() {
        XCTAssertEqual(DesignSystemAppearance.baseInterfaceStyle(enabled: false), .dark)
        XCTAssertEqual(DesignSystemAppearance.baseInterfaceStyle(enabled: true), .unspecified)
        XCTAssertEqual(DesignSystemAppearance.baseInterfaceStyle(), .dark, "flag ships off")
    }

    func testFlagOffBuildHasNoPlistForcedStyleKey() throws {
        // The forced dark moved from the Info.plist key to the window; the launch screen is pinned.
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertNil(info["UIUserInterfaceStyle"])
        let launch = try XCTUnwrap(info["UILaunchScreen"] as? [String: Any])
        XCTAssertEqual(launch["UIColorName"] as? String, "LaunchBackground")
    }
}

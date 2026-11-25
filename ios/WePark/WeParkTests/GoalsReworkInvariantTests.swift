//
//  GoalsReworkInvariantTests.swift
//  WeParkTests
//
//  docs/specs/goals-rework.md section 1 / section 5: with every goal's window starting NOW and
//  one free rule for all goals,
//      green(A Few Hours) ⊇ green(Overnight 7 AM) ⊇ green(Park & Forget)
//  and a later Overnight lever end can only REMOVE green. Property-checked over a sample of
//  REAL bundled tile segments at several times of day / week (Sunday, ASP days, an ASP
//  suspension day, the pre-dawn cap case, exactly 7:00 AM).
//

import XCTest
@testable import WePark

final class GoalsReworkInvariantTests: XCTestCase {

    // MARK: - Fixtures

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

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

    /// Minimal local decode of `index.json` (`TileLoader`'s own `TileIndex` is private).
    private struct SampleTileIndex: Decodable {
        struct Entry: Decodable { let row: Int; let col: Int }
        let tiles: [Entry]
    }

    /// Every Nth tile of the bundled index, decoded, capped so the sweep stays fast.
    private func sampleSegments(everyNthTile stride: Int = 40, cap: Int = 6000) throws -> [Segment] {
        let indexURL = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "json"))
        let index = try JSONDecoder().decode(SampleTileIndex.self, from: Data(contentsOf: indexURL))
        var segments: [Segment] = []
        for (i, tile) in index.tiles.enumerated() where i % stride == 0 {
            guard let url = Bundle.main.url(forResource: "tile_\(tile.row)_\(tile.col)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Segment].self, from: data) else { continue }
            segments.append(contentsOf: decoded)
            if segments.count >= cap { break }
        }
        return segments
    }

    /// Tue 1 PM, Sunday morning, Mon evening, pre-dawn Wed (A Few Hours cap case), the evening
    /// before the Thanksgiving ASP suspension (Thu 11/26), Fri 3 AM, Sat afternoon, Mon exactly
    /// 7:00 AM, and Wed 5/13 (before the suspended Ascension Thursday).
    private var sampleTimes: [Date] {
        [
            et(2026, 11, 24, 13),
            et(2026, 11, 22, 10),
            et(2026, 11, 23, 20),
            et(2026, 11, 25, 5),
            et(2026, 11, 25, 22),
            et(2026, 11, 27, 3),
            et(2026, 11, 28, 15),
            et(2026, 11, 30, 7),
            et(2026, 5, 13, 10),
        ]
    }

    // MARK: - Invariant

    func testInvariant_fewHoursSupersetOfOvernightSupersetOfParkAndForget() throws {
        let segments = try sampleSegments()
        XCTAssertGreaterThan(segments.count, 500, "Sample must be a meaningful slice of real tiles")

        var fewGreenTotal = 0
        var overnightGreenTotal = 0
        for now in sampleTimes {
            for segment in segments {
                let few = ParkingGoals.match(segment: segment, goal: .freeFewHours, from: now, engine: engine).matches
                let overnight = ParkingGoals.match(segment: segment, goal: .freeOvernight, from: now, engine: engine).matches
                let forget = ParkingGoals.match(segment: segment, goal: .parkAndForget, from: now, engine: engine).matches
                if few { fewGreenTotal += 1 }
                if overnight { overnightGreenTotal += 1 }
                if overnight { XCTAssertTrue(few, "Overnight-green must be A-Few-Hours-green: \(segment.id) at \(now)") }
                if forget { XCTAssertTrue(overnight, "Park&Forget-green must be Overnight-green: \(segment.id) at \(now)") }
            }
        }
        XCTAssertGreaterThan(fewGreenTotal, 0, "Sample must contain real green so the invariant isn't vacuous")
        XCTAssertGreaterThanOrEqual(fewGreenTotal, overnightGreenTotal)
    }

    func testInvariant_laterOvernightLeverOnlyRemovesGreen() throws {
        let segments = try sampleSegments()
        let hours = ParkingGoals.overnightMorningHourOptions  // 6...10, ascending
        for now in sampleTimes {
            for segment in segments {
                var previous = true
                for hour in hours {
                    let green = ParkingGoals.match(
                        segment: segment, goal: .freeOvernight, from: now, engine: engine,
                        overnightMorningHour: hour
                    ).matches
                    if green { XCTAssertTrue(previous, "Lever \(hour) AM added green over an earlier hour: \(segment.id) at \(now)") }
                    previous = green
                }
            }
        }
    }

    func testInvariant_noGoalIsGreenForARunningMeter() throws {
        let segments = try sampleSegments()
        // Tuesday 1 PM: any segment with a metered rule whose paid hours cover 1 PM Tuesday
        // (minute 780) must be red for every goal.
        let now = et(2026, 11, 24, 13)
        var checked = 0
        for segment in segments {
            let paidNow = segment.rules.contains { rule in
                rule.category == .metered
                    && rule.days.contains(2)
                    && rule.timeRanges.contains { $0.start <= 780 && 780 < $0.end }
            }
            guard paidNow else { continue }
            checked += 1
            for goal in ParkingGoal.allCases {
                XCTAssertFalse(
                    ParkingGoals.match(segment: segment, goal: goal, from: now, engine: engine).matches,
                    "\(goal): a running meter must never be green (\(segment.id))"
                )
            }
        }
        XCTAssertGreaterThan(checked, 0, "Sample must include metered curbs")
    }

    // MARK: - Window copy

    func testWindowLabel_overnightTomorrow() {
        let now = et(2026, 11, 24, 20, 15)
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertEqual(ParkingGoals.windowLabel(for: .freeOvernight, end: end, from: now), "Now → 7:00 AM tomorrow")
    }

    func testWindowLabel_fewHoursSameDay() {
        let now = et(2026, 11, 24, 17, 15)
        let end = ParkingGoals.target(for: .freeFewHours, from: now)
        XCTAssertEqual(ParkingGoals.windowLabel(for: .freeFewHours, end: end, from: now), "Now → 8:15 PM")
    }

    func testWindowLabel_parkAndForgetUsesWeekdayDate() {
        let now = et(2026, 11, 24, 12)
        // Rung offset 6 days out -> Mon 11/30.
        let end = now.startOfDayET(offsetDays: 6)
        XCTAssertEqual(ParkingGoals.windowLabel(for: .parkAndForget, end: end, from: now), "Now → Mon 11/30")
    }

    func testWindowLabel_overnightWithNineAMLever() {
        let now = et(2026, 11, 24, 20, 0)
        let end = ParkingGoals.target(for: .freeOvernight, from: now, overnightMorningHour: 9)
        XCTAssertEqual(ParkingGoals.windowLabel(for: .freeOvernight, end: end, from: now), "Now → 9:00 AM tomorrow")
    }
}

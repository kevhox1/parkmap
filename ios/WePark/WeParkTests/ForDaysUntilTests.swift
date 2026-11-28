//
//  ForDaysUntilTests.swift
//  WeParkTests
//
//  DT35-1 (PR4): the For-days "Free until" picker's grid, clamp, range, DST and stale-pick rules,
//  plus the copy strings. Reference dates (ET):
//    2026-06-04 Thursday 10:00 AM: ordinary week (Overnight ends Fri 7:00 AM).
//    2027-03-12 Friday: the grid reaches spring-forward day 3/14 (2:00 AM does not exist on 3/14).
//    2026-10-30 Friday: the grid reaches fall-back day 11/1 (1:00 to 2:00 AM repeats on 11/1).
//

import XCTest
@testable import WePark

final class ForDaysUntilTests: XCTestCase {

    private func etDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
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

    private let nbsp = "\u{00A0}"

    // MARK: Range + grid

    func testGrid_startsAtOvernightEnd_endsAtMidnightAfterDay8() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        XCTAssertEqual(grid.first, etDate(2026, 6, 5, 7, 0), "first selectable end is the Overnight end")
        XCTAssertEqual(grid.last, etDate(2026, 6, 12, 0, 0), "last is the start of day 8 (midnight)")
        XCTAssertEqual(grid.last, now.startOfDayET(offsetDays: 8))
    }

    func testGrid_isStrictly30MinuteSteps_onOrdinaryDays() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        for pair in zip(grid, grid.dropFirst()) {
            XCTAssertEqual(pair.1.timeIntervalSince(pair.0), 30 * 60, "\(pair.0) to \(pair.1)")
        }
    }

    func testGrid_honoursMorningHourLever() {
        let now = etDate(2026, 6, 4, 10, 0)
        XCTAssertEqual(ForDaysUntil.grid(now: now, morningHour: 9).first, etDate(2026, 6, 5, 9, 0))
        XCTAssertEqual(ForDaysUntil.grid(now: now, morningHour: 6).first, ParkingGoals.overnightEnd(from: now, morningHour: 6),
                       "the minimum is always exactly the Overnight end")
    }

    func testGrid_afterMidnightBeforeSeven_startsToday() {
        let now = etDate(2026, 6, 4, 2, 15)
        XCTAssertEqual(ForDaysUntil.grid(now: now, morningHour: 7).first, etDate(2026, 6, 4, 7, 0))
    }

    // MARK: Clamp

    func testSnap_earlierThanOvernightEnd_clampsUp_andSaysSo() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let result = ForDaysUntil.snap(etDate(2026, 6, 4, 17, 0), grid: grid)
        XCTAssertEqual(result.date, grid.first)
        XCTAssertTrue(result.clamped)
    }

    func testSnap_floorsOntoGrid_andIsNotClamped() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let result = ForDaysUntil.snap(etDate(2026, 6, 9, 9, 20), grid: grid)
        XCTAssertEqual(result.date, etDate(2026, 6, 9, 9, 0))
        XCTAssertFalse(result.clamped)
    }

    func testSnap_beyondTop_clampsDownSilently() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let result = ForDaysUntil.snap(etDate(2026, 7, 1, 9, 0), grid: grid)
        XCTAssertEqual(result.date, grid.last)
        XCTAssertFalse(result.clamped)
    }

    // MARK: Stepper

    func testStep_movesBy30Minutes_andStopsAtBothEnds() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let nine = etDate(2026, 6, 9, 9, 0)
        XCTAssertEqual(ForDaysUntil.step(from: nine, by: 1, grid: grid), etDate(2026, 6, 9, 9, 30))
        XCTAssertEqual(ForDaysUntil.step(from: nine, by: -1, grid: grid), etDate(2026, 6, 9, 8, 30))
        XCTAssertNil(ForDaysUntil.step(from: grid.first!, by: -1, grid: grid), "disabled at the Overnight end")
        XCTAssertNil(ForDaysUntil.step(from: grid.last!, by: 1, grid: grid), "disabled at midnight after day 8")
    }

    func testStep_rollsIntoNeighbouringDay() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        XCTAssertEqual(ForDaysUntil.step(from: etDate(2026, 6, 8, 23, 30), by: 1, grid: grid), etDate(2026, 6, 9, 0, 0))
        XCTAssertEqual(ForDaysUntil.step(from: etDate(2026, 6, 9, 0, 0), by: 1, grid: grid), etDate(2026, 6, 9, 0, 30))
    }

    // MARK: Days + quick chips

    func testDayIndex_midnightBelongsToTheNightBefore() {
        let now = etDate(2026, 6, 4, 10, 0)
        XCTAssertEqual(ForDaysUntil.dayIndex(of: etDate(2026, 6, 9, 9, 0), now: now), 5)
        XCTAssertEqual(ForDaysUntil.dayIndex(of: etDate(2026, 6, 9, 0, 0), now: now), 4, "midnight Mon night is Monday")
        XCTAssertEqual(ForDaysUntil.dayIndex(of: etDate(2026, 6, 12, 0, 0), now: now), 7, "the top end is on the 8th chip")
    }

    func testRetarget_keepsTimeOfDay_andClamps() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let moved = ForDaysUntil.retarget(etDate(2026, 6, 9, 9, 30), toDay: 6, now: now, grid: grid)
        XCTAssertEqual(moved.date, etDate(2026, 6, 10, 9, 30))
        XCTAssertFalse(moved.clamped)
        let today = ForDaysUntil.retarget(etDate(2026, 6, 9, 9, 30), toDay: 0, now: now, grid: grid)
        XCTAssertEqual(today.date, grid.first)
        XCTAssertTrue(today.clamped, "Today 9:30 AM is already past: Overnight covers it")
        let midnight = ForDaysUntil.retarget(etDate(2026, 6, 9, 0, 0), toDay: 6, now: now, grid: grid)
        XCTAssertEqual(midnight.date, etDate(2026, 6, 11, 0, 0))
    }

    func testQuick_hoursAndMidnight() {
        let now = etDate(2026, 6, 4, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        XCTAssertEqual(ForDaysUntil.quick(hour: 17, onDay: 4, now: now, grid: grid).date, etDate(2026, 6, 8, 17, 0))
        XCTAssertEqual(ForDaysUntil.quick(hour: nil, onDay: 4, now: now, grid: grid).date, etDate(2026, 6, 9, 0, 0))
        XCTAssertEqual(ForDaysUntil.quick(hour: nil, onDay: 7, now: now, grid: grid).date, grid.last)
        XCTAssertTrue(ForDaysUntil.quick(hour: 7, onDay: 0, now: now, grid: grid).clamped)
    }

    // MARK: DST (ET wall clock)

    func testGrid_springForwardDay_skipsTheMissingHour_andStaysIncreasing() {
        let now = etDate(2027, 3, 12, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let cal = Calendar.easternTime
        let springDay = grid.filter { cal.component(.day, from: $0) == 14 && cal.component(.month, from: $0) == 3 }
        XCTAssertFalse(springDay.contains { cal.component(.hour, from: $0) == 2 }, "2:00 to 3:00 AM does not exist on 3/14")
        XCTAssertTrue(springDay.contains { cal.component(.hour, from: $0) == 3 && cal.component(.minute, from: $0) == 0 })
        for pair in zip(grid, grid.dropFirst()) { XCTAssertLessThan(pair.0, pair.1) }
    }

    func testGrid_fallBackDay_hasOneEntryPerRepeatedWallClockSlot() {
        let now = etDate(2026, 10, 30, 10, 0)
        let grid = ForDaysUntil.grid(now: now, morningHour: 7)
        let cal = Calendar.easternTime
        let fallDay = grid.filter { cal.component(.day, from: $0) == 1 && cal.component(.month, from: $0) == 11 }
        let oneThirty = fallDay.filter {
            cal.component(.hour, from: $0) == 1 && cal.component(.minute, from: $0) == 30
        }
        XCTAssertEqual(oneThirty.count, 1, "the repeated hour has a single 1:30 AM entry")
        XCTAssertEqual(Set(grid).count, grid.count, "no duplicates")
        for pair in zip(grid, grid.dropFirst()) { XCTAssertLessThan(pair.0, pair.1) }
        XCTAssertEqual(grid.last, now.startOfDayET(offsetDays: 8))
    }

    // MARK: Stale pick

    func testRestoredPick_staleOrMissing_resetsToAuto() {
        let now = etDate(2026, 6, 4, 10, 0)
        XCTAssertNil(ForDaysUntil.restoredPick(stored: 0, now: now, morningHour: 7))
        let past = etDate(2026, 6, 1, 17, 0).timeIntervalSince1970
        XCTAssertNil(ForDaysUntil.restoredPick(stored: past, now: now, morningHour: 7))
        let atMin = etDate(2026, 6, 5, 7, 0).timeIntervalSince1970
        XCTAssertNil(ForDaysUntil.restoredPick(stored: atMin, now: now, morningHour: 7), "at the minimum resets")
    }

    func testRestoredPick_validPick_survives() {
        let now = etDate(2026, 6, 4, 10, 0)
        let monday = etDate(2026, 6, 8, 17, 0)
        XCTAssertEqual(
            ForDaysUntil.restoredPick(stored: monday.timeIntervalSince1970, now: now, morningHour: 7), monday
        )
    }

    func testRestoredPick_moveOfMinimumWithLever_makesOldPickStale() {
        let now = etDate(2026, 6, 4, 10, 0)
        let fridayEight = etDate(2026, 6, 5, 8, 0).timeIntervalSince1970
        XCTAssertNotNil(ForDaysUntil.restoredPick(stored: fridayEight, now: now, morningHour: 7))
        XCTAssertNil(ForDaysUntil.restoredPick(stored: fridayEight, now: now, morningHour: 9))
    }

    // MARK: Display + copy

    func testStamp_midnightIsTheNightBefore_neverTwelveAM() {
        XCTAssertEqual(WPForDaysCopy.stamp(etDate(2026, 6, 12, 0, 0)), "midnight Thu night")
        XCTAssertEqual(WPForDaysCopy.spokenStamp(etDate(2026, 6, 12, 0, 0)), "midnight Thursday night")
        XCTAssertFalse(WPForDaysCopy.stamp(etDate(2026, 6, 12, 0, 0)).contains("12"))
    }

    func testStamp_regularTimes() {
        XCTAssertEqual(WPForDaysCopy.stamp(etDate(2026, 6, 9, 9, 0)), "Tue 9\(nbsp)AM")
        XCTAssertEqual(WPForDaysCopy.stamp(etDate(2026, 6, 8, 17, 30)), "Mon 5:30\(nbsp)PM")
        XCTAssertEqual(WPForDaysCopy.spokenStamp(etDate(2026, 6, 9, 9, 0)), "Tuesday 9\(nbsp)AM")
    }

    func testDayAndQuickTitles() {
        let now = etDate(2026, 6, 4, 10, 0)
        XCTAssertEqual(WPForDaysCopy.dayTitle(offset: 0, now: now), "Today")
        XCTAssertEqual(WPForDaysCopy.dayTitle(offset: 1, now: now), "Tomorrow")
        XCTAssertEqual(WPForDaysCopy.dayTitle(offset: 2, now: now), "Sat")
        XCTAssertEqual(WPForDaysCopy.dayTitle(offset: 7, now: now), "Thu")
        XCTAssertEqual(WPForDaysCopy.quickTitle(hour: 7), "7\(nbsp)AM")
        XCTAssertEqual(WPForDaysCopy.quickTitle(hour: 12), "12\(nbsp)PM")
        XCTAssertEqual(WPForDaysCopy.quickTitle(hour: 17), "5\(nbsp)PM")
        XCTAssertEqual(WPForDaysCopy.quickTitle(hour: nil), "Midnight")
    }

    func testClampNoteCopy() {
        XCTAssertEqual(WPForDaysCopy.clampNote, "Overnight already covers this. Use Overnight for earlier.")
    }

    // MARK: WPGoalCopy for a non-midnight end (Auto midnight paths unchanged)

    func testHeadline_tile_countdown_forNonMidnightEnd() {
        let now = etDate(2026, 6, 4, 10, 0)
        let end = etDate(2026, 6, 9, 9, 0)
        XCTAssertEqual(WPForDaysCopy.headline(end: end), "Tue 6/9, 9\(nbsp)AM")
        XCTAssertEqual(WPForDaysCopy.tile(end: end), "until Tue 9\(nbsp)AM")
        XCTAssertEqual(WPForDaysCopy.countdown(end: etDate(2026, 6, 5, 14, 0), now: now), "1 day 4 h from now")
        XCTAssertEqual(WPForDaysCopy.countdown(end: etDate(2026, 6, 6, 10, 0), now: now), "2 days from now")
        XCTAssertEqual(WPForDaysCopy.countdown(end: etDate(2026, 6, 4, 18, 0), now: now), "8 h from now")
    }

    func testCountdown_neverSaysOneDays() {
        let now = etDate(2026, 6, 4, 10, 0)
        let text = WPForDaysCopy.countdown(end: etDate(2026, 6, 5, 11, 0), now: now)
        XCTAssertEqual(text, "1 day 1 h from now")
        XCTAssertFalse(text.contains("1 days"))
    }

    func testAutoMidnightPaths_areUnchanged() {
        let now = etDate(2026, 6, 4, 10, 0)
        let end = now.startOfDayET(offsetDays: 8)
        XCTAssertEqual(WPGoalCopy.headlineEnd(goal: .parkAndForget, end: end, now: now), WPGoalCopy.longDate(end.addingTimeInterval(-1)))
        XCTAssertEqual(WPGoalCopy.tileUntil(goal: .parkAndForget, end: end), "until " + WPGoalCopy.weekdayDate(end.addingTimeInterval(-1)))
        XCTAssertEqual(WPGoalCopy.countdown(goal: .parkAndForget, end: end, now: now), "Until midnight, 7 days from now")
    }

    func testGoalSheetInput_manualForDays_routesCopyThroughTheNewHelpers() {
        let now = etDate(2026, 6, 4, 10, 0)
        let end = etDate(2026, 6, 9, 9, 0)
        let state = WPForDaysState(
            requested: end, effective: end, isFallback: false, greenCount: 3, kind: nil, thin: false
        )
        let input = WPGoalSheetInput(
            selectedGoal: .parkAndForget, now: now,
            fewHoursEnd: now.addingTimeInterval(3 * 3600), overnightEnd: etDate(2026, 6, 5, 7, 0),
            forDaysEnd: end, detailMode: false, loading: false, guardKind: nil, note: nil,
            morningHour: 7, forDaysPick: end, forDaysState: state, forDaysClampNote: false
        )
        XCTAssertEqual(input.headlineEnd, "Tue 6/9, 9\(nbsp)AM")
        XCTAssertEqual(input.tileUntil(.parkAndForget), "until Tue 9\(nbsp)AM")
        XCTAssertNil(input.forDaysBanner, "no banner when the request itself has clear curbs")
    }
}

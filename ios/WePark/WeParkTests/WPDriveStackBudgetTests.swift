//
//  WPDriveStackBudgetTests.swift
//  WeParkTests
//
//  DT35-6b: the Stoop drive stack gives way at accessibility sizes so the Apple Maps logo and
//  Legal link keep a clear strip (see `MapBottomInsetPolicy`).
//

import XCTest
@testable import WePark

final class WPDriveStackBudgetTests: XCTestCase {

    func testStandardSizesKeepTheOriginalVerdictBudget() {
        XCTAssertEqual(WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: false), 0.55)
    }

    func testAccessibilitySizesCapTheVerdictsLower() {
        let ax = WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: true)
        XCTAssertLessThan(ax, WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: false))
        // Verdicts plus roughly 0.25 of the screen for pill and actions stay inside the inset clamp.
        XCTAssertLessThanOrEqual(ax + 0.25, MapBottomInsetPolicy.maxHeightFraction)
    }

    // MARK: Pill short form keeps the end of the window

    private func compact(_ goal: ParkingGoal, end: Date, from now: Date) -> String {
        WPDriveStackBudget.compactPillText(endLabel: ParkingGoals.windowEndLabel(for: goal, end: end, from: now))
    }

    func testCompactPillKeepsTheEndForEveryGoalAndDropsTheRest() {
        let cal = Calendar.easternTime
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22, minute: 0))!
        let overnightEnd = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 7, minute: 0))!
        let fewHoursEnd = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 0, minute: 0))!
        let daysEnd = cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 0, minute: 0))!
        let overnight = compact(.freeOvernight, end: overnightEnd, from: now)
        let few = compact(.freeFewHours, end: fewHoursEnd, from: now)
        let days = compact(.parkAndForget, end: daysEnd, from: now)
        for text in [overnight, few, days] {
            XCTAssertTrue(text.hasPrefix("Until "), text)
            XCTAssertFalse(text.contains("Now"), text)
            XCTAssertFalse(text.contains("Overnight"), text)
            XCTAssertFalse(text.contains("\u{2026}"), text)
        }
        XCTAssertTrue(overnight.contains("7:00") && overnight.contains("tomorrow"), overnight)
        XCTAssertTrue(days.contains("11/30"), days)
    }

    func testCompactPillNeverBreaksATimeFromItsMeridiem() {
        let text = WPDriveStackBudget.compactPillText(endLabel: "Mon 11/30 7:00 AM")
        XCTAssertTrue(text.contains("7:00\u{00A0}AM") || text.contains("7:00\u{202F}AM"), text)
    }

    // MARK: For-days picks with a time

    private func etDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Calendar.easternTime.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testForDaysAutoMidnightEndKeepsTheDateOnlyWording() {
        let now = etDate(2026, 11, 24, 12)
        let end = now.startOfDayET(offsetDays: 6)
        XCTAssertEqual(ParkingGoals.windowEndLabel(for: .parkAndForget, end: end, from: now), "Mon 11/30")
        XCTAssertEqual(ParkingGoals.windowLabel(for: .parkAndForget, end: end, from: now), "Now \u{2192} Mon 11/30")
    }

    func testForDaysPickWithATimeIncludesTheTime() {
        let now = etDate(2026, 11, 24, 12)
        let end = etDate(2026, 11, 30, 9)
        XCTAssertEqual(ParkingGoals.windowEndLabel(for: .parkAndForget, end: end, from: now), "Mon 11/30 9:00 AM")
        XCTAssertEqual(ParkingGoals.windowLabel(for: .parkAndForget, end: end, from: now), "Now \u{2192} Mon 11/30 9:00 AM")
        let text = compact(.parkAndForget, end: end, from: now)
        XCTAssertTrue(text.hasPrefix("Until Mon 11/30 9:00"), text)
        XCTAssertTrue(text.contains("\u{00A0}AM"), text)
    }

    func testForDaysPickAtHalfPastIncludesMinutes() {
        let now = etDate(2026, 11, 24, 12)
        let end = etDate(2026, 11, 30, 21, 30)
        XCTAssertEqual(ParkingGoals.windowEndLabel(for: .parkAndForget, end: end, from: now), "Mon 11/30 9:30 PM")
    }
}

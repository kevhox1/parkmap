//
//  WPWindowClockTests.swift
//  WeParkTests
//
//  R35 PR1 (docs/specs/r35-map-polish-and-trip-destination.md): the Stoop goal window clock.
//  A fake clock (plain `Date` values) drives everything: no sleeping, no real time.
//

import CoreLocation
import XCTest
@testable import WePark

final class WPWindowClockTests: XCTestCase {

    // MARK: - Fixtures

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    private func input(now: Date, selected: ParkingGoal = .freeFewHours) -> WPGoalSheetInput {
        let instant = WPWindowClock.instant(now)
        return WPGoalSheetInput(
            selectedGoal: selected,
            now: instant,
            fewHoursEnd: ParkingGoals.target(for: .freeFewHours, from: instant),
            overnightEnd: ParkingGoals.target(for: .freeOvernight, from: instant),
            forDaysEnd: ParkingGoals.target(for: .parkAndForget, from: instant),
            detailMode: false,
            loading: false,
            guardKind: nil,
            note: nil,
            morningHour: ParkingGoals.defaultOvernightMorningHour,
            liveNow: now
        )
    }

    /// The tile sub-line with the formatter's no-break space normalised, so the test does
    /// not depend on the OS clock-format whitespace.
    private func untilLabel(_ sheet: WPGoalSheetInput) -> String {
        WPGoalCopy.tileUntil(goal: .freeFewHours, end: sheet.selectedEnd)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - instant

    func testInstantFloorsToFiveMinutes() {
        let t = et(2026, 11, 27, 22, 7, 41)
        XCTAssertEqual(WPWindowClock.instant(t), et(2026, 11, 27, 22, 5, 0))
        XCTAssertEqual(WPWindowClock.instant(et(2026, 11, 27, 22, 5, 0)), et(2026, 11, 27, 22, 5, 0))
        XCTAssertEqual(WPWindowClock.instant(et(2026, 11, 27, 22, 9, 59)), et(2026, 11, 27, 22, 5, 0))
    }

    func testInstantIsIdempotentAndBoundedAcrossDSTAndMidnight() {
        // Spring forward, fall back (the 1 AM hour repeats), an ordinary midnight.
        for day in [(2026, 3, 8), (2026, 11, 1), (2026, 11, 27)] {
            let start = et(day.0, day.1, day.2, 0, 0)
            var t = start.addingTimeInterval(-3600)
            let stop = start.addingTimeInterval(27 * 3600)
            while t < stop {
                let i = WPWindowClock.instant(t)
                XCTAssertEqual(WPWindowClock.instant(i), i)
                XCTAssertLessThanOrEqual(i, t)
                XCTAssertLessThan(t, i.addingTimeInterval(WPWindowClock.step))
                // Wall-clock aligned in New York (offsets are whole hours).
                XCTAssertEqual(Calendar.easternTime.component(.minute, from: i) % 5, 0)
                t = t.addingTimeInterval(60)
            }
        }
    }

    // MARK: - Honesty invariant

    func testWindowAlwaysContainsTheLiveWindowForEveryGoalEveryMinute() {
        // Includes both DST days and a midnight crossing.
        for day in [(2026, 3, 8), (2026, 11, 1), (2026, 11, 27)] {
            var now = et(day.0, day.1, day.2, 0, 0)
            let stop = now.addingTimeInterval(26 * 3600)
            while now < stop {
                let instant = WPWindowClock.instant(now)
                for goal in [ParkingGoal.freeFewHours, .freeOvernight, .parkAndForget] {
                    let end = ParkingGoals.target(for: goal, from: instant)
                    // The coloured window [instant, end] contains the live window [now, end].
                    XCTAssertLessThanOrEqual(instant, now)
                    XCTAssertGreaterThan(end, now, "\(goal) end must be in the future at \(now)")
                    XCTAssertEqual(ParkingGoals.target(for: goal, from: instant), end)
                }
                // A few hours is never longer than 3 h from the live clock, and never shorter than
                // 2 h 55 min unless Overnight's end caps it.
                let few = ParkingGoals.target(for: .freeFewHours, from: instant)
                let over = ParkingGoals.target(for: .freeOvernight, from: instant)
                let remaining = few.timeIntervalSince(now)
                XCTAssertLessThanOrEqual(remaining, 3 * 3600)
                if few != over {
                    XCTAssertGreaterThan(remaining, 2 * 3600 + 55 * 60 - 1)
                }
                // Nesting: A few hours never ends after Overnight.
                XCTAssertLessThanOrEqual(few, over)
                now = now.addingTimeInterval(60)
            }
        }
    }

    // MARK: - needsRecolor

    func testNeedsRecolorFalseInsideACell() {
        let applied = et(2026, 11, 27, 22, 5)
        let end = et(2026, 11, 28, 1, 5)
        for second in stride(from: 0, to: 300, by: 7) {
            let now = applied.addingTimeInterval(TimeInterval(second))
            XCTAssertFalse(WPWindowClock.needsRecolor(applied: applied, now: now, displayedEnd: end))
        }
    }

    func testNeedsRecolorTrueOnCellChange() {
        let applied = et(2026, 11, 27, 22, 5)
        let now = et(2026, 11, 27, 22, 10, 1)
        XCTAssertTrue(WPWindowClock.needsRecolor(applied: applied, now: now, displayedEnd: nil))
    }

    func testNeedsRecolorTrueWhenDisplayedEndHasArrived() {
        let applied = et(2026, 11, 28, 7, 0)
        let end = et(2026, 11, 28, 7, 0, 30)   // an end that is not on the grid (trip departure)
        XCTAssertTrue(WPWindowClock.needsRecolor(
            applied: applied, now: et(2026, 11, 28, 7, 0, 40), displayedEnd: end
        ))
    }

    func testNeedsRecolorTrueWhenTheClockWentBack() {
        let applied = et(2026, 11, 27, 22, 30)
        XCTAssertTrue(WPWindowClock.needsRecolor(
            applied: applied, now: et(2026, 11, 27, 22, 10), displayedEnd: nil
        ))
    }

    func testOvernightFlipsWithinAMinuteOfSevenAM() {
        // 6:59 AM: Overnight ends at 7:00 today. The tick at 7:00:30 must recolor, and the new
        // window is tomorrow's 7 AM.
        let before = WPWindowClock.instant(et(2026, 11, 27, 6, 59, 10))
        let end = ParkingGoals.target(for: .freeOvernight, from: before)
        XCTAssertEqual(end, et(2026, 11, 27, 7, 0))
        let tick = et(2026, 11, 27, 7, 0, 30)
        XCTAssertTrue(WPWindowClock.needsRecolor(applied: before, now: tick, displayedEnd: end))
        let after = WPWindowClock.instant(tick)
        XCTAssertEqual(ParkingGoals.target(for: .freeOvernight, from: after), et(2026, 11, 28, 7, 0))
    }

    // MARK: - Labels advance with a fake clock

    func testLabelAdvancesInFiveMinuteStepsAndCountdownEveryMinute() {
        var endLabels: [String] = []
        var countdowns: [String] = []
        var now = et(2026, 11, 27, 22, 5, 0)
        for _ in 0..<21 {
            let sheet = input(now: now)
            endLabels.append(untilLabel(sheet))
            countdowns.append(sheet.countdown)
            now = now.addingTimeInterval(60)
        }
        // 22:05 to 22:25 inclusive: ends 1:05, 1:10, 1:15, 1:20, 1:25 AM, in 5 minute steps.
        XCTAssertEqual(Array(NSOrderedSet(array: endLabels)).count, 5, "\(endLabels)")
        XCTAssertEqual(endLabels.first, "until 1:05 AM")
        XCTAssertEqual(endLabels.last, "until 1:25 AM")
        // The countdown reads differently every minute (it drops by one each minute inside a cell
        // and resets to 3 h when the end steps), and never claims more than 3 h.
        for (a, b) in zip(countdowns, countdowns.dropFirst()) { XCTAssertNotEqual(a, b, "\(countdowns)") }
        XCTAssertEqual(countdowns[0], "3 h from now")
        XCTAssertEqual(countdowns[1], "2 h 59 min from now")
        XCTAssertEqual(countdowns[4], "2 h 56 min from now")
        XCTAssertEqual(countdowns[5], "3 h from now")
    }

    func testForegroundAfterAnHourIsCurrent() {
        let applied = WPWindowClock.instant(et(2026, 11, 27, 22, 5, 20))
        let back = et(2026, 11, 27, 23, 10, 0)
        XCTAssertTrue(WPWindowClock.needsRecolor(applied: applied, now: back, displayedEnd: nil))
        let sheet = input(now: back)
        XCTAssertEqual(untilLabel(sheet), "until 2:10 AM")
        XCTAssertEqual(sheet.countdown, "3 h from now")
    }

    func testWindowCrossingMidnightKeepsHeadlineAndCountdownInAgreement() {
        let now = et(2026, 11, 27, 23, 58, 0)
        let sheet = input(now: now)
        // Few hours from 11:55 PM ends 2:55 AM the next day, capped by Overnight's 7 AM only if sooner.
        XCTAssertEqual(sheet.selectedEnd, et(2026, 11, 28, 2, 55))
        XCTAssertTrue(sheet.headlineEnd.contains("tomorrow"), sheet.headlineEnd)
        XCTAssertEqual(sheet.countdown, "2 h 57 min from now")
    }

    func testFallBackNightHasNoNegativeOrOversizeCountdown() {
        // 2026-11-01 01:30 EDT, the hour that repeats.
        let now = et(2026, 11, 1, 1, 30)
        let sheet = input(now: now)
        let remaining = sheet.selectedEnd.timeIntervalSince(now)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThanOrEqual(remaining, 3 * 3600)
    }

    func testCountdownNeverReadsEarlierThanTheWindowInstant() {
        var sheet = input(now: et(2026, 11, 27, 22, 7, 0))
        sheet.liveNow = et(2026, 11, 27, 21, 0, 0)   // stale live clock
        XCTAssertEqual(sheet.countdownNow, sheet.now)
        XCTAssertLessThanOrEqual(
            sheet.selectedEnd.timeIntervalSince(sheet.countdownNow), 3 * 3600
        )
    }

    // MARK: - Minute alignment

    func testSecondsToNextMinuteLandsJustPastTheBoundary() {
        let t = et(2026, 11, 27, 22, 5, 20)
        let sleep = WPWindowClock.secondsToNextMinute(from: t)
        XCTAssertEqual(sleep, 40.5, accuracy: 0.001)
        let boundary = t.addingTimeInterval(sleep)
        XCTAssertEqual(Calendar.easternTime.component(.second, from: boundary), 0)
        XCTAssertEqual(WPWindowClock.secondsToNextMinute(from: et(2026, 11, 27, 22, 6, 0)), 60.5, accuracy: 0.001)
    }

    // MARK: - Overlay signature (no flicker when nothing changed colour)

    private func line(_ a: Double, _ b: Double) -> [CLLocationCoordinate2D] {
        [CLLocationCoordinate2D(latitude: 40.75 + a, longitude: -73.99 + b),
         CLLocationCoordinate2D(latitude: 40.75 + a + 0.0005, longitude: -73.99 + b)]
    }

    func testSignatureEqualForSameInputInDifferentOrder() {
        let green = [line(0, 0), line(0.001, 0), line(0.002, 0)]
        let red = [line(0, 0.001), line(0.001, 0.001)]
        let a = WPOverlaySignature.make(groups: [green, [], [], red, []], selected: nil, context: 1)
        let b = WPOverlaySignature.make(groups: [green.reversed(), [], [], red.reversed(), []], selected: nil, context: 1)
        XCTAssertEqual(a, b)
    }

    func testSignatureDiffersWhenOneCurbFlipsColour() {
        let green = [line(0, 0), line(0.001, 0), line(0.002, 0)]
        let red = [line(0, 0.001), line(0.001, 0.001)]
        let before = WPOverlaySignature.make(groups: [green, [], [], red, []], selected: nil, context: 1)
        var flippedGreen = green
        let moved = flippedGreen.removeLast()
        let after = WPOverlaySignature.make(groups: [flippedGreen, [], [], red + [moved], []], selected: nil, context: 1)
        XCTAssertNotEqual(before, after)
    }

    func testSignatureDiffersOnContextAndSelection() {
        let g = [line(0, 0)]
        let base = WPOverlaySignature.make(groups: [g, [], [], [], []], selected: nil, context: 1)
        XCTAssertNotEqual(base, WPOverlaySignature.make(groups: [g, [], [], [], []], selected: nil, context: 2))
        XCTAssertNotEqual(base, WPOverlaySignature.make(groups: [g, [], [], [], []], selected: line(0.5, 0), context: 1))
    }

    func testSignatureBoxSkipsRepeatsAndCounts() {
        let box = WPOverlaySignatureBox()
        let s1 = WPOverlaySignature.make(groups: [[line(0, 0)], [], [], [], []], selected: nil, context: 0)
        let s2 = WPOverlaySignature.make(groups: [[line(0, 0), line(1, 1)], [], [], [], []], selected: nil, context: 0)
        XCTAssertTrue(box.shouldPublish(s1))
        XCTAssertFalse(box.shouldPublish(s1))
        XCTAssertFalse(box.shouldPublish(s1))
        XCTAssertTrue(box.shouldPublish(s2))
        XCTAssertEqual(box.publishCount, 2)
        XCTAssertEqual(box.skipCount, 2)
    }

    // MARK: - Trip cache key

    func testTripClassificationKeyIsIndependentOfNowInStoop() {
        let arrival = et(2026, 11, 28, 9, 0)
        let departure = et(2026, 11, 28, 17, 0)
        func key(_ now: Date, stoop: Bool) -> OverlayClassificationKey {
            OverlayClassificationKey(
                now: WPWindowClock.tripCacheStamp(arrival: arrival, now: now, stoop: stoop),
                mode: .trip(arrival: arrival, departure: departure)
            )
        }
        let t1 = et(2026, 11, 27, 22, 0)
        let t2 = et(2026, 11, 27, 22, 20)
        XCTAssertEqual(key(t1, stoop: true), key(t2, stoop: true))
        XCTAssertNotEqual(key(t1, stoop: false), key(t2, stoop: false), "flag off keeps the legacy now key")
    }
}

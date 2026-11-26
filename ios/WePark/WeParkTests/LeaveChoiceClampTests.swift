//
//  LeaveChoiceClampTests.swift
//  `LeaveChoice.leaveAt(from:)` documents "always within [now, latest]". Rounding to the NEAREST
//  5 minutes used to land up to 2.5 minutes before `now` for a `.custom` time already passed
//  (and for `.minutes` under 3). It must never send a past time.
//

import XCTest
@testable import WePark

final class LeaveChoiceClampTests: XCTestCase {
    /// A 5-minute mark plus 2 minutes: the nearest mark (the mark itself) is in the past.
    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 120)

    func testCustom_alreadyPassed_neverBeforeNow() {
        let passed = now.addingTimeInterval(-600)
        XCTAssertGreaterThanOrEqual(LeaveChoice.custom(passed).leaveAt(from: now), now)
    }

    func testCustom_nearestMarkIsBeforeNow_clampedToNow() {
        XCTAssertEqual(LeaveChoice.custom(now).leaveAt(from: now), now)
    }

    func testMinutes_small_neverBeforeNow() {
        XCTAssertGreaterThanOrEqual(LeaveChoice.minutes(1).leaveAt(from: now), now)
        XCTAssertGreaterThanOrEqual(LeaveChoice.minutes(0).leaveAt(from: now), now)
    }

    func testCustom_future_stillRoundsToFiveMinutes() {
        let picked = now.addingTimeInterval(33 * 60)
        let result = LeaveChoice.custom(picked).leaveAt(from: now)
        XCTAssertEqual(result.timeIntervalSince1970.truncatingRemainder(dividingBy: 300), 0)
        XCTAssertGreaterThan(result, now)
    }

    func testAlwaysWithinNowAndLatest_acrossOffsets() {
        for offset in stride(from: -900, through: 20_000, by: 37) {
            let picked = now.addingTimeInterval(Double(offset))
            let result = LeaveChoice.custom(picked).leaveAt(from: now)
            XCTAssertGreaterThanOrEqual(result, now, "offset \(offset)")
            XCTAssertLessThanOrEqual(result, LeaveChoice.latest(from: now), "offset \(offset)")
        }
    }
}

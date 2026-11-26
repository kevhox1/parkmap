//
//  StoopPhase5bClipTests.swift
//  WeParkTests
//
//  Stoop Phase 5b (B11 App Clip). Pins:
//    - the shared compile-time flag stays false and AppConstants forwards to it
//    - DECISIONS #7: under Stoop the clip schedules exactly ONE reminder ("Still leaving around
//      4:45?", 2 minutes before leave_at); the shipping two-reminder plan is untouched
//    - the reminder permission seam defaults to "do not ask"
//    - the round-2 wording, including the privacy promise from docs/design-kit/BRIEF.md
//

import XCTest
@testable import WePark

final class StoopPhase5bClipTests: XCTestCase {

    private let p5bPass = UUID()
    private let p5bNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let p5bUS = Locale(identifier: "en_US")
    private let p5bNY = TimeZone(identifier: "America/New_York") ?? .current

    // MARK: Flag

    func testFlag_isFalseAndAppConstantsForwardsToIt() {
        XCTAssertFalse(StoopFlag.designSystemV2Enabled)
        XCTAssertEqual(AppConstants.designSystemV2Enabled, StoopFlag.designSystemV2Enabled)
    }

    // MARK: One reminder (DECISIONS #7)

    func testSinglePlan_isExactlyOneReminderTwoMinutesBeforeLeave() {
        let leave = p5bNow.addingTimeInterval(10 * 60)
        let plan = HandoffReminderPlan.makeSingle(
            passID: p5bPass, name: "Bodega Cat", leaveAt: leave, expiresAt: leave.addingTimeInterval(900),
            now: p5bNow, timeZone: p5bNY, locale: p5bUS
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].fireDate, leave.addingTimeInterval(-120))
        XCTAssertEqual(plan[0].body, "Bodega Cat is waiting for your spot.")
        XCTAssertEqual(plan[0].identifier, HandoffReminderPlan.leaveIdentifier(passID: p5bPass))
        XCTAssertTrue(plan[0].title.hasPrefix("Still leaving around "))
        XCTAssertTrue(plan[0].title.hasSuffix("?"))
    }

    func testSinglePlan_nowSchedulesNothing() {
        let plan = HandoffReminderPlan.makeSingle(
            passID: p5bPass, name: "X", leaveAt: p5bNow, expiresAt: p5bNow.addingTimeInterval(900), now: p5bNow
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testSinglePlan_leavingInUnderTwoMinutesFiresAsSoonAsItCan() {
        let leave = p5bNow.addingTimeInterval(60)
        let plan = HandoffReminderPlan.makeSingle(
            passID: p5bPass, name: "X", leaveAt: leave, expiresAt: leave.addingTimeInterval(900), now: p5bNow
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].fireDate, p5bNow.addingTimeInterval(2))
    }

    func testSinglePlan_neverFiresAtOrAfterTheLeaveTimeOrExpiry() {
        let leave = p5bNow.addingTimeInterval(1)
        XCTAssertTrue(HandoffReminderPlan.makeSingle(
            passID: p5bPass, name: "X", leaveAt: leave, expiresAt: leave.addingTimeInterval(900), now: p5bNow
        ).isEmpty)
        let later = p5bNow.addingTimeInterval(600)
        XCTAssertTrue(HandoffReminderPlan.makeSingle(
            passID: p5bPass, name: "X", leaveAt: later, expiresAt: later.addingTimeInterval(-300), now: p5bNow
        ).isEmpty)
    }

    func testPlan_flagOffKeepsTheShippingTwoReminders() {
        let leave = p5bNow.addingTimeInterval(10 * 60)
        let expiry = leave.addingTimeInterval(900)
        let off = HandoffReminderPlan.plan(
            stoop: false, passID: p5bPass, name: "Bodega Cat", leaveAt: leave, expiresAt: expiry, now: p5bNow
        )
        let shipping = HandoffReminderPlan.make(
            passID: p5bPass, name: "Bodega Cat", leaveAt: leave, expiresAt: expiry, now: p5bNow
        )
        XCTAssertEqual(off, shipping)
        XCTAssertEqual(off.count, 2)
        let on = HandoffReminderPlan.plan(
            stoop: true, passID: p5bPass, name: "Bodega Cat", leaveAt: leave, expiresAt: expiry, now: p5bNow
        )
        XCTAssertEqual(on.count, 1)
    }

    // MARK: Clock text

    func testBareClock_twelveHourDropsTheDayPeriod_twentyFourHourUsesHHmm() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 25; c.hour = 16; c.minute = 45; c.timeZone = p5bNY
        let date = Calendar(identifier: .gregorian).date(from: c) ?? p5bNow
        XCTAssertEqual(WPClipClock.bare(date, timeZone: p5bNY, locale: p5bUS), "4:45")
        XCTAssertEqual(WPClipClock.bare(date, timeZone: p5bNY, locale: Locale(identifier: "de_DE")), "16:45")
    }

    // MARK: Copy

    func testCopy_privacyPromiseCoversWhoAndWhere() {
        XCTAssertTrue(WPClipCopy.privacyBody.contains("who you are"))
        XCTAssertTrue(WPClipCopy.privacyBody.contains("where you are"))
    }

    func testCopy_roundTwoWording() {
        XCTAssertEqual(WPClipCopy.headline(name: "Bodega Cat"), "Bodega Cat is waiting for your spot")
        XCTAssertEqual(WPClipCopy.headline(name: nil), "A neighbor is waiting for your spot")
        XCTAssertEqual(WPClipCopy.chipTitle(.minutes(10)), "About 10 min")
        XCTAssertEqual(WPClipCopy.chipTitle(.minutes(60)), "About 1 hour")
        XCTAssertEqual(WPClipCopy.tell(name: "Bodega Cat"), "Tell Bodega Cat")
        XCTAssertEqual(WPClipCopy.reminderOnly, "That's the only notification you'll get.")
        XCTAssertEqual(WPClipCopy.reminderTitle(around: "4:45"), "Still leaving around 4:45?")
        XCTAssertFalse(WPClipCopy.thanksTitle.contains("!"))
    }
}

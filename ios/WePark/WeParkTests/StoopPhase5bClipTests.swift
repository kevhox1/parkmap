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
        XCTAssertEqual(WPClipCopy.allowReminder, "Remind me once")
        XCTAssertEqual(WPClipCopy.reminderTitle(around: "4:45"), "Still leaving around 4:45?")
        XCTAssertFalse(WPClipCopy.thanksTitle.contains("!"))
    }

    // MARK: Reminder copy matches the reminder plan

    func testReminderCopy_isTrueForEveryPath() {
        let copy = WPClipCopy.reminderOnly
        XCTAssertTrue(copy.contains("one reminder"))
        XCTAssertTrue(copy.contains("5 more min"), "the snooze reminder must be disclosed")
        XCTAssertTrue(copy.contains("says thanks"), "the backend thanks alert must be disclosed")
        XCTAssertFalse(copy.lowercased().contains("only notification"))
        XCTAssertTrue(WPClipCopy.snoozeHint.contains("reminds you again"))
    }

    func testReminderPlan_isOneReminder_andSnoozeReplacesIt() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let leave = now.addingTimeInterval(20 * 60)
        let first = HandoffReminderPlan.plan(stoop: true, passID: id, name: "Bodega Cat", leaveAt: leave, expiresAt: leave.addingTimeInterval(15 * 60), now: now)
        XCTAssertEqual(first.count, 1, "copy says one reminder")
        // "5 more min": the controller reschedules for leave + 5 min. Same identifier, so it replaces the
        // pending one; a snooze after the first fired is the one extra reminder the copy discloses.
        let later = leave.addingTimeInterval(5 * 60)
        let snoozed = HandoffReminderPlan.plan(stoop: true, passID: id, name: "Bodega Cat", leaveAt: later, expiresAt: later.addingTimeInterval(15 * 60), now: now)
        XCTAssertEqual(snoozed.count, 1)
        XCTAssertEqual(snoozed.first?.identifier, first.first?.identifier)
    }
}

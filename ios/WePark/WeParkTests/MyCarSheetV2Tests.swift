//
//  MyCarSheetV2Tests.swift
//  WeParkTests
//
//  Pure-helper tests for the redesigned My Car sheet (`MyCarSheetV2Logic`): the "Next: ..."
//  plain-English line, sign dedupe, reminder summary, header lines, and the flag-off variant
//  resolution (legacy stays the default).
//

import XCTest
@testable import WePark

final class MyCarSheetV2Tests: XCTestCase {

    // MARK: - Fixtures (prefixed to avoid XCTestCase-extension name shadowing across files)

    private func v2Rule(
        _ category: WePark.Category,
        description: String = "",
        days: [Int] = [],
        ranges: [(Int, Int)] = [],
        anytime: Bool = false,
        arrow: String? = "both"
    ) -> ParkingRule {
        ParkingRule(
            category: category,
            description: description,
            days: days,
            timeRanges: ranges.map { TimeRange(start: $0.0, end: $0.1) },
            anytime: anytime,
            arrow: arrow
        )
    }

    private func v2Next(_ rule: ParkingRule?, hours: Double) -> NextRestriction {
        NextRestriction(hours: hours, label: rule == nil ? nil : "x", category: rule?.category, rule: rule)
    }

    // MARK: - Flag / variant

    func testFlag_defaultsFalse_andResolvesLegacy() {
        XCTAssertFalse(AppConstants.myCarSheetV2Enabled)
        XCTAssertEqual(MyCarSheetVariant.resolve(), .legacy)
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: false), .legacy)
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: true), .v2)
    }

    func testLeaveButton_opensSheetOnlyWhenThereAreHandoffOptions() {
        XCTAssertFalse(MyCarSheetV2Logic.leaveButtonOpensSheet(communityEnabled: false, spotPassAvailable: false))
        XCTAssertTrue(MyCarSheetV2Logic.leaveButtonOpensSheet(communityEnabled: true, spotPassAvailable: false))
        XCTAssertTrue(MyCarSheetV2Logic.leaveButtonOpensSheet(communityEnabled: false, spotPassAvailable: true))
        XCTAssertTrue(MyCarSheetV2Logic.leaveButtonOpensSheet(communityEnabled: true, spotPassAvailable: true))
    }

    // MARK: - Rule wording

    func testPlainRule_streetCleaning() {
        let rule = v2Rule(.aspMonThu, days: [1, 4], ranges: [(540, 630)])
        XCTAssertEqual(MyCarSheetV2Logic.plainRule(rule), "street cleaning Mon & Thu 9\u{2013}10:30 AM")
    }

    func testPlainRule_streetCleaning_noExplicitDays_usesCategoryDays() {
        let rule = v2Rule(.aspTueFri, days: [], ranges: [(480, 570)])
        XCTAssertEqual(MyCarSheetV2Logic.plainRule(rule), "street cleaning Tue & Fri 8\u{2013}9:30 AM")
    }

    func testPlainRule_noParkingWeekdays() {
        let rule = v2Rule(.noParking, days: [1, 2, 3, 4, 5], ranges: [(480, 1080)])
        XCTAssertEqual(MyCarSheetV2Logic.plainRule(rule), "no parking 8 AM\u{2013}6 PM weekdays")
    }

    func testPlainRule_anytime() {
        XCTAssertEqual(
            MyCarSheetV2Logic.plainRule(v2Rule(.noStanding, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)),
            "no standing at all times"
        )
    }

    func testDayPhrase() {
        XCTAssertEqual(MyCarSheetV2Logic.dayPhrase([1, 4]), "Mon & Thu")
        XCTAssertEqual(MyCarSheetV2Logic.dayPhrase([1, 2, 3, 4, 5, 6]), "Mon\u{2013}Sat")
        XCTAssertEqual(MyCarSheetV2Logic.dayPhrase([1, 3, 5]), "Mon, Wed & Fri")
        XCTAssertEqual(MyCarSheetV2Logic.dayPhrase([0, 6]), "weekends")
        XCTAssertEqual(MyCarSheetV2Logic.dayPhrase([]), "daily")
    }

    func testClock() {
        XCTAssertEqual(MyCarSheetV2Logic.clock(0), "12 AM")
        XCTAssertEqual(MyCarSheetV2Logic.clock(720), "12 PM")
        XCTAssertEqual(MyCarSheetV2Logic.clock(1140), "7 PM")
        XCTAssertEqual(MyCarSheetV2Logic.clock(630), "10:30 AM")
        XCTAssertEqual(MyCarSheetV2Logic.clock(545), "9:05 AM")
    }

    // MARK: - Next line

    func testNextLine_upcomingRestriction() {
        let rule = v2Rule(.aspMonThu, days: [1, 4], ranges: [(540, 630)])
        let line = MyCarSheetV2Logic.nextMoveLine(
            restriction: v2Next(rule, hours: 20), rules: [rule], dayOfWeek: 6, minuteOfDay: 600
        )
        XCTAssertEqual(line, "Next: street cleaning Mon & Thu 9\u{2013}10:30 AM")
    }

    func testNextLine_activeNow_saysNow() {
        let rule = v2Rule(.noParking, days: [1, 2, 3, 4, 5], ranges: [(480, 1080)])
        let line = MyCarSheetV2Logic.nextMoveLine(
            restriction: v2Next(rule, hours: 0), rules: [rule], dayOfWeek: 2, minuteOfDay: 600
        )
        XCTAssertEqual(line, "Now: no parking 8 AM\u{2013}6 PM weekdays")
    }

    func testNextLine_meterOnly_meterUntil() {
        let meter = v2Rule(.metered, days: [1, 2, 3, 4, 5, 6], ranges: [(540, 1140)])
        let line = MyCarSheetV2Logic.nextMoveLine(
            restriction: v2Next(nil, hours: 168), rules: [meter], dayOfWeek: 3, minuteOfDay: 780
        )
        XCTAssertEqual(line, "Now: meter until 7 PM")
    }

    func testNextLine_nothingToSay_isNil() {
        let meter = v2Rule(.metered, days: [1], ranges: [(540, 1140)])
        XCTAssertNil(MyCarSheetV2Logic.nextMoveLine(
            restriction: v2Next(nil, hours: 168), rules: [meter], dayOfWeek: 0, minuteOfDay: 780
        ))
        XCTAssertNil(MyCarSheetV2Logic.nextMoveLine(
            restriction: v2Next(nil, hours: 168), rules: [], dayOfWeek: 0, minuteOfDay: 0
        ))
    }

    // MARK: - Dedupe

    func testDedupedRules_collapsesIdenticalSigns() {
        let a = v2Rule(.aspMonThu, description: "NO PARKING (SANITATION BROOM SYMBOL) 8-9:30AM MON & THUR", days: [1, 4], ranges: [(480, 570)], arrow: "towards")
        let b = v2Rule(.aspMonThu, description: "no parking  (sanitation broom symbol) 8-9:30am mon & thur", days: [4, 1], ranges: [(480, 570)], arrow: "away")
        let c = v2Rule(.metered, description: "1 HR METERED PARKING", days: [1], ranges: [(540, 1140)])
        let result = MyCarSheetV2Logic.dedupedRules([a, b, c])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.category, .aspMonThu)
        XCTAssertEqual(result.last?.category, .metered)
    }

    func testSignText_isFullText_notTruncated() {
        let long = "NO PARKING (SANITATION BROOM SYMBOL) 8:30AM-10AM MON & THURS EXCEPT SUNDAY"
        XCTAssertEqual(MyCarSheetV2Logic.signText(v2Rule(.aspMonThu, description: long)), long)
    }

    func testSignText_blankDescription_generatesLine() {
        let rule = v2Rule(.noParking, days: [1, 2, 3, 4, 5], ranges: [(480, 1080)])
        XCTAssertEqual(MyCarSheetV2Logic.signText(rule), "No parking 8 AM\u{2013}6 PM weekdays")
    }

    // MARK: - Reminder summary

    func testReminderSummary_off() {
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: false, offsets: .default), "Reminders off")
    }

    func testReminderSummary_leadPlusNightBefore() {
        let offsets = ReminderOffsets(
            remind15Min: true, remind30Min: false, remind1Hour: false, remind2Hours: false, remindNightBefore: true
        )
        XCTAssertEqual(
            MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: offsets),
            "15 min before + night before"
        )
    }

    func testReminderSummary_multipleLeads_sameUnit() {
        let offsets = ReminderOffsets(
            remind15Min: true, remind30Min: true, remind1Hour: false, remind2Hours: false, remindNightBefore: false
        )
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: offsets), "15 & 30 min before")
    }

    func testReminderSummary_mixedUnits() {
        let offsets = ReminderOffsets(
            remind15Min: true, remind30Min: false, remind1Hour: true, remind2Hours: false, remindNightBefore: false
        )
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: offsets), "15 min & 1 hr before")
    }

    func testReminderSummary_nightOnly_andDefault_andNone() {
        let night = ReminderOffsets(
            remind15Min: false, remind30Min: false, remind1Hour: false, remind2Hours: false, remindNightBefore: true
        )
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: night), "Night before")
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: .default), "1 hr before")
        let none = ReminderOffsets(
            remind15Min: false, remind30Min: false, remind1Hour: false, remind2Hours: false, remindNightBefore: false
        )
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: none), "Pick a time")
    }

    func testReminderSummary_communityOff_collapsesToOn() {
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: true, offsets: .default, showDetail: false), "On")
        XCTAssertEqual(MyCarSheetV2Logic.reminderSummary(remindMe: false, offsets: .default, showDetail: false), "Reminders off")
    }

    // MARK: - Header lines

    func testCrossStreetRange() {
        XCTAssertEqual(MyCarSheetV2Logic.crossStreetRange(from: "1st Ave", to: "2nd Ave"), "1st\u{2013}2nd Ave")
        XCTAssertEqual(MyCarSheetV2Logic.crossStreetRange(from: "Hester St", to: "Grand St"), "Hester\u{2013}Grand St")
        XCTAssertEqual(MyCarSheetV2Logic.crossStreetRange(from: "Bowery", to: "Grand St"), "Bowery \u{2013} Grand St")
    }

    func testTitle_addressWins_elseStreetAndSide_elseMyCar() {
        XCTAssertEqual(MyCarSheetV2Logic.title(addressLine: "50 E 1st St", street: "E 1st St", side: "North side"), "50 E 1st St")
        XCTAssertEqual(MyCarSheetV2Logic.title(addressLine: nil, street: "E 1st St", side: "North side"), "E 1st St, North side")
        XCTAssertEqual(MyCarSheetV2Logic.title(addressLine: nil, street: nil, side: nil), "My Car")
    }

    func testSecondaryLine() {
        XCTAssertEqual(
            MyCarSheetV2Logic.secondaryLine(side: "North side", sideInTitle: false, crossStreets: "1st\u{2013}2nd Ave", parkedAgo: "8h ago", hasData: true),
            "North side \u{00B7} 1st\u{2013}2nd Ave \u{00B7} parked 8h ago"
        )
        XCTAssertEqual(
            MyCarSheetV2Logic.secondaryLine(side: "North side", sideInTitle: true, crossStreets: "1st\u{2013}2nd Ave", parkedAgo: "8h ago", hasData: true),
            "1st\u{2013}2nd Ave \u{00B7} parked 8h ago"
        )
        XCTAssertEqual(
            MyCarSheetV2Logic.secondaryLine(side: nil, sideInTitle: false, crossStreets: nil, parkedAgo: "just now", hasData: false),
            "No parking data here \u{00B7} parked just now"
        )
    }
}

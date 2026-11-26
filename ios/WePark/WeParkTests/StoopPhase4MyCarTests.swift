//
//  StoopPhase4MyCarTests.swift
//  WeParkTests
//
//  Stoop Phase 4 (B7 My Car). Pins the accuracy rules of `WPMyCarLogic`:
//    - the verdict is legal only for a readable, legal curb; unclear / no-data never read "Legal"
//    - times come from the engine; midnight is "midnight"; "until Today" never appears
//    - no sub-curb precision claims
//    - reminder previews mirror the scheduler (lead before the start; 8 PM ET the evening before),
//      skip reminders already in the past, and never promise one that cannot fire
//    - the suspension note only claims what applies to this curb
//    - variant resolution: Stoop needs both flags; flag off stays legacy
//

import XCTest
@testable import WePark

final class StoopPhase4MyCarTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: Fixtures (private names: no collision with other test files)

    private func p4Date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = .easternTime
        return Calendar.easternTime.date(from: c) ?? Date.distantPast
    }

    private func p4Rule(
        _ category: WePark.Category, days: [Int] = [], ranges: [(Int, Int)] = [], anytime: Bool = false,
        arrow: String = "both"
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": "", "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": arrow,
        ]
    }

    private func p4Segment(_ rules: [[String: Any]]) -> Segment {
        let dict: [String: Any] = [
            "id": "P4T", "street": "EAST 1ST STREET", "from": "1 AVENUE", "to": "2 AVENUE",
            "side": "N", "line": [[40.7236, -73.9889], [40.7240, -73.9880]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private let everyDay = [0, 1, 2, 3, 4, 5, 6]

    /// Street cleaning Mon and Thu 9:00 to 10:30 AM.
    private var sweepMonThu: [String: Any] { p4Rule(.aspMonThu, days: [1, 4], ranges: [(540, 630)]) }

    private func verdict(_ rules: [[String: Any]], _ now: Date) -> WPMyCarVerdict {
        WPMyCarLogic.verdict(segment: p4Segment(rules), engine: engine, now: now)
    }

    // MARK: Variant

    func testVariant_stoopNeedsBothFlags_flagOffStaysLegacy() {
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: false, designSystemEnabled: false), .legacy)
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: false, designSystemEnabled: true), .legacy)
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: true, designSystemEnabled: false), .v2)
        XCTAssertEqual(MyCarSheetVariant.resolve(v2Enabled: true, designSystemEnabled: true), .stoop)
        XCTAssertEqual(MyCarSheetVariant.resolve(), .legacy, "both flags ship dark")
    }

    // MARK: Verdict

    func testVerdict_legal_isLegalUntilTheNextRestriction() {
        // Sat 11/28 10 AM: next street cleaning Mon 11/30 9:00 AM.
        let v = verdict([sweepMonThu], p4Date(2026, 11, 28, 10, 11))
        XCTAssertEqual(v.variant, .park)
        XCTAssertEqual(v.over, "Legal until")
        XCTAssertTrue(v.big.contains("Mon 11/30"), v.big)
        XCTAssertTrue(v.big.contains("9:00"), v.big)
        XCTAssertTrue(v.isLegalNow)
        XCTAssertEqual(v.restrictionStart, p4Date(2026, 11, 30, 9, 0))
        XCTAssertEqual(v.restrictionName, "street cleaning")
        XCTAssertEqual(v.primaryTitle, "I left")
    }

    func testVerdict_soon_isMoveBy_withoutTheWordToday() {
        // Tue 12/1 8:11 AM, street cleaning Tue 9:00.
        let v = verdict([p4Rule(.aspTueFri, days: [2], ranges: [(540, 630)])], p4Date(2026, 12, 1, 8, 11))
        XCTAssertEqual(v.variant, .soon)
        XCTAssertEqual(v.over, "Move by")
        XCTAssertFalse(v.big.contains("Today"), v.big)
        XCTAssertTrue(v.big.contains("9:00"), v.big)
        XCTAssertTrue(v.isLegalNow)
    }

    func testVerdict_dont_isMoveYourCarNow_andReadsCleanly() {
        let v = verdict([p4Rule(.aspTueFri, days: [2], ranges: [(420, 630)])], p4Date(2026, 12, 1, 9, 48))
        XCTAssertEqual(v.variant, .dont)
        XCTAssertEqual(v.over, "Move your car now")
        XCTAssertEqual(v.big, "No parking")
        XCTAssertFalse(v.sub?.contains("until Today") ?? false, v.sub ?? "")
        XCTAssertTrue(v.sub?.contains("10:30") ?? false, v.sub ?? "")
        XCTAssertFalse(v.isLegalNow)
        XCTAssertEqual(v.primaryTitle, "I moved it")
        XCTAssertFalse(v.offersReminders, "the scheduler never reminds about a restriction already in force")
    }

    func testVerdict_meterRunning_isPayTheMeter_neverLegal() {
        let v = verdict([p4Rule(.metered, days: everyDay, ranges: [(480, 1140)])], p4Date(2026, 12, 1, 16, 40))
        XCTAssertEqual(v.variant, .meter)
        XCTAssertEqual(v.over, "Pay the meter until")
        XCTAssertFalse(v.isLegalNow)
    }

    func testVerdict_meterStartingLater_isMeterStarts_notMoveBy() {
        // 8:11 AM, meter 10 AM to 7 PM, nothing else: legal now, the meter starts at 10.
        let v = verdict([p4Rule(.metered, days: everyDay, ranges: [(600, 1140)])], p4Date(2026, 12, 1, 8, 11))
        XCTAssertEqual(v.variant, .soon)
        XCTAssertEqual(v.over, "Meter starts")
        XCTAssertTrue(v.big.contains("10:00"), v.big)
    }

    func testVerdict_noData_andNoSegment_neverLegal() {
        let now = p4Date(2026, 12, 1, 10, 11)
        let none = verdict([], now)
        XCTAssertEqual(none.variant, .nodata)
        XCTAssertEqual(none.big, "No sign data")
        XCTAssertFalse(none.isLegalNow)
        XCTAssertFalse(none.offersReminders)

        let missing = WPMyCarLogic.verdict(segment: nil, engine: engine, now: now)
        XCTAssertEqual(missing.variant, .nodata)
        XCTAssertFalse(missing.isLegalNow)
    }

    func testVerdict_unclearSign_saysCheckThePostedSign_neverLegal() {
        let v = verdict([p4Rule(.unknown, anytime: true)], p4Date(2026, 12, 1, 10, 11))
        XCTAssertEqual(v.variant, .unclear)
        XCTAssertEqual(v.big, "Check the posted sign")
        XCTAssertFalse(v.isLegalNow)
        XCTAssertFalse(v.offersReminders)
        XCTAssertFalse((v.over + v.big + (v.sub ?? "")).lowercased().contains("legal"))
    }

    func testVerdict_midnightIsSpelledOut() {
        // No parking every day from midnight to 1 AM: from 10 AM the next restriction starts at midnight.
        let v = verdict([p4Rule(.noParking, days: everyDay, ranges: [(0, 60)])], p4Date(2026, 12, 1, 10, 11))
        XCTAssertTrue(v.big.contains("midnight"), v.big)
        XCTAssertFalse(v.big.contains("12:00 AM"), v.big)
    }

    func testVerdict_arrowSign_makesNoSubCurbClaim_andNeverGreen() {
        let v = verdict([p4Rule(.noStanding, anytime: true, arrow: "towards")], p4Date(2026, 12, 1, 10, 11))
        XCTAssertFalse(v.isLegalNow, "an arrow-limited restriction never turns the verdict green")
        let text = (v.over + " " + v.big + " " + (v.sub ?? "")).lowercased()
        XCTAssertFalse(text.contains("20 ft"))
        XCTAssertFalse(text.contains("past it"))
        let lines = WPSignList.lines(for: p4Segment([p4Rule(.noStanding, anytime: true, arrow: "towards")]), engine: engine, now: p4Date(2026, 12, 1, 10, 11))
        XCTAssertEqual(lines.first?.plain, WPSignList.arrowLine)
    }

    func testVerdict_neighborReportCanOnlyMakeItStricter() {
        let reports = WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: true)
        let legal = WPMyCarLogic.verdict(
            segment: p4Segment([sweepMonThu]), engine: engine, now: p4Date(2026, 11, 28, 10, 11), reports: reports
        )
        XCTAssertEqual(legal.variant, .dont)
        XCTAssertEqual(legal.over, "Neighbors say")
        XCTAssertFalse(legal.isLegalNow)
        // An already-red or no-data curb stays as the signs say.
        let nodata = WPMyCarLogic.verdict(segment: p4Segment([]), engine: engine, now: p4Date(2026, 11, 28, 10, 11), reports: reports)
        XCTAssertEqual(nodata.variant, .nodata)
    }

    // MARK: Header

    func testTitle_addressFirst_thenStreet_thenMyCar() {
        XCTAssertEqual(WPMyCarLogic.title(addressLine: "In front of 50 E 1st St", street: "E 1st St"), "In front of 50 E 1st St")
        XCTAssertEqual(WPMyCarLogic.title(addressLine: nil, street: "Extra Pl"), "On Extra Pl")
        XCTAssertEqual(WPMyCarLogic.title(addressLine: "", street: nil), "My car")
    }

    func testParkedLine() {
        let now = p4Date(2026, 12, 1, 12, 0)
        XCTAssertEqual(WPMyCarLogic.parkedLine(parkedAt: now.addingTimeInterval(-20), now: now), "Parked just now")
        XCTAssertEqual(WPMyCarLogic.parkedLine(parkedAt: now.addingTimeInterval(-12 * 60), now: now), "Parked 12 min ago")
        XCTAssertEqual(WPMyCarLogic.parkedLine(parkedAt: now.addingTimeInterval(-3 * 3600 - 600), now: now), "Parked 3 h ago")
        XCTAssertEqual(WPMyCarLogic.parkedLine(parkedAt: now.addingTimeInterval(-26 * 3600), now: now), "Parked 1 day ago")
        XCTAssertEqual(WPMyCarLogic.parkedLine(parkedAt: now.addingTimeInterval(-50 * 3600), now: now), "Parked 2 days ago")
    }

    // MARK: Reminders

    private var allOffsets: ReminderOffsets {
        ReminderOffsets(
            remind15Min: true, remind30Min: true, remind1Hour: true, remind2Hours: true, remindNightBefore: true
        )
    }

    func testReminderPreviews_everyOption_matchTheSchedulerArithmetic() {
        let start = p4Date(2026, 11, 30, 9, 0)
        let now = p4Date(2026, 11, 28, 10, 0)
        let previews = WPMyCarLogic.reminderPreviews(offsets: allOffsets, restrictionStart: start, now: now)
        XCTAssertEqual(previews.map(\.kind), [.nightBefore, .hours2, .hour1, .minutes30, .minutes15])
        XCTAssertEqual(previews.map(\.fireDate), [
            p4Date(2026, 11, 29, 20, 0),
            p4Date(2026, 11, 30, 7, 0),
            p4Date(2026, 11, 30, 8, 0),
            p4Date(2026, 11, 30, 8, 30),
            p4Date(2026, 11, 30, 8, 45),
        ])
    }

    func testReminderPreviews_skipRemindersAlreadyInThePast() {
        let start = p4Date(2026, 12, 1, 9, 0)
        let now = p4Date(2026, 12, 1, 8, 11)
        let previews = WPMyCarLogic.reminderPreviews(offsets: allOffsets, restrictionStart: start, now: now)
        // Only 30 and 15 minutes before are still ahead (8:30, 8:45).
        XCTAssertEqual(previews.map(\.kind), [.minutes30, .minutes15])
    }

    func testNightBefore_isEightPMWallClock_acrossDST() {
        // Restriction Sun 3/14/2027 9 AM (spring-forward day): night before is Sat 3/13 8 PM EST.
        let night = WPMyCarLogic.nightBeforeDate(relativeTo: p4Date(2027, 3, 14, 9, 0))
        XCTAssertEqual(night, p4Date(2027, 3, 13, 20, 0))
        XCTAssertEqual(night?.minuteOfDayET, AppConstants.nightBeforeHourET * 60)
        // Fall-back day.
        XCTAssertEqual(WPMyCarLogic.nightBeforeDate(relativeTo: p4Date(2026, 11, 1, 9, 0)), p4Date(2026, 10, 31, 20, 0))
    }

    func testReminderSummary_countsOnlyWhatCanFire() {
        let start = p4Date(2026, 11, 30, 9, 0)
        let now = p4Date(2026, 11, 28, 10, 0)
        let two = WPMyCarLogic.reminderPreviews(
            offsets: ReminderOffsets(remind15Min: false, remind30Min: false, remind1Hour: true, remind2Hours: false, remindNightBefore: true),
            restrictionStart: start, now: now
        )
        let text = WPMyCarLogic.reminderSummary(previews: two, now: now).replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(text.hasPrefix("You'll get 2 reminders:"), text)
        XCTAssertTrue(text.contains("8:00 PM"), text)
        XCTAssertTrue(text.contains("8:00 AM"), text)

        let none = WPMyCarLogic.reminderSummary(previews: [], now: now)
        XCTAssertTrue(none.hasPrefix("No reminder is left"), none)
        XCTAssertEqual(WPMyCarLogic.reminderRowSub(remindMe: false, previews: two, now: now), "Off")
        XCTAssertEqual(WPMyCarLogic.reminderRowSub(remindMe: true, previews: [], now: now), "No reminder time left before it changes")
        XCTAssertTrue(WPMyCarLogic.reminderRowSub(remindMe: true, previews: two, now: now).hasPrefix("Next one:"))
    }

    func testOffersReminders_onlyWhenAFutureRestrictionExists() {
        let now = p4Date(2026, 11, 28, 10, 0)
        XCTAssertTrue(verdict([sweepMonThu], now).offersReminders)
        // A curb whose only rule is a meter has no non-meter restriction to remind about.
        XCTAssertFalse(verdict([p4Rule(.metered, days: everyDay, ranges: [(600, 1140)])], now).offersReminders)
    }

    // MARK: Suspension note

    func testSuspensionNote_onlyWhenItAppliesToThisCurb() {
        let wed = p4Date(2026, 11, 25, 10, 0)
        let tomorrow = SuspensionBannerState.tomorrowSuspended(reason: "Thanksgiving")
        let note = WPMyCarLogic.suspensionNote(segment: p4Segment([sweepMonThu]), state: tomorrow, now: wed)
        XCTAssertEqual(note, "Street cleaning is suspended tomorrow for Thanksgiving. You don't have to move the car Thursday.")
        // Street cleaning Tue/Fri does not run Thursday: no claim.
        XCTAssertNil(WPMyCarLogic.suspensionNote(
            segment: p4Segment([p4Rule(.aspTueFri, days: [2, 5], ranges: [(540, 630)])]), state: tomorrow, now: wed))
        // No street cleaning on this curb at all: no claim.
        XCTAssertNil(WPMyCarLogic.suspensionNote(
            segment: p4Segment([p4Rule(.metered, days: everyDay, ranges: [(480, 1140)])]), state: tomorrow, now: wed))
        XCTAssertNil(WPMyCarLogic.suspensionNote(segment: nil, state: tomorrow, now: wed))
        XCTAssertNil(WPMyCarLogic.suspensionNote(segment: p4Segment([sweepMonThu]), state: .aspInEffect, now: wed))
    }

    // MARK: Wording helpers

    func testShort_dropsOnlyALeadingToday() {
        XCTAssertEqual(WPMyCarLogic.short("Today 9:00 AM"), "9:00 AM")
        XCTAssertEqual(WPMyCarLogic.short("Today midnight"), "midnight")
        XCTAssertEqual(WPMyCarLogic.short("Tomorrow 7:00 AM"), "Tomorrow 7:00 AM")
        XCTAssertEqual(WPMyCarLogic.short("Mon 11/30 9:00 AM"), "Mon 11/30 9:00 AM")
    }
}

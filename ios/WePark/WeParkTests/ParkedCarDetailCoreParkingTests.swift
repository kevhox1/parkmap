//
//  ParkedCarDetailCoreParkingTests.swift
//  WeParkTests
//
//  Open-items #16 (core-parking-16 session, 2026-09-11). Spec: docs/open-items.md #16.
//
//  Tests target `ParkedCarDetailLogic`'s three NEW, NOT-community-flagged pure functions —
//  the status-line wording, the rules-collapse threshold, and the ASP-suspension-note
//  scoping/wording — extracted from `ParkedCarDetailView.swift` so they're unit-testable
//  without mounting a SwiftUI view. Same house style as `ParkedCarDetailPhase4aTests.swift`.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  No Calendar.current use.
//

import XCTest
@testable import WePark

// MARK: - freeUntilStatusText (item 1)

final class ParkedCarDetailFreeUntilStatusTextTests: XCTestCase {

    private func makeRule(category: Category) -> ParkingRule {
        ParkingRule(
            category: category,
            description: "",
            days: [1, 4],
            timeRanges: [TimeRange(start: 480, end: 570)],
            anytime: false,
            arrow: "both"
        )
    }

    func testActiveNow_reusesRestrictionLabelVerbatim() {
        let restriction = NextRestriction(
            hours: 0,
            label: "ASP Mon/Thu active now",
            category: .aspMonThu,
            rule: makeRule(category: .aspMonThu)
        )
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(restriction: restriction, timeLabel: "unused"),
            "ASP Mon/Thu active now"
        )
    }

    func testActiveNow_nilLabel_fallsBackToRestrictedNow() {
        // Defensive case: NextRestriction.label is optional even when isActiveNow is true.
        let restriction = NextRestriction(hours: 0, label: nil, category: .noStanding, rule: nil)
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(restriction: restriction, timeLabel: "unused"),
            "Restricted now"
        )
    }

    func testUnrestricted_sentinelHours_returnsNoRestrictionsHere() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(restriction: restriction, timeLabel: "unused"),
            "Free \u{2014} no restrictions here"
        )
    }

    func testUpcomingRestriction_returnsFreeUntilWithCallersTimeLabel() {
        let restriction = NextRestriction(
            hours: 5.5,
            label: "ASP Mon/Thu",
            category: .aspMonThu,
            rule: makeRule(category: .aspMonThu)
        )
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(restriction: restriction, timeLabel: "Thursday 9:30 AM"),
            "Free until Thursday 9:30 AM"
        )
    }

    func testUpcomingRestriction_noParkingCategory_stillUsesFreeUntilFamily() {
        let restriction = NextRestriction(
            hours: 2,
            label: "No Parking",
            category: .noParking,
            rule: makeRule(category: .noParking)
        )
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(restriction: restriction, timeLabel: "Today 7:00 PM"),
            "Free until Today 7:00 PM"
        )
    }
}

// MARK: - shouldCollapseRules (item 2)

final class ParkedCarDetailShouldCollapseRulesTests: XCTestCase {

    func testZeroRules_doesNotCollapse() {
        XCTAssertFalse(ParkedCarDetailLogic.shouldCollapseRules(count: 0))
    }

    func testThreeRules_boundary_doesNotCollapse() {
        XCTAssertFalse(ParkedCarDetailLogic.shouldCollapseRules(count: 3))
    }

    func testFourRules_boundary_collapses() {
        XCTAssertTrue(ParkedCarDetailLogic.shouldCollapseRules(count: 4))
    }

    func testManyRules_collapses() {
        XCTAssertTrue(ParkedCarDetailLogic.shouldCollapseRules(count: 9))
    }
}

// MARK: - segmentHasASPRule + aspSuspensionNote (item 3)

final class ParkedCarDetailASPSuspensionTests: XCTestCase {

    private func makeSegment(rules: [ParkingRule], id: String = "SEG1") -> Segment {
        Segment(
            id: id,
            street: "BOWERY",
            fromStreet: "HESTER STREET",
            to: "GRAND STREET",
            side: "N",
            line: [[40.7183, -73.9942], [40.7190, -73.9940]],
            rules: rules,
            dominantCategory: nil
        )
    }

    private func aspRule() -> ParkingRule {
        ParkingRule(
            category: .aspMonThu,
            description: "NO PARKING 8-9:30AM MON & THUR",
            days: [1, 4],
            timeRanges: [TimeRange(start: 480, end: 570)],
            anytime: false,
            arrow: "both"
        )
    }

    private func noStandingRule() -> ParkingRule {
        ParkingRule(
            category: .noStanding,
            description: "NO STANDING ANYTIME",
            days: [0, 1, 2, 3, 4, 5, 6],
            timeRanges: [],
            anytime: true,
            arrow: "both"
        )
    }

    // MARK: segmentHasASPRule

    func testSegmentHasASPRule_trueWhenAnyRuleIsASP() {
        let seg = makeSegment(rules: [noStandingRule(), aspRule()])
        XCTAssertTrue(ParkedCarDetailLogic.segmentHasASPRule(seg))
    }

    func testSegmentHasASPRule_falseWhenNoASPRule() {
        let seg = makeSegment(rules: [noStandingRule()])
        XCTAssertFalse(ParkedCarDetailLogic.segmentHasASPRule(seg))
    }

    func testSegmentHasASPRule_falseWhenNoRulesAtAll() {
        let seg = makeSegment(rules: [])
        XCTAssertFalse(ParkedCarDetailLogic.segmentHasASPRule(seg))
    }

    // MARK: aspSuspensionNote

    func testASPSuspensionNote_segmentHasASPAndSuspended_returnsBannerCopy() {
        XCTAssertEqual(
            ParkedCarDetailLogic.aspSuspensionNote(segmentHasASPRule: true, suspensionReason: "Memorial Day"),
            "ASP Suspended \u{2014} Memorial Day"
        )
    }

    func testASPSuspensionNote_segmentHasNoASPRule_returnsNilEvenIfSuspendedToday() {
        XCTAssertNil(
            ParkedCarDetailLogic.aspSuspensionNote(segmentHasASPRule: false, suspensionReason: "Memorial Day")
        )
    }

    func testASPSuspensionNote_notSuspendedToday_returnsNilEvenWithASPRule() {
        XCTAssertNil(
            ParkedCarDetailLogic.aspSuspensionNote(segmentHasASPRule: true, suspensionReason: nil)
        )
    }

    /// End-to-end against the REAL suspension calendar (same known date other tests in this
    /// suite already rely on — `ParkingRulesEngineParityTests`/`W7Tests` both use Memorial Day
    /// 2026-05-25 as a known-suspended fixture date).
    func testASPSuspensionNote_realCalendar_memorialDay_producesExpectedNote() {
        let service = ASPSuspensionService()
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 25
        comps.hour = 12
        comps.timeZone = .easternTime
        guard let memorialDay = Calendar.easternTime.date(from: comps) else {
            XCTFail("failed to build fixture date")
            return
        }
        let reason = service.reasonForSuspension(memorialDay)
        XCTAssertNotNil(reason, "Memorial Day 2026 should be a known suspension date")
        let note = ParkedCarDetailLogic.aspSuspensionNote(segmentHasASPRule: true, suspensionReason: reason)
        XCTAssertEqual(note, "ASP Suspended \u{2014} \(reason ?? "")")
    }

    func testASPSuspensionNote_realCalendar_regularDay_returnsNil() {
        let service = ASPSuspensionService()
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 10
        comps.hour = 12
        comps.timeZone = .easternTime
        guard let regularDay = Calendar.easternTime.date(from: comps) else {
            XCTFail("failed to build fixture date")
            return
        }
        let reason = service.reasonForSuspension(regularDay)
        let note = ParkedCarDetailLogic.aspSuspensionNote(segmentHasASPRule: true, suspensionReason: reason)
        XCTAssertNil(note)
    }
}

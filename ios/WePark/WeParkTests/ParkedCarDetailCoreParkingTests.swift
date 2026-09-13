//
//  ParkedCarDetailCoreParkingTests.swift
//  WeParkTests
//
//  Open-items #16 (core-parking-16 session, 2026-09-11). Spec: docs/open-items.md #16.
//
//  Tests target `ParkedCarDetailLogic`'s NEW, NOT-community-flagged pure functions —
//  the status-line wording, the rules-collapse threshold, and the ASP-suspension-note
//  scoping/wording — extracted from `ParkedCarDetailView.swift` so they're unit-testable
//  without mounting a SwiftUI view. Same house style as `ParkedCarDetailPhase4aTests.swift`.
//
//  PR #106 QA Finding #1 fix: `ParkedCarDetailFreeUntilStatusTextTests` below now also covers
//  the metered-only-segment regression (the FT-9 bug class reintroduced at this call site —
//  `nextRestriction` intentionally skips METERED rules, so a metered-only segment used to
//  render "Free — no restrictions here" while the meter was actively charging) plus a mixed
//  ASP+METERED segment integration test against the REAL `ParkingRulesEngine` asserting the
//  ASP-derived line still renders unaffected.
//
//  Open-items #4 (S13c/#106 gate follow-up, polish-19-17b-20 session, 2026-09-12):
//  `ParkedCarDetailShouldSuppressStatusLineTests` below covers the headline/status-line
//  dedupe guard — Kevin's gate observation that "Free until Monday 9:30 AM" (and similar)
//  rendered twice, once as the headline and once as the status line.
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

    private func makeRule(category: WePark.Category) -> ParkingRule {
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
            ParkedCarDetailLogic.freeUntilStatusText(
                restriction: restriction, timeLabel: "unused", meteredStatusLabel: nil
            ),
            "ASP Mon/Thu active now"
        )
    }

    func testActiveNow_nilLabel_fallsBackToRestrictedNow() {
        // Defensive case: NextRestriction.label is optional even when isActiveNow is true.
        let restriction = NextRestriction(hours: 0, label: nil, category: .noStanding, rule: nil)
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(
                restriction: restriction, timeLabel: "unused", meteredStatusLabel: nil
            ),
            "Restricted now"
        )
    }

    func testUnrestricted_noMeteredRule_returnsNoRestrictionsHere() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        XCTAssertEqual(
            ParkedCarDetailLogic.freeUntilStatusText(
                restriction: restriction, timeLabel: "unused", meteredStatusLabel: nil
            ),
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
            ParkedCarDetailLogic.freeUntilStatusText(
                restriction: restriction, timeLabel: "Thursday 9:30 AM", meteredStatusLabel: nil
            ),
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
            ParkedCarDetailLogic.freeUntilStatusText(
                restriction: restriction, timeLabel: "Today 7:00 PM", meteredStatusLabel: nil
            ),
            "Free until Today 7:00 PM"
        )
    }

    // MARK: - PR #106 QA Finding #1: metered-only segment must never claim "no restrictions"

    /// The exact repro from QA's Finding #1: a metered-only segment, meter actively charging
    /// right now. `restriction` is the sentinel (`nextRestriction` skips METERED entirely),
    /// so pre-fix this rendered "Free — no restrictions here" directly under the sheet's
    /// existing headline correctly saying "paid until 7pm". Post-fix: falls back to the
    /// engine's own `meteredStatus` output, stripped of its wrapper.
    func testUnrestricted_meteredOnly_paidNow_returnsStrippedPaidLabel_notFreeClaim() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction,
            timeLabel: "unused",
            meteredStatusLabel: "Metered (paid until 7pm)"
        )
        XCTAssertEqual(text, "paid until 7pm")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("no restrictions"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("free"))
    }

    func testUnrestricted_meteredOnly_freeUntil_returnsStrippedLabel_notUnqualifiedFreeClaim() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction,
            timeLabel: "unused",
            meteredStatusLabel: "Metered (free until 9am)"
        )
        XCTAssertEqual(text, "free until 9am")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("no restrictions"))
    }

    func testUnrestricted_meteredOnly_freeForDays_returnsStrippedLabel() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction,
            timeLabel: "unused",
            meteredStatusLabel: "Metered (free for 2d)"
        )
        XCTAssertEqual(text, "free for 2d")
    }

    func testUnrestricted_meteredOnly_plainFree_returnsStrippedLabel() {
        let restriction = NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction,
            timeLabel: "unused",
            meteredStatusLabel: "Metered (free)"
        )
        XCTAssertEqual(text, "free")
    }

    /// Real-engine integration test (not just the pure-function unit tests above): a
    /// metered-only fixture segment, driven through the ACTUAL `ParkingRulesEngine
    /// .nextRestriction`/`.meteredStatus`/`.nextRestrictionTimeLabel`, exactly as
    /// `ParkedCarDetailView.statusLineView(for:)` calls them. Fails if the metered-only
    /// regression is ever reintroduced at the call site, not just inside the pure function.
    func testRealEngine_meteredOnlySegment_neverClaimsNoRestrictions() {
        let meterRule = ParkingRule(
            category: .metered,
            description: "",
            days: [],
            timeRanges: [TimeRange(start: 480, end: 1140)],  // 8am - 7pm
            anytime: false,
            arrow: "both"
        )
        let seg = Segment(
            id: "SEG_METERED_ONLY",
            street: "5TH AVENUE",
            fromStreet: "42ND STREET",
            to: "43RD STREET",
            side: "E",
            line: [[40.7541, -73.9840], [40.7548, -73.9836]],
            rules: [meterRule],
            dominantCategory: .metered
        )
        let engine = ParkingRulesEngine()
        // Wednesday, 2026-03-11, 12:00 PM ET — inside the 8am-7pm metered window, a regular
        // (non-suspended, non-holiday) weekday.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 11
        comps.hour = 12
        comps.timeZone = .easternTime
        let now = Calendar.easternTime.date(from: comps)!

        let restriction = engine.nextRestriction(for: seg, at: now)
        XCTAssertTrue(restriction.isUnrestricted, "nextRestriction must skip METERED entirely (pre-existing, correct engine semantics) — this is the exact precondition Finding #1 fires on")

        let hasMeteredRule = ParkedCarDetailLogic.segmentHasMeteredRule(seg)
        XCTAssertTrue(hasMeteredRule)
        let meteredStatusLabel = hasMeteredRule ? engine.meteredStatus(for: seg, at: now) : nil
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)

        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction, timeLabel: timeLabel, meteredStatusLabel: meteredStatusLabel
        )

        XCTAssertFalse(
            text.localizedCaseInsensitiveContains("no restrictions"),
            "must never claim 'no restrictions' on a segment whose only rule is METERED — got: \(text)"
        )
        XCTAssertEqual(text, "paid until 7pm")
    }

    /// The sibling case QA explicitly asked for: a segment with BOTH an ASP-family rule AND a
    /// metered rule. The ASP rule is found well within the 14-day window, so
    /// `restriction.isUnrestricted` is `false` and the metered-only fallback above never
    /// triggers — the ASP-derived "Free until <time>" line must still render exactly as
    /// before this fix.
    func testRealEngine_mixedASPAndMeteredSegment_stillRendersASPDerivedFreeUntilLine() {
        let aspRule = ParkingRule(
            category: .aspMonThu,
            description: "NO PARKING 8-9:30AM MON & THUR",
            days: [1, 4],
            timeRanges: [TimeRange(start: 480, end: 570)],
            anytime: false,
            arrow: "both"
        )
        let meterRule = ParkingRule(
            category: .metered,
            description: "",
            days: [],
            timeRanges: [TimeRange(start: 570, end: 1140)],  // 9:30am - 7pm
            anytime: false,
            arrow: "both"
        )
        let seg = Segment(
            id: "SEG_ASP_AND_METERED",
            street: "5TH AVENUE",
            fromStreet: "42ND STREET",
            to: "43RD STREET",
            side: "E",
            line: [[40.7541, -73.9840], [40.7548, -73.9836]],
            rules: [aspRule, meterRule],
            dominantCategory: .aspMonThu
        )
        let engine = ParkingRulesEngine()
        // Wednesday, 2026-03-11, 12:00 PM ET — a regular weekday, well clear of any holiday.
        // The next ASP Mon/Thu occurrence (Thu 2026-03-12, 8:00 AM) is within the 14-day
        // window regardless.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 11
        comps.hour = 12
        comps.timeZone = .easternTime
        let now = Calendar.easternTime.date(from: comps)!

        let restriction = engine.nextRestriction(for: seg, at: now)
        XCTAssertFalse(restriction.isUnrestricted, "the ASP rule must be found within the 14-day window")
        XCTAssertFalse(restriction.isActiveNow)

        let hasMeteredRule = ParkedCarDetailLogic.segmentHasMeteredRule(seg)
        XCTAssertTrue(hasMeteredRule, "fixture sanity check — this segment DOES carry a metered rule")
        let meteredStatusLabel = hasMeteredRule ? engine.meteredStatus(for: seg, at: now) : nil
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)

        let text = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction, timeLabel: timeLabel, meteredStatusLabel: meteredStatusLabel
        )

        XCTAssertTrue(
            text.hasPrefix("Free until "),
            "a mixed ASP+metered segment with an upcoming ASP restriction must still render the ASP-derived line — got: \(text)"
        )
        XCTAssertEqual(text, "Free until \(timeLabel)")
    }
}

// MARK: - stripMeteredWrapper (PR #106 QA Finding #1 fix)

final class ParkedCarDetailStripMeteredWrapperTests: XCTestCase {

    func testPaidUntil_stripsWrapper() {
        XCTAssertEqual(ParkedCarDetailLogic.stripMeteredWrapper("Metered (paid until 7pm)"), "paid until 7pm")
    }

    func testFreeUntil_stripsWrapper() {
        XCTAssertEqual(ParkedCarDetailLogic.stripMeteredWrapper("Metered (free until 9am)"), "free until 9am")
    }

    func testFreeForDays_stripsWrapper() {
        XCTAssertEqual(ParkedCarDetailLogic.stripMeteredWrapper("Metered (free for 2d)"), "free for 2d")
    }

    func testPlainFree_stripsWrapper() {
        XCTAssertEqual(ParkedCarDetailLogic.stripMeteredWrapper("Metered (free)"), "free")
    }

    func testNoWrapper_returnsUnchanged() {
        // Defensive: an input that doesn't match the "Metered (...)" shape passes through.
        XCTAssertEqual(ParkedCarDetailLogic.stripMeteredWrapper("Metered"), "Metered")
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

// MARK: - shouldSuppressStatusLine (open-items #4, 2026-09-12)

final class ParkedCarDetailShouldSuppressStatusLineTests: XCTestCase {

    func testIdenticalText_suppresses() {
        XCTAssertTrue(
            ParkedCarDetailLogic.shouldSuppressStatusLine(
                headlineText: "Free until Monday 9:30 AM",
                statusText: "Free until Monday 9:30 AM"
            )
        )
    }

    func testIdenticalMeteredText_suppresses() {
        XCTAssertTrue(
            ParkedCarDetailLogic.shouldSuppressStatusLine(
                headlineText: "paid until 6pm",
                statusText: "paid until 6pm"
            )
        )
    }

    func testDifferentText_doesNotSuppress() {
        // The mixed ASP+METERED case: headline reflects the active meter, status line
        // reflects the separate upcoming ASP window — must NOT collapse.
        XCTAssertFalse(
            ParkedCarDetailLogic.shouldSuppressStatusLine(
                headlineText: "paid until 7pm",
                statusText: "Free until Thursday 9:30 AM"
            )
        )
    }

    func testSimilarButNotIdenticalText_doesNotSuppress() {
        // Case sensitivity / near-miss guard: this is a literal equality check, not a
        // semantic one — a caller passing near-but-not-identical strings must still see
        // both lines rather than accidentally suppressing on a false match.
        XCTAssertFalse(
            ParkedCarDetailLogic.shouldSuppressStatusLine(
                headlineText: "Free",
                statusText: "Free \u{2014} no restrictions here"
            )
        )
    }

    func testBothEmpty_suppresses() {
        // Defensive/boundary case — not reachable via any real call site, but the equality
        // guard itself has no special-case carve-out for empty strings.
        XCTAssertTrue(ParkedCarDetailLogic.shouldSuppressStatusLine(headlineText: "", statusText: ""))
    }

    /// Real-engine integration test: an ASP-only segment, where the headline
    /// (`engine.safetyLabel`) and the status line (`freeUntilStatusText` fed by
    /// `nextRestriction`) both derive from the SAME upcoming-ASP branch and must produce
    /// byte-identical text — the exact repro Kevin's gate saw duplicated on-screen.
    func testRealEngine_aspOnlySegment_headlineAndStatusLineAreIdentical_mustSuppress() {
        let aspRule = ParkingRule(
            category: .aspMonThu,
            description: "NO PARKING 8-9:30AM MON & THUR",
            days: [1, 4],
            timeRanges: [TimeRange(start: 480, end: 570)],
            anytime: false,
            arrow: "both"
        )
        let seg = Segment(
            id: "SEG_ASP_ONLY",
            street: "5TH AVENUE",
            fromStreet: "42ND STREET",
            to: "43RD STREET",
            side: "E",
            line: [[40.7541, -73.9840], [40.7548, -73.9836]],
            rules: [aspRule],
            dominantCategory: .aspMonThu
        )
        let engine = ParkingRulesEngine()
        // Wednesday, 2026-03-11, 12:00 PM ET — a regular weekday well clear of any holiday;
        // the next ASP Mon/Thu occurrence (Thu 2026-03-12, 8:00 AM) is within the 14-day
        // window, so both derivations land on the same "Free until <timeLabel>" branch.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 11
        comps.hour = 12
        comps.timeZone = .easternTime
        let now = Calendar.easternTime.date(from: comps)!

        let restriction = engine.nextRestriction(for: seg, at: now)
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)
        let statusText = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction, timeLabel: timeLabel, meteredStatusLabel: nil
        )
        let headlineText = engine.safetyLabel(for: seg, at: now).text

        XCTAssertEqual(headlineText, statusText, "fixture sanity check — both must derive the identical string")
        XCTAssertTrue(
            ParkedCarDetailLogic.shouldSuppressStatusLine(headlineText: headlineText, statusText: statusText)
        )
    }

    /// Real-engine integration test: the mixed ASP+METERED segment (same fixture shape as
    /// `ParkedCarDetailFreeUntilStatusTextTests.testRealEngine_mixedASPAndMeteredSegment_stillRendersASPDerivedFreeUntilLine`)
    /// during the actively-metered window — headline says "paid until 7pm", status line says
    /// the separate upcoming-ASP "Free until <time>" line. Must NOT suppress.
    func testRealEngine_mixedASPAndMeteredSegment_activelyMetered_mustNotSuppress() {
        let aspRule = ParkingRule(
            category: .aspMonThu,
            description: "NO PARKING 8-9:30AM MON & THUR",
            days: [1, 4],
            timeRanges: [TimeRange(start: 480, end: 570)],
            anytime: false,
            arrow: "both"
        )
        let meterRule = ParkingRule(
            category: .metered,
            description: "",
            days: [],
            timeRanges: [TimeRange(start: 570, end: 1140)],  // 9:30am - 7pm
            anytime: false,
            arrow: "both"
        )
        let seg = Segment(
            id: "SEG_ASP_AND_METERED_ACTIVE",
            street: "5TH AVENUE",
            fromStreet: "42ND STREET",
            to: "43RD STREET",
            side: "E",
            line: [[40.7541, -73.9840], [40.7548, -73.9836]],
            rules: [aspRule, meterRule],
            dominantCategory: .aspMonThu
        )
        let engine = ParkingRulesEngine()
        // Wednesday, 2026-03-11, 12:00 PM ET — inside the meter's 9:30am-7pm active window.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 3
        comps.day = 11
        comps.hour = 12
        comps.timeZone = .easternTime
        let now = Calendar.easternTime.date(from: comps)!

        let restriction = engine.nextRestriction(for: seg, at: now)
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)
        let hasMeteredRule = ParkedCarDetailLogic.segmentHasMeteredRule(seg)
        let meteredStatusLabel = hasMeteredRule ? engine.meteredStatus(for: seg, at: now) : nil
        let statusText = ParkedCarDetailLogic.freeUntilStatusText(
            restriction: restriction, timeLabel: timeLabel, meteredStatusLabel: meteredStatusLabel
        )
        let headlineText = engine.safetyLabel(for: seg, at: now).text

        XCTAssertEqual(headlineText, "paid until 7pm", "fixture sanity check — meter must be actively charging")
        XCTAssertTrue(statusText.hasPrefix("Free until "), "fixture sanity check — status line must be the ASP-derived line")
        XCTAssertNotEqual(headlineText, statusText)
        XCTAssertFalse(
            ParkedCarDetailLogic.shouldSuppressStatusLine(headlineText: headlineText, statusText: statusText)
        )
    }
}

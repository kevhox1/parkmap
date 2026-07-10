//
//  TF217Tests.swift
//  WeParkTests
//
//  TF2-17: Unit tests for `DrivingContextService.aggregateSideDetail` / `SideAggregation` /
//  `SafetyLabel(for: SideAggregation)` — the "Free until X" chip-copy feature.
//  TF2-18 P1-2 (bundled): additional tests for the `.comingSoon` severity/opportunity tier
//  that was added alongside TF2-17 in the same aggregation refactor.
//
//  Test groups (mirrors the TF2-17 spec §8 Test Inventory numbering in comments):
//    A. aggregateSideDetail — earliest-restriction ranking (spec items 1–9)
//    B. SafetyLabel(for: SideAggregation) bridge (spec items 10–14, + TF2-18 comingSoon cases)
//    C. Voice regression — text-change and comingSoon severity are both voice-invisible
//       (spec item 15, extended for TF2-18)
//    D. TF2-18 P1-2 — comingSoon threshold / boundary tests (not in the original TF2-17
//       spec's inventory, added because P1-2 was bundled into this same PR)
//
//  Segment fixtures reuse `tf27MakeSeg` from TF27Tests.swift (same test target, internal
//  visibility) for length-controllable single-rule segments, and the `rule(...)`/
//  `makeSegment(...)` XCTestCase extension helpers from ParkingRulesEngineParityTests.swift
//  for the FT-9 regression test (needs a segment with TWO rules — metered + ASP).
//
//  No Calendar.current.
//  No import SwiftUI (service/model tests must not import SwiftUI per QA invariant).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixture helpers

/// Fixed test date: Wednesday 8 AM ET (2026-01-07). Matches TF27Tests.swift's private
/// `tf27TestDate` fixture in shape, redefined here (that one is file-private) with the same
/// value for consistency across the two aggregation test files.
private var tf217TestDate: Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 1
    comps.day = 7   // Wednesday
    comps.hour = 8
    comps.minute = 0
    comps.second = 0
    comps.timeZone = TimeZone(identifier: "America/New_York")
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

// MARK: - A. aggregateSideDetail — earliest-restriction ranking

final class AggregateSideDetailTests: XCTestCase {

    let engine = ParkingRulesEngine()

    // Test 1: single free segment with an upcoming No Parking restriction (~20h away) →
    // text byte-identical to engine.safetyLabel(for:).text. AC-5.
    func testAggregateSideDetail_singleFreeSegmentWithUpcomingRestriction_returnsFreeUntilText() {
        // 20h from Wed 8am ET = Thu 4:00am. Same-day minute-of-day 240 (4am) with all-days
        // rule.days means offset=0 is skipped (240 < currentMinutes 480) so this resolves to
        // "tomorrow 4am" — exactly 20h away.
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 240, end: 270)]
        )
        let expectedText = engine.safetyLabel(for: seg, at: tf217TestDate).text
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .free)
        XCTAssertEqual(result.earliestFreeUntilText, expectedText)
    }

    // Test 2: two qualifying free segments, restrictions at 2h and 6h → text reflects the
    // 2h (earliest) one. AC-6 (conservative-min).
    func testAggregateSideDetail_multipleFreeSegments_earliestRestrictionWins() {
        // 2h away: 10:00am (minute 600).
        let soonSeg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 600, end: 630)]
        )
        // 6h away exactly: 2:00pm (minute 840) — deliberately at the comingSoon boundary
        // (not < 6h) so this segment stays .free on its own; picked to make the "earliest
        // wins" assertion unambiguous regardless of the boundary rule.
        let laterSeg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 840, end: 870)]
        )
        let expectedText = engine.safetyLabel(for: soonSeg, at: tf217TestDate).text
        let result = DrivingContextService.aggregateSideDetail(
            segments: [soonSeg, laterSeg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.earliestFreeUntilText, expectedText, "Earliest (2h) restriction's text should win over the 6h one")
    }

    // Test 3: all qualifying free segments have no restriction within 14 days →
    // earliestFreeUntilText is nil, SafetyLabel bridge renders "Free — check signs". OQ-1/AC-7.
    func testAggregateSideDetail_allFreeSegmentsUnrestricted_returnsNilText() {
        let seg = tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0)
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .free)
        XCTAssertNil(result.earliestFreeUntilText)
        XCTAssertEqual(SafetyLabel(for: result).text, "Free — check signs")
    }

    // Test 4: a metered-free segment ("free until 10am" via meteredStatus, meter not yet
    // charging) is excluded from the ranking — nextRestriction() skips METERED rules
    // entirely (OQ-3), so this segment alone falls back to "Free — check signs".
    func testAggregateSideDetail_meteredFreeSegmentOnly_excludedFromRanking_fallsBackToCheckSigns() {
        // Meter charges 10am–8pm; at 8am test time it's not yet running → "free until 10am".
        let seg = tf27MakeSeg(
            side: "N", category: .metered, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 600, end: 1200)]
        )
        // Sanity: confirm the engine really does classify this .free (not .metered) at test time.
        let engineLabel = engine.safetyLabel(for: seg, at: tf217TestDate)
        XCTAssertEqual(engineLabel.severity, .free, "Precondition: metered-free segment must be severity .free before paid hours start")

        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .free)
        XCTAssertNil(result.earliestFreeUntilText, "Metered-free segment must not supply the ranking text (OQ-3)")
    }

    // Test 5: mixed free + restricted segments on the same side — still resolves .free with
    // the free segment's text (TF2-7 precedence unchanged). AC-9.
    func testAggregateSideDetail_mixedFreeAndRestrictedSegments_stillReturnsFreeWithText() {
        let freeSeg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 240, end: 270)]  // ~20h away
        )
        let restrictedSeg = tf27MakeSeg(side: "N", category: .noStanding, lengthMeters: 15.0)  // anytime, active now
        let expectedText = engine.safetyLabel(for: freeSeg, at: tf217TestDate).text

        let result = DrivingContextService.aggregateSideDetail(
            segments: [freeSeg, restrictedSeg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .free)
        XCTAssertEqual(result.earliestFreeUntilText, expectedText)
    }

    // Test 6: a sub-6m free sliver with an EARLIER restriction must not win the ranking over
    // a qualifying (>=6m) segment with a LATER restriction — length-gating happens before
    // ranking, matching pre-TF2-17 `aggregateSide` behavior.
    func testAggregateSideDetail_subMinimumFreeSegment_excludedFromRanking() {
        // Sub-minimum (4m) segment, restriction 1h away — would win the ranking if it were
        // eligible, but it's excluded by the 6m length gate before ranking even runs.
        let tinySeg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 4.0,
            timeRanges: [TimeRange(start: 540, end: 570)]  // 1h away (9:00am)
        )
        // Qualifying (10m) segment, restriction ~20h away.
        let qualifyingSeg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 240, end: 270)]
        )
        let expectedText = engine.safetyLabel(for: qualifyingSeg, at: tf217TestDate).text

        let result = DrivingContextService.aggregateSideDetail(
            segments: [tinySeg, qualifyingSeg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.earliestFreeUntilText, expectedText, "The sub-6m segment's earlier restriction must not win")
    }

    // Test 7: regression parity — aggregateSideDetail(...).opportunity matches the existing
    // 9-case aggregateSide decision table (TF27Tests.AggregateSideTests), rebuilt here.
    func testAggregateSideDetail_matchesAggregateSideOpportunity_forAllNineExistingDecisionTableCases() {
        struct Case { let segments: [Segment]; let side: String; let expected: SideOpportunity; let label: String }

        let cases: [Case] = [
            Case(
                segments: [tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0)],
                side: "N", expected: .free, label: "single free >=6m"
            ),
            Case(
                segments: [tf27MakeSeg(side: "N", category: .free, lengthMeters: 4.0)],
                side: "N", expected: .restricted, label: "single free <6m"
            ),
            Case(
                segments: [
                    tf27MakeSeg(side: "N", category: .noParking, lengthMeters: 30.0),
                    tf27MakeSeg(side: "N", category: .free, lengthMeters: 8.0)
                ],
                side: "N", expected: .free, label: "mixed free+restricted, free qualifies"
            ),
            Case(
                segments: [tf27MakeSeg(
                    side: "S", category: .metered, lengthMeters: 20.0,
                    timeRanges: [TimeRange(start: 420, end: 1200)]
                )],
                side: "S", expected: .metered, label: "metered only, paid now"
            ),
            Case(
                segments: [
                    tf27MakeSeg(side: "E", category: .noParking, lengthMeters: 15.0),
                    tf27MakeSeg(side: "E", category: .noStanding, lengthMeters: 10.0)
                ],
                side: "E", expected: .restricted, label: "all restricted"
            ),
            Case(
                segments: [tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0)],
                side: "W", expected: .unknown, label: "no segments for side"
            ),
            Case(
                segments: [
                    tf27MakeSeg(side: "N", category: .free, lengthMeters: 10.0),
                    tf27MakeSeg(
                        side: "N", category: .metered, lengthMeters: 20.0,
                        timeRanges: [TimeRange(start: 420, end: 1200)]
                    )
                ],
                side: "N", expected: .free, label: "free before metered"
            ),
        ]

        for c in cases {
            let opportunity = DrivingContextService.aggregateSide(
                segments: c.segments, side: c.side, engine: engine, date: tf217TestDate
            )
            let detail = DrivingContextService.aggregateSideDetail(
                segments: c.segments, side: c.side, engine: engine, date: tf217TestDate
            )
            XCTAssertEqual(opportunity, detail.opportunity, "aggregateSide/aggregateSideDetail mismatch for case: \(c.label)")
            XCTAssertEqual(detail.opportunity, c.expected, "Unexpected opportunity for case: \(c.label)")
        }
    }

    // Test 8: explicit assertion that aggregateSide is a pure passthrough to
    // aggregateSideDetail(...).opportunity across a representative sample.
    func testAggregateSide_publicWrapper_unchangedAfterRefactor() {
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 600, end: 630)]
        )
        let wrapperResult = DrivingContextService.aggregateSide(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        let detailResult = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(wrapperResult, detailResult.opportunity)
    }

    // Test 9 (FT-9 regression): a segment with BOTH an active-now metered rule AND an
    // upcoming ASP rule (the exact FT-9 bug shape) must classify as `.metered` at the
    // aggregation level, never `.free` — replays docs/qa/ft9-bowery-2ndave-investigation.md
    // one layer up (aggregateSideDetail, not just ParkingRulesEngine.safetyLabel).
    func testAggregateSideDetail_ft9Regression_activelyMeteredSegmentPlusUpcomingASP_classifiesMetered() {
        // Wednesday 8am ET (2026-01-07): metered rule active 7am-10am (covers 8am);
        // ASP Mon/Thu rule not active today (Wed is not an ASP_MON_THU day) — upcoming.
        let combinedSeg = makeSegment(
            id: "FT9-combined",
            dominantCategory: .metered,
            rules: [
                rule(category: .metered, days: [0,1,2,3,4,5,6], timeRanges: [(420, 600)]),
                rule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])
            ]
        )
        // A second, unrelated restricted segment on the same side — "a different segment",
        // per AC-11's framing — that also does not qualify free.
        let bystanderSeg = makeSegment(
            id: "FT9-bystander",
            dominantCategory: .noParking,
            rules: [rule(category: .noParking, days: [0,1,2,3,4,5,6], timeRanges: [], anytime: true)]
        )

        // Precondition: the engine itself must classify the combined segment .metered
        // (the FT-9 fix, already merged) — not .free.
        let engineLabel = engine.safetyLabel(for: combinedSeg, at: tf217TestDate)
        XCTAssertEqual(engineLabel.severity, .metered, "Precondition: FT-9 fix must hold at the engine level")

        let result = DrivingContextService.aggregateSideDetail(
            segments: [combinedSeg, bystanderSeg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .metered, "Side must classify .metered, not .free — FT-9 bug class must not reappear at the aggregation layer")
        XCTAssertNil(result.earliestFreeUntilText)
    }
}

// MARK: - B. SafetyLabel(for: SideAggregation) bridge

final class SafetyLabelSideAggregationTests: XCTestCase {

    // Test 10: .free with text → exact text, .free severity.
    func testSafetyLabel_freeWithText_exactTextAndFreeSeverity() {
        let agg = SideAggregation(opportunity: .free, earliestFreeUntilText: "Free until Wednesday 9:30 AM")
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "Free until Wednesday 9:30 AM")
        XCTAssertEqual(label.severity, .free)
    }

    // Test 11: .free with nil text → "Free — check signs", .free severity.
    func testSafetyLabel_freeWithNilText_checkSignsFallback() {
        let agg = SideAggregation(opportunity: .free, earliestFreeUntilText: nil)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "Free — check signs")
        XCTAssertEqual(label.severity, .free)
    }

    // Test 12: .metered → "Metered", .metered severity (unchanged).
    func testSafetyLabel_metered_unchanged() {
        let agg = SideAggregation(opportunity: .metered, earliestFreeUntilText: nil)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "Metered")
        XCTAssertEqual(label.severity, .metered)
    }

    // Test 13: .restricted → "No parking", .restricted severity (unchanged).
    func testSafetyLabel_restricted_unchanged() {
        let agg = SideAggregation(opportunity: .restricted, earliestFreeUntilText: nil)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "No parking")
        XCTAssertEqual(label.severity, .restricted)
    }

    // Test 14: .unknown → "—", .unknown severity (unchanged).
    func testSafetyLabel_unknown_unchanged() {
        let agg = SideAggregation(opportunity: .unknown, earliestFreeUntilText: nil)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "—")
        XCTAssertEqual(label.severity, .unknown)
    }

    // TF2-18 P1-2 additions — .comingSoon cases (same bridge, new opportunity case).

    func testSafetyLabel_comingSoonWithText_exactTextAndComingSoonSeverity() {
        let agg = SideAggregation(opportunity: .comingSoon, earliestFreeUntilText: "Free until Today 1:00 PM")
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "Free until Today 1:00 PM")
        XCTAssertEqual(label.severity, .comingSoon)
    }

    func testSafetyLabel_comingSoonWithNilText_checkSignsFallback() {
        // Defensive-fallback case (aggregateSideDetail never actually produces this
        // combination in practice — see the bridge init's doc comment).
        let agg = SideAggregation(opportunity: .comingSoon, earliestFreeUntilText: nil)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, "Free — check signs")
        XCTAssertEqual(label.severity, .comingSoon)
    }

    // TF2-18 override note (AC-3 flag): SafetyLabel(for: SideOpportunity) also gained a
    // .comingSoon branch for exhaustiveness — verify it independently of the SideAggregation
    // bridge above.
    func testSafetyLabel_sideOpportunityBridge_comingSoon_genericTextAndSeverity() {
        let label = SafetyLabel(for: SideOpportunity.comingSoon)
        XCTAssertEqual(label.text, "Free — check signs")
        XCTAssertEqual(label.severity, .comingSoon)
    }
}

// MARK: - C. Voice regression — text changes and comingSoon severity are voice-invisible

final class TF217VoiceRegressionTests: XCTestCase {

    let service = DrivingContextService(voice: MockDrivingVoice())

    private func ctx(left: SafetyLabel, right: SafetyLabel) -> DrivingContext {
        DrivingContext(street: "SPRING ST", from: "6 AVE", to: "VARICK ST", leftLabel: left, rightLabel: right)
    }

    // Test 15: buildUtteranceText output is byte-identical regardless of `.text` — only
    // `.severity` may drive voice copy (OQ-4).
    func testBuildUtteranceText_unaffectedBySafetyLabelTextChange() {
        let oldStyle = ctx(
            left: SafetyLabel(text: "Free — check signs", severity: .free),
            right: SafetyLabel(text: "No parking", severity: .restricted)
        )
        let newStyle = ctx(
            left: SafetyLabel(text: "Free until Wednesday 9:30 AM", severity: .free),
            right: SafetyLabel(text: "No parking", severity: .restricted)
        )
        XCTAssertEqual(service.buildUtteranceText(oldStyle), service.buildUtteranceText(newStyle))
    }

    // Same idea for CruiseVoicePolicy.utteranceText.
    func testCruiseVoicePolicyUtteranceText_unaffectedBySafetyLabelTextChange() {
        let oldStyle = ctx(
            left: SafetyLabel(text: "Free — check signs", severity: .free),
            right: SafetyLabel(text: "Metered", severity: .metered)
        )
        let newStyle = ctx(
            left: SafetyLabel(text: "Free until Thursday 7:00 AM", severity: .free),
            right: SafetyLabel(text: "paid until 7pm", severity: .metered)
        )
        XCTAssertEqual(CruiseVoicePolicy.utteranceText(for: oldStyle), CruiseVoicePolicy.utteranceText(for: newStyle))
    }

    // TF2-18: `.comingSoon` must produce IDENTICAL voice output to `.free` in the same
    // position — the new severity is chip-color-only, never voice-visible.
    func testBuildUtteranceText_comingSoonIdenticalToFree() {
        let freeCtx = ctx(
            left: SafetyLabel(text: "Free — check signs", severity: .free),
            right: SafetyLabel(text: "No parking", severity: .restricted)
        )
        let comingSoonCtx = ctx(
            left: SafetyLabel(text: "Free until Today 1:00 PM", severity: .comingSoon),
            right: SafetyLabel(text: "No parking", severity: .restricted)
        )
        XCTAssertEqual(service.buildUtteranceText(freeCtx), service.buildUtteranceText(comingSoonCtx))
    }

    func testCruiseVoicePolicy_comingSoonIdenticalToFree_shouldAnnounceAndUtteranceText() {
        let freeCtx = ctx(
            left: SafetyLabel(text: "Free — check signs", severity: .free),
            right: SafetyLabel(text: "—", severity: .unknown)
        )
        let comingSoonCtx = ctx(
            left: SafetyLabel(text: "Free until Today 1:00 PM", severity: .comingSoon),
            right: SafetyLabel(text: "—", severity: .unknown)
        )
        XCTAssertEqual(CruiseVoicePolicy.shouldAnnounce(context: freeCtx), CruiseVoicePolicy.shouldAnnounce(context: comingSoonCtx))
        XCTAssertTrue(CruiseVoicePolicy.shouldAnnounce(context: comingSoonCtx), "comingSoon side alone should still trigger an announcement, same as free")
        XCTAssertEqual(CruiseVoicePolicy.utteranceText(for: freeCtx), CruiseVoicePolicy.utteranceText(for: comingSoonCtx))
    }

    // isFreeForVoice(_:) direct unit tests.
    func testIsFreeForVoice_trueForFreeAndComingSoon_falseForOthers() {
        XCTAssertTrue(DrivingContextService.isFreeForVoice(.free))
        XCTAssertTrue(DrivingContextService.isFreeForVoice(.comingSoon))
        XCTAssertFalse(DrivingContextService.isFreeForVoice(.metered))
        XCTAssertFalse(DrivingContextService.isFreeForVoice(.restricted))
        XCTAssertFalse(DrivingContextService.isFreeForVoice(.unknown))
    }
}

// MARK: - D. TF2-18 P1-2 — comingSoon threshold / boundary tests

final class AggregateSideDetailComingSoonTests: XCTestCase {

    let engine = ParkingRulesEngine()

    // Winning restriction well within the 6h window (5h) → .comingSoon.
    func testAggregateSideDetail_winningRestrictionWithin6h_classifiesComingSoon() {
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 780, end: 810)]  // 5h away (1:00pm)
        )
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .comingSoon)
        XCTAssertNotNil(result.earliestFreeUntilText)
    }

    // Winning restriction just outside the window (7h) → stays .free, not .comingSoon.
    func testAggregateSideDetail_winningRestrictionJustOutside6h_staysFree() {
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 900, end: 930)]  // 7h away (3:00pm)
        )
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .free)
    }

    // Exact boundary (6h, not < 6h) → stays .free (strict less-than, matches
    // ParkingRulesEngine.currentState's own `< nearFutureWindow` check).
    func testAggregateSideDetail_winningRestrictionExactly6h_staysFree() {
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 840, end: 870)]  // exactly 6h away (2:00pm)
        )
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        let restriction = engine.nextRestriction(for: seg, at: tf217TestDate)
        XCTAssertEqual(restriction.hours, 6.0, accuracy: 0.01, "Fixture must produce exactly 6h for this boundary test to be meaningful")
        XCTAssertEqual(result.opportunity, .free, "Exactly 6h should NOT be comingSoon (strict < 6h)")
    }

    // comingSoon and the classification `ParkingRulesEngine.currentState` would independently
    // compute for the SAME segment must agree — the aggregation-level tier mirrors the
    // per-segment map tier it's restoring.
    func testAggregateSideDetail_comingSoonMirrorsCurrentStateFreeButRestrictionSoon() {
        let seg = tf27MakeSeg(
            side: "N", category: .noParking, lengthMeters: 10.0,
            timeRanges: [TimeRange(start: 780, end: 810)]  // 5h away
        )
        let currentState = engine.currentState(for: seg, at: tf217TestDate)
        XCTAssertEqual(currentState, .freeButRestrictionSoon, "Precondition: engine.currentState must classify this segment as freeButRestrictionSoon")

        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .comingSoon)
    }

    // A metered-active segment's severity must never become comingSoon (comingSoon only
    // applies to the free-side branch) — precedence unchanged.
    func testAggregateSideDetail_meteredActiveSegment_neverComingSoon() {
        let seg = tf27MakeSeg(
            side: "S", category: .metered, lengthMeters: 20.0,
            timeRanges: [TimeRange(start: 420, end: 1200)]
        )
        let result = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "S", engine: engine, date: tf217TestDate
        )
        XCTAssertEqual(result.opportunity, .metered)
    }
}

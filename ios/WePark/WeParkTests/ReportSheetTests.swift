//
//  ReportSheetTests.swift
//  WeParkTests
//
//  Tier 3 Sub-PR #2 — Universal Community Reporting.
//  Tests for ReportSheet.buildMeta (pure static function) + timeSinceBadge pure function.
//  Spec: docs/tier3-patrol-report-spec.md §8.
//
//  Test inventory (17 tests):
//
//  Type → meta mapping — ReportSheet.buildMeta(type:subTag:sweeperDirection:)
//  (AC-R18, AC-R20, AC-R21):
//    1.  testBuildMeta_enforcementActive_noSubTag_returnsNilMeta           (AC-R18 base)
//    2.  testBuildMeta_enforcementActive_cleaningTruck_hasSubTag           (AC-R18)
//    3.  testBuildMeta_enforcementActive_parkingAgent_hasSubTag
//    4.  testBuildMeta_enforcementActive_towTruck_hasSubTag
//    5.  testBuildMeta_sweeper_passed_directionIsPassed                    (AC-R20)
//    6.  testBuildMeta_sweeper_approaching_directionIsComingSoon           (AC-R21)
//    7.  testBuildMeta_enforcementActive_returnsCorrectPinType
//    8.  testBuildMeta_sweeper_returnsSweeperPassedPinType
//
//  timeSinceBadge pure function — PinMarkerAnnotation.timeSinceBadge(pin:now:)
//  (AC-R25, AC-R26, AC-R27, AC-R28):
//    9.  testTimeSinceBadge_under60s_returnsJustNow                        (AC-R25)
//   10.  testTimeSinceBadge_exactlyZero_returnsJustNow                     (AC-R25 boundary)
//   11.  testTimeSinceBadge_59s_returnsJustNow                             (AC-R25 boundary)
//   12.  testTimeSinceBadge_5min_returns5mAgo                              (AC-R26)
//   13.  testTimeSinceBadge_59min_returns59mAgo                            (AC-R26 boundary)
//   14.  testTimeSinceBadge_60min_returns1hAgo                             (AC-R27)
//   15.  testTimeSinceBadge_90min_returns1hAgo                             (AC-R27 boundary)
//   16.  testTimeSinceBadge_120min_returns2hAgo
//   17.  testTimeSinceBadge_isCalendarIndependent                          (AC-R28)
//
//  ReportSheet enabled state — ReportSheet.isEnabled(selectedType:isSubmitting:)
//  (AC-R16):
//   18.  testIsEnabled_noTypeSelected_isFalse
//   19.  testIsEnabled_enforcementSelected_notSubmitting_isTrue
//   20.  testIsEnabled_enforcementSelected_isSubmitting_isFalse
//
//  Baseline before this suite: 258 tests.
//  After: 258 + 20 = 278 tests.
//
//  Design note: buildMeta and isEnabled are static pure functions, testable without
//  constructing a SwiftUI view (no @State dependency). timeSinceBadge is a static
//  pure function on PinMarkerAnnotation — no live MKMapView needed.
//

import XCTest
import MapKit
@testable import WePark

// MARK: - ReportSheet type→meta mapping tests

/// Tests for ReportSheet.buildMeta(type:subTag:sweeperDirection:) — pure static function.
///
/// Verifies that the (PinType, [String: Any]?) pairs match the §6 mapping table exactly.
final class ReportSheetMetaTests: XCTestCase {

    // MARK: - Enforcement: no sub_tag (AC-R18 base)

    func testBuildMeta_enforcementActive_noSubTag_returnsNilMeta() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: nil,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .enforcementActive)
        XCTAssertNil(meta, "No sub_tag selected → meta should be nil (DB null-meta case)")
    }

    // MARK: - Enforcement: cleaning truck (AC-R18)

    func testBuildMeta_enforcementActive_cleaningTruck_hasSubTag() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: .cleaningTruck,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .enforcementActive)
        XCTAssertEqual(meta?["sub_tag"] as? String, "cleaning_truck",
                       "cleaning truck sub_tag must match EnforcementActiveMeta.SubTag.cleaningTruck rawValue")
    }

    // MARK: - Enforcement: parking agent

    func testBuildMeta_enforcementActive_parkingAgent_hasSubTag() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: .parkingAgent,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .enforcementActive)
        XCTAssertEqual(meta?["sub_tag"] as? String, "parking_agent")
    }

    // MARK: - Enforcement: tow truck

    func testBuildMeta_enforcementActive_towTruck_hasSubTag() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: .towTruck,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .enforcementActive)
        XCTAssertEqual(meta?["sub_tag"] as? String, "tow_truck")
    }

    // MARK: - Enforcement: pin type

    func testBuildMeta_enforcementActive_returnsCorrectPinType() {
        let (pinType, _) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: nil,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .enforcementActive)
    }

    // MARK: - Sweeper: passed (AC-R20)

    func testBuildMeta_sweeper_passed_directionIsPassed() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .sweeper,
            subTag: nil,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .sweeperPassed)
        XCTAssertEqual(meta?["direction"] as? String, "passed",
                       "Sweeper passed → direction must be 'passed' per §6 mapping table")
    }

    // MARK: - Sweeper: approaching (AC-R21)

    func testBuildMeta_sweeper_approaching_directionIsComingSoon() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .sweeper,
            subTag: nil,
            sweeperDirection: .approaching
        )
        XCTAssertEqual(pinType, .sweeperPassed)
        XCTAssertEqual(meta?["direction"] as? String, "coming_soon",
                       "Sweeper approaching → direction must be 'coming_soon' per §6 mapping table")
    }

    // MARK: - Sweeper: pin type

    func testBuildMeta_sweeper_returnsSweeperPassedPinType() {
        let (pinType, _) = ReportSheet.buildMeta(
            type: .sweeper,
            subTag: nil,
            sweeperDirection: .passed
        )
        XCTAssertEqual(pinType, .sweeperPassed)
    }
}

// MARK: - timeSinceBadge pure function tests

/// Tests for PinMarkerAnnotation.timeSinceBadge(pin:now:) — pure static function.
///
/// Verifies badge output at all boundary conditions defined in spec §5 (AC-R25–R28).
/// Uses injected `now: Date` to avoid Date() nondeterminism.
final class TimeSinceBadgeTests: XCTestCase {

    // MARK: - Test fixture helpers

    /// Creates a minimal CommunityPin with the given `createdAt`.
    ///
    /// Uses `enforcement_active` type. The badge function does not check pin type —
    /// it only uses `pin.createdAt`. JSON-decode path ensures model contract is honored.
    private func makePin(createdAt: Date) -> CommunityPin {
        let id = UUID(uuidString: "BEEF0001-0000-0000-0000-000000000001")!
        let json = """
        {
          "id": "\(id.uuidString)",
          "pin_type": "enforcement_active",
          "source": "crowd",
          "lifespan": "ephemeral",
          "lat": 40.72,
          "lng": -74.00,
          "author_id": null,
          "author_username": null,
          "created_at": "\(iso8601(createdAt))",
          "updated_at": "\(iso8601(createdAt))",
          "expires_at": null,
          "resolved_at": null,
          "confirm_count": 0,
          "dispute_count": 0,
          "meta": null,
          "notes": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Force-unwrap is acceptable in tests — a decode failure means the fixture JSON is wrong,
        // which is a test-authoring error that should fail loudly.
        return try! decoder.decode(CommunityPin.self, from: json)
    }

    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Fixed epoch used across all tests to eliminate date nondeterminism.
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - "Just now" (AC-R25)

    func testTimeSinceBadge_under60s_returnsJustNow() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-30))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "Just now")
    }

    func testTimeSinceBadge_exactlyZero_returnsJustNow() {
        let pin = makePin(createdAt: epoch)
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "Just now")
    }

    func testTimeSinceBadge_59s_returnsJustNow() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-59))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "Just now")
    }

    // MARK: - "Xm ago" (AC-R26)

    func testTimeSinceBadge_5min_returns5mAgo() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-300))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "5m ago")
    }

    func testTimeSinceBadge_59min_returns59mAgo() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-59 * 60))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "59m ago")
    }

    // MARK: - "1h ago" (AC-R27)

    func testTimeSinceBadge_60min_returns1hAgo() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-3600))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "1h ago")
    }

    func testTimeSinceBadge_90min_returns1hAgo() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-90 * 60))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "1h ago")
    }

    // MARK: - "Xh ago"

    func testTimeSinceBadge_120min_returns2hAgo() {
        let pin = makePin(createdAt: epoch.addingTimeInterval(-120 * 60))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: epoch), "2h ago")
    }

    // MARK: - Calendar-independence (AC-R28)

    /// AC-R28: timeSinceBadge must produce consistent output regardless of locale/timezone.
    /// Uses a date far from any DST boundary. Pure arithmetic → same result everywhere.
    func testTimeSinceBadge_isCalendarIndependent() {
        // 2026-05-12 UTC — no DST ambiguity.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let pin = makePin(createdAt: now.addingTimeInterval(-300))
        XCTAssertEqual(PinMarkerAnnotation.timeSinceBadge(pin: pin, now: now), "5m ago",
                       "timeSinceBadge must be calendar-independent — pure timeIntervalSince (AC-R28)")
    }
}

// MARK: - ReportSheet enabled state tests (AC-R16)

/// Tests for ReportSheet.isEnabled(selectedType:isSubmitting:) — pure static function.
final class ReportSheetEnabledTests: XCTestCase {

    /// AC-R16: disabled when no type selected.
    func testIsEnabled_noTypeSelected_isFalse() {
        XCTAssertFalse(ReportSheet.isEnabled(selectedType: nil, isSubmitting: false),
                       "CTA must be disabled when no primary type selected (AC-R16)")
    }

    /// AC-R16: enabled when a type is selected and not submitting.
    func testIsEnabled_enforcementSelected_notSubmitting_isTrue() {
        XCTAssertTrue(ReportSheet.isEnabled(selectedType: .enforcementActive, isSubmitting: false),
                      "CTA must be enabled when a primary type is selected (AC-R16)")
    }

    /// AC-R22: disabled while submitting (prevents double-submit).
    func testIsEnabled_enforcementSelected_isSubmitting_isFalse() {
        XCTAssertFalse(ReportSheet.isEnabled(selectedType: .enforcementActive, isSubmitting: true),
                       "CTA must be disabled while submitting (AC-R22 double-submit guard)")
    }
}

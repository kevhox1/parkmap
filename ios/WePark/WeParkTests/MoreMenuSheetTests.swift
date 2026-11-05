//
//  MoreMenuSheetTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §3.1) —
//  unit tests for `moreMenuVisibleRows(...)`'s amended row set (the "How WePark works" and
//  "Parking 101" rows) plus a render smoke for `MoreMenuSheet`.
//
//  Test groups:
//    1. Row visibility + ordering — every combination of the four booleans.
//    2. Row content — title/subtitle/symbol for the two new rows.
//    3. Render smoke (`UIHostingController`, this repo's standing pattern).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import SwiftUI
@testable import WePark

final class MoreMenuVisibleRowsTests: XCTestCase {

    // MARK: - 1. Visibility + ordering

    func testAllRowsVisible_fullOrdering() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true,
            onboardingReplayAvailable: true,
            hasParkedCar: true,
            fullPaletteMode: true
        )
        XCTAssertEqual(rows, [
            .report, .howWeParkWorks, .mapKey, .parking101, .showAllRules, .findMyCar, .parkUntil
        ])
    }

    func testHowWeParkWorksRow_hidden_whenOnboardingReplayUnavailable() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true,
            onboardingReplayAvailable: false,
            hasParkedCar: true,
            fullPaletteMode: true
        )
        XCTAssertFalse(rows.contains(.howWeParkWorks))
    }

    /// `mapKey` and `parking101` are unconditional — unlike `howWeParkWorks`, they show
    /// regardless of the onboarding flags (design doc §3.1: Parking 101 "finally gives the
    /// existing deep guide a home outside Search," unrelated to the onboarding experience).
    func testMapKeyAndParking101_alwaysVisible_regardlessOfOtherFlags() {
        for communityEnabled in [true, false] {
            for onboardingReplayAvailable in [true, false] {
                for hasParkedCar in [true, false] {
                    for fullPaletteMode in [true, false] {
                        let rows = moreMenuVisibleRows(
                            communityEnabled: communityEnabled,
                            onboardingReplayAvailable: onboardingReplayAvailable,
                            hasParkedCar: hasParkedCar,
                            fullPaletteMode: fullPaletteMode
                        )
                        XCTAssertTrue(rows.contains(.mapKey))
                        XCTAssertTrue(rows.contains(.parking101))
                    }
                }
            }
        }
    }

    func testReportRow_gatedOnCommunityEnabled() {
        let withCommunity = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: false,
            hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertTrue(withCommunity.contains(.report))

        let withoutCommunity = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false,
            hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertFalse(withoutCommunity.contains(.report))
    }

    func testFindMyCarRow_gatedOnHasParkedCar() {
        let parked = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false,
            hasParkedCar: true, fullPaletteMode: false
        )
        XCTAssertTrue(parked.contains(.findMyCar))

        let notParked = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false,
            hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertFalse(notParked.contains(.findMyCar))
    }

    func testParkUntilRow_gatedOnFullPaletteMode() {
        let full = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false,
            hasParkedCar: false, fullPaletteMode: true
        )
        XCTAssertTrue(full.contains(.parkUntil))

        let goalFirst = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false,
            hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertFalse(goalFirst.contains(.parkUntil))
    }

    /// The minimal row set (every optional row hidden) is exactly the two always-on rows, in
    /// order.
    func testMinimalRowSet_isMapKeyThenParking101() {
        let rows = moreMenuVisibleRows(
            communityEnabled: false,
            onboardingReplayAvailable: false,
            hasParkedCar: false,
            fullPaletteMode: false
        )
        XCTAssertEqual(rows, [.mapKey, .parking101])
    }

    // MARK: - 2. Row content

    func testHowWeParkWorksRow_content() {
        XCTAssertEqual(MoreMenuRow.howWeParkWorks.title, "How WePark works")
        XCTAssertEqual(MoreMenuRow.howWeParkWorks.subtitle, "Replay the quick tour")
        XCTAssertEqual(MoreMenuRow.howWeParkWorks.symbolName, "sparkles")
    }

    func testParking101Row_content() {
        XCTAssertEqual(MoreMenuRow.parking101.title, "Parking 101")
        XCTAssertEqual(MoreMenuRow.parking101.subtitle, "The full guide to NYC parking rules")
        XCTAssertEqual(MoreMenuRow.parking101.symbolName, "book.closed.fill")
    }
}

// MARK: - 3. Render smoke

@MainActor
final class MoreMenuSheetRenderTests: XCTestCase {

    func testMoreMenuSheet_withAllRows_rendersWithoutCrash() {
        let sheet = MoreMenuSheet(
            rows: moreMenuVisibleRows(
                communityEnabled: true,
                onboardingReplayAvailable: true,
                hasParkedCar: true,
                fullPaletteMode: true
            ),
            fullPaletteMode: true,
            onSelect: { _ in },
            onToggleFullPalette: {},
            onDone: {}
        )
        let host = UIHostingController(rootView: sheet)
        XCTAssertNotNil(host.view, "MoreMenuSheet with every row present should render without crash")
    }

    func testMoreMenuSheet_minimalRows_rendersWithoutCrash() {
        let sheet = MoreMenuSheet(
            rows: moreMenuVisibleRows(
                communityEnabled: false,
                onboardingReplayAvailable: false,
                hasParkedCar: false,
                fullPaletteMode: false
            ),
            fullPaletteMode: false,
            onSelect: { _ in },
            onToggleFullPalette: {},
            onDone: {}
        )
        let host = UIHostingController(rootView: sheet)
        XCTAssertNotNil(host.view, "MoreMenuSheet with the minimal row set should render without crash")
    }
}

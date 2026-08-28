//
//  ReportSheetPhase2aTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2a (build 20 S6) — pure static gating/formatting functions added to
//  `ReportSheet.swift`. Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (11 tests):
//    ReportSheet.showsStreetClosureTile(communityEnabled:) — grid gating, both flag states:
//      1. testShowsStreetClosureTile_flagOn_true
//      2. testShowsStreetClosureTile_flagOff_false
//
//    ReportSheet.showsConfirmStreetStep(communityEnabled:selectedType:candidates:) — step
//    gating, both flag states + the type/candidates dimensions:
//      3.  testShowsConfirmStreetStep_flagOff_alwaysFalse_evenWithTypeAndCandidates
//      4.  testShowsConfirmStreetStep_flagOn_noTypeSelected_false
//      5.  testShowsConfirmStreetStep_flagOn_emptyCandidates_false
//      6.  testShowsConfirmStreetStep_flagOn_enforcementActive_nonEmptyCandidates_true
//      7.  testShowsConfirmStreetStep_flagOn_sweeper_nonEmptyCandidates_true
//
//    ReportSheet.sideDisplayName(_:) — "confirm the street" row formatting:
//      8.  testSideDisplayName_north
//      9.  testSideDisplayName_south
//      10. testSideDisplayName_eastWest
//      11. testSideDisplayName_unexpectedCode_fallsBackGracefully
//

import XCTest
@testable import WePark

// MARK: - showsStreetClosureTile (grid gating)

final class ShowsStreetClosureTileTests: XCTestCase {

    func testShowsStreetClosureTile_flagOn_true() {
        XCTAssertTrue(ReportSheet.showsStreetClosureTile(communityEnabled: true))
    }

    func testShowsStreetClosureTile_flagOff_false() {
        XCTAssertFalse(ReportSheet.showsStreetClosureTile(communityEnabled: false),
            "Flag-off must hide the third 'Street closure' tile — adding it is a visible grid change (product rule 7)")
    }
}

// MARK: - showsConfirmStreetStep (confirm-the-street step gating)

final class ShowsConfirmStreetStepTests: XCTestCase {

    private func aSegment() -> Segment {
        Segment(
            id: "TEST", street: "MOTT STREET", fromStreet: "SPRING STREET", to: "BROOME STREET",
            side: "E", line: [[40.7230, -73.9950], [40.7232, -73.9948]], rules: [], dominantCategory: nil
        )
    }

    /// The core flag-off invariant: flag-off must keep the pre-Community-2.0
    /// straight-to-heading flow byte-identical, regardless of type/candidates.
    func testShowsConfirmStreetStep_flagOff_alwaysFalse_evenWithTypeAndCandidates() {
        let result = ReportSheet.showsConfirmStreetStep(
            communityEnabled: false,
            selectedType: .enforcementActive,
            candidates: [aSegment()]
        )
        XCTAssertFalse(result)
    }

    func testShowsConfirmStreetStep_flagOn_noTypeSelected_false() {
        let result = ReportSheet.showsConfirmStreetStep(
            communityEnabled: true,
            selectedType: nil,
            candidates: [aSegment()]
        )
        XCTAssertFalse(result)
    }

    func testShowsConfirmStreetStep_flagOn_emptyCandidates_false() {
        let result = ReportSheet.showsConfirmStreetStep(
            communityEnabled: true,
            selectedType: .enforcementActive,
            candidates: []
        )
        XCTAssertFalse(result, "OD-1: off-segment (empty candidates) must hide the step — nothing to confirm against")
    }

    func testShowsConfirmStreetStep_flagOn_enforcementActive_nonEmptyCandidates_true() {
        let result = ReportSheet.showsConfirmStreetStep(
            communityEnabled: true,
            selectedType: .enforcementActive,
            candidates: [aSegment()]
        )
        XCTAssertTrue(result)
    }

    func testShowsConfirmStreetStep_flagOn_sweeper_nonEmptyCandidates_true() {
        let result = ReportSheet.showsConfirmStreetStep(
            communityEnabled: true,
            selectedType: .sweeper,
            candidates: [aSegment()]
        )
        XCTAssertTrue(result)
    }
}

// MARK: - sideDisplayName

final class SideDisplayNameTests: XCTestCase {

    func testSideDisplayName_north() {
        XCTAssertEqual(ReportSheet.sideDisplayName("N"), "North side")
    }

    func testSideDisplayName_south() {
        XCTAssertEqual(ReportSheet.sideDisplayName("S"), "South side")
    }

    func testSideDisplayName_eastWest() {
        XCTAssertEqual(ReportSheet.sideDisplayName("E"), "East side")
        XCTAssertEqual(ReportSheet.sideDisplayName("W"), "West side")
    }

    func testSideDisplayName_unexpectedCode_fallsBackGracefully() {
        // Matching is case-insensitive (`.uppercased()` in the switch), but the fallback
        // string echoes the ORIGINAL (not uppercased) input — same behavior as
        // `ParkConfirmView.sideLabel(_:)`'s existing, independently-duplicated helper.
        XCTAssertEqual(ReportSheet.sideDisplayName("x"), "x side")
        XCTAssertEqual(ReportSheet.sideDisplayName("NE"), "NE side",
            "Unexpected multi-character codes fall back to '<code> side', never a crash")
    }
}

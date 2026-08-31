//
//  SpotPlacementViewTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2b (build 20 S7) — tests for `SpotPlacementCopy`'s pure static
//  copy-generation functions (nearLabel naming boundaries, confirm-card title/subtitle).
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2 ("Spot placement").
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (10 tests):
//    SpotPlacementCopy.nearLabel(fraction:fromStreet:toStreet:) — boundary coverage,
//    port of design/prototype.html:824-830's frac < 0.4 / frac > 0.6 branches:
//      1. testNearLabel_fractionZero_nearFromStreet
//      2. testNearLabel_fractionJustBelow0_4_nearFromStreet
//      3. testNearLabel_fractionExactly0_4_midBlock                  (boundary: falls through)
//      4. testNearLabel_fractionHalf_midBlock
//      5. testNearLabel_fractionExactly0_6_midBlock                  (boundary: falls through)
//      6. testNearLabel_fractionJustAbove0_6_nearToStreet
//      7. testNearLabel_fractionOne_nearToStreet
//
//    SpotPlacementCopy.confirmTitle(segment:) / confirmSubtitle(segment:positionFraction:):
//      8. testConfirmTitle_matchesStreetSideFormat
//      9. testConfirmSubtitle_midBlock_includesBtwnCrossStreets
//      10. testConfirmSubtitle_nearFromStreet_usesNearLabel
//

import XCTest
@testable import WePark

// MARK: - Fixture

private func placementFixtureSegment(
    id: String = "TEST",
    street: String = "MOTT STREET",
    from: String = "SPRING STREET",
    to: String = "BROOME STREET",
    side: String = "E"
) -> Segment {
    Segment(
        id: id, street: street, fromStreet: from, to: to, side: side,
        line: [[40.7230, -73.9950], [40.7230, -73.9940]], rules: [], dominantCategory: nil
    )
}

// MARK: - nearLabel boundary tests

final class SpotPlacementNearLabelTests: XCTestCase {

    func testNearLabel_fractionZero_nearFromStreet() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.0, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "near SPRING ST")
    }

    func testNearLabel_fractionJustBelow0_4_nearFromStreet() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.39, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "near SPRING ST")
    }

    /// Boundary: exactly 0.4 must NOT count as "near from" — the JS source uses a strict
    /// `<` comparison, not `<=`.
    func testNearLabel_fractionExactly0_4_midBlock() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.4, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "mid-block")
    }

    func testNearLabel_fractionHalf_midBlock() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.5, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "mid-block")
    }

    /// Boundary: exactly 0.6 must NOT count as "near to" — strict `>`, not `>=`.
    func testNearLabel_fractionExactly0_6_midBlock() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.6, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "mid-block")
    }

    func testNearLabel_fractionJustAbove0_6_nearToStreet() {
        let result = SpotPlacementCopy.nearLabel(fraction: 0.61, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "near BROOME ST")
    }

    func testNearLabel_fractionOne_nearToStreet() {
        let result = SpotPlacementCopy.nearLabel(fraction: 1.0, fromStreet: "SPRING STREET", toStreet: "BROOME STREET")
        XCTAssertEqual(result, "near BROOME ST")
    }
}

// MARK: - confirmTitle / confirmSubtitle

final class SpotPlacementConfirmCopyTests: XCTestCase {

    func testConfirmTitle_matchesStreetSideFormat() {
        let seg = placementFixtureSegment(side: "E")
        let result = SpotPlacementCopy.confirmTitle(segment: seg)
        XCTAssertEqual(result, "MOTT ST (east side)",
            "Format: {canonical street} ({lowercased side name}) — design/prototype.html:1012's placeTitle")
    }

    func testConfirmSubtitle_midBlock_includesBtwnCrossStreets() {
        let seg = placementFixtureSegment()
        let result = SpotPlacementCopy.confirmSubtitle(segment: seg, positionFraction: 0.5)
        XCTAssertEqual(result, "mid-block · btwn SPRING ST & BROOME ST")
    }

    func testConfirmSubtitle_nearFromStreet_usesNearLabel() {
        let seg = placementFixtureSegment()
        let result = SpotPlacementCopy.confirmSubtitle(segment: seg, positionFraction: 0.1)
        XCTAssertEqual(result, "near SPRING ST · btwn SPRING ST & BROOME ST")
    }
}

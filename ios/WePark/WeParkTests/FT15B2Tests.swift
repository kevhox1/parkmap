//
//  FT15B2Tests.swift
//  WeParkTests
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B2 (map tap-select +
//  report sheet). Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §4.2, §12
//  (AC-R1, AC-R2, AC-R3, AC-R5, AC-R6).
//
//  Architecture note: follows the pure-function testing strategy already established in
//  this file's neighborhood (`DriveCameraTiltTests`, `DriveZoomStyleTests`) — every
//  decision this stream makes that doesn't require a live `MKMapView` or a mounted
//  SwiftUI view is extracted into a pure static function and tested directly here. The
//  actual `MKMapView` overlay add/remove (`Coordinator.syncBlockSelectHighlight`) and the
//  live SwiftUI tap-select interaction are verified by this PR's mandatory live-UI smoke,
//  NOT by a unit test that would require synthesizing a headless `MKMapView`/`UIWindowScene`
//  — that pattern is explicitly forbidden by this project's standing spec-fidelity norm.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory:
//    ContentView.toggledBlockSelection (AC-R1, AC-R2):
//      1. testToggle_addsNewKey
//      2. testToggle_removesExistingKey
//      3. testToggle_bothCurbsOn_addsOppositeKey
//      4. testToggle_bothCurbsOff_doesNotAddOppositeKey
//      5. testToggle_bothCurbsOn_noOppositeFound_addsOnlyTappedKey
//      6. testToggle_deselect_doesNotRemoveOppositeKey
//
//    ContentView.oppositeSideSegment(of:in:) (AC-R2):
//      7. testOppositeSide_findsMatchingOppositeSide
//      8. testOppositeSide_sameSide_notMatched
//      9. testOppositeSide_differentStreet_notMatched
//      10. testOppositeSide_fromToSwapped_stillMatches
//      11. testOppositeSide_noneLoaded_returnsNil
//
//    MapViewRepresentable.blockSelectHighlightCoordinateGroups:
//      12. testHighlightGroups_emptyKeys_returnsEmpty
//      13. testHighlightGroups_matchesOnlySelectedKeys
//      14. testHighlightGroups_dropsDegenerateSegments
//
//    BlockRestrictionReportSheet.isSubmitEnabled (AC-R5):
//      15. testSubmitEnabled_requiresPhoto
//      16. testSubmitEnabled_disabledWhileSubmitting
//
//    BlockRestrictionReportSheet.selectionSummary(for:) (Kevin's canonical E 2nd St case):
//      17. testSummary_singleBlockTwoCurbs_matchesSpecExampleShape
//      18. testSummary_twoBlocksBothCurbs_fourBlockfaces_kevinsCanonicalCase
//      19. testSummary_multipleStreets_fallsBackToCountOnly
//      20. testSummary_empty_returnsPlaceholder
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixture helpers

/// Decodes a fixture `Segment` from inline JSON, mirroring
/// `SegmentBlockfaceKeyTests.decodeSegment` (FT15ModelTests.swift) — duplicated locally
/// per this project's file-scoped fixture-helper convention.
private func ft15b2Segment(
    id: String,
    street: String,
    from: String,
    to: String,
    side: String,
    line: [[Double]] = [[40.7248, -74.0032], [40.7249, -74.0021]]
) -> Segment {
    let lineJSON = line.map { "[\($0[0]), \($0[1])]" }.joined(separator: ", ")
    let json = """
    {
      "id": "\(id)",
      "from": "\(from)",
      "to": "\(to)",
      "street": "\(street)",
      "side": "\(side)",
      "line": [\(lineJSON)],
      "rules": [],
      "dominantCategory": null
    }
    """
    return try! JSONDecoder().decode(Segment.self, from: Data(json.utf8))
}

// MARK: - ContentView.toggledBlockSelection (AC-R1, AC-R2)

final class ToggledBlockSelectionTests: XCTestCase {

    func testToggle_addsNewKey() {
        let result = ContentView.toggledBlockSelection(
            current: [], tappedKey: "A", bothCurbsOn: false, oppositeKey: nil
        )
        XCTAssertEqual(result, ["A"])
    }

    func testToggle_removesExistingKey() {
        let result = ContentView.toggledBlockSelection(
            current: ["A"], tappedKey: "A", bothCurbsOn: false, oppositeKey: nil
        )
        XCTAssertEqual(result, [], "AC-R1: tapping a selected segment again must remove it")
    }

    func testToggle_bothCurbsOn_addsOppositeKey() {
        let result = ContentView.toggledBlockSelection(
            current: [], tappedKey: "A_N", bothCurbsOn: true, oppositeKey: "A_S"
        )
        XCTAssertEqual(result, ["A_N", "A_S"],
            "AC-R2: Both curbs ON must auto-add the opposite-side segment")
    }

    func testToggle_bothCurbsOff_doesNotAddOppositeKey() {
        let result = ContentView.toggledBlockSelection(
            current: [], tappedKey: "A_N", bothCurbsOn: false, oppositeKey: "A_S"
        )
        XCTAssertEqual(result, ["A_N"], "Both curbs OFF must add only the tapped side")
    }

    func testToggle_bothCurbsOn_noOppositeFound_addsOnlyTappedKey() {
        let result = ContentView.toggledBlockSelection(
            current: [], tappedKey: "A_N", bothCurbsOn: true, oppositeKey: nil
        )
        XCTAssertEqual(result, ["A_N"],
            "AC-R2: no opposite-side segment loaded → 1-block selection, no crash, no silent no-op")
    }

    func testToggle_deselect_doesNotRemoveOppositeKey() {
        // Both blockfaces already selected; deselecting one must not remove the other —
        // "Both curbs" only auto-ADDS on select (spec §4.2 step 4), it never auto-removes.
        let result = ContentView.toggledBlockSelection(
            current: ["A_N", "A_S"], tappedKey: "A_N", bothCurbsOn: true, oppositeKey: "A_S"
        )
        XCTAssertEqual(result, ["A_S"])
    }
}

// MARK: - ContentView.oppositeSideSegment(of:in:) (AC-R2)

final class OppositeSideSegmentTests: XCTestCase {

    func testOppositeSide_findsMatchingOppositeSide() {
        let north = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let south = ft15b2Segment(id: "2", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "S")

        let result = ContentView.oppositeSideSegment(of: north, in: [north, south])
        XCTAssertEqual(result?.id, "2")
    }

    func testOppositeSide_sameSide_notMatched() {
        let north1 = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let north2 = ft15b2Segment(id: "2", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")

        let result = ContentView.oppositeSideSegment(of: north1, in: [north1, north2])
        XCTAssertNil(result, "A segment with the SAME side must never match as its own opposite")
    }

    func testOppositeSide_differentStreet_notMatched() {
        let target = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let otherStreet = ft15b2Segment(id: "2", street: "E 3RD STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "S")

        let result = ContentView.oppositeSideSegment(of: target, in: [target, otherStreet])
        XCTAssertNil(result)
    }

    /// Two Segment rows describing the same physical blockface can store from/to in
    /// either order (same reasoning as `Segment.blockfaceKey`'s own direction-agnostic
    /// design) — the opposite-side search must not be direction-sensitive either.
    func testOppositeSide_fromToSwapped_stillMatches() {
        let north = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let south = ft15b2Segment(id: "2", street: "E 2ND STREET", from: "2ND AVENUE", to: "3RD AVENUE", side: "S")

        let result = ContentView.oppositeSideSegment(of: north, in: [north, south])
        XCTAssertEqual(result?.id, "2")
    }

    func testOppositeSide_noneLoaded_returnsNil() {
        let north = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let result = ContentView.oppositeSideSegment(of: north, in: [north])
        XCTAssertNil(result, "AC-R2: only the tapped side loaded → no opposite found")
    }
}

// MARK: - MapViewRepresentable.blockSelectHighlightCoordinateGroups

final class BlockSelectHighlightCoordinateGroupsTests: XCTestCase {

    func testHighlightGroups_emptyKeys_returnsEmpty() {
        let seg = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let result = MapViewRepresentable.blockSelectHighlightCoordinateGroups(keys: [], segments: [seg])
        XCTAssertTrue(result.isEmpty)
    }

    func testHighlightGroups_matchesOnlySelectedKeys() {
        let north = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let south = ft15b2Segment(id: "2", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "S")
        let unrelated = ft15b2Segment(id: "3", street: "E 3RD STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")

        let result = MapViewRepresentable.blockSelectHighlightCoordinateGroups(
            keys: [north.blockfaceKey],
            segments: [north, south, unrelated]
        )
        XCTAssertEqual(result.count, 1, "Only the selected key's segment should produce a coordinate group")
    }

    func testHighlightGroups_dropsDegenerateSegments() {
        let degenerate = ft15b2Segment(
            id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N",
            line: [[40.7248, -74.0032]]  // single point — fewer than 2 coordinates
        )
        let result = MapViewRepresentable.blockSelectHighlightCoordinateGroups(
            keys: [degenerate.blockfaceKey],
            segments: [degenerate]
        )
        XCTAssertTrue(result.isEmpty, "A segment with < 2 coordinates must be dropped, not crash")
    }
}

// MARK: - BlockRestrictionReportSheet.isSubmitEnabled (AC-R5)

final class BlockRestrictionSubmitEnabledTests: XCTestCase {

    func testSubmitEnabled_requiresPhoto() {
        XCTAssertFalse(BlockRestrictionReportSheet.isSubmitEnabled(hasPhoto: false, isSubmitting: false),
            "AC-R5: Submit must be disabled without a captured photo")
        XCTAssertTrue(BlockRestrictionReportSheet.isSubmitEnabled(hasPhoto: true, isSubmitting: false))
    }

    func testSubmitEnabled_disabledWhileSubmitting() {
        XCTAssertFalse(BlockRestrictionReportSheet.isSubmitEnabled(hasPhoto: true, isSubmitting: true))
    }
}

// MARK: - BlockRestrictionReportSheet.selectionSummary(for:)

final class BlockRestrictionSelectionSummaryTests: XCTestCase {

    func testSummary_singleBlockTwoCurbs_matchesSpecExampleShape() {
        let north = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let south = ft15b2Segment(id: "2", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "S")

        let summary = BlockRestrictionReportSheet.selectionSummary(for: [north, south])

        // formattedStreetName title-cases word-by-word ("E 2ND STREET" → "E 2nd Street"),
        // same convention as ArrivalPromptSheet.formattedStreetName's own doc example
        // ("W 34 ST" → "W 34 St").
        XCTAssertTrue(summary.contains("E 2nd Street"), "Summary must name the street: \(summary)")
        XCTAssertTrue(summary.contains("both curbs"), "Two distinct sides must read 'both curbs': \(summary)")
        XCTAssertTrue(summary.contains("2 blockfaces"), "Summary must show the blockface count: \(summary)")
    }

    /// Kevin's canonical case: E 2nd St between 3rd Ave and 1st Ave = 2 blocks × 2 curbs
    /// = 4 blockfaces. Three distinct cross streets are touched (3rd/2nd/1st Ave — 2nd
    /// Ave is the shared internal boundary), so this exercises the 3+-cross-street
    /// fallback path (comma list, not a single "X–Y" range — see the doc comment on
    /// `selectionSummary(for:)` for why a 2-endpoint-only range isn't attempted here).
    func testSummary_twoBlocksBothCurbs_fourBlockfaces_kevinsCanonicalCase() {
        let segments = [
            ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N"),
            ft15b2Segment(id: "2", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "S"),
            ft15b2Segment(id: "3", street: "E 2ND STREET", from: "2ND AVENUE", to: "1ST AVENUE", side: "N"),
            ft15b2Segment(id: "4", street: "E 2ND STREET", from: "2ND AVENUE", to: "1ST AVENUE", side: "S"),
        ]

        let summary = BlockRestrictionReportSheet.selectionSummary(for: segments)

        XCTAssertTrue(summary.contains("4 blockfaces"), "Must report exactly 4 blockfaces: \(summary)")
        XCTAssertTrue(summary.contains("both curbs"), "Must report both curbs: \(summary)")
    }

    func testSummary_multipleStreets_fallsBackToCountOnly() {
        let a = ft15b2Segment(id: "1", street: "E 2ND STREET", from: "3RD AVENUE", to: "2ND AVENUE", side: "N")
        let b = ft15b2Segment(id: "2", street: "BOWERY", from: "HOUSTON STREET", to: "STANTON STREET", side: "E")

        let summary = BlockRestrictionReportSheet.selectionSummary(for: [a, b])
        XCTAssertTrue(summary.contains("2 streets selected"), "Multi-street selection must not fake a single range: \(summary)")
    }

    func testSummary_empty_returnsPlaceholder() {
        let summary = BlockRestrictionReportSheet.selectionSummary(for: [])
        XCTAssertEqual(summary, "No blocks selected")
    }
}

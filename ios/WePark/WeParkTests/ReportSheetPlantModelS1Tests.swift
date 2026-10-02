//
//  ReportSheetPlantModelS1Tests.swift
//  WeParkTests
//
//  Long-press universal-plant model, Stage 1 (plumbing only) —
//  Spec: docs/longpress-universal-plant-spec.md §3.1 ("Park is a third flavor of
//  hand-off, not a new concept") + §3.5 (flag/gating matrix) + §4 Stream 1.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Scope note: this PR is PURE PLUMBING — `ReportGridTile.parkMyCar` /
//  `ReportGridDestination.parkMyCarHandoff` exist and route correctly, and
//  `ReportSheet.visibleGridTiles(showsParkMyCarTile:communityEnabled:)` proves the OD-5
//  flag-off collapse — but NOTHING renders yet (`showsParkMyCarTile` defaults `false` at
//  every production call site, `reportGridSection`/`body` don't consume
//  `visibleGridTiles` yet). Entry-point rewiring (long-press, Report pill) and the
//  flag-off single-tile collapse UI are Stage 2 — see the spec's §4 Stream 2.
//
//  Test inventory (8 tests):
//    ReportSheet.destination(forTapping:communityEnabled:candidates:) — the new
//    `.parkMyCar` tile's routing, mirroring `ReportGridRoutingTests`'s existing coverage
//    of `.streetClosure`/`.spotOpen`:
//      1. testDestination_parkMyCarTile_flagOn_handsOff
//      2. testDestination_parkMyCarTile_flagOff_stillHandsOff_alwaysAvailable
//      3. testDestination_parkMyCarHandoff_neverEqualsAnySelectTypeOrOtherHandoff
//
//    ReportSheet.visibleGridTiles(showsParkMyCarTile:communityEnabled:) — OD-5 gating:
//      4. testVisibleGridTiles_showsParkMyCarTileFalse_communityOff_emptyGrid
//      5. testVisibleGridTiles_showsParkMyCarTileFalse_communityOn_fourExistingTilesUnchanged
//      6. testVisibleGridTiles_showsParkMyCarTileTrue_communityOff_collapsesToParkOnly
//      7. testVisibleGridTiles_showsParkMyCarTileTrue_communityOn_parkIsPeerOfFourTiles
//      8. testVisibleGridTiles_parkAlwaysFirstWhenPresent
//
//  Init-param additive-safety (new `onRequestParkMyCar`/`showsParkMyCarTile` params) is
//  deliberately NOT covered by a dedicated runtime test — see the note at the bottom of
//  this file for why.
//

import XCTest
@testable import WePark

// MARK: - .parkMyCar tile routing (Stage 1 plumbing)

/// Extends `ReportGridRoutingTests`'s established coverage pattern
/// (`ReportSheetPhase2aTests.swift`) to the new `.parkMyCar` tile, without touching that
/// file — kept in its own file so this stage's diff is isolated and easy to bisect per
/// the spec's own OD-6 staging rationale.
final class ReportGridParkMyCarRoutingTests: XCTestCase {

    private func aSegment() -> Segment {
        Segment(
            id: "TEST", street: "MOTT STREET", fromStreet: "SPRING STREET", to: "BROOME STREET",
            side: "E", line: [[40.7230, -73.9950], [40.7232, -73.9948]], rules: [], dominantCategory: nil
        )
    }

    func testDestination_parkMyCarTile_flagOn_handsOff() {
        let result = ReportSheet.destination(
            forTapping: .parkMyCar,
            communityEnabled: true,
            candidates: [aSegment()]
        )
        XCTAssertEqual(result, .parkMyCarHandoff)
    }

    /// Spec §2: "Park my car (always available, not flag-gated)". Unlike `.streetClosure`/
    /// `.spotOpen` (whose flag-off routing test documents "gating is a separate concern,
    /// unreachable in production flag-off"), Park's flag-off routing test documents the
    /// OPPOSITE: this IS reachable in production flag-off, because Park is the one tile
    /// OD-5's collapsed chooser always shows.
    func testDestination_parkMyCarTile_flagOff_stillHandsOff_alwaysAvailable() {
        let result = ReportSheet.destination(
            forTapping: .parkMyCar,
            communityEnabled: false,
            candidates: []
        )
        XCTAssertEqual(result, .parkMyCarHandoff,
            "Park my car must hand off identically regardless of communityEnabled — it is never flag-gated (spec §2)")
    }

    /// Structural regression net, mirroring `testDestination_spotPlacementHandoff_neverEqualsAnySelectTypeOrStreetClosureHandoff`
    /// — `.parkMyCarHandoff` must never be mistaken for any `.selectType` case or either of
    /// the other two hand-off destinations.
    func testDestination_parkMyCarHandoff_neverEqualsAnySelectTypeOrOtherHandoff() {
        let parkHandoff = ReportSheet.destination(forTapping: .parkMyCar, communityEnabled: true, candidates: [aSegment()])
        let closureHandoff = ReportSheet.destination(forTapping: .streetClosure, communityEnabled: true, candidates: [aSegment()])
        let spotHandoff = ReportSheet.destination(forTapping: .spotOpen, communityEnabled: true, candidates: [aSegment()])
        XCTAssertNotEqual(parkHandoff, .selectType(.enforcementActive, showsConfirmStreet: true))
        XCTAssertNotEqual(parkHandoff, .selectType(.enforcementActive, showsConfirmStreet: false))
        XCTAssertNotEqual(parkHandoff, .selectType(.sweeper, showsConfirmStreet: true))
        XCTAssertNotEqual(parkHandoff, .selectType(.sweeper, showsConfirmStreet: false))
        XCTAssertNotEqual(parkHandoff, closureHandoff)
        XCTAssertNotEqual(parkHandoff, spotHandoff)
    }
}

// MARK: - visibleGridTiles (OD-5 flag/gating matrix)

/// Tests for `ReportSheet.visibleGridTiles(showsParkMyCarTile:communityEnabled:)` — the
/// pure function Stage 2 will wire into `reportGridSection`/the flag-off collapse. Not
/// called by any production view yet (see the function's own doc comment) — these tests
/// prove the CONTRACT is correct ahead of that wiring, same "test the static helper first"
/// sequencing this file's sibling `ReportSheetPhase2aTests.swift` established for
/// `destination(forTapping:)` during QA pass 2.
final class VisibleGridTilesTests: XCTestCase {

    func testVisibleGridTiles_showsParkMyCarTileFalse_communityOff_emptyGrid() {
        let tiles = ReportSheet.visibleGridTiles(showsParkMyCarTile: false, communityEnabled: false)
        XCTAssertEqual(tiles, [],
            "showsParkMyCarTile == false (every current production call site) + flag-off: the grid never renders anyway (showsReportGrid is false) — empty is the correct, unreachable-but-documented default")
    }

    func testVisibleGridTiles_showsParkMyCarTileFalse_communityOn_fourExistingTilesUnchanged() {
        let tiles = ReportSheet.visibleGridTiles(showsParkMyCarTile: false, communityEnabled: true)
        XCTAssertEqual(tiles, [.type(.enforcementActive), .type(.sweeper), .spotOpen, .streetClosure],
            "showsParkMyCarTile == false (every current production call site): the EXISTING 4-tile grid, byte-identical to today — this PR changes zero observable behavior")
        XCTAssertFalse(tiles.contains(.parkMyCar))
    }

    /// OD-5: the collapse. This is the behavior the guard tests were asked to prove —
    /// `showsParkMyCarTile == true` + flag-off yields EXACTLY one tile, Park.
    func testVisibleGridTiles_showsParkMyCarTileTrue_communityOff_collapsesToParkOnly() {
        let tiles = ReportSheet.visibleGridTiles(showsParkMyCarTile: true, communityEnabled: false)
        XCTAssertEqual(tiles, [.parkMyCar],
            "OD-5: flag-off must collapse the chooser to exactly one tile — Park my car here, nothing else")
        XCTAssertEqual(tiles.count, 1)
    }

    func testVisibleGridTiles_showsParkMyCarTileTrue_communityOn_parkIsPeerOfFourTiles() {
        let tiles = ReportSheet.visibleGridTiles(showsParkMyCarTile: true, communityEnabled: true)
        XCTAssertEqual(
            tiles,
            [.parkMyCar, .type(.enforcementActive), .type(.sweeper), .spotOpen, .streetClosure]
        )
        XCTAssertEqual(tiles.count, 5, "Flag-on: Park is a peer of the 4 existing community tiles, 5 total (spec §3.5)")
    }

    func testVisibleGridTiles_parkAlwaysFirstWhenPresent() {
        let tiles = ReportSheet.visibleGridTiles(showsParkMyCarTile: true, communityEnabled: true)
        XCTAssertEqual(tiles.first, .parkMyCar,
            "Park's position in the returned array — Stage 2's grid layout decision reads this ordering; pinning it here so a future reorder is a deliberate, reviewed diff, not an accident")
    }
}

// MARK: - Note: init-param additive-safety

// Deliberately NOT tested with a live `ReportSheet()` construction here — this file's
// sibling `ReportSheetPhase2aTests.swift` documents the established house convention
// explicitly: "no test in this file constructs a `ReportSheet` view instance (only its
// pure static helpers)" (see `ReportSheet.swift`'s own `onRequestStreetClosure`/
// `onRequestSpotPlacement` doc comments for why). `ReportSheet`'s `pinService:
// CommunityPinService` dependency is `@MainActor`-isolated, and this test target has no
// precedent for constructing one in a synchronous `XCTestCase` method — doing so here
// for the first time, purely to assert two trivial default-value reads the Swift compiler
// already guarantees (a non-optional-with-default-value parameter DOES default when
// omitted, or `ReportSheet.swift` fails to compile), would be new actor-isolation risk
// for zero additional coverage. `destination(forTapping:)`/`visibleGridTiles(...)` above
// already prove both new params' BEHAVIOR; the two-line diff that added
// `onRequestParkMyCar`/`showsParkMyCarTile` to the init (mirroring
// `onRequestStreetClosure`/`onRequestSpotPlacement`'s exact existing shape) is covered by
// the build itself, same as those two params always have been.

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
//  QA pass 2 (PR #95 Mac-gate blocker, 2026-08-28) added the
//  `ReportGridRoutingTests` class below — see that class's header for the root-cause
//  writeup this addresses.
//
//  Test inventory (19 tests):
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
//    ReportSheet.destination(forTapping:communityEnabled:candidates:) — grid tap ROUTING,
//    both flag states, all three tiles (QA pass 2 / Mac-gate blocker fix):
//      12. testDestination_flagOff_enforcementTile_selectsType_confirmStreetHidden
//      13. testDestination_flagOn_enforcementTile_withCandidates_confirmStreetShown
//      14. testDestination_flagOn_enforcementTile_emptyCandidates_confirmStreetHidden
//      15. testDestination_flagOn_sweeperTile_withCandidates_confirmStreetShown
//      16. testDestination_streetClosureTile_flagOn_handsOff
//      17. testDestination_streetClosureTile_flagOff_stillHandsOff_gatingIsASeparateConcern
//      18. testDestination_streetClosureHandoff_neverEqualsAnySelectType
//      19. testDestination_typeTile_preservesTappedType_neverTheOtherOne
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

// MARK: - Report grid tap routing (QA pass 2 / PR #95 Mac-gate blocker fix)

/// Tests for `ReportSheet.destination(forTapping:communityEnabled:candidates:)`.
///
/// **Root cause this addresses (Kevin's Mac gate, flag-on, `iPhone 17 / iOS 26.5`):**
/// tapping the "Enforcement active" row tore down the ENTIRE flow — report sheet dismissed,
/// browse sheet also gone, no crash logged. QA's leading hypothesis was a mis-routed tap
/// (the enforcement tile's action somehow reaching the closure tile's hand-off). Direct
/// code trace REFUTED that specific mechanism: `reportTypeRow`'s Button action was byte-
/// for-byte unchanged by this PR (`git diff` confirmed) and never referenced
/// `onRequestStreetClosure`, which has exactly one call site (`streetClosureRow`). But
/// elimination against `ContentView.swift`'s dismiss-target logic PROVED
/// `enterBlockSelectMode()` (the only code path that sets `blockSelectModeActive = true`,
/// which is REQUIRED for the browse sheet to stay hidden afterward — see
/// `dismissTargetOutsideBrowseNav`) must have fired. The actual mechanism: before this fix,
/// Row 3 ("Street closure") sat BELOW per-type conditional content that was inserted in the
/// SAME synchronous transaction as a type-row tap — so Row 3's on-screen position (and hit-
/// test target) moved as a direct side effect of selecting a type, racing the tap's touch-up
/// against the relayout. `body`'s fix moves Row 3 to render FIRST, before Rows 1/2 and ALL of
/// their conditional detail, so nothing can ever be inserted above it — Rows 1/2's own
/// (already flag-off-verified) interleaved-detail structure is untouched (see that fix's own
/// doc comment in `body` for the full reasoning, including the deliberate visual-order
/// tradeoff this implies for the flag-ON grid only).
///
/// SwiftUI layout-stability itself isn't unit-testable in this codebase without ViewInspector
/// (QA pass 1 Finding #2), so these tests can't reproduce the layout race directly — but as of
/// QA pass 2 round 2, `reportTypeRow`'s and `streetClosureRow`'s Button actions both `switch`
/// on `destination(forTapping:communityEnabled:candidates:)`'s result to perform their real
/// side effects — two live call sites in `Views/ReportSheet.swift`, not just this test file.
/// These tests therefore assert the actual routing CONTRACT the shipped buttons execute, for
/// every (tile, flag, candidates) combination — a FUTURE edit that makes a tile's handler
/// resolve to the wrong `ReportGridDestination` (the class of bug QA's hypothesis originally
/// described) fails a test immediately AND changes the live button's behavior, not a
/// disconnected model's.
final class ReportGridRoutingTests: XCTestCase {

    private func aSegment() -> Segment {
        Segment(
            id: "TEST", street: "MOTT STREET", fromStreet: "SPRING STREET", to: "BROOME STREET",
            side: "E", line: [[40.7230, -73.9950], [40.7232, -73.9948]], rules: [], dominantCategory: nil
        )
    }

    // MARK: Enforcement/sweeper tiles → .selectType

    func testDestination_flagOff_enforcementTile_selectsType_confirmStreetHidden() {
        let result = ReportSheet.destination(
            forTapping: .type(.enforcementActive),
            communityEnabled: false,
            candidates: [aSegment()]
        )
        XCTAssertEqual(result, .selectType(.enforcementActive, showsConfirmStreet: false),
            "Flag-off: tapping enforcement selects the type but never shows confirm-street — byte-identical to the pre-Community-2.0 flow")
    }

    func testDestination_flagOn_enforcementTile_withCandidates_confirmStreetShown() {
        let result = ReportSheet.destination(
            forTapping: .type(.enforcementActive),
            communityEnabled: true,
            candidates: [aSegment()]
        )
        XCTAssertEqual(result, .selectType(.enforcementActive, showsConfirmStreet: true))
    }

    func testDestination_flagOn_enforcementTile_emptyCandidates_confirmStreetHidden() {
        let result = ReportSheet.destination(
            forTapping: .type(.enforcementActive),
            communityEnabled: true,
            candidates: []
        )
        XCTAssertEqual(result, .selectType(.enforcementActive, showsConfirmStreet: false),
            "OD-1: off-segment (empty candidates) selects the type but shows no confirm-street section")
    }

    func testDestination_flagOn_sweeperTile_withCandidates_confirmStreetShown() {
        let result = ReportSheet.destination(
            forTapping: .type(.sweeper),
            communityEnabled: true,
            candidates: [aSegment()]
        )
        XCTAssertEqual(result, .selectType(.sweeper, showsConfirmStreet: true))
    }

    // MARK: Street-closure tile → .streetClosureHandoff

    func testDestination_streetClosureTile_flagOn_handsOff() {
        let result = ReportSheet.destination(
            forTapping: .streetClosure,
            communityEnabled: true,
            candidates: [aSegment()]
        )
        XCTAssertEqual(result, .streetClosureHandoff)
    }

    /// The tile itself is gated OFF at the UI layer (`showsStreetClosureTile`) when the flag
    /// is off, so this exact call is unreachable in production with `communityEnabled ==
    /// false` — but `destination(forTapping:)` is a pure ROUTING function, and routing
    /// ("what does tapping this tile mean") is a separate concern from gating ("is this tile
    /// visible at all"). It must not silently reinterpret a `.streetClosure` tap as a type
    /// selection under any flag state.
    func testDestination_streetClosureTile_flagOff_stillHandsOff_gatingIsASeparateConcern() {
        let result = ReportSheet.destination(
            forTapping: .streetClosure,
            communityEnabled: false,
            candidates: []
        )
        XCTAssertEqual(result, .streetClosureHandoff)
    }

    // MARK: Structural regression net — the exact bug class QA's hypothesis described

    /// Directly targets QA's leading hypothesis's SHAPE (a tap mis-routing into the closure
    /// hand-off) — even though the actual root cause was a layout race, not a logic bug,
    /// this guards against that class of regression going forward.
    func testDestination_streetClosureHandoff_neverEqualsAnySelectType() {
        let handoff = ReportSheet.destination(forTapping: .streetClosure, communityEnabled: true, candidates: [aSegment()])
        XCTAssertNotEqual(handoff, .selectType(.enforcementActive, showsConfirmStreet: true))
        XCTAssertNotEqual(handoff, .selectType(.enforcementActive, showsConfirmStreet: false))
        XCTAssertNotEqual(handoff, .selectType(.sweeper, showsConfirmStreet: true))
        XCTAssertNotEqual(handoff, .selectType(.sweeper, showsConfirmStreet: false))
    }

    /// Guards against an "off-by-one"/"wrong type" class of routing bug: tapping the
    /// enforcement tile must never resolve to `.selectType(.sweeper, ...)` or vice versa.
    func testDestination_typeTile_preservesTappedType_neverTheOtherOne() {
        let enforcementResult = ReportSheet.destination(
            forTapping: .type(.enforcementActive), communityEnabled: true, candidates: [aSegment()]
        )
        let sweeperResult = ReportSheet.destination(
            forTapping: .type(.sweeper), communityEnabled: true, candidates: [aSegment()]
        )
        guard case .selectType(let enforcementType, _) = enforcementResult,
              case .selectType(let sweeperType, _) = sweeperResult else {
            XCTFail("Both type-tile taps must resolve to .selectType")
            return
        }
        XCTAssertEqual(enforcementType, .enforcementActive)
        XCTAssertEqual(sweeperType, .sweeper)
        XCTAssertNotEqual(enforcementType, sweeperType)
    }
}

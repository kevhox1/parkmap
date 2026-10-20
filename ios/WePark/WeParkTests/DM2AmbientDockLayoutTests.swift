//
//  DM2AmbientDockLayoutTests.swift
//  WeParkTests
//
//  Live-smoke fix (Kevin, 2026-10-20, PR #133 flag-on cold launch, iPhone 17 sim) — unit
//  tests for `communityMapChromeBottomPadding` (`ContentView.swift`), the pure function that
//  gives the persistent Report pill / "?" map-key button enough bottom clearance to sit
//  ABOVE the goal-first ambient dock (`GoalSelectorView`) instead of drawing over its tile
//  row. Mirrors `W85cPolishTests.swift`'s own `paddingForBannerState` test shape — same
//  "pure logic test against the extracted function, not the live view" rationale.
//
//  NOT covered here (by design, not oversight): `ContentView.communityMapChromeBottomPaddingValue`
//  itself (the private computed property that threads `goalSelectorDockVisible`'s five
//  inputs into this function) requires a live `ContentView` instance to exercise — verified
//  by code inspection (it reads the SAME five inputs `bottomSafeAreaContent`'s own
//  `goalDockVisible` local already uses, so the two can't disagree) plus the mandatory
//  live-UI smoke, same disclosure this codebase's other pure-function test files already
//  make for their own view-layer wiring.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class DM2AmbientDockLayoutTests: XCTestCase {

    // MARK: - communityMapChromeBottomPadding

    func testCommunityMapChromeBottomPadding_dockHidden_matchesLegacySheetClearance() {
        let padding = communityMapChromeBottomPadding(goalDockVisible: false, browseSheetPeekHeight: 64)
        XCTAssertEqual(
            padding, 76,
            "flag-off / dock-not-visible must stay byte-identical to the pre-fix `browseSheetPeekHeight + 12` clearance"
        )
    }

    func testCommunityMapChromeBottomPadding_dockHidden_tracksLivePeekHeight() {
        let padding = communityMapChromeBottomPadding(goalDockVisible: false, browseSheetPeekHeight: 120)
        XCTAssertEqual(
            padding, 132,
            "dock-not-visible must keep reading the live browseSheetPeekHeight, not a frozen constant — unchanged from pre-fix behavior"
        )
    }

    func testCommunityMapChromeBottomPadding_dockVisible_returnsFixedWorstCaseClearance() {
        let padding = communityMapChromeBottomPadding(goalDockVisible: true, browseSheetPeekHeight: 64)
        XCTAssertEqual(padding, 326)
    }

    func testCommunityMapChromeBottomPadding_dockVisible_ignoresBrowseSheetPeekHeight() {
        // The FT-20 browse sheet never mounts while the ambient dock is up
        // (`activeSheet == nil` is one of `goalSelectorDockVisible`'s own conditions) — the
        // dock-visible branch must be entirely independent of browseSheetPeekHeight.
        let paddingA = communityMapChromeBottomPadding(goalDockVisible: true, browseSheetPeekHeight: 64)
        let paddingB = communityMapChromeBottomPadding(goalDockVisible: true, browseSheetPeekHeight: 999)
        XCTAssertEqual(
            paddingA, paddingB,
            "dock-visible clearance must not vary with browseSheetPeekHeight — the sheet isn't mounted in this state"
        )
    }

    func testCommunityMapChromeBottomPadding_dockVisible_clearsFullDockHeightWithBreathingRoom() {
        // The reported bug: the Report pill/"?" button drew over the dock's tile row. This
        // padding value is the button's BOTTOM-edge offset from the screen's bottom edge, so
        // it alone (before even adding the button's own ~48pt height) must already exceed
        // the dock's own worst-case height (toggle 44 + guard banner 60 + "Start Driving" 48
        // + tile row 112 + 3 inter-row gaps of 10 + 8pt dock bottom padding = 302), or the
        // button's bottom edge would still land inside the dock.
        let padding = communityMapChromeBottomPadding(goalDockVisible: true, browseSheetPeekHeight: 64)
        let dockWorstCaseHeight: CGFloat = 302
        XCTAssertGreaterThan(
            padding, dockWorstCaseHeight,
            "the clearance must exceed the dock's full worst-case height, or the button would still draw over the tile row"
        )
    }

    func testCommunityMapChromeBottomPadding_dockVisible_exceedsDockHidden_forSamePeekHeight() {
        // Sanity check on the fix's direction: for the SAME browseSheetPeekHeight, the
        // dock-visible clearance must be strictly larger than the dock-hidden one — the bug
        // was that both branches used to return the identical (too-small) value.
        let hidden = communityMapChromeBottomPadding(goalDockVisible: false, browseSheetPeekHeight: 64)
        let visible = communityMapChromeBottomPadding(goalDockVisible: true, browseSheetPeekHeight: 64)
        XCTAssertGreaterThan(visible, hidden)
    }
}

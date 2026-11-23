//
//  DM2AmbientDockLayoutTests.swift
//  WeParkTests
//
//  Live-smoke fix (Kevin, 2026-10-20, PR #133 flag-on cold launch, iPhone 17 sim) originally
//  added `communityMapChromeBottomPadding` (`ContentView.swift`) with a SECOND, dock-aware
//  branch so the persistent Report pill / "?" map-key button cleared the goal-first ambient
//  dock's tile row instead of drawing over it.
//
//  Addendum 2 (2026-10-21 smoke revisions, `docs/design/goal-first-ambient-design.md` A2.1)
//  neutralizes that branch: Report pill and "?" now have PERMANENT homes
//  (`GoalSelectorView`'s own top row; `recenterButtonStack`'s rail) instead of floating alone
//  and chasing the dock's height with a hand-maintained clearance number —
//  `communityMapChromeOverlay` no longer even renders this chrome while the goal dock is
//  visible (see that property's new third gate, exercised via `goalSelectorDockVisible` in
//  `DM2GoalSelectorTests.swift`). This file now pins the ORIGINAL, single-branch,
//  flag-independent clearance `communityMapChromeBottomPadding(browseSheetPeekHeight:)`
//  reverted to — the dock-aware branch's old tests are gone, not updated, since that behavior
//  no longer exists anywhere in the function.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class DM2AmbientDockLayoutTests: XCTestCase {

    // MARK: - communityMapChromeBottomPadding (reverted to legacy, flag-independent shape)

    func testCommunityMapChromeBottomPadding_matchesLegacySheetClearance() {
        let padding = communityMapChromeBottomPadding(browseSheetPeekHeight: 64)
        XCTAssertEqual(
            padding, 76,
            "Addendum 2: this function is back to the single pre-PR-#134 shape — " +
            "browseSheetPeekHeight + 12, with no second branch."
        )
    }

    func testCommunityMapChromeBottomPadding_tracksLivePeekHeight() {
        let padding = communityMapChromeBottomPadding(browseSheetPeekHeight: 120)
        XCTAssertEqual(
            padding, 132,
            "must keep reading the live browseSheetPeekHeight, not a frozen constant."
        )
    }

    func testCommunityMapChromeBottomPadding_isLinearInPeekHeight() {
        // Sanity check on the function's single remaining shape: strictly
        // peekHeight + 12, no hidden floor/ceiling/second branch left over from the
        // dock-aware era.
        let a = communityMapChromeBottomPadding(browseSheetPeekHeight: 50)
        let b = communityMapChromeBottomPadding(browseSheetPeekHeight: 200)
        XCTAssertEqual(b - a, 150, "the function must be exactly peekHeight + 12 — no other branch left.")
    }

    // MARK: - ambientOverlayBottomPadding (#37 ①: confirm prompt / long-press card / guide banner)

    /// Flag off / dock hidden: byte-identical to the legacy clearance, whatever the (stale)
    /// measured dock height says.
    func testAmbientOverlayBottomPadding_dockHidden_isLegacyRegardlessOfMeasuredHeight() {
        for measured: CGFloat in [0, 120, 600] {
            XCTAssertEqual(
                ambientOverlayBottomPadding(goalDockVisible: false, measuredDockHeight: measured, browseSheetPeekHeight: 64),
                76
            )
        }
    }

    func testAmbientOverlayBottomPadding_dockHidden_tracksPeekHeight() {
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: false, measuredDockHeight: 300, browseSheetPeekHeight: 120),
            132
        )
    }

    /// Dock visible: clears the measured dock height + 12pt gap, standard size and AX5-scale.
    func testAmbientOverlayBottomPadding_dockVisible_clearsMeasuredDock() {
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: true, measuredDockHeight: 230, browseSheetPeekHeight: 64),
            242
        )
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: true, measuredDockHeight: 520, browseSheetPeekHeight: 64),
            532,
            "a tall dock must still be cleared — the value is measured, not a frozen constant"
        )
    }

    /// Unmeasured dock (`.zero`) never yields LESS than the legacy clearance.
    func testAmbientOverlayBottomPadding_dockVisibleButUnmeasured_fallsBackToLegacy() {
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: true, measuredDockHeight: 0, browseSheetPeekHeight: 64),
            76
        )
    }

    /// Flag-off wiring: with `driveModeDefaultEnabled == false` the dock-visible input is
    /// false for every combination of the other inputs, so the padding is always legacy.
    func testAmbientOverlayBottomPadding_flagOff_dockInputAlwaysFalse() {
        XCTAssertFalse(AppConstants.driveModeDefaultEnabled)
        for sheetNil in [true, false] {
            for drive in [true, false] {
                XCTAssertFalse(goalSelectorDockVisible(
                    driveModeDefaultEnabled: false,
                    activeSheetIsNil: sheetNil,
                    driveModeActive: drive,
                    blockSelectModeActive: false,
                    spotPlacementActive: false,
                    curbPlacementActive: false
                ))
            }
        }
    }

    /// AX5: the dock outgrows the screen; the card must stay on-screen (capped at 45% of the
    /// container), not chase the dock's off-screen top.
    func testAmbientOverlayBottomPadding_overflowingDock_isCappedToKeepCardOnScreen() {
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: true, measuredDockHeight: 1100, containerHeight: 800, browseSheetPeekHeight: 64),
            360
        )
        // Standard size: cap does not bite.
        XCTAssertEqual(
            ambientOverlayBottomPadding(goalDockVisible: true, measuredDockHeight: 230, containerHeight: 800, browseSheetPeekHeight: 64),
            242
        )
    }
}

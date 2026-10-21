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
}

//
//  FT20StreamATests.swift
//  WeParkTests
//
//  FT-20 Stream A — browse-mode bottom sheet CONTAINER.
//  docs/ft20-bottom-sheet-navigation-spec.md §4.1/§4.2, §0b findings B1/B2.
//
//  `BrowseSheetDetentMath` is a pure, UIKit-free function — no simulator/rendering
//  required, so it's covered directly here (mirroring the `paddingForBannerState` /
//  `gearButtonVisible` / `recenterButtonStackVisible` precedent already established in
//  FT13Tests.swift / FT18Tests.swift). `BrowseNavigationSheet`'s actual on-screen rendering
//  (row anatomy, detent behavior, keyboard avoidance) has no ViewInspector/snapshot library
//  in this repo and is out of reach on this Linux VPS — it's covered by Kevin's on-device
//  live-UI smoke per this project's standing protocol, not by these tests.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class BrowseSheetDetentMathTests: XCTestCase {

    // MARK: - peekHeight

    func testPeekHeight_addsGrabberAllowanceToMeasuredSearchHeight() {
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 60)
        XCTAssertEqual(
            result,
            60 + BrowseSheetDetentMath.grabberAndInsetAllowance,
            "Peek height should be the measured search-area height plus the grabber/inset allowance."
        )
    }

    func testPeekHeight_flooredAtMinimumForAVeryShortOrUnmeasuredSearchArea() {
        // searchAreaHeight: 0 simulates the very first layout pass, before
        // .onGeometryChange has fired even once.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 0)
        XCTAssertEqual(
            result,
            BrowseSheetDetentMath.minimumPeekHeight,
            "An unmeasured (height 0) or pathologically short search area must never " +
            "produce a peek detent shorter than the 44pt-touch-target-plus-grabber floor " +
            "(spec §4.1: 'Peek must clear a full 44pt touch target plus the grabber')."
        )
    }

    func testPeekHeight_floorAppliesEvenForNegativeInput() {
        // Defensive: GeometryProxy heights should never be negative in practice, but the
        // floor must hold regardless of what's fed in.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: -10)
        XCTAssertEqual(result, BrowseSheetDetentMath.minimumPeekHeight)
    }

    func testPeekHeight_growsWithLargerMeasuredContent() {
        // Dynamic Type at a large accessibility size inflates the search row — the peek
        // detent must grow to match, not stay pinned at a small default.
        let small = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 50)
        let large = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 140)
        XCTAssertGreaterThan(
            large, small,
            "Peek height must scale with the measured content, not be a fixed constant " +
            "(design-review finding B2 — Dynamic Type support)."
        )
    }

    // MARK: - mediumHeight

    func testMediumHeight_isPeekPlusActionListWhenUnderTheCeiling() {
        let searchHeight: CGFloat = 60
        let listHeight: CGFloat = 180
        let ceiling: CGFloat = 1000  // effectively unreachable — isolates the "no clamp" path

        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionListHeight: listHeight,
            maxAllowedHeight: ceiling
        )

        let expectedPeek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchHeight)
        XCTAssertEqual(
            result, expectedPeek + listHeight,
            "Medium height should be exactly peek height + the measured 3-row action list " +
            "height — 'search + exactly three rows and no more' (OQ-3) — when nothing " +
            "forces a clamp."
        )
    }

    func testMediumHeight_clampsAtCeilingForRunawayDynamicType() {
        // Simulates an AX5-class Dynamic Type size where the search row and 3 rows would,
        // uncapped, sum past what should ever be reachable by the "custom" medium detent.
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: 300,
            actionListHeight: 900,
            maxAllowedHeight: 500
        )
        XCTAssertEqual(
            result, 500,
            "Medium height must never exceed maxAllowedHeight — design-review finding B2: " +
            "a runaway Dynamic Type size must not push the custom medium detent up to, or " +
            "past, `.large`."
        )
    }

    func testMediumHeight_neverExceedsMaxAllowedHeightAcrossARangeOfInputs() {
        let ceiling: CGFloat = 400
        for searchHeight in stride(from: CGFloat(0), through: 400, by: 50) {
            for listHeight in stride(from: CGFloat(0), through: 800, by: 100) {
                let result = BrowseSheetDetentMath.mediumHeight(
                    searchAreaHeight: searchHeight,
                    actionListHeight: listHeight,
                    maxAllowedHeight: ceiling
                )
                XCTAssertLessThanOrEqual(
                    result, ceiling,
                    "mediumHeight(\(searchHeight), \(listHeight)) exceeded the clamp ceiling."
                )
            }
        }
    }

    func testMediumHeight_isAtLeastPeekHeightEvenWhenClamped() {
        // Sanity: the clamp should never be so aggressive that medium collapses below peek
        // for realistic inputs (ceiling comfortably above the peek floor).
        let searchHeight: CGFloat = 60
        let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchHeight)
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionListHeight: 10,
            maxAllowedHeight: peek + 100
        )
        XCTAssertGreaterThanOrEqual(result, peek)
    }

    // MARK: - Regression guard: this is a CUSTOM detent, never `.medium`

    /// Design-review finding B1: an earlier draft of the spec's own §4.1 code sample used
    /// system `.medium` (~40% of screen) for the middle detent, directly contradicting
    /// Kevin's OQ-3 ruling. This isn't something `BrowseSheetDetentMath` itself can
    /// "regress" (it has no notion of `.medium` at all — that's exactly the point: the
    /// computed value is a plain `CGFloat` fed into `.height(_:)`), but this test pins the
    /// expectation that a realistic medium height (search field + 3 short rows, default
    /// Dynamic Type) lands nowhere near a typical device's ~40%-of-screen `.medium` value,
    /// so a future regression that silently reintroduces a system-fraction-sized default
    /// would be caught here.
    func testMediumHeight_realisticContentIsFarShorterThanSystemMediumFraction() {
        // Rough measured values for "search field (single line) + 3 List rows at default
        // Dynamic Type" — see BrowseSheetSearchAreaStub / actionList's row count.
        let realisticSearchHeight: CGFloat = 60
        let realisticListHeight: CGFloat = 170   // ~3 rows × ~44pt insetGrouped row + section insets
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: realisticSearchHeight,
            actionListHeight: realisticListHeight,
            maxAllowedHeight: 1000
        )
        // A typical iPhone's system `.medium` detent is roughly 400-450pt (~40-50% of a
        // ~850-930pt screen height minus safe areas). The realistic content-fit value
        // should be comfortably under that, not approaching it.
        XCTAssertLessThan(
            result, 350,
            "A realistic 'search field + 3 short rows' medium height should be well under " +
            "a typical device's system `.medium` fraction — if this test starts failing " +
            "because the computed value crept up near ~400pt+, check for an accidental " +
            "reintroduction of `.medium`-shaped sizing (design-review finding B1)."
        )
    }
}

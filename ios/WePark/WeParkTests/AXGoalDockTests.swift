//
//  AXGoalDockTests.swift
//  WeParkTests
//
//  Open item #37 6 — accessibility-size goal dock (`docs/design/goal-first-ambient-design.md`,
//  "Addendum - accessibility-size goal dock (2026-11-23)"). Pure branching rules, the map
//  budget (measured by laying the real `GoalSelectorView` out headlessly at a pinned Dynamic
//  Type size), the overlay clearance with a measured AX dock, and the coach copy/anchor rules.
//

import XCTest
import SwiftUI
@testable import WePark

@MainActor
final class AXGoalDockTests: XCTestCase {

    // MARK: - Layout branching

    func testUsesGoalCard_onlyAtAccessibilitySizes() {
        let nonAX: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
        for size in nonAX {
            XCTAssertFalse(goalDockUsesGoalCard(dynamicTypeSize: size, fullPaletteMode: false), "\(size)")
        }
        let ax: [DynamicTypeSize] = [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        for size in ax {
            XCTAssertTrue(goalDockUsesGoalCard(dynamicTypeSize: size, fullPaletteMode: false), "\(size)")
        }
    }

    func testUsesGoalCard_fullPaletteModeKeepsItsOwnRow() {
        XCTAssertFalse(goalDockUsesGoalCard(dynamicTypeSize: .accessibility3, fullPaletteMode: true))
    }

    func testCardSubLabel_shownAtAX1AX2_droppedFromAX3Up() {
        XCTAssertTrue(goalCardShowsSubLabel(dynamicTypeSize: .large))
        XCTAssertTrue(goalCardShowsSubLabel(dynamicTypeSize: .accessibility1))
        XCTAssertTrue(goalCardShowsSubLabel(dynamicTypeSize: .accessibility2))
        XCTAssertFalse(goalCardShowsSubLabel(dynamicTypeSize: .accessibility3))
        XCTAssertFalse(goalCardShowsSubLabel(dynamicTypeSize: .accessibility4))
        XCTAssertFalse(goalCardShowsSubLabel(dynamicTypeSize: .accessibility5))
    }

    func testCardChangeWord_followsTheSubLabelThreshold() {
        XCTAssertTrue(goalCardShowsChangeWord(dynamicTypeSize: .large))
        XCTAssertTrue(goalCardShowsChangeWord(dynamicTypeSize: .accessibility2))
        XCTAssertFalse(goalCardShowsChangeWord(dynamicTypeSize: .accessibility3))
        XCTAssertFalse(goalCardShowsChangeWord(dynamicTypeSize: .accessibility5))
    }

    // MARK: - Card selection + accessibility copy

    func testCardAccessibilityLabel_namesSelectedGoalAndCarriesSubLabel() {
        XCTAssertEqual(
            ParkingGoal.freeOvernight.goalCardAccessibilityLabel,
            "Overnight, Won't need to move it. Selected. Double tap to change goal."
        )
        XCTAssertEqual(
            ParkingGoal.freeFewHours.goalCardAccessibilityLabel,
            "A Few Hours, No meter, no cost. Selected. Double tap to change goal."
        )
        XCTAssertEqual(
            ParkingGoal.parkAndForget.goalCardAccessibilityLabel,
            "Park & Forget, Go days without moving it. Selected. Double tap to change goal."
        )
    }

    func testDockCopyIsUnchangedFromTheLockedTileCopy() {
        XCTAssertEqual(ParkingGoal.freeOvernight.dockIcon, "moon.stars.fill")
        XCTAssertEqual(ParkingGoal.freeFewHours.dockIcon, "hourglass")
        XCTAssertEqual(ParkingGoal.parkAndForget.dockIcon, "parkingsign.circle.fill")
        XCTAssertEqual(ParkingGoal.freeFewHours.dockPrimary, "A Few Hours")
        XCTAssertEqual(ParkingGoal.parkAndForget.dockSubLabel, "Go days without moving it")
    }

    // MARK: - Map budget (measured on the real view)

    private let screenWidth: CGFloat = 402
    private let screenHeight: CGFloat = 874   // iPhone 17 Pro-class
    private let bottomSafeInset: CGFloat = 34

    private func dockHeight(
        _ size: DynamicTypeSize,
        goal: ParkingGoal = .freeOvernight,
        banner: EmptyMapGuardKind? = nil,
        fullPalette: Bool = false
    ) -> CGFloat {
        let view = GoalSelectorView(
            selectedGoal: goal,
            fullPaletteMode: fullPalette,
            emptyMapGuardKind: banner,
            onSelectGoal: { _ in },
            onReturnToGoals: {},
            onStartDriving: {}
        )
        .environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: view)
        let fit = host.sizeThatFits(in: CGSize(width: screenWidth, height: .greatestFiniteMagnitude))
        return fit.height + bottomSafeInset
    }

    /// Worst no-banner case is Park & Forget (its name wraps to two lines on the card).
    func testBudget_dockAtMostFortyPercent_atEveryAXSize_everyGoal() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            for goal in ParkingGoal.allCases {
                let h = dockHeight(size, goal: goal)
                XCTAssertLessThanOrEqual(h, screenHeight * 0.40, "\(size) \(goal): dock \(h)pt of \(screenHeight)")
            }
        }
    }

    /// Amendment section 3: with the banner chip, the dock stays within 45% at every AX size for
    /// every banner kind and every goal (the full-sentence banner measured 49-59%).
    func testBudget_withBannerChip_dockAtMostFortyFivePercent() {
        let kinds: [EmptyMapGuardKind] = [.steppedDown, .sparse, .empty]
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            for kind in kinds {
                for goal in ParkingGoal.allCases {
                    let h = dockHeight(size, goal: goal, banner: kind)
                    XCTAssertLessThanOrEqual(h, screenHeight * 0.45, "\(size) \(kind) \(goal): dock \(h)pt")
                }
            }
        }
    }

    /// The chip adds at most 44pt + the 4pt gap above Start Driving (48pt) to the no-banner dock
    /// (AX1 keeps "Change" with a chip, so the like-for-like comparison is at AX1 and AX3+).
    func testChip_addsAtMostFortyEightPoints() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let delta = dockHeight(size, banner: .empty) - dockHeight(size)
            XCTAssertLessThanOrEqual(delta, 48.5, "\(size): chip delta \(delta)")
            XCTAssertGreaterThanOrEqual(delta, 47.5, "\(size): chip delta \(delta)")
        }
    }

    /// Below AX1 the full banner is unchanged (far taller than the 48pt chip).
    func testBelowAX1_fullBannerStillRenders_notTheChip() {
        let delta = dockHeight(.large, banner: .empty) - dockHeight(.large)
        XCTAssertGreaterThan(delta, 48.5)
        XCTAssertFalse(goalDockUsesBannerChip(dynamicTypeSize: .xxxLarge, fullPaletteMode: false))
        XCTAssertTrue(goalDockUsesBannerChip(dynamicTypeSize: .accessibility1, fullPaletteMode: false))
        XCTAssertFalse(goalDockUsesBannerChip(dynamicTypeSize: .accessibility1, fullPaletteMode: true))
    }

    /// Dock type cap: AX4 and AX5 freeze at AX3 sizing, so the dock stops growing.
    func testBudget_dockFrozenAtAX3SizingAbove() {
        XCTAssertEqual(dockHeight(.accessibility4), dockHeight(.accessibility3), accuracy: 1)
        XCTAssertEqual(dockHeight(.accessibility5), dockHeight(.accessibility3), accuracy: 1)
    }

    /// Below AX1 nothing changes. 232pt is what the shipped layout measures at `.large`
    /// (56 Start Driving + 10 gap + 158 tile row, a 3-line sub-label wraps + 8 pad)
    /// (Re-verified against main live at `large`; see PR description.)
    func testBelowAX1_dockHeightIsTheShippedA33Layout() {
        XCTAssertEqual(dockHeight(.large) - bottomSafeInset, 232, accuracy: 0.5)
    }

    // MARK: - Overlay clearance with the measured AX dock

    /// With the dock inside its 40% budget the measured clearance (dock + 12) is what is used;
    /// the 45% clamp no longer binds.
    func testOverlayPadding_axDockWithinBudget_usesMeasuredClearanceNotClamp() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let h = dockHeight(size, goal: .parkAndForget) - bottomSafeInset  // frame height, as `onboardingGoalDockFrame` reports
            let padding = ambientOverlayBottomPadding(
                goalDockVisible: true,
                measuredDockHeight: h,
                containerHeight: screenHeight,
                browseSheetPeekHeight: 64
            )
            XCTAssertEqual(padding, h + 12, accuracy: 0.001, "\(size)")
            XCTAssertLessThan(padding, screenHeight * 0.45, "\(size): clamp must not bind")
        }
    }

    // MARK: - Onboarding coach

    func testCoachMark1_axCopyNamesTheCard_otherCopyUnchanged() {
        XCTAssertEqual(
            OnboardingCoachMark.goalTiles.title(accessibilityLayout: true),
            "Tap the goal card to pick what you need"
        )
        XCTAssertEqual(OnboardingCoachMark.goalTiles.title(accessibilityLayout: false), "Pick what you need.")
        XCTAssertEqual(
            OnboardingCoachMark.colorMeaning.title(accessibilityLayout: true),
            OnboardingCoachMark.colorMeaning.title
        )
        XCTAssertEqual(
            OnboardingCoachMark.tapABlock.title(accessibilityLayout: true),
            OnboardingCoachMark.tapABlock.title
        )
    }

    /// Selection (not the card tap) is what dismisses mark 1: the card never calls
    /// `onSelectGoal`, the sheet tiles do, and mark 1 is dismissed by goal selection.
    func testCoachMark1_isDismissedByGoalSelection() {
        XCTAssertTrue(OnboardingCoachMark.goalTiles.dismissedByGoalTileTap)
    }

    /// The card is both "row" and "selected tile": the selected-tile frame the caller derives
    /// from the per-goal dictionary is the card's frame once the card reports under the
    /// selected goal's key.
    func testCoachAnchors_cardFrameIsBothRowAndSelectedTile() {
        let card = CGRect(x: 16, y: 600, width: 370, height: 170)
        let frames = [ParkingGoal.freeFewHours.rawValue: card]
        XCTAssertEqual(
            onboardingSelectedTileFrame(tileFrames: frames, selectedGoalRawValue: ParkingGoal.freeFewHours.rawValue),
            card
        )
    }

    func testOverlayRenders_atAX5_markOneAndTwo() {
        let dock = CGRect(x: 0, y: 560, width: 402, height: 314)
        let card = CGRect(x: 16, y: 700, width: 370, height: 140)
        for mark in [OnboardingCoachMark.goalTiles, .colorMeaning] {
            let view = OnboardingCoachOverlay(
                mark: mark, goalDockFrame: dock, tileRowFrame: card, selectedTileFrame: card,
                nearestCurbScreenPoint: nil, onPrimaryAction: {}, onSkipAll: {}
            )
            .environment(\.dynamicTypeSize, .accessibility5)
            XCTAssertNotNil(UIHostingController(rootView: view).view)
        }
    }

    // MARK: - Dock renders at every AX size and both goals

    func testDockRenders_everyAXSize_everyGoal() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            for goal in ParkingGoal.allCases {
                XCTAssertGreaterThan(dockHeight(size, goal: goal), 0)
            }
        }
    }

    // MARK: - Banner chip (follow-up, amendment section 3)

    func testChipCopy_perKind_isTheSpecifiedShortPhrase() {
        XCTAssertEqual(EmptyMapGuardKind.steppedDown.chipCopy, "Showing best available")
        XCTAssertEqual(EmptyMapGuardKind.sparse.chipCopy, "Only a few blocks clear")
        XCTAssertEqual(EmptyMapGuardKind.empty.chipCopy, "No clear spots nearby")
        for kind in [EmptyMapGuardKind.steppedDown, .sparse, .empty] {
            XCTAssertLessThanOrEqual(kind.chipCopy.count, 23)
            XCTAssertNotEqual(kind.chipCopy, kind.bannerCopy)
        }
    }

    func testFullSentencesAreUnchanged() {
        XCTAssertEqual(EmptyMapGuardKind.steppedDown.bannerCopy, "Nothing clear for a full week nearby \u{2014} showing the best available.")
        XCTAssertEqual(EmptyMapGuardKind.sparse.bannerCopy, "Only a few blocks nearby are clear for a full week.")
        XCTAssertEqual(EmptyMapGuardKind.empty.bannerCopy, "No clear spots found very nearby \u{2014} try Overnight, or pan the map.")
    }

    func testChipConstants() {
        XCTAssertEqual(goalBannerChipMinHeight, 44)
        XCTAssertEqual(goalBannerChipGapAboveStartDriving, 4)
    }

    /// AX2-only rule: with a chip showing, "Change" goes at AX2 too. AX1 keeps it; no chip keeps
    /// the shipped thresholds.
    func testChangeWord_dropsAtAX2OnlyWhenChipShowing() {
        XCTAssertTrue(goalCardShowsChangeWord(dynamicTypeSize: .accessibility1, bannerChipShowing: true))
        XCTAssertFalse(goalCardShowsChangeWord(dynamicTypeSize: .accessibility2, bannerChipShowing: true))
        XCTAssertTrue(goalCardShowsChangeWord(dynamicTypeSize: .accessibility2, bannerChipShowing: false))
        XCTAssertFalse(goalCardShowsChangeWord(dynamicTypeSize: .accessibility3, bannerChipShowing: true))
        XCTAssertTrue(goalCardShowsChangeWord(dynamicTypeSize: .large, bannerChipShowing: false))
    }

    func testGoalSheetOpensLarge_onlyAtAX4Up() {
        XCTAssertFalse(goalSheetOpensLarge(dynamicTypeSize: .accessibility3))
        XCTAssertTrue(goalSheetOpensLarge(dynamicTypeSize: .accessibility4))
        XCTAssertTrue(goalSheetOpensLarge(dynamicTypeSize: .accessibility5))
        XCTAssertFalse(goalSheetOpensLarge(dynamicTypeSize: .large))
    }

    // MARK: - Coach bubble region (follow-up, pure math)

    func testSkipTop_belowAX1_isLegacy_atAXDropsBelowBanner() {
        XCTAssertEqual(onboardingCoachSkipTop(safeMinY: 62, topChromeBottom: 203, accessibilityLayout: false), 70)
        XCTAssertEqual(onboardingCoachSkipTop(safeMinY: 62, topChromeBottom: 203, accessibilityLayout: true), 207)
        // A short banner never moves Skip above the legacy position.
        XCTAssertEqual(onboardingCoachSkipTop(safeMinY: 62, topChromeBottom: 40, accessibilityLayout: true), 70)
    }

    func testRegionTop_equalsLegacyWhenSkipUnmoved() {
        let band: CGFloat = 60
        XCTAssertEqual(onboardingCoachRegionTop(safeMinY: 62, skipTop: 70, skipBandHeight: band), 62 + band)
        XCTAssertEqual(onboardingCoachRegionTop(safeMinY: 62, skipTop: 207, skipBandHeight: 86), 285)
    }

    /// AX5 geometry from the QA repro: 203pt ASP banner, dock top 568 (chip showing). The
    /// region must start below the banner + Skip and end at dock top - 12, never overlapping.
    func testVerticalBounds_ax5_regionBetweenChromeAndDockMinus12() {
        let skipTop = onboardingCoachSkipTop(safeMinY: 62, topChromeBottom: 203, accessibilityLayout: true)
        let top = onboardingCoachRegionTop(safeMinY: 62, skipTop: skipTop, skipBandHeight: 86)
        let dockTop: CGFloat = 568
        let b = onboardingCoachBubbleVerticalBounds(
            top: top, bottom: dockTop - 12, safeMaxY: 840, minimumHeight: 170, accessibilityLayout: true
        )
        XCTAssertGreaterThanOrEqual(b.top, 203 + 4 + 44)   // below banner and the 44pt Skip
        XCTAssertEqual(b.bottom, dockTop - 12)
        XCTAssertGreaterThan(b.bottom - b.top, 140)
    }

    /// Below AX1 the legacy "may extend to the minimum height" behavior is unchanged.
    func testVerticalBounds_belowAX1_keepsLegacyMinimumExtension() {
        let b = onboardingCoachBubbleVerticalBounds(
            top: 120, bottom: 150, safeMaxY: 840, minimumHeight: 170, accessibilityLayout: false
        )
        XCTAssertEqual(b.bottom, 290)
    }

    /// At AX a short region is NOT stretched over the dock (only the hard floor applies).
    func testVerticalBounds_ax_doesNotStretchPastTheDockWhenRegionIsUsable() {
        let b = onboardingCoachBubbleVerticalBounds(
            top: 300, bottom: 480, safeMaxY: 840, minimumHeight: 400, accessibilityLayout: true
        )
        XCTAssertEqual(b.bottom, 480)
    }

    // MARK: - Rail clearance (follow-up, pure math)

    func testRailClearance_pullsTrailingEdgeLeftOfRail_whenVerticallyOverlapping() {
        let rail = CGRect(x: 330, y: 100, width: 56, height: 124)   // Search + More
        let maxX = onboardingCoachRailAdjustedSafeMaxX(
            safeMaxX: 402, railFrame: rail, regionTop: 200, regionBottom: 500
        )
        let width = onboardingCoachBubbleWidth(safeWidth: maxX - 0)
        let centerX = onboardingCoachBubbleCenterX(anchorX: nil, bubbleWidth: width, safeMinX: 0, safeMaxX: maxX)
        let rightEdge = centerX + width / 2
        XCTAssertLessThanOrEqual(rightEdge, rail.minX - 8 + 0.001)
        XCTAssertGreaterThanOrEqual(centerX - width / 2, 20)
    }

    func testRailClearance_noChangeWithoutOverlapOrMeasurement() {
        let rail = CGRect(x: 330, y: 100, width: 56, height: 124)
        XCTAssertEqual(onboardingCoachRailAdjustedSafeMaxX(safeMaxX: 402, railFrame: rail, regionTop: 300, regionBottom: 600), 402)
        XCTAssertEqual(onboardingCoachRailAdjustedSafeMaxX(safeMaxX: 402, railFrame: .zero, regionTop: 100, regionBottom: 600), 402)
    }

    func testRailClearance_neverWidensPastSafeArea() {
        let rail = CGRect(x: 500, y: 100, width: 56, height: 124)
        XCTAssertEqual(onboardingCoachRailAdjustedSafeMaxX(safeMaxX: 402, railFrame: rail, regionTop: 100, regionBottom: 600), 402)
    }

    func testOverlayRenders_atAX5_withMeasuredChromeAndRail() {
        let dock = CGRect(x: 0, y: 568, width: 402, height: 306)
        let card = CGRect(x: 16, y: 700, width: 370, height: 140)
        for mark in [OnboardingCoachMark.goalTiles, .colorMeaning, .tapABlock] {
            let view = OnboardingCoachOverlay(
                mark: mark, goalDockFrame: dock, tileRowFrame: card, selectedTileFrame: card,
                nearestCurbScreenPoint: nil,
                topChromeBottom: 203,
                railFrame: CGRect(x: 330, y: 100, width: 56, height: 124),
                onPrimaryAction: {}, onSkipAll: {}
            )
            .environment(\.dynamicTypeSize, .accessibility5)
            XCTAssertNotNil(UIHostingController(rootView: view).view)
        }
    }
}

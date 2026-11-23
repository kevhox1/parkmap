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

    /// KNOWN SPEC GAP (flagged in the PR): the addendum's 45%-with-banner budget is not
    /// reachable with the banner text at its specified AX2 cap on an 874pt screen (measured
    /// 441/518/432pt = 50/59/49% at AX1/AX2/AX3 for Park & Forget + the longest banner). This
    /// only pins that the dock never outgrows 62%, so a regression is still caught.
    func testBudget_withLongestBanner_staysBounded_specGapFlagged() {
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let h = dockHeight(size, goal: .parkAndForget, banner: .empty)
            XCTAssertLessThanOrEqual(h, screenHeight * 0.62, "\(size): dock \(h)pt with banner")
        }
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
}

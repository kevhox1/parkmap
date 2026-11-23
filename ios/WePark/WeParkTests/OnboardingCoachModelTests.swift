//
//  OnboardingCoachModelTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2) —
//  unit tests for the pure coach-layer sequencing model (`Models/OnboardingCoachModel.swift`).
//
//  Test groups:
//    1. `OnboardingCoachMark` content — exact copy, primary action labels, real-control-tap
//       membership.
//    2. Sequencing — first mark, next-mark advance.
//    3. `onboardingCoachShouldShow(...)` — every combination.
//    4. `onboardingCoachOverlayVisible(...)` — the rest-posture-only exclusion list, every
//       combination.
//    5/6. Selected-tile frame derivation and bubble layout clamping (QA follow-up).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
@testable import WePark

final class OnboardingCoachModelTests: XCTestCase {

    // MARK: - 1. Mark content (§2.2 — exact copy)

    func testMark1_goalTiles_exactCopy() {
        XCTAssertEqual(OnboardingCoachMark.goalTiles.title, "Pick what you need.")
        XCTAssertEqual(OnboardingCoachMark.goalTiles.subtitle, "The map will only show spots that match.")
        XCTAssertEqual(OnboardingCoachMark.goalTiles.primaryActionLabel, "Got it")
        XCTAssertTrue(OnboardingCoachMark.goalTiles.dismissedByGoalTileTap)
    }

    func testMark2_colorMeaning_exactCopy() {
        XCTAssertEqual(
            OnboardingCoachMark.colorMeaning.title,
            "Green means you're covered. Red means you'll have to move it."
        )
        XCTAssertNil(OnboardingCoachMark.colorMeaning.subtitle)
        XCTAssertEqual(OnboardingCoachMark.colorMeaning.primaryActionLabel, "Got it")
        XCTAssertTrue(OnboardingCoachMark.colorMeaning.dismissedByGoalTileTap)
    }

    func testMark3_tapABlock_exactCopy() {
        XCTAssertEqual(OnboardingCoachMark.tapABlock.title, "Tap any block to see why.")
        XCTAssertNil(OnboardingCoachMark.tapABlock.subtitle)
        // Mark 3's primary action is "Done", not "Got it" — it's the last mark.
        XCTAssertEqual(OnboardingCoachMark.tapABlock.primaryActionLabel, "Done")
        XCTAssertFalse(OnboardingCoachMark.tapABlock.dismissedByGoalTileTap)
    }

    /// AC-31 check: same vocabulary discipline as the story deck.
    func testNoMark_containsBannedVocabulary() {
        let banned = ["avoid", "ticket", "fine", "evasion", "dodge"]
        for mark in OnboardingCoachMark.allCases {
            let text = (mark.title + " " + (mark.subtitle ?? "")).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "mark \(mark) copy must not contain \"\(word)\"")
            }
        }
    }

    // MARK: - 2. Sequencing

    func testFirstMark_isGoalTiles() {
        XCTAssertEqual(onboardingCoachFirstMark(), .goalTiles)
    }

    func testNextMark_advancesInOrder() {
        XCTAssertEqual(onboardingCoachNextMark(after: .goalTiles), .colorMeaning)
        XCTAssertEqual(onboardingCoachNextMark(after: .colorMeaning), .tapABlock)
        XCTAssertNil(onboardingCoachNextMark(after: .tapABlock))
    }

    // MARK: - 3. onboardingCoachShouldShow(...) — every combination

    func testShouldShow_trueOnlyWhenBothFlagsAndGateAreTrue() {
        for storyFlag in [true, false] {
            for driveFlag in [true, false] {
                for gate in [true, false] {
                    let expected = storyFlag && driveFlag && gate
                    XCTAssertEqual(
                        onboardingCoachShouldShow(
                            onboardingStoryEnabled: storyFlag,
                            driveModeDefaultEnabled: driveFlag,
                            gateShouldShow: gate
                        ),
                        expected
                    )
                }
            }
        }
    }

    // MARK: - 4. onboardingCoachOverlayVisible(...) — rest-posture-only, every combination

    func testOverlayVisible_onlyWhenEveryExclusionClears() {
        for activeSheetIsNil in [true, false] {
            for driveModeActive in [true, false] {
                for blockSelectModeActive in [true, false] {
                    for spotPlacementActive in [true, false] {
                        for curbPlacementActive in [true, false] {
                            let expected = activeSheetIsNil && !driveModeActive
                                && !blockSelectModeActive && !spotPlacementActive
                                && !curbPlacementActive
                            XCTAssertEqual(
                                onboardingCoachOverlayVisible(
                                    activeSheetIsNil: activeSheetIsNil,
                                    driveModeActive: driveModeActive,
                                    blockSelectModeActive: blockSelectModeActive,
                                    spotPlacementActive: spotPlacementActive,
                                    curbPlacementActive: curbPlacementActive
                                ),
                                expected
                            )
                        }
                    }
                }
            }
        }
    }

    /// QA #1: the coach never mounts while LocationPrimingCard is showing.
    func testOverlayVisible_falseWhilePrimingCardShowing() {
        XCTAssertFalse(onboardingCoachOverlayVisible(
            activeSheetIsNil: true, driveModeActive: false, blockSelectModeActive: false,
            spotPlacementActive: false, curbPlacementActive: false, primingCardShowing: true
        ))
        XCTAssertTrue(onboardingCoachOverlayVisible(
            activeSheetIsNil: true, driveModeActive: false, blockSelectModeActive: false,
            spotPlacementActive: false, curbPlacementActive: false, primingCardShowing: false
        ))
    }

    // MARK: - 5. Selected-tile frame (QA #5)

    func testSelectedTileFrame_followsSelection_notLastReporter() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 50),
            "b": CGRect(x: 110, y: 0, width: 100, height: 50),
            "c": CGRect(x: 220, y: 0, width: 100, height: 50)
        ]
        XCTAssertEqual(onboardingSelectedTileFrame(tileFrames: frames, selectedGoalRawValue: "a").minX, 0)
        XCTAssertEqual(onboardingSelectedTileFrame(tileFrames: frames, selectedGoalRawValue: "b").minX, 110)
        XCTAssertEqual(onboardingSelectedTileFrame(tileFrames: frames, selectedGoalRawValue: "c").minX, 220)
    }

    func testSelectedTileFrame_missing_isZero() {
        XCTAssertEqual(onboardingSelectedTileFrame(tileFrames: [:], selectedGoalRawValue: "a"), .zero)
    }

    // MARK: - 6. Bubble layout (QA #3/#4)

    func testBubbleWidth_cappedAndSafeAreaBound() {
        XCTAssertEqual(onboardingCoachBubbleWidth(safeWidth: 393), 320)
        XCTAssertEqual(onboardingCoachBubbleWidth(safeWidth: 300), 260)
        XCTAssertEqual(onboardingCoachBubbleWidth(safeWidth: 10), 0)
    }

    func testBubbleCenterX_clampsLeftAndRight() {
        // Width 320 in a 393-wide safe area: center must stay within [180, 213].
        XCTAssertEqual(onboardingCoachBubbleCenterX(anchorX: 0, bubbleWidth: 320, safeMinX: 0, safeMaxX: 393), 180)
        XCTAssertEqual(onboardingCoachBubbleCenterX(anchorX: 400, bubbleWidth: 320, safeMinX: 0, safeMaxX: 393), 213)
        XCTAssertEqual(onboardingCoachBubbleCenterX(anchorX: 200, bubbleWidth: 320, safeMinX: 0, safeMaxX: 393), 200)
        XCTAssertEqual(onboardingCoachBubbleCenterX(anchorX: nil, bubbleWidth: 320, safeMinX: 0, safeMaxX: 393), 196.5)
    }

    func testBubbleCenterX_neverLeavesSafeArea_atAnyAnchor() {
        for anchor in stride(from: CGFloat(-50), through: 450, by: 25) {
            let w = onboardingCoachBubbleWidth(safeWidth: 393)
            let c = onboardingCoachBubbleCenterX(anchorX: anchor, bubbleWidth: w, safeMinX: 0, safeMaxX: 393)
            XCTAssertGreaterThanOrEqual(c - w / 2, 20)
            XCTAssertLessThanOrEqual(c + w / 2, 373)
        }
    }

    func testBubbleFitsAbove() {
        XCTAssertTrue(onboardingCoachBubbleFitsAbove(anchorY: 500, topLimit: 100, gap: 40, minimumHeight: 140))
        XCTAssertFalse(onboardingCoachBubbleFitsAbove(anchorY: 200, topLimit: 100, gap: 40, minimumHeight: 140))
    }

    func testPointOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        XCTAssertTrue(onboardingCoachPointIsOnScreen(CGPoint(x: 200, y: 400), in: bounds))
        XCTAssertFalse(onboardingCoachPointIsOnScreen(CGPoint(x: -5, y: 400), in: bounds))
        XCTAssertFalse(onboardingCoachPointIsOnScreen(CGPoint(x: 200, y: 900), in: bounds))
        XCTAssertFalse(onboardingCoachPointIsOnScreen(CGPoint(x: 5, y: 400), in: bounds))
    }
}

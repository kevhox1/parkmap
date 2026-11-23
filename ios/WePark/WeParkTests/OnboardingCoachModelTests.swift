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
//    5. `onboardingCoachBearingOffset(...)` — the mark-3 anchor approximation.
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

    // MARK: - 5. onboardingCoachBearingOffset(...)

    /// Due north from the origin should map to a straight-up (negative-y) screen offset with
    /// no horizontal component.
    func testBearingOffset_due_north_pointsUp() {
        let origin = CLLocationCoordinate2D(latitude: 40.730, longitude: -73.990)
        let target = CLLocationCoordinate2D(latitude: 40.735, longitude: -73.990)
        let offset = onboardingCoachBearingOffset(from: origin, to: target, maxOffset: 70)
        XCTAssertEqual(offset.width, 0, accuracy: 0.5)
        XCTAssertLessThan(offset.height, 0, "north must map to a negative (upward) screen y offset")
        XCTAssertEqual(abs(offset.height), 70, accuracy: 0.5)
    }

    /// Due east should map to a rightward (positive-x) offset with no vertical component.
    func testBearingOffset_due_east_pointsRight() {
        let origin = CLLocationCoordinate2D(latitude: 40.730, longitude: -73.990)
        let target = CLLocationCoordinate2D(latitude: 40.730, longitude: -73.980)
        let offset = onboardingCoachBearingOffset(from: origin, to: target, maxOffset: 70)
        XCTAssertGreaterThan(offset.width, 0, "east must map to a positive (rightward) screen x offset")
        XCTAssertEqual(offset.height, 0, accuracy: 0.5)
    }

    /// Identical origin/target — the design doc's own named fallback ("no segment is within
    /// range") must resolve to exactly zero, anchoring at the map's visual center.
    func testBearingOffset_identicalCoordinates_isZero() {
        let point = CLLocationCoordinate2D(latitude: 40.730, longitude: -73.990)
        let offset = onboardingCoachBearingOffset(from: point, to: point, maxOffset: 70)
        XCTAssertEqual(offset.width, 0)
        XCTAssertEqual(offset.height, 0)
    }

    /// The returned offset's magnitude never exceeds `maxOffset`, at a few different bearings.
    func testBearingOffset_neverExceedsMaxOffset() {
        let origin = CLLocationCoordinate2D(latitude: 40.730, longitude: -73.990)
        let targets = [
            CLLocationCoordinate2D(latitude: 40.731, longitude: -73.991),
            CLLocationCoordinate2D(latitude: 40.729, longitude: -73.989),
            CLLocationCoordinate2D(latitude: 40.7305, longitude: -73.9905)
        ]
        for target in targets {
            let offset = onboardingCoachBearingOffset(from: origin, to: target, maxOffset: 40)
            let magnitude = (offset.width * offset.width + offset.height * offset.height).squareRoot()
            XCTAssertLessThanOrEqual(magnitude, 40.5, "offset magnitude must not exceed maxOffset")
        }
    }
}

//
//  OnboardingStoryModelTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §1) —
//  unit tests for the pure story-deck model (`Models/OnboardingStoryModel.swift`).
//
//  Test groups:
//    1. `OnboardingStoryCard` content — exact copy, continue labels, card numbers.
//    2. Deck sequencing — first card, final-card detection, next-card advance.
//    3. `onboardingStoryShouldShow(...)` — the pure gating function, every combination.
//    4. `AppConstants.onboardingStoryEnabled` dark-ships `false`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class OnboardingStoryModelTests: XCTestCase {

    // MARK: - 1. Card content (§1.2 — exact copy)

    func testCard1_problem_exactCopy() {
        XCTAssertEqual(
            OnboardingStoryCard.problem.headline,
            "Parking here is a game you play twice a week."
        )
        XCTAssertEqual(
            OnboardingStoryCard.problem.body,
            "Street cleaning swaps sides on a schedule — park on the wrong one, and you're " +
            "moving the car for no reason."
        )
        XCTAssertEqual(OnboardingStoryCard.problem.continueLabel, "Continue")
        XCTAssertEqual(OnboardingStoryCard.problem.cardNumber, 1)
    }

    func testCard2_ask_exactCopy() {
        XCTAssertEqual(OnboardingStoryCard.ask.headline, "Tell us what you need.")
        XCTAssertEqual(
            OnboardingStoryCard.ask.body,
            "Overnight, a few hours, or days without moving it — pick one, and that's the " +
            "only question the map answers."
        )
        XCTAssertEqual(OnboardingStoryCard.ask.continueLabel, "Continue")
        XCTAssertEqual(OnboardingStoryCard.ask.cardNumber, 2)
    }

    func testCard3_payoff_exactCopy() {
        XCTAssertEqual(OnboardingStoryCard.payoff.headline, "Drive, and the map does the thinking.")
        XCTAssertEqual(
            OnboardingStoryCard.payoff.body,
            "Everything simplifies to two colors — green means you're covered, red means " +
            "you'll have to move it."
        )
        // §1.5: the wording change on the final card signals this tap reveals the product.
        XCTAssertEqual(OnboardingStoryCard.payoff.continueLabel, "Let's go")
        XCTAssertEqual(OnboardingStoryCard.payoff.cardNumber, 3)
    }

    /// AC-31 check (design doc §1.2): none of the banned words appear in any card's copy.
    func testNoCard_containsBannedVocabulary() {
        let banned = ["avoid", "ticket", "fine", "evasion", "dodge"]
        for card in OnboardingStoryCard.allCases {
            let text = (card.headline + " " + card.body).lowercased()
            for word in banned {
                XCTAssertFalse(
                    text.contains(word),
                    "card \(card.cardNumber) copy must not contain banned word \"\(word)\""
                )
            }
        }
    }

    // MARK: - 2. Deck sequencing (§1.5)

    func testFirstCard_isProblem() {
        XCTAssertEqual(onboardingStoryFirstCard(), .problem)
    }

    func testIsFinalCard_onlyTrueForPayoff() {
        XCTAssertFalse(onboardingStoryIsFinalCard(.problem))
        XCTAssertFalse(onboardingStoryIsFinalCard(.ask))
        XCTAssertTrue(onboardingStoryIsFinalCard(.payoff))
    }

    func testNextCard_advancesInOrder() {
        XCTAssertEqual(onboardingStoryNextCard(after: .problem), .ask)
        XCTAssertEqual(onboardingStoryNextCard(after: .ask), .payoff)
        XCTAssertNil(onboardingStoryNextCard(after: .payoff))
    }

    // MARK: - 3. onboardingStoryShouldShow(...) — every combination

    func testShouldShow_trueOnlyWhenBothFlagsAndGateAreTrue() {
        for storyFlag in [true, false] {
            for driveFlag in [true, false] {
                for gate in [true, false] {
                    let expected = storyFlag && driveFlag && gate
                    XCTAssertEqual(
                        onboardingStoryShouldShow(
                            onboardingStoryEnabled: storyFlag,
                            driveModeDefaultEnabled: driveFlag,
                            gateShouldShow: gate
                        ),
                        expected,
                        "story(\(storyFlag)) drive(\(driveFlag)) gate(\(gate)) should resolve \(expected)"
                    )
                }
            }
        }
    }

    // MARK: - 4. Flag dark-ships false

    func testOnboardingStoryEnabled_defaultsFalse() {
        XCTAssertFalse(
            AppConstants.onboardingStoryEnabled,
            "onboardingStoryEnabled must ship dark until Kevin flips it."
        )
    }
}

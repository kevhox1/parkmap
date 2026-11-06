//
//  OnboardingStoryModel.swift
//  WePark
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §1) — the
//  pure model behind `Views/OnboardingStoryView.swift`'s 3-card story deck. Zero SwiftUI,
//  zero UserDefaults, zero side effects: a plain `CaseIterable` enum plus free functions that
//  describe each card's exact copy (§1.2, copied verbatim — do not paraphrase) and the
//  deck's advance/skip/completion semantics (§1.5).
//
//  Declared top-level (not nested inside any MainActor-isolated type) so none of its members
//  inherit MainActor isolation from a container — this project's own compile-failure-class list
//  flags "no == on nested enums in nonisolated code" as a real gotcha; this enum never faces
//  that because it is never nested.
//
//  No Calendar.current. No dates at all.
//

import Foundation

// MARK: - OnboardingStoryCard

/// One of the 3 full-screen story cards, in display order (design doc §1.2).
enum OnboardingStoryCard: Int, CaseIterable, Equatable {
    case problem = 0
    case ask = 1
    case payoff = 2

    /// Exact headline copy, §1.2 — verbatim, not paraphrased.
    nonisolated var headline: String {
        switch self {
        case .problem: return "Parking here is a game you play twice a week."
        case .ask: return "Tell us what you need."
        case .payoff: return "Drive, and the map does the thinking."
        }
    }

    /// Exact body copy, §1.2 — verbatim, not paraphrased.
    nonisolated var body: String {
        switch self {
        case .problem:
            return "Street cleaning swaps sides on a schedule — park on the wrong one, and " +
                "you're moving the car for no reason."
        case .ask:
            return "Overnight, a few hours, or days without moving it — pick one, and that's " +
                "the only question the map answers."
        case .payoff:
            return "Everything simplifies to two colors — green means you're covered, red " +
                "means you'll have to move it."
        }
    }

    /// The Continue button's label — "Continue" on cards 1-2, "Let's go" on card 3 (§1.5): the
    /// wording change signals this tap actually reveals the product, not just another page turn.
    nonisolated var continueLabel: String {
        switch self {
        case .problem, .ask: return "Continue"
        case .payoff: return "Let's go"
        }
    }

    /// 1-based card number for the "Card X of 3" framing used in accessibility labels / the
    /// progress indicator's own semantics (§1.2's own "Card 1 of 3" headers).
    nonisolated var cardNumber: Int { rawValue + 1 }
}

// MARK: - Pure deck semantics (§1.5)

/// Whether `card` is the deck's final card — the Continue button on this card is "Let's go"
/// and tapping it (or Skip, from any card) completes the deck.
nonisolated func onboardingStoryIsFinalCard(_ card: OnboardingStoryCard) -> Bool {
    card.rawValue >= OnboardingStoryCard.allCases.count - 1
}

/// The first card shown when the deck (re)appears — always card 1, both for a fresh cold
/// launch and for a manual "How WePark works" replay (§3.2).
nonisolated func onboardingStoryFirstCard() -> OnboardingStoryCard { .problem }

/// The card a Continue tap advances FROM `card` TO, or `nil` if `card` is already the final
/// card (meaning Continue on it completes the deck instead of advancing). Swiping forward uses
/// the same semantics; swiping backward to revisit an earlier card is allowed and handled by
/// `TabView`'s own binding directly, not through this function (§1.5: "revisiting card 1 from
/// card 2 is allowed, it's cheap and forgiving").
nonisolated func onboardingStoryNextCard(after card: OnboardingStoryCard) -> OnboardingStoryCard? {
    OnboardingStoryCard(rawValue: card.rawValue + 1)
}

// MARK: - Pure gating (design doc §6)

/// Whether the story cover should present on cold launch: both onboarding flags are on
/// (`AppConstants.onboardingExperienceEnabled(...)`) AND the one-shot gate has never fired.
/// `nonisolated` for the same sync-XCTest reason every pure gating function in this codebase is.
nonisolated func onboardingStoryShouldShow(
    onboardingStoryEnabled: Bool,
    driveModeDefaultEnabled: Bool,
    gateShouldShow: Bool
) -> Bool {
    AppConstants.onboardingExperienceEnabled(
        onboardingStoryEnabled: onboardingStoryEnabled,
        driveModeDefaultEnabled: driveModeDefaultEnabled
    ) && gateShouldShow
}

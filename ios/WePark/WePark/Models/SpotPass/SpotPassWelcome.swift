//
//  SpotPassWelcome.swift
//  Models/SpotPass
//
//  Spot Pass C2 (spec 6.2, 6.3; design 8.2): the clip-origin "Tier 1'" Welcome that replaces the
//  3-card story deck, and the pure decisions around it. No SwiftUI, no side effects except the
//  explicit `SpotPassOnboardingState` writes (injectable `UserDefaults`, BackgroundNoteGate
//  convention).
//
//  Composition with `docs/design/first-run-onboarding-design.md` (nothing there changes):
//    organic fresh install        -> story deck -> Tier 2 priming -> Tier 3 coach     (unchanged)
//    clip-origin fresh install    -> THIS Welcome -> Tier 2 priming -> Tier 3 coach
//    existing install (upgrade)   -> coach only (unchanged)
//  Tier 1' depends on `spotHandoffEnabled` and the carry-over context only (not on
//  `onboardingStoryEnabled`); Tier 3 keeps its own flags. It NEVER requests a permission.
//

import Foundation

// MARK: - Origin

nonisolated enum SpotPassOnboardingOrigin: String, Equatable, Sendable {
    case clip
    case organic
    case existing
}

/// How adopting the clip's anonymous session went (spec 6.2).
nonisolated enum ClipAdoptionOutcome: String, Equatable, Sendable {
    /// The clip's session now backs the full app: karma and `helped_count` carry over.
    case adopted
    /// The full app already had a session (a reinstall that kept its keychain, a user who signed in
    /// first): MVP leaves the clip identity as is and shows no tailored welcome (`merge_anon_identity` is Phase 2).
    case keptExistingSession
    /// Nothing from a clip to adopt.
    case noContext
    /// A context exists but its session could not be read or accepted.
    case failed
}

nonisolated enum SpotPassOnboardingPolicy {

    /// Set once, at the sentinel check. `clip` only for a fresh install that arrived with a clip
    /// context AND did not already have a session of its own.
    static func classify(
        isFreshInstall: Bool,
        hasClipContext: Bool,
        adoption: ClipAdoptionOutcome
    ) -> SpotPassOnboardingOrigin {
        guard isFreshInstall else { return .existing }
        guard hasClipContext, adoption != .keptExistingSession, adoption != .noContext else { return .organic }
        return .clip
    }

    /// Whether the tailored Welcome presents (instead of the story deck) on this launch.
    /// A Spot Pass link opening the app wins: "no onboarding on a Universal Link open" (spec 6.3).
    static func shouldShowWelcome(
        enabled: Bool,
        origin: SpotPassOnboardingOrigin?,
        hasClipContext: Bool,
        hasSeenWelcome: Bool,
        linkPending: Bool
    ) -> Bool {
        enabled && origin == .clip && hasClipContext && !hasSeenWelcome && !linkPending
    }
}

// MARK: - Persistence

struct SpotPassOnboardingState {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var origin: SpotPassOnboardingOrigin? {
        defaults.string(forKey: AppConstants.onboardingOriginKey).flatMap(SpotPassOnboardingOrigin.init(rawValue:))
    }

    /// Writes the origin ONLY if none is recorded ("set once at the sentinel check"). Returns the
    /// effective origin.
    @discardableResult
    func recordOriginIfNeeded(_ computed: SpotPassOnboardingOrigin) -> SpotPassOnboardingOrigin {
        if let existing = origin { return existing }
        defaults.set(computed.rawValue, forKey: AppConstants.onboardingOriginKey)
        return computed
    }

    var hasSeenWelcome: Bool { defaults.bool(forKey: AppConstants.hasSeenClipWelcomeKey) }

    /// Welcome completed OR skipped: the deck never shows afterwards; the coach (Tier 3) still runs
    /// because `hasSeenOnboardingCoach` is deliberately left untouched.
    func markWelcomeFinished() {
        defaults.set(true, forKey: AppConstants.hasSeenClipWelcomeKey)
        OnboardingStoryGate(defaults: defaults).markShown()
    }
}

// MARK: - Copy

nonisolated enum SpotPassWelcomeChipStyle: Equatable, Sendable {
    case pending
    case settled
}

nonisolated struct SpotPassWelcomeContent: Equatable, Sendable {
    let headline: String
    let body: String
    let chipLabel: String?
    let chipStyle: SpotPassWelcomeChipStyle?
    let primaryButton: String
    let skipButton: String
    let accessibilityLabel: String

    static let karmaPerPass = 5

    /// Design 8.2 copy matrix. "People helped" counts every pass the driver actually departed:
    /// settled (`passesHelped`) plus waiting on the seeker's thanks (`passesPendingKarma`).
    static func make(for context: ClipHandoffContext) -> SpotPassWelcomeContent {
        let settled = max(0, context.passesHelped)
        let pending = max(0, context.passesPendingKarma)
        let total = settled + pending
        let headline = "Welcome, neighbor."

        if total == 0 {
            let body = "You were ready to pass a spot. That's what this is all about."
            return SpotPassWelcomeContent(
                headline: headline, body: body, chipLabel: nil, chipStyle: nil,
                primaryButton: "Show me around", skipButton: "Skip",
                accessibilityLabel: "\(headline) \(body)"
            )
        }

        let people = total == 1 ? "1 person" : "\(total) people"
        let body = "You've already helped \(people) park."
        let chip: String
        let style: SpotPassWelcomeChipStyle
        let spoken: String
        if pending > 0 {
            chip = "+\(pending * karmaPerPass) karma lands when they say thanks"
            style = .pending
            spoken = "\(pending * karmaPerPass) karma pending until they say thanks."
        } else if total == 1 {
            chip = "+\(karmaPerPass) karma \u{00B7} yours to keep"
            style = .settled
            spoken = "\(karmaPerPass) karma, yours to keep."
        } else {
            chip = "\(total * karmaPerPass) karma"
            style = .settled
            spoken = "\(total * karmaPerPass) karma."
        }
        return SpotPassWelcomeContent(
            headline: headline, body: body, chipLabel: chip, chipStyle: style,
            primaryButton: "Show me around", skipButton: "Skip",
            accessibilityLabel: "\(headline) \(body) \(spoken)"
        )
    }
}

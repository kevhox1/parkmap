//
//  SpotPassSupport.swift
//  Services/SpotPass
//
//  Spot Pass C1: the small collaborators the seeker store depends on, each behind a protocol so
//  tests inject fakes (no real network, no real haptics, no real UserDefaults).
//
//    - `SpotPassPersistence`   the active pass survives a relaunch (UserDefaults, spec §3
//                              "one active pass per seeker").
//    - `SpotPassPreferences`   "show my first name" (default OFF) and "explainer seen".
//    - `SpotPassNameFilter`    the opt-in first name rule (design §9.2, F12; the backend derives it).
//    - `SpotPassFeedback`      the success haptic + VoiceOver announcements (design §1.4, §2.9).
//

import Foundation
import UserNotifications
import UIKit

// MARK: - Persistence

@MainActor
protocol SpotPassPersistence: AnyObject {
    func load() -> SpotPassSession?
    func save(_ session: SpotPassSession)
    func clear()
}

@MainActor
final class UserDefaultsSpotPassPersistence: SpotPassPersistence {

    nonisolated static let key = "wepark.spotPass.activeSession"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SpotPassSession? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SpotPassSession.self, from: data)
    }

    func save(_ session: SpotPassSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Preferences

/// Seeker-side settings (design §9.2). Everything defaults to the privacy-preserving value.
@MainActor
struct SpotPassPreferences {

    /// Whether to show the Spot Pass rationale before creating a pass: only while the system
    /// permission is still undecided AND the user has not already seen the rationale.
    nonisolated static func shouldShowRationale(
        authorizationStatus: UNAuthorizationStatus,
        alreadySeen: Bool
    ) -> Bool {
        authorizationStatus == .notDetermined && !alreadySeen
    }

    nonisolated static let showFirstNameKey = "wepark.spotPass.showFirstName"
    nonisolated static let explainerSeenKey = "wepark.spotPass.explainerSeen"
    nonisolated static let nightModeKey = "wepark.spotPass.nightMode"
    nonisolated static let notificationRationaleSeenKey = "wepark.spotPass.notificationRationaleSeen"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// "Show my first name on my pass". OFF by default (spec §0 decision 2).
    var showFirstName: Bool {
        get { defaults.bool(forKey: Self.showFirstNameKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.showFirstNameKey) }
    }

    var hasSeenExplainer: Bool {
        get { defaults.bool(forKey: Self.explainerSeenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.explainerSeenKey) }
    }

    /// The Spot Pass notification rationale has been shown and answered (allow or "Not now").
    /// Once true it is never shown again; the pass relies on polling if notifications are off.
    var notificationRationaleSeen: Bool {
        get { defaults.bool(forKey: Self.notificationRationaleSeenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.notificationRationaleSeenKey) }
    }

    /// Night brightness (70%) instead of maximum (design §2.6). Persisted.
    var nightMode: Bool {
        get { defaults.bool(forKey: Self.nightModeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.nightModeKey) }
    }
}

// MARK: - First name (opt-in)

/// Client-side mirror of the design §10.3 rule so the badge shows what the driver will see: a name
/// that fails the check silently falls back to the alias. The SERVER is the source of truth (it
/// stores and shows the name); if `create_handoff` echoes `display_name` the badge uses that.
nonisolated enum SpotPassNameFilter {

    static let maxLength = 20

    /// Authority/impersonation and urgency words from design §10.3 (substring check). Deliberately
    /// short: this is a courtesy mirror, not the moderation boundary.
    private static let blockedSubstrings = [
        "cop", "officer", "police", "warden", "agent", "inspector", "ticket", "admin",
        "hurry", "rush", "steal", "grab", "snatch", "wepark"
    ]

    /// The first name the SERVER will use for `show_name = true` (backend PR #161): the first word
    /// of `profiles.username`, unless it is an auto `neighbor-xxxxxxxx` handle (then none). Passed
    /// through `cleaned` as a courtesy mirror of the design section 10.3 fallback.
    static func firstName(fromUsername username: String?) -> String? {
        guard let username else { return nil }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("neighbor-") { return nil }
        return cleaned(trimmed)
    }

    /// Trimmed first token of a name, or nil if empty, too long, not letters, or blocked.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first.map(String.init) ?? ""
        guard !first.isEmpty, first.count <= maxLength else { return nil }
        let allowed = first.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
        guard allowed else { return nil }
        let lowered = first.lowercased()
        if blockedSubstrings.contains(where: { lowered.contains($0) }) { return nil }
        return first
    }
}

// MARK: - Feedback (haptics + VoiceOver)

@MainActor
protocol SpotPassFeedback: AnyObject {
    /// `.notification(.success)`: the seeker cannot see their screen while presenting it (F2).
    func success()
    func announce(_ message: String)
}

@MainActor
final class SpotPassSystemFeedback: SpotPassFeedback {
    private let generator = UINotificationFeedbackGenerator()

    func success() {
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

//
//  ReminderOffsets.swift
//  WePark
//
//  FT-6: Customizable ASP Reminder Timing — data model.
//
//  Codable struct of five Bool fields. One field per preset. Persisted in UserDefaults
//  under AppConstants.reminderOffsetsKey as JSON-encoded Data.
//
//  Preset-to-ruleIndex mapping (STABLE — never reorder, see spec §4.2):
//    r0 = 15 minutes before   (lead: 900s)
//    r1 = 30 minutes before   (lead: 1800s)
//    r2 = 1 hour before       (lead: 3600s)  ← the original W6 single-notification default
//    r3 = 2 hours before      (lead: 7200s)
//    r4 = Night before        (special: 20:00 ET on prior calendar evening)
//
//  Default value = { remind1Hour: true, all others: false }
//  This default reproduces the pre-FT-6 single-1h-notification behavior exactly.
//  Existing users see no change on upgrade.
//
//  No import SwiftUI — pure model (no framework deps beyond Foundation).
//  No Calendar.current — no date math in this file.
//

import Foundation

struct ReminderOffsets: Codable, Equatable {

    /// r0 — fires restrictionStart − 15 min (900 seconds).
    var remind15Min: Bool

    /// r1 — fires restrictionStart − 30 min (1800 seconds).
    var remind30Min: Bool

    /// r2 — fires restrictionStart − 1 hour (3600 seconds). The original W6 default.
    var remind1Hour: Bool

    /// r3 — fires restrictionStart − 2 hours (7200 seconds).
    var remind2Hours: Bool

    /// r4 — fires at AppConstants.nightBeforeHourET (20:00 ET) on the prior calendar evening.
    var remindNightBefore: Bool

    // MARK: - Default

    /// The default ReminderOffsets value — remind1Hour only.
    /// Reproduces pre-FT-6 behavior exactly. Used on first run and upgrade.
    static let `default` = ReminderOffsets(
        remind15Min: false,
        remind30Min: false,
        remind1Hour: true,
        remind2Hours: false,
        remindNightBefore: false
    )

    // MARK: - Persistence helpers

    /// Loads ReminderOffsets from the given UserDefaults instance.
    /// Returns `ReminderOffsets.default` if the key is absent or decoding fails.
    ///
    /// - Parameter defaults: The UserDefaults instance to read from. Accepts any suite so
    ///   unit tests can inject an ephemeral instance without polluting `UserDefaults.standard`.
    static func load(from defaults: UserDefaults = .standard) -> ReminderOffsets {
        guard let data = defaults.data(forKey: AppConstants.reminderOffsetsKey) else {
            return .default
        }
        return (try? JSONDecoder().decode(ReminderOffsets.self, from: data)) ?? .default
    }

    /// Saves the given ReminderOffsets to the specified UserDefaults instance.
    ///
    /// - Parameters:
    ///   - offsets: The value to persist.
    ///   - defaults: The UserDefaults instance to write to.
    static func save(_ offsets: ReminderOffsets, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(offsets) {
            defaults.set(data, forKey: AppConstants.reminderOffsetsKey)
        }
    }
}

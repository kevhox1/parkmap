//
//  SpotPassActivityAttributes.swift
//  Shared/SpotPass
//
//  ActivityAttributes shared by the app, the clip and both Live Activity extensions (the type must
//  be identical in every process that starts, updates or renders the activity). C3 defines the
//  real shape (clip driver countdown); C2 (full app) reuses it.
//
//  Constraints: under ActivityKit's 4 KB, never a location, address, plate or username (spec 9).
//
//  Push contract: the backend ends the activity with a content-state of ONLY `{"phase":"thanks"}`
//  or `{"phase":"ended"}` (supabase/functions/_shared/handoff_push.ts), so every other
//  `ContentState` field is optional and an unknown phase decodes to `.ended`.
//

import ActivityKit
import Foundation

nonisolated struct SpotPassActivityAttributes: ActivityAttributes {

    nonisolated enum Phase: String, Codable, Hashable, Sendable {
        case counting       // "Leaving in 9:42"
        case timeToGo       // leave_at reached: "Time to go?"
        case sent           // "Sent. <name> knows you're pulling out."
        case passed         // celebration, karma pending
        case thanks         // seeker said thanks
        case cancelled
        case ended

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Phase(rawValue: raw) ?? .ended
        }
    }

    nonisolated struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Planned departure time; drives the system timer. nil in push-to-end updates.
        var leaveAt: Date?
        /// When the countdown started (progress bar origin).
        var startedAt: Date?
        /// The armed pass's id (a random UUID, lowercase). Full app only (C2): the App Intent buttons
        /// carry it so a stale button can never act on a newer pass. nil for the clip and in
        /// push-to-end updates.
        var passID: String?
        /// C4 (full app only): the armed-window auto-detect is running, so the caption says "auto
        /// heads-up on" (design 5.4). nil/false everywhere else and in push-to-end updates.
        var autoDetect: Bool?

        init(
            phase: Phase = .counting, leaveAt: Date? = nil, startedAt: Date? = nil, passID: String? = nil,
            autoDetect: Bool? = nil
        ) {
            self.phase = phase
            self.leaveAt = leaveAt
            self.startedAt = startedAt
            self.passID = passID
            self.autoDetect = autoDetect
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .ended
            leaveAt = try container.decodeIfPresent(Date.self, forKey: .leaveAt)
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            passID = try container.decodeIfPresent(String.self, forKey: .passID)
            autoDetect = try container.decodeIfPresent(Bool.self, forKey: .autoDetect)
        }
    }

    /// What the driver sees as the pass owner's name: the opt-in first name, else the alias.
    var alias: String
    var glyph: String = SpotPassGlyph.fallbackSymbol
    /// True for the App Clip's activity: buttons are deep links, not App Intents.
    var isClip: Bool = false
}

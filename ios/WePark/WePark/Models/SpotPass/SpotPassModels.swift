//
//  SpotPassModels.swift
//  Models/SpotPass
//
//  Spot Pass C1 (seeker flow): the value types the seeker store, the API and the views agree on
//  (`docs/specs/qr-spot-handoff.md` §3 states, §8 contract; `docs/design/spot-pass-design.md` §2.5
//  states, §9 copy). Pure data, no behavior beyond small lookups.
//
//  Isolation: every type here is `nonisolated` (the app target defaults to MainActor) so plain
//  synchronous XCTest methods and the API layer can use them directly.
//

import Foundation

// MARK: - Server vocabulary (spec §3, §8)

/// `spot_handoffs.status` (spec §3). Raw values are the exact server strings.
nonisolated enum SpotPassServerStatus: String, Codable, Equatable, Sendable {
    case created
    case armed
    case departed
    case expired
    case cancelled
    case suspended
}

/// `confirm_handoff_outcome(id, outcome)` argument (spec §8). Raw values are the exact server strings.
nonisolated enum SpotPassOutcome: String, Codable, Equatable, Sendable {
    case gotSpot = "got_spot"
    case noLuck = "no_luck"
}

/// What the seeker may read about their own pass row (spec §8 RLS: "seeker selects own rows").
nonisolated struct SpotPassSnapshot: Equatable, Sendable {
    let status: SpotPassServerStatus
    /// The driver's chosen leave time. Only ever used to derive a COARSE band (spec §3, §9 item 4).
    let leaveAt: Date?
    let expiresAt: Date?
    let departedAt: Date?
    let outcome: SpotPassOutcome?

    init(
        status: SpotPassServerStatus,
        leaveAt: Date? = nil,
        expiresAt: Date? = nil,
        departedAt: Date? = nil,
        outcome: SpotPassOutcome? = nil
    ) {
        self.status = status
        self.leaveAt = leaveAt
        self.expiresAt = expiresAt
        self.departedAt = departedAt
        self.outcome = outcome
    }
}

// MARK: - The pass

/// `create_handoff` response plus what the client needs to draw it (spec §8). Persisted in
/// `UserDefaults` so an active pass survives a relaunch ("one active pass per seeker").
nonisolated struct SpotPassSession: Codable, Equatable, Sendable {
    let id: UUID
    /// 22-char base64url token. Goes ONLY into the QR URL; never logged, never shared as an image.
    let token: String
    let alias: String
    /// Server glyph key (an SF Symbol name or an animal key); resolve with `SpotPassGlyph`.
    let glyph: String
    /// Opt-in first name, when the seeker turned it on and it passed the filter. Nil = use the alias.
    let displayName: String?
    let createdAt: Date
    let expiresAt: Date

    /// What the badge and the alias row call this person: first name when opted in, else the alias.
    var shownName: String { displayName ?? alias }
}

/// The seeker's own karma, for the bucketed chip and the settled receipt (spec §10, design §2.4).
nonisolated struct SpotPassKarma: Equatable, Sendable {
    /// `profiles.reputation`.
    let reputation: Int
    /// `profiles.helped_count`: drives the bucket label.
    let helpedCount: Int

    static let zero = SpotPassKarma(reputation: 0, helpedCount: 0)

    /// Design §2.4 buckets. Exact counts never reach the badge (F9: a rising number would link
    /// successive passes to one person).
    var bucketLabel: String { Self.bucketLabel(helpedCount: helpedCount) }

    static func bucketLabel(helpedCount: Int) -> String {
        switch helpedCount {
        case ..<1: return "New neighbor"
        case 1...9: return "Helped a few"
        case 10...24: return "Helped 10+"
        case 25...49: return "Helped 25+"
        case 50...99: return "Helped 50+"
        default: return "Helped 100+"
        }
    }
}

// MARK: - Phases

nonisolated enum SpotPassEndReason: Equatable, Sendable {
    /// Unclaimed TTL, armed expiry, driver cancel, purge: all read the same, no reason (spec §3).
    case expired
    /// Reported/suspended: "This Spot Pass has been paused." (design §9.5).
    case suspended
    /// The seeker tapped "Stop waiting".
    case stopped
    /// The seeker parked (spec §3 auto-end).
    case parked
    /// Drive mode ended (spec §3 auto-end).
    case driveEnded

    /// True when the flow should simply close (the seeker caused it) rather than show "Pass ended".
    var closesFlow: Bool {
        switch self {
        case .stopped, .parked, .driveEnded: return true
        case .expired, .suspended: return false
        }
    }
}

nonisolated enum SpotPassCreateFailure: Equatable, Sendable {
    /// "Can't make a pass without a connection." (design §9.5)
    case offline
    case generic
}

/// The seeker-side state machine (spec §3 mapped to design §2.5 / §9). Driven by
/// `SpotPassReducer`; the store owns the transitions' side effects.
nonisolated enum SpotPassPhase: Equatable, Sendable {
    case idle
    case creating
    case createFailed(SpotPassCreateFailure)
    /// `created`: the QR is showing, nobody has scanned yet.
    case open
    /// `armed`: a neighbor scanned and chose a leave time.
    case armed
    /// `departed`: "Spot opening up."
    case departed
    /// Outcome confirmed. `karmaDelta` is the server-confirmed change (nil when unknown).
    case settled(SpotPassOutcome, karmaDelta: Int?)
    case ended(SpotPassEndReason)

    /// A live pass the server still considers active for this seeker.
    var isLive: Bool {
        switch self {
        case .open, .armed, .departed: return true
        default: return false
        }
    }

    /// A pass that can still be cancelled silently (open or armed). A `departed` pass is NOT
    /// auto-ended by parking or ending drive mode: that is the success case, and the seeker still
    /// owes the "Got it, thanks!" confirm.
    var isCancellable: Bool {
        switch self {
        case .open, .armed: return true
        default: return false
        }
    }
}

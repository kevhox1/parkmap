//
//  SpotPassAPI.swift
//  Services/SpotPass
//
//  Spot Pass C1: the seeker's server contract (`docs/specs/qr-spot-handoff.md` §8, FIXED):
//
//    create_handoff(show_name bool)            -> jsonb { id, token, alias, glyph (slug), expires_at }   RPC
//    cancel_handoff(id)                                                                      RPC
//    confirm_handoff_outcome(id, outcome)      outcome in { got_spot, no_luck } -> { ok, outcome, seeker_points }   RPC
//
//  How the seeker LEARNS state changes (spec §3 sequence 6, §7.1, §8 RLS "seeker selects own rows"):
//    - PUSH: `send-handoff-push` kinds `armed` / `departed` (alert). A push only triggers a refresh.
//    - POLL: `fetchStatus` reads the seeker's own `spot_handoffs` row. The poll is the source of
//      truth; push is the fast path. The app works with push permission denied (design §9.5).
//    - KARMA: `fetchKarma` calls `get_my_handoff_karma()` (spec §10; backend PR #161).
//    - Reads of `spot_handoffs` select NAMED columns only (column grants deny `select *`); the
//      table is not in realtime. A driver cancel is silent: the row stays `armed` and just expires.
//
//  The seeker NEVER calls the driver endpoints (peek / claim / depart / extend / cancel): those
//  are C2/C3.
//
//  Streams build against this protocol; the backend is being written in parallel, so everything
//  that interprets a server response is tolerant and lives in `SpotPassWire` where tests pin it.
//

import Foundation

// MARK: - Errors

nonisolated enum SpotPassAPIError: Error, Equatable, Sendable {
    /// The device could not reach the server.
    case offline
    /// No usable session (anonymous sign-in never completed).
    case notSignedIn
    /// The row is gone (purged) or not visible to this seeker.
    case notFound
    /// The server answered with a non-success status.
    case rejected(statusCode: Int)
    /// The response did not match the contract.
    case malformedResponse
}

// MARK: - Protocol

/// The seeker-side API. `@MainActor` like the other service protocols in this app
/// (`AccountDeleting`): the live implementation talks to the `@MainActor` auth service.
@MainActor
protocol SpotPassAPI: AnyObject {
    func createHandoff(showName: Bool) async throws -> SpotPassSession
    func cancelHandoff(id: UUID) async throws
    /// Returns the server's answer (`{ok, outcome, seeker_points}`); `ok == false` means the
    /// server did not accept the outcome (wrong state, expired): the seeker may retry.
    func confirmHandoffOutcome(id: UUID, outcome: SpotPassOutcome) async throws -> SpotPassConfirmResult
    /// The seeker's own row (status, leave_at, expires_at, departed_at, outcome).
    func fetchStatus(id: UUID) async throws -> SpotPassSnapshot
    /// The seeker's own karma (`get_my_handoff_karma()`). May fail independently of the pass;
    /// callers treat it as optional.
    func fetchKarma() async throws -> SpotPassKarma
    /// The seeker's `profiles.username`, or nil. Only used to decide whether the opt-in "show my
    /// first name" toggle can be on (the server derives the shown name the same way).
    func fetchUsername() async throws -> String?
}

/// `confirm_handoff_outcome` response (backend PR #161): `{ok, outcome, seeker_points}`.
nonisolated struct SpotPassConfirmResult: Equatable, Sendable {
    let ok: Bool
    /// Karma points the server actually awarded this seeker (0 when caps/cooldowns applied).
    let seekerPoints: Int
}

// MARK: - Wire interpretation (pure)

/// Tolerant decoding of the contract's JSON. PostgREST returns a function's JSON either as an
/// object or as a one-element array depending on the return type, so both are accepted.
nonisolated enum SpotPassWire {

    // MARK: Dates

    /// Parses Postgres/PostgREST timestamps: `2026-11-23T20:15:00Z`, `...00.123Z`,
    /// `...00.123456+00:00`. Fractional digits beyond milliseconds are dropped first because
    /// `ISO8601DateFormatter` is unreliable with six-digit fractions.
    static func parseDate(_ string: String) -> Date? {
        let normalized = trimFraction(string)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    /// Keeps at most three fractional digits: `.123456+00:00` becomes `.123+00:00`.
    static func trimFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var digitsEnd = string.index(after: dot)
        while digitsEnd < string.endIndex, string[digitsEnd].isASCII, string[digitsEnd].isNumber {
            digitsEnd = string.index(after: digitsEnd)
        }
        let digits = string[string.index(after: dot)..<digitsEnd]
        guard digits.count > 3 else { return string }
        let kept = String(digits.prefix(3))
        let head = String(string[string.startIndex...dot])
        let tail = String(string[digitsEnd...])
        return head + kept + tail
    }

    // MARK: Objects

    private static func firstObject(_ data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = json as? [String: Any] { return object }
        if let array = json as? [[String: Any]] { return array.first }
        return nil
    }

    /// `create_handoff` response. `createdAt` is the client's receive time (the server does not
    /// return it). `display_name` is optional: the contract does not list it, but if the server
    /// echoes the name it will show to the driver, the badge uses exactly that.
    static func decodeCreated(_ data: Data, now: Date) throws -> SpotPassSession {
        guard let object = firstObject(data),
              let idString = object["id"] as? String, let id = UUID(uuidString: idString),
              let token = object["token"] as? String, SpotPassLink.isValidToken(token),
              let alias = object["alias"] as? String, !alias.isEmpty,
              let glyph = object["glyph"] as? String,
              let expiresString = object["expires_at"] as? String,
              let expiresAt = parseDate(expiresString)
        else { throw SpotPassAPIError.malformedResponse }
        let name = (object["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SpotPassSession(
            id: id,
            token: token,
            alias: alias,
            glyph: glyph,
            displayName: name,
            createdAt: now,
            expiresAt: expiresAt
        )
    }

    /// One `spot_handoffs` row (or a one-element array). An empty array means the row is gone.
    static func decodeSnapshot(_ data: Data) throws -> SpotPassSnapshot {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.isEmpty {
            throw SpotPassAPIError.notFound
        }
        guard let object = firstObject(data),
              let statusString = object["status"] as? String,
              let status = SpotPassServerStatus(rawValue: statusString)
        else { throw SpotPassAPIError.malformedResponse }

        func date(_ key: String) -> Date? {
            (object[key] as? String).flatMap(parseDate)
        }
        let outcome = (object["outcome"] as? String).flatMap(SpotPassOutcome.init(rawValue:))
        return SpotPassSnapshot(
            status: status,
            leaveAt: date("leave_at"),
            expiresAt: date("expires_at"),
            departedAt: date("departed_at"),
            outcome: outcome
        )
    }

    /// `{ok, outcome, seeker_points}` (or a one-element array).
    static func decodeConfirm(_ data: Data) throws -> SpotPassConfirmResult {
        guard let object = firstObject(data), let ok = object["ok"] as? Bool else {
            throw SpotPassAPIError.malformedResponse
        }
        return SpotPassConfirmResult(ok: ok, seekerPoints: (object["seeker_points"] as? Int) ?? 0)
    }

    /// A `profiles` row (or a one-element array) -> `username`, or nil.
    static func decodeUsername(_ data: Data) -> String? {
        firstObject(data).flatMap { $0["username"] as? String }
    }

    /// `get_my_handoff_karma()` jsonb `{spots_passed, spots_caught, helped_count, reputation}`
    /// (also accepts a `profiles` row). Missing counters read as zero.
    static func decodeKarma(_ data: Data) throws -> SpotPassKarma {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [Any], json.isEmpty {
            return .zero
        }
        guard let object = firstObject(data) else { throw SpotPassAPIError.malformedResponse }
        return SpotPassKarma(
            reputation: (object["reputation"] as? Int) ?? 0,
            helpedCount: (object["helped_count"] as? Int) ?? 0
        )
    }
}

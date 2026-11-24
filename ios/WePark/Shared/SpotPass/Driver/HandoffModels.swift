//
//  HandoffModels.swift
//  Shared/SpotPass/Driver
//
//  Spot Pass C3: the driver-side value types and the wire format of the public edge functions
//  (`supabase/functions/handoff-*`, spec section 8). Pure; compiled into the app, the clip and the
//  Live Activity extensions.
//
//  Contract (all POST, anonymous-callable, JSON):
//    handoff-peek    {token}                                  -> {status:"open", alias, glyph, display_name|null} | {status:"unavailable"}
//    handoff-claim   {token, leave_at, push_token?, activity_token?, topic?}
//                                                             -> {status:"armed", id, leave_at, expires_at, claimer_secret} | {status:"unavailable"}
//    handoff-depart  {id, claimer_secret, source}             -> {ok}      (ok:false on a RETRY = "may already be sent")
//    handoff-extend  {id, claimer_secret}                     -> {ok, leave_at, expires_at}
//    handoff-cancel  {id, claimer_secret}                     -> {ok}
//    handoff-report  {token, reason} | {id, claimer_secret, reason} -> {ok}
//    HTTP 503 {"error":"disabled"} = feature off; 429 = rate limited.
//
//  The claimer secret is wrapped in `ClaimerSecret`, which redacts itself from `print`, string
//  interpolation, `String(reflecting:)` and `dump`. Nothing in the clip logs; this is the belt.
//

import Foundation

// MARK: - Secret

nonisolated struct ClaimerSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Deliberately not named `description`-friendly; only request building and the secure store read it.
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    var description: String { "ClaimerSecret(redacted)" }
    var debugDescription: String { "ClaimerSecret(redacted)" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

// MARK: - Preview / grants

nonisolated struct HandoffPassPreview: Equatable, Sendable {
    let alias: String
    let glyph: String
    /// Opt-in first name (spec decision 2). nil = use the alias.
    let displayName: String?

    /// What the driver sees as the pass owner's name.
    var name: String { displayName ?? alias }
}

nonisolated enum HandoffPeekResult: Equatable, Sendable {
    case open(HandoffPassPreview)
    case unavailable
}

nonisolated struct HandoffArmedGrant: Equatable, Sendable {
    /// nil only against an OLD backend that predates `id` in the claim response. Without it the
    /// pass cannot be departed/extended/cancelled from the clip: the UI falls back to "open the app".
    let passID: UUID?
    let leaveAt: Date
    let expiresAt: Date
    let secret: ClaimerSecret
}

nonisolated enum HandoffClaimResult: Equatable, Sendable {
    case armed(HandoffArmedGrant)
    case unavailable
}

nonisolated struct HandoffExtendResult: Equatable, Sendable {
    let ok: Bool
    let leaveAt: Date?
    let expiresAt: Date?
}

nonisolated enum HandoffDepartSource: String, Sendable, CaseIterable {
    case manual
    case liveActivity = "live_activity"
    case notification
    case auto
    case startDriving = "start_driving"
    case shortcut
}

nonisolated enum HandoffReportReason: String, Sendable, CaseIterable {
    case harassment, spam, unsafe, other
}

nonisolated enum HandoffReportTarget: Equatable, Sendable {
    case token(String)
    case claimed(id: UUID, secret: ClaimerSecret)
}

nonisolated struct HandoffClaimRequest: Equatable, Sendable {
    let token: String
    let leaveAt: Date
    let pushToken: String?
    let activityToken: String?
    /// Bundle id the push token belongs to (the clip's, `SpotPassShared.clipBundleID`).
    let topic: String?
}

// MARK: - Errors

nonisolated enum HandoffAPIError: Error, Equatable, Sendable {
    case offline
    /// HTTP 503 {"error":"disabled"}: the server-side kill switch is on.
    case disabled
    case rateLimited
    case server(statusCode: Int)
    case malformedResponse
}

// MARK: - Wire

nonisolated enum HandoffWire {

    static func parseDate(_ string: String) -> Date? {
        let normalized = trimFraction(string)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    private static func trimFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isASCII, string[end].isNumber {
            end = string.index(after: end)
        }
        let digits = string[string.index(after: dot)..<end]
        guard digits.count > 3 else { return string }
        return String(string[string.startIndex...dot]) + String(digits.prefix(3)) + String(string[end...])
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HandoffAPIError.malformedResponse
        }
        return json
    }

    // MARK: Decoding

    static func decodePeek(_ data: Data) throws -> HandoffPeekResult {
        let json = try object(data)
        guard let status = json["status"] as? String else { throw HandoffAPIError.malformedResponse }
        guard status == "open" else { return .unavailable }
        guard let alias = json["alias"] as? String, !alias.isEmpty,
              let glyph = json["glyph"] as? String
        else { throw HandoffAPIError.malformedResponse }
        let name = (json["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .open(HandoffPassPreview(alias: alias, glyph: glyph, displayName: name))
    }

    static func decodeClaim(_ data: Data) throws -> HandoffClaimResult {
        let json = try object(data)
        guard let status = json["status"] as? String else { throw HandoffAPIError.malformedResponse }
        guard status == "armed" else { return .unavailable }
        guard let leaveString = json["leave_at"] as? String, let leaveAt = parseDate(leaveString),
              let expiresString = json["expires_at"] as? String, let expiresAt = parseDate(expiresString),
              let secret = json["claimer_secret"] as? String, !secret.isEmpty
        else { throw HandoffAPIError.malformedResponse }
        let id = (json["id"] as? String).flatMap(UUID.init(uuidString:))
        return .armed(HandoffArmedGrant(passID: id, leaveAt: leaveAt, expiresAt: expiresAt, secret: ClaimerSecret(secret)))
    }

    static func decodeOK(_ data: Data) throws -> Bool {
        let json = try object(data)
        guard let ok = json["ok"] as? Bool else { throw HandoffAPIError.malformedResponse }
        return ok
    }

    static func decodeExtend(_ data: Data) throws -> HandoffExtendResult {
        let json = try object(data)
        guard let ok = json["ok"] as? Bool else { throw HandoffAPIError.malformedResponse }
        return HandoffExtendResult(
            ok: ok,
            leaveAt: (json["leave_at"] as? String).flatMap(parseDate),
            expiresAt: (json["expires_at"] as? String).flatMap(parseDate)
        )
    }

    /// Maps a non-2xx response to an error. 503 + `{"error":"disabled"}` is the kill switch.
    static func error(forStatus status: Int, body: Data) -> HandoffAPIError {
        switch status {
        case 503:
            let json = try? object(body)
            return (json?["error"] as? String) == "disabled" ? .disabled : .server(statusCode: 503)
        case 429:
            return .rateLimited
        default:
            return .server(statusCode: status)
        }
    }

    // MARK: Request bodies

    static func claimBody(_ request: HandoffClaimRequest) -> [String: Any] {
        var body: [String: Any] = [
            "token": request.token,
            "leave_at": isoString(request.leaveAt)
        ]
        if let pushToken = request.pushToken { body["push_token"] = pushToken }
        if let activityToken = request.activityToken { body["activity_token"] = activityToken }
        if request.pushToken != nil || request.activityToken != nil, let topic = request.topic {
            body["topic"] = topic
        }
        return body
    }

    static func securedBody(id: UUID, secret: ClaimerSecret, extra: [String: Any] = [:]) -> [String: Any] {
        var body = extra
        body["id"] = id.uuidString.lowercased()
        body["claimer_secret"] = secret.rawValue
        return body
    }

    static func reportBody(target: HandoffReportTarget, reason: HandoffReportReason) -> [String: Any] {
        switch target {
        case .token(let token):
            return ["token": token, "reason": reason.rawValue]
        case .claimed(let id, let secret):
            return securedBody(id: id, secret: secret, extra: ["reason": reason.rawValue])
        }
    }
}

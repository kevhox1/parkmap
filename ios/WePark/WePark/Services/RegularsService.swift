//
//  RegularsService.swift
//  WePark
//
//  Regulars network — S5 (iOS model/service layer). Spec: docs/regulars-network-spec.md §2
//  (wire shapes), §3.2-§3.5 (the UI surfaces a LATER session wires against this file — S7/S9/
//  S10/S10b). Wire-truth source: `supabase/07-regulars-schema.sql` (the MERGED, QA-fixed
//  migration file — not the spec's own SQL sketch, which S1's QA fix round found had drifted
//  from it in a few places; see that migration's own QA-FIX-ROUND-ADDENDUM comment).
//  Sequencing: docs/regulars-roadmap.md, session S5.
//
//  Mirrors `Services/ZoneMessageService.swift`'s house shape (per this session's own dispatch
//  instruction): `@MainActor @Observable`, raw `URLSession` + `Codable` (no supabase-swift
//  PostgREST client), anon key + injectable `authService`/`urlSession`, published
//  state + `isLoading`/`fetchError` per read surface, a `nonisolated static` shared date-decoding
//  `JSONDecoder` factory (matching `CommunityPinService.makeDateDecodingJSONDecoder()`).
//
//  S5 method inventory (matches the dispatch's deliverable list — zero UI, zero surfaces beyond
//  this):
//    - fetchEdges()                          — GET  regular_edges   (read own trust graph)
//    - createInvite()                        — POST regular_invites (created_by only, §2.4)
//    - redeemInvite(token:)                  — POST rpc/redeem_regular_invite
//    - fetchNotices()                        — GET  regular_notices
//    - sendNotice(body:scheduledFor:)         — POST regular_notices (sender_id/body/scheduled_for
//                                               only, §2.6)
//    - block(userId:) / unblock(userId:)      — POST / DELETE regular_blocks
//  Deliberately NOT included this session (out of the dispatch's explicit scope, flagged here so
//  a later session doesn't have to rediscover why): `pin_notes` read/write (attaches to a
//  specific `leaving_soon` pin — S9's UI scope owns deciding when to call it), the
//  `revoked_at` "Cancel invite" update path (S7 UI scope), and any `regular_edges` DELETE
//  ("unfriend" without blocking, spec §2.2) — not named in this session's dispatch list, and
//  block-then-unblock already exercises the delete-an-edge code path server-side (the
//  `delete_regular_edge_on_block` trigger), so nothing here is untested by omitting a second,
//  separate unfriend primitive.
//
//  RLS note (read carefully before extending this file): EVERY method below requires a valid
//  user JWT, not just the anon key — `regular_edges`/`regular_invites`/`regular_notices`/
//  `regular_blocks`'s RLS policies all key off `auth.uid()`, which is `null` for a bare anon-key
//  request. This is a deliberate departure from `CommunityPinService`'s read path (anonymous,
//  `pins_with_author` grants public SELECT) — there is no public/anonymous read surface anywhere
//  in the Regulars feature, by design (spec §2.2's "deny-by-default is the whole point").
//
//  Column-grant discipline (the dispatch's explicit constraint, re-stated per call site below):
//  every write in this file sends ONLY the columns `07-regulars-schema.sql`'s column-level
//  grants actually permit a client to set. `createInvite()` sends `created_by` alone (never
//  `created_at`/`expires_at` — S1's QA pass proved those get silently exploited, then locked
//  down, when client-writable). `sendNotice(...)` sends `sender_id`/`body`/`scheduled_for` alone
//  (never `created_at`/`expires_at` — `expires_at` is trigger-derived regardless, but this file
//  doesn't even try). No `on_conflict`-bearing upsert exists in this file — this repo's own scar
//  tissue (`docs/qa/pr101-community-phase4b-ios.md` Finding #1) doesn't apply here because every
//  write below is a plain `INSERT` or an RPC call, never an upsert.
//
//  COMPILE-UNVERIFIED — written on a Linux VPS, no Xcode/Swift toolchain. Every request-building
//  shape used here (`buildRequest`, `Prefer: return=representation`, RPC calls under
//  `rest/v1/rpc/<name>`) is the identical shape already used and shipped in
//  `CommunityPinService.swift`/`ZoneMessageService.swift` — deliberately not a new, unverified
//  API surface. A Mac `xcodebuild build`+`test` pass is a required gate before merge, matching
//  every other file in this codebase's posture.
//
//  Architectural invariants (matches this codebase's standing convention, `HANDOFF.md`):
//   - @MainActor: all published-state mutations run on the main actor.
//   - No Calendar.current.
//   - REST network path: raw URLSession + Codable.
//   - Supabase URL + anon key injected at init, same Config.xcconfig → Info.plist source as every
//     other Supabase-backed service. Never hardcoded.
//

import Foundation

// MARK: - RegularsServiceError

/// Errors from every write/read path in this file. One shared error type (unlike
/// `ZoneMessageService`'s separate fetch/write error enums) — every Regulars operation needs the
/// same three cases, and this file has no per-surface validation error the way
/// `ZoneMessageWriteError.invalidBody` does (client-side length checks below throw
/// `.invalidNoticeBody` instead of inventing a second enum for one extra case).
enum RegularsServiceError: Error, Equatable {
    /// `authService` is `nil`, or has no valid session/JWT. Every method in this file requires
    /// `auth.uid() != null` — see this file's header RLS note.
    case notAuthenticated
    /// The server responded with a non-2xx status.
    case httpError(statusCode: Int)
    /// Request body encoding failed (JSONSerialization / date formatting).
    case encodingFailure
    /// The write succeeded (2xx) but the server's `return=representation` echo couldn't be
    /// decoded — mirrors `ZoneMessageWriteError.decodingFailure`'s "the write itself is NOT
    /// rolled back by this" posture.
    case decodingFailure
    /// `sendNotice(body:)`'s trimmed body is empty or exceeds `regular_notices.body`'s
    /// `check (char_length(body) between 1 and 140)` constraint (`07-regulars-schema.sql`
    /// §S1-6) — caught client-side before spending a round trip on a guaranteed 400/23514.
    case invalidNoticeBody
    /// `redeemInvite(token:)`'s RPC response body didn't decode into any of the four known
    /// `{ok, reason, regular_id}` shapes (`RegularInviteRedeemResult`) — a genuine, unexpected
    /// server-shape mismatch, distinct from `.decodingFailure` above (which is about a
    /// `return=representation` row echo, not an RPC scalar/object result).
    case unrecognizedRedeemResult
}

// MARK: - RegularsService

/// Regulars network read/write service (S5). See this file's header for the exact method
/// inventory and the RLS/column-grant discipline every method below follows.
///
/// All state mutations run on `@MainActor` so published state can be observed safely from
/// SwiftUI without additional dispatch — same invariant as `CommunityPinService`/
/// `ZoneMessageService`.
@MainActor
@Observable
final class RegularsService {

    // MARK: - Published state

    /// The current user's Regulars trust graph, as fetched by `fetchEdges()`. Each row's
    /// `otherUserId(ownUserId:)` resolves to the actual "who is this a Regulars edge with" —
    /// see `RegularEdge`'s own doc comment.
    private(set) var edges: [RegularEdge] = []

    /// True while `fetchEdges()` has a network fetch in progress.
    private(set) var isLoadingEdges = false

    /// Set when the most recent `fetchEdges()` call failed. `nil` on success. `edges` is left
    /// unchanged on failure — same "fail soft, don't blank what's already on screen" posture as
    /// `CommunityPinService.resolveChannelPins`.
    private(set) var edgesFetchError: Error? = nil

    /// Notices visible to the current user — their own sent notices plus every current
    /// Regular's, as fetched by `fetchNotices()`. Most-recent-first (server's own
    /// `created_at.desc` ordering, unlike `ZoneMessageService.messages`, which reverses to
    /// oldest-first for a chat-style feed — Loop C has no feed UI at all, spec decision 2, so
    /// there's no chronological-append convention to match here).
    private(set) var notices: [RegularNotice] = []

    /// True while `fetchNotices()` has a network fetch in progress.
    private(set) var isLoadingNotices = false

    /// Set when the most recent `fetchNotices()` call failed. `nil` on success.
    private(set) var noticesFetchError: Error? = nil

    // MARK: - Init parameters

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// Auth session used by every method in this file — every Regulars RLS policy keys off
    /// `auth.uid()` (see this file's header). `nil` is valid only for previews/inert
    /// construction; any real call throws `.notAuthenticated` rather than crashing, mirroring
    /// `ZoneMessageService.authService`'s own optional convention.
    let authService: SupabaseAuthService?

    /// URLSession used for all network calls. Injectable for tests (mock-URLProtocol pattern),
    /// mirrors `ZoneMessageService.urlSession`.
    let urlSession: URLSession

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL. Read from `Info.plist` key `SUPABASE_URL` at
    ///     runtime in production.
    ///   - supabaseAnonKey: The anon/public API key. Read from `Info.plist` key
    ///     `SUPABASE_ANON_KEY` at runtime in production. NEVER hardcode this value in source.
    ///   - authService: Auth session for every method below. Default `nil` (inert construction
    ///     only — every real call requires a non-nil, authenticated instance).
    ///   - urlSession: Injectable URL session. Default `URLSession.shared`.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        authService: SupabaseAuthService? = nil,
        urlSession: URLSession = .shared
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.authService = authService
        self.urlSession = urlSession
    }

    /// Convenience initializer that reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from
    /// `Bundle.main` (bridged from `Config.xcconfig` via `Info.plist`) — mirrors
    /// `ZoneMessageService`'s own convenience init exactly (same placeholder-URL fallback for
    /// pre-config builds).
    convenience init(authService: SupabaseAuthService? = nil, urlSession: URLSession = .shared) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, authService: authService, urlSession: urlSession)
    }

    // MARK: - Fixture injection (test seam)

    /// Directly sets `edges`, bypassing the network. Mirrors
    /// `CommunityPinService.inject(fixtures:)` / `ZoneMessageService.inject(fixtures:)`.
    func inject(edges fixtures: [RegularEdge]) {
        edges = fixtures
    }

    /// Directly sets `notices`, bypassing the network.
    func inject(notices fixtures: [RegularNotice]) {
        notices = fixtures
    }

    // MARK: - Shared date-decoding JSONDecoder

    /// Same custom ISO8601 date strategy (with-fractional-seconds, falling back to without) as
    /// `CommunityPinService.makeDateDecodingJSONDecoder()` / `ZoneMessageService.decodeResponse`
    /// — duplicated here rather than shared, per this codebase's own established "no
    /// cross-service-file type/helper sharing" convention (`ZoneMessageService`'s header note on
    /// why its own decoder is duplicated, not imported).
    ///
    /// `nonisolated` (matching `ZoneStore.loadCache`/`CommunityPinService.makeDateDecodingJSONDecoder`'s
    /// own precedent): pure `JSONDecoder` construction, no actor-isolated state touched — this
    /// build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise isolate this
    /// implicitly, which would wrongly force every caller (including plain, non-actor unit
    /// tests) onto the main actor just to build a decoder.
    nonisolated static func makeDateDecodingJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatters: [ISO8601DateFormatter] = {
                let withFraction = ISO8601DateFormatter()
                withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return [withFraction, plain]
            }()
            for formatter in formatters {
                if let date = formatter.date(from: string) { return date }
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Cannot decode date: \(string)")
            )
        }
        return decoder
    }

    /// The matching ISO8601 STRING formatter for a `Date` -> request-body value (the encode
    /// side of the decoder above) — used by `sendNotice(scheduledFor:)` to serialize
    /// `scheduled_for` for `JSONSerialization`, which cannot encode a raw `Date`. With
    /// fractional seconds, matching the decoder's primary (not fallback) format.
    nonisolated static func iso8601StringWithFraction(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Shared request builder

    /// Builds a PostgREST/RPC `URLRequest`. Unlike `ZoneMessageService.buildAuthenticatedRequest`
    /// (path-only, no query support), this also accepts `queryItems` — needed for every GET in
    /// this file (RLS-filtered reads still need explicit `select=...`/`order=...`) and for the
    /// `unblock(userId:)` DELETE (PostgREST filters DELETE targets via query params, not the
    /// path — same "buildAuthenticatedRequest(path:) can't express this" reasoning
    /// `CommunityPinService.deleteCrowdPin` already documents for its own DELETE).
    private func buildRequest(
        path: String,
        method: String,
        jwt: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        extraHeaders: [String: String] = [:]
    ) -> URLRequest? {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    /// Resolves a valid JWT or throws `.notAuthenticated` — the same two-step check
    /// (`authService` non-nil, `validAccessToken()` non-nil) every write path in
    /// `CommunityPinService`/`ZoneMessageService` performs before building a request.
    private func requireJWT() async throws -> String {
        guard let authSvc = authService, let jwt = await authSvc.validAccessToken() else {
            throw RegularsServiceError.notAuthenticated
        }
        return jwt
    }

    // MARK: - Fetch edges

    /// Fetches the current user's Regulars trust graph (`regular_edges`, RLS: `auth.uid() in
    /// (low_user_id, high_user_id)` — this always returns rows the caller participates in,
    /// never a third party's). On failure, sets `edgesFetchError` and leaves `edges` unchanged.
    func fetchEdges() async {
        do {
            let jwt = try await requireJWT()
            isLoadingEdges = true
            edgesFetchError = nil

            guard let request = buildRequest(
                path: "rest/v1/regular_edges",
                method: "GET",
                jwt: jwt,
                queryItems: [
                    URLQueryItem(name: "select", value: "low_user_id,high_user_id,created_at"),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                ]
            ) else {
                throw RegularsServiceError.encodingFailure
            }

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            edges = try Self.makeDateDecodingJSONDecoder().decode([RegularEdge].self, from: data)
        } catch {
            edgesFetchError = error
        }
        isLoadingEdges = false
    }

    // MARK: - Create invite

    /// Inserts one `regular_invites` row (spec §2.4, §3.2's "on appear" step of the invite
    /// sheet). Sends `created_by` ONLY — see this file's header for why `id`/`created_at`/
    /// `expires_at` must never be sent explicitly. `return=representation` is safe here: the
    /// freshly-inserted row's `created_by = auth.uid()` always satisfies
    /// `regular_invites_select_own`'s own `USING` clause (the S11/PR#100 RETURNING lesson,
    /// closed by construction — `07-regulars-schema.sql` §S1-4's own comment confirms this).
    ///
    /// - Returns: The inserted `RegularInvite` — its `id` is the token to render as QR/link
    ///   (S7 UI scope; this method only produces the token, it does not render anything).
    func createInvite() async throws -> RegularInvite {
        guard let authSvc = authService, let userId = authSvc.currentUserId else {
            throw RegularsServiceError.notAuthenticated
        }
        let jwt = try await requireJWT()

        let payload: [String: Any] = ["created_by": userId.uuidString]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RegularsServiceError.encodingFailure
        }

        guard let request = buildRequest(
            path: "rest/v1/regular_invites",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: ["Prefer": "return=representation"]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let inserted = try? Self.makeDateDecodingJSONDecoder().decode([RegularInvite].self, from: data),
              let invite = inserted.first else {
            throw RegularsServiceError.decodingFailure
        }
        return invite
    }

    // MARK: - Redeem invite

    /// Calls the `redeem_regular_invite(p_token)` RPC (`07-regulars-schema.sql` §S1-4) — the
    /// deep-link redeem-side confirm sheet's "Add them back?" action (spec §3.2). Race-safe,
    /// single-writer-wins server-side; every one of the four possible outcomes is a normal
    /// `2xx` response, decoded via `RegularInviteRedeemResult` (never thrown as a Swift error —
    /// only a genuine transport/auth/shape failure throws).
    ///
    /// - Parameter token: The invite's own `id` (parsed from `wepark://invite/<id>` — that
    ///   parsing is `WeParkApp`'s `.onOpenURL` scope, S7, not this method's).
    /// - Returns: Which of the four terminal states the RPC reported.
    func redeemInvite(token: UUID) async throws -> RegularInviteRedeemResult {
        let jwt = try await requireJWT()

        let payload: [String: Any] = ["p_token": token.uuidString]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RegularsServiceError.encodingFailure
        }

        guard let request = buildRequest(
            path: "rest/v1/rpc/redeem_regular_invite",
            method: "POST",
            jwt: jwt,
            body: body
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try Self.decodeRedeemResult(from: data)
    }

    /// Decodes `redeem_regular_invite`'s `jsonb` response body
    /// (`{"ok": Bool, "reason": String?, "regular_id": UUID?}`) into a `RegularInviteRedeemResult`.
    /// Pure, `nonisolated` — separated from `redeemInvite(token:)` so wire-shape tests can
    /// exercise every one of the four possible server payloads directly, without a network
    /// round trip (mirrors this codebase's "pure decision logic split from the network call
    /// that produces its input" convention, e.g.
    /// `CommunityPushRelevance.isRelevant`/`.notificationCopy`).
    nonisolated static func decodeRedeemResult(from data: Data) throws -> RegularInviteRedeemResult {
        struct RPCResponse: Decodable {
            let ok: Bool
            let reason: String?
            let regularId: UUID?
            enum CodingKeys: String, CodingKey {
                case ok, reason
                case regularId = "regular_id"
            }
        }

        guard let decoded = try? JSONDecoder().decode(RPCResponse.self, from: data) else {
            throw RegularsServiceError.decodingFailure
        }

        if decoded.ok, let regularId = decoded.regularId {
            return .success(regularId: regularId)
        }
        switch decoded.reason {
        case "expired_or_used": return .expiredOrUsed
        case "cannot_add_self": return .cannotAddSelf
        case "blocked":         return .blocked
        default:
            throw RegularsServiceError.unrecognizedRedeemResult
        }
    }

    // MARK: - Fetch notices

    /// Fetches notices visible to the current user (`regular_notices`, RLS: sender OR any
    /// current Regular of the sender). On failure, sets `noticesFetchError` and leaves
    /// `notices` unchanged.
    func fetchNotices() async {
        do {
            let jwt = try await requireJWT()
            isLoadingNotices = true
            noticesFetchError = nil

            guard let request = buildRequest(
                path: "rest/v1/regular_notices",
                method: "GET",
                jwt: jwt,
                queryItems: [
                    URLQueryItem(name: "select", value: "id,sender_id,body,scheduled_for,created_at,expires_at"),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                ]
            ) else {
                throw RegularsServiceError.encodingFailure
            }

            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            notices = try Self.makeDateDecodingJSONDecoder().decode([RegularNotice].self, from: data)
        } catch {
            noticesFetchError = error
        }
        isLoadingNotices = false
    }

    // MARK: - Send notice

    /// `regular_notices.body`'s CHECK constraint, verbatim (`07-regulars-schema.sql` §S1-6):
    /// `char_length(body) between 1 and 140`. Checked client-side so an over-length draft fails
    /// fast with `.invalidNoticeBody` instead of spending a round trip on a guaranteed 400 —
    /// same reasoning as `ZoneMessageService.bodyMaxLength`.
    static let noticeBodyMaxLength = 140

    /// Inserts one `regular_notices` row — the Quick Regulars Notice write path (spec §2.6,
    /// §3.5). Sends `sender_id`/`body`/`scheduled_for` ONLY — see this file's header for why
    /// `created_at`/`expires_at` must never be sent explicitly (the latter is server-derived
    /// regardless of what's sent, but this method doesn't even try). `return=representation` is
    /// safe here for the same RETURNING reason as `createInvite()`
    /// (`regular_notices_select_own_or_regular`'s first branch, `sender_id = auth.uid()`).
    ///
    /// - Parameters:
    ///   - body: Raw draft text (canned phrase + optional free text, already composed
    ///     client-side per spec §3.5 — this method has no opinion on internal structure).
    ///     Trimmed and length-checked against `noticeBodyMaxLength` before the request is built.
    ///   - scheduledFor: Non-`nil` ONLY for the Scheduled Departure "I'm out at ___" canned
    ///     phrase (spec §3.5, §0 decision 7). `nil` (the default) produces byte-identical
    ///     behavior to the pre-Scheduled-Departure send-now shape. This method does NOT
    ///     validate the 24-hour-horizon / future-only CHECKs client-side (`07-regulars-schema.sql`
    ///     §S1-6) — S10b's schedule-mode UI owns that validation (its `DatePicker` is
    ///     constrained so an invalid value can't be produced in the first place, per spec §3.5's
    ///     "a native picker can't produce an invalid value" reasoning); this method trusts its
    ///     caller and lets a genuinely invalid value surface as a server-side 400/23514 via
    ///     `.httpError`.
    /// - Returns: The inserted `RegularNotice`, decoded from the server's echo.
    @discardableResult
    func sendNotice(body: String, scheduledFor: Date? = nil) async throws -> RegularNotice {
        guard let authSvc = authService, let userId = authSvc.currentUserId else {
            throw RegularsServiceError.notAuthenticated
        }
        let jwt = try await requireJWT()

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.noticeBodyMaxLength else {
            throw RegularsServiceError.invalidNoticeBody
        }

        var payload: [String: Any] = [
            "sender_id": userId.uuidString,
            "body": trimmed,
        ]
        if let scheduledFor {
            payload["scheduled_for"] = Self.iso8601StringWithFraction(scheduledFor)
        }
        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RegularsServiceError.encodingFailure
        }

        guard let request = buildRequest(
            path: "rest/v1/regular_notices",
            method: "POST",
            jwt: jwt,
            body: requestBody,
            extraHeaders: ["Prefer": "return=representation"]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let inserted = try? Self.makeDateDecodingJSONDecoder().decode([RegularNotice].self, from: data),
              let notice = inserted.first else {
            throw RegularsServiceError.decodingFailure
        }

        // Optimistic prepend, matching notices' most-recent-first ordering (see `notices`' own
        // doc comment) — mirrors `ZoneMessageService.sendMessage`'s optimistic-append precedent,
        // adapted for the opposite ordering direction.
        notices.insert(notice, at: 0)

        return notice
    }

    // MARK: - Block / unblock

    /// Inserts one `regular_blocks` row (spec §2.3). Severs any live `regular_edges` row
    /// between the two accounts in the SAME transaction, server-side
    /// (`delete_regular_edge_on_block`, `07-regulars-schema.sql` §S1-3) — this method does not
    /// separately delete the edge; the trigger already guarantees that.
    ///
    /// `return=minimal` (not `return=representation`): nothing downstream needs the inserted
    /// row's own shape (no `Identifiable` model type exists for `regular_blocks` — this feature
    /// deliberately never surfaces "who blocked me" to the blocked party, spec §2.3, so there's
    /// no reason for the CALLER's own client to decode a full row back either).
    ///
    /// - Parameter userId: The account to block.
    func block(userId: UUID) async throws {
        guard let authSvc = authService, let myId = authSvc.currentUserId else {
            throw RegularsServiceError.notAuthenticated
        }
        let jwt = try await requireJWT()

        let payload: [String: Any] = [
            "user_id": myId.uuidString,
            "blocked_user_id": userId.uuidString,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RegularsServiceError.encodingFailure
        }

        guard let request = buildRequest(
            path: "rest/v1/regular_blocks",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Deletes the caller's own `regular_blocks` row against `userId` (an "un-block" — this does
    /// NOT recreate a `regular_edges` row; re-adding the other account as a Regular still
    /// requires a fresh invite exchange, spec §2.3/§2.4 — blocking is not reversible into an
    /// automatic re-friendship). Filters via query params, not the path — PostgREST DELETE
    /// targeting convention, same reasoning as `CommunityPinService.deleteCrowdPin`'s own DELETE.
    ///
    /// - Parameter userId: The account to unblock.
    func unblock(userId: UUID) async throws {
        guard let authSvc = authService, let myId = authSvc.currentUserId else {
            throw RegularsServiceError.notAuthenticated
        }
        let jwt = try await requireJWT()

        guard let request = buildRequest(
            path: "rest/v1/regular_blocks",
            method: "DELETE",
            jwt: jwt,
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(myId.uuidString)"),
                URLQueryItem(name: "blocked_user_id", value: "eq.\(userId.uuidString)"),
            ],
            extraHeaders: ["Prefer": "return=minimal"]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Remove a Regular (S7, spec §2.2/§3.1 "remove/block affordances")

    /// Deletes the `regular_edges` row between the caller and `otherUserId` — "unfriend"
    /// WITHOUT blocking (`regular_edges_delete_own`, `07-regulars-schema.sql` §S1-2: "either
    /// party can end the relationship unilaterally"). Flagged in `RegularsService`'s own S5
    /// header as deliberately left unwired that session ("a standalone `regular_edges` DELETE
    /// ... not named in this session's dispatch list") — this is that follow-up, S7's own
    /// "remove ... affordance" dispatch item.
    ///
    /// Filters with an `or=(and(...),and(...))` PostgREST combinator covering BOTH orderings of
    /// the composite primary key, rather than computing the canonical `low_user_id < high_user_id`
    /// ordering client-side — this table's own low/high assignment is a Postgres `uuid <`
    /// comparison, and duplicating that comparison's exact semantics in Swift (whose `UUID`
    /// doesn't define `Comparable` at all) would be a second, unverified place for the two
    /// orderings to silently drift apart. The RLS policy (`auth.uid() in (low_user_id,
    /// high_user_id)`) already guarantees this can only ever match a row the caller participates
    /// in, so the OR-both-orderings filter is exactly as safe as a canonical-order filter would
    /// be, without needing one.
    ///
    /// - Parameter otherUserId: The Regular to remove.
    func removeRegular(otherUserId: UUID) async throws {
        guard let authSvc = authService, let myId = authSvc.currentUserId else {
            throw RegularsServiceError.notAuthenticated
        }
        let jwt = try await requireJWT()

        let orFilter = "or=(and(low_user_id.eq.\(myId.uuidString),high_user_id.eq.\(otherUserId.uuidString))," +
                       "and(low_user_id.eq.\(otherUserId.uuidString),high_user_id.eq.\(myId.uuidString)))"
        guard var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/regular_edges"),
            resolvingAgainstBaseURL: false
        ) else {
            throw RegularsServiceError.encodingFailure
        }
        // Built as a raw query string (not `[URLQueryItem]`) because the `or=(...)` combinator's
        // own commas/parentheses must reach PostgREST unescaped-in-structure — `URLQueryItem`
        // would percent-encode the parentheses correctly but there is no clean way to express
        // the nested `and(...)`  groups as a *value* of a single named item without hand-building
        // the same string anyway; this mirrors PostgREST's own documented `or`/`and` filter
        // syntax examples verbatim.
        components.percentEncodedQuery = orFilter
        guard let url = components.url else {
            throw RegularsServiceError.encodingFailure
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Optimistic removal from the locally-cached list, mirroring `sendNotice`'s own
        // optimistic-mutation precedent — `RegularsSettingsView` doesn't need to re-`fetchEdges()`
        // just to reflect a delete it just performed successfully.
        edges.removeAll { $0.lowUserId == otherUserId || $0.highUserId == otherUserId }
    }

    // MARK: - Fetch a single invite (S7, invite-sheet redemption polling)

    /// Re-fetches one `regular_invites` row by its own `id` — used by `RegularInviteView`'s
    /// polling loop to detect `redeemed_at` flipping non-null (spec §3.2: "Polls ... for
    /// `redeemed_at` and flips to a success state"). Only ever resolves for the CREATOR's own
    /// invite (`regular_invites_select_own`, `created_by = auth.uid()`) — a redeemer's session
    /// can never read someone else's invite row this way, which is exactly why the
    /// redemption-side confirm sheet (`RegularInviteRedemptionView`) cannot look up the inviter's
    /// handle before calling `redeemInvite(token:)`; see that view's own header comment.
    ///
    /// - Parameter id: The invite's own `id` (the same value rendered as the QR/link token).
    /// - Returns: `nil` if the row no longer matches (deleted/RLS-filtered) rather than throwing
    ///   — mirrors `fetchOwnProfile`'s "not found is a normal state" convention, not an error.
    func fetchInvite(id: UUID) async throws -> RegularInvite? {
        let jwt = try await requireJWT()

        guard let request = buildRequest(
            path: "rest/v1/regular_invites",
            method: "GET",
            jwt: jwt,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
                URLQueryItem(
                    name: "select",
                    value: "id,created_by,created_at,expires_at,redeemed_by,redeemed_at,revoked_at"
                ),
                URLQueryItem(name: "limit", value: "1"),
            ]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let invites = try Self.makeDateDecodingJSONDecoder().decode([RegularInvite].self, from: data)
        return invites.first
    }

    // MARK: - Cancel invite (S7, spec §3.2 "Cancel" button)

    /// Sets `revoked_at = now()` on the caller's own still-open invite
    /// (`regular_invites_update_own` + the column-level `grant update (revoked_at)` —
    /// `07-regulars-schema.sql` §S1-4). Sends ONLY `revoked_at` — every other column on this
    /// table is either server-derived or, per that same column-level grant, simply not
    /// client-writable at all regardless of what this method sends.
    ///
    /// - Parameter id: The invite's own `id`.
    func cancelInvite(id: UUID) async throws {
        let jwt = try await requireJWT()

        let payload: [String: Any] = ["revoked_at": Self.iso8601StringWithFraction(Date())]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RegularsServiceError.encodingFailure
        }

        guard let request = buildRequest(
            path: "rest/v1/regular_invites",
            method: "PATCH",
            jwt: jwt,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")],
            body: body,
            extraHeaders: ["Prefer": "return=minimal"]
        ) else {
            throw RegularsServiceError.encodingFailure
        }

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RegularsServiceError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Fetch profiles (S7, handle/avatar resolution — see `RegularProfileSummary`'s header)

    /// Batch-reads `public.profiles` (a pre-existing, app-wide public table — see
    /// `RegularProfileSummary`'s own doc comment for why this is not a new privacy surface) for
    /// exactly the handle/avatar fields a Regulars-list row or an invite-redemption confirmation
    /// needs to display. Public read, no `Authorization` header — mirrors
    /// `CommunityPinService.fetchOwnProfile`'s exact "apikey + Accept only" shape, the
    /// established convention for this one publicly-readable table.
    ///
    /// - Parameter ids: The user ids to resolve. Empty input short-circuits to `[:]` without a
    ///   network call (an empty `id=in.()` PostgREST filter is a guaranteed-empty, wasted round
    ///   trip).
    /// - Returns: A dictionary keyed by `id` for every row PostgREST returned. Silently omits
    ///   (never throws for) any id with no matching row, or on any network/decode failure —
    ///   this is optional cosmetic enrichment (a row still renders, just without a resolved
    ///   handle) never a required read, mirroring `CrewFeedSection.profileRow`'s own
    ///   renders-nothing-when-absent posture for missing profile data.
    func fetchProfiles(ids: [UUID]) async -> [UUID: RegularProfileSummary] {
        guard !ids.isEmpty else { return [:] }

        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )
        let idList = ids.map(\.uuidString).joined(separator: ",")
        components?.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(idList))"),
            URLQueryItem(name: "select", value: "id,username,avatar"),
        ]
        guard let url = components?.url else { return [:] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await urlSession.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let profiles = try? JSONDecoder().decode([RegularProfileSummary].self, from: data)
        else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }
}

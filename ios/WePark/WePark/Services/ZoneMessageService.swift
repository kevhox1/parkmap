//
//  ZoneMessageService.swift
//  WePark
//
//  Community 2.0 Phase 1 (build 20, session S3) — read path for the zone-anchored chat half of
//  the crew feed. Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Crew feed" /
//  "Blockface-anchored chat"), §2.4, §3 Phase 1.
//
//  Mirrors `CommunityPinService`'s own fetch/merge/Realtime shape, per the spec's explicit
//  instruction ("mirroring CommunityPinService's own fetch/merge/Realtime shape rather than
//  inventing a new pattern"), scaled down to what `zone_messages` actually needs:
//   - `zone_messages` has NO update or delete policy at all (`supabase/01-mvp-schema.sql`: only
//     `zone_messages_select_all` + `zone_messages_insert_user`) — every row is insert-only and
//     immutable forever. Unlike `CommunityPinService` there is no UPDATE/DELETE merge path, no
//     expiry filter, and no `resolved_at`/`nowProvider` concept to gate on.
//   - No bounding-box: chat is zone-scoped, not viewport-scoped. The one filter dimension is
//     `zone_id`, set via `setSelectedZone(_:)` — mirroring the same-named method +
//     `RealtimeMergeGate`'s zone_id dimension `CommunityPinService` gained this same session
//     (spec §1 delta table: "keep one channel, add zone_id as one more dimension" rather than N
//     zone-scoped channels).
//   - `id` is a Postgres `bigserial` (`Int`), NOT a uuid — different from every `pins`/
//     `CommunityPin` row. Do not copy the `UUID`-typed `id` idiom from `CommunityPin.swift`.
//   - `message_type` is `'user'` or `'system_tracker'` (`01-mvp-schema.sql:76`) — `system_tracker`
//     rows are inserted only via a not-yet-built `SECURITY DEFINER` RPC (schema comment: "will be
//     added in the next migration when the tracker schema lands"); this file has no opinion on
//     that RPC, it only needs to decode whichever value a fetched/pushed row actually carries.
//   - `zone_messages` Realtime is ALREADY enabled (`01-mvp-schema.sql`'s
//     `alter publication supabase_realtime add table public.zone_messages`) — not gated on
//     Phase 0's Community 2.0 migration being applied.
//
//  Read-only through S12 — S13b (build 20, WP3 of docs/design/community-2.0-hero-gap-inventory.md)
//  adds the WRITE path this file's header used to say didn't exist yet: `sendMessage(zoneId:
//  segmentId:body:)`. Consumers: `Views/BlockDetailView.swift`'s "BLOCK CHATTER" compose bar
//  (segment-anchored) and `Views/CrewFeedSection.swift`'s zone-level "Say something to the
//  square…" compose bar (segmentId: nil) — one write primitive, two call sites, matching this
//  file's own `fetchMessages`/`CrewFeedMerge` precedent of one read primitive serving both
//  surfaces. Also net-new: `fetchMessages(segmentId:)`, a SEPARATE one-shot read (does not
//  touch `messages`/`isLoading`/`fetchError` above) for the block-detail chat thread, which is
//  scoped to one specific block regardless of whichever zone (if any) the crew feed currently
//  has selected — mirrors `CommunityPinService.fetchLeaderboardPins(zoneId:)`'s own "separate
//  one-shot fetch, doesn't touch the zone-chip-driven published state" precedent.
//
//  RLS verdict (S13b, verified against `supabase/01-mvp-schema.sql`/`03-community-2.0-schema.sql`
//  before writing `sendMessage`, per this session's dispatch instruction to check before
//  shipping a write that could 42501):
//   - `zone_messages_insert_user` (01-mvp-schema.sql:91-97) already permits an authenticated
//     insert: `auth.uid() is not null and author_id = auth.uid() and message_type = 'user'`. No
//     migration needed — this session ships ZERO new SQL.
//   - `segment_id` (03-community-2.0-schema.sql §2.4) has NO column-level lockdown — that
//     migration's own comment (line 154-155) confirms `zone_messages_insert_user` already lets
//     an authenticated author set ANY column on their own insert, segment_id included.
//   - Return-preference choice: `return=representation` (not `return=minimal`) — SAFE here,
//     unlike the S11 RETURNING lesson this session was told to check for. That lesson's failure
//     mode was requesting the row back on a table where the SELECT policy was narrower than the
//     INSERT policy (e.g. author-only select). Here `zone_messages_select_all` is
//     `using (true)` — the freshly-inserted row is selectable by literally anyone, including its
//     own author, so PostgREST's post-insert SELECT (which `return=representation` triggers)
//     cannot be blocked by RLS. Chosen deliberately, not by default, so the sender sees their
//     own message immediately (mirrors `CommunityPinService.insertCrowdPin`'s own "Fix 1"
//     precedent) rather than waiting for a Realtime echo.
//   - `on_conflict` lesson does NOT apply — this is a plain `INSERT`, no upsert, no conflict
//     target.
//
//  COMPILE-UNVERIFIED — written on a Linux VPS, no Xcode/Swift toolchain. Every SDK symbol used
//  in `SupabaseZoneMessageRealtimeChannel` below is the exact same call shape already used (and
//  documented as verified against the pinned supabase-swift revision) in
//  `Services/RealtimePinChannel.swift` — deliberately NOT a new, unverified API surface. A Mac
//  `xcodebuild build`+`test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  Architectural invariants (matches `CommunityPinService`'s own, `HANDOFF.md` convention):
//   - @MainActor: all `messages` mutations run on the main actor so SwiftUI reads are safe.
//   - No Calendar.current.
//   - REST network path: raw URLSession + Codable (no supabase-swift PostgREST client — same
//     `CommunityPinService` convention).
//   - Supabase URL + anon key injected at init, same Config.xcconfig → Info.plist source as
//     every other Supabase-backed service in this codebase. Never hardcoded.
//

import Foundation
import Realtime

// MARK: - ZoneMessage

/// Decoded from the `zone_messages_with_author` view. `supabase/03-community-2.0-schema.sql`
/// §2.4-note recreates this view to append `segment_id` — the same "p.* frozen at CREATE VIEW
/// time" bug class `02f-block-scoped-restrictions.sql` already fixed once for `pins_with_author`.
///
/// Plain synthesized `Codable` (no discriminated-meta decode logic, unlike `CommunityPin`) — the
/// `CodingKeys` raw values below are all this type needs.
struct ZoneMessage: Identifiable, Codable {
    /// `bigserial` in Postgres — a plain integer, NOT a uuid (unlike every `pins`/
    /// `CommunityPin` row). Do not copy the `UUID`-typed `id` idiom from `CommunityPin.swift`.
    let id: Int
    let zoneId: String
    /// `nil` for a message whose author account was later deleted
    /// (`author_id uuid references auth.users(id) on delete set null` — `01-mvp-schema.sql:75`)
    /// — the message itself is never deleted, only its authorship link.
    let authorId: UUID?
    let messageType: MessageType
    let body: String
    /// Cross-links a chat message to a `pins` report it references (e.g. a "confirmed ↑" chat
    /// line auto-posted alongside a report). No FK in the schema (`related_report_id uuid`, no
    /// `references` clause) — an application-level linkage, not a DB-enforced one.
    let relatedReportId: UUID?
    let createdAt: Date
    /// Inline from the view's `left join` — `nil` when `authorId` is `nil`, or (in principle) if
    /// the joined profiles row is missing even though `authorId` is set.
    let authorUsername: String?
    let authorReputation: Int?
    /// Community 2.0 (spec §2.4): nullable blockface anchor. `nil` for every pre-2.0 zone-chat
    /// row (zone-wide, not block-specific) and for any future zone-wide (non-blockface) message.
    let segmentId: String?

    /// `01-mvp-schema.sql:76`'s CHECK constraint values, verbatim.
    enum MessageType: String, Codable {
        case user          = "user"
        case systemTracker = "system_tracker"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case zoneId           = "zone_id"
        case authorId         = "author_id"
        case messageType      = "message_type"
        case body
        case relatedReportId  = "related_report_id"
        case createdAt        = "created_at"
        case authorUsername   = "author_username"
        case authorReputation = "author_reputation"
        case segmentId        = "segment_id"
    }
}

// MARK: - ZoneMessageFetchError

/// Errors from `ZoneMessageService.fetchMessages(zoneId:)` / `fetchMessages(segmentId:)`.
enum ZoneMessageFetchError: Error {
    /// The server responded with a non-2xx status.
    case httpError(statusCode: Int)
}

// MARK: - ZoneMessageWriteError (S13b)

/// Errors from `ZoneMessageService.sendMessage(zoneId:segmentId:body:)`. Mirrors
/// `CommunityPinWriteError` (`Services/CommunityPinService.swift`) exactly — same case set,
/// same meaning — kept as a separate type per this file's own established convention of not
/// sharing types across service files (see this file's header note on `ZoneMessage`'s decoder
/// being duplicated, not imported, from `CommunityPinService`'s).
enum ZoneMessageWriteError: Error {
    /// `authService` is `nil`, or has no valid session. Writes require `auth.uid() != null`.
    case notAuthenticated
    /// The server responded with a non-2xx status.
    case httpError(statusCode: Int)
    /// Request body encoding failed.
    case encodingFailure
    /// `body`, once trimmed, is empty or exceeds `zone_messages.body`'s
    /// `check (length(body) between 1 and 1000)` constraint (`01-mvp-schema.sql:77`) — caught
    /// client-side before spending a round trip on a guaranteed-400.
    case invalidBody
    /// The insert succeeded but the server's `return=representation` response body couldn't be
    /// decoded back into a `ZoneMessage` — the write itself is NOT rolled back by this (same
    /// "the write succeeded, only the decode of the echo failed" posture as
    /// `CommunityPinService.insertCrowdPin`'s own decode-failure comment), but the caller has no
    /// row to optimistically append, so this is surfaced rather than silently swallowed.
    case decodingFailure
}

// MARK: - ZoneMessageComposeLogic (S13b)

/// Pure, `nonisolated` draft-validation logic shared by every compose bar that calls
/// `sendMessage` — `Views/CrewFeedSection.swift`'s zone-level "Say something to the square…"
/// bar and `Views/BlockDetailView.swift`'s segment-anchored "Message this block…" bar. One
/// small shared type rather than two independent trim/empty checks that could silently drift
/// (e.g. one accepting whitespace-only text the other rejects).
enum ZoneMessageComposeLogic {
    /// Trims leading/trailing whitespace and newlines. Does NOT enforce the server's max-length
    /// constraint here — `ZoneMessageService.sendMessage` is the single source of truth for
    /// that (`.invalidBody`), so a compose bar's "can I tap send" check and the actual network
    /// call's validation can't disagree about the boundary.
    nonisolated static func trimmedBody(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the send button should be enabled for the current draft text.
    nonisolated static func canSend(draft: String) -> Bool {
        !trimmedBody(draft).isEmpty
    }
}

// MARK: - ZoneMessageService

/// Read-only zone-chat service (Community 2.0 Phase 1). Fetches + Realtime-subscribes to
/// `zone_messages` for a single selected zone at a time.
///
/// All state mutations run on `@MainActor` so `messages` can be observed safely from SwiftUI
/// without additional dispatch — same invariant as `CommunityPinService`.
@MainActor
@Observable
final class ZoneMessageService {

    // MARK: - Published state

    /// Messages for the currently-selected zone, oldest-first — ready for a feed UI that renders
    /// top-to-bottom / appends new messages at the bottom. The REST fetch itself orders
    /// `created_at.desc` to get the most-recent `messageFetchLimit` rows; `fetchMessages`
    /// reverses that before publishing.
    private(set) var messages: [ZoneMessage] = []

    /// True while a network fetch is in progress.
    private(set) var isLoading = false

    /// Set when the most recent fetch failed. `nil` on success. `messages` is left unchanged on
    /// failure (same "fail soft, don't blank what's already on screen" posture as
    /// `CommunityPinService.resolveChannelPins`).
    private(set) var fetchError: Error? = nil

    /// The zone currently selected by the crew feed's zone chips. `nil` = no zone selected —
    /// there is no "all zones" chat view in the design (§1 delta table: zone chips are the only
    /// navigation), so `nil` degrades to an empty feed, not an unfiltered one.
    private(set) var selectedZoneId: String? = nil

    // MARK: - Init parameters

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// S13b: auth session used by `sendMessage(zoneId:segmentId:body:)` — `nil` in
    /// previews/read-only contexts (mirrors `CommunityPinService.authService`'s own optional
    /// convention; the read path above has never needed one, `zone_messages_select_all` is
    /// anonymous-readable). A write attempted with `authService == nil` throws
    /// `.notAuthenticated` rather than crashing.
    let authService: SupabaseAuthService?

    /// URLSession used for all network calls. Injectable for tests (MockURLProtocol pattern),
    /// mirrors `CommunityPinService.urlSession`.
    let urlSession: URLSession

    /// Realtime subscription abstraction. Injectable so tests can substitute
    /// `MockRealtimeZoneMessageChannel` (`#if DEBUG`, below) without a live socket. Production
    /// call sites should prefer `SupabaseClients.makeRealtimeZoneMessageChannel()` (a future
    /// Views-layer wiring session, S4+) over this convenience init's standalone fallback, so the
    /// app shares one `RealtimeClientV2` — same reasoning as `CommunityPinService.realtimeChannel`.
    let realtimeChannel: RealtimeZoneMessageSubscribing

    /// Most recent fetch's in-flight task — cancelled and replaced if `setSelectedZone(_:)` is
    /// called again before it completes (e.g. rapid zone-chip taps). No debounce here, unlike
    /// `CommunityPinService.onRegionChanged`: zone switches are discrete user taps, not a
    /// continuous pan/zoom stream, so there is nothing to coalesce.
    private var fetchTask: Task<Void, Never>? = nil

    /// Maximum number of most-recent messages fetched per zone. First-pass number, not measured
    /// — tune post-launch, same as every other named constant in this codebase (mirrors
    /// `CommunityPinService.pinRefreshIntervalSeconds`'s own "not measured" precedent).
    static let messageFetchLimit = 50

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL. Read from `Info.plist` key `SUPABASE_URL` at
    ///     runtime in production.
    ///   - supabaseAnonKey: The anon/public API key. Read from `Info.plist` key
    ///     `SUPABASE_ANON_KEY` at runtime in production. NEVER hardcode this value in source.
    ///   - urlSession: Injectable URL session. Default `URLSession.shared`.
    ///   - authService: S13b — auth session for `sendMessage`. Default `nil` (read-only use,
    ///     matching every pre-S13b call site of this initializer).
    ///   - realtimeChannel: Injectable Realtime subscription. Default `nil`, in which case a
    ///     standalone `SupabaseZoneMessageRealtimeChannel` is constructed from
    ///     `supabaseURL`/`supabaseAnonKey` — mirrors `CommunityPinService`'s own designated init
    ///     fallback pattern.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        urlSession: URLSession = .shared,
        authService: SupabaseAuthService? = nil,
        realtimeChannel: RealtimeZoneMessageSubscribing? = nil
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.authService = authService
        self.realtimeChannel = realtimeChannel
            ?? SupabaseZoneMessageRealtimeChannel(supabaseURL: supabaseURL, supabaseAnonKey: supabaseAnonKey)
    }

    /// Convenience initializer that reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from
    /// `Bundle.main` (bridged from `Config.xcconfig` via `Info.plist`) — mirrors
    /// `CommunityPinService`'s own convenience init exactly (same placeholder-URL fallback for
    /// pre-config builds).
    convenience init(authService: SupabaseAuthService? = nil, realtimeChannel: RealtimeZoneMessageSubscribing? = nil) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, authService: authService, realtimeChannel: realtimeChannel)
    }

    // MARK: - Zone selection

    /// Sets the active zone and (re)fetches its message history, cancelling any still-in-flight
    /// fetch for a previously-selected zone. Passing `nil` clears both the selection and the
    /// feed immediately (no network call — there is nothing to fetch for "no zone").
    func setSelectedZone(_ zoneId: String?) {
        selectedZoneId = zoneId
        fetchTask?.cancel()
        guard let zoneId else {
            messages = []
            return
        }
        fetchTask = Task { [weak self] in
            await self?.fetchMessages(zoneId: zoneId)
        }
    }

    // MARK: - Fixture injection (test / sim-smoke gate)

    /// Directly sets `messages`, bypassing the network. Mirrors
    /// `CommunityPinService.inject(fixtures:)` — used by unit tests and (in a future session) a
    /// sim-smoke injection point for the crew feed UI.
    func inject(fixtures: [ZoneMessage]) {
        messages = fixtures
    }

    // MARK: - Network fetch

    /// Fetches the most recent `messageFetchLimit` messages for `zoneId`, oldest-first in the
    /// published `messages` array. On failure, sets `fetchError` and leaves `messages`
    /// unchanged.
    func fetchMessages(zoneId: String) async {
        guard let request = buildFetchRequest(zoneId: zoneId) else { return }

        isLoading = true
        fetchError = nil

        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ZoneMessageFetchError.httpError(statusCode: http.statusCode)
            }
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            let decoded = try decodeResponse(data: data)
            // PostgREST returned created_at.desc (most-recent-first, capped at the fetch
            // limit) — reverse for chronological, oldest-first display.
            messages = decoded.reversed()
        } catch is CancellationError {
            // Superseded by a newer setSelectedZone(_:) call — not a real failure, no-op
            // (mirrors CommunityPinService.fetchPins's own cancellation-is-not-a-failure guard).
        } catch {
            fetchError = error
        }

        isLoading = false
    }

    /// Builds the PostgREST URLRequest for the message-history fetch.
    ///
    /// Anonymous read — `zone_messages_select_all` permits SELECT unconditionally
    /// (`01-mvp-schema.sql`, `using (true)`). No Authorization header, matching every other read
    /// path in this codebase (AC-D21 precedent).
    private func buildFetchRequest(zoneId: String) -> URLRequest? {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/zone_messages_with_author"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "zone_id", value: "eq.\(zoneId)"),
            URLQueryItem(name: "order",   value: "created_at.desc"),
            URLQueryItem(name: "limit",   value: "\(Self.messageFetchLimit)"),
            URLQueryItem(
                name: "select",
                value: "id,zone_id,author_id,message_type,body,related_report_id,created_at,author_username,author_reputation,segment_id"
            ),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Decodes a PostgREST JSON array response into `[ZoneMessage]`. Unlike
    /// `CommunityPinService.decodeResponse`, this decodes the whole array directly rather than
    /// element-by-element with a graceful per-row fallback: `ZoneMessage` has no discriminated
    /// `pin_type`-shaped decode surface to defend (`PinMeta`'s associated-value enum has no
    /// counterpart here), so a genuinely malformed row is exactly as likely to indicate a real
    /// schema mismatch worth surfacing via `fetchError` as it is to indicate one bad row among
    /// many good ones. Revisit with a graceful-decode trampoline (mirroring
    /// `CommunityPin.gracefulDecode`) if that assumption turns out to be wrong in practice.
    private func decodeResponse(data: Data) throws -> [ZoneMessage] {
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
        return try decoder.decode([ZoneMessage].self, from: data)
    }

    // MARK: - S13b: Block-scoped read (independent of zone selection)

    /// Maximum most-recent messages fetched for one block's chatter thread. Smaller than
    /// `messageFetchLimit` (a whole zone's history) — a single block's thread is expected to
    /// be short; not measured, tune post-launch, same "not measured" posture as every other
    /// named constant in this codebase.
    static let blockChatterFetchLimit = 30

    /// One-shot fetch of the most recent messages anchored to a specific block (`segment_id`),
    /// independent of `messages`/`selectedZoneId`/`isLoading`/`fetchError` above — the block
    /// detail sheet can be opened for any block regardless of which zone (if any) the crew
    /// feed currently has selected, or whether the crew feed is even open. Mirrors
    /// `CommunityPinService.fetchLeaderboardPins(zoneId:)`'s own "separate one-shot REST fetch
    /// that doesn't touch the zone-chip-driven published state" precedent.
    ///
    /// Throws (rather than fail-soft into an empty array) so the caller (`BlockDetailView`)
    /// can distinguish "no chatter yet" (empty array) from "the fetch failed" — the two need
    /// different UI (an intentional empty state vs. simply leaving whatever was on screen).
    ///
    /// Anonymous read — same `zone_messages_select_all` policy as `fetchMessages(zoneId:)`, no
    /// Authorization header needed.
    func fetchMessages(segmentId: String) async throws -> [ZoneMessage] {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/zone_messages_with_author"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "segment_id", value: "eq.\(segmentId)"),
            URLQueryItem(name: "order",      value: "created_at.desc"),
            URLQueryItem(name: "limit",      value: "\(Self.blockChatterFetchLimit)"),
            URLQueryItem(
                name: "select",
                value: "id,zone_id,author_id,message_type,body,related_report_id,created_at,author_username,author_reputation,segment_id"
            ),
        ]
        guard let url = components?.url else { throw ZoneMessageFetchError.httpError(statusCode: 0) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZoneMessageFetchError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Same server ordering (created_at.desc) as fetchMessages(zoneId:) — reverse for
        // chronological, oldest-first display.
        return try decodeResponse(data: data).reversed()
    }

    // MARK: - S13b: Write path — send a message

    /// `zone_messages.body`'s CHECK constraint, verbatim (`01-mvp-schema.sql:77`):
    /// `length(body) between 1 and 1000`. Checked client-side so an over-length draft fails
    /// fast with `.invalidBody` instead of spending a round trip on a guaranteed 400.
    static let bodyMaxLength = 1000

    /// Inserts a new `zone_messages` row — the write path `Views/BlockDetailView.swift`'s
    /// "BLOCK CHATTER" compose bar and `Views/CrewFeedSection.swift`'s zone-level compose bar
    /// both call. See this file's header for the full RLS/RETURNING verdict this method's
    /// shape is built on.
    ///
    /// - Parameters:
    ///   - zoneId: Required — `zone_messages.zone_id` is `not null` (`01-mvp-schema.sql:74`).
    ///     Callers anchoring to a specific block (no explicit zone chip selected) must derive
    ///     one first (`BlockDetailLogic.resolvedZoneId(forSegmentMidpoint:)` in
    ///     `Views/BlockDetailView.swift`) and treat a `nil` result as "can't post here" rather
    ///     than calling this with a placeholder.
    ///   - segmentId: `nil` for a zone-wide message (the crew feed's "Say something to the
    ///     square…" compose bar); non-nil for a block-anchored message
    ///     (`Segment.id` — the SAME raw tile-segment id `ReportSheet`'s crowd-report write path
    ///     already stamps on `pins.segment_id`, per `Views/CrewFeedSection.swift`'s own header
    ///     note on that id shape — NOT the 4-part `blockfaceKey` format).
    ///   - body: Raw draft text. Trimmed and length-checked against
    ///     `zone_messages.body`'s CHECK constraint before the request is built.
    /// - Returns: The inserted `ZoneMessage`, decoded from the server's `return=representation`
    ///   echo — the caller can append it to its own local state immediately (this method does
    ///   NOT append it to `messages` unconditionally; see below).
    @discardableResult
    func sendMessage(zoneId: String, segmentId: String? = nil, body: String) async throws -> ZoneMessage {
        guard let authSvc = authService else {
            throw ZoneMessageWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw ZoneMessageWriteError.notAuthenticated
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.bodyMaxLength else {
            throw ZoneMessageWriteError.invalidBody
        }

        var payload: [String: Any] = [
            "zone_id":       zoneId,
            "author_id":     userId.uuidString,
            "message_type":  ZoneMessage.MessageType.user.rawValue,
            "body":          trimmed,
        ]
        if let segmentId { payload["segment_id"] = segmentId }

        guard let requestBody = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ZoneMessageWriteError.encodingFailure
        }

        // return=representation: deliberate, not the default — see this file's header for the
        // RLS check that makes this safe (zone_messages_select_all is `using (true)`, so the
        // author can always read back their own just-inserted row).
        let request = buildAuthenticatedRequest(
            path: "rest/v1/zone_messages",
            method: "POST",
            jwt: jwt,
            body: requestBody,
            extraHeaders: [
                "Prefer": "return=representation",
                "Accept": "application/json",
            ]
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ZoneMessageWriteError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let inserted = try? decodeResponse(data: data), let message = inserted.first else {
            throw ZoneMessageWriteError.decodingFailure
        }

        // Optimistic add to the zone-chip-driven feed — ONLY when this message's zone matches
        // whatever zone is currently selected there (the crew feed's own compose bar always
        // satisfies this; a block-anchored send from BlockDetailView may or may not, depending
        // on whether the crew feed even has a zone selected right now — either way this stays
        // correct, since `handleRealtimeInsert`'s own de-dupe-by-id guard makes a redundant
        // append here harmless if a Realtime echo also lands). `BlockDetailView` itself does
        // NOT rely on this side effect — it appends the returned message to its own local
        // block-scoped state directly.
        if selectedZoneId == zoneId, !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }

        return message
    }

    /// Builds an authenticated PostgREST request — mirrors
    /// `CommunityPinService.buildAuthenticatedRequest` exactly (same header shape), duplicated
    /// per this file's own established "no cross-service-file type/helper sharing" convention
    /// (see this file's header note on `ZoneMessage`'s decoder being duplicated, not imported).
    private func buildAuthenticatedRequest(
        path: String,
        method: String,
        jwt: String,
        body: Data?,
        extraHeaders: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: supabaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }

    // MARK: - Realtime subscription

    /// The chain "tail" for connect/disconnect serialization — same race-avoidance pattern as
    /// `CommunityPinService.realtimeLifecycleTask`. See that property's doc comment for the full
    /// rationale (PR #84 lifecycle race) this mirrors verbatim.
    private var realtimeLifecycleTask: Task<Void, Never>?

    /// `internal` (not `private`) so tests can await the full connect chain — same rationale as
    /// `CommunityPinService.realtimeConnectTask`.
    var realtimeConnectTask: Task<Void, Never>? = nil

    /// Same rationale as `CommunityPinService.realtimeDisconnectTask`.
    var realtimeDisconnectTask: Task<Void, Never>? = nil

    /// Establishes the Realtime WebSocket subscription on `public.zone_messages` (INSERT only —
    /// see this file's header for why UPDATE/DELETE never apply to this table). Serialized
    /// against any in-flight `disconnectRealtime()` the exact same way
    /// `CommunityPinService.startRealtime()` is.
    func startRealtime() {
        let predecessor = realtimeLifecycleTask
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.realtimeChannel.connect { [weak self] message in
                self?.handleRealtimeInsert(message)
            }
        }
        realtimeLifecycleTask = task
        realtimeConnectTask = task
    }

    /// Tears down the Realtime WebSocket. Mirrors `CommunityPinService.disconnectRealtime()`.
    func disconnectRealtime() {
        let predecessor = realtimeLifecycleTask
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.realtimeChannel.disconnect()
        }
        realtimeLifecycleTask = task
        realtimeDisconnectTask = task
    }

    /// Re-establishes the Realtime WebSocket. Mirrors `CommunityPinService.reconnectRealtime()`.
    func reconnectRealtime() {
        startRealtime()
    }

    /// Gates an incoming Realtime INSERT through the zone dimension before appending — the
    /// `zone_messages` counterpart to `CommunityPinService.handleRealtimeUpsert`'s zone gate
    /// added this same session. No pin-type/viewport dimensions apply here (chat has neither
    /// concept). `nil` `selectedZoneId` (no zone chosen yet) drops every event, matching
    /// `setSelectedZone(nil)`'s own "no zone = empty feed" contract — an event can never appear
    /// for a zone the user hasn't picked.
    private func handleRealtimeInsert(_ message: ZoneMessage) {
        guard let selectedZoneId, message.zoneId == selectedZoneId else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
    }
}

// MARK: - RealtimeZoneMessageSubscribing

/// Protocol seam for the Realtime `zone_messages` subscription — enables
/// `MockRealtimeZoneMessageChannel` injection in tests and keeps `ZoneMessageService`'s own
/// consumers free of any SDK import. Mirrors `RealtimePinSubscribing`
/// (`Services/RealtimePinChannel.swift`) with one fewer callback: `zone_messages` is
/// insert-only/immutable (no update or delete policy exists — see this file's header), so there
/// is no `onDelete`/`onUpdate` counterpart to `onUpsert`.
@MainActor
protocol RealtimeZoneMessageSubscribing: AnyObject {
    /// True while the underlying socket reports a connected state.
    var isConnected: Bool { get }

    /// Subscribes to INSERT on `public.zone_messages`. Safe to call redundantly.
    func connect(onInsert: @escaping @MainActor (ZoneMessage) -> Void) async

    /// Tears down the socket. Safe to call redundantly / when not connected.
    func disconnect() async
}

// MARK: - SupabaseZoneMessageRealtimeChannel

/// Real implementation wrapping the SDK's `RealtimeClientV2` + `RealtimeChannelV2`. Every SDK
/// call here is the identical shape already used (and verified against the pinned
/// supabase-swift revision) in `RealtimePinChannel.swift`'s `SupabasePinRealtimeChannel` —
/// deliberately not a new, unverified API surface.
@MainActor
final class SupabaseZoneMessageRealtimeChannel: RealtimeZoneMessageSubscribing {

    /// Fixed topic name for the single table-wide `public.zone_messages` channel — mirrors
    /// `SupabasePinRealtimeChannel.topic`'s own "identifier only, not schema/table-derived"
    /// convention.
    private static let topic = "public:zone_messages"

    private let realtimeClient: RealtimeClientV2
    private var channel: RealtimeChannelV2?

    /// Retains the `onPostgresChange` subscription token — the callback is cancelled if this
    /// token is deallocated (per `RealtimeChannelV2`'s own doc, same as the pins channel).
    private var subscriptionToken: RealtimeSubscription?

    /// Designated initializer — takes an already-constructed `RealtimeClientV2`, shared across
    /// the app for this Supabase project's lifetime. Production call sites reach this via
    /// `SupabaseClients.makeRealtimeZoneMessageChannel()`.
    init(realtimeClient: RealtimeClientV2) {
        self.realtimeClient = realtimeClient
    }

    /// Convenience initializer — builds its own standalone `RealtimeClientV2` from raw
    /// URL/key. Used only as `ZoneMessageService`'s internal fallback default when no shared
    /// `SupabaseClients` instance is injected — mirrors `SupabasePinRealtimeChannel`'s own
    /// convenience init exactly.
    convenience init(supabaseURL: URL, supabaseAnonKey: String) {
        self.init(
            realtimeClient: RealtimeClientV2(
                url: supabaseURL.appendingPathComponent("realtime/v1"),
                options: RealtimeClientOptions(headers: ["apikey": supabaseAnonKey])
            )
        )
    }

    var isConnected: Bool {
        realtimeClient.status == .connected
    }

    func connect(onInsert: @escaping @MainActor (ZoneMessage) -> Void) async {
        await realtimeClient.connect()

        let ch: RealtimeChannelV2
        if let existing = channel {
            ch = existing
        } else {
            let newChannel = realtimeClient.channel(Self.topic)
            channel = newChannel
            subscriptionToken = newChannel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "zone_messages"
            ) { action in
                Task { @MainActor in
                    Self.handle(action, onInsert: onInsert)
                }
            }
            ch = newChannel
        }

        // Idempotent: skip if already subscribed/subscribing (redundant connect() call) — same
        // guard shape as SupabasePinRealtimeChannel.connect.
        guard ch.status != .subscribed, ch.status != .subscribing else { return }

        do {
            try await ch.subscribeWithError()
        } catch {
            print("[SupabaseZoneMessageRealtimeChannel] subscribe failed (SDK will retry on reconnect): \(error)")
        }
    }

    func disconnect() async {
        if let channel {
            await channel.unsubscribe()
        }
        realtimeClient.disconnect()
    }

    /// Routes one decoded `AnyAction` to `onInsert`. Only `.insert` is ever meaningful for
    /// `zone_messages` (no UPDATE/DELETE policy exists — see this file's header); `.update`/
    /// `.delete` cases are ignored defensively here rather than assumed unreachable, matching
    /// `CommunityPin.gracefulDecode`'s soft-failure posture for the REST path (a single
    /// unexpected event must not crash the feed).
    @MainActor
    private static func handle(_ action: AnyAction, onInsert: @MainActor (ZoneMessage) -> Void) {
        guard case .insert(let insert) = action,
              let message = try? insert.decodeRecord(as: ZoneMessage.self, decoder: jsonDecoder) else {
            return
        }
        onInsert(message)
    }

    /// Decoder for `InsertAction.record` → `ZoneMessage`. Same custom ISO8601 date strategy
    /// (with and without fractional seconds) as `ZoneMessageService.decodeResponse` — the two
    /// decoders must stay in sync since both decode the identical `zone_messages` row shape
    /// from the same server. Duplicated (not shared) for the same file-independence reason
    /// `RealtimePinChannel.swift`'s own copy is duplicated from `CommunityPinService`'s.
    private static let jsonDecoder: JSONDecoder = {
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
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Cannot decode date: \(string)"
                )
            )
        }
        return decoder
    }()
}

// MARK: - Test seam (DEBUG only)

#if DEBUG

/// In-memory double for `RealtimeZoneMessageSubscribing` — no live socket, no SDK import needed
/// by `WeParkTests`. Mirrors `MockRealtimePinChannel` (`Services/RealtimePinChannel.swift`)
/// exactly, minus the `onDelete` callback `zone_messages` has no counterpart for.
final class MockRealtimeZoneMessageChannel: RealtimeZoneMessageSubscribing {
    private(set) var isConnected: Bool = false

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    /// Captured on the most recent `connect(onInsert:)` call so tests can invoke it directly to
    /// simulate an inbound Realtime event without a live socket.
    private(set) var capturedOnInsert: (@MainActor (ZoneMessage) -> Void)?

    func connect(onInsert: @escaping @MainActor (ZoneMessage) -> Void) async {
        connectCallCount += 1
        isConnected = true
        capturedOnInsert = onInsert
    }

    func disconnect() async {
        disconnectCallCount += 1
        isConnected = false
    }

    /// Test helper: simulates an inbound Realtime INSERT without a live socket.
    func simulateInsert(_ message: ZoneMessage) {
        capturedOnInsert?(message)
    }
}

#endif

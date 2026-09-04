//
//  CommunityPinService.swift
//  WePark
//
//  Tier 1 Pin Display — Community 1.0 read-only fetch + Realtime subscription stub.
//  Tier 3 Sub-PR #1 additions: authenticated write path (insertCrowdPin, upsertVote,
//  callExtendPinExpiry) + Realtime channel activation for ephemeral crowd pins.
//  FT-2 addition: deleteCrowdPin — hard-delete a pin the current user authored.
//  Spec: docs/tier1-pin-display-spec.md §9, docs/tier3-auth-and-reactions-spec.md §3.9,
//  docs/ft2-delete-own-pin-spec.md.
//
//  Responsibilities:
//   - Debounced (800ms) PostgREST bounding-box fetch, merged from 3 channels:
//       1. filming / asp_suspended_today / special_event (source = open_data, not expired, not resolved)
//       2. enforcement_active / sweeper_passed (source = crowd, lifespan = ephemeral, not expired, not resolved)
//       3. filming / construction (source = crowd, block-scoped reports, not expired, not resolved) — FT-15/TF2-15
//   - Periodic refresh (pinRefreshIntervalSeconds) re-fetches the last visible region — now a
//     RECONCILIATION FALLBACK behind real Realtime (below), not the primary freshness
//     mechanism. Retuned 8s → 45s accordingly (supabase-swift Stream B, spec §6.1). Still
//     suspended entirely during Drive Mode — see the Realtime section below for why that
//     remains safe.
//   - Real WebSocket Realtime subscription on `public.pins` (supabase-swift Stream B — see
//     "Realtime" section below). STAYS CONNECTED through Drive Mode — this is what replaces
//     the periodic-refresh suspension as the live-update mechanism while driving (spec §7).
//   - Client-side expiry filter: removes pins where expiresAt != nil && expiresAt <= nowProvider().
//   - Publishes `visiblePins: [CommunityPin]` — ContentView observes this.
//   - Write path: insertCrowdPin / upsertVote / callExtendPinExpiry (authenticated, sub-PR #1).
//   - Write path: deleteCrowdPin (FT-2) — hard-deletes a pin the caller authored, gated
//     server-side by the pre-existing `pins_delete_own` RLS policy. Optimistic local
//     removal before the network call; a Realtime DELETE echo for the same pin is a
//     harmless no-op against `removePin(id:)`. If the network call itself throws, the
//     pin is rolled back into `visiblePins` at its original position — UNLESS a genuine
//     Realtime DELETE echo for that same id already arrived during the round trip, in
//     which case the server truth (really deleted) wins and the rollback is suppressed.
//     See `deleteCrowdPin`'s doc comment for the full reasoning.
//   - Optimistic add after insertCrowdPin: uses return=representation + mergeRealtimeChange
//     so the reporter sees their own pin immediately without panning (Fix 1).
//
//  Architectural invariants (HANDOFF.md Changelog 2026-05-26, spec §5):
//   - @MainActor: all visiblePins mutations run on the main actor so SwiftUI reads are safe.
//   - No Calendar.current — all time math uses nowProvider() (injectable for tests).
//   - REST network path: raw URLSession + Codable (no supabase-swift SPM dep for reads/writes —
//     spec §2 Out, §6.1, §14: deliberately not migrated to the SDK's PostgREST client).
//   - Supabase URL + anon key injected at init (read from Config.xcconfig → Info.plist at runtime).
//   - The key is NEVER hardcoded here. See Config.xcconfig.example for the key names.
//
//  Drive Mode guard (spec §6.3):
//   - If driveModeActive AND the region center moved < 200m from the last fetch center,
//     the debounced re-fetch is skipped to avoid hammering Supabase during active navigation.
//
//  Fixture mode (TF1 build gate):
//   - inject() replaces visiblePins directly with caller-supplied fixtures.
//   - Used by CommunityPinServiceTests and by ContentView for the sim smoke gate.
//
//  Realtime (supabase-swift Stream B — docs/supabase-swift-realtime-spec.md §5, §7, §8):
//   - startRealtime() establishes ONE table-wide WebSocket subscription on `public.pins`
//     (INSERT/UPDATE/DELETE), via the injected `realtimeChannel: RealtimePinSubscribing`
//     (real impl: `Services/RealtimePinChannel.swift`'s `SupabasePinRealtimeChannel`, wrapping
//     the supabase-swift SDK's `RealtimeClientV2`/`RealtimeChannelV2`).
//   - NOT two channels split by `source=eq.open_data` / `lifespan=eq.ephemeral` — an earlier
//     TODO comment here sketched that design; it was WRONG (§5.1: `postgres_changes` filters
//     can't express the REST channels' compound predicates) and has been replaced. See the
//     spec for the full reasoning if this needs revisiting.
//   - Every event is gated through `RealtimeMergeGate` (pin-type eligibility + viewport,
//     against `lastFetchedRegion`) before reaching the existing, unmodified
//     `mergeRealtimeChange(pin:)` (upsert) or the new `removePin(id:)` (delete).
//   - Stays connected through Drive Mode — the periodic REST poll stays suspended during
//     Drive Mode (unchanged), but that's now safe because Realtime is the live mechanism, not
//     the poll (spec §7 — the headline win: enforcement pins used to go fully stale while
//     circling/driving; they no longer do).
//   - `disconnectRealtime()`/`reconnectRealtime()` are wired to ContentView's `.background`/
//     `.active` scenePhase transitions (spec §5.3).
//
//  Write-path read path:
//   - Read path remains raw URLSession with no Authorization header (anon read, AC-D21).
//   - Write path attaches Authorization: Bearer <jwt> via SupabaseAuthService.
//   - authService is injected at init. The convenience init() creates a shared instance.
//
//  FT-15 / TF2-15 (docs/ft15-tf215-temporary-block-restrictions-spec.md, Stream B4):
//   - Adds Channel 3 (buildCrowdBlockScopedRequest): source=crowd, pin_type in
//     (filming, construction), resolved_at is null, not expired. §3.4 calls this out
//     explicitly as the gap that made the whole feature invisible pre-B4 — neither
//     Channel 1 (hardcodes source=eq.open_data) nor Channel 2 (hardcodes
//     lifespan=eq.ephemeral) would ever return a source=crowd, lifespan=session row.
//   - Adds blockScopedRestriction(forBlockfaceKey:) — the shared lookup used by
//     BlockDetailView / ParkedCarDetailView to decide whether to show the "Temporary
//     restriction reported" banner (§9.2).
//   - mergeableTypes (Realtime/optimistic-add merge path) widened to include
//     .construction, matching the read path's new coverage.
//
//  FT-15 / TF2-15 (docs/ft15-tf215-temporary-block-restrictions-spec.md, Stream B3):
//   - Adds insertBlockScopedReport(...) — the write path B2's BlockRestrictionReportSheet
//     calls on Submit. Uploads the evidence photo (via the new PinEvidenceUploader), then
//     inserts N `pins` rows (one per selected blockface) sharing one client-generated
//     `report_group_id`, per §3.4's write order.
//   - See insertBlockScopedReport's own doc comment for the partial-failure decision
//     (best-effort rollback of a partially-succeeded pins batch; the evidence row itself
//     is left as an accepted, documented orphan on that specific failure path, matching
//     supabase/02f-block-scoped-restrictions.sql's own accepted-gap posture).
//   - Rate-limit rejections (PostgREST errcode 42501 / HTTP 403 from the schema's
//     enforce_block_scoped_rate_limit() trigger) are surfaced as a distinct
//     BlockScopedReportError.rateLimitExceeded case with clear user-facing copy, not a
//     generic HTTP error.
//
//  Community 2.0 Phase 1 (docs/community-2.0-reconciliation-spec.md §1 delta table, §3 Phase 1
//  — build 20, session S3). Three of this file's own extension seams, each a small, named
//  change:
//   - Channel 2 (crowd ephemeral fetch): pin_type list + `isChannel2Member` widened to include
//     `.openSpot`/`.leavingSoon` (spec §2.8: both are `lifespan='ephemeral'`, same as
//     enforcement/sweeper). Select list also widened to request `position_fraction`/
//     `leaving_minutes`/`claimed_by` — otherwise the two new types would fetch successfully but
//     silently decode those three fields as nil, defeating the point of adding them.
//   - `ephemeralTTLSeconds(for:leavingMinutes:)` updated to the resolved OQ-2 values: 45m
//     (`enforcement_active`), 120m (`sweeper_passed`, both a reversal of FT-1's 5-minute
//     baseline — see the method's own doc comment for the full reasoning), 3m (`open_spot`,
//     net-new), stated-minutes+3 (`leaving_soon`, net-new). Per spec §0 OQ-2: "staleness is the
//     signal" — an aged enforcement/sweeper pin is now read as useful history ("agent already
//     came through"), not stale noise, so every surface rendering these pins must show relative
//     age. This method drives `insertCrowdPin`'s client-computed `expires_at` (superseded
//     server-side for `open_spot`/`leaving_soon` by the §2.11 trigger — this client value is
//     display/decay math, not the write-path source of truth for those two types) and is
//     reused directly by tests exercising the TTL table.
//   - `RealtimeMergeGate` gained a THIRD gating dimension (zone_id), alongside pin-type
//     eligibility and viewport — `selectedZoneId`/`setSelectedZone(_:)` below are this
//     service's half of that: `nil` (default) = no zone filter, byte-identical to this
//     service's pre-Phase-1 behavior until S4's zone chips call `setSelectedZone(_:)`.
//

import Foundation
import MapKit

// MARK: - VoteType

/// The two vote values for crowd pin reactions (spec §3.9).
/// Raw value matches the DB column value exactly (AC-V1).
enum VoteType: String {
    case confirm  = "confirm"
    case dispute  = "dispute"

    // Vote retraction: tapping the opposite button upserts over the existing vote.
    // The upsert semantics (Prefer: resolution=merge-duplicates) handle this transparently.
    // No explicit "undo" mechanism needed — the last write wins on (pin_id, user_id).
}

// MARK: - CommunityPinWriteError

/// Errors from the authenticated write path.
enum CommunityPinWriteError: Error {
    /// SupabaseAuthService has no current session. Writes require auth.uid() != null.
    case notAuthenticated
    /// The server responded with a non-2xx status.
    case httpError(statusCode: Int)
    /// Request body encoding failed.
    case encodingFailure
}

// MARK: - CommunityProfile (Community 2.0 Phase 3, build 20 S9)

/// A lean read of one `profiles` row — backs the crew-feed profile row
/// (`design/prototype.html:161-173`, spec §2.5/§3 Phase 3). Deliberately not the full
/// `profiles` schema shape (no `updated_at`) — only what the profile row + leaderboard
/// "You" row need to render. `Decodable` only; this is a read-only model, never encoded
/// (`CommunityPinService.upsertProfile` already owns the write path with its own narrower
/// username/avatar-only payload — the client never writes its own reputation/counts,
/// spec §2.6/§3 Phase 2's standing constraint).
struct CommunityProfile: Decodable {
    let id: UUID
    let username: String
    let avatar: String?
    let reputation: Int
    let createdAt: Date
    let helpedCount: Int
    let accurateReportCount: Int
    let totalReportCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, username, avatar, reputation
        case createdAt           = "created_at"
        case helpedCount         = "helped_count"
        case accurateReportCount = "accurate_report_count"
        case totalReportCount    = "total_report_count"
    }
}

// MARK: - FT-15 / TF2-15: Block-scoped report write path (Stream B3)

/// One blockface to include in a block-scoped restriction report.
///
/// Spec: `docs/ft15-tf215-temporary-block-restrictions-spec.md` §4.2, §4.3.
///
/// `blockfaceKey` is expected to be a `Segment.blockfaceKey` value — read verbatim off a
/// tapped `Segment` (B2's map multi-select), never re-derived from text. `lat`/`lng` are
/// the marker coordinate for this blockface's `pins` row; callers typically pass the
/// tapped `Segment`'s `midpoint`. This type intentionally does not import or reference
/// `Segment` directly, keeping `Services/CommunityPinService.swift` decoupled from the
/// specific model B2 sources selections from — any caller that can produce a key + a
/// coordinate can use this write path.
struct BlockScopedReportSelection {
    let blockfaceKey: String
    let lat: Double
    let lng: Double

    init(blockfaceKey: String, lat: Double, lng: Double) {
        self.blockfaceKey = blockfaceKey
        self.lat = lat
        self.lng = lng
    }
}

/// Result of a successful `insertBlockScopedReport(...)` call.
struct BlockScopedReportResult {
    /// The client-generated UUID shared by every inserted row.
    let reportGroupId: UUID
    /// The N inserted `pins` rows, in the same order as the input `selections`.
    let insertedPins: [CommunityPin]
}

/// Errors from `CommunityPinService.insertBlockScopedReport(...)`.
enum BlockScopedReportError: Error {
    /// No valid auth session.
    case notAuthenticated
    /// `selections` was empty — nothing to report. Mirrors AC-R3 ("Continue is disabled
    /// with zero blocks selected") as a second, independent guard at the write-path
    /// boundary; B2's UI should never actually reach this, but the write path doesn't
    /// trust the caller to have enforced it.
    case emptySelections
    /// `pinType` was not `.filming` or `.construction` — the only two types this primitive
    /// serves (§9.3).
    case unsupportedPinType(PinType)
    /// The evidence photo failed to upload (Storage object or `pin_evidence` row insert —
    /// see `PinEvidenceUploadError` for which). Zero `pins` rows have been attempted at
    /// this point.
    case evidenceUploadFailed(underlying: Error)
    /// The rate-limit trigger rejected an insert (PostgREST errcode `42501` /
    /// `insufficient_privilege` — `enforce_block_scoped_rate_limit()` in
    /// `supabase/02f-block-scoped-restrictions.sql`). Detected from the parsed response
    /// body, not just the HTTP status, so an unrelated 403 can't misfire this case.
    case rateLimitExceeded
    /// A `pins` row insert failed for a reason other than the rate limit (network error,
    /// hard-ceiling CHECK violation, etc.). Any rows already inserted for this batch have
    /// been best-effort rolled back before this is thrown — see
    /// `insertBlockScopedReport`'s doc comment for the full partial-failure decision.
    case pinsInsertFailed(statusCode: Int)
    /// The resolved end time is not strictly after `startsAt` (§5's window model; matches
    /// `pins_block_scoped_report_group_required_chk`'s sibling constraint
    /// `pins_starts_before_expires_chk`, which rejects this server-side too). B2's date
    /// pickers are expected to prevent this in the UI — this is a second, defensive guard
    /// at the write-path boundary so an obviously-inverted/zero-length window never even
    /// reaches the network, mirroring the hard-ceiling clamp's "avoid a confusing generic
    /// error for an obviously invalid submission" reasoning. Thrown before any network
    /// call (evidence upload included).
    case invalidWindow
    /// Request body JSON encoding failed.
    case encodingFailure
}

extension BlockScopedReportError: LocalizedError {
    /// User-facing copy for B2's submit-error UI (mirrors `ReportSheet.submitError`'s
    /// existing inline-error pattern). Deliberately never echoes a raw server message or
    /// status code into user-visible text.
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You need to be signed in to submit a report. Try again in a moment."
        case .emptySelections:
            return "Select at least one block before continuing."
        case .unsupportedPinType:
            return "Something went wrong preparing your report. Try again."
        case .evidenceUploadFailed(let underlying):
            return (underlying as? LocalizedError)?.errorDescription
                ?? "Couldn't upload your evidence photo. Check your connection and try again."
        case .rateLimitExceeded:
            return "You've reported the maximum number of closures for now — please try again later."
        case .pinsInsertFailed:
            return "Couldn't submit your report. Check your connection and try again."
        case .invalidWindow:
            return "The restriction end time must be after the start time."
        case .encodingFailure:
            return "Something went wrong preparing your report. Try again."
        }
    }
}

// MARK: - CommunityPinService

/// Read-only community pin service for Tier 1 open-data pins.
///
/// Fetches `filming`, `asp_suspended_today`, and `special_event` pins from the Supabase
/// `pins_with_author` view via a debounced bounding-box PostgREST query.
/// Realtime subscription supplements the poll for live ingest updates.
///
/// All state mutations run on `@MainActor` so `visiblePins` can be observed safely
/// from SwiftUI without additional dispatch.
@MainActor
@Observable
final class CommunityPinService {

    // MARK: - Published state

    /// Pins currently visible in the fetched bounding box, after client-side expiry filter.
    /// ContentView observes this to push markers to the map and feed the ASP banner supplement.
    private(set) var visiblePins: [CommunityPin] = [] {
        didSet { visiblePinsGeneration += 1 }
    }

    /// Incremented every time `visiblePins` changes.
    ///
    /// ContentView observes this `Int` via `.onChange(of: pinService.visiblePinsGeneration)`
    /// rather than `.onChange(of: pinService.visiblePins)` because `CommunityPin` is not
    /// `Equatable` (AC-D20 freezes `CommunityPin.swift`). `Int` is always `Equatable`,
    /// so this pattern sidesteps the conformance requirement without modifying the model.
    private(set) var visiblePinsGeneration: Int = 0

    /// True while a network fetch is in progress.
    private(set) var isLoading: Bool = false

    /// Set when the most recent fetch failed. Nil on success.
    private(set) var fetchError: Error? = nil

    // MARK: - Init parameters

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// Injectable time provider. Default: `{ Date() }`.
    /// Tests override this to freeze time for expiry assertions (AC-D1 through AC-D4).
    let nowProvider: () -> Date

    /// URLSession used for all network calls. Injectable for tests (MockURLProtocol pattern).
    let urlSession: URLSession

    /// Auth service that provides the JWT for authenticated writes (Tier 3 sub-PR #1).
    /// Nil is valid for read-only mode (Tier 1 paths) — the fetch path does not require auth.
    /// Tests that only exercise the read path can leave this nil.
    let authService: SupabaseAuthService?

    /// Realtime subscription abstraction (supabase-swift Stream B). Injectable so tests can
    /// substitute `MockRealtimePinChannel` (`Services/RealtimePinChannel.swift`, `#if DEBUG`)
    /// without a live socket. Production call sites (`ContentView`, via `WeParkApp`'s shared
    /// `SupabaseClients.makeRealtimePinChannel()`) inject a real `SupabasePinRealtimeChannel`
    /// sharing the app-lifetime `RealtimeClientV2`.
    let realtimeChannel: RealtimePinSubscribing

    // MARK: - Internal state

    // MARK: - Periodic refresh interval constant

    /// Interval for the periodic region re-fetch (Fix 2).
    /// Retuned 8s → 45s (supabase-swift Stream B, spec §6.1) now that real WebSocket
    /// Realtime (below) is the PRIMARY freshness mechanism — this poll is a reconciliation
    /// fallback: it catches anything a dropped/reconnecting socket missed, at a much lower
    /// cadence than when it was the only live-update path. First-pass number, not measured
    /// (spec §13 OQ-1) — tune post-launch same as every other named constant in this codebase.
    /// Named constant so it can be referenced in tests without magic numbers.
    static let pinRefreshIntervalSeconds: TimeInterval = 45

    /// In-flight debounce task. Cancelled and replaced on each `onRegionChanged` call.
    private var fetchTask: Task<Void, Never>? = nil

    /// Repeating periodic refresh task (Fix 2). Created lazily in `startPeriodicRefresh()`.
    /// Cancelled by `stopPeriodicRefresh()` when Drive Mode activates or the service is torn down.
    ///
    /// `internal` (not `private`) so tests can assert scheduling invariants via `@testable import`:
    /// e.g. "startPeriodicRefresh sets a non-nil task", "setDriveModeActive(true) clears the task".
    /// This is the narrowest access widening required — all tests use it as a non-nil/nil probe only.
    var periodicRefreshTask: Task<Void, Never>? = nil

    /// The last map region that was successfully fetched.
    /// Used by the periodic refresh to re-fetch the same viewport (Fix 2).
    private(set) var lastFetchedRegion: MKCoordinateRegion? = nil

    /// The map center used for the most recent completed fetch.
    /// Used by the Drive Mode re-fetch guard (spec §6.3: skip if center moved < 200m).
    private var lastFetchCenter: CLLocationCoordinate2D? = nil

    /// True when Drive Mode is active. Set from ContentView via `setDriveModeActive(_:)`.
    private var driveModeActive: Bool = false

    /// The zone currently selected by the crew feed's zone chips (Community 2.0 Phase 1 UI,
    /// S4). `nil` = no zone filter active — every Realtime event passes the zone dimension
    /// unconditionally (`RealtimeMergeGate.isInZone`), byte-identical to this service's
    /// pre-Phase-1 behavior until a caller sets this. `private(set)` so tests can assert the
    /// value `setSelectedZone(_:)` last wrote, same "narrowest access widening for test
    /// assertions" precedent as `periodicRefreshTask` above.
    private(set) var selectedZoneId: String? = nil

    /// Tracks pins whose optimistic removal (`deleteCrowdPin`) is still in flight, keyed by
    /// pin id, so a genuine Realtime DELETE echo that lands during the network round trip can
    /// be distinguished from "no echo arrived yet" once the round trip completes.
    ///
    /// Value semantics: `false` means "optimistically removed, no Realtime confirmation seen
    /// yet"; `true` means `removePin(id:)` was called for this id while the entry existed —
    /// i.e. the server genuinely deleted the row and Realtime confirmed it independently of
    /// this client's own in-flight request. `deleteCrowdPin` consults this value in its
    /// failure path to decide whether restoring the pin would resurrect something the server
    /// actually deleted (see `deleteCrowdPin` and `rollbackOptimisticDelete` doc comments).
    ///
    /// An id is only ever present here for the duration of one `deleteCrowdPin` call — set
    /// just before the optimistic removal, cleared via `defer` when that call returns or
    /// throws. Not a general-purpose cache: a Realtime echo that arrives before or after that
    /// window (no matching entry) just runs `removePin(id:)`'s normal, unconditional removal.
    private var pendingOptimisticDeletes: [UUID: Bool] = [:]

    /// Consecutive failure count per channel label ("open_data" / "crowd_ephemeral" /
    /// "crowd_block_scoped"). Used only to throttle `logChannelFailure` console spam during
    /// a sustained outage (e.g. Channel 3 hitting production before Stream A's migration
    /// lands — docs/qa/ft15-b4-fetch-channel-qa.md Findings #1/#2). Reset to 0 on success.
    private var channelFailureStreak: [String: Int] = [:]

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL (e.g. `https://<project>.supabase.co`).
    ///     Read from `Info.plist` key `SUPABASE_URL` at runtime in production.
    ///   - supabaseAnonKey: The anon/public API key.
    ///     Read from `Info.plist` key `SUPABASE_ANON_KEY` at runtime in production.
    ///     NEVER hardcode this value in source.
    ///   - nowProvider: Injectable time source. Default `{ Date() }`.
    ///   - urlSession: Injectable URL session. Default `URLSession.shared`.
    ///   - realtimeChannel: Injectable Realtime subscription. Default `nil`, in which case a
    ///     standalone `SupabasePinRealtimeChannel` is constructed from `supabaseURL`/
    ///     `supabaseAnonKey` (mirrors `authService`'s own "default nil, real value can't be a
    ///     plain default-argument expression" pattern — a real Realtime channel needs
    ///     `supabaseURL`/`supabaseAnonKey`, which aren't available in a default-argument
    ///     expression referencing sibling parameters). Production call sites should prefer
    ///     passing `SupabaseClients.makeRealtimePinChannel()` instead, so the app shares one
    ///     `RealtimeClientV2` for its whole lifetime rather than each service standing up its
    ///     own socket.
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        nowProvider: @escaping () -> Date = { Date() },
        urlSession: URLSession = .shared,
        authService: SupabaseAuthService? = nil,
        realtimeChannel: RealtimePinSubscribing? = nil
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.nowProvider = nowProvider
        self.urlSession = urlSession
        self.authService = authService
        self.realtimeChannel = realtimeChannel
            ?? SupabasePinRealtimeChannel(supabaseURL: supabaseURL, supabaseAnonKey: supabaseAnonKey)
    }

    /// Convenience initializer that reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from
    /// `Bundle.main` (bridged from `Config.xcconfig` via `Info.plist`).
    ///
    /// Used by `WeParkApp` as its factory method for the shared service instance.
    /// The `authService` parameter is required for the Tier 3 write path — pass the
    /// same `SupabaseAuthService` instance that was created in `WeParkApp.swift`.
    ///
    /// If either key is missing (pre-prod-apply builds, missing Config.xcconfig),
    /// the service starts with placeholder values — no network calls are made, and
    /// the fixture injection path is available for testing/smoke.
    ///
    /// Note: This convenience init no longer creates a default SupabaseAuthService
    /// internally (AC-A5: single SupabaseClient/auth instance per app lifetime).
    /// The authService is injected to ensure the same session is shared across all callers.
    ///
    /// - Parameter realtimeChannel: See the designated init's doc comment. `ContentView`
    ///   passes `SupabaseClients.makeRealtimePinChannel()` explicitly rather than relying on
    ///   this convenience init's `nil` default, so the app's one shared `RealtimeClientV2` is
    ///   reused (spec §3.4) instead of a second, standalone socket being opened.
    convenience init(authService: SupabaseAuthService? = nil, realtimeChannel: RealtimePinSubscribing? = nil) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(
            supabaseURL: resolvedURL,
            supabaseAnonKey: key,
            authService: authService,
            realtimeChannel: realtimeChannel
        )
    }

    // MARK: - Region change entry point

    /// Called from `ContentView.onRegionChanged` callback.
    ///
    /// Cancels the previous debounce task and starts a new 800ms window.
    /// On the Drive Mode active path, skips re-fetch when the map center hasn't
    /// moved more than 200m from the last fetch center (spec §6.3).
    ///
    /// - Parameter region: The new map region after a pan or zoom.
    func onRegionChanged(_ region: MKCoordinateRegion) {
        // Drive Mode guard: skip if center hasn't moved far enough (spec §6.3).
        if driveModeActive, let lastCenter = lastFetchCenter {
            let lastCL = CLLocation(latitude: lastCenter.latitude, longitude: lastCenter.longitude)
            let newCL = CLLocation(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            )
            if lastCL.distance(from: newCL) < 200 {
                return
            }
        }

        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self.fetchPins(for: region)
        }

        // Start the periodic refresh on the first region change if it's not already running
        // (Drive Mode is not active). Subsequent region changes don't re-stack the timer.
        if periodicRefreshTask == nil && !driveModeActive {
            startPeriodicRefresh()
        }
    }

    /// Informs the service whether Drive Mode is currently active.
    /// Affects the re-fetch guard in `onRegionChanged` (spec §6.3).
    /// Also suspends/resumes the periodic refresh: active Drive Mode cancels the timer
    /// to avoid hammering Supabase during navigation; exiting Drive Mode restarts it so
    /// the resting map stays fresh for community pins.
    func setDriveModeActive(_ active: Bool) {
        driveModeActive = active
        if active {
            // Suspend periodic refresh during Drive Mode (Fix 2).
            stopPeriodicRefresh()
        } else {
            // Reset last-fetch-center so the first non-Drive region change fetches fresh.
            lastFetchCenter = nil
            // Resume periodic refresh if a region has been fetched (Fix 2).
            startPeriodicRefresh()
        }
    }

    // MARK: - Zone selection (Community 2.0 Phase 1)

    /// Sets the zone currently selected by the crew feed's zone chips. `nil` clears the filter
    /// (every pin passes the zone dimension unconditionally — see `selectedZoneId`'s doc
    /// comment). Purely a gating-state setter: does not itself trigger a fetch or touch
    /// `visiblePins` — S4's zone-chip UI is expected to pair this with its own REST re-fetch
    /// scoped to the new zone (mirroring how `onRegionChanged` already drives the bounding-box
    /// fetch), since this service's channels are viewport-scoped, not zone-scoped, on the read
    /// path (spec §1 delta table: zone filtering is a Realtime-side, client-side dimension, not
    /// a second fetch axis this session adds).
    func setSelectedZone(_ zoneId: String?) {
        selectedZoneId = zoneId
    }

    // MARK: - Periodic refresh (Fix 2 — TF1 Realtime stand-in)

    /// Starts the periodic refresh loop.
    ///
    /// Safe to call multiple times — a running task is cancelled before creating a new one
    /// to ensure at most one timer loop is active at any time (no stacking).
    ///
    /// No-op if driveModeActive is true (the caller is responsible for not calling this
    /// while driving, but the guard here is a safety net).
    ///
    /// The loop re-fetches `lastFetchedRegion` every `pinRefreshIntervalSeconds`. It uses
    /// `lastFetchedRegion` (captured at execution time, not at Task-creation time) so a
    /// region change that arrives before the tick fires uses the new viewport automatically.
    func startPeriodicRefresh() {
        // Don't stack multiple timers.
        stopPeriodicRefresh()
        // Don't start during Drive Mode.
        guard !driveModeActive else { return }
        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pinRefreshIntervalSeconds))
                guard !Task.isCancelled, let self else { break }
                // Re-fetch the current region (captured at tick time, not at Task creation).
                if let region = self.lastFetchedRegion {
                    await self.fetchPins(for: region)
                }
            }
        }
    }

    /// Cancels the periodic refresh task.
    ///
    /// Called when Drive Mode activates (to avoid hammering Supabase during navigation)
    /// and when the service's active map is removed.
    func stopPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
    }

    // MARK: - Realtime subscription (supabase-swift Stream B)

    /// The chain "tail" — the most recently enqueued Realtime lifecycle operation, whether it
    /// was created by `startRealtime()` or `disconnectRealtime()`. Every new lifecycle call
    /// captures this BEFORE creating its own `Task`, and that new `Task`'s body `await`s the
    /// captured predecessor's `.value` as its very first line, before doing any real work. That
    /// is what actually serializes connect/disconnect/reconnect against each other (QA finding
    /// #1, PR #84 pass 1 — see `docs/qa/realtime-stream-b-pr84.md`).
    ///
    /// Why not just `Task.cancel()` (the pre-fix approach)? `Task.cancel()` is cooperative, and
    /// neither `RealtimePinSubscribing.connect(...)` nor `.disconnect()` check
    /// `Task.isCancelled` anywhere in their implementations — so cancelling the *wrapper* Task
    /// does not interrupt the in-flight `await realtimeChannel.connect(...)` /
    /// `await realtimeChannel.disconnect()` call inside it. The cancelled Task's underlying
    /// network call kept running in the background and could complete AFTER a newly-started
    /// operation, racing it. On a fast `.active → .background → .active` scenePhase flap (a
    /// real app-switch, Siri, or an incoming-call banner), that let the losing `disconnect()`'s
    /// `unsubscribe()`/`realtimeClient.disconnect()` land *after* the new `connect()`'s
    /// `subscribeWithError()` — and `connect()`'s own idempotency guard
    /// (`ch.status != .subscribed`, `RealtimePinChannel.swift`) could read a stale `.subscribed`
    /// status left over from before the race and skip re-subscribing entirely, while the
    /// trailing disconnect tore the socket down moments later. End state: this service believed
    /// Realtime was live while the socket was actually dead, with no self-detection until a
    /// full clean background/foreground cycle — silently defeating the whole point of this
    /// feature during Drive Mode, when the fallback poll is also suspended.
    ///
    /// Chaining instead of cancelling is also the semantically correct behavior, not just the
    /// safe one: every requested operation still runs, in the order it was requested, so a
    /// disconnect queued right after a connect still disconnects the freshly-connected socket
    /// rather than being silently dropped.
    private var realtimeLifecycleTask: Task<Void, Never>?

    /// The `Task` created by the most recent `startRealtime()` call. `internal` (not
    /// `private`) so tests can `await service.realtimeConnectTask?.value` to deterministically
    /// wait for the ENTIRE chain up to and including this connect — because this Task's body
    /// awaits `realtimeLifecycleTask`'s prior value first, awaiting `.value` here also waits
    /// for any predecessor `disconnectRealtime()` to have fully finished. Mirrors
    /// `periodicRefreshTask`'s own "narrowest access widening for test assertions" precedent
    /// above.
    var realtimeConnectTask: Task<Void, Never>? = nil

    /// The `Task` created by the most recent `disconnectRealtime()` call. Same `internal`-for-
    /// tests rationale and same "awaiting `.value` waits for the whole chain up to this point"
    /// property as `realtimeConnectTask`.
    var realtimeDisconnectTask: Task<Void, Never>? = nil

    /// Establishes the real Supabase Realtime WebSocket subscription on `public.pins`.
    ///
    /// Design (spec §5.1): ONE table-wide subscription, `event: *` (insert/update/delete) —
    /// NOT the two-channel `source=eq.open_data` / `lifespan=eq.ephemeral` split an earlier
    /// version of this comment sketched. `postgres_changes` filters can only express
    /// single-column comparisons — they cannot reproduce the REST channels' compound
    /// predicates (`resolved_at IS NULL AND (expires_at IS NULL OR expires_at > now())`), so
    /// that two-channel design would have silently pushed resolved/expired rows straight into
    /// `visiblePins`. All filtering (pin-type eligibility, viewport, expiry, resolved-at)
    /// happens client-side instead, via `RealtimeMergeGate` in front of the existing,
    /// unmodified `mergeRealtimeChange(pin:)` and the new `removePin(id:)`.
    ///
    /// Called once at launch (`ContentView.performLaunchSetup`) and again by
    /// `reconnectRealtime()` on every foreground transition. Safe to call redundantly —
    /// `RealtimePinSubscribing.connect` is documented as idempotent. Serialized against any
    /// in-flight `disconnectRealtime()` via `realtimeLifecycleTask` (see its doc comment) —
    /// this Task does not start its own `connect()` work until any prior lifecycle operation
    /// has fully completed.
    func startRealtime() {
        let predecessor = realtimeLifecycleTask
        let task = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.realtimeChannel.connect(
                onUpsert: { [weak self] pin in
                    self?.handleRealtimeUpsert(pin)
                },
                onDelete: { [weak self] id in
                    self?.removePin(id: id)
                }
            )
        }
        realtimeLifecycleTask = task
        realtimeConnectTask = task
    }

    /// Tears down the Realtime WebSocket. Wired to `ContentView`'s new `.onChange(of:
    /// scenePhase)` `.background` branch (spec §5.3) — iOS suspends/kills background socket
    /// activity for an app with no background-execution entitlement anyway; disconnecting
    /// explicitly avoids the socket dying in an ambiguous half-open state. Serialized against
    /// any in-flight `startRealtime()` via `realtimeLifecycleTask` (see its doc comment).
    func disconnectRealtime() {
        let predecessor = realtimeLifecycleTask
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.realtimeChannel.disconnect()
        }
        realtimeLifecycleTask = task
        realtimeDisconnectTask = task
    }

    /// Re-establishes the Realtime WebSocket. Wired to `ContentView`'s existing `.active`
    /// scenePhase branch (spec §5.3), alongside a one-shot `refetchCurrentRegion()` catch-up
    /// fetch for whatever changed on `public.pins` while backgrounded (belt-and-suspenders).
    /// Goes through `startRealtime()`, so it inherits the same serialization against any
    /// still-in-flight `disconnectRealtime()` from a fast scenePhase flap.
    func reconnectRealtime() {
        startRealtime()
    }

    /// Gates an incoming Realtime upsert (INSERT or UPDATE) event through
    /// `RealtimeMergeGate` before it reaches the existing, unmodified
    /// `mergeRealtimeChange(pin:)` (spec §8.2 gap #1 — Realtime has no server-side
    /// bounding-box filter, so every change to `public.pins` city-wide reaches every
    /// subscribed client; this is the client-side stand-in).
    ///
    /// A `nil` `lastFetchedRegion` (no region fetched yet — e.g. Realtime connects before the
    /// first `onRegionChanged` debounce fires) is treated as "not within region": there is
    /// nothing on-screen yet to update, and admitting pins before any viewport is known would
    /// defeat the gate's purpose. The next `onRegionChanged` → `fetchPins` cycle populates
    /// `visiblePins` from REST as usual once a region is known.
    private func handleRealtimeUpsert(_ pin: CommunityPin) {
        guard RealtimeMergeGate.mergeablePinTypes.contains(pin.pinType) else { return }
        guard let region = lastFetchedRegion,
              RealtimeMergeGate.isWithinRegion(lat: pin.lat, lng: pin.lng, region: region) else { return }
        // Community 2.0 Phase 1: third gating dimension. `selectedZoneId == nil` (the default,
        // pre-S4 state) always passes — see `RealtimeMergeGate.isInZone`'s doc comment.
        guard RealtimeMergeGate.isInZone(pinZoneId: pin.zoneId, selectedZoneId: selectedZoneId) else { return }
        mergeRealtimeChange(pin: pin)
    }

    /// Removes a pin by ID — the DELETE-event counterpart to `mergeRealtimeChange(pin:)`
    /// (spec §8.2 gap #2). A Postgres Realtime DELETE payload, without `REPLICA IDENTITY FULL`
    /// (deliberately not set — spec §2 Out), only reliably carries the deleted row's primary
    /// key, so this cannot reuse `mergeRealtimeChange`'s `CommunityPin`-typed signature. No-op
    /// if `id` is not currently present in `visiblePins` (e.g. it was never in the fetched
    /// viewport, or Kevin's manual SQL cleanup deleted a row no client had loaded).
    ///
    /// If `id` has an in-flight optimistic-delete entry (`pendingOptimisticDeletes` —
    /// `deleteCrowdPin`'s request for the same id hasn't resolved yet), this is the signal
    /// that the server genuinely deleted the row independent of how that request ends up
    /// resolving. Marking the entry `true` here tells `deleteCrowdPin`'s failure path not to
    /// resurrect the pin even if its own HTTP response comes back as an error (e.g. the
    /// delete succeeded server-side but the response itself was lost) — see
    /// `rollbackOptimisticDelete`'s doc comment for the full reasoning.
    func removePin(id: UUID) {
        if pendingOptimisticDeletes[id] != nil {
            pendingOptimisticDeletes[id] = true
        }
        visiblePins.removeAll { $0.id == id }
    }

    /// One-shot re-fetch of the last-known viewport, bypassing the 800ms debounce. Used by
    /// `ContentView`'s `.active` scenePhase branch as a belt-and-suspenders catch-up for
    /// whatever changed on `public.pins` while the Realtime socket was disconnected
    /// (backgrounded) — spec §5.3, §5.4. No-op if no region has been fetched yet.
    func refetchCurrentRegion() async {
        guard let region = lastFetchedRegion else { return }
        await fetchPins(for: region)
    }

    // MARK: - Fixture injection (TF1 build + test gate)

    /// Directly sets `visiblePins` with the provided fixture pins, bypassing the network.
    ///
    /// Used by:
    ///   - `CommunityPinServiceTests` — fixture-based unit tests (AC-D1 through AC-D8).
    ///   - `ContentView` — sim smoke gate to inject visible markers without a live DB.
    ///
    /// The client-side filter is NOT applied here; caller provides pre-filtered fixtures
    /// if they need expiry semantics tested. Use `clientSideFilter(_:)` directly in tests.
    func inject(fixtures: [CommunityPin]) {
        visiblePins = fixtures
    }

    // MARK: - Client-side expiry filter (AC-D1 through AC-D4)

    /// Filters out expired and resolved pins.
    ///
    /// Rules (spec §9):
    ///   - Remove if `expiresAt != nil && expiresAt <= nowProvider()`. (AC-D1 / AC-D3)
    ///   - Retain if `expiresAt == nil` (durable pins have no expiry). (AC-D2)
    ///   - Remove if `resolvedAt != nil`. (AC-D4)
    ///
    /// - Parameter pins: Raw decoded pins from the server response.
    /// - Returns: Pins that are still active and not expired.
    func clientSideFilter(_ pins: [CommunityPin]) -> [CommunityPin] {
        let now = nowProvider()
        return pins.filter { pin in
            // Remove resolved pins (AC-D4).
            guard pin.resolvedAt == nil else { return false }
            // Remove expired pins (AC-D1). Retain nil-expiry pins (AC-D2 / AC-D3).
            if let expiresAt = pin.expiresAt {
                return expiresAt > now
            }
            return true
        }
    }

    // MARK: - FT-15 / TF2-15: block-scoped restriction lookup (§9.2)

    /// Returns the active-or-upcoming block-scoped restriction pin (`filming` or
    /// `construction`, `report_group_id != nil`) whose `segmentId` matches the given
    /// blockface key, if any.
    ///
    /// Used by `BlockDetailView` / `ParkedCarDetailView` to decide whether to show the
    /// "Temporary restriction reported" banner (§9.2) for the segment currently being
    /// viewed. `key` is expected to be a `Segment.blockfaceKey` value — matching is
    /// string-equality only, by construction (§4.3): both the write path and this read
    /// path derive the key from the identical computed property, so there is no
    /// normalization or fuzzy matching here.
    ///
    /// If multiple block-scoped pins somehow match the same key (shouldn't happen under
    /// normal use — one report per blockface — but not enforced server-side), the first
    /// match in `visiblePins` wins; callers needing every match should filter
    /// `visiblePins` directly instead.
    func blockScopedRestriction(forBlockfaceKey key: String) -> CommunityPin? {
        visiblePins.first { pin in
            pin.reportGroupId != nil &&
            (pin.pinType == .filming || pin.pinType == .construction) &&
            pin.segmentId == key
        }
    }

    // MARK: - Network fetch

    /// Issues three PostgREST bounding-box queries in parallel and merges the results:
    ///   - Channel 1 (open_data): filming / asp_suspended_today / special_event pins.
    ///   - Channel 2 (crowd ephemeral): enforcement_active / sweeper_passed pins,
    ///     source=crowd, lifespan=ephemeral, resolved_at is null, not expired.
    ///   - Channel 3 (crowd block-scoped, FT-15/TF2-15): filming / construction pins,
    ///     source=crowd, resolved_at is null, not expired. §3.4.
    ///
    /// Per-channel failure isolation (docs/qa/ft15-b4-fetch-channel-qa.md Finding #1):
    /// each channel's request/decode is attempted independently via `fetchChannelOutcome`.
    /// A single channel's non-2xx status, network error, or decode failure does NOT abort
    /// the other two channels — their fresh results still reach `visiblePins` this cycle.
    /// This matters concretely today: Channel 3's `select` list depends on columns
    /// (`starts_at`, `report_group_id`) that don't exist in production until Stream A's
    /// migration is applied. Until then, Channel 3 will 400 on every cycle — without this
    /// isolation, that single failure would have taken the entire community-pin layer
    /// stale app-wide (existing filming/ASP/enforcement/sweeper markers included), not
    /// just the new block-scoped feature.
    ///
    /// A failed channel's contribution to `visiblePins` this cycle falls back to whatever
    /// that channel last successfully contributed (re-run through `clientSideFilter` so
    /// anything that has since expired is still dropped — see `resolveChannelPins`).
    /// This is a deliberately simple "fail soft, don't invent staleness tracking" choice:
    /// it can never make a curb LOOK more restricted than the last known-good fetch said,
    /// and it can't silently blank markers just because an unrelated channel is down.
    ///
    /// On success (any channel): replaces `visiblePins` with the merged, filtered result.
    /// On failure (any channel): sets `fetchError`; retained/refreshed pins from the other
    /// channels are still applied to `visiblePins` (stale-but-present, never blanked).
    private func fetchPins(for region: MKCoordinateRegion) async {
        let bbox = BoundingBox(from: region)
        guard let openDataRequest = buildOpenDataRequest(bbox: bbox),
              let crowdRequest = buildCrowdEphemeralRequest(bbox: bbox),
              let blockScopedRequest = buildCrowdBlockScopedRequest(bbox: bbox) else {
            return
        }

        isLoading = true
        fetchError = nil
        lastFetchCenter = region.center
        // Store the last fetched region so the periodic refresh (Fix 2) can re-fetch it.
        lastFetchedRegion = region

        // Issue all three requests concurrently — independent channels, no ordering
        // dependency. Each one reports its own success/failure rather than throwing out
        // of the shared `do` block, so one channel's problem can't discard the others'
        // in-flight results.
        async let channel1Outcome = fetchChannelOutcome(request: openDataRequest, label: "open_data")
        async let channel2Outcome = fetchChannelOutcome(request: crowdRequest, label: "crowd_ephemeral")
        async let channel3Outcome = fetchChannelOutcome(request: blockScopedRequest, label: "crowd_block_scoped")

        let outcome1 = await channel1Outcome
        let outcome2 = await channel2Outcome
        let outcome3 = await channel3Outcome

        // If a newer onRegionChanged call cancelled this fetchTask while requests were
        // in flight, treat the whole cycle as a no-op: a fresh fetchPins() for the new
        // region is already queued. This preserves the pre-existing cancellation
        // behavior (previously the single `catch is CancellationError` case) — routine
        // debounce supersession should never be logged as a channel failure or partially
        // merged into visiblePins.
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        // Merge all three channels: open_data first (deterministic ordering), then
        // crowd-ephemeral, then crowd-block-scoped. clientSideFilter deduplicates by
        // filter logic (not by ID); channel 1/2 use distinct pin_type ranges with no
        // overlap. Channel 3 shares `filming` with channel 1, but the two are mutually
        // exclusive on `source` (open_data vs. crowd) — see §3.4's `segment_id`
        // semantics note for why a crowd filming row can never collide with an
        // open-data filming row.
        let channel1Pins = resolveChannelPins(outcome: outcome1, label: "open_data", memberOf: Self.isChannel1Member)
        let channel2Pins = resolveChannelPins(outcome: outcome2, label: "crowd_ephemeral", memberOf: Self.isChannel2Member)
        let channel3Pins = resolveChannelPins(outcome: outcome3, label: "crowd_block_scoped", memberOf: Self.isChannel3Member)

        visiblePins = clientSideFilter(channel1Pins + channel2Pins + channel3Pins)

        isLoading = false
    }

    /// The outcome of a single channel's fetch + decode attempt.
    private enum ChannelFetchOutcome {
        case success([CommunityPin])
        case failure(Error)
    }

    /// Runs one channel's request end-to-end (network + HTTP status check + decode),
    /// reporting its own outcome instead of throwing into a shared `do` block. This is
    /// the isolation primitive `fetchPins` composes over `async let` — see that method's
    /// doc comment for why isolation matters here.
    private func fetchChannelOutcome(request: URLRequest, label: String) async -> ChannelFetchOutcome {
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                throw CommunityPinFetchError.httpError(statusCode: httpResponse.statusCode)
            }
            let pins = try decodeResponse(data: data)
            return .success(pins)
        } catch {
            return .failure(error)
        }
    }

    /// Resolves one channel's contribution to this fetch cycle's merge.
    ///
    /// - On success: resets the channel's failure streak and returns the fresh pins.
    /// - On failure: logs (throttled — see `logChannelFailure`), sets `fetchError`, and
    ///   falls back to whichever pins of this channel's type are already in `visiblePins`
    ///   from the last successful fetch — NOT an empty array. This is what stops one
    ///   channel's outage from blanking the *other* channels' markers (Finding #1): the
    ///   caller merges `channel1Pins + channel2Pins + channel3Pins`, and only the failed
    ///   channel's slice degrades to "last known good" instead of "nothing." The retained
    ///   slice still passes back through `clientSideFilter` at the call site, so a pin
    ///   that expires while its channel is down is still correctly removed — this does
    ///   not freeze stale data forever, it just avoids blanking it prematurely.
    private func resolveChannelPins(
        outcome: ChannelFetchOutcome,
        label: String,
        memberOf predicate: (CommunityPin) -> Bool
    ) -> [CommunityPin] {
        switch outcome {
        case .success(let pins):
            channelFailureStreak[label] = 0
            return pins
        case .failure(let error):
            logChannelFailure(label: label, error: error)
            fetchError = error
            return visiblePins.filter(predicate)
        }
    }

    /// Logs a channel failure, throttled to avoid spamming the console once per
    /// `pinRefreshIntervalSeconds` tick during a sustained outage (e.g. Channel 3 hitting
    /// production 400s every cycle before Stream A's migration lands). Logs the first
    /// failure immediately, then only every 10th consecutive failure after that
    /// (~80s at the periodic-refresh cadence).
    private func logChannelFailure(label: String, error: Error) {
        let streak = (channelFailureStreak[label] ?? 0) + 1
        channelFailureStreak[label] = streak
        guard streak == 1 || streak.isMultiple(of: 10) else { return }
        print("[CommunityPinService] channel '\(label)' fetch failed (consecutive: \(streak)): \(error)")
    }

    /// True if `pin` matches Channel 1's fetch predicate (open_data source; filming /
    /// asp_suspended_today / special_event). Used only to select which slice of the
    /// currently-visible pins to retain when Channel 1's fetch fails — see
    /// `resolveChannelPins`. Mirrors `buildOpenDataRequest`'s filter.
    ///
    /// `nonisolated` (matching `ephemeralTTLSeconds(for:)`'s existing precedent below):
    /// this is passed around as a plain `(CommunityPin) -> Bool` closure value, and it
    /// touches no actor-isolated state (only its `CommunityPin` parameter), so it should
    /// not carry `@MainActor` isolation onto that closure type.
    private nonisolated static func isChannel1Member(_ pin: CommunityPin) -> Bool {
        pin.source == .openData &&
        [PinType.filming, .aspSuspendedToday, .specialEvent].contains(pin.pinType)
    }

    /// True if `pin` matches Channel 2's fetch predicate (crowd source, ephemeral lifespan;
    /// enforcement_active / sweeper_passed, plus open_spot / leaving_soon when
    /// `AppConstants.communityEnabled` — both `lifespan='ephemeral'`, same bucket as
    /// enforcement/sweeper, spec §2.8). Mirrors `buildCrowdEphemeralRequest`'s pin_type list.
    ///
    /// S4 QA pass 1, PR #94 Finding #1 (BLOCKING): the two Community 2.0 types used to be
    /// unconditional here — gated now via `AppConstants.communityPhase1PinTypes(enabled:)`,
    /// the single source of truth also used by `RealtimeMergeGate.mergeablePinTypes` and
    /// `ContentView.handleVisiblePinsChange`'s `mapMarkerTypes`.
    private nonisolated static func isChannel2Member(_ pin: CommunityPin) -> Bool {
        let eligibleTypes = Set([PinType.enforcementActive, .sweeperPassed])
            .union(AppConstants.communityPhase1PinTypes())
        return pin.source == .crowd &&
            pin.lifespan == .ephemeral &&
            eligibleTypes.contains(pin.pinType)
    }

    /// True if `pin` matches Channel 3's fetch predicate (crowd source; filming /
    /// construction, any lifespan). Mirrors `buildCrowdBlockScopedRequest`.
    private nonisolated static func isChannel3Member(_ pin: CommunityPin) -> Bool {
        pin.source == .crowd &&
        [PinType.filming, .construction].contains(pin.pinType)
    }

    // MARK: - Request builders

    /// Builds the PostgREST URLRequest for Channel 1: open-data pins.
    ///
    /// Fetches: filming, asp_suspended_today, special_event
    ///   source = eq.open_data
    ///   resolved_at = is.null
    ///   expires_at is null OR > now
    private func buildOpenDataRequest(bbox: BoundingBox) -> URLRequest? {
        let nowISO = iso8601Now()

        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/pins_with_author"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "pin_type",    value: "in.(filming,asp_suspended_today,special_event)"),
            URLQueryItem(name: "source",      value: "eq.open_data"),
            URLQueryItem(name: "resolved_at", value: "is.null"),
            URLQueryItem(name: "or",          value: "(expires_at.is.null,expires_at.gt.\(nowISO))"),
            URLQueryItem(name: "lat",         value: "gte.\(bbox.swLat)"),
            URLQueryItem(name: "lat",         value: "lte.\(bbox.neLat)"),
            URLQueryItem(name: "lng",         value: "gte.\(bbox.swLng)"),
            URLQueryItem(name: "lng",         value: "lte.\(bbox.neLng)"),
            URLQueryItem(
                name: "select",
                value: "id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,expires_at,confirm_count,dispute_count,meta,notes,author_username,created_at,updated_at,resolved_at,author_id"
            ),
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Supabase PostgREST requires the anon key as the `apikey` header (AC-D21).
        // No `Authorization: Bearer <user-jwt>` header — anonymous read, per RLS policy
        // `pins_select_public` in supabase/02-pins-schema.sql §6.
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }

    /// Community 2.0 Phase 1 (S4 QA pass 1, PR #94 Finding #1 — BLOCKING): the PostgREST
    /// `pin_type=in.(...)` value for Channel 2's fetch, gated on `communityEnabled` via
    /// `AppConstants.communityPhase1PinTypes(enabled:)` — the single source of truth also
    /// used by `RealtimeMergeGate.mergeablePinTypes` and
    /// `ContentView.handleVisiblePinsChange`'s `mapMarkerTypes`. `open_spot`/`leaving_soon`
    /// are appended to the query ONLY when the flag is on, so a flag-off client never even
    /// REQUESTS (let alone receives, merges, or renders) either type — Phase 0's migration
    /// is already live in production, so this is closing a real, present-day gap, not a
    /// hypothetical one.
    ///
    /// `nonisolated static` and pure (no instance state) so tests can assert both flag
    /// states directly without a live `CommunityPinService` or network mock.
    nonisolated static func channel2PinTypeQueryValue(communityEnabled: Bool) -> String {
        let types: [PinType] = [.enforcementActive, .sweeperPassed]
            + AppConstants.communityPhase1PinTypes(enabled: communityEnabled)
        return "in.(\(types.map(\.rawValue).joined(separator: ",")))"
    }

    /// Builds the PostgREST URLRequest for Channel 2: crowd ephemeral pins.
    ///
    /// Fetches: enforcement_active, sweeper_passed always; open_spot, leaving_soon only
    ///   when `AppConstants.communityEnabled` (Community 2.0 Phase 1, spec §2.8/§3 Phase 1 —
    ///   see `channel2PinTypeQueryValue(communityEnabled:)` above) — same `lifespan='ephemeral'`
    ///   bucket as enforcement/sweeper, so this channel's existing filter shape already covers
    ///   them without a fourth channel, once the flag is on.
    ///   source = eq.crowd
    ///   lifespan = eq.ephemeral
    ///   resolved_at = is.null       — 3-dispute-resolved pins are excluded (spec §3.9)
    ///   expires_at is null OR > now — expired pins excluded server-side as well as client-side
    ///
    /// Bug #1 fix: this channel was documented in the service header comment but never
    /// implemented in the request layer — crowd pins were fetched with zero results because
    /// the open-data request's source=eq.open_data filter excluded them entirely.
    private func buildCrowdEphemeralRequest(bbox: BoundingBox) -> URLRequest? {
        let nowISO = iso8601Now()

        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/pins_with_author"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(
                name: "pin_type",
                value: Self.channel2PinTypeQueryValue(communityEnabled: AppConstants.communityEnabled)
            ),
            URLQueryItem(name: "source",      value: "eq.crowd"),
            URLQueryItem(name: "lifespan",    value: "eq.ephemeral"),
            URLQueryItem(name: "resolved_at", value: "is.null"),
            URLQueryItem(name: "or",          value: "(expires_at.is.null,expires_at.gt.\(nowISO))"),
            URLQueryItem(name: "lat",         value: "gte.\(bbox.swLat)"),
            URLQueryItem(name: "lat",         value: "lte.\(bbox.neLat)"),
            URLQueryItem(name: "lng",         value: "gte.\(bbox.swLng)"),
            URLQueryItem(name: "lng",         value: "lte.\(bbox.neLng)"),
            URLQueryItem(
                // Community 2.0 Phase 1: appends position_fraction/leaving_minutes/claimed_by
                // (spec §2.2's three new pins_with_author columns) — without these, open_spot/
                // leaving_soon rows would fetch successfully but silently decode those three
                // fields as nil (CommunityPin's decodeIfPresent is safe either way), defeating
                // the purpose of adding them. Every existing column stays in its original order.
                name: "select",
                value: "id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,expires_at,confirm_count,dispute_count,meta,notes,author_username,created_at,updated_at,resolved_at,author_id,position_fraction,leaving_minutes,claimed_by"
            ),
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }

    /// Builds the PostgREST URLRequest for Channel 3: crowd block-scoped restriction pins.
    ///
    /// Fetches: filming, construction (crowd-authored, block-scoped reports — §9.3: the
    /// same primitive serves both FT-15's film-shoot case and TF2-15's construction case)
    ///   source = eq.crowd
    ///   pin_type in (filming, construction)
    ///   resolved_at = is.null
    ///   expires_at is null OR > now
    ///
    /// Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.4, §12 AC-C1/AC-C2.
    ///
    /// Concrete gap this closes (§3.4): `buildOpenDataRequest` hardcodes `source=eq.open_data`;
    /// `buildCrowdEphemeralRequest` hardcodes `lifespan=eq.ephemeral`. Neither channel would
    /// ever return a `source=crowd, lifespan=session` (or `durable`) row. Without this
    /// channel, FT-15/TF2-15 block-scoped reports are written to `pins` (Stream B3's write
    /// path) but never fetched by any client — the feature would be invisible end to end.
    ///
    /// Deliberately does NOT filter on `lifespan` — a block-scoped report is `session` or
    /// `durable` depending on how the write path sets it; this channel's identity is
    /// `source=crowd, pin_type in (filming, construction)`, not a lifespan value.
    ///
    /// Deliberately does NOT filter on `starts_at` (AC-C2): a report whose window hasn't
    /// started yet must still be fetched so the consumption UI can show an "Upcoming" badge
    /// (`CommunityPin.isUpcoming(now:)`) rather than silently hiding it until it goes live.
    /// Only `expires_at` gates visibility here, matching every other channel's convention —
    /// `clientSideFilter` needs no change for this (it already only checks `expiresAt`/
    /// `resolvedAt`, never `startsAt`).
    private func buildCrowdBlockScopedRequest(bbox: BoundingBox) -> URLRequest? {
        let nowISO = iso8601Now()

        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/pins_with_author"),
            resolvingAgainstBaseURL: false
        )

        components?.queryItems = [
            URLQueryItem(name: "pin_type",    value: "in.(filming,construction)"),
            URLQueryItem(name: "source",      value: "eq.crowd"),
            URLQueryItem(name: "resolved_at", value: "is.null"),
            URLQueryItem(name: "or",          value: "(expires_at.is.null,expires_at.gt.\(nowISO))"),
            URLQueryItem(name: "lat",         value: "gte.\(bbox.swLat)"),
            URLQueryItem(name: "lat",         value: "lte.\(bbox.neLat)"),
            URLQueryItem(name: "lng",         value: "gte.\(bbox.swLng)"),
            URLQueryItem(name: "lng",         value: "lte.\(bbox.neLng)"),
            URLQueryItem(
                name: "select",
                // Includes starts_at + report_group_id (absent from channels 1/2's select
                // lists — this is the first channel that needs them). Deliberately does NOT
                // select has_evidence_photo: that column does not exist on the live schema
                // yet (CommunityPin.swift's decode-only note) and requesting an unknown
                // column would make PostgREST reject the entire query with a 400.
                value: "id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,starts_at,expires_at,confirm_count,dispute_count,meta,notes,author_username,created_at,updated_at,resolved_at,author_id,report_group_id"
            ),
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }

    // MARK: - Response decoder

    /// A `JSONDecoder` configured for PostgREST's ISO 8601 timestamp format (with or without
    /// fractional seconds) — factored out of `decodeResponse` (Community 2.0 Phase 3, build 20
    /// S9) so every REST decode path in this file shares one date-parsing behavior rather than
    /// drifting between `decodeResponse` (pins) and newer read paths (`fetchOwnProfile`,
    /// `fetchLeaderboardPins` below). Pure/`nonisolated` — no instance state.
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
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Cannot decode date: \(string)"
                )
            )
        }
        return decoder
    }

    /// Decodes a PostgREST JSON array response into `[CommunityPin]`.
    ///
    /// Uses `CommunityPin.gracefulDecode` per element so a single malformed row
    /// does not crash the entire feed.
    private func decodeResponse(data: Data) throws -> [CommunityPin] {
        let decoder = Self.makeDateDecodingJSONDecoder()

        // PostgREST returns a JSON array.
        // Decode element-by-element using gracefulDecode to tolerate future unknown pin_types.
        struct PinArrayTrampoline: Decodable {
            let pins: [CommunityPin?]
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var result: [CommunityPin?] = []
                while !container.isAtEnd {
                    let pinDecoder = try container.superDecoder()
                    result.append(CommunityPin.gracefulDecode(from: pinDecoder))
                }
                pins = result
            }
        }

        let trampoline = try decoder.decode(PinArrayTrampoline.self, from: data)
        return trampoline.pins.compactMap { $0 }
    }

    // MARK: - Read path: Leaderboard (Community 2.0 Phase 3, build 20 S9)

    /// Builds the PostgREST URLRequest backing the Phase 3 leaderboard: crowd-authored pins
    /// within a zone's bounding box, confirmed by at least one neighbor (`confirm_count > 0`),
    /// created in the trailing 7 days — spec §3 Phase 3 ("a live query against existing
    /// columns, no new table").
    ///
    /// Deliberately does NOT reuse the debounced Channel 1-3 pipeline (`buildOpenDataRequest`/
    /// `buildCrowdEphemeralRequest`/`buildCrowdBlockScopedRequest`): every one of those filters
    /// out expired/resolved rows (`clientSideFilter` does the same again client-side), which
    /// would silently drop most of a trailing-7-day window's ephemeral pins — a
    /// `sweeper_passed` pin's 120-minute TTL is long gone by the time this query runs three
    /// days later, but its `confirm_count` should still count toward this week's leaderboard.
    /// This is a separate, one-shot fetch with no expiry/resolved-at filter at all.
    ///
    /// No `pin_type` filter — any crowd report type (enforcement, sweeper, open_spot, a
    /// crowd-authored closure) with at least one confirm counts, matching spec §3 Phase 3's
    /// literal "pins they authored with confirm_count > 0" wording (not narrowed to ephemeral
    /// types only).
    private func buildLeaderboardRequest(zoneId: String, sevenDaysAgoISO: String) -> URLRequest? {
        guard let box = CommunityZoneBounds.box(for: zoneId) else { return nil }

        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/pins_with_author"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "source",       value: "eq.crowd"),
            URLQueryItem(name: "confirm_count", value: "gt.0"),
            URLQueryItem(name: "created_at",   value: "gte.\(sevenDaysAgoISO)"),
            URLQueryItem(name: "lat",          value: "gte.\(box.latMin)"),
            URLQueryItem(name: "lat",          value: "lte.\(box.latMax)"),
            URLQueryItem(name: "lng",          value: "gte.\(box.lngMin)"),
            URLQueryItem(name: "lng",          value: "lte.\(box.lngMax)"),
            URLQueryItem(
                // Deliberately omits `expires_at`/`resolved_at` — the leaderboard doesn't
                // read either (no client-side expiry re-check; the trailing-7-day window +
                // `confirm_count > 0` predicates above are the only filters that matter here),
                // and dropping them keeps the request's own query string free of any
                // expiry-shaped substring, matching this method's "no expiry/resolved-at
                // filter at all" doc comment literally, not just in spirit. Every other field
                // `CommunityPin.init(from:)` requires non-optionally (id, pin_type, source,
                // lifespan, lat, lng, created_at, updated_at, confirm_count, dispute_count) is
                // still selected, so decoding never fails on a missing-required-key error.
                name: "select",
                value: "id,pin_type,source,lifespan,lat,lng,segment_id,zone_id,confirm_count,dispute_count,meta,notes,author_username,created_at,updated_at,author_id"
            ),
            // QA pass 1 fix (PR #97, Finding #2): bounds the worst-case payload for a busy
            // zone. Without a `limit`, the client would download EVERY matching row (bounded
            // only by time + confirm_count>0, not by count) and rank/truncate to top-5
            // on-device — fine for a quiet MVP zone, not fine once a zone genuinely gets busy
            // (the whole point of the feature). `order=confirm_count.desc` means the 200 rows
            // returned are the HIGHEST-confirm_count pins in the window, so the eventual
            // top-5-by-author-pin-count ranking (`CommunityLeaderboard.build`) is computed over
            // the most-relevant slice, not an arbitrary one. Accepted v1 semantic (noted in
            // `CommunityLeaderboard.build`'s doc comment): for a zone with >200 qualifying pins
            // in a week, an author with many LOWER-confirm-count pins could rank slightly lower
            // here than an unbounded full scan would show. 200 is generous relative to any
            // realistic MVP zone's weekly crowd-report volume; retune the same way as every
            // other tunable constant in this codebase if live use shows otherwise.
            URLQueryItem(name: "order", value: "confirm_count.desc"),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Fetches the raw pins backing the Phase 3 leaderboard — see `buildLeaderboardRequest`'s
    /// doc comment for why this bypasses the usual channel/expiry pipeline. Pure network +
    /// decode; grouping/ranking/the "You" row is `CommunityLeaderboard.build(...)`
    /// (`Views/CrewFeedSection.swift`), kept view-adjacent per this codebase's existing
    /// "pure decision logic lives near its one consumer" convention (mirrors `CrewFeedMerge`).
    ///
    /// Returns `[]` (rather than throwing) when `zoneId` doesn't match any known zone box —
    /// defensive; every real caller passes a `CommunityZone.id`, which always resolves.
    ///
    /// - Parameter zoneId: One of `CommunityZone`'s raw values ("nolita"/"soho"/"les").
    func fetchLeaderboardPins(zoneId: String) async throws -> [CommunityPin] {
        let sevenDaysAgo = nowProvider().addingTimeInterval(-7 * 24 * 60 * 60)
        guard let request = buildLeaderboardRequest(
            zoneId: zoneId,
            sevenDaysAgoISO: iso8601String(from: sevenDaysAgo)
        ) else {
            return []
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinFetchError.httpError(statusCode: status)
        }

        return try decodeResponse(data: data)
    }

    // MARK: - Realtime merge core (unchanged by supabase-swift Stream B — see spec §8.1)

    /// Merges a Realtime INSERT or UPDATE event into `visiblePins`.
    ///
    /// Called by `handleRealtimeUpsert(_:)` (real Realtime WebSocket path, gated through
    /// `RealtimeMergeGate` first — supabase-swift Stream B) or directly in tests. Also reused
    /// by the optimistic-add paths after a successful write (`insertCrowdPin`,
    /// `insertBlockScopedReport`). Exported as `internal` so tests can exercise the merge
    /// logic directly.
    ///
    /// On INSERT: append pin (if it passes client-side filter and is a mergeable type).
    /// On UPDATE: replace existing pin by ID; remove if resolved_at is now non-nil.
    ///
    /// Sub-PR #1: extended to handle Tier 3 ephemeral crowd pins (enforcement_active,
    /// sweeper_passed) in addition to the Tier 1 open-data types. Reactions (confirm_count,
    /// expires_at updates) from other users propagate via this path.
    func mergeRealtimeChange(pin: CommunityPin) {
        // Tier 1 open-data display types + Tier 3 ephemeral crowd pins + FT-15/TF2-15
        // crowd block-scoped pins. asp_suspended_today is handled via banner supplement,
        // not as a map marker (spec §3), but is still merged into visiblePins for the
        // banner supplement.
        //
        // Pulled out to `RealtimeMergeGate.mergeablePinTypes` (supabase-swift Stream B, spec
        // §8.3) — single source of truth shared with `handleRealtimeUpsert(_:)`'s own gate, so
        // a future pin type is a one-line addition in ONE place, not a re-derivation here too.
        guard RealtimeMergeGate.mergeablePinTypes.contains(pin.pinType) else { return }

        // If resolved: remove.
        if pin.resolvedAt != nil {
            visiblePins.removeAll { $0.id == pin.id }
            return
        }

        // Apply client-side expiry filter.
        let filtered = clientSideFilter([pin])
        guard let validPin = filtered.first else {
            // Expired — remove if present.
            visiblePins.removeAll { $0.id == pin.id }
            return
        }

        // Update existing or append new.
        if let idx = visiblePins.firstIndex(where: { $0.id == pin.id }) {
            visiblePins[idx] = validPin
        } else {
            visiblePins.append(validPin)
        }
    }

    // MARK: - Helpers

    /// Returns a bounding box where the aspect-ratio of the region is preserved.
    private struct BoundingBox {
        let swLat: Double
        let neLat: Double
        let swLng: Double
        let neLng: Double

        init(from region: MKCoordinateRegion) {
            let halfLat = region.span.latitudeDelta / 2.0
            let halfLng = region.span.longitudeDelta / 2.0
            swLat = region.center.latitude  - halfLat
            neLat = region.center.latitude  + halfLat
            swLng = region.center.longitude - halfLng
            neLng = region.center.longitude + halfLng
        }
    }

    /// Formats the current time as ISO 8601 for the PostgREST query filter.
    private func iso8601Now() -> String {
        iso8601String(from: nowProvider())
    }

    /// Formats any Date as ISO 8601 for use in PostgREST request payloads.
    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Lifetime (seconds from report time) for an ephemeral crowd pin type, or nil for
    /// non-expiring types.
    ///
    /// FT-1 originally shortened enforcement/sweeper to 5 minutes ("mobile, very fresh — a
    /// 30-min lifetime kept them on the map long after they'd moved on"). **Superseded by
    /// Community 2.0 OQ-2 (resolved 2026-08-26, `docs/community-2.0-reconciliation-spec.md`
    /// §0): the prototype's 45m/120m values govern instead.** Kevin's reasoning reframes the
    /// pin's semantics: it is not only "agent is here NOW" but "agent already came through —
    /// unlikely to swing back soon," so an aged pin is *useful history*, not stale noise. The
    /// staleness is the signal — every surface rendering these pins MUST show relative age
    /// ("reported X min ago") for that display rule to be honest; this method only owns the
    /// TTL number, not the age-display requirement, which lives on the rendering surfaces
    /// (Views — S4+). The confirm-to-extend (+15m, 2h cap via `extend_pin_expiry`) mechanic is
    /// unchanged by this reversal.
    ///
    /// `open_spot` (3m) and `leaving_soon` (stated minutes + 3m) are net-new — no prior
    /// conflict, spec §6 appendix values as-is. `leaving_soon`'s TTL depends on the specific
    /// pin's user-chosen countdown, so this method takes an optional `leavingMinutes`
    /// parameter (default `nil` — every existing call site is unaffected); falls back to the
    /// same `coalesce(..., 10)` default the server-side `derive_pin_expiry()` trigger uses
    /// (spec §2.11) if the value is unknown.
    ///
    /// Broken meters are NOT mobile — a meter stays broken for a while — so they keep the
    /// original 30-min lifetime, untouched by OQ-2.
    ///
    /// Note (Community 2.0 §2.11): the server derives the authoritative `expires_at` for
    /// `open_spot`/`leaving_soon` on INSERT via a `BEFORE INSERT` trigger — this client value is
    /// display/decay math (and `insertCrowdPin`'s best-effort client-computed request payload,
    /// which the trigger then overrides for those two types), not the source of truth for them.
    nonisolated static func ephemeralTTLSeconds(for type: PinType, leavingMinutes: Int? = nil) -> TimeInterval? {
        switch type {
        case .enforcementActive:
            return 45 * 60      // OQ-2 (2026-08-26): staleness is the signal
        case .sweeperPassed:
            return 120 * 60     // OQ-2 (2026-08-26): staleness is the signal
        case .brokenMeter:
            return 30 * 60      // stationary condition — unaffected by OQ-2
        case .openSpot:
            return 3 * 60       // net-new, spec §6 appendix
        case .leavingSoon:
            return TimeInterval((leavingMinutes ?? 10) + 3) * 60   // net-new, mirrors derive_pin_expiry()'s coalesce default
        default:
            return nil          // non-ephemeral types do not auto-expire
        }
    }

    // MARK: - Community 2.0 Phase 2a / build 20 S6 — write-time zone stamping

    /// Resolves the `zone_id` to write on a crowd pin insert.
    ///
    /// An explicit, caller-supplied `explicit` value always wins (a future caller that
    /// genuinely knows the zone — e.g. from the currently-selected crew-feed zone chip —
    /// isn't second-guessed). Only when `explicit` is `nil` (every call site as of this
    /// session, per `Views/ReportSheet.swift`'s `zoneId: nil`) does this fall back to a
    /// `CommunityZoneBounds` box-match against the pin's own `lat`/`lng` — the same
    /// bounding-box approximation OQ-1 already chose for the zones themselves, applied here
    /// at WRITE time instead of only at crew-feed DISPLAY time
    /// (`CrewFeedMerge.resolvedZoneId(for:)`). Returns `nil` (an honest, correctly-null
    /// `zone_id` column) when the coordinate falls outside all three known zone boxes —
    /// never a guessed/default zone.
    ///
    /// Pure, `nonisolated` — no network, no actor isolation, directly unit-testable.
    ///
    /// Note: this is a client-derived value, same trust level as every other client-supplied
    /// insert field today (§2.11 of the reconciliation spec already flags `expires_at` as
    /// entirely client-supplied pre-migration). True server-side stamping — e.g. a
    /// `BEFORE INSERT` trigger deriving `zone_id` from `lat`/`lng` the same way
    /// `derive_pin_expiry()` derives `expires_at` — remains an option for a future migration
    /// if write-time accuracy ever needs to be authoritative rather than best-effort; not
    /// pursued in this session per the roadmap's S6 scope (client-side box-match only).
    nonisolated static func resolveZoneId(explicit: String?, lat: Double, lng: Double) -> String? {
        explicit ?? CommunityZoneBounds.zoneId(forLat: lat, lng: lng)
    }

    // MARK: - Write path: Insert crowd pin (sub-PR #1)

    /// Inserts a new crowd-sourced ephemeral pin.
    ///
    /// Requires an active auth session (currentUserId != nil). The RLS policy
    /// `pins_insert_crowd` requires `auth.uid() = author_id AND source = 'crowd'`.
    ///
    /// Fix 1 — Optimistic add: uses `Prefer: return=representation` so PostgREST returns
    /// the full inserted row as JSON. The returned pin is decoded and fed through
    /// `mergeRealtimeChange(pin:)` so it appears on the map immediately — the reporter
    /// sees their pin without needing to pan the map.
    ///
    /// - Note: The UI that calls this (patrol mode report sheet) ships in sub-PR #2.
    ///   This method is built and tested in sub-PR #1 so the write primitive exists
    ///   before the UI layer is built.
    ///
    /// - Parameters:
    ///   - type: Pin type (e.g. `.enforcementActive`). Must be a crowd-reportable type.
    ///   - meta: Optional typed metadata for the pin.
    ///   - lat: Latitude of the pin location.
    ///   - lng: Longitude of the pin location.
    ///   - segmentId: Optional segment ID from the tile data.
    ///   - zoneId: Optional explicit zone ID (e.g. "soho-les"). When `nil`, `resolveZoneId(explicit:lat:lng:)`
    ///     derives one from `lat`/`lng` at write time (Community 2.0 Phase 2a / build 20 S6)
    ///     — see that function's doc comment.
    ///   - notes: Optional free-text notes.
    ///   - positionFraction: Community 2.0 Phase 2b (build 20 S7, spec §3 Phase 2): position
    ///     along the blockface, [0,1] from the segment's "from" endpoint to its "to"
    ///     endpoint (spec §2.2's `pins.position_fraction` column). Included in the payload
    ///     only when non-nil — every pre-existing call site (`nil` default) is unaffected.
    ///     Used by the `open_spot` placement flow (`SpotPlacementView`).
    ///   - leavingMinutes: Community 2.0 Phase 2b: the `leaving_soon` pin's user-chosen
    ///     countdown (5/10/15/20). Included in the payload only when non-nil. Also threaded
    ///     into `ephemeralTTLSeconds(for:leavingMinutes:)` below so the client-computed
    ///     `expires_at` reflects it (the server's `derive_pin_expiry()` trigger is the
    ///     authoritative source, per spec §2.11 — this is best-effort display/decay math,
    ///     same caveat as every other client-supplied `expires_at` value here). Net-new in
    ///     this session; no `leaving_soon` UI call site exists yet (that's Phase 4a, S10) —
    ///     added now because the reconciliation spec's Phase 2 section describes both new
    ///     parameters together as one unit of work, and adding both today avoids a second
    ///     future touch to this file's most-multi-phase-touched write path.
    func insertCrowdPin(
        type: PinType,
        meta: [String: Any]?,
        lat: Double,
        lng: Double,
        segmentId: String?,
        zoneId: String?,
        notes: String?,
        positionFraction: Double? = nil,
        leavingMinutes: Int? = nil
    ) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw CommunityPinWriteError.notAuthenticated
        }

        // expires_at for ephemeral types. Uses nowProvider() for testability (AC-I1).
        // TTL is resolved by the pure `ephemeralTTLSeconds(for:leavingMinutes:)` helper
        // (FT-1; `leavingMinutes` threaded through since Community 2.0 Phase 2b, S7).
        let expiresAt: String? = Self.ephemeralTTLSeconds(for: type, leavingMinutes: leavingMinutes).map {
            iso8601String(from: nowProvider().addingTimeInterval($0))
        }

        // Community 2.0 Phase 2a / build 20 S6 (PR #94 QA Finding #3 follow-up): every write
        // path today calls this with `zoneId: nil`, leaving `pins.zone_id` permanently null —
        // the crew feed only surfaces these pins via `CrewFeedMerge`'s DISPLAY-time
        // `CommunityZoneBounds` fallback, which is "a display-only patch, not a cure" per
        // `docs/community-2.0-roadmap.md` S6. `resolveZoneId` stamps the column at insert time
        // instead, so a future server-side/analytics query on `zone_id` isn't silently null.
        let resolvedZoneId = Self.resolveZoneId(explicit: zoneId, lat: lat, lng: lng)

        var payload: [String: Any] = [
            "pin_type":  type.rawValue,
            "source":    PinSource.crowd.rawValue,
            "lifespan":  PinLifespan.ephemeral.rawValue,
            "lat":       lat,
            "lng":       lng,
            "author_id": userId.uuidString,
        ]
        if let expiresAt     { payload["expires_at"] = expiresAt }
        if let segmentId     { payload["segment_id"] = segmentId }
        if let resolvedZoneId { payload["zone_id"] = resolvedZoneId }
        if let notes         { payload["notes"] = notes }
        if let meta          { payload["meta"] = meta }
        // Community 2.0 Phase 2b (build 20 S7): included only when non-nil — every
        // pre-existing call site leaves both nil and sees no payload change.
        if let positionFraction { payload["position_fraction"] = positionFraction }
        if let leavingMinutes   { payload["leaving_minutes"] = leavingMinutes }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CommunityPinWriteError.encodingFailure
        }

        // Fix 1: return=representation requests the full inserted row back from PostgREST.
        // The returned JSON array (PostgREST wraps single inserts in an array) is decoded
        // and the first element is fed through mergeRealtimeChange so the reporter sees
        // their pin immediately without waiting for a region-change re-fetch.
        let request = buildAuthenticatedRequest(
            path: "rest/v1/pins",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: [
                "Prefer": "return=representation",
                "Accept": "application/json",
            ]
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }

        // Fix 1: Decode the returned row and optimistically add it to visiblePins.
        // PostgREST returns a JSON array for INSERT; take the first element.
        // If decoding fails (e.g. schema mismatch), the write itself succeeded — don't throw.
        // The pin will appear on the next periodic refresh or region-change fetch instead.
        if let insertedPins = try? decodeResponse(data: data), let insertedPin = insertedPins.first {
            mergeRealtimeChange(pin: insertedPin)
        }
    }

    // MARK: - Write path: Vote (confirm / dispute)

    /// Upserts a vote on a crowd pin.
    ///
    /// Uses PostgREST upsert semantics: `Prefer: resolution=merge-duplicates` on the
    /// unique constraint (pin_id, user_id). Changing vote = upsert over the existing row.
    ///
    /// **PR #101 QA pass 1 fix (2026-09-03) — latent shipped bug closed in the same commit as
    /// the analogous `PushRegistrationService.upsertToken` fix:** this call was missing the
    /// `on_conflict` query parameter. `public.votes`' primary key is `id bigserial` (never sent
    /// in this method's payload); the real dedupe target is the SEPARATE `unique (pin_id,
    /// user_id)` constraint (`supabase/02-pins-schema.sql:164-172`). Per PostgREST's documented
    /// default — omitted `on_conflict` → `ON CONFLICT (<primary key>)` — every vote-CHANGE for
    /// an existing `(pin_id, user_id)` pair (e.g. tap "Still there?" then later "Gone" on the
    /// SAME pin) hit an uncaught `23505` unique-violation on the real constraint instead of
    /// upserting, because `ON CONFLICT (id)` never actually conflicts (id is server-generated,
    /// never client-supplied). The FIRST vote for any given `(pin_id, user_id)` pair always
    /// worked (nothing to conflict with yet), which is exactly why this shipped unnoticed —
    /// this is flag-off-reachable: `enforcement_active`/`sweeper_passed`'s confirm/dispute UI
    /// (`PinDetailSheet.ReactionsRow`) predates `AppConstants.communityEnabled` entirely (Tier 3
    /// sub-PR #1). Now fixed by passing `on_conflict=pin_id,user_id` below, mirroring the exact
    /// same fix applied to `PushRegistrationService.upsertToken` in the same PR.
    ///
    /// The `votes_refresh_pin_counts` trigger fires server-side and updates
    /// `pins.confirm_count` / `pins.dispute_count`. A Realtime UPDATE event then
    /// propagates the new counts to all subscribers via `mergeRealtimeChange`.
    ///
    /// - Parameters:
    ///   - pinId: The UUID of the pin being voted on.
    ///   - vote: `.confirm` or `.dispute`.
    func upsertVote(pinId: UUID, vote: VoteType) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw CommunityPinWriteError.notAuthenticated
        }

        let payload: [String: Any] = [
            "pin_id":  pinId.uuidString,
            "user_id": userId.uuidString,
            "vote":    vote.rawValue,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CommunityPinWriteError.encodingFailure
        }

        let request = buildAuthenticatedRequest(
            path: "rest/v1/votes",
            method: "POST",
            jwt: jwt,
            body: body,
            // PostgREST upsert: on conflict (pin_id, user_id), update the vote column.
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"],
            // Required — see this method's own doc comment above for the bug this closes.
            // `pin_id,user_id` matches `votes`' actual `unique (pin_id, user_id)` constraint
            // (a plain multi-column constraint, not a named/expression index — PostgREST
            // resolves a bare comma-separated column list directly, no index-name lookup
            // needed, unlike `ingest-film-permits/index.ts`'s expression-index case).
            queryItems: [URLQueryItem(name: "on_conflict", value: "pin_id,user_id")]
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }
    }

    // MARK: - Write path: Identity (Community 2.0 Phase 2b, build 20 S7)

    /// Upserts the current user's `profiles` row with a chosen handle/avatar — the "Join the
    /// board & post" identity save (`Views/IdentitySheet.swift`,
    /// `design/prototype.html:415-429`, spec §3 Phase 2).
    ///
    /// Reuses the exact upsert shape `upsertVote` already established above
    /// (`Prefer: resolution=merge-duplicates`, resolving on the row's primary key `id`) — a
    /// second call from the same device safely overwrites rather than duplicating.
    ///
    /// Deliberately sets ONLY `username`/`avatar` — never `reputation` /
    /// `helped_count` / `accurate_report_count` / `total_report_count`, all of which are
    /// server-computed via §2.6's insert-on-conflict triggers
    /// (`award_report_reputation`/`award_confirm_reputation`/`award_chat_reputation`). The
    /// client never writes its own rep — a standing constraint restated verbatim in the
    /// reconciliation spec's Phase 2 section.
    ///
    /// QA pass 1 fix (PR #96, Finding #1): `username` is REQUIRED (non-optional), never
    /// nil/empty. `public.profiles.username` is `text ... not null` with no `DEFAULT`
    /// (`supabase/01-mvp-schema.sql:10`) — Phase 0's migration (§2.5) only dropped the
    /// column's UNIQUE constraint, not its `NOT NULL`. PostgREST's upsert
    /// (`Prefer: resolution=merge-duplicates`) compiles to `INSERT ... ON CONFLICT (id) DO
    /// UPDATE`, and Postgres validates `NOT NULL` on the row constructed for the `INSERT`
    /// clause BEFORE conflict resolution is applied — an omitted/null username 400s on
    /// EVERY call, not only a user's first-ever profile write. Making this parameter
    /// non-optional closes the bug class at the type level for every current AND future
    /// caller, rather than relying on each call site to remember a runtime workaround. The
    /// one production caller, `IdentitySheet.resolvedUsername(rawHandle:)`, guarantees a
    /// non-empty value (trims, falls back to a generated suggestion when empty).
    ///
    /// - Parameters:
    ///   - username: The chosen handle, trimmed and guaranteed non-empty by the caller.
    ///   - avatar: The chosen avatar emoji, or nil.
    func upsertProfile(username: String, avatar: String?) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw CommunityPinWriteError.notAuthenticated
        }

        var payload: [String: Any] = ["id": userId.uuidString, "username": username]
        if let avatar { payload["avatar"] = avatar }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CommunityPinWriteError.encodingFailure
        }

        let request = buildAuthenticatedRequest(
            path: "rest/v1/profiles",
            method: "POST",
            jwt: jwt,
            body: body,
            // PostgREST upsert: on conflict (id, the primary key), update username/avatar.
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }
    }

    // MARK: - Read path: Own profile (Community 2.0 Phase 3, build 20 S9)

    /// Fetches the current user's own `profiles` row for the crew-feed profile row
    /// (spec §2.5/§3 Phase 3, `design/prototype.html:161-173`). Returns `nil` — rather than
    /// throwing — when no row exists yet, since that's a common, expected state (a device
    /// that has never authored a report, voted, or chatted has no `profiles` row at all, per
    /// §2.6's insert-on-conflict triggers being the only writer besides `upsertProfile`), not
    /// a failure. The profile row itself renders nothing in that case (this file's
    /// `CrewFeedSection.profileRow`), matching the prototype's own `profileOn` gate.
    ///
    /// Public read (`profiles_select_all`, `01-mvp-schema.sql`) — no JWT required for a
    /// `select`, consistent with every other user's profile being publicly readable (that's
    /// also what makes `author_username`/leaderboard entries visible to everyone).
    ///
    /// - Parameter userId: The current user's `auth.uid()` (`authService.currentUserId`).
    func fetchOwnProfile(userId: UUID) async throws -> CommunityProfile? {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userId.uuidString)"),
            URLQueryItem(
                name: "select",
                value: "id,username,avatar,reputation,created_at,helped_count,accurate_report_count,total_report_count"
            ),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinFetchError.httpError(statusCode: status)
        }

        let profiles = try Self.makeDateDecodingJSONDecoder().decode([CommunityProfile].self, from: data)
        return profiles.first
    }

    // MARK: - Write path: Extend pin expiry

    /// Calls the `extend_pin_expiry` RPC to extend an ephemeral pin's TTL by 15 minutes.
    ///
    /// The RPC is defined in `supabase/02-pins-schema.sql` and caps expiry at now+2h.
    /// Called alongside `upsertVote(.confirm)` when the user taps "Still there?".
    ///
    /// - Parameter pinId: The UUID of the ephemeral pin to extend.
    func callExtendPinExpiry(pinId: UUID) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken() else {
            throw CommunityPinWriteError.notAuthenticated
        }

        let payload: [String: Any] = ["p_pin_id": pinId.uuidString]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CommunityPinWriteError.encodingFailure
        }

        let request = buildAuthenticatedRequest(
            path: "rest/v1/rpc/extend_pin_expiry",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: [:]
        )

        let (_, response) = try await urlSession.data(for: request)
        // 204 No Content is also a valid success for RPCs with no return value.
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }
    }

    // MARK: - Write path: Claim a leaving_soon pin (Community 2.0 Phase 3, build 20 S9)

    /// Calls the `claim_pin` RPC (spec §2.10) — the "I'm heading there" affordance for
    /// `leaving_soon` pins. Single `UPDATE ... WHERE claimed_by IS NULL` server-side, so the
    /// first caller wins and every subsequent caller gets `false` back — race-safe by
    /// construction, no client-side locking needed.
    ///
    /// Deliberately does NOT locally patch `visiblePins` on a `true` result — `claimed_by` is
    /// a decode-only field (`CommunityPin.claimedBy`'s doc comment) with no local mutation
    /// path on an immutable struct, and this mirrors `upsertVote`'s existing precedent:
    /// neither call locally patches its counter/field, both rely on the already-live Realtime
    /// UPDATE echo (the RPC's `UPDATE public.pins SET claimed_by = ...` is a normal row
    /// update, so it flows through the same `mergeRealtimeChange` pipeline `votes_refresh_pin_counts`
    /// already relies on for confirm/dispute counts) to reflect the change everywhere,
    /// including this caller's own UI.
    ///
    /// - Parameter pinId: The `leaving_soon` pin's UUID.
    /// - Returns: `true` if this call won the claim; `false` if someone already claimed it —
    ///   spec §2.10 and §3 Phase 4 are explicit that `false` is the expected, race-safe
    ///   outcome ("someone beat you to it — first come, first served"), never surfaced as an
    ///   error by any caller of this method.
    /// - Throws: `CommunityPinWriteError.notAuthenticated` with no session;
    ///   `.httpError(statusCode:)` for any non-2xx response (a genuine failure, distinct from
    ///   the `false` race-safe return above).
    func claimPin(pinId: UUID) async throws -> Bool {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken() else {
            throw CommunityPinWriteError.notAuthenticated
        }

        let payload: [String: Any] = ["p_pin_id": pinId.uuidString]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw CommunityPinWriteError.encodingFailure
        }

        let request = buildAuthenticatedRequest(
            path: "rest/v1/rpc/claim_pin",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: [:]
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }

        // `claim_pin` returns a bare `boolean` scalar (`true`/`false`), not a row/array —
        // decode directly rather than via decodeResponse(...) (which expects [CommunityPin]).
        // A 2xx response with an unparseable/empty body (shouldn't happen, but defensive)
        // reads as `false` rather than throwing — "not claimed" is always a safe fallback
        // here, never a state that would corrupt anything downstream.
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    // MARK: - Write path: Delete own pin (FT-2)

    /// Hard-deletes a pin the current user authored — the "I reported this by mistake"
    /// escape hatch (`docs/ft2-delete-own-pin-spec.md` §4.1).
    ///
    /// Server-side authority is the `pins_delete_own` RLS policy
    /// (`supabase/02-pins-schema.sql:157-159`, `for delete using (auth.uid() = author_id)`)
    /// — that policy already exists and is live; this method does NOT re-check ownership
    /// client-side before issuing the request. `PinDetailSheet`'s delete affordance only
    /// ever appears on the caller's own pin (`ReactionsRow.isOwnPin`), but that UI guard is
    /// a convenience, not the security boundary — a caller that somehow reached this method
    /// for someone else's pin gets an HTTP 403 back from RLS, exactly as intended.
    ///
    /// Optimistic local removal happens BEFORE the network call fires (spec §4.1 step 2),
    /// mirroring `insertCrowdPin`'s optimistic-add: `visiblePins` drops the pin immediately
    /// so the map marker disappears without waiting for a round trip.
    ///
    /// If the network call subsequently throws, this method ROLLS the removal BACK — restoring
    /// the pin to `visiblePins` at its original index — before rethrowing, so the caller
    /// (`PinDetailSheet`) can show its inline error against a map that still shows the pin,
    /// not one that already erased it. This is a deliberately different posture than
    /// `insertCrowdPin`'s optimistic add, which does NOT roll back on failure: a failed
    /// optimistic *add* just means a pin the user tried to share never appears — mildly
    /// annoying, and self-evident when it doesn't show up. A failed optimistic *delete*
    /// without rollback is worse in kind: the user's map says the bad report is gone, so they
    /// believe they fixed it and move on, while every *other* driver still sees the original
    /// (possibly wrong) pin. That's exactly the scenario FT-2 exists to prevent — so this path
    /// must not defeat it.
    ///
    /// Rollback vs. a genuine Realtime DELETE echo (spec §5 "Delete while offline", and the
    /// case where the delete actually succeeded server-side but the HTTP response itself was
    /// lost/errored): rolling back unconditionally on any thrown error would risk resurrecting
    /// a pin the server truly did delete, only to have it vanish again (or worse, stick around)
    /// once Realtime's real DELETE event arrives — a flicker at best, a stale zombie pin at
    /// worst. To avoid that, `pendingOptimisticDeletes[id]` is set to `false` right before the
    /// optimistic removal and consulted right before any rollback:
    ///   - If a Realtime DELETE echo for this same id arrives DURING the round trip,
    ///     `removePin(id:)` flips that entry to `true`. The failure-path rollback below checks
    ///     this and skips restoring the pin — Realtime's independent confirmation that the row
    ///     is really gone wins over the failed HTTP response.
    ///   - If no echo arrives during the round trip, the entry stays `false`, the pin is
    ///     restored, and the `pendingOptimisticDeletes` entry is cleared via `defer` regardless
    ///     of outcome. If a genuine echo arrives LATER (after this call has already returned/
    ///     thrown and the entry is gone), it just runs `removePin(id:)`'s normal, unconditional
    ///     `visiblePins.removeAll { $0.id == id }` — which correctly removes the pin this
    ///     rollback just restored. Either ordering self-corrects to server truth.
    ///
    /// The `votes` FK (`supabase/02-pins-schema.sql:166`, `on delete cascade`) means a
    /// successful delete here also removes every vote on the pin server-side — no
    /// client-side pre-delete of votes is needed.
    ///
    /// A Realtime DELETE event for this same pin arriving after a SUCCESSFUL delete (own echo,
    /// or another client's fetch racing this one) routes through `removePin(id:)`, which is a
    /// no-op on an ID that's already absent (this method's own optimistic removal got there
    /// first). No flicker, no resurrection, no crash: removal is idempotent by construction.
    ///
    /// - Parameter id: The pin's primary key.
    /// - Throws: `CommunityPinWriteError.notAuthenticated` if there's no valid session (thrown
    ///   before any optimistic removal — nothing to roll back on this path); `.httpError
    ///   (statusCode:)` for any other non-2xx response (in particular 403 if RLS rejects the
    ///   delete because the caller isn't the author), with the pin restored to `visiblePins`
    ///   first unless Realtime already confirmed the delete (see above). HTTP 404 is treated
    ///   as success, not a failure — the pin is already gone (expired cleanup, or a delete race
    ///   with another client/tab), and PostgREST itself returns 200/204 with zero rows affected
    ///   rather than 404 for "no matching row" on DELETE, so this is defensive, not the
    ///   expected path. No rollback happens on this path since it isn't a failure.
    func deleteCrowdPin(id: UUID) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              authSvc.currentUserId != nil else {
            throw CommunityPinWriteError.notAuthenticated
        }

        // Capture the pin's exact position and fields BEFORE the optimistic removal, so a
        // failure-path rollback restores it precisely rather than reconstructing it. `nil` if
        // `id` isn't currently present (nothing to capture or later roll back).
        let capturedIndex = visiblePins.firstIndex { $0.id == id }
        let capturedPin = capturedIndex.map { visiblePins[$0] }

        // Register this id as an in-flight optimistic delete BEFORE removing it, so a Realtime
        // DELETE echo that lands during the network round trip can be distinguished from "no
        // echo arrived" once we're back here deciding whether to roll back (see doc comment
        // above and `removePin(id:)`). Cleared unconditionally on return via `defer`.
        if capturedPin != nil {
            pendingOptimisticDeletes[id] = false
        }
        defer { pendingOptimisticDeletes[id] = nil }

        // Optimistic local removal — before the network call (spec §4.1 step 2).
        visiblePins.removeAll { $0.id == id }

        // DELETE requests filter by primary key via a PostgREST query parameter
        // (?id=eq.<uuid>), not the path — same URLComponents pattern as the request
        // builders above (e.g. buildOpenDataRequest). buildAuthenticatedRequest(path:...)
        // can't express this: it only ever appends `path` as a literal path component.
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/pins"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        guard let url = components?.url else {
            rollbackOptimisticDelete(id: id, pin: capturedPin, index: capturedIndex)
            throw CommunityPinWriteError.encodingFailure
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // return=minimal: DELETE has no body either way; no representation is needed back.
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CommunityPinWriteError.httpError(statusCode: 0)
            }
            // 2xx: success. 404: already gone — also treated as success (see doc comment
            // above). Neither path rolls back.
            if (200..<300).contains(http.statusCode) || http.statusCode == 404 {
                return
            }
            throw CommunityPinWriteError.httpError(statusCode: http.statusCode)
        } catch {
            rollbackOptimisticDelete(id: id, pin: capturedPin, index: capturedIndex)
            throw error
        }
    }

    /// Restores a pin removed by `deleteCrowdPin`'s optimistic removal, after the network call
    /// actually failed — UNLESS a genuine Realtime DELETE echo for the same id arrived during
    /// the round trip (`pendingOptimisticDeletes[id] == true`, set by `removePin(id:)`), in
    /// which case the server really did delete the row and only the client's response failed
    /// to reflect it; resurrecting the pin in that case would recreate, via a different code
    /// path, exactly the "map disagrees with server truth" bug FT-2 exists to prevent.
    ///
    /// No-op if there's nothing captured to restore (`pin`/`index` nil — `id` wasn't present at
    /// the start of `deleteCrowdPin`), if Realtime already confirmed the delete, or if the pin
    /// is somehow already present (defensive; shouldn't happen given `deleteCrowdPin`'s single
    /// call site for this, but avoids a duplicate entry if it ever does).
    ///
    /// - Parameters:
    ///   - id: The pin's primary key — used only to consult `pendingOptimisticDeletes`.
    ///   - pin: The exact `CommunityPin` captured immediately before optimistic removal.
    ///   - index: Its index in `visiblePins` at that same moment.
    private func rollbackOptimisticDelete(id: UUID, pin: CommunityPin?, index: Int?) {
        guard let pin, let index else { return }
        guard pendingOptimisticDeletes[id] != true else { return }
        guard !visiblePins.contains(where: { $0.id == id }) else { return }
        let insertIndex = min(index, visiblePins.count)
        visiblePins.insert(pin, at: insertIndex)
    }

    // MARK: - Write path: Block-scoped restriction report (FT-15/TF2-15 Stream B3)

    /// Per-type default window (§5.3) applied when the report's end time is left blank.
    /// `nil` for any `pinType` other than `.filming`/`.construction` — this primitive
    /// serves only those two (§9.3).
    ///
    /// OQ-2 (spec, non-blocking): these are first-pass numbers, not measured against real
    /// permit durations — tune post-launch. Must match
    /// `supabase/02f-block-scoped-restrictions.sql`'s `pins_block_scoped_ceiling_chk`
    /// defaults/comments exactly; if one side of this pair is ever retuned, update both.
    nonisolated static func defaultReportWindow(for pinType: PinType) -> TimeInterval? {
        switch pinType {
        case .filming:      return 24 * 3600            // 24h
        case .construction: return 14 * 24 * 3600        // 14d
        default:            return nil
        }
    }

    /// Hard ceiling (§5.3) from `starts_at`. `nil` for any `pinType` other than
    /// `.filming`/`.construction`. This is DEFENSE IN DEPTH ONLY — the actual authority is
    /// `pins_block_scoped_ceiling_chk` in `supabase/02f-block-scoped-restrictions.sql`,
    /// which enforces the identical values server-side regardless of what this client
    /// computes. Clamping here just avoids a confusing generic 400/23514 for an obviously
    /// out-of-range submission.
    nonisolated static func hardCeiling(for pinType: PinType) -> TimeInterval? {
        switch pinType {
        case .filming:      return 7 * 24 * 3600         // 7d
        case .construction: return 90 * 24 * 3600        // 90d
        default:            return nil
        }
    }

    /// The `lifespan` value a block-scoped report of `pinType` is inserted with, per the
    /// two-axis model (`docs/typed-pin-schema-spec.md` §3: filming is `session`
    /// — self-expiring, same-day-typical; construction is `durable` — does not
    /// conventionally auto-expire, but THIS feature explicitly overrides that convention
    /// by still setting `expires_at` on construction rows too, per §5.1/§5.3's own window
    /// model applying to both types). `nil` for any other `pinType`.
    nonisolated static func lifespanForBlockScopedReport(pinType: PinType) -> PinLifespan? {
        switch pinType {
        case .filming:      return .session
        case .construction: return .durable
        default:            return nil
        }
    }

    /// Resolves the actual `expires_at` to submit: the caller-supplied value if present,
    /// else `startsAt + defaultReportWindow(for:)`; then clamps to
    /// `startsAt + hardCeiling(for:)` either way (defense in depth — see `hardCeiling`'s
    /// doc comment).
    ///
    /// Pure and `nonisolated static` so B2's UI can call this exact function to compute
    /// the "We'll assume this ends in X" copy (AC-R6) without risking the displayed
    /// default ever drifting from the value this write path actually submits.
    nonisolated static func resolvedExpiresAt(pinType: PinType, startsAt: Date, requested: Date?) -> Date {
        let base: Date
        if let requested {
            base = requested
        } else {
            let window = defaultReportWindow(for: pinType) ?? (90 * 24 * 3600)
            base = startsAt.addingTimeInterval(window)
        }
        guard let ceiling = hardCeiling(for: pinType) else { return base }
        let ceilingDate = startsAt.addingTimeInterval(ceiling)
        return min(base, ceilingDate)
    }

    /// Submits a block-scoped restriction report (§3.4): uploads the evidence photo, then
    /// inserts N `pins` rows (one per selected blockface) sharing one client-generated
    /// `report_group_id`.
    ///
    /// ## Partial-failure behavior — flagged for orchestrator review
    ///
    /// The spec explicitly hands this decision to B3 ("you own the client behavior") and
    /// rules out a wrapping RPC (§3.4). Three cases:
    ///
    /// 1. **Evidence upload fails** (Storage object or `pin_evidence` row — see
    ///    `PinEvidenceUploadError`): nothing else has been attempted. Thrown as
    ///    `.evidenceUploadFailed`; zero `pins` rows exist.
    ///    `PinEvidenceUploader.upload(...)` attempts a best-effort delete of the Storage
    ///    object if the `pin_evidence` row insert fails after a successful upload — but
    ///    see that method's doc comment for a flagged, honest limitation: the schema ships
    ///    no Storage delete policy in phase 1, so today that attempt itself 403s, and this
    ///    specific failure CAN leave an orphaned Storage object with zero DB trace. Low
    ///    severity (private bucket, uploader-keyed path, no PII exposure beyond what §7
    ///    already accepts for evidence that does have a DB row) but not silently claimed
    ///    as solved.
    /// 2. **Evidence succeeds, but the pins batch fails partway through** (rows `1...k` of
    ///    `N` inserted, row `k+1` fails — rate limit, network, or a constraint): this
    ///    method deletes the `k` already-inserted rows (author-owned, via the existing,
    ///    unmodified `pins_delete_own` RLS — no new server capability) before rethrowing
    ///    the triggering error. **This is a deliberate choice beyond what the schema
    ///    explicitly mandates**: the schema's own comments accept an ORPHANED EVIDENCE row
    ///    as inert (§3.4/§7, no automatic deletion in phase 1 either way), but say nothing
    ///    about a partial PINS BATCH — and a report that silently covers 2 of 4 tapped
    ///    blocks, with no UI signal that it's incomplete, is a materially worse and more
    ///    confusing outcome than "the whole submission failed, retry." Rolling back to
    ///    zero keeps the result binary: either all N rows are live, or none are. The
    ///    evidence row/photo are NOT rolled back in this case (matches the schema's own
    ///    accepted-orphan posture) — a retried submission generates a fresh
    ///    `report_group_id` (a new call to this method), so the old evidence row simply
    ///    becomes unreferenced, not incorrect or duplicated.
    /// 3. **Rate limit specifically**: surfaced as `.rateLimitExceeded`, not a generic HTTP
    ///    error, so the caller can show clear copy instead of a raw error string. Detected
    ///    by parsing the PostgREST error body's `code` field for `"42501"` (the SQLSTATE
    ///    `enforce_block_scoped_rate_limit()` raises), not just the HTTP status, so this
    ///    can't misfire on some unrelated 403.
    ///
    /// - Parameters:
    ///   - pinType: `.filming` or `.construction` only (§9.3). Any other value throws
    ///     `.unsupportedPinType` before any network call is made.
    ///   - selections: One entry per tapped blockface (§4.2's "Both curbs" toggle already
    ///     resolved into this list by the caller — this method does not infer opposite
    ///     sides). Must be non-empty.
    ///   - startsAt: The report's window start (§5.2's "Restriction starts" picker).
    ///   - expiresAt: The report's window end, or `nil` if the user left "Restriction
    ///     ends" blank — `resolvedExpiresAt(pinType:startsAt:requested:)` fills the
    ///     type-specific default and clamps to the hard ceiling either way.
    ///   - notes: Optional free-text notes, shared across every row in the batch.
    ///   - evidencePhoto: Raw captured photo bytes (required — §2/AC-R5; this method does
    ///     not accept a nil/optional photo).
    ///   - evidenceContentType: MIME type of `evidencePhoto`. Default `"image/jpeg"`.
    /// - Returns: The shared `report_group_id` and the N inserted rows.
    /// - Throws: `BlockScopedReportError`.
    func insertBlockScopedReport(
        pinType: PinType,
        selections: [BlockScopedReportSelection],
        startsAt: Date,
        expiresAt: Date?,
        notes: String?,
        evidencePhoto: Data,
        evidenceContentType: String = "image/jpeg"
    ) async throws -> BlockScopedReportResult {
        guard let lifespan = Self.lifespanForBlockScopedReport(pinType: pinType) else {
            throw BlockScopedReportError.unsupportedPinType(pinType)
        }
        guard !selections.isEmpty else {
            throw BlockScopedReportError.emptySelections
        }
        guard let authSvc = authService else {
            throw BlockScopedReportError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw BlockScopedReportError.notAuthenticated
        }

        // Named distinctly from the static `resolvedExpiresAt(pinType:startsAt:requested:)`
        // function above to avoid a local-variable/static-function name shadow.
        let resolvedExpires = Self.resolvedExpiresAt(pinType: pinType, startsAt: startsAt, requested: expiresAt)
        guard resolvedExpires > startsAt else {
            throw BlockScopedReportError.invalidWindow
        }

        // §3.4: client generates report_group_id up front. The evidence row is written
        // BEFORE any pins row exists — see this method's doc comment above for the full
        // partial-failure decision this ordering implies.
        let reportGroupId = UUID()

        let uploader = PinEvidenceUploader(
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseAnonKey,
            urlSession: urlSession,
            authService: authSvc
        )
        do {
            _ = try await uploader.upload(
                photoData: evidencePhoto,
                contentType: evidenceContentType,
                reportGroupId: reportGroupId
            )
        } catch {
            throw BlockScopedReportError.evidenceUploadFailed(underlying: error)
        }

        // Insert N pins rows SEQUENTIALLY (not concurrently) — this is what makes the
        // rollback-on-partial-failure behavior above possible: at any point we know
        // exactly which rows of this batch have already landed.
        var insertedPins: [CommunityPin] = []
        var insertedIds: [UUID] = []

        for selection in selections {
            do {
                let pin = try await insertSingleBlockScopedPin(
                    pinType: pinType,
                    lifespan: lifespan,
                    selection: selection,
                    reportGroupId: reportGroupId,
                    startsAt: startsAt,
                    expiresAt: resolvedExpires,
                    notes: notes,
                    userId: userId,
                    jwt: jwt
                )
                insertedPins.append(pin)
                insertedIds.append(pin.id)
            } catch let error as BlockScopedReportError {
                await rollbackBlockScopedPins(ids: insertedIds, jwt: jwt)
                throw error
            } catch {
                await rollbackBlockScopedPins(ids: insertedIds, jwt: jwt)
                throw BlockScopedReportError.pinsInsertFailed(statusCode: 0)
            }
        }

        // Optimistic add — mirrors insertCrowdPin's Fix 1 pattern (Channel 3's read path
        // already covers these rows going forward; this makes them appear immediately
        // without waiting for the next periodic refresh).
        for pin in insertedPins {
            mergeRealtimeChange(pin: pin)
        }

        return BlockScopedReportResult(reportGroupId: reportGroupId, insertedPins: insertedPins)
    }

    /// Inserts exactly one `pins` row for a block-scoped report batch.
    ///
    /// Builds its own request (rather than reusing `insertCrowdPin`'s payload shape,
    /// which is ephemeral-type-specific) so it can send `starts_at` / `report_group_id`
    /// and read the raw response body needed for rate-limit detection.
    private func insertSingleBlockScopedPin(
        pinType: PinType,
        lifespan: PinLifespan,
        selection: BlockScopedReportSelection,
        reportGroupId: UUID,
        startsAt: Date,
        expiresAt: Date,
        notes: String?,
        userId: UUID,
        jwt: String
    ) async throws -> CommunityPin {
        var payload: [String: Any] = [
            "pin_type":        pinType.rawValue,
            "source":          PinSource.crowd.rawValue,
            "lifespan":        lifespan.rawValue,
            "lat":             selection.lat,
            "lng":             selection.lng,
            "segment_id":      selection.blockfaceKey,
            "author_id":       userId.uuidString,
            "report_group_id": reportGroupId.uuidString,
            "starts_at":       iso8601String(from: startsAt),
            "expires_at":      iso8601String(from: expiresAt),
        ]
        if let notes { payload["notes"] = notes }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw BlockScopedReportError.encodingFailure
        }

        let request = buildAuthenticatedRequest(
            path: "rest/v1/pins",
            method: "POST",
            jwt: jwt,
            body: body,
            extraHeaders: [
                "Prefer": "return=representation",
                "Accept": "application/json",
            ]
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BlockScopedReportError.pinsInsertFailed(statusCode: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            if Self.isRateLimitError(statusCode: http.statusCode, body: data) {
                throw BlockScopedReportError.rateLimitExceeded
            }
            throw BlockScopedReportError.pinsInsertFailed(statusCode: http.statusCode)
        }

        guard let pins = try? decodeResponse(data: data), let pin = pins.first else {
            throw BlockScopedReportError.pinsInsertFailed(statusCode: http.statusCode)
        }
        return pin
    }

    /// True if a non-2xx `pins` insert response is the rate-limit trigger's rejection.
    ///
    /// `enforce_block_scoped_rate_limit()` (`supabase/02f-block-scoped-restrictions.sql`)
    /// raises `errcode = 'insufficient_privilege'` (Postgres SQLSTATE `42501`), which
    /// PostgREST maps to HTTP 403 with a JSON body `{"code":"42501", "message":"...", ...}`.
    /// Checking the parsed `code` field (not just the HTTP status) so this can't misfire on
    /// some other, unrelated 403 — the only thing in this feature that raises `42501` is
    /// this trigger.
    private nonisolated static func isRateLimitError(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 403 else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return (json["code"] as? String) == "42501"
    }

    /// Best-effort compensating rollback for a partially-succeeded block-scoped pins
    /// batch — see `insertBlockScopedReport`'s doc comment (case 2) for the full
    /// reasoning. Deletes each already-inserted row of THIS batch via the existing,
    /// unmodified `pins_delete_own` RLS policy (author-only delete — no new server-side
    /// capability needed).
    ///
    /// Failures here are swallowed: if a delete also fails (e.g. the same network outage
    /// that caused the original insert failure), there is nothing more this method can
    /// safely retry without risking deleting the wrong rows on some later, unrelated call.
    /// The caller's own triggering error (rate limit / insert failure) is what gets
    /// surfaced to the user either way, and a row left behind by a failed rollback attempt
    /// is still author-owned and deletable later through the same existing RLS path (or a
    /// future dispute/auto-resolve cycle, §6.1).
    private func rollbackBlockScopedPins(ids: [UUID], jwt: String) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            var components = URLComponents(
                url: supabaseURL.appendingPathComponent("rest/v1/pins"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
            guard let url = components?.url else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

            _ = try? await urlSession.data(for: request)
        }
    }

    // MARK: - Authenticated request builder (write path)

    /// Builds an authenticated URLRequest for write operations.
    ///
    /// Attaches both `apikey` (Supabase gateway auth) and `Authorization: Bearer <jwt>`
    /// (RLS auth.uid() satisfaction). Both headers are required for authenticated writes.
    ///
    /// - Parameter queryItems: PR #101 QA pass 1 fix (Finding — "shipped upsertVote may share
    ///   the on_conflict defect"): additive, defaults to `[]`, so every EXISTING call site's
    ///   URL is byte-identical to before this parameter existed (`appendingPathComponent(path)`
    ///   alone, no `URLComponents` round-trip). Only `upsertVote` (below) passes a non-empty
    ///   value today — an `on_conflict` query param is required whenever a POST's `Prefer:
    ///   resolution=merge-duplicates` upsert needs to target a constraint OTHER than the
    ///   table's primary key (PostgREST's documented default is `ON CONFLICT (<primary key>)`
    ///   when `on_conflict` is omitted — see `upsertVote`'s own doc comment for the concrete
    ///   bug this caused).
    private func buildAuthenticatedRequest(
        path: String,
        method: String,
        jwt: String,
        body: Data?,
        extraHeaders: [String: String],
        queryItems: [URLQueryItem] = []
    ) -> URLRequest {
        var url = supabaseURL.appendingPathComponent(path)
        if !queryItems.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            if let composedURL = components.url {
                url = composedURL
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        return request
    }
}

// MARK: - CommunityPinFetchError

enum CommunityPinFetchError: Error {
    case httpError(statusCode: Int)
    case missingConfig
}

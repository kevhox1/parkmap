//
//  CommunityPinService.swift
//  WePark
//
//  Tier 1 Pin Display — Community 1.0 read-only fetch + Realtime subscription stub.
//  Tier 3 Sub-PR #1 additions: authenticated write path (insertCrowdPin, upsertVote,
//  callExtendPinExpiry) + Realtime channel activation for ephemeral crowd pins.
//  Spec: docs/tier1-pin-display-spec.md §9, docs/tier3-auth-and-reactions-spec.md §3.9.
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
        mergeRealtimeChange(pin: pin)
    }

    /// Removes a pin by ID — the DELETE-event counterpart to `mergeRealtimeChange(pin:)`
    /// (spec §8.2 gap #2). A Postgres Realtime DELETE payload, without `REPLICA IDENTITY FULL`
    /// (deliberately not set — spec §2 Out), only reliably carries the deleted row's primary
    /// key, so this cannot reuse `mergeRealtimeChange`'s `CommunityPin`-typed signature. No-op
    /// if `id` is not currently present in `visiblePins` (e.g. it was never in the fetched
    /// viewport, or Kevin's manual SQL cleanup deleted a row no client had loaded).
    func removePin(id: UUID) {
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

    /// True if `pin` matches Channel 2's fetch predicate (crowd source, ephemeral
    /// lifespan; enforcement_active / sweeper_passed). Mirrors `buildCrowdEphemeralRequest`.
    private nonisolated static func isChannel2Member(_ pin: CommunityPin) -> Bool {
        pin.source == .crowd &&
        pin.lifespan == .ephemeral &&
        [PinType.enforcementActive, .sweeperPassed].contains(pin.pinType)
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

    /// Builds the PostgREST URLRequest for Channel 2: crowd ephemeral pins.
    ///
    /// Fetches: enforcement_active, sweeper_passed
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
            URLQueryItem(name: "pin_type",    value: "in.(enforcement_active,sweeper_passed)"),
            URLQueryItem(name: "source",      value: "eq.crowd"),
            URLQueryItem(name: "lifespan",    value: "eq.ephemeral"),
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

    /// Decodes a PostgREST JSON array response into `[CommunityPin]`.
    ///
    /// Uses `CommunityPin.gracefulDecode` per element so a single malformed row
    /// does not crash the entire feed.
    private func decodeResponse(data: Data) throws -> [CommunityPin] {
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
    /// FT-1: enforcement agents and street sweepers are MOBILE and go stale fast — a
    /// 30-min lifetime kept them on the map long after they'd moved on. They now expire
    /// after 5 minutes (a "Still there?" confirm can still extend +15 min up to the 2h
    /// cap via the extend RPC). Broken meters are NOT mobile — a meter stays broken for a
    /// while — so they keep the original 30-min lifetime.
    nonisolated static func ephemeralTTLSeconds(for type: PinType) -> TimeInterval? {
        switch type {
        case .enforcementActive, .sweeperPassed:
            return 5 * 60      // FT-1: mobile, very fresh
        case .brokenMeter:
            return 30 * 60     // stationary condition — unchanged
        default:
            return nil          // non-ephemeral types do not auto-expire
        }
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
    ///   - zoneId: Optional zone ID (e.g. "soho-les").
    ///   - notes: Optional free-text notes.
    func insertCrowdPin(
        type: PinType,
        meta: [String: Any]?,
        lat: Double,
        lng: Double,
        segmentId: String?,
        zoneId: String?,
        notes: String?
    ) async throws {
        guard let authSvc = authService else {
            throw CommunityPinWriteError.notAuthenticated
        }
        guard let jwt = await authSvc.validAccessToken(),
              let userId = authSvc.currentUserId else {
            throw CommunityPinWriteError.notAuthenticated
        }

        // expires_at for ephemeral types. Uses nowProvider() for testability (AC-I1).
        // TTL is resolved by the pure `ephemeralTTLSeconds(for:)` helper (FT-1).
        let expiresAt: String? = Self.ephemeralTTLSeconds(for: type).map {
            iso8601String(from: nowProvider().addingTimeInterval($0))
        }

        var payload: [String: Any] = [
            "pin_type":  type.rawValue,
            "source":    PinSource.crowd.rawValue,
            "lifespan":  PinLifespan.ephemeral.rawValue,
            "lat":       lat,
            "lng":       lng,
            "author_id": userId.uuidString,
        ]
        if let expiresAt { payload["expires_at"] = expiresAt }
        if let segmentId { payload["segment_id"] = segmentId }
        if let zoneId    { payload["zone_id"] = zoneId }
        if let notes     { payload["notes"] = notes }
        if let meta      { payload["meta"] = meta }

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
            extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CommunityPinWriteError.httpError(statusCode: status)
        }
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
    private func buildAuthenticatedRequest(
        path: String,
        method: String,
        jwt: String,
        body: Data?,
        extraHeaders: [String: String]
    ) -> URLRequest {
        let url = supabaseURL.appendingPathComponent(path)
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

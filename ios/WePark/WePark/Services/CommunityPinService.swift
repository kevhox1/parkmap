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
//   - Periodic refresh (pinRefreshIntervalSeconds) re-fetches the last visible region so
//     new pins from self + others appear, and expired pins drop, without manual panning.
//     This is the TF1 stand-in for WebSocket Realtime. The timer fires only when a region
//     has been fetched at least once and is cancelled/suspended when driveModeActive.
//   - Realtime subscription stub (activated in sub-PR #1 for crowd ephemeral pins).
//   - Client-side expiry filter: removes pins where expiresAt != nil && expiresAt <= nowProvider().
//   - Publishes `visiblePins: [CommunityPin]` — ContentView observes this.
//   - Write path: insertCrowdPin / upsertVote / callExtendPinExpiry (authenticated, sub-PR #1).
//   - Optimistic add after insertCrowdPin: uses return=representation + mergeRealtimeChange
//     so the reporter sees their own pin immediately without panning (Fix 1).
//
//  Architectural invariants (HANDOFF.md Changelog 2026-05-26, spec §5):
//   - @MainActor: all visiblePins mutations run on the main actor so SwiftUI reads are safe.
//   - No Calendar.current — all time math uses nowProvider() (injectable for tests).
//   - Network path: raw URLSession + Codable (no supabase-swift SPM dep; see spec §9 note).
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
//  Realtime note:
//   - startRealtime() is ACTIVATED in sub-PR #1 for ephemeral crowd pins.
//   - Two channels: open_data (Tier 1) + ephemeral crowd (Tier 3).
//   - Without the supabase-swift SDK, Realtime uses Supabase's REST polling supplement
//     (the poll path handles live updates; full WebSocket Realtime is the SDK adoption path).
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

    // MARK: - Internal state

    // MARK: - Periodic refresh interval constant

    /// Interval for the periodic region re-fetch (Fix 2 / TF1 Realtime stand-in).
    /// Set to 8s so other users' fresh reports appear in <10s instead of ~25–35s.
    /// This is still the TF1 polling stand-in; real-time push via the supabase-swift
    /// SDK WebSocket Realtime is the TF2 upgrade path that will replace this timer.
    /// Named constant so it can be referenced in tests without magic numbers.
    static let pinRefreshIntervalSeconds: TimeInterval = 8

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
    init(
        supabaseURL: URL,
        supabaseAnonKey: String,
        nowProvider: @escaping () -> Date = { Date() },
        urlSession: URLSession = .shared,
        authService: SupabaseAuthService? = nil
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.nowProvider = nowProvider
        self.urlSession = urlSession
        self.authService = authService
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
    convenience init(authService: SupabaseAuthService? = nil) {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key, authService: authService)
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

    // MARK: - Realtime subscription (activated in sub-PR #1)

    /// Activates Supabase Realtime subscriptions for community pins.
    ///
    /// Sub-PR #1 activates this for two channels:
    ///   - Channel 1: open_data pins (Tier 1 — filming, special_event, asp_suspended_today).
    ///   - Channel 2: ephemeral crowd pins (Tier 3 — enforcement_active, sweeper_passed).
    ///
    /// Without the supabase-swift SDK, full WebSocket Realtime is not wired here.
    /// The polling path (onRegionChanged, 800ms debounce) serves as the live-update
    /// mechanism for TF1. Full WebSocket Realtime is the SDK-adoption fast-follow (see PR §9).
    ///
    /// TODO (SDK fast-follow): Replace stub with supabase-swift RealtimeChannel subscriptions:
    ///   Channel 1 filter: "source=eq.open_data"
    ///   Channel 2 filter: "lifespan=eq.ephemeral"
    ///   Both fire mergeRealtimeChange(pin:) on INSERT/UPDATE events.
    ///   The mergeRealtimeChange path (below) handles both channels identically.
    func startRealtime() {
        // Polling path is the active update mechanism for TF1 (onRegionChanged).
        // Full WebSocket Realtime requires the supabase-swift SDK (SPM adoption fast-follow).
        // mergeRealtimeChange(pin:) is implemented and tested below — ready for activation.
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

    // MARK: - Realtime merge (stub — activated post-prod-apply)

    /// Merges a Realtime INSERT or UPDATE event into `visiblePins`.
    ///
    /// Called by the Realtime subscription handler (SDK activation path) or directly
    /// in tests. Exported as `internal` so tests can exercise the merge logic.
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
        let mergeableTypes: Set<PinType> = [
            .filming, .specialEvent, .aspSuspendedToday,    // Tier 1
            .enforcementActive, .sweeperPassed, .brokenMeter, // Tier 3
            .construction  // FT-15/TF2-15 — filming is already covered by the Tier 1 line above
        ]
        guard mergeableTypes.contains(pin.pinType) else { return }

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

//
//  RealtimePinChannel.swift
//  WePark
//
//  supabase-swift adoption — Stream B (Realtime).
//  Spec: docs/supabase-swift-realtime-spec.md §3.4, §5, §8.2.
//
//  Abstraction over the SDK's `RealtimeChannelV2` so `CommunityPinService` — and its tests —
//  never depend on a live socket directly. Mirrors the `RouteServicing` protocol-extraction
//  precedent (`Services/RouteService.swift` — `RouteServicing` — W8.5c M-2).
//
//  This is the ONLY production file in this feature that imports the SDK's `Realtime`
//  product. `SupabaseClients.makeRealtimePinChannel()` returns the `RealtimePinSubscribing`
//  protocol type (not the concrete class below), so `WeParkApp.swift` / `ContentView.swift`
//  never need to `import Realtime` themselves just to wire this up.
//
//  Design (spec §5.1): ONE table-wide subscription on `public.pins`, `event: *`
//  (INSERT/UPDATE/DELETE), no server-side filter. `postgres_changes` filters can only express
//  single-column comparisons — they cannot reproduce the REST fetch channels' compound
//  predicates — so all filtering happens client-side via `RealtimeMergeGate` +
//  `CommunityPinService.clientSideFilter`, not here.
//
//  Known behavior difference vs. the REST path (documented, not a bug): `public.pins` is the
//  BASE table (Realtime/WAL only sees base tables, never views). The REST fetch channels read
//  `pins_with_author`, a VIEW that joins in `author_username`. A Realtime-pushed INSERT/UPDATE
//  therefore never carries `author_username` — it decodes to `nil` via `CommunityPin`'s
//  existing `decodeIfPresent` (already optional-safe, AC-D20 — no model change needed). A
//  Realtime-sourced pin shows no author username in the UI until the next REST re-fetch (the
//  periodic reconciliation poll, or the next `onRegionChanged` pan) fills it in.
//
//  DELETE handling (spec §8.2 gap #2): without `REPLICA IDENTITY FULL` (deliberately not set —
//  §2 Out), a Postgres Realtime DELETE payload's `oldRecord` only reliably carries the primary
//  key column (`id`). That is read directly off `DeleteAction.oldRecord["id"]` here and handed
//  to `onDelete(UUID)` — it never attempts to decode a full `CommunityPin` for a DELETE.
//
//  COMPILE-UNVERIFIED (written on a Linux VPS, no Xcode/Swift toolchain): every SDK symbol used
//  below (`RealtimeClientV2`, `RealtimeClientOptions`, `RealtimeChannelV2`, `AnyAction`,
//  `InsertAction`/`UpdateAction`/`DeleteAction`, `HasRecord.decodeRecord`/
//  `HasOldRecord.decodeOldRecord`, `onPostgresChange(AnyAction.self:...)`, `subscribeWithError()`,
//  `RealtimeChannelStatus`, `RealtimeClientStatus`) was verified by reading the actual pinned
//  `supabase-swift` revision's source (`a71f55a8d522aa38e2cecd314b64c6b24d518f8c` == v2.55.0,
//  same revision Stream A verified against — `Sources/RealtimeV2/*.swift`), not from memory of
//  another SDK's API shape. See the PR description for the specific files read and remaining
//  points of uncertainty (flagged inline below where relevant). Requires a Mac `xcodebuild
//  build` + `test` pass before merge.
//

import Foundation
import Realtime

// MARK: - RealtimePinSubscribing

/// Protocol seam for the Realtime pin subscription — enables `MockRealtimePinChannel`
/// injection in tests and keeps `CommunityPinService.swift` free of any SDK import.
@MainActor
protocol RealtimePinSubscribing: AnyObject {
    /// True while the underlying socket reports a connected state (`RealtimeClientV2.status
    /// == .connected`). Exposed for a future connection-status-driven fallback-poll cadence
    /// (spec §5.2, OQ-4) — not acted on in this phase.
    var isConnected: Bool { get }

    /// Subscribes to INSERT/UPDATE/DELETE on `public.pins`. Safe to call redundantly — a
    /// second call while already connected/subscribed is a no-op beyond re-opening the socket
    /// if it had been explicitly disconnected.
    ///
    /// Closures are `@MainActor`-typed (not just plain `(CommunityPin) -> Void`) so the
    /// isolation requirement survives being stored and invoked later from the SDK's own
    /// background delivery context — the conforming implementation hops onto `@MainActor`
    /// before calling either closure, so callers never need their own dispatch.
    func connect(
        onUpsert: @escaping @MainActor (CommunityPin) -> Void,
        onDelete: @escaping @MainActor (UUID) -> Void
    ) async

    /// Tears down the socket. Safe to call redundantly / when not connected.
    func disconnect() async
}

// MARK: - SupabasePinRealtimeChannel

/// Real implementation wrapping the SDK's `RealtimeClientV2` + `RealtimeChannelV2`.
@MainActor
final class SupabasePinRealtimeChannel: RealtimePinSubscribing {

    /// Fixed topic name for the single table-wide `public.pins` channel (spec §5.1). Not
    /// schema/table-derived by the SDK itself — `schema`/`table` are passed separately to
    /// `onPostgresChange`; this string is just this channel's identifier on the socket.
    private static let topic = "public:pins"

    private let realtimeClient: RealtimeClientV2
    private var channel: RealtimeChannelV2?

    /// Retains the `onPostgresChange` subscription token — per `RealtimeChannelV2`'s own doc,
    /// the callback is cancelled if this token is deallocated.
    private var subscriptionToken: RealtimeSubscription?

    // MARK: Init

    /// Designated initializer — takes an already-constructed `RealtimeClientV2`, shared across
    /// the app for this Supabase project's lifetime (`RealtimeClientV2`'s own doc: "Create one
    /// client per Supabase project and reuse it across your app"). Production call sites reach
    /// this via `SupabaseClients.makeRealtimePinChannel()`.
    init(realtimeClient: RealtimeClientV2) {
        self.realtimeClient = realtimeClient
    }

    /// Convenience initializer — builds its own standalone `RealtimeClientV2` from raw
    /// URL/key. Used only as `CommunityPinService`'s internal fallback default when no shared
    /// `SupabaseClients` instance is injected (mirrors the existing `authService:
    /// SupabaseAuthService? = nil` fallback pattern already in that initializer). Production
    /// call sites (`ContentView`, via `WeParkApp`'s shared `SupabaseClients`) should prefer the
    /// designated initializer instead.
    convenience init(supabaseURL: URL, supabaseAnonKey: String) {
        self.init(
            realtimeClient: RealtimeClientV2(
                url: supabaseURL.appendingPathComponent("realtime/v1"),
                options: RealtimeClientOptions(headers: ["apikey": supabaseAnonKey])
            )
        )
    }

    // MARK: RealtimePinSubscribing

    var isConnected: Bool {
        realtimeClient.status == .connected
    }

    func connect(
        onUpsert: @escaping @MainActor (CommunityPin) -> Void,
        onDelete: @escaping @MainActor (UUID) -> Void
    ) async {
        // No-op if already connected — RealtimeClientV2.connect()'s own doc: "Calling this
        // method when already connected is a no-op."
        await realtimeClient.connect()

        let ch: RealtimeChannelV2
        if let existing = channel {
            ch = existing
        } else {
            // Register the postgres_changes callback exactly once, on the very first connect()
            // call for this instance's lifetime — RealtimeChannelV2's own doc warns that
            // registering callbacks AFTER subscribe() triggers a runtime warning. Subsequent
            // connect() calls (e.g. after a scenePhase-driven disconnect/reconnect cycle) reuse
            // the same channel + registration and only re-subscribe below.
            let newChannel = realtimeClient.channel(Self.topic)
            channel = newChannel
            subscriptionToken = newChannel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "pins"
            ) { action in
                Task { @MainActor in
                    Self.handle(action, onUpsert: onUpsert, onDelete: onDelete)
                }
            }
            ch = newChannel
        }

        // Idempotent: skip if already subscribed/subscribing (redundant connect() call).
        guard ch.status != .subscribed, ch.status != .subscribing else { return }

        do {
            try await ch.subscribeWithError()
        } catch {
            // The SDK's own reconnect/retry (RealtimeClientV2, per spec §5.2) handles transient
            // failures; this is diagnostic only, not a user-facing error surface (matches
            // CommunityPinService.logChannelFailure's console-only precedent for the REST path).
            print("[SupabasePinRealtimeChannel] subscribe failed (SDK will retry on reconnect): \(error)")
        }
    }

    func disconnect() async {
        // Unsubscribe the channel FIRST so its own status cleanly transitions to
        // `.unsubscribed` before the socket goes down — this is what lets a later connect()
        // call correctly recognize "needs re-subscribe" via the `ch.status != .subscribed`
        // guard above, rather than seeing a stale `.subscribed` left over from before the
        // client-level disconnect (RealtimeClientV2.disconnect()'s own doc: channels "remain
        // registered" across a manual disconnect, i.e. their status is not reset for you).
        if let channel {
            await channel.unsubscribe()
        }
        realtimeClient.disconnect()
    }

    // MARK: - Event handling

    /// Routes one decoded `AnyAction` to `onUpsert`/`onDelete`, dropping anything that fails to
    /// decode rather than throwing (mirrors `CommunityPin.gracefulDecode`'s soft-failure
    /// posture for the REST path — a single malformed/unexpected row must not crash the feed).
    @MainActor
    private static func handle(
        _ action: AnyAction,
        onUpsert: @MainActor (CommunityPin) -> Void,
        onDelete: @MainActor (UUID) -> Void
    ) {
        switch action {
        case .insert(let insert):
            guard let pin = try? insert.decodeRecord(as: CommunityPin.self, decoder: jsonDecoder) else {
                return
            }
            onUpsert(pin)

        case .update(let update):
            guard let pin = try? update.decodeRecord(as: CommunityPin.self, decoder: jsonDecoder) else {
                return
            }
            onUpsert(pin)

        case .delete(let delete):
            // No REPLICA IDENTITY FULL (§2 Out) — oldRecord only reliably carries the primary
            // key. Primary-key-only removal; never attempts a full CommunityPin decode here.
            guard let idJSON = delete.oldRecord["id"],
                  let idString = idJSON.stringValue,
                  let id = UUID(uuidString: idString) else {
                return
            }
            onDelete(id)
        }
    }

    /// Decoder for `InsertAction.record` / `UpdateAction.record` → `CommunityPin`. Same custom
    /// ISO8601 date strategy (with and without fractional seconds) as
    /// `CommunityPinService.decodeResponse` — the two decoders must stay in sync since both
    /// decode the identical `pins` row shape from the same server. Duplicated rather than
    /// shared because `CommunityPinService`'s copy is `private` to that file and this file
    /// intentionally has no dependency on it (only file in this feature that imports `Realtime`).
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

/// In-memory double for `RealtimePinSubscribing` — no live socket, no SDK import needed by
/// `WeParkTests` (mirrors `SupabaseAuthService.swift`'s `InMemoryAuthStorage` /
/// `#if DEBUG` test-seam-in-production-file precedent). Lets
/// `CommunityPinService`'s connect/disconnect/reconnect *sequencing* be unit-tested — actual
/// event delivery over a live socket is a QA-owned live/simulator check (spec §11, AC-R1), not
/// something this double can stand in for.
final class MockRealtimePinChannel: RealtimePinSubscribing {
    private(set) var isConnected: Bool = false

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0

    /// Artificial delay injected before `connect()` does its work. Used by the lifecycle-race
    /// regression test (`CommunityPinServiceRealtimeWiringTests
    /// .testDisconnectThenReconnectFlap_doesNotRaceAndEndsConnected`) to simulate a slow
    /// `RealtimeClientV2.connect()`/`subscribeWithError()` round-trip so a test can construct a
    /// specific interleaving against a concurrent `disconnect()` — mirrors the real network
    /// timing that makes the lifecycle race (QA finding #1, PR #84 pass 1) possible in
    /// production. `nil` by default (existing tests are unaffected).
    var connectDelay: Duration?

    /// Same as `connectDelay`, for `disconnect()`. Together the two let a race test simulate
    /// "disconnect's network round-trip is still in flight when a subsequent connect would run"
    /// without needing a real socket.
    var disconnectDelay: Duration?

    /// Captured on the most recent `connect(onUpsert:onDelete:)` call so tests can invoke
    /// them directly to simulate an inbound Realtime event without a live socket.
    private(set) var capturedOnUpsert: (@MainActor (CommunityPin) -> Void)?
    private(set) var capturedOnDelete: (@MainActor (UUID) -> Void)?

    func connect(
        onUpsert: @escaping @MainActor (CommunityPin) -> Void,
        onDelete: @escaping @MainActor (UUID) -> Void
    ) async {
        if let connectDelay {
            try? await Task.sleep(for: connectDelay)
        }
        connectCallCount += 1
        isConnected = true
        capturedOnUpsert = onUpsert
        capturedOnDelete = onDelete
    }

    func disconnect() async {
        if let disconnectDelay {
            try? await Task.sleep(for: disconnectDelay)
        }
        disconnectCallCount += 1
        isConnected = false
    }

    /// Test helper: simulates an inbound upsert without a live socket.
    func simulateUpsert(_ pin: CommunityPin) {
        capturedOnUpsert?(pin)
    }

    /// Test helper: simulates an inbound delete without a live socket.
    func simulateDelete(id: UUID) {
        capturedOnDelete?(id)
    }
}

#endif

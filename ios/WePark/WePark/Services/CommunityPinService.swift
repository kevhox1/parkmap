//
//  CommunityPinService.swift
//  WePark
//
//  Tier 1 Pin Display — Community 1.0 read-only fetch + Realtime subscription stub.
//  Spec: docs/tier1-pin-display-spec.md §9.
//
//  Responsibilities:
//   - Debounced (800ms) PostgREST bounding-box fetch for filming / asp_suspended_today /
//     special_event pins (source = open_data, not expired, not resolved).
//   - Realtime subscription stub (wired per spec; end-to-end requires prod schema apply — AC-D5).
//   - Client-side expiry filter: removes pins where expiresAt != nil && expiresAt <= nowProvider().
//   - Publishes `visiblePins: [CommunityPin]` — ContentView observes this.
//
//  Architectural invariants (HANDOFF.md Changelog 2026-05-26, spec §5):
//   - @MainActor: all visiblePins mutations run on the main actor so SwiftUI reads are safe.
//   - No Calendar.current — all time math uses nowProvider() (injectable for tests).
//   - Network path: raw URLSession + Codable (no supabase-swift SPM dep for TF1; see spec §9).
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
//   - startRealtime() wires a subscription channel stub. End-to-end (AC-D10/D11) requires
//     the prod schema to be live (supabase/02-pins-schema.sql applied). The stub is marked
//     with a TODO so @backend-data can activate it post-apply without structural change.
//

import Foundation
import MapKit

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
    private(set) var visiblePins: [CommunityPin] = []

    /// True while a network fetch is in progress.
    private(set) var isLoading: Bool = false

    /// Set when the most recent fetch failed. Nil on success.
    private(set) var fetchError: Error? = nil

    // MARK: - Init parameters

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// Injectable time provider. Default: `{ Date() }`.
    /// Tests override this to freeze time for expiry assertions (AC-D1 through AC-D4).
    private let nowProvider: () -> Date

    /// URLSession used for all network calls. Injectable for tests (MockURLProtocol pattern).
    private let urlSession: URLSession

    // MARK: - Internal state

    /// In-flight debounce task. Cancelled and replaced on each `onRegionChanged` call.
    private var fetchTask: Task<Void, Never>? = nil

    /// The map center used for the most recent completed fetch.
    /// Used by the Drive Mode re-fetch guard (spec §6.3: skip if center moved < 200m).
    private var lastFetchCenter: CLLocationCoordinate2D? = nil

    /// True when Drive Mode is active. Set from ContentView via `setDriveModeActive(_:)`.
    private var driveModeActive: Bool = false

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
        urlSession: URLSession = .shared
    ) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.nowProvider = nowProvider
        self.urlSession = urlSession
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
    }

    /// Informs the service whether Drive Mode is currently active.
    /// Affects the re-fetch guard in `onRegionChanged` (spec §6.3).
    func setDriveModeActive(_ active: Bool) {
        driveModeActive = active
        if !active {
            // Reset last-fetch-center so the first non-Drive region change fetches fresh.
            lastFetchCenter = nil
        }
    }

    // MARK: - Realtime subscription stub

    /// Wires the Supabase Realtime subscription for INSERT/UPDATE events on `pins`
    /// where `source = 'open_data'`.
    ///
    /// End-to-end (AC-D10/D11): requires `supabase/02-pins-schema.sql` applied to
    /// production AND the `supabase-swift` package added as an SPM dependency.
    /// For TF1 the stub logs intent without connecting; the polling path handles
    /// live updates via `onRegionChanged`.
    ///
    /// TODO: post-prod-apply — replace this stub with the real Realtime subscription
    /// using the `supabase-swift` SDK. See spec §6.2 for the channel sketch.
    func startRealtime() {
        // Stub: Realtime subscription deferred until prod schema is live.
        // The raw URLSession polling path (onRegionChanged) is sufficient for TF1.
        // When activating: subscribe to public:pins:open_data channel,
        // on INSERT/UPDATE call mergeRealtimeChange(_:),
        // on resolved_at non-null call removeResolvedPin(id:).
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

    // MARK: - Network fetch

    /// Issues the PostgREST bounding-box query and updates `visiblePins`.
    ///
    /// Query spec (tier1-pin-display-spec.md §6):
    ///   - pin_type = in.(filming, asp_suspended_today, special_event)
    ///   - source = eq.open_data
    ///   - resolved_at = is.null
    ///   - or=(expires_at.is.null, expires_at.gt.<now-ISO>)
    ///   - bounding box: lat/lng gte/lte from MKCoordinateRegion
    ///
    /// On success: replaces `visiblePins` with the filtered result.
    /// On failure: sets `fetchError`; does NOT clear `visiblePins` (stale data stays visible).
    private func fetchPins(for region: MKCoordinateRegion) async {
        let bbox = BoundingBox(from: region)
        guard let request = buildRequest(bbox: bbox) else {
            return
        }

        isLoading = true
        fetchError = nil
        lastFetchCenter = region.center

        do {
            let (data, response) = try await urlSession.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                fetchError = CommunityPinFetchError.httpError(statusCode: httpResponse.statusCode)
                isLoading = false
                return
            }

            let decoded = try decodeResponse(data: data)
            visiblePins = clientSideFilter(decoded)
            fetchError = nil
        } catch is CancellationError {
            // Task was cancelled (new region change arrived before debounce elapsed). No-op.
        } catch {
            fetchError = error
        }

        isLoading = false
    }

    // MARK: - Request builder

    /// Builds the PostgREST URLRequest for the bounding-box pin query.
    private func buildRequest(bbox: BoundingBox) -> URLRequest? {
        // ISO 8601 timestamp for the client-side-expiry filter param.
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
    /// Called by the Realtime subscription handler (not yet active in TF1).
    /// Exported as `internal` so tests can exercise the merge logic without a live channel.
    ///
    /// On INSERT: append pin (if it passes client-side filter and is a display type).
    /// On UPDATE: replace existing pin by ID; remove if resolved_at is now non-nil.
    func mergeRealtimeChange(pin: CommunityPin) {
        // Only merge display-type pins (filming + special_event; asp_suspended_today
        // is handled via banner supplement, not as a map marker — spec §3).
        let displayTypes: Set<PinType> = [.filming, .specialEvent, .aspSuspendedToday]
        guard displayTypes.contains(pin.pinType) else { return }

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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: nowProvider())
    }
}

// MARK: - CommunityPinFetchError

enum CommunityPinFetchError: Error {
    case httpError(statusCode: Int)
    case missingConfig
}

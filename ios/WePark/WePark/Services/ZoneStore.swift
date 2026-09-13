//
//  ZoneStore.swift
//  WePark
//
//  Community 2.0 S14 — fetch-at-launch zone list, replacing the compiled-in three-zone lookup
//  table that used to live in `Services/` (retired this session) now that `public.zones` is
//  growing from 3 rows to 41 (`docs/community-2.0-manhattan-zones.md`,
//  `supabase/06-manhattan-zones.sql`). Spec: `docs/community-2.0-s14-execution-spec.md`.
//
//  Mirrors `Services/ZoneMessageService.swift`'s house shape exactly — `@MainActor
//  @Observable`, raw `URLSession` + `Codable`, no supabase-swift PostgREST client, manual
//  `CodingKeys` (on `Zone` itself), no `Authorization` header since `zones_select_all` is
//  `using (true)` (AC-D21 precedent, same as every other anonymous-read path in this codebase).
//
//  ⚠️ Load-bearing (spec §3.1): `loadZonesIfNeeded()` is called UNCONDITIONALLY from
//  `ContentView.performLaunchSetup()` — NOT gated behind `AppConstants.communityEnabled`.
//  `CommunityPinService.resolveZoneId`'s write-time zone stamping runs today, in production,
//  for every crowd report any external user submits, flag on or off (`insertCrowdPin` predates
//  Community 2.0 and isn't itself behind the flag). Gating this fetch behind the flag would
//  silently regress that already-shipping write path back to zero zone coverage for flag-off
//  users. The picker/feed UI (`Views/CrewFeedSection.swift`) stays fully flag-gated as before —
//  only the underlying fetch must not be.
//
//  This file also holds the three pure, view-free helper types the picker and the write-time/
//  display-time zone lookups all share:
//   - `ZoneGeometry` — point-in-zone / zone-by-id lookups against an explicit `zones: [Zone]`
//     list, replacing the retired compiled table's own `zoneId(forLat:lng:)`/`box(for:)`.
//     Smallest-matching-box wins when a point falls inside more than one zone
//     (`docs/community-2.0-manhattan-zones.md`'s documented overlap seams — never mattered at
//     3 non-overlapping zones, load-bearing at 41).
//   - `ZoneOrdering` — nearest-first ordering + the chip-row visibility window, backing
//     `CrewFeedSection`'s picker.
//   - `ZoneSelectionDefaulting` — keeps a still-valid zone-chip selection across a fresh
//     fetch, or picks a sane default when there is none yet.
//
//  COMPILE-UNVERIFIED — written on a Linux VPS, no Xcode/Swift toolchain. A Mac
//  `xcodebuild build`+`test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  No Calendar.current. No hardcoded Mapbox tokens or Supabase keys.
//

import Foundation

// MARK: - ZoneGeometry

/// Pure point-in-zone / zone-by-id lookups against an explicit `zones: [Zone]` list — the
/// direct replacement for the retired compiled zone-bounds table's own lookup functions.
/// `nonisolated` (no actor context, no mutable state) — safe from any isolation context,
/// including `CommunityPinService`'s `@MainActor` write path and plain unit tests.
enum ZoneGeometry {
    /// Returns the zone id whose bounding box contains `(lat, lng)`, or `nil` if none does.
    ///
    /// Smallest-matching-box wins when a point falls inside more than one zone — the documented
    /// tie-break for the `docs/community-2.0-manhattan-zones.md`-flagged overlaps (nolita/noho,
    /// west-village/chelsea, etc.). Never mattered at 3 non-overlapping zones; load-bearing at
    /// 41.
    nonisolated static func zoneId(forLat lat: Double, lng: Double, in zones: [Zone]) -> String? {
        zones.filter { $0.contains(lat: lat, lng: lng) }.min { $0.areaApprox < $1.areaApprox }?.id
    }

    /// Returns the zone matching `zoneId`, or `nil` if no zone in `zones` carries that id (e.g.
    /// the retired `soho-les` id, a typo, or an id that's since dropped out of the fetched
    /// list).
    nonisolated static func box(for zoneId: String, in zones: [Zone]) -> Zone? {
        zones.first { $0.id == zoneId }
    }
}

// MARK: - ZoneOrdering

/// Pure nearest-first ordering + chip-row visibility window backing `CrewFeedSection`'s picker
/// (spec §3.4). `nonisolated` throughout (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
/// — pure functions, no actor-isolated state, directly callable from a plain synchronous
/// `XCTestCase` without `await`.
enum ZoneOrdering {
    /// Earth radius in meters — same constant this codebase's other haversine helpers use
    /// (`CandidateSegmentSearch.haversine`, `LocationService.haversineMeters`), duplicated here
    /// per this codebase's file-independence convention rather than shared.
    private static let earthRadiusMeters = 6_371_000.0

    private nonisolated static func haversineMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let radLat1 = lat1 * .pi / 180.0
        let radLat2 = lat2 * .pi / 180.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLng = (lng2 - lng1) * .pi / 180.0

        let sinDLat = sin(dLat / 2)
        let sinDLng = sin(dLng / 2)
        let h = sinDLat * sinDLat + cos(radLat1) * cos(radLat2) * sinDLng * sinDLng
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadiusMeters * c
    }

    /// Distance from `(lat, lng)` to a zone's box — 0 if inside, else the distance to the
    /// nearest clamped edge point (not the centroid — more honest for large/elongated zones
    /// like `les`/`hells-kitchen`, per `docs/community-2.0-manhattan-zones.md`'s own sizing
    /// notes on those two).
    nonisolated static func distanceMeters(fromLat lat: Double, lng: Double, to zone: Zone) -> Double {
        let clampedLat = min(max(lat, zone.latMin), zone.latMax)
        let clampedLng = min(max(lng, zone.lngMin), zone.lngMax)
        return haversineMeters(lat1: lat, lng1: lng, lat2: clampedLat, lng2: clampedLng)
    }

    /// Home zone (if resolvable and present in `zones`) pinned first, unconditionally — not
    /// merely a distance-0 tie, an explicit rule, so float/overlap edge cases never bury it.
    /// Remaining zones ascending by distance; ties (multiple containing boxes, no home zone
    /// set) broken by ascending area — smallest/most-specific first, same rationale as
    /// `ZoneGeometry.zoneId`'s containment tie-break. No origin at all (no car, no device
    /// location) falls back to alphabetical by name — a stable order, never raw fetch-order id
    /// soup.
    nonisolated static func orderedZones(
        zones: [Zone],
        homeZoneId: String?,
        originLat: Double?,
        originLng: Double?
    ) -> [Zone] {
        var sorted: [Zone]
        if let originLat, let originLng {
            sorted = zones.sorted { a, b in
                let da = distanceMeters(fromLat: originLat, lng: originLng, to: a)
                let db = distanceMeters(fromLat: originLat, lng: originLng, to: b)
                if da != db { return da < db }
                return a.areaApprox < b.areaApprox
            }
        } else {
            sorted = zones.sorted { $0.name < $1.name }
        }

        if let homeZoneId, let homeIndex = sorted.firstIndex(where: { $0.id == homeZoneId }) {
            let home = sorted.remove(at: homeIndex)
            sorted.insert(home, at: 0)
        }
        return sorted
    }

    /// The chip row always shows the `limit` nearest zones PLUS the currently-selected zone
    /// even if it fell outside that window (a user who picked something far away from the
    /// overflow sheet must still see it highlighted in the row, not silently
    /// un-selected-looking).
    nonisolated static func visibleChipZones(ordered: [Zone], selectedZoneId: String?, limit: Int) -> [Zone] {
        var visible = Array(ordered.prefix(limit))
        if let selectedZoneId,
           !visible.contains(where: { $0.id == selectedZoneId }),
           let selected = ordered.first(where: { $0.id == selectedZoneId }) {
            visible.append(selected)
        }
        return visible
    }
}

// MARK: - ZoneSelectionDefaulting

/// Pure "what should the picker's selection be right now" decision — keeps a still-valid
/// selection when possible, so a fetch completing (or a fresh view mount reading an
/// already-cached list) never yanks a user's current zone-chip choice out from under them.
/// `nonisolated` (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — pure, no actor state.
enum ZoneSelectionDefaulting {
    /// - Parameters:
    ///   - currentSelection: The picker's current selection, or `nil` if none yet.
    ///   - orderedZones: `ZoneOrdering.orderedZones(...)`'s output for the current
    ///     origin/home-zone state.
    /// - Returns: `currentSelection` unchanged if it's still present in `orderedZones`;
    ///   otherwise `orderedZones.first?.id` (nearest/home zone, or `nil` when `orderedZones`
    ///   is empty — e.g. a first-launch-and-offline cold start with no cached zones yet).
    nonisolated static func defaultSelection(currentSelection: String?, orderedZones: [Zone]) -> String? {
        if let currentSelection, orderedZones.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }
        return orderedZones.first?.id
    }
}

// MARK: - ZoneFetchError

/// Errors from `ZoneStore.fetchZones()`.
enum ZoneFetchError: Error {
    /// The server responded with a non-2xx status.
    case httpError(statusCode: Int)
}

// MARK: - ZoneStore

/// Fetch-at-launch zone list + on-disk cache fallback. See this file's header for the
/// unconditional-fetch invariant this type's one production consumer
/// (`ContentView.performLaunchSetup()`) must honor.
///
/// All state mutations run on `@MainActor` so `zones` can be observed safely from SwiftUI
/// without additional dispatch — same invariant as `CommunityPinService`/`ZoneMessageService`.
@MainActor
@Observable
final class ZoneStore {

    // MARK: - Published state

    private(set) var zones: [Zone] = []

    /// True while a network fetch is in progress.
    private(set) var isLoading = false

    /// Set when the most recent fetch failed. `nil` on success. `zones` is left at whatever it
    /// was before the failed attempt (cache-seeded or empty) — same "fail soft, don't blank
    /// what's already known" posture as `CommunityPinService.resolveChannelPins`/
    /// `ZoneMessageService.fetchMessages`.
    private(set) var fetchError: Error? = nil

    /// `UserDefaults.standard` key for the on-disk cache — plain device-local storage, no
    /// iCloud sync (zones aren't per-user state, no cross-device concern). Not `private`: tests
    /// exercise the cache round-trip directly against this same key.
    nonisolated static let cacheKey = "wepark_zones_cache_v1"

    /// The pre-2026-08-26 legacy id (`03-community-2.0-schema.sql`'s archived row) — never
    /// shown in any picker UI, filtered both server-side (the fetch's own `id=not.eq.soho-les`
    /// query param) and client-side here (belt-and-braces, mirrors `CrewFeedMerge.merge`'s own
    /// precedent of re-filtering data that's already supposed to be scoped by the query).
    static let retiredZoneId = "soho-les"

    // MARK: - Init parameters

    private let supabaseURL: URL
    private let supabaseAnonKey: String

    /// URLSession used for all network calls. Injectable for tests (MockURLProtocol pattern).
    let urlSession: URLSession

    /// `UserDefaults` instance used for the on-disk cache. Injectable so tests can pass an
    /// ephemeral suite instead of polluting `UserDefaults.standard` — mirrors
    /// `GarageSavingsService.init(defaults:)`'s own test-injection convention. Production
    /// default: `.standard` (unchanged behavior — same key, same round-trip semantics).
    ///
    /// Load-bearing for test isolation specifically because `ZoneStore.loadZonesIfNeeded()`
    /// runs UNCONDITIONALLY from `ContentView.performLaunchSetup()` (this file's own header):
    /// the unit test target runs inside the WePark host app, so without this injection point
    /// the host app's own real launch-time fetch writes into `UserDefaults.standard` under
    /// `cacheKey` concurrently with — or before — any test that asserts "no prior cache."
    private let defaults: UserDefaults

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - supabaseURL: The Supabase project URL. Read from `Info.plist` key `SUPABASE_URL` at
    ///     runtime in production.
    ///   - supabaseAnonKey: The anon/public API key. Read from `Info.plist` key
    ///     `SUPABASE_ANON_KEY` at runtime in production. NEVER hardcode this value in source.
    ///   - urlSession: Injectable URL session. Default `URLSession.shared`.
    ///   - defaults: Injectable `UserDefaults` for the on-disk cache. Default `.standard`.
    init(supabaseURL: URL, supabaseAnonKey: String, urlSession: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.urlSession = urlSession
        self.defaults = defaults
    }

    /// Convenience initializer that reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from
    /// `Bundle.main` (bridged from `Config.xcconfig` via `Info.plist`) — mirrors
    /// `ZoneMessageService`'s own convenience init exactly (same placeholder-URL fallback for
    /// pre-config builds). Does NOT itself trigger a fetch — `zones` stays empty until a caller
    /// explicitly awaits `loadZonesIfNeeded()`/`fetchZones()`. This is what lets this init be
    /// used as `CommunityPinService`'s defaulted `zoneStore:` parameter without any of that
    /// service's ~50 pre-existing test call sites accidentally touching the network.
    convenience init() {
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        let resolvedURL = URL(string: urlString) ?? URL(string: "https://placeholder.supabase.co")!
        self.init(supabaseURL: resolvedURL, supabaseAnonKey: key)
    }

    /// Test/preview-only convenience initializer — never touches the network. `zones` is seeded
    /// directly from `preloadedZones`; a caller that wants a live fetch on top of this must call
    /// `fetchZones()`/`loadZonesIfNeeded()` explicitly.
    convenience init(preloadedZones: [Zone]) {
        self.init(supabaseURL: URL(string: "https://placeholder.supabase.co")!, supabaseAnonKey: "")
        self.zones = preloadedZones
    }

    // MARK: - Fetch-at-launch entry point

    /// Called once from `ContentView.performLaunchSetup()` — see this file's header for why
    /// that call site must be unconditional, not gated behind `AppConstants.communityEnabled`.
    ///
    /// Seeds `zones` synchronously from the on-disk cache (if any) BEFORE the network attempt
    /// resolves, so a picker mounted mid-fetch never renders emptier than the last successful
    /// launch. Never refetched on foreground/scenePhase — the zone list itself only ever
    /// refreshes once per process lifetime, per `docs/community-2.0-manhattan-zones.md`'s
    /// explicit "fetched once at cold launch, not realtime" contract.
    func loadZonesIfNeeded() async {
        zones = Self.loadCache(defaults: defaults) ?? []
        await fetchZones()
    }

    // MARK: - Network fetch

    /// Fetches the current zone list, excluding the retired `soho-les` id. On success: replaces
    /// `zones` wholesale, persists the result to the on-disk cache, clears `fetchError`. On
    /// failure (non-2xx / network / decode error): sets `fetchError`, leaves `zones` at
    /// whatever `loadZonesIfNeeded()` seeded (cache or empty) — same fail-soft posture as
    /// `ZoneMessageService.fetchMessages`.
    func fetchZones() async {
        guard let request = buildFetchRequest() else { return }

        isLoading = true
        fetchError = nil

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw ZoneFetchError.httpError(statusCode: status)
            }
            let decoded = try JSONDecoder().decode([Zone].self, from: data)
            // Belt-and-braces: filter out "soho-les" BOTH via the query param below AND
            // client-side here (mirrors CrewFeedMerge.merge's precedent of re-filtering data
            // that's already supposed to be scoped by the query).
            let filtered = decoded.filter { $0.id != Self.retiredZoneId }
            zones = filtered
            Self.saveCache(filtered, defaults: defaults)
        } catch {
            fetchError = error
        }

        isLoading = false
    }

    /// Builds the PostgREST URLRequest for the zone-list fetch.
    ///
    /// Anonymous read — `zones_select_all` permits SELECT unconditionally (`using (true)`,
    /// `01-mvp-schema.sql:48-50`). No Authorization header, matching every other read path in
    /// this codebase (AC-D21 precedent).
    private func buildFetchRequest() -> URLRequest? {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/zones"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,name,lat_min,lat_max,lng_min,lng_max"),
            URLQueryItem(name: "order",  value: "id"),
            URLQueryItem(name: "id",     value: "not.eq.\(Self.retiredZoneId)"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - On-disk cache

    /// Not `private`: `ZoneStoreTests` exercises the cache round-trip (`saveCache` then
    /// `loadCache` returns an equal array) directly against this same key.
    /// `nonisolated` (with `saveCache`/`cacheKey`): pure UserDefaults+Codable I/O, no actor
    /// state — must stay synchronously callable from a plain `XCTestCase` (the build's
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise isolate these implicitly).
    ///
    /// `defaults` parameter defaults to `.standard` (unchanged production behavior/call
    /// shape) but lets tests pass an ephemeral suite instead — required because the unit test
    /// target runs inside the WePark host app, and this type's own unconditional launch-time
    /// fetch (this file's header) means the HOST APP writes real zones into
    /// `UserDefaults.standard` under `cacheKey` independently of, and possibly concurrently
    /// with, any test run. A "no prior cache" test asserting against `.standard` directly is
    /// therefore inherently flaky — isolating the storage, not just cleaning up after the
    /// fact, is the only deterministic fix (mirrors `GarageSavingsService.init(defaults:)`'s
    /// own test-injection convention for the identical class of problem).
    nonisolated static func loadCache(defaults: UserDefaults = .standard) -> [Zone]? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([Zone].self, from: data)
    }

    nonisolated static func saveCache(_ zones: [Zone], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(zones) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}

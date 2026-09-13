//
//  ZoneStoreTests.swift
//  WeParkTests
//
//  Community 2.0 S14 — wire-shape + cache tests for `Services/ZoneStore.swift`.
//  Spec: docs/community-2.0-s14-execution-spec.md §6 test plan, this repo's established
//  PostgREST-request-shape convention (`ZoneMessageServiceTests.testFetchMessages_
//  requestIncludesZoneIdFilter` / `testFetchMessages_noAuthorizationHeader_apiKeyPresent`).
//
//  Reuses `PinMockURLProtocol` (declared in `CommunityPinServiceTests.swift`, same test
//  target) rather than declaring a second URLProtocol mock class — same precedent
//  `ZoneMessageServiceTests.swift` already follows.
//
//  Mac-gate fix (post-PR-#108 review): the unit test target runs INSIDE the WePark host app,
//  and `ZoneStore.loadZonesIfNeeded()` runs UNCONDITIONALLY at that host app's own launch
//  (`ContentView.performLaunchSetup()`, this session's own spec-correct requirement) — so the
//  host app's real fetch writes into `UserDefaults.standard` under `ZoneStore.cacheKey`
//  before/during any test run, independent of and racing whatever this file does.
//  `tearDown`-only cleanup can't fix a "no prior cache" assertion (pollution PRECEDES the
//  first test), and `setUp` cleanup would still be flaky (the host's async fetch can complete
//  mid-suite). Every class below that touches the cache now injects an ephemeral `UserDefaults`
//  suite (mirrors `GarageSavingsServiceTests`' own identical-shaped fix for
//  `GarageSavingsService.init(defaults:)`) so this file is fully independent of the host app's
//  real cache — including the fetch-success-path classes (`ZoneStoreFetchRequestShapeTests`/
//  `ZoneStoreDecodeTests`), whose successful `fetchZones()` calls also write to the cache and
//  would otherwise silently pollute `UserDefaults.standard` with test fixture data.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (10 tests):
//    Fetch request shape:
//      1. testFetchZones_requestIncludesSelectOrderAndSohoLesExclusion
//      2. testFetchZones_noAuthorizationHeader_apiKeyPresent
//    Decode:
//      3. testFetchZones_threeRowFixture_decodesCorrectly
//      4. testFetchZones_fortyOneRowFixture_decodesCorrectly
//      5. testFetchZones_responseIncludingSohoLes_filteredClientSide
//    Failure handling:
//      6. testFetchZones_httpError_setsFetchError_leavesZonesUnchanged
//    Cache:
//      7. testCache_saveThenLoad_returnsEqualArray
//      8. testCache_loadWithNoPriorSave_returnsNil
//      9. testLoadZonesIfNeeded_failedFetch_noPriorCache_leavesZonesEmpty
//     10. testLoadZonesIfNeeded_failedFetch_withPriorCache_fallsBackToCachedList
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
@testable import WePark

private let kZoneStoreTestURL = URL(string: "https://zone-store-test.supabase.co")!
private let kZoneStoreAnonKey = "test-anon-key-zone-store"

private func zoneStoreJSON(id: String, name: String, latMin: Double, latMax: Double, lngMin: Double, lngMax: Double) -> String {
    """
    {"id": "\(id)", "name": "\(name)", "lat_min": \(latMin), "lat_max": \(latMax), "lng_min": \(lngMin), "lng_max": \(lngMax)}
    """
}

private func zoneStoreArrayJSON(_ rows: [String]) -> Data {
    Data(("[" + rows.joined(separator: ",") + "]").utf8)
}

@MainActor
final class ZoneStoreFetchRequestShapeTests: XCTestCase {

    private let suiteName = "com.wepark.test.zonestore.fetchrequestshape"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneStore {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneStore(supabaseURL: kZoneStoreTestURL, supabaseAnonKey: kZoneStoreAnonKey, urlSession: session, defaults: defaults)
    }

    func testFetchZones_requestIncludesSelectOrderAndSohoLesExclusion() async {
        var capturedURL: URL?
        let store = makeStore { request in
            capturedURL = request.url
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        await store.fetchZones()

        let query = capturedURL?.query ?? ""
        XCTAssertTrue(query.contains("select=id,name,lat_min,lat_max,lng_min,lng_max"), "Got: \(query)")
        XCTAssertTrue(query.contains("order=id"), "Got: \(query)")
        XCTAssertTrue(query.contains("id=not.eq.soho-les"), "Got: \(query)")
        XCTAssertTrue(capturedURL?.path.contains("rest/v1/zones") ?? false)
    }

    func testFetchZones_noAuthorizationHeader_apiKeyPresent() async {
        var capturedRequest: URLRequest?
        let store = makeStore { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        await store.fetchZones()

        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "zones_select_all permits anonymous read — no Authorization header (AC-D21 precedent)")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "apikey"), kZoneStoreAnonKey)
    }
}

@MainActor
final class ZoneStoreDecodeTests: XCTestCase {

    private let suiteName = "com.wepark.test.zonestore.decode"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneStore {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneStore(supabaseURL: kZoneStoreTestURL, supabaseAnonKey: kZoneStoreAnonKey, urlSession: session, defaults: defaults)
    }

    func testFetchZones_threeRowFixture_decodesCorrectly() async {
        let body = zoneStoreArrayJSON([
            zoneStoreJSON(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930),
            zoneStoreJSON(id: "soho", name: "SoHo", latMin: 40.7220, latMax: 40.7237, lngMin: -74.0050, lngMax: -73.9970),
            zoneStoreJSON(id: "les", name: "LES", latMin: 40.7145, latMax: 40.7230, lngMin: -73.9920, lngMax: -73.9800),
        ])
        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.fetchZones()

        XCTAssertEqual(store.zones.count, 3)
        XCTAssertEqual(store.zones.map(\.id).sorted(), ["les", "nolita", "soho"])
        XCTAssertNil(store.fetchError)
    }

    /// Post-migration shape sanity check — the fetch/decode path is generic over row count, no
    /// client change required to move from 3 to 41 rows (spec §3.5's pre/post matrix).
    func testFetchZones_fortyOneRowFixture_decodesCorrectly() async {
        let rows = (1...41).map { i in
            zoneStoreJSON(id: "zone-\(i)", name: "Zone \(i)", latMin: 40.70, latMax: 40.71, lngMin: -74.00, lngMax: -73.99)
        }
        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, zoneStoreArrayJSON(rows))
        }
        await store.fetchZones()

        XCTAssertEqual(store.zones.count, 41)
    }

    /// Belt-and-braces client-side filter: even if a test server response includes the retired
    /// `soho-les` id (e.g. the query param were ever dropped by mistake), it must never survive
    /// into `zones`.
    func testFetchZones_responseIncludingSohoLes_filteredClientSide() async {
        let body = zoneStoreArrayJSON([
            zoneStoreJSON(id: "soho-les", name: "SoHo-LES (legacy)", latMin: 40.71, latMax: 40.72, lngMin: -74.00, lngMax: -73.99),
            zoneStoreJSON(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930),
        ])
        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.fetchZones()

        XCTAssertFalse(store.zones.contains { $0.id == "soho-les" })
        XCTAssertEqual(store.zones.count, 1)
    }

    func testFetchZones_httpError_setsFetchError_leavesZonesUnchanged() async {
        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.fetchZones()

        XCTAssertNotNil(store.fetchError)
        XCTAssertTrue(store.zones.isEmpty)
    }
}

final class ZoneStoreCacheTests: XCTestCase {

    private let suiteName = "com.wepark.test.zonestore.cache"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCache_saveThenLoad_returnsEqualArray() {
        let zones = [
            Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930),
            Zone(id: "soho", name: "SoHo", latMin: 40.7220, latMax: 40.7237, lngMin: -74.0050, lngMax: -73.9970),
        ]
        ZoneStore.saveCache(zones, defaults: defaults)
        XCTAssertEqual(ZoneStore.loadCache(defaults: defaults), zones)
    }

    /// Isolated suite, cleared in `setUp` — genuinely no prior save, unlike asserting directly
    /// against `UserDefaults.standard` (which the host app's own unconditional launch-time
    /// fetch may have already written into).
    func testCache_loadWithNoPriorSave_returnsNil() {
        XCTAssertNil(ZoneStore.loadCache(defaults: defaults))
    }
}

@MainActor
final class ZoneStoreLoadZonesIfNeededTests: XCTestCase {

    private let suiteName = "com.wepark.test.zonestore.loadzonesifneeded"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneStore {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneStore(supabaseURL: kZoneStoreTestURL, supabaseAnonKey: kZoneStoreAnonKey, urlSession: session, defaults: defaults)
    }

    /// First-launch-and-offline edge case (AC): no prior cache, fetch fails → `zones == []`,
    /// nothing crashes.
    func testLoadZonesIfNeeded_failedFetch_noPriorCache_leavesZonesEmpty() async {
        XCTAssertNil(ZoneStore.loadCache(defaults: defaults), "precondition: no prior cache")
        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.loadZonesIfNeeded()
        XCTAssertTrue(store.zones.isEmpty)
        XCTAssertNotNil(store.fetchError)
    }

    /// A failed fetch WITH a prior successful cache falls back to the cached list, not an
    /// empty one.
    func testLoadZonesIfNeeded_failedFetch_withPriorCache_fallsBackToCachedList() async {
        let cached = [Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930)]
        ZoneStore.saveCache(cached, defaults: defaults)

        let store = makeStore { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.loadZonesIfNeeded()

        XCTAssertEqual(store.zones, cached)
        XCTAssertNotNil(store.fetchError)
    }
}

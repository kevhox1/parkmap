//
//  CommunityPinServiceTests.swift
//  WeParkTests
//
//  Community 1.0 Tier 1 Pin Display — fixture-driven unit tests.
//  Spec: docs/tier1-pin-display-spec.md §11 (AC-D1 through AC-D9d).
//
//  Test inventory (38 tests):
//
//  Client-side filter — expiry (4 tests, AC-D1 through AC-D4):
//    1.  testClientSideFilter_expiredPin_removed              (AC-D1)
//    2.  testClientSideFilter_nilExpiry_retained              (AC-D2)
//    3.  testClientSideFilter_futureExpiry_retained           (AC-D3)
//    4.  testClientSideFilter_resolvedPin_removed             (AC-D4)
//
//  Fetch path — request structure (5 tests, AC-D6 + Bug #1):
//    5.  testFetchRequest_includesOpenDataSourceFilter        (AC-D6)
//    6.  testFetchRequest_includesCrowdEphemeralChannel       (Bug #1)
//    7.  testFetchRequest_crowdChannel_includesResolvedAtIsNull (Bug #1)
//    8.  testBuildRequest_noAuthorizationHeader               (AC-D21)
//    9.  testBuildRequest_apiKeyHeader_present
//
//  Debounce — two rapid calls fire only one fetch (1 test, AC-D7):
//   10.  testDebounce_twoRapidCalls_firesOneFetch             (AC-D7)
//
//  Map marker filter — asp_suspended_today excluded (1 test, AC-D8):
//   11.  testMapMarkerFilter_aspSuspendedToday_excluded       (AC-D8)
//
//  ASP banner supplement — resolvedBannerState (4 tests, AC-D9a through AC-D9d):
//   12.  testResolvedBannerState_aspPinToday_bundleInEffect_returnsSuspended  (AC-D9a)
//   13.  testResolvedBannerState_bundleAlreadySuspended_noOverride            (AC-D9b)
//   14.  testResolvedBannerState_noPins_returnsBundle                         (AC-D9c)
//   15.  testResolvedBannerState_expiredPin_noOverride                        (AC-D9d)
//
//  Realtime merge — mergeRealtimeChange (5 tests):
//   16.  testMergeRealtimeChange_newFilmingPin_appended
//   17.  testMergeRealtimeChange_resolvedPin_removed
//   18.  testMergeRealtimeChange_expiredPin_removed
//   19.  testMergeRealtimeChange_aspPin_notAddedAsMarker_but_available_in_visiblePins
//   20.  testMergeRealtimeChange_updateExistingPin
//
//  Bug #1: crowd pin optimistic-append tests (3 tests):
//   21.  testMergeRealtimeChange_enforcementActive_crowdPin_appended
//   22.  testMergeRealtimeChange_sweeperPassed_crowdPin_appended
//   23.  testMergeRealtimeChange_resolvedCrowdPin_removed
//
//  Bug #4: ReportSheet.locationContextLabel (4 tests):
//   24.  testLocationContextLabel_withStreetName_returnsReportingOn
//   25.  testLocationContextLabel_nilStreetName_returnsFallback
//   26.  testLocationContextLabel_emptyStreetName_returnsFallback
//   27.  testLocationContextLabel_multiWordStreet_preservedExactly
//
//  Fixture injection (2 tests):
//   28.  testInject_replacesVisiblePins
//   29.  testInject_emptyArray_clearsVisiblePins
//
//  Per-channel failure isolation (4 tests, fix for docs/qa/ft15-b4-fetch-channel-qa.md
//  Finding #1 — one channel's non-2xx response must not discard the other channels'
//  fresh results, nor blank that channel's own previously-visible pins):
//   30.  testFetchPins_channel3Fails_channel1And2StillMergeFreshResults
//   31.  testFetchPins_channel3Fails_previouslyVisibleChannel3PinRetained
//   32.  testFetchPins_channel3Fails_expiredPreviouslyVisiblePinStillDropped
//   33.  testFetchPins_allChannelsSucceed_fetchErrorNil
//
//  URL request structure tests moved to CommunityPinServiceRequestTests (5 tests above).
//
//  Baseline: 280/0. After this suite: 280 + 13 + 4 (net new) = 297/0 (total).
//  (21 original tests → 5 request tests restructured + 3 crowd merge + 4 locationContextLabel
//  + 4 channel-isolation = 38 total)
//
//  FT-15 / TF2-15 Stream B4 (docs/ft15-tf215-temporary-block-restrictions-spec.md §12):
//  fetchPins now issues a 3rd concurrent request (crowd block-scoped, filming/construction).
//  The 5 request-structure tests + the debounce test above were updated in place
//  (expectedFulfillmentCount / fetchCount assertions: 2 → 3) rather than duplicated, since
//  they assert "how many requests fire per fetch", which is a property of ALL three
//  channels together, not something a per-channel test file should own. New Channel-3-
//  specific assertions (predicate shape, AC-C1/AC-C2, blockScopedRestriction lookup,
//  mergeableTypes widening, CommunityPin.isUpcoming/showsReactionsRow) live in
//  FT15B4Tests.swift, following the same separate-file-per-feature convention as
//  FT15ModelTests.swift (Stream B1).
//
//  Per-channel failure isolation fix (this revision, addressing QA pass 1 Finding #1):
//  fetchPins no longer aborts all three channels on one channel's failure. Each channel's
//  request/decode is attempted independently (fetchChannelOutcome); a failing channel
//  falls back to its own previously-visible pins (re-filtered for expiry) rather than an
//  empty array, so an unrelated channel's outage can never blank markers it has nothing
//  to do with. See CommunityPinServiceChannelIsolationTests below.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens or Supabase keys.
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Shared fixture helpers

private let kServiceURL = URL(string: "https://test.supabase.co")!
private let kAnonKey = "test-anon-key-not-real"

/// Fixed reference point for service filter tests (AC-D1 through AC-D4).
///
/// Using a fixed future epoch avoids lazy-init ordering issues and ensures
/// kPast < kNow < kFuture regardless of when tests run.
/// Chosen far in the future (~2027) so kFuture is always a future date in production.
private let kBase:   TimeInterval = 1_800_000_000   // 2027-01-15T00:40:00Z
private let kNow:    Date = Date(timeIntervalSince1970: kBase)
private let kPast:   Date = Date(timeIntervalSince1970: kBase - 1)      // 1 second before kNow
private let kFuture: Date = Date(timeIntervalSince1970: kBase + 3600)   // 1 hour after kNow

/// Builds a fixture `CommunityPin` with the given parameters.
private func makeFixturePin(
    id: UUID = UUID(),
    pinType: PinType = .filming,
    source: PinSource = .openData,
    expiresAt: Date? = kFuture,
    resolvedAt: Date? = nil,
    metaJSON: String? = nil
) -> CommunityPin {
    // Build JSON and decode — matches the production decode path exactly.
    let expiresValue: String
    if let e = expiresAt {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        expiresValue = #""\#(fmt.string(from: e))""#
    } else {
        expiresValue = "null"
    }
    let resolvedValue: String
    if let r = resolvedAt {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        resolvedValue = #""\#(fmt.string(from: r))""#
    } else {
        resolvedValue = "null"
    }

    let defaultMeta: String
    switch pinType {
    case .filming:
        defaultMeta = metaJSON ?? #"{ "permit_id": "NYC-TEST-001", "production_name": "Test Show", "film_office_url": null }"#
    case .aspSuspendedToday:
        defaultMeta = metaJSON ?? #"{ "suspension_date": "2026-06-01", "reason": "Test Holiday" }"#
    case .specialEvent:
        defaultMeta = metaJSON ?? #"{ "event_name": "Test Event", "event_type": "parade" }"#
    default:
        defaultMeta = metaJSON ?? "null"
    }

    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "\(source.rawValue)",
      "lifespan": "session",
      "lat": 40.7505,
      "lng": -73.9965,
      "segment_id": null,
      "zone_id": null,
      "author_id": null,
      "author_username": null,
      "created_at": "2026-06-01T10:00:00+00:00",
      "updated_at": "2026-06-01T10:00:00+00:00",
      "expires_at": \(expiresValue),
      "resolved_at": \(resolvedValue),
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": \(defaultMeta),
      "notes": null
    }
    """

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

    return try! decoder.decode(CommunityPin.self, from: Data(json.utf8))
}

// MARK: - Client-side filter tests (AC-D1 through AC-D4)

/// @MainActor: CommunityPinService is @MainActor @Observable.
@MainActor
final class CommunityPinServiceFilterTests: XCTestCase {

    // MARK: AC-D1: expired pin removed

    /// AC-D1: clientSideFilter removes a pin whose expiresAt is in the past.
    func testClientSideFilter_expiredPin_removed() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        // Pin expired 1 second before kNow.
        let expiredPin = makeFixturePin(expiresAt: kPast)
        let result = service.clientSideFilter([expiredPin])
        XCTAssertTrue(result.isEmpty,
            "AC-D1: pin with expiresAt <= now must be removed by clientSideFilter")
    }

    // MARK: AC-D2: nil expiry retained

    /// AC-D2: clientSideFilter retains a pin whose expiresAt is nil (durable pin).
    func testClientSideFilter_nilExpiry_retained() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let durablePin = makeFixturePin(expiresAt: nil)
        let result = service.clientSideFilter([durablePin])
        XCTAssertEqual(result.count, 1,
            "AC-D2: pin with nil expiresAt must be retained by clientSideFilter")
    }

    // MARK: AC-D3: future expiry retained

    /// AC-D3: clientSideFilter retains a pin whose expiresAt is in the future.
    func testClientSideFilter_futureExpiry_retained() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let futurePin = makeFixturePin(expiresAt: kFuture)
        let result = service.clientSideFilter([futurePin])
        XCTAssertEqual(result.count, 1,
            "AC-D3: pin with expiresAt > now must be retained by clientSideFilter")
    }

    // MARK: AC-D4: resolved pin removed

    /// AC-D4: clientSideFilter removes a pin whose resolvedAt is non-nil.
    func testClientSideFilter_resolvedPin_removed() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        // Resolved pin with future expiresAt — should still be removed (resolved takes priority).
        let resolvedPin = makeFixturePin(expiresAt: kFuture, resolvedAt: kNow)
        let result = service.clientSideFilter([resolvedPin])
        XCTAssertTrue(result.isEmpty,
            "AC-D4: pin with non-nil resolvedAt must be removed by clientSideFilter")
    }
}

// MARK: - Fetch path request structure tests (AC-D6 + Bug #1 crowd channel)

@MainActor
final class CommunityPinServiceRequestTests: XCTestCase {

    /// Helper: builds a mock session that captures ALL requests fired during a fetch.
    ///
    /// The fetch now issues three concurrent requests (open_data + crowd ephemeral +
    /// FT-15/TF2-15 crowd block-scoped). The handler is called once per request; we
    /// capture all URLs in an array.
    private func captureRequestsAndMakeService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (CommunityPinService, URLSession) {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow },
            urlSession: session
        )
        return (service, session)
    }

    // MARK: - AC-D6: open-data channel filter

    /// AC-D6: At least one of the two requests must include source=eq.open_data.
    ///
    /// Bug #1 fix context: the fetch now issues two parallel requests (Channel 1: open_data,
    /// Channel 2: crowd). This test verifies Channel 1 is still being sent correctly.
    func testFetchRequest_includesOpenDataSourceFilter() async throws {
        var capturedURLs: [String] = []
        // Both requests will call the handler. We need 2 fulfillments.
        let expectation = expectation(description: "all three fetches fire")
        // FT-15/TF2-15: fetchPins now issues 3 concurrent requests (open_data +
        // crowd ephemeral + crowd block-scoped), up from 2.
        expectation.expectedFulfillmentCount = 3

        let (service, _) = captureRequestsAndMakeService { request in
            capturedURLs.append(request.url?.absoluteString ?? "")
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        let hasOpenData = capturedURLs.contains { $0.contains("source=eq.open_data") }
        XCTAssertTrue(hasOpenData,
            "AC-D6: at least one request must include source=eq.open_data. Got: \(capturedURLs)")
    }

    // MARK: - Bug #1: crowd channel filter

    /// Bug #1 fix: the second request must include source=eq.crowd + lifespan=eq.ephemeral
    /// + pin_type in enforcement_active/sweeper_passed.
    ///
    /// This is the channel that was previously missing, causing crowd-reported pins to
    /// never appear on the map.
    func testFetchRequest_includesCrowdEphemeralChannel() async throws {
        var capturedURLs: [String] = []
        let expectation = expectation(description: "all three fetches fire")
        // FT-15/TF2-15: fetchPins now issues 3 concurrent requests (open_data +
        // crowd ephemeral + crowd block-scoped), up from 2.
        expectation.expectedFulfillmentCount = 3

        let (service, _) = captureRequestsAndMakeService { request in
            capturedURLs.append(request.url?.absoluteString ?? "")
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        let hasCrowdChannel = capturedURLs.contains { url in
            url.contains("source=eq.crowd") &&
            url.contains("lifespan=eq.ephemeral") &&
            url.contains("enforcement_active")
        }
        XCTAssertTrue(hasCrowdChannel,
            "Bug #1 fix: one request must include source=eq.crowd + lifespan=eq.ephemeral + enforcement_active. Got: \(capturedURLs)")
    }

    /// Bug #1 fix: the crowd channel request must include resolved_at=is.null so that
    /// 3-dispute-resolved pins are excluded from the response.
    func testFetchRequest_crowdChannel_includesResolvedAtIsNull() async throws {
        var capturedURLs: [String] = []
        let expectation = expectation(description: "all three fetches fire")
        // FT-15/TF2-15: fetchPins now issues 3 concurrent requests (open_data +
        // crowd ephemeral + crowd block-scoped), up from 2.
        expectation.expectedFulfillmentCount = 3

        let (service, _) = captureRequestsAndMakeService { request in
            capturedURLs.append(request.url?.absoluteString ?? "")
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        let crowdURL = capturedURLs.first { $0.contains("source=eq.crowd") }
        XCTAssertNotNil(crowdURL, "Crowd channel URL must be captured")
        XCTAssertTrue(crowdURL?.contains("resolved_at") == true && crowdURL?.contains("is.null") == true,
            "Crowd channel must include resolved_at=is.null to exclude 3-dispute-resolved pins. Got: \(crowdURL ?? "nil")")
    }

    // MARK: - AC-D6 companion: no Authorization header

    /// AC-D6 companion: requests must NOT include an Authorization header (anon-only read).
    func testBuildRequest_noAuthorizationHeader() async throws {
        var capturedRequests: [URLRequest] = []
        let expectation = expectation(description: "all three fetches fire")
        // FT-15/TF2-15: fetchPins now issues 3 concurrent requests (open_data +
        // crowd ephemeral + crowd block-scoped), up from 2.
        expectation.expectedFulfillmentCount = 3

        let (service, _) = captureRequestsAndMakeService { request in
            capturedRequests.append(request)
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        // None of the 3 requests should have an Authorization header (anon read path — AC-D21).
        for request in capturedRequests {
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertNil(authHeader,
                "AC-D21: fetch must NOT include an Authorization header for anon read. URL: \(request.url?.absoluteString ?? "")")
        }
    }

    // MARK: - apikey header present

    /// All 3 requests must include the apikey header (Supabase PostgREST requirement).
    func testBuildRequest_apiKeyHeader_present() async throws {
        var capturedRequests: [URLRequest] = []
        let expectation = expectation(description: "all three fetches fire")
        // FT-15/TF2-15: fetchPins now issues 3 concurrent requests (open_data +
        // crowd ephemeral + crowd block-scoped), up from 2.
        expectation.expectedFulfillmentCount = 3

        let (service, _) = captureRequestsAndMakeService { request in
            capturedRequests.append(request)
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        for request in capturedRequests {
            let apiKeyHeader = request.value(forHTTPHeaderField: "apikey")
            XCTAssertEqual(apiKeyHeader, kAnonKey,
                "All 3 requests must include apikey header. URL: \(request.url?.absoluteString ?? "")")
        }
    }
}

// MARK: - Debounce test (AC-D7)

@MainActor
final class CommunityPinServiceDebounceTests: XCTestCase {

    /// AC-D7: Two calls to onRegionChanged 200ms apart fire only ONE debounce window,
    /// resulting in exactly three network requests (one per channel: open_data + crowd
    /// ephemeral + FT-15/TF2-15 crowd block-scoped).
    ///
    /// The debounce collapses the two calls into one fetchPins invocation.
    /// fetchPins issues three concurrent requests (Channel 1 + Channel 2 + Channel 3).
    /// Expected total: 3 requests (not 6, which would happen if both onRegionChanged calls fetched).
    func testDebounce_twoRapidCalls_firesOneFetch() async {
        var fetchCount = 0
        PinMockURLProtocol.requestHandler = { request in
            fetchCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow },
            urlSession: session
        )

        let region1 = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let region2 = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.755, longitude: -73.985),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )

        // First call.
        service.onRegionChanged(region1)
        // Wait 200ms — still within the 800ms debounce window.
        try? await Task.sleep(for: .milliseconds(200))
        // Second call — should cancel the first debounce task.
        service.onRegionChanged(region2)

        // Wait 1.2s total (800ms debounce + 400ms buffer).
        try? await Task.sleep(for: .milliseconds(1200))

        // fetchPins issues 3 requests per debounced call (open_data + crowd ephemeral +
        // FT-15/TF2-15 crowd block-scoped channels).
        // Two rapid onRegionChanged calls that collapse to ONE fetch → 3 total requests.
        // If debounce fails and two fetches fire → 6 requests (the failure mode).
        XCTAssertEqual(fetchCount, 3,
            "AC-D7: two onRegionChanged calls 200ms apart must fire ONE debounced fetch " +
            "(= 3 requests: open_data + crowd ephemeral + crowd block-scoped)")
    }
}

// MARK: - Per-channel failure isolation tests (fix for QA Finding #1,
// docs/qa/ft15-b4-fetch-channel-qa.md)

/// Builds a raw PostgREST-shaped JSON array response body for a single pin, independent
/// of `makeFixturePin` (which decodes through `CommunityPin` directly rather than
/// producing a `Data` response body a mock `URLProtocol` handler can return).
private func channelPinResponseBody(
    id: UUID = UUID(),
    pinType: PinType,
    source: PinSource,
    lifespan: PinLifespan = .session,
    expiresAt: Date = kFuture
) -> Data {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    let json = """
    [{
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "\(source.rawValue)",
      "lifespan": "\(lifespan.rawValue)",
      "lat": 40.7505,
      "lng": -73.9965,
      "segment_id": null,
      "zone_id": null,
      "author_id": null,
      "author_username": null,
      "created_at": "2026-06-01T10:00:00+00:00",
      "updated_at": "2026-06-01T10:00:00+00:00",
      "expires_at": "\(fmt.string(from: expiresAt))",
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }]
    """
    return Data(json.utf8)
}

/// Verifies the per-channel failure isolation fix: `fetchPins` issues Channel 1
/// (open_data), Channel 2 (crowd ephemeral), and Channel 3 (crowd block-scoped)
/// independently, and one channel's non-2xx response must not discard the other two
/// channels' fresh results, nor blank out that channel's own previously-visible pins.
///
/// Channels are distinguished in the mock handler by URL substring: "asp_suspended_today"
/// (Channel 1 only), "enforcement_active" (Channel 2 only), "construction" (Channel 3 only,
/// via its `pin_type=in.(filming,construction)` filter — no other channel's URL contains
/// the literal string "construction").
@MainActor
final class CommunityPinServiceChannelIsolationTests: XCTestCase {

    private func makeIsolationService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> CommunityPinService {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow },
            urlSession: session
        )
    }

    private let testRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    /// Channel 3 (block-scoped) 400s; Channel 1 and Channel 2 return 200 with fresh pins.
    /// The fresh Channel 1/2 pins must still land in `visiblePins` — the pre-fix behavior
    /// discarded ALL three channels' results whenever any one of them failed.
    func testFetchPins_channel3Fails_channel1And2StillMergeFreshResults() async throws {
        let freshFilmingId = UUID()
        let freshEnforcementId = UUID()
        let expectation = expectation(description: "all three channels attempted")
        expectation.expectedFulfillmentCount = 3

        let service = makeIsolationService { request in
            let url = request.url?.absoluteString ?? ""
            defer { expectation.fulfill() }
            if url.contains("construction") {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data())
            } else if url.contains("asp_suspended_today") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        channelPinResponseBody(id: freshFilmingId, pinType: .filming, source: .openData))
            } else {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        channelPinResponseBody(id: freshEnforcementId, pinType: .enforcementActive, source: .crowd, lifespan: .ephemeral))
            }
        }

        service.onRegionChanged(testRegion)
        await fulfillment(of: [expectation], timeout: 2.5)
        // Give the @MainActor merge a beat to complete after the last await inside fetchPins.
        try await Task.sleep(for: .milliseconds(200))

        let ids = Set(service.visiblePins.map { $0.id })
        XCTAssertTrue(ids.contains(freshFilmingId),
            "Channel 1's fresh pin must merge into visiblePins even though Channel 3 failed")
        XCTAssertTrue(ids.contains(freshEnforcementId),
            "Channel 2's fresh pin must merge into visiblePins even though Channel 3 failed")
        XCTAssertNotNil(service.fetchError, "A failing channel must still surface via fetchError")
    }

    /// A previously-successful Channel 3 pin must survive a cycle where Channel 3 fails —
    /// the failure must not blank markers that a DIFFERENT, unrelated outage has nothing
    /// to do with. Channel 1 and Channel 2 return empty arrays (no fresh data of their own)
    /// so the only pin in play is the retained Channel 3 one.
    func testFetchPins_channel3Fails_previouslyVisibleChannel3PinRetained() async throws {
        let staleBlockScopedPin = makeFixturePin(
            pinType: .construction,
            source: .crowd,
            expiresAt: kFuture
        )
        let expectation = expectation(description: "all three channels attempted")
        expectation.expectedFulfillmentCount = 3

        let service = makeIsolationService { request in
            defer { expectation.fulfill() }
            let url = request.url?.absoluteString ?? ""
            if url.contains("construction") {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        // Seed visiblePins as if a prior successful fetch had populated it.
        service.inject(fixtures: [staleBlockScopedPin])

        service.onRegionChanged(testRegion)
        await fulfillment(of: [expectation], timeout: 2.5)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(service.visiblePins.contains { $0.id == staleBlockScopedPin.id },
            "A previously-visible Channel 3 pin must be retained when Channel 3's fetch fails, " +
            "not dropped just because that one channel is down")
    }

    /// The "retain previous pins on failure" fallback still runs the retained slice back
    /// through `clientSideFilter` — a pin that expires while its channel happens to be down
    /// must NOT be frozen on the map forever. This is what keeps the fail-soft fallback from
    /// silently misleading a driver about a curb being restricted after the restriction has
    /// actually lapsed.
    func testFetchPins_channel3Fails_expiredPreviouslyVisiblePinStillDropped() async throws {
        let expiredBlockScopedPin = makeFixturePin(
            pinType: .construction,
            source: .crowd,
            expiresAt: kPast
        )
        let expectation = expectation(description: "all three channels attempted")
        expectation.expectedFulfillmentCount = 3

        let service = makeIsolationService { request in
            defer { expectation.fulfill() }
            let url = request.url?.absoluteString ?? ""
            if url.contains("construction") {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        service.inject(fixtures: [expiredBlockScopedPin])

        service.onRegionChanged(testRegion)
        await fulfillment(of: [expectation], timeout: 2.5)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(service.visiblePins.contains { $0.id == expiredBlockScopedPin.id },
            "An already-expired retained pin must still be dropped by clientSideFilter, " +
            "even on the fail-soft retention path")
    }

    /// Baseline regression: when all three channels succeed, fetchError must be nil
    /// (the per-channel isolation refactor must not leave a stale error set from a
    /// previous failed cycle).
    func testFetchPins_allChannelsSucceed_fetchErrorNil() async throws {
        let expectation = expectation(description: "all three channels attempted")
        expectation.expectedFulfillmentCount = 3

        let service = makeIsolationService { request in
            defer { expectation.fulfill() }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        service.onRegionChanged(testRegion)
        await fulfillment(of: [expectation], timeout: 2.5)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(service.fetchError, "fetchError must be nil after a fully-successful fetch cycle")
    }
}

// MARK: - Map marker filter test (AC-D8)

@MainActor
final class CommunityPinServiceMarkerFilterTests: XCTestCase {

    /// AC-D8: asp_suspended_today pins must NOT be included in the map-marker array.
    ///
    /// Strategy: inject a fixture mix of filming + asp_suspended_today pins. Apply the
    /// same filter that ContentView's .onChange uses: `.filter { [.filming, .specialEvent].contains($0.pinType) }`.
    /// Assert that the result contains only filming pins.
    func testMapMarkerFilter_aspSuspendedToday_excluded() {
        let filmingPin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        let aspPin = makeFixturePin(pinType: .aspSuspendedToday, expiresAt: kFuture)

        // Simulate what ContentView's .onChange(of: pinService.visiblePins) does.
        let allPins = [filmingPin, aspPin]
        let markerPins = allPins.filter { [.filming, .specialEvent].contains($0.pinType) }

        XCTAssertEqual(markerPins.count, 1, "AC-D8: only filming pin should pass the marker filter")
        XCTAssertEqual(markerPins[0].pinType, .filming, "AC-D8: the retained pin must be a filming pin")

        let aspInMarkers = markerPins.contains { $0.pinType == .aspSuspendedToday }
        XCTAssertFalse(aspInMarkers,
            "AC-D8: asp_suspended_today must NOT appear in the map marker array")
    }
}

// MARK: - ASP banner supplement tests (AC-D9a through AC-D9d)

final class ResolvedBannerStateTests: XCTestCase {

    // Helper: build an asp_suspended_today fixture pin for a specific date string.
    private func aspPin(
        suspensionDate: String,
        reason: String = "Test Holiday",
        expiresAt: Date? = kFuture,
        resolvedAt: Date? = nil
    ) -> CommunityPin {
        let metaJSON = #"{ "suspension_date": "\#(suspensionDate)", "reason": "\#(reason)" }"#
        return makeFixturePin(
            pinType: .aspSuspendedToday,
            expiresAt: expiresAt,
            resolvedAt: resolvedAt,
            metaJSON: metaJSON
        )
    }

    /// AC-D9a: bundle says .aspInEffect + live pin for today → returns .todaySuspended(reason:).
    func testResolvedBannerState_aspPinToday_bundleInEffect_returnsSuspended() {
        // resolvedBannerState uses Date.nowET.toETDateString() (actual current date).
        // Build the fixture pin with the actual today's ET date so the date strings match.
        // This avoids the need to inject a nowProvider into resolvedBannerState (which is a
        // free function in ContentView.swift, not a class).
        let today = Date().toETDateString()  // actual current ET date
        let pin = aspPin(suspensionDate: today)

        // resolvedBannerState is a free function (internal) in ContentView.swift.
        let result = resolvedBannerState(bundleState: .aspInEffect, aspPins: [pin])

        if case .todaySuspended(let reason) = result {
            XCTAssertEqual(reason, "Test Holiday",
                "AC-D9a: reason must come from pin.meta.aspSuspendedTodayMeta.reason")
        } else {
            XCTFail("AC-D9a: expected .todaySuspended, got \(result)")
        }
    }

    /// AC-D9b: bundle says .todaySuspended → bundle wins; pin does not change the state.
    func testResolvedBannerState_bundleAlreadySuspended_noOverride() {
        let today = Date().toETDateString()  // actual current ET date
        let pin = aspPin(suspensionDate: today)

        let result = resolvedBannerState(
            bundleState: .todaySuspended(reason: "Memorial Day"),
            aspPins: [pin]
        )

        if case .todaySuspended(let reason) = result {
            XCTAssertEqual(reason, "Memorial Day",
                "AC-D9b: bundle wins when already suspended — reason must stay 'Memorial Day'")
        } else {
            XCTFail("AC-D9b: expected .todaySuspended(Memorial Day), got \(result)")
        }
    }

    /// AC-D9c: empty pin array → returns bundle state unchanged (.aspInEffect).
    func testResolvedBannerState_noPins_returnsBundle() {
        let result = resolvedBannerState(bundleState: .aspInEffect, aspPins: [])
        XCTAssertEqual(result, .aspInEffect,
            "AC-D9c: empty aspPins must return bundle state unchanged")
    }

    /// AC-D9d: expired asp pin → does NOT override bundle (.aspInEffect preserved).
    func testResolvedBannerState_expiredPin_noOverride() {
        let today = kNow.toETDateString()
        // Pin is expired (expiresAt = kPast, which is 1s before kNow).
        let expiredPin = aspPin(suspensionDate: today, expiresAt: kPast)

        let result = resolvedBannerState(bundleState: .aspInEffect, aspPins: [expiredPin])
        XCTAssertEqual(result, .aspInEffect,
            "AC-D9d: expired asp pin must NOT override bundle state")
    }
}

// MARK: - Realtime merge tests

@MainActor
final class CommunityPinServiceRealtimeMergeTests: XCTestCase {

    /// New filming pin → appended to visiblePins.
    func testMergeRealtimeChange_newFilmingPin_appended() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)

        service.mergeRealtimeChange(pin: pin)

        XCTAssertEqual(service.visiblePins.count, 1)
        XCTAssertEqual(service.visiblePins[0].id, pin.id)
    }

    /// Pin with resolvedAt set → removed from visiblePins.
    func testMergeRealtimeChange_resolvedPin_removed() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        // First inject it.
        service.inject(fixtures: [pin])
        XCTAssertEqual(service.visiblePins.count, 1)

        // Now merge an update where it's resolved.
        let resolvedPin = makeFixturePin(id: pin.id, pinType: .filming, expiresAt: kFuture, resolvedAt: kNow)
        service.mergeRealtimeChange(pin: resolvedPin)

        XCTAssertTrue(service.visiblePins.isEmpty,
            "Resolved pin must be removed from visiblePins on merge")
    }

    /// Expired pin received via Realtime → removed.
    func testMergeRealtimeChange_expiredPin_removed() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        service.inject(fixtures: [pin])

        let expiredPin = makeFixturePin(id: pin.id, pinType: .filming, expiresAt: kPast)
        service.mergeRealtimeChange(pin: expiredPin)

        XCTAssertTrue(service.visiblePins.isEmpty,
            "Expired pin must be removed from visiblePins on Realtime merge")
    }

    /// asp_suspended_today pin is merged into visiblePins (it's needed for the banner supplement).
    func testMergeRealtimeChange_aspPin_notAddedAsMarker_but_available_in_visiblePins() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let aspPin = makeFixturePin(pinType: .aspSuspendedToday, expiresAt: kFuture)
        service.mergeRealtimeChange(pin: aspPin)

        // The ASP pin IS in visiblePins (the banner supplement reads from visiblePins).
        XCTAssertEqual(service.visiblePins.count, 1)
        XCTAssertEqual(service.visiblePins[0].pinType, .aspSuspendedToday)
        // The .onChange in ContentView will filter it out of communityPins (map markers).
        // That filter logic is tested in testMapMarkerFilter_aspSuspendedToday_excluded.
    }

    /// UPDATE event replaces the existing pin.
    func testMergeRealtimeChange_updateExistingPin() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pinID = UUID()
        let original = makeFixturePin(id: pinID, pinType: .filming, expiresAt: kFuture)
        service.inject(fixtures: [original])

        // Simulate an UPDATE with a new expiry.
        let updatedPin = makeFixturePin(id: pinID, pinType: .filming, expiresAt: kFuture)
        service.mergeRealtimeChange(pin: updatedPin)

        XCTAssertEqual(service.visiblePins.count, 1, "UPDATE must replace, not append")
        XCTAssertEqual(service.visiblePins[0].id, pinID)
    }
}

// MARK: - Fixture injection tests

@MainActor
final class CommunityPinServiceInjectionTests: XCTestCase {

    /// inject() replaces visiblePins.
    func testInject_replacesVisiblePins() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin1 = makeFixturePin(pinType: .filming)
        let pin2 = makeFixturePin(pinType: .specialEvent)

        service.inject(fixtures: [pin1, pin2])

        XCTAssertEqual(service.visiblePins.count, 2)
        XCTAssertEqual(service.visiblePins[0].id, pin1.id)
        XCTAssertEqual(service.visiblePins[1].id, pin2.id)
    }

    /// inject([]) clears visiblePins.
    func testInject_emptyArray_clearsVisiblePins() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        service.inject(fixtures: [makeFixturePin()])
        XCTAssertEqual(service.visiblePins.count, 1)

        service.inject(fixtures: [])
        XCTAssertTrue(service.visiblePins.isEmpty, "inject([]) must clear visiblePins")
    }
}

// MARK: - Bug #1: Crowd pin optimistic-append tests

/// Verifies that mergeRealtimeChange correctly appends crowd ephemeral pins.
///
/// This covers the optimistic-append path: when the reporter submits a pin, the service
/// calls mergeRealtimeChange to immediately show the pin without waiting for a region-change
/// re-fetch. The bug was that the fetch query excluded crowd pins — these tests ensure
/// the merge path works for enforcement_active and sweeper_passed.
@MainActor
final class CommunityPinServiceCrowdMergeTests: XCTestCase {

    /// enforcement_active crowd pin → appended to visiblePins via mergeRealtimeChange.
    ///
    /// This is the optimistic-append path used immediately after insertCrowdPin returns.
    /// Without this, the reporter would not see their own pin until a region-change fires.
    func testMergeRealtimeChange_enforcementActive_crowdPin_appended() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin = makeFixturePin(pinType: .enforcementActive, source: .crowd, expiresAt: kFuture)

        service.mergeRealtimeChange(pin: pin)

        XCTAssertEqual(service.visiblePins.count, 1,
            "enforcement_active crowd pin must be appended via mergeRealtimeChange")
        XCTAssertEqual(service.visiblePins[0].pinType, .enforcementActive)
        XCTAssertEqual(service.visiblePins[0].source, .crowd)
    }

    /// sweeper_passed crowd pin → appended to visiblePins via mergeRealtimeChange.
    func testMergeRealtimeChange_sweeperPassed_crowdPin_appended() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pin = makeFixturePin(pinType: .sweeperPassed, source: .crowd, expiresAt: kFuture)

        service.mergeRealtimeChange(pin: pin)

        XCTAssertEqual(service.visiblePins.count, 1,
            "sweeper_passed crowd pin must be appended via mergeRealtimeChange")
        XCTAssertEqual(service.visiblePins[0].pinType, .sweeperPassed)
    }

    /// enforcement_active crowd pin with resolvedAt set → removed via mergeRealtimeChange.
    ///
    /// Verifies the 3-dispute-resolved path: when dispute_count reaches the threshold
    /// and the pin is resolved, a Realtime UPDATE with resolvedAt set should remove it
    /// from the map.
    func testMergeRealtimeChange_resolvedCrowdPin_removed() {
        let service = CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow }
        )
        let pinID = UUID()
        let pin = makeFixturePin(id: pinID, pinType: .enforcementActive, source: .crowd, expiresAt: kFuture)
        service.inject(fixtures: [pin])
        XCTAssertEqual(service.visiblePins.count, 1)

        // Simulate a Realtime UPDATE where the pin has been resolved (dispute threshold reached).
        let resolvedPin = makeFixturePin(
            id: pinID,
            pinType: .enforcementActive,
            source: .crowd,
            expiresAt: kFuture,
            resolvedAt: kNow
        )
        service.mergeRealtimeChange(pin: resolvedPin)

        XCTAssertTrue(service.visiblePins.isEmpty,
            "Resolved crowd pin must be removed from visiblePins on mergeRealtimeChange")
    }
}

// MARK: - Bug #4: ReportSheet.locationContextLabel tests

/// Tests for ReportSheet.locationContextLabel(streetName:) — pure static function.
///
/// Verifies the "Reporting on X" / fallback label logic for the in-drive report context line.
final class ReportSheetLocationContextLabelTests: XCTestCase {

    /// Non-nil, non-empty streetName → "Reporting on <name>".
    func testLocationContextLabel_withStreetName_returnsReportingOn() {
        let result = ReportSheet.locationContextLabel(streetName: "Grand St")
        XCTAssertEqual(result, "Reporting on Grand St",
            "Non-nil streetName must produce 'Reporting on <name>'")
    }

    /// nil streetName → "Reporting at current location" fallback.
    func testLocationContextLabel_nilStreetName_returnsFallback() {
        let result = ReportSheet.locationContextLabel(streetName: nil)
        XCTAssertEqual(result, "Reporting at current location",
            "nil streetName must produce fallback label")
    }

    /// Empty string streetName → fallback (treats empty as unresolved).
    func testLocationContextLabel_emptyStreetName_returnsFallback() {
        let result = ReportSheet.locationContextLabel(streetName: "")
        XCTAssertEqual(result, "Reporting at current location",
            "Empty streetName must produce fallback label (treated as unresolved)")
    }

    /// Multi-word street name with abbreviation — round-trips cleanly.
    func testLocationContextLabel_multiWordStreet_preservedExactly() {
        let result = ReportSheet.locationContextLabel(streetName: "W 28th St")
        XCTAssertEqual(result, "Reporting on W 28th St")
    }
}

// MARK: - PinMockURLProtocol (URLProtocol for request interception)

/// Thread-safe mock URLProtocol for testing CommunityPinService network requests.
/// Named PinMockURLProtocol (not MockURLProtocol) to avoid clash with
/// RouteServiceTests.MockURLProtocol in the same test target.
/// Pattern matches W8.5a RouteServiceTests (URLProtocol mock).
final class PinMockURLProtocol: URLProtocol {

    /// The handler to call when a request arrives. Set before creating the URLSession.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PinMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - RealtimeMergeGate tests (supabase-swift Stream B, AC-R2)

/// Pure-function tests for `RealtimeMergeGate` — no `CommunityPinService`, no socket, no
/// `@MainActor` needed (the gate itself is plain `Foundation`/`MapKit`).
final class RealtimeMergeGateTests: XCTestCase {

    /// Matches `makeFixturePin`'s hardcoded coordinate (lat 40.7505, lng -73.9965) so gate
    /// tests and merge-integration tests below can share the same mental model of "the pin".
    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7505, longitude: -73.9965),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    /// AC-R2: a pin at the exact center of the viewport is included.
    func testIsWithinRegion_pinAtCenter_included() {
        XCTAssertTrue(
            RealtimeMergeGate.isWithinRegion(
                lat: region.center.latitude, lng: region.center.longitude, region: region
            )
        )
    }

    /// AC-R2: a pin clearly outside the padded viewport (Los Angeles vs. Manhattan) is excluded.
    func testIsWithinRegion_pinFarOutside_excluded() {
        XCTAssertFalse(
            RealtimeMergeGate.isWithinRegion(lat: 34.0522, lng: -118.2437, region: region)
        )
    }

    /// A pin outside the EXACT (unpadded) viewport, but inside the default 1.5x padding, is
    /// still included — the whole point of padding (spec §3.4: "a pin just outside the
    /// visible edge doesn't pop in/out on every micro-pan"). Exact half-span here is 0.005°;
    /// padded (1.5x) half-span is 0.0075°.
    func testIsWithinRegion_insidePaddingButOutsideExactViewport_included() {
        let lat = region.center.latitude + 0.006
        XCTAssertTrue(
            RealtimeMergeGate.isWithinRegion(lat: lat, lng: region.center.longitude, region: region),
            "A pin within the 1.5x padded viewport but outside the exact unpadded viewport must still be included"
        )
    }

    /// A pin just past the padded boundary is excluded.
    func testIsWithinRegion_justOutsidePadding_excluded() {
        let lat = region.center.latitude + 0.0076
        XCTAssertFalse(
            RealtimeMergeGate.isWithinRegion(lat: lat, lng: region.center.longitude, region: region)
        )
    }

    /// `paddingFactor: 1.0` tests the exact (unpadded) viewport boundary directly.
    func testIsWithinRegion_exactViewport_paddingFactorOne() {
        let justInside = region.center.latitude + 0.0049
        let justOutside = region.center.latitude + 0.0051
        XCTAssertTrue(
            RealtimeMergeGate.isWithinRegion(
                lat: justInside, lng: region.center.longitude, region: region, paddingFactor: 1.0
            )
        )
        XCTAssertFalse(
            RealtimeMergeGate.isWithinRegion(
                lat: justOutside, lng: region.center.longitude, region: region, paddingFactor: 1.0
            )
        )
    }

    /// `mergeablePinTypes` mirrors `mergeRealtimeChange`'s pre-existing set (spec §8.3) — a
    /// personal-only type (`parked_car`) or a durable/non-community type must never be
    /// Realtime-mergeable.
    func testMergeablePinTypes_containsExpectedTypes_excludesIneligibleTypes() {
        let expectedIncluded: [PinType] = [
            .filming, .specialEvent, .aspSuspendedToday,
            .enforcementActive, .sweeperPassed, .brokenMeter,
            .construction,
        ]
        for type in expectedIncluded {
            XCTAssertTrue(RealtimeMergeGate.mergeablePinTypes.contains(type), "\(type) must be mergeable")
        }
        let expectedExcluded: [PinType] = [.parkedCar, .signCorrection, .blockNote]
        for type in expectedExcluded {
            XCTAssertFalse(RealtimeMergeGate.mergeablePinTypes.contains(type), "\(type) must NOT be mergeable")
        }
    }
}

// MARK: - CommunityPinService Realtime wiring tests (supabase-swift Stream B, AC-R1/R3–R7)

/// Exercises `startRealtime()` / `disconnectRealtime()` / `reconnectRealtime()` /
/// `handleRealtimeUpsert(_:)` / `removePin(id:)` end-to-end against `MockRealtimePinChannel`
/// (`Services/RealtimePinChannel.swift`, `#if DEBUG`) — no live socket. Actual event delivery
/// over a real WebSocket is a QA-owned live/simulator check (spec §11, AC-R1), not something
/// this mock can stand in for.
@MainActor
final class CommunityPinServiceRealtimeWiringTests: XCTestCase {

    /// Region centered on `makeFixturePin`'s hardcoded coordinate (lat 40.7505, lng -73.9965).
    private let manhattanRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7505, longitude: -73.9965),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    /// Somewhere clearly outside the padded Manhattan viewport.
    private let losAngelesRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    /// Builds a `CommunityPinService` wired to `mock` and a `PinMockURLProtocol`-backed
    /// session that always returns an empty PostgREST array — used by tests that need
    /// `lastFetchedRegion` populated via a real (mocked) `onRegionChanged` → `fetchPins` cycle,
    /// since `handleRealtimeUpsert`'s viewport gate reads `lastFetchedRegion` directly rather
    /// than a separately-injectable value.
    private func makeService(realtimeChannel: MockRealtimePinChannel) -> CommunityPinService {
        PinMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "[]".data(using: .utf8)!)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)

        return CommunityPinService(
            supabaseURL: kServiceURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { kNow },
            urlSession: session,
            realtimeChannel: realtimeChannel
        )
    }

    /// Seeds `lastFetchedRegion` via a real (mocked) REST fetch triggered through
    /// `onRegionChanged`'s normal 800ms-debounced path.
    private func seedLastFetchedRegion(_ service: CommunityPinService, region: MKCoordinateRegion) async {
        service.onRegionChanged(region)
        try? await Task.sleep(for: .milliseconds(1000))
    }

    /// Starts Realtime and awaits the in-flight connect Task so `MockRealtimePinChannel`'s
    /// captured closures are guaranteed to be set before the test proceeds — avoids a
    /// `Task.yield()` timing race against the fire-and-forget `Task { }` inside
    /// `startRealtime()`.
    private func startAndAwaitConnect(_ service: CommunityPinService) async {
        service.startRealtime()
        await service.realtimeConnectTask?.value
    }

    // MARK: AC-R1 (unit-testable slice)

    /// `startRealtime()` actually calls `realtimeChannel.connect(...)`.
    func testStartRealtime_callsConnectOnRealtimeChannel() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)

        await startAndAwaitConnect(service)

        XCTAssertEqual(mock.connectCallCount, 1)
        XCTAssertTrue(mock.isConnected)
    }

    // MARK: AC-R3: eligible, in-viewport upsert reaches mergeRealtimeChange

    func testRealtimeUpsert_eligibleType_inViewport_appearsInVisiblePins() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await seedLastFetchedRegion(service, region: manhattanRegion)
        await startAndAwaitConnect(service)

        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        mock.simulateUpsert(pin)

        XCTAssertTrue(
            service.visiblePins.contains { $0.id == pin.id },
            "AC-R3: an INSERT for an eligible, in-viewport pin type must reach mergeRealtimeChange and appear in visiblePins"
        )
    }

    // MARK: AC-R4: ineligible type OR out-of-viewport is dropped before mergeRealtimeChange

    func testRealtimeUpsert_ineligibleType_dropped() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await seedLastFetchedRegion(service, region: manhattanRegion)
        await startAndAwaitConnect(service)

        // parked_car is a personal, non-community pin type — must never arrive via Realtime.
        let pin = makeFixturePin(pinType: .parkedCar, expiresAt: kFuture)
        mock.simulateUpsert(pin)

        XCTAssertFalse(
            service.visiblePins.contains { $0.id == pin.id },
            "AC-R4: a pin type not in RealtimeMergeGate.mergeablePinTypes must be dropped before reaching mergeRealtimeChange"
        )
    }

    func testRealtimeUpsert_eligibleType_outOfViewport_dropped() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        // Seed lastFetchedRegion far from the fixture pin's Manhattan coordinate.
        await seedLastFetchedRegion(service, region: losAngelesRegion)
        await startAndAwaitConnect(service)

        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        mock.simulateUpsert(pin)

        XCTAssertFalse(
            service.visiblePins.contains { $0.id == pin.id },
            "AC-R4: a pin outside the fetched viewport must be dropped before reaching mergeRealtimeChange"
        )
    }

    func testRealtimeUpsert_noRegionFetchedYet_dropped() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        // No onRegionChanged call — lastFetchedRegion is nil.
        await startAndAwaitConnect(service)

        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        mock.simulateUpsert(pin)

        XCTAssertFalse(
            service.visiblePins.contains { $0.id == pin.id },
            "A Realtime event arriving before any viewport is known must be dropped, not admitted"
        )
    }

    // MARK: AC-R5: DELETE removes by ID via removePin, no CommunityPin decode required

    func testRealtimeDelete_removesMatchingPin() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        service.inject(fixtures: [pin])
        XCTAssertEqual(service.visiblePins.count, 1)

        await startAndAwaitConnect(service)
        mock.simulateDelete(id: pin.id)

        XCTAssertTrue(
            service.visiblePins.isEmpty,
            "AC-R5: a DELETE event must remove the corresponding pin from visiblePins by ID"
        )
    }

    func testRealtimeDelete_unknownId_noOp() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        service.inject(fixtures: [pin])

        await startAndAwaitConnect(service)
        mock.simulateDelete(id: UUID())

        XCTAssertEqual(service.visiblePins.count, 1, "removePin(id:) must be a no-op for an ID not currently present")
    }

    /// Direct unit test of `removePin(id:)` itself, bypassing the mock/Realtime plumbing
    /// entirely — confirms the primary-key-only removal path (AC-R5's "without requiring a
    /// fully-decoded CommunityPin") independent of how the ID reaches it.
    func testRemovePin_directCall_removesById() {
        let service = CommunityPinService(supabaseURL: kServiceURL, supabaseAnonKey: kAnonKey, nowProvider: { kNow })
        let pin = makeFixturePin(pinType: .filming, expiresAt: kFuture)
        service.inject(fixtures: [pin])

        service.removePin(id: pin.id)

        XCTAssertTrue(service.visiblePins.isEmpty)
    }

    // MARK: AC-R6: disconnectRealtime() / reconnectRealtime() call through to the channel

    func testDisconnectRealtime_callsDisconnectOnRealtimeChannel() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await startAndAwaitConnect(service)
        XCTAssertTrue(mock.isConnected)

        service.disconnectRealtime()
        await service.realtimeDisconnectTask?.value

        XCTAssertEqual(mock.disconnectCallCount, 1)
        XCTAssertFalse(mock.isConnected)
    }

    func testReconnectRealtime_callsConnectAgain() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await startAndAwaitConnect(service)
        XCTAssertEqual(mock.connectCallCount, 1)

        service.reconnectRealtime()
        await service.realtimeConnectTask?.value

        XCTAssertEqual(mock.connectCallCount, 2, "reconnectRealtime() must call connect() again")
        XCTAssertTrue(mock.isConnected)
    }

    // MARK: AC-R7: Drive Mode leaves Realtime connected, still suspends the periodic poll

    func testSetDriveModeActive_true_leavesRealtimeConnected_suspendsPeriodicPoll() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await startAndAwaitConnect(service)
        XCTAssertTrue(mock.isConnected)

        service.setDriveModeActive(true)

        XCTAssertTrue(mock.isConnected, "AC-R7: Realtime must stay connected through Drive Mode")
        XCTAssertEqual(mock.disconnectCallCount, 0, "AC-R7: setDriveModeActive(true) must never disconnect Realtime")
        XCTAssertNil(
            service.periodicRefreshTask,
            "Periodic REST poll must still be suspended during Drive Mode (unchanged pre-existing behavior)"
        )
    }

    // MARK: QA pass 1, Finding #1 (docs/qa/realtime-stream-b-pr84.md) — lifecycle race regression
    //
    // Every test above this point explicitly `await`s each lifecycle Task before issuing the
    // next call (`await startAndAwaitConnect(...)`, `await service.realtimeDisconnectTask?.value`,
    // etc.). That sidesteps the race QA flagged BY CONSTRUCTION: it never exercises the
    // interleaving of a genuinely concurrent connect vs. disconnect, which is exactly what a
    // fast `.background -> .active` scenePhase flap produces in production
    // (`ContentView.handleScenePhaseChange` calls `disconnectRealtime()` then, on the very next
    // `.active` transition, `reconnectRealtime()` — with nothing awaited in between). The test
    // below deliberately does NOT await between `disconnectRealtime()` and `reconnectRealtime()`,
    // reproducing that exact interleaving.

    /// Reproduces the race directly: a `disconnectRealtime()` whose underlying
    /// `realtimeChannel.disconnect()` is artificially slow (simulating a real
    /// `unsubscribe()`/`RealtimeClientV2.disconnect()` network round-trip), immediately
    /// followed — with no `await` in between — by `reconnectRealtime()`, mirroring
    /// `handleScenePhaseChange(.background)` immediately followed by
    /// `handleScenePhaseChange(.active)`.
    ///
    /// Pre-fix (`Task.cancel()`-based, unserialized): `disconnectRealtime()` kicks off a
    /// `realtimeDisconnectTask` that starts sleeping inside `mock.disconnect()`.
    /// `reconnectRealtime()` -> `startRealtime()` immediately overwrites `realtimeConnectTask`
    /// with a brand-new Task that calls `mock.connect()` right away (no delay) — it has no
    /// mechanism forcing it to wait for the disconnect in flight. `mock.connect()` finishes
    /// almost instantly and sets `isConnected = true`. Only later, once the artificial delay
    /// elapses, does the abandoned disconnect Task's `mock.disconnect()` call finally land and
    /// set `isConnected = false` — exactly the "the trailing disconnect tears the socket down a
    /// moment later" failure QA described. The assertion below (`isConnected` must be `true`
    /// after the whole chain settles) FAILS pre-fix.
    ///
    /// Post-fix (chained via `realtimeLifecycleTask`): `disconnectRealtime()`'s Task is the new
    /// chain tail. `reconnectRealtime()` -> `startRealtime()` captures THAT Task as its own
    /// predecessor and its body awaits `predecessor?.value` before calling `mock.connect()` at
    /// all — so `mock.connect()` cannot run, and cannot flip `isConnected` to `true`, until
    /// `mock.disconnect()` has fully finished (including its artificial delay) and already set
    /// `isConnected` to `false` first. Awaiting `service.realtimeConnectTask?.value` therefore
    /// waits for the entire chain in the correct order, and the final state is connected.
    func testDisconnectThenReconnectFlap_doesNotRaceAndEndsConnected() async {
        let mock = MockRealtimePinChannel()
        let service = makeService(realtimeChannel: mock)
        await startAndAwaitConnect(service)
        XCTAssertTrue(mock.isConnected)
        XCTAssertEqual(mock.connectCallCount, 1)

        // Make disconnect()'s underlying work slow relative to connect()'s, so a naive
        // unserialized implementation lets the fast connect() "win" the race and finish first,
        // with the slow disconnect() landing afterwards and undoing it.
        mock.disconnectDelay = .milliseconds(200)

        // The exact interleaving of a fast background -> foreground scenePhase flap: no await
        // between the disconnect call and the reconnect call.
        service.disconnectRealtime()
        service.reconnectRealtime()

        // Once fixed, awaiting the connect task alone is sufficient: its body awaits the
        // disconnect task (its chain predecessor) before doing its own connect() work, so this
        // single await spans the whole chain, in the correct order.
        await service.realtimeConnectTask?.value

        // Belt-and-suspenders: also explicitly wait past the artificial disconnect delay, so a
        // pre-fix run can't accidentally "pass" just because this test didn't wait long enough
        // for the abandoned disconnect Task to land and flip isConnected back to false.
        try? await Task.sleep(for: .milliseconds(300)) // > the 200ms disconnect delay above

        XCTAssertTrue(
            mock.isConnected,
            "A background->foreground flap must leave Realtime actually connected once the " +
            "chain settles, not silently dead: disconnect() must fully complete BEFORE " +
            "connect() runs, not race it and land after."
        )
        XCTAssertEqual(mock.disconnectCallCount, 1)
        XCTAssertEqual(mock.connectCallCount, 2, "reconnectRealtime() must have called connect() again")
    }
}

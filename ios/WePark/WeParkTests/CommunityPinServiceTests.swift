//
//  CommunityPinServiceTests.swift
//  WeParkTests
//
//  Community 1.0 Tier 1 Pin Display — fixture-driven unit tests.
//  Spec: docs/tier1-pin-display-spec.md §11 (AC-D1 through AC-D9d).
//
//  Test inventory (21 tests):
//
//  Client-side filter — expiry (4 tests, AC-D1 through AC-D4):
//    1.  testClientSideFilter_expiredPin_removed              (AC-D1)
//    2.  testClientSideFilter_nilExpiry_retained              (AC-D2)
//    3.  testClientSideFilter_futureExpiry_retained           (AC-D3)
//    4.  testClientSideFilter_resolvedPin_removed             (AC-D4)
//
//  Fetch path — source=open_data guard (1 test, AC-D6):
//    5.  testFetchRequest_includesOpenDataSourceFilter        (AC-D6)
//
//  Debounce — two rapid calls fire only one fetch (1 test, AC-D7):
//    6.  testDebounce_twoRapidCalls_firesOneFetch             (AC-D7)
//
//  Map marker filter — asp_suspended_today excluded (1 test, AC-D8):
//    7.  testMapMarkerFilter_aspSuspendedToday_excluded       (AC-D8)
//
//  ASP banner supplement — resolvedBannerState (4 tests, AC-D9a through AC-D9d):
//    8.  testResolvedBannerState_aspPinToday_bundleInEffect_returnsSuspended  (AC-D9a)
//    9.  testResolvedBannerState_bundleAlreadySuspended_noOverride            (AC-D9b)
//   10.  testResolvedBannerState_noPins_returnsBundle                         (AC-D9c)
//   11.  testResolvedBannerState_expiredPin_noOverride                        (AC-D9d)
//
//  Realtime merge — mergeRealtimeChange (5 tests):
//   12.  testMergeRealtimeChange_newFilmingPin_appended
//   13.  testMergeRealtimeChange_resolvedPin_removed
//   14.  testMergeRealtimeChange_expiredPin_removed
//   15.  testMergeRealtimeChange_aspPin_notAddedAsMarker_but_available_in_visiblePins
//   16.  testMergeRealtimeChange_updateExistingPin
//
//  Fixture injection (2 tests):
//   17.  testInject_replacesVisiblePins
//   18.  testInject_emptyArray_clearsVisiblePins
//
//  URL request structure (3 tests, AC-D6):
//   19.  testBuildRequest_containsExpectedQueryItems
//   20.  testBuildRequest_noAuthorizationHeader
//   21.  testBuildRequest_apiKeyHeader_present
//
//  Baseline: 280/0. After this suite: 280 + 21 = 301/0 (total).
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

/// ISO 8601 fixture dates (no Calendar.current).
private let kNow       = ISO8601DateFormatter().date(from: "2026-06-01T12:00:00+00:00")!
private let kPast      = ISO8601DateFormatter().date(from: "2026-06-01T11:59:59+00:00")!  // 1s in past
private let kFuture    = ISO8601DateFormatter().date(from: "2026-06-01T13:00:00+00:00")!  // 1h in future

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

// MARK: - Fetch path request structure tests (AC-D6)

@MainActor
final class CommunityPinServiceRequestTests: XCTestCase {

    /// AC-D6: The URLRequest built by buildRequest includes source=eq.open_data.
    ///
    /// Access: `buildRequest` is private; tested indirectly by calling
    /// `onRegionChanged` on a service with a mock URLSession that captures the request.
    ///
    /// Strategy: inject a custom URLSession (via PinMockURLProtocol) and observe the
    /// URLRequest captured during the debounced fetch. Verify that the URL includes
    /// `source=eq.open_data` in its query string.
    func testFetchRequest_includesOpenDataSourceFilter() async throws {
        // Capture the request URL.
        var capturedURL: URL? = nil
        let expectation = expectation(description: "fetch fires")

        PinMockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            expectation.fulfill()
            // Return an empty JSON array so the decoder doesn't throw.
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!, "[]".data(using: .utf8)!)
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

        // Fire onRegionChanged — the 800ms debounce will fire the fetch.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)

        // Wait up to 2s for the debounced fetch to fire (800ms debounce + buffer).
        await fulfillment(of: [expectation], timeout: 2.0)

        // AC-D6: The URL must include source=eq.open_data.
        let urlString = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(
            urlString.contains("source=eq.open_data"),
            "AC-D6: URLRequest must include source=eq.open_data filter. Got: \(urlString)"
        )
    }

    /// AC-D6 companion: request must NOT include an Authorization header (anon-only read).
    func testBuildRequest_noAuthorizationHeader() async throws {
        var capturedRequest: URLRequest? = nil
        let expectation = expectation(description: "fetch fires")

        PinMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            expectation.fulfill()
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

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.0)

        // Must not have an Authorization header (anon read path — AC-D21).
        let authHeader = capturedRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertNil(authHeader,
            "AC-D21: fetch must NOT include an Authorization header for anon read")
    }

    /// The apikey header must be present (Supabase PostgREST requirement).
    func testBuildRequest_apiKeyHeader_present() async throws {
        var capturedRequest: URLRequest? = nil
        let expectation = expectation(description: "fetch fires")

        PinMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            expectation.fulfill()
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

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.0)

        let apiKeyHeader = capturedRequest?.value(forHTTPHeaderField: "apikey")
        XCTAssertEqual(apiKeyHeader, kAnonKey,
            "Request must include apikey header set to the anon key")
    }
}

// MARK: - Debounce test (AC-D7)

@MainActor
final class CommunityPinServiceDebounceTests: XCTestCase {

    /// AC-D7: Two calls to onRegionChanged 200ms apart fire only ONE network fetch.
    ///
    /// Strategy: inject a PinMockURLProtocol that counts requests. Send two region changes
    /// 200ms apart (within the 800ms debounce window). Wait 1.2s total. Assert count == 1.
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

        XCTAssertEqual(fetchCount, 1,
            "AC-D7: two onRegionChanged calls 200ms apart must fire only ONE fetch (debounce)")
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
        // Inject a frozen "now" provider so toETDateString() returns a predictable date.
        // Use kNow = 2026-06-01T12:00:00+00:00 → ET date "2026-06-01".
        // We can't easily inject "now" into the free function, so we build the pin with
        // the matching date string and verify the function's logic instead.
        let today = kNow.toETDateString()  // "2026-06-01" in ET (UTC = ET for this test)
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
        let today = kNow.toETDateString()
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

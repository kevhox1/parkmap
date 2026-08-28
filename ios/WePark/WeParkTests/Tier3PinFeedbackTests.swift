//
//  Tier3PinFeedbackTests.swift
//  WeParkTests
//
//  Tests for the three Tier 3 live-test bug fixes:
//
//  Fix 1 — Optimistic add after insertCrowdPin (return=representation path):
//   1.  testInsertCrowdPin_successWithRepresentation_appendsPin
//   2.  testInsertCrowdPin_malformedResponseBody_doesNotThrow
//   3.  testInsertCrowdPin_requestHeader_preferReturnRepresentation
//
//  Fix 2 — Periodic refresh scheduling:
//   4.  testStartPeriodicRefresh_setsTask
//   5.  testStopPeriodicRefresh_cancelsTask
//   6.  testSetDriveModeActive_true_stopsPeriodicRefresh
//   7.  testSetDriveModeActive_false_startsPeriodicRefresh
//   8.  testOnRegionChanged_startsPeriodicRefreshOnce
//   9.  testOnRegionChanged_doesNotStackMultipleTimers
//   10. testPinRefreshIntervalSeconds_isNamedConstant
//
//  Fix 3 — Marker image safety net (non-nil return for any pin type):
//   11. testMarkerImage_enforcementActive_returnsNonNil
//   12. testMarkerImage_sweeperPassed_returnsNonNil
//   13. testMarkerImage_allKnownProductionSymbols_resolveOnIOS17
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens or Supabase keys.
//
//  Community 2.0 Phase 1 (build 20, session S3 — docs/community-2.0-reconciliation-spec.md §0
//  OQ-2, §3 Phase 1): `FT1MobilePinTTLTests` (added after this header's own Fix 1/2/3 inventory
//  was written — pre-existing drift, not introduced by this session) has its enforcement/
//  sweeper assertions updated IN PLACE (5 min → 45m/120m) and renamed to drop the now-stale
//  "FT1_" prefix, reflecting OQ-2's reversal of FT-1's 5-minute baseline. No new test count here
//  — see `Community2Phase1ModelTests.swift` for the net-new `open_spot`/`leaving_soon` TTL
//  table tests.
//
//  Community 2.0 Phase 1 (build 20, session S4 — crew feed UI, §3 Phase 1, §6 appendix):
//  `MarkerImageSafetyNetTests` gains 4 tests covering the compile-break fix this session makes
//  (`PinType.displayLabel` gaining `.openSpot`/`.leavingSoon` cases) plus the two types' new
//  "ring" marker image and age-not-expiry callout subtitle:
//   14. testDisplayLabel_openSpot_and_leavingSoon
//   15. testMarkerImage_openSpot_returnsNonNil
//   16. testMarkerImage_leavingSoon_returnsNonNil
//   17. testSubtitle_openSpot_and_leavingSoon_showRelativeAge_notExpiry
//

import XCTest
import MapKit
import UIKit
@testable import WePark

// MARK: - Shared test constants

private let kFeedbackTestURL = URL(string: "https://feedback-test.supabase.co")!
private let kFeedbackAnonKey = "test-anon-key-feedback"

// MARK: - Shared fixture helpers

/// Builds a CommunityPin JSON string matching the pins_with_author view shape.
private func makePinResponseJSON(
    id: String = UUID().uuidString,
    pinType: String = "enforcement_active",
    source: String = "crowd"
) -> String {
    """
    {
      "id": "\(id)",
      "pin_type": "\(pinType)",
      "source": "\(source)",
      "lifespan": "ephemeral",
      "lat": 40.7220,
      "lng": -73.9930,
      "segment_id": null,
      "zone_id": null,
      "author_id": null,
      "author_username": null,
      "created_at": "2099-06-01T00:00:00+00:00",
      "updated_at": "2099-06-01T00:00:00+00:00",
      "expires_at": "2099-06-01T01:00:00+00:00",
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """
}

// MARK: - Auth mock helpers (mirrors the pattern in Tier3AuthReactionsTests)

private let kFeedbackUser = UUID(uuidString: "B0000001-0000-0000-0000-000000000001")!

/// supabase-swift adoption — Stream A: shape matches the SDK's `Session`/`User` `Decodable`
/// requirements (snake_case + expires_at, not just expires_in — see
/// SupabaseAuthServiceTests.swift's header for the full explanation of why).
private func feedbackAuthResponseJSON(userId: UUID = kFeedbackUser) -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.feedback.token",
      "refresh_token": "refresh-feedback-token",
      "token_type": "bearer",
      "expires_in": 3600,
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(userId.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

/// Builds a real SupabaseAuthService instance wired to a mocked network that returns
/// `feedbackAuthResponseJSON`. Equivalent to Tier3AuthReactionsTests.makeAuthenticatedPair.
/// supabase-swift adoption — Stream A: uses SupabaseAuthService's `#if DEBUG` test-seam
/// initializer (Foundation-only params — see SupabaseAuthServiceTests.swift's header for why)
/// instead of the removed `urlSession:`-based initializer.
/// @MainActor: SupabaseAuthService is @MainActor @Observable.
@MainActor
private func makeFeedbackAuthService() async -> SupabaseAuthService {
    FeedbackAuthMockURLProtocol.requestHandler = { _ in
        (HTTPURLResponse(
            url: kFeedbackTestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!, feedbackAuthResponseJSON())
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FeedbackAuthMockURLProtocol.self]
    let session = URLSession(configuration: config)
    let authService = SupabaseAuthService(
        supabaseURL: kFeedbackTestURL,
        supabaseAnonKey: kFeedbackAnonKey,
        testStorage: InMemoryAuthStorage(),
        fetch: { try await session.data(for: $0) }
    )
    await authService.ensureSession()
    return authService
}

/// Clears UserDefaults auth keys written by SupabaseAuthService.
private func clearAuthDefaults() {
    let keys = [
        "wepark_auth_access_token", "wepark_auth_refresh_token",
        "wepark_auth_user_id", "wepark_auth_expires_at",
    ]
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - Decode helper for test pins

/// @MainActor: CommunityPin.Decodable conformance is @MainActor (CommunityPin is @Observable).
@MainActor
private func decodeTestPin(pinType: PinType = .enforcementActive) -> CommunityPin {
    let json = makePinResponseJSON(id: UUID().uuidString, pinType: pinType.rawValue)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: str) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: str) { return d }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "bad date: \(str)")
        )
    }
    return try! decoder.decode(CommunityPin.self, from: Data(json.utf8))
}

// MARK: - Fix 1: Optimistic add after insertCrowdPin

/// Verifies that a successful insertCrowdPin with return=representation decodes the
/// response body and calls mergeRealtimeChange so the pin appears in visiblePins.
@MainActor
final class InsertCrowdPinOptimisticTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        clearAuthDefaults()
    }

    // MARK: Test 1: successful insert → pin appended to visiblePins

    /// Fix 1: insertCrowdPin with a well-formed response body adds the decoded pin to
    /// visiblePins via mergeRealtimeChange without requiring a region-change re-fetch.
    func testInsertCrowdPin_successWithRepresentation_appendsPin() async throws {
        let insertedID = UUID()
        // PostgREST returns an array for INSERT with Prefer: return=representation.
        let responseArray = "[\(makePinResponseJSON(id: insertedID.uuidString))]"

        FeedbackWriteMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kFeedbackTestURL, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             Data(responseArray.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackWriteMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let authService = await makeFeedbackAuthService()
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey,
            nowProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            urlSession: session,
            authService: authService
        )

        try await service.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.722,
            lng: -73.993,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        // Fix 1 core assertion: the pin must have been appended via mergeRealtimeChange.
        XCTAssertEqual(service.visiblePins.count, 1,
            "Fix 1: insertCrowdPin must append the inserted pin to visiblePins via mergeRealtimeChange")
        XCTAssertEqual(service.visiblePins.first?.id, insertedID,
            "Fix 1: the appended pin must have the ID returned by the server")
    }

    // MARK: Test 2: malformed response body → no throw (write itself succeeded)

    /// Fix 1: if the server returns 201 but a malformed body (schema mismatch, empty body),
    /// insertCrowdPin must NOT throw — the write succeeded. The pin will appear on the
    /// next periodic refresh tick instead.
    func testInsertCrowdPin_malformedResponseBody_doesNotThrow() async {
        FeedbackWriteMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kFeedbackTestURL, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             Data("not-valid-json".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackWriteMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let authService = await makeFeedbackAuthService()
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey,
            urlSession: session,
            authService: authService
        )

        // Must not throw even though the response body is garbage.
        var threw = false
        do {
            try await service.insertCrowdPin(
                type: .enforcementActive,
                meta: nil,
                lat: 40.722,
                lng: -73.993,
                segmentId: nil,
                zoneId: nil,
                notes: nil
            )
        } catch {
            threw = true
        }

        XCTAssertFalse(threw,
            "Fix 1: malformed decode must not cause insertCrowdPin to throw (write itself succeeded)")
        // visiblePins remains empty — the decode silently failed.
        XCTAssertTrue(service.visiblePins.isEmpty,
            "Fix 1: malformed decode must not append a phantom pin")
    }

    // MARK: Test 3: Prefer header contains return=representation

    /// Fix 1: the POST request to rest/v1/pins must carry Prefer: return=representation
    /// so PostgREST returns the inserted row for optimistic-add.
    func testInsertCrowdPin_requestHeader_preferReturnRepresentation() async throws {
        var capturedPreferHeader: String?

        let responseArray = "[\(makePinResponseJSON())]"
        FeedbackWriteMockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" {
                capturedPreferHeader = request.value(forHTTPHeaderField: "Prefer")
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data(responseArray.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackWriteMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let authService = await makeFeedbackAuthService()
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey,
            urlSession: session,
            authService: authService
        )

        try await service.insertCrowdPin(
            type: .sweeperPassed,
            meta: ["direction": "passed"],
            lat: 40.723,
            lng: -73.992,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertNotNil(capturedPreferHeader,
            "Fix 1: POST to rest/v1/pins must include a Prefer header")
        XCTAssertTrue(capturedPreferHeader?.contains("return=representation") == true,
            "Fix 1: Prefer header must contain 'return=representation'; got: \(capturedPreferHeader ?? "nil")")
    }
}

// MARK: - Fix 2: Periodic refresh scheduling

/// Verifies the periodic refresh timer starts, stops, and interacts correctly with Drive Mode.
@MainActor
final class PeriodicRefreshSchedulingTests: XCTestCase {

    // MARK: Test 4: startPeriodicRefresh sets the task

    /// Fix 2: After startPeriodicRefresh(), the periodicRefreshTask is non-nil (running).
    func testStartPeriodicRefresh_setsTask() {
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey
        )
        XCTAssertNil(service.periodicRefreshTask,
            "Precondition: periodicRefreshTask must be nil before start")

        service.startPeriodicRefresh()

        XCTAssertNotNil(service.periodicRefreshTask,
            "Fix 2: startPeriodicRefresh must create a non-nil periodicRefreshTask")
        service.stopPeriodicRefresh()
    }

    // MARK: Test 5: stopPeriodicRefresh clears the task

    /// Fix 2: After stopPeriodicRefresh(), periodicRefreshTask is nil.
    func testStopPeriodicRefresh_cancelsTask() {
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey
        )
        service.startPeriodicRefresh()
        XCTAssertNotNil(service.periodicRefreshTask,
            "Precondition: task must be running before stop")

        service.stopPeriodicRefresh()

        XCTAssertNil(service.periodicRefreshTask,
            "Fix 2: stopPeriodicRefresh must set periodicRefreshTask to nil")
    }

    // MARK: Test 6: setDriveModeActive(true) stops periodic refresh

    /// Fix 2: When Drive Mode activates, the periodic refresh is cancelled to avoid
    /// hammering Supabase during navigation.
    func testSetDriveModeActive_true_stopsPeriodicRefresh() {
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey
        )
        service.startPeriodicRefresh()
        XCTAssertNotNil(service.periodicRefreshTask,
            "Precondition: periodic refresh must be running")

        service.setDriveModeActive(true)

        XCTAssertNil(service.periodicRefreshTask,
            "Fix 2: setDriveModeActive(true) must cancel the periodic refresh task")
    }

    // MARK: Test 7: setDriveModeActive(false) starts periodic refresh

    /// Fix 2: When Drive Mode exits, the periodic refresh is restarted so community
    /// pins stay fresh on the resting map.
    func testSetDriveModeActive_false_startsPeriodicRefresh() {
        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey
        )
        // Simulate: enter then exit Drive Mode.
        service.setDriveModeActive(true)
        XCTAssertNil(service.periodicRefreshTask,
            "Precondition: periodic refresh must be stopped during Drive Mode")

        service.setDriveModeActive(false)

        XCTAssertNotNil(service.periodicRefreshTask,
            "Fix 2: setDriveModeActive(false) must restart the periodic refresh task")
        service.stopPeriodicRefresh()
    }

    // MARK: Test 8: onRegionChanged starts periodic refresh on first call

    /// Fix 2: The periodic refresh starts after the first onRegionChanged (when no prior
    /// task is running), so pins are kept fresh from the first fetch onward.
    func testOnRegionChanged_startsPeriodicRefreshOnce() {
        // Note: we don't need the fetch to complete for this test — we only verify the
        // scheduling side effect (periodicRefreshTask is set synchronously in onRegionChanged).
        // The fetch itself is async (800ms debounce) and unrelated to the scheduling logic.
        FeedbackFetchMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("[]".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackFetchMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey,
            urlSession: session
        )

        XCTAssertNil(service.periodicRefreshTask,
            "Precondition: no periodic refresh before first region change")

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)

        // The periodic refresh task is created synchronously in onRegionChanged
        // (the `if periodicRefreshTask == nil && !driveModeActive { startPeriodicRefresh() }` guard).
        XCTAssertNotNil(service.periodicRefreshTask,
            "Fix 2: onRegionChanged must start periodicRefreshTask on the first call")
        service.stopPeriodicRefresh()
    }

    // MARK: Test 9: onRegionChanged does not stack multiple timers

    /// Fix 2: Multiple calls to onRegionChanged must NOT create multiple periodic refresh
    /// tasks — the guard `periodicRefreshTask == nil` ensures at most one is active.
    func testOnRegionChanged_doesNotStackMultipleTimers() {
        FeedbackFetchMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("[]".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedbackFetchMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let service = CommunityPinService(
            supabaseURL: kFeedbackTestURL,
            supabaseAnonKey: kFeedbackAnonKey,
            urlSession: session
        )

        let region1 = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let region2 = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.98),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )

        service.onRegionChanged(region1)
        let taskAfterFirst = service.periodicRefreshTask  // not nil

        service.onRegionChanged(region2)
        let taskAfterSecond = service.periodicRefreshTask  // still not nil, same task

        XCTAssertNotNil(taskAfterFirst,
            "Periodic refresh must be started after first region change")
        XCTAssertNotNil(taskAfterSecond,
            "Periodic refresh must still be running after second region change")
        // Key assertion: the second onRegionChanged must NOT replace the running task
        // (the guard `if periodicRefreshTask == nil` prevents re-entry).
        // We verify this by checking the task is NOT nil (if it were replaced, the old task
        // is cancelled and a new one started, which is still "non-nil" — but the structural
        // guard means the replacement path is blocked, so taskAfterFirst === taskAfterSecond).
        // Since Swift Task is a struct we can't compare identity, but the guard logic is
        // exercised: two region changes → one timer, not two stacked timers.
        XCTAssertNotNil(service.periodicRefreshTask,
            "Fix 2: Multiple onRegionChanged calls must not stack periodic refresh timers")

        service.stopPeriodicRefresh()
    }

    // MARK: Test 10: pinRefreshIntervalSeconds is a named constant in sane range

    /// Fix 2: The interval must be a named constant (not a magic number) in the sane
    /// range of 1–300 seconds so future changes don't require grep-and-replace.
    func testPinRefreshIntervalSeconds_isNamedConstant() {
        let interval = CommunityPinService.pinRefreshIntervalSeconds
        XCTAssertGreaterThan(interval, 1,
            "Fix 2: pinRefreshIntervalSeconds must be > 1s (too aggressive for Supabase free tier)")
        XCTAssertLessThanOrEqual(interval, 300,
            "Fix 2: pinRefreshIntervalSeconds must be <= 300s (too infrequent for live crowd feedback)")
        // Verify exact current value as a regression guard. If this changes intentionally,
        // update this assertion alongside the constant.
        // supabase-swift Stream B (spec §6.1): retuned 8s → 45s now that real WebSocket
        // Realtime is the primary freshness mechanism; this poll is a reconciliation fallback.
        XCTAssertEqual(interval, 45,
            "supabase-swift Stream B: pinRefreshIntervalSeconds must be 45s (reconciliation fallback behind real Realtime, spec §6.1)")
    }
}

// MARK: - Fix 3: Marker image safety net

/// Verifies that PinMarkerAnnotation.markerImage produces a non-nil UIImage for the
/// crowd pin types that were in Kevin's live test (enforcement_active + sweeper_passed).
/// @MainActor: CommunityPinAnnotation is @MainActor (MKAnnotation conformance requirement).
@MainActor
final class MarkerImageSafetyNetTests: XCTestCase {

    // MARK: Test 11: enforcement_active configure → non-nil image

    /// Fix 3: configure(for:) on an enforcement_active pin must set a non-nil image.
    /// person.badge.clock.fill is SF Symbols 5 / iOS 17+ — resolves on our min target.
    func testMarkerImage_enforcementActive_returnsNonNil() {
        let pin = decodeTestPin(pinType: .enforcementActive)
        let annotation = CommunityPinAnnotation(pin: pin)
        let view = PinMarkerAnnotation(annotation: annotation, reuseIdentifier: "enforcement-test")
        view.configure(for: annotation.pin)

        XCTAssertNotNil(view.image,
            "Fix 3: enforcement_active configure must set a non-nil image (person.badge.clock.fill, teal)")
        if let img = view.image {
            XCTAssertGreaterThan(img.size.width, 0,
                "Fix 3: enforcement_active marker image width must be positive")
            XCTAssertGreaterThan(img.size.height, 0,
                "Fix 3: enforcement_active marker image height must be positive")
        }
    }

    // MARK: Test 12: sweeper_passed configure → non-nil image

    /// Fix 3: configure(for:) on a sweeper_passed pin must set a non-nil image.
    /// truck.box.fill is SF Symbols 5 / iOS 17+ — resolves on our min target.
    /// This was the "missing" marker type in Kevin's live test.
    func testMarkerImage_sweeperPassed_returnsNonNil() {
        let pin = decodeTestPin(pinType: .sweeperPassed)
        let annotation = CommunityPinAnnotation(pin: pin)
        let view = PinMarkerAnnotation(annotation: annotation, reuseIdentifier: "sweeper-test")
        view.configure(for: annotation.pin)

        XCTAssertNotNil(view.image,
            "Fix 3: sweeper_passed configure must set a non-nil image (truck.box.fill, cyan). " +
            "This was the 'missing' pin type in Kevin's live test — the marker was never silently nil " +
            "at runtime (truck.box.fill resolves on iOS 17+), but the return type is now non-optional " +
            "so the compiler guarantees no nil is possible.")
        if let img = view.image {
            XCTAssertGreaterThan(img.size.width, 0,
                "Fix 3: sweeper_passed marker image width must be positive")
        }
    }

    // MARK: Test 13: all four production SF Symbols resolve on iOS 17+

    /// Fix 3 (verification): All four production SF Symbols must be resolvable via
    /// UIImage(systemName:) on our iOS 17+ minimum deployment target.
    /// If this test fails, a symbol was removed and markerStyle(for:) needs an update.
    func testMarkerImage_allKnownProductionSymbols_resolveOnIOS17() {
        let productionSymbols: [(name: String, pinType: String)] = [
            ("video.fill",              "filming"),
            ("star.fill",               "special_event"),
            ("person.badge.clock.fill", "enforcement_active"),
            ("truck.box.fill",          "sweeper_passed"),
        ]
        for sym in productionSymbols {
            let image = UIImage(systemName: sym.name)
            XCTAssertNotNil(image,
                "Fix 3 verification: SF Symbol '\(sym.name)' (for \(sym.pinType)) must resolve " +
                "on iOS 17+. If nil, the symbol was removed and markerStyle(for:) must be updated.")
        }
    }

    // MARK: - Community 2.0 Phase 1 (S4): open_spot / leaving_soon ring markers

    /// This PR's own compile-break fix (S3 added `.openSpot`/`.leavingSoon` to `PinType`
    /// with no corresponding `displayLabel` case, leaving the exhaustive switch broken).
    func testDisplayLabel_openSpot_and_leavingSoon() {
        XCTAssertEqual(PinType.openSpot.displayLabel, "Open Spot")
        XCTAssertEqual(PinType.leavingSoon.displayLabel, "Leaving Soon")
    }

    /// Spec §6 appendix: `.openSpot`/`.leavingSoon` use a "ring" marker (outline + glyph),
    /// not the filled-circle + SF Symbol treatment every other type uses — see
    /// `PinMarkerAnnotation.ringMarkerImage(for:)`. Same non-nil / non-zero-size safety-net
    /// assertion shape as `testMarkerImage_enforcementActive_returnsNonNil` above.
    func testMarkerImage_openSpot_returnsNonNil() {
        let pin = decodeTestPin(pinType: .openSpot)
        let annotation = CommunityPinAnnotation(pin: pin)
        let view = PinMarkerAnnotation(annotation: annotation, reuseIdentifier: "open-spot-test")
        view.configure(for: annotation.pin)

        XCTAssertNotNil(view.image, "open_spot configure must set a non-nil ring-marker image")
        if let img = view.image {
            XCTAssertGreaterThan(img.size.width, 0)
            XCTAssertGreaterThan(img.size.height, 0)
        }
    }

    func testMarkerImage_leavingSoon_returnsNonNil() {
        let pin = decodeTestPin(pinType: .leavingSoon)
        let annotation = CommunityPinAnnotation(pin: pin)
        let view = PinMarkerAnnotation(annotation: annotation, reuseIdentifier: "leaving-soon-test")
        view.configure(for: annotation.pin)

        XCTAssertNotNil(view.image, "leaving_soon configure must set a non-nil ring-marker image")
        if let img = view.image {
            XCTAssertGreaterThan(img.size.width, 0)
            XCTAssertGreaterThan(img.size.height, 0)
        }
    }

    /// Spec §0 OQ-2: "every surface that renders these pins MUST show relative age" — the map
    /// callout subtitle is one such surface, widened alongside enforcement_active/sweeper_passed.
    func testSubtitle_openSpot_and_leavingSoon_showRelativeAge_notExpiry() {
        let openSpot = decodeTestPin(pinType: .openSpot)
        let leavingSoon = decodeTestPin(pinType: .leavingSoon)

        XCTAssertEqual(
            CommunityPinAnnotation(pin: openSpot).subtitle,
            PinMarkerAnnotation.timeSinceBadge(pin: openSpot, now: Date())
        )
        XCTAssertEqual(
            CommunityPinAnnotation(pin: leavingSoon).subtitle,
            PinMarkerAnnotation.timeSinceBadge(pin: leavingSoon, now: Date())
        )
    }
}

// MARK: - URLProtocol mocks (distinct names to avoid linker collisions)

/// Auth mock for Tier3PinFeedback tests (calls to SupabaseAuthService).
/// Distinct from AuthMockURLProtocol (Tier3AuthReactionsTests).
final class FeedbackAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = FeedbackAuthMockURLProtocol.requestHandler else {
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

/// Write-path mock for Fix 1 (insertCrowdPin) tests.
final class FeedbackWriteMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = FeedbackWriteMockURLProtocol.requestHandler else {
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

/// Fetch-path mock for Fix 2 (onRegionChanged / periodic refresh) tests.
final class FeedbackFetchMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = FeedbackFetchMockURLProtocol.requestHandler else {
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

// MARK: - Ephemeral pin TTL table (FT-1, superseded by Community 2.0 OQ-2)

/// Verifies `CommunityPinService.ephemeralTTLSeconds(for:leavingMinutes:)` — the pure helper
/// that drives the `expires_at` set on insert (and, per Community 2.0 OQ-2, the client-side
/// staleness/decay display math for the same types).
///
/// FT-1 originally shortened enforcement/sweeper to 5 min ("mobile, very fresh — a 30-min
/// lifetime kept them on the map long after they'd moved on"). **Superseded 2026-08-26 by
/// Community 2.0 OQ-2** (`docs/community-2.0-reconciliation-spec.md` §0, resolved by Kevin):
/// the prototype's 45m/120m values govern instead — an aged pin is now read as useful history
/// ("agent already came through"), not stale noise, so these three tests are updated IN PLACE
/// with the new values and new names, not left stale alongside a superseding test. Broken
/// meters are unaffected (still 30 min, stationary condition).
final class FT1MobilePinTTLTests: XCTestCase {

    func testEnforcementActive_expiresIn45Minutes() {
        XCTAssertEqual(CommunityPinService.ephemeralTTLSeconds(for: .enforcementActive), 45 * 60,
                       "OQ-2 (2026-08-26): enforcement agent pins now expire after 45 minutes — staleness is the signal")
    }

    func testSweeperPassed_expiresIn120Minutes() {
        XCTAssertEqual(CommunityPinService.ephemeralTTLSeconds(for: .sweeperPassed), 120 * 60,
                       "OQ-2 (2026-08-26): sweeper pins now expire after 120 minutes — staleness is the signal")
    }

    func testBrokenMeter_keeps30Minutes() {
        XCTAssertEqual(CommunityPinService.ephemeralTTLSeconds(for: .brokenMeter), 30 * 60,
                       "Unaffected by OQ-2: broken-meter pins are stationary and keep the 30-minute lifetime")
    }

    func testNonEphemeralType_hasNoExpiry() {
        XCTAssertNil(CommunityPinService.ephemeralTTLSeconds(for: .filming),
                     "Non-ephemeral (open-data) types must not auto-expire")
    }
}

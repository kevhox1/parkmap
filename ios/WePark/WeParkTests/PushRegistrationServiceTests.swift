//
//  PushRegistrationServiceTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 4b — iOS side (build 20, S12).
//  Spec: docs/community-2.0-reconciliation-spec.md §2.9 + §3 Phase 4 +
//  docs/community-2.0-roadmap.md S12 row (incl. WP5 rider).
//
//  Test inventory (28 tests; +2 in PR #101 QA pass 1 fix — the wire-level gap QA flagged):
//    APNSEnvironmentTests (4):
//      1. testParse_developmentProfile_returnsSandbox
//      2. testParse_productionProfile_returnsProduction
//      3. testParse_nilProfileString_returnsProduction
//      4. testParse_malformedProfileString_returnsProduction
//    PushTokenUpsertPayloadTests (1):
//      5. testTokenUpsertPayload_containsUserIdEnvironmentZone
//    CommunityPushRelevanceIsRelevantTests (8):
//      6. testIsRelevant_sweeperPassed_matchingSegment_true
//      7. testIsRelevant_enforcementActive_matchingSegment_true
//      8. testIsRelevant_differentSegments_false
//      9. testIsRelevant_noParkedCar_nilSegment_false
//      10. testIsRelevant_pinHasNilSegment_false
//      11. testIsRelevant_openSpot_ownBlockMatch_false
//      12. testIsRelevant_leavingSoon_ownBlockMatch_false
//      13. testIsRelevant_unrelatedType_filming_false
//    CommunityPushRelevanceNotificationCopyTests (4):
//      14. testNotificationCopy_sweeperPassed_hasComplianceCopy
//      15. testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage
//      16. testNotificationCopy_openSpot_nil
//      17. testNotificationCopy_filming_nil
//    CommunityPushRelevanceFirstUnseenSweeperPassedMatchTests (4):
//      18. testFirstUnseenMatch_matchingUnseenPin_returned
//      19. testFirstUnseenMatch_alreadySeenPin_skipped
//      20. testFirstUnseenMatch_wrongType_skipped
//      21. testFirstUnseenMatch_noParkedCar_nil
//    CommunityPushDedupeStoreTests (5):
//      22. testHasSeen_freshStore_false
//      23. testMarkSeen_thenHasSeen_true
//      24. testMarkSeen_isIdempotent_noDuplicateEntries
//      25. testMarkSeen_boundedTrim_dropsOldestBeyondMaxEntries
//      26. testSeenIds_skipsMalformedEntries
//    PushRegistrationServiceWireTests (3, PR #101 QA pass 1 fix — wire-level, not just the
//    pure payload-dict test above; closes the exact gap that let Finding #1 ship; +1 in
//    S13a fold-in for the foreground double-POST fix):
//      27. testUpsertToken_requestIncludesOnConflictAndMergeDuplicatesPreferHeader
//      28. testAttemptUpsert_sameCandidateTwice_secondCallSkipsNetwork
//      29. testAttemptUpsert_backToBackCallsBeforeFirstCompletes_onlyOneNetworkRequest
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
@testable import WePark

// MARK: - Shared fixture helper

/// Builds a fixture `CommunityPin` with `segment_id`/`confirm_count` overrides —
/// `CommunityPinServiceTests.makeFixturePin` (that file's own private helper) hardcodes both
/// to `null`/`0`, which this file's relevance/dedupe tests need to vary. Kept local to this
/// file (not shared) to avoid touching `CommunityPinServiceTests.swift`, out of this
/// session's scope.
private func makePushFixturePin(
    id: UUID = UUID(),
    pinType: PinType = .sweeperPassed,
    segmentId: String? = "MOTT ST|1|E",
    confirmCount: Int = 3
) -> CommunityPin {
    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": 40.7217,
      "lng": -73.9950,
      "segment_id": \(segmentId.map { #""\#($0)""# } ?? "null"),
      "zone_id": "nolita",
      "author_id": null,
      "author_username": null,
      "created_at": "2026-09-03T10:00:00+00:00",
      "updated_at": "2026-09-03T10:00:00+00:00",
      "expires_at": "2026-09-03T12:00:00+00:00",
      "resolved_at": null,
      "confirm_count": \(confirmCount),
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Cannot decode date: \(string)")
        )
    }
    return try! decoder.decode(CommunityPin.self, from: Data(json.utf8))
}

// MARK: - 1. APNSEnvironment tests

final class APNSEnvironmentTests: XCTestCase {

    private func plistString(apsEnvironment: String) -> String {
        """
        garbage-CMS-bytes-before\
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>aps-environment</key>
                <string>\(apsEnvironment)</string>
            </dict>
        </dict>
        </plist>
        garbage-CMS-bytes-after
        """
    }

    func testParse_developmentProfile_returnsSandbox() {
        let result = APNSEnvironment.parse(profileString: plistString(apsEnvironment: "development"))
        XCTAssertEqual(result, APNSEnvironment.sandbox)
    }

    func testParse_productionProfile_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: plistString(apsEnvironment: "production"))
        XCTAssertEqual(result, APNSEnvironment.production)
    }

    /// The load-bearing failure mode: App Store Connect (TestFlight + App Store) strips
    /// `embedded.mobileprovision` entirely, so `profileString == nil` is the NORMAL path for
    /// every such install — `.production` is the correct, deliberate fallback.
    func testParse_nilProfileString_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: nil)
        XCTAssertEqual(result, APNSEnvironment.production)
    }

    func testParse_malformedProfileString_returnsProduction() {
        let result = APNSEnvironment.parse(profileString: "not a plist at all, no xml markers here")
        XCTAssertEqual(result, APNSEnvironment.production)
    }
}

// MARK: - 2. Token-upsert payload shape tests

final class PushTokenUpsertPayloadTests: XCTestCase {

    func testTokenUpsertPayload_containsUserIdEnvironmentZone() {
        let userId = UUID()
        let payload = PushRegistrationService.tokenUpsertPayload(
            userId: userId,
            tokenHex: "abcd1234",
            environment: APNSEnvironment.sandbox,
            zoneId: "nolita"
        )
        XCTAssertEqual(payload["user_id"] as? String, userId.uuidString)
        XCTAssertEqual(payload["apns_token"] as? String, "abcd1234")
        XCTAssertEqual(payload["environment"] as? String, "sandbox")
        XCTAssertEqual(payload["zone_id"] as? String, "nolita")
        XCTAssertEqual(payload.count, 4, "payload must contain exactly these 4 keys — never lat/lng, never segment_id")
    }
}

// MARK: - 3. CommunityPushRelevance.isRelevant tests

final class CommunityPushRelevanceIsRelevantTests: XCTestCase {

    func testIsRelevant_sweeperPassed_matchingSegment_true() {
        XCTAssertTrue(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_enforcementActive_matchingSegment_true() {
        XCTAssertTrue(CommunityPushRelevance.isRelevant(
            pinType: .enforcementActive, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_differentSegments_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "ELIZABETH ST|1|W"
        ))
    }

    func testIsRelevant_noParkedCar_nilSegment_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: nil
        ))
    }

    func testIsRelevant_pinHasNilSegment_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .sweeperPassed, pinSegmentId: nil, parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    /// spec §3 Phase 4b item 2: open_spot/leaving_soon on your own block is never relevant to
    /// a parked user, even on an exact segment match.
    func testIsRelevant_openSpot_ownBlockMatch_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .openSpot, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_leavingSoon_ownBlockMatch_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .leavingSoon, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }

    func testIsRelevant_unrelatedType_filming_false() {
        XCTAssertFalse(CommunityPushRelevance.isRelevant(
            pinType: .filming, pinSegmentId: "MOTT ST|1|E", parkedCarSegmentId: "MOTT ST|1|E"
        ))
    }
}

// MARK: - 4. CommunityPushRelevance.notificationCopy tests

final class CommunityPushRelevanceNotificationCopyTests: XCTestCase {

    func testNotificationCopy_sweeperPassed_hasComplianceCopy() {
        let copy = CommunityPushRelevance.notificationCopy(for: .sweeperPassed)
        XCTAssertEqual(copy?.title, "Sweeper reported on your block")
        XCTAssertFalse(copy?.body.isEmpty ?? true)
    }

    /// AC parity with the rest of this codebase's "no avoid/ticket/fine/evasion/dodge" copy
    /// convention (mirrors ReportSheet's own AC-R17), and verbatim-matches direction doc §6's
    /// "move your car / feed the meter" framing, never ticket-avoidance language.
    func testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage() {
        let copy = CommunityPushRelevance.notificationCopy(for: .enforcementActive)
        XCTAssertEqual(copy?.title, "Enforcement active on your block")
        let combined = ((copy?.title ?? "") + " " + (copy?.body ?? "")).lowercased()
        for forbidden in ["avoid", "ticket", "fine", "evasion", "dodge"] {
            XCTAssertFalse(combined.contains(forbidden), "copy must not contain '\(forbidden)'")
        }
        XCTAssertTrue(combined.contains("move your car") || combined.contains("feed the meter"))
    }

    func testNotificationCopy_openSpot_nil() {
        XCTAssertNil(CommunityPushRelevance.notificationCopy(for: .openSpot))
    }

    func testNotificationCopy_filming_nil() {
        XCTAssertNil(CommunityPushRelevance.notificationCopy(for: .filming))
    }
}

// MARK: - 5. CommunityPushRelevance.firstUnseenSweeperPassedMatch tests (WP5)

final class CommunityPushRelevanceFirstUnseenSweeperPassedMatchTests: XCTestCase {

    func testFirstUnseenMatch_matchingUnseenPin_returned() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: []
        )
        XCTAssertEqual(result?.id, pin.id)
    }

    func testFirstUnseenMatch_alreadySeenPin_skipped() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: [pin.id]
        )
        XCTAssertNil(result)
    }

    func testFirstUnseenMatch_wrongType_skipped() {
        let pin = makePushFixturePin(pinType: .enforcementActive, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: "MOTT ST|1|E", seenPinIds: []
        )
        XCTAssertNil(result, "firstUnseenSweeperPassedMatch is scoped to sweeper_passed only")
    }

    func testFirstUnseenMatch_noParkedCar_nil() {
        let pin = makePushFixturePin(pinType: .sweeperPassed, segmentId: "MOTT ST|1|E")
        let result = CommunityPushRelevance.firstUnseenSweeperPassedMatch(
            pins: [pin], parkedCarSegmentId: nil, seenPinIds: []
        )
        XCTAssertNil(result)
    }
}

// MARK: - 6. CommunityPushDedupeStore tests

final class CommunityPushDedupeStoreTests: XCTestCase {

    private let suiteName = "com.wepark.test.communitypushdedupestore"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testHasSeen_freshStore_false() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        XCTAssertFalse(store.hasSeen(UUID()))
    }

    func testMarkSeen_thenHasSeen_true() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        let id = UUID()
        store.markSeen(id)
        XCTAssertTrue(store.hasSeen(id))
    }

    func testMarkSeen_isIdempotent_noDuplicateEntries() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        let id = UUID()
        store.markSeen(id)
        store.markSeen(id)
        XCTAssertEqual(store.seenIds().count, 1)
    }

    func testMarkSeen_boundedTrim_dropsOldestBeyondMaxEntries() {
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen", maxEntries: 2)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        store.markSeen(first)
        store.markSeen(second)
        store.markSeen(third)
        XCTAssertFalse(store.hasSeen(first), "the oldest entry must be trimmed once maxEntries is exceeded")
        XCTAssertTrue(store.hasSeen(second))
        XCTAssertTrue(store.hasSeen(third))
        XCTAssertEqual(store.seenIds().count, 2)
    }

    func testSeenIds_skipsMalformedEntries() {
        ephemeralDefaults.set(["not-a-uuid", UUID().uuidString], forKey: "test.seen")
        let store = CommunityPushDedupeStore(defaults: ephemeralDefaults, key: "test.seen")
        XCTAssertEqual(store.seenIds().count, 1, "a malformed stored entry must be skipped, not crash")
    }
}

// MARK: - 7. PushRegistrationService wire-level tests (PR #101 QA pass 1 fix)
//
// QA pass 1 (docs/qa/pr101-community-phase4b-ios.md, Finding #1) flagged that the original 26
// tests only asserted on `tokenUpsertPayload`'s pure dictionary output — nothing exercised
// `attemptUpsert`/`upsertToken`'s ACTUAL `URLRequest` (URL, query string, headers), which is
// exactly the gap that let the missing `on_conflict` parameter ship undetected. These tests
// close that gap using the same `PinMockURLProtocol`-style request-interception pattern this
// repo already established (`WeParkTests/CommunityPinServiceTests.swift`,
// `WeParkTests/Tier3AuthReactionsTests.swift`) — distinctly named per-file mocks to avoid
// shared static-state races across test files in the same target.

/// Thread-safe mock URLProtocol for `SupabaseAuthService`'s own network calls, scoped to this
/// file only (distinct from `AuthMockURLProtocol` in `Tier3AuthReactionsTests.swift` and
/// `SeamMockURLProtocol` in `SupabaseAuthServiceTests.swift`).
final class PushAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PushAuthMockURLProtocol.requestHandler else {
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

/// Mock URLProtocol for `PushRegistrationService`'s own `device_push_tokens` POST — distinct
/// from `PushAuthMockURLProtocol` above (auth SDK traffic) and every other file's mock.
final class PushTokenMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = PushTokenMockURLProtocol.requestHandler else {
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

private let kPushAuthURL = URL(string: "https://push-wire-test.supabase.co")!
private let kPushAnonKey = "test-anon-key-push-wire"
private let kPushUser = UUID(uuidString: "C0000001-0000-0000-0000-000000000001")!

/// Valid Supabase Auth SDK `Session` JSON — same shape verified in
/// `SupabaseAuthServiceTests.swift`/`Tier3AuthReactionsTests.swift` against the SDK's actual
/// `Decodable` requirements.
private func pushWireSessionJSON(userId: UUID = kPushUser) -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.push-wire-test.token",
      "refresh_token": "refresh-push-wire-test",
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

private func pushTokenMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PushTokenMockURLProtocol.self]
    return URLSession(configuration: config)
}

@MainActor
final class PushRegistrationServiceWireTests: XCTestCase {

    /// Builds a `PushRegistrationService` wired to a pre-authenticated `SupabaseAuthService`
    /// (mirrors `Tier3AuthReactionsTests.makeAuthenticatedPair`'s exact pattern) and a
    /// `PushTokenMockURLProtocol`-backed `URLSession` for its own `device_push_tokens` traffic.
    /// `environmentProvider` is injected as a fixed `"sandbox"` so these tests never depend on
    /// `APNSEnvironment.detectCurrent()`'s real bundle read.
    private func makeAuthenticatedService() async -> PushRegistrationService {
        let authSession = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PushAuthMockURLProtocol.self]
            return config
        }())
        let authService = SupabaseAuthService(
            supabaseURL: kPushAuthURL,
            supabaseAnonKey: kPushAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await authSession.data(for: $0) }
        )
        PushAuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kPushAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             pushWireSessionJSON())
        }
        await authService.ensureSession()

        return PushRegistrationService(
            supabaseURL: kPushAuthURL,
            supabaseAnonKey: kPushAnonKey,
            authService: authService,
            urlSession: pushTokenMockSession(),
            environmentProvider: { "sandbox" },
            // `AppConstants.communityEnabled` is hardcoded `false` on this branch — inject
            // `{ true }` here rather than depending on the global flag, so these wire tests
            // actually exercise the service's write path instead of no-oping on the flag
            // guard. See `communityEnabledProvider`'s own doc comment in
            // `PushRegistrationService.swift` for why this seam exists.
            communityEnabledProvider: { true }
        )
    }

    /// Finding #1's fix, verified at the wire: the actual outgoing `URLRequest` for a token
    /// upsert must carry `on_conflict=user_id,apns_token` (the table's real unique constraint)
    /// AND the `Prefer: resolution=merge-duplicates` header — asserting the pure
    /// `tokenUpsertPayload` dictionary alone (the pre-fix test coverage) would not have caught
    /// the missing query parameter, since that function never touches the URL.
    func testUpsertToken_requestIncludesOnConflictAndMergeDuplicatesPreferHeader() async throws {
        let service = await makeAuthenticatedService()

        var capturedURL: URL? = nil
        var capturedPreferHeader: String? = nil
        PushTokenMockURLProtocol.requestHandler = { request in
            capturedURL = request.url
            capturedPreferHeader = request.value(forHTTPHeaderField: "Prefer")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        service.didReceiveDeviceToken(Data([0x01, 0x02, 0x03, 0x04]))
        service.updateZone("nolita")
        await service.inFlightUpload?.value

        let components = capturedURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let onConflictValue = components?.queryItems?.first(where: { $0.name == "on_conflict" })?.value
        XCTAssertEqual(onConflictValue, "user_id,apns_token",
            "upsertToken's request must carry on_conflict=user_id,apns_token (device_push_tokens' real unique constraint), got URL: \(capturedURL?.absoluteString ?? "nil")")
        XCTAssertTrue(capturedPreferHeader?.contains("resolution=merge-duplicates") == true,
            "upsertToken's request must include Prefer: resolution=merge-duplicates, got: \(capturedPreferHeader ?? "nil")")
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/device_push_tokens") == true,
            "request path must still target rest/v1/device_push_tokens, got: \(components?.path ?? "nil")")
    }

    /// `attemptUpsert`'s dedupe-by-`lastUploaded` logic: calling `updateZone` a second time
    /// with the SAME zone (token/environment also unchanged) must not fire a second network
    /// request — QA pass 1 flagged this as an untested gap alongside Finding #1's fix.
    func testAttemptUpsert_sameCandidateTwice_secondCallSkipsNetwork() async throws {
        let service = await makeAuthenticatedService()

        var requestCount = 0
        PushTokenMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        service.didReceiveDeviceToken(Data([0x0A, 0x0B]))
        service.updateZone("soho")
        await service.inFlightUpload?.value
        XCTAssertEqual(requestCount, 1, "the first upsert for a new (token, environment, zone) triple must hit the network")

        // Same zone again — attemptUpsert's `candidate != lastUploaded` guard should skip.
        service.updateZone("soho")
        await service.inFlightUpload?.value
        XCTAssertEqual(requestCount, 1, "re-deriving the SAME zone must not fire a second network request")

        // A genuinely different zone must fire again.
        service.updateZone("les")
        await service.inFlightUpload?.value
        XCTAssertEqual(requestCount, 2, "a real zone change must trigger a new upsert")
    }

    /// S13a fold-in (open item #13, "foreground double-POST"): calling `updateZone` and
    /// `handleAppForeground` back-to-back on the SAME synchronous turn — WITHOUT awaiting
    /// the first call's `inFlightUpload` in between — must fire only ONE network request,
    /// not two. This reproduces `ContentView.handleScenePhaseChange`'s `.active` branch
    /// exactly: `updatePushZoneFromParkedCarOrLocation()` (→ `updateZone`) immediately
    /// followed by `pushRegistrationService.handleAppForeground()`, same candidate, same
    /// turn. `testAttemptUpsert_sameCandidateTwice_secondCallSkipsNetwork` above does NOT
    /// cover this — it awaits `inFlightUpload` between calls, so `lastUploaded` is already
    /// written by the time the second call runs. This test deliberately does NOT await in
    /// between, reproducing the race `lastUploaded` alone cannot catch.
    func testAttemptUpsert_backToBackCallsBeforeFirstCompletes_onlyOneNetworkRequest() async throws {
        let service = await makeAuthenticatedService()

        var requestCount = 0
        PushTokenMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        service.didReceiveDeviceToken(Data([0x0C, 0x0D]))
        service.updateZone("nolita")
        // Deliberately NOT awaiting inFlightUpload here — this is the race window the fix closes.
        service.handleAppForeground()
        await service.inFlightUpload?.value

        XCTAssertEqual(requestCount, 1,
            "a redundant handleAppForeground() call issued before the first attemptUpsert's Task has run must not fire a second network request for the identical candidate")
    }
}

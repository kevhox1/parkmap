//
//  CommunityZoneStampingTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2a (build 20 S6) — write-time zone stamping.
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2;
//  docs/community-2.0-roadmap.md S6 row (PR #94 QA Finding #3 follow-up).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (9 tests):
//    CommunityPinService.resolveZoneId(explicit:lat:lng:) — pure function:
//      1. testResolveZoneId_explicitWins_evenInsideABox
//      2. testResolveZoneId_nilExplicit_insideNolita_returnsNolita
//      3. testResolveZoneId_nilExplicit_insideSoho_returnsSoho
//      4. testResolveZoneId_nilExplicit_insideLes_returnsLes
//      5. testResolveZoneId_nilExplicit_outsideAllBoxes_returnsNil
//      6. testResolveZoneId_nilExplicit_onNolitaBoundary_returnsNolita
//
//    insertCrowdPin integration — request payload actually carries the resolved value:
//      7. testInsertCrowdPin_noExplicitZone_insideNolita_stampsZoneIdInPayload
//      8. testInsertCrowdPin_noExplicitZone_outsideAllZones_omitsZoneIdKey
//      9. testInsertCrowdPin_explicitZone_notOverriddenByBoxMatch
//

import XCTest
@testable import WePark

// MARK: - resolveZoneId (pure function, no auth/network needed)

final class ResolveZoneIdTests: XCTestCase {

    func testResolveZoneId_explicitWins_evenInsideABox() {
        // (40.7230, -73.9950) is inside the nolita box, but an explicit zoneId must never
        // be second-guessed by the box-match fallback.
        let result = CommunityPinService.resolveZoneId(explicit: "soho-les", lat: 40.7230, lng: -73.9950)
        XCTAssertEqual(result, "soho-les")
    }

    func testResolveZoneId_nilExplicit_insideNolita_returnsNolita() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7230, lng: -73.9950)
        XCTAssertEqual(result, "nolita")
    }

    func testResolveZoneId_nilExplicit_insideSoho_returnsSoho() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7225, lng: -74.0000)
        XCTAssertEqual(result, "soho")
    }

    func testResolveZoneId_nilExplicit_insideLes_returnsLes() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7200, lng: -73.9850)
        XCTAssertEqual(result, "les")
    }

    /// A coordinate outside all three zone boxes must resolve to a genuinely-null zone_id,
    /// never a guessed/default zone.
    func testResolveZoneId_nilExplicit_outsideAllBoxes_returnsNil() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.70, lng: -74.02)
        XCTAssertNil(result)
    }

    /// Boundary: the nolita box's own min lat/lng corner (inclusive per
    /// `CommunityZoneBounds.zoneId`'s `>=`/`<=` comparisons).
    func testResolveZoneId_nilExplicit_onNolitaBoundary_returnsNolita() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7217, lng: -73.9967)
        XCTAssertEqual(result, "nolita")
    }
}

// MARK: - insertCrowdPin integration — payload actually carries the resolved zone_id

/// Local mock plumbing, mirroring `Tier3AuthReactionsTests`'s `WriteMockURLProtocol` /
/// `AuthMockURLProtocol` pattern but file-scoped (this project's convention: file-private
/// mock URLProtocols + helpers per test file, to avoid shared static state races between
/// files running in parallel — see that file's own header comment).
private let kZoneStampAuthURL = URL(string: "https://zone-stamp-test.supabase.co")!
private let kZoneStampAnonKey = "test-anon-key-zone-stamp"
private let kZoneStampUser = UUID(uuidString: "B0000001-0000-0000-0000-000000000001")!

private func zoneStampAuthResponseJSON() -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.test.token",
      "refresh_token": "refresh-test-token",
      "token_type": "bearer",
      "expires_in": 3600,
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(kZoneStampUser.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

private func zoneStampAuthMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zoneStampWriteMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zoneStampBodyData(from request: URLRequest) -> Data? {
    if let data = request.httpBody, !data.isEmpty { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 1024
    var buf = [UInt8](repeating: 0, count: bufSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buf, maxLength: bufSize)
        guard read > 0 else { break }
        data.append(contentsOf: buf[0..<read])
    }
    return data.isEmpty ? nil : data
}

@MainActor
final class InsertCrowdPinZoneStampingTests: XCTestCase {

    private func makeAuthenticatedPair() async -> (CommunityPinService, SupabaseAuthService) {
        let mockSession = zoneStampAuthMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kZoneStampAuthURL,
            supabaseAnonKey: kZoneStampAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )
        AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kZoneStampAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             zoneStampAuthResponseJSON())
        }
        await authService.ensureSession()

        let pinService = CommunityPinService(
            supabaseURL: kZoneStampAuthURL,
            supabaseAnonKey: kZoneStampAnonKey,
            urlSession: zoneStampWriteMockSession(),
            authService: authService
        )
        return (pinService, authService)
    }

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testInsertCrowdPin_noExplicitZone_insideNolita_stampsZoneIdInPayload() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7230,
            lng: -73.9950,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "nolita",
            "A pin inside the nolita box with no explicit zoneId must be stamped 'nolita' at write time")
    }

    func testInsertCrowdPin_noExplicitZone_outsideAllZones_omitsZoneIdKey() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.70,
            lng: -74.02,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertNil(capturedBody?["zone_id"],
            "A coordinate outside all three zone boxes must leave zone_id genuinely absent, never a guessed value")
    }

    func testInsertCrowdPin_explicitZone_notOverriddenByBoxMatch() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        // (40.7230, -73.9950) box-matches "nolita" — but an explicit zoneId must win.
        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7230,
            lng: -73.9950,
            segmentId: nil,
            zoneId: "soho-les",
            notes: nil
        )

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "soho-les",
            "An explicit caller-supplied zoneId must never be silently replaced by the box-match fallback")
    }
}

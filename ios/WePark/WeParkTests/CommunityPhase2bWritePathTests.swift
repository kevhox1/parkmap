//
//  CommunityPhase2bWritePathTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2b (build 20 S7) — write-path payload-shape tests for
//  `CommunityPinService.insertCrowdPin`'s new `positionFraction`/`leavingMinutes`
//  parameters and the net-new `upsertProfile(username:avatar:)` method.
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (8 tests):
//    insertCrowdPin — positionFraction/leavingMinutes payload inclusion:
//      1. testInsertCrowdPin_positionFractionProvided_includedInPayload
//      2. testInsertCrowdPin_positionFractionNil_omittedFromPayload
//      3. testInsertCrowdPin_leavingMinutesProvided_includedInPayload
//      4. testInsertCrowdPin_leavingMinutesNil_omittedFromPayload
//      5. testInsertCrowdPin_openSpotType_positionFraction_bothWrittenTogether
//
//    upsertProfile — payload shape + request headers:
//      6. testUpsertProfile_payloadShape_idUsernameAvatar
//      7. testUpsertProfile_usernameAlwaysIncludedNonEmpty (QA pass 1 fix, PR #96 Finding
//         #1 — replaces the old nil-username test; see that test's own doc comment)
//      8. testUpsertProfile_requestIncludesUpsertPreferHeader
//
//  Reuses the SHARED (not file-private) `WriteMockURLProtocol` / `AuthMockURLProtocol`
//  classes declared once in `Tier3AuthReactionsTests.swift` — see
//  `CommunityZoneStampingTests.swift`'s own header comment (QA pass 1, PR #95 Finding #5)
//  for why this file duplicates its own file-private auth-fixture helpers rather than
//  importing that file's (which are themselves `private`-scoped).
//

import XCTest
@testable import WePark

// MARK: - Shared fixtures (file-private duplicates — see header)

private let kPhase2bAuthURL = URL(string: "https://phase2b-test.supabase.co")!
private let kPhase2bAnonKey = "test-anon-key-phase2b"
private let kPhase2bUser = UUID(uuidString: "C0000001-0000-0000-0000-000000000001")!

private func phase2bAuthResponseJSON() -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.test.token",
      "refresh_token": "refresh-test-token",
      "token_type": "bearer",
      "expires_in": 3600,
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(kPhase2bUser.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

private func phase2bAuthMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func phase2bWriteMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func phase2bBodyData(from request: URLRequest) -> Data? {
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
private func makePhase2bAuthenticatedPair() async -> (CommunityPinService, SupabaseAuthService) {
    let mockSession = phase2bAuthMockSession()
    let authService = SupabaseAuthService(
        supabaseURL: kPhase2bAuthURL,
        supabaseAnonKey: kPhase2bAnonKey,
        testStorage: InMemoryAuthStorage(),
        fetch: { try await mockSession.data(for: $0) }
    )
    AuthMockURLProtocol.requestHandler = { _ in
        (HTTPURLResponse(url: kPhase2bAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         phase2bAuthResponseJSON())
    }
    await authService.ensureSession()

    let pinService = CommunityPinService(
        supabaseURL: kPhase2bAuthURL,
        supabaseAnonKey: kPhase2bAnonKey,
        urlSession: phase2bWriteMockSession(),
        authService: authService
    )
    return (pinService, authService)
}

// MARK: - insertCrowdPin: positionFraction / leavingMinutes payload shape

@MainActor
final class InsertCrowdPinPhase2bPayloadTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testInsertCrowdPin_positionFractionProvided_includedInPayload() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.insertCrowdPin(
            type: .openSpot, meta: nil, lat: 40.7230, lng: -73.9950,
            segmentId: "seg-1", zoneId: nil, notes: nil,
            positionFraction: 0.35
        )

        XCTAssertEqual(capturedBody?["position_fraction"] as? Double, 0.35)
    }

    func testInsertCrowdPin_positionFractionNil_omittedFromPayload() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive, meta: nil, lat: 40.7230, lng: -73.9950,
            segmentId: nil, zoneId: nil, notes: nil
        )

        XCTAssertNil(capturedBody?["position_fraction"],
            "Every pre-existing call site (positionFraction defaulted, not passed) must see no payload change")
    }

    func testInsertCrowdPin_leavingMinutesProvided_includedInPayload() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.insertCrowdPin(
            type: .leavingSoon, meta: nil, lat: 40.7230, lng: -73.9950,
            segmentId: nil, zoneId: nil, notes: nil,
            leavingMinutes: 15
        )

        XCTAssertEqual(capturedBody?["leaving_minutes"] as? Int, 15)
    }

    func testInsertCrowdPin_leavingMinutesNil_omittedFromPayload() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.insertCrowdPin(
            type: .sweeperPassed, meta: nil, lat: 40.7230, lng: -73.9950,
            segmentId: nil, zoneId: nil, notes: nil
        )

        XCTAssertNil(capturedBody?["leaving_minutes"])
    }

    /// `SpotPlacementView`'s real call site shape: an `open_spot` insert always carries a
    /// `positionFraction`, never a `leavingMinutes` — both independently-gated `if let`s
    /// must coexist correctly in one call.
    func testInsertCrowdPin_openSpotType_positionFraction_bothWrittenTogether() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.insertCrowdPin(
            type: .openSpot, meta: nil, lat: 40.7230, lng: -73.9950,
            segmentId: "seg-open-spot", zoneId: nil, notes: nil,
            positionFraction: 0.72
        )

        XCTAssertEqual(capturedBody?["pin_type"] as? String, "open_spot")
        XCTAssertEqual(capturedBody?["position_fraction"] as? Double, 0.72)
        XCTAssertNil(capturedBody?["leaving_minutes"])
        XCTAssertEqual(capturedBody?["segment_id"] as? String, "seg-open-spot")
    }
}

// MARK: - upsertProfile: payload shape + headers

@MainActor
final class UpsertProfilePayloadTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testUpsertProfile_payloadShape_idUsernameAvatar() async throws {
        let (pinService, authService) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.upsertProfile(username: "MottStRegular", avatar: "🗽")

        XCTAssertEqual(capturedBody?["id"] as? String, authService.currentUserId?.uuidString)
        XCTAssertEqual(capturedBody?["username"] as? String, "MottStRegular")
        XCTAssertEqual(capturedBody?["avatar"] as? String, "🗽")
        // The client never writes its own reputation — see upsertProfile's own doc comment.
        XCTAssertNil(capturedBody?["reputation"])
        XCTAssertNil(capturedBody?["helped_count"])
    }

    /// QA pass 1 fix (PR #96, Finding #1): replaces the old
    /// `testUpsertProfile_usernameNil_omittedFromPayload`, which validated a payload shape
    /// (username key omitted) that is a REAL Postgres `NOT NULL` violation against the live
    /// schema (`public.profiles.username`, `supabase/01-mvp-schema.sql:10`, no `DEFAULT` —
    /// PostgREST's upsert validates that constraint on the constructed `INSERT` row BEFORE
    /// conflict resolution, so it fails on every call, not just a first-ever write).
    /// `upsertProfile` no longer accepts a nil `username` at all — this is now a compile-time
    /// guarantee for every caller, not a runtime check. This test instead proves the payload
    /// UNCONDITIONALLY includes a non-empty `username` for whatever value the (now-required)
    /// parameter holds. The client-side guarantee that a non-empty value reaches this method
    /// at all in the first place lives in `IdentitySheet.resolvedUsername(rawHandle:)`
    /// (tested separately, `IdentitySheetTests.swift`).
    func testUpsertProfile_usernameAlwaysIncludedNonEmpty() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = phase2bBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.upsertProfile(username: "MottStRegular", avatar: nil)

        let username = capturedBody?["username"] as? String
        XCTAssertNotNil(username)
        XCTAssertFalse(username?.isEmpty ?? true,
            "The payload must never carry an empty username — public.profiles.username is NOT NULL with no DEFAULT")
    }

    func testUpsertProfile_requestIncludesUpsertPreferHeader() async throws {
        let (pinService, _) = await makePhase2bAuthenticatedPair()
        var capturedRequest: URLRequest? = nil

        WriteMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await pinService.upsertProfile(username: "MottStRegular", avatar: nil)

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates,return=minimal",
            "Must use the same upsert-on-conflict shape as upsertVote — a second identity save from this device overwrites, never duplicates")
    }
}

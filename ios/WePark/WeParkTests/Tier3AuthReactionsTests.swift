//
//  Tier3AuthReactionsTests.swift
//  WeParkTests
//
//  Tier 3 Sub-PR #1 — Unit tests for anonymous auth + write path + reactions.
//  Spec: docs/tier3-auth-and-reactions-spec.md §7 (AC-A1 through AC-V4).
//
//  supabase-swift adoption — Stream A (Auth/Keychain) update
//  (docs/supabase-swift-realtime-spec.md §9, §11): the `SupabaseAuthServiceTests` class that
//  used to live in this file (AC-A1 through AC-A4, 5 tests) has moved to its own file,
//  `WeParkTests/SupabaseAuthServiceTests.swift`, rewritten against the SDK-backed internals
//  (AC-A1 through AC-A5). The two helper methods below (`makeAuthenticatedPair` /
//  `makeAuthenticatedWritePair`) that construct an authenticated `SupabaseAuthService` for the
//  CommunityPinService write-path tests were updated to use the new
//  `SupabaseAuthService(supabaseURL:supabaseAnonKey:testStorage:fetch:)` test-seam initializer
//  (the old `urlSession:`-based initializer no longer exists) — this is the only change in this
//  file; CommunityPinService.swift itself is untouched, and none of the assertions below
//  changed.
//
//  Test inventory (10 tests remain in this file after the move):
//
//  Write path — request shapes (AC-W1, AC-W2, AC-W3, AC-V1):
//    1.  testInsertCrowdPin_requestIncludesAuthorizationHeader      (AC-W1)
//    2.  testInsertCrowdPin_payloadShape                            (AC-W2)
//    3.  testInsertCrowdPin_notAuthenticated_throws                 (AC-W3)
//    4.  testUpsertVote_requestIncludesPreferHeader                 (AC-V1)
//    5.  testUpsertVote_notAuthenticated_throws                     (AC-W3 mirror)
//
//  Reactions UI — own-pin guard logic (AC-V4):
//    6.  testOwnPinGuard_sameId_isOwnPin_true
//    7.  testOwnPinGuard_differentId_isOwnPin_false
//    8.  testOwnPinGuard_nilAuthorId_isOwnPin_false
//
//  Reactions UI — "Still there?" + "Gone" call discipline (AC-V2, AC-V3):
//    9.  testStillHere_callsBothUpsertAndExtend                    (AC-V2)
//   10.  testGone_callsOnlyUpsertDispute                           (AC-V3)
//
//  All tests use MockURLProtocol (from RouteServiceTests) or AuthMockURLProtocol.
//  No live network calls, no live DB needed for these unit tests.
//  End-to-end vote→auto-resolve needs @backend-data's 02e applied (later integration step).
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Shared fixtures for auth tests

private let kAuthURL = URL(string: "https://auth-test.supabase.co")!
private let kAuthAnonKey = "test-anon-key-auth"

/// Fixed user UUIDs for deterministic test assertions.
private let kUser1 = UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!
private let kUser2 = UUID(uuidString: "A0000002-0000-0000-0000-000000000002")!

/// A valid Supabase Auth SDK `Session` JSON fixture — shape matches supabase-swift's
/// `Session`/`User` `Decodable` requirements exactly (synthesized `Codable` for `Session`;
/// `User`'s custom `init(from:)` only truly requires `id`, `aud`, `created_at`, `updated_at`).
/// `expires_at` is a real future Unix timestamp (1 hour out) so `Session.isExpired` is false —
/// the SDK checks `expiresAt`, not `expiresIn`, for expiry.
private func authResponseJSON(userId: UUID = kUser1) -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.test.token",
      "refresh_token": "refresh-test-token",
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

// MARK: - AuthMockURLProtocol

/// Thread-safe mock URLProtocol for SupabaseAuthService network calls.
/// Separate from PinMockURLProtocol to avoid shared-state races when tests run in parallel.
final class AuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AuthMockURLProtocol.requestHandler else {
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

// MARK: - WriteMockURLProtocol

/// Separate mock for CommunityPinService write-path tests.
/// Distinct from AuthMockURLProtocol and PinMockURLProtocol.
final class WriteMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = WriteMockURLProtocol.requestHandler else {
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

// MARK: - Helper: build a mock URLSession

private func authMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func writeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Helper: extract request body (httpBody or httpBodyStream)

/// URLSession converts httpBody to an httpBodyStream when the request passes through
/// the session. Read from whichever source has data.
private func bodyData(from request: URLRequest) -> Data? {
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

// MARK: - CommunityPinService Write Path Tests (AC-W1, AC-W2, AC-W3, AC-V1)

/// @MainActor: CommunityPinService and SupabaseAuthService are both @MainActor @Observable.
@MainActor
final class CommunityPinWritePathTests: XCTestCase {

    // MARK: - Helper: make a pre-authenticated service pair

    /// Returns a (pinService, authService) pair where authService already has a valid token.
    ///
    /// Sets AuthMockURLProtocol.requestHandler to return a valid session, calls
    /// ensureSession() on the auth service, then resets the handler so subsequent
    /// auth service calls (from validAccessToken) also succeed.
    private func makeAuthenticatedPair() async -> (CommunityPinService, SupabaseAuthService) {
        let mockSession = authMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )

        // Set the auth mock to return a valid session response.
        AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             authResponseJSON(userId: kUser1))
        }
        // Call ensureSession to populate in-memory auth state (accessToken, currentUserId, etc.)
        await authService.ensureSession()

        let pinService = CommunityPinService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            urlSession: writeMockSession(),
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

    // MARK: AC-W1: insertCrowdPin includes Authorization header

    /// AC-W1: insertCrowdPin request includes `Authorization: Bearer <jwt>`.
    func testInsertCrowdPin_requestIncludesAuthorizationHeader() async throws {
        let (pinService, _) = await makeAuthenticatedPair()

        var capturedAuthHeader: String? = nil
        WriteMockURLProtocol.requestHandler = { request in
            capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7505,
            lng: -73.9965,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        // AC-W1: Authorization header must be present and start with "Bearer ".
        XCTAssertNotNil(capturedAuthHeader,
            "AC-W1: insertCrowdPin request must include Authorization header")
        XCTAssertTrue(capturedAuthHeader?.hasPrefix("Bearer ") == true,
            "AC-W1: Authorization header must be 'Bearer <jwt>', got: \(capturedAuthHeader ?? "nil")")
    }

    // MARK: AC-W2: insertCrowdPin payload shape

    /// AC-W2: insert payload includes source='crowd', author_id, lifespan='ephemeral', expires_at.
    func testInsertCrowdPin_payloadShape() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = bodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7505,
            lng: -73.9965,
            segmentId: "7th Ave|W 32nd St|W 33rd St",
            zoneId: "soho-les",
            notes: nil
        )

        XCTAssertNotNil(capturedBody, "AC-W2: request body must be decodable JSON")

        // AC-W2: required fields.
        XCTAssertEqual(capturedBody?["source"] as? String, "crowd",
            "AC-W2: source must be 'crowd'")
        XCTAssertEqual(capturedBody?["lifespan"] as? String, "ephemeral",
            "AC-W2: lifespan must be 'ephemeral'")
        XCTAssertEqual(capturedBody?["author_id"] as? String, kUser1.uuidString,
            "AC-W2: author_id must equal currentUserId")
        XCTAssertNotNil(capturedBody?["expires_at"],
            "AC-W2: expires_at must be present for enforcement_active pins")
        XCTAssertEqual(capturedBody?["pin_type"] as? String, "enforcement_active",
            "AC-W2: pin_type must match the requested type raw value")
    }

    // MARK: AC-W3: insertCrowdPin without auth throws notAuthenticated

    /// AC-W3: insertCrowdPin throws CommunityPinWriteError.notAuthenticated when
    /// authService.currentUserId is nil (no valid session).
    func testInsertCrowdPin_notAuthenticated_throws() async {
        let service = CommunityPinService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            urlSession: writeMockSession(),
            authService: nil  // No auth service — write path must throw.
        )

        do {
            try await service.insertCrowdPin(
                type: .enforcementActive,
                meta: nil,
                lat: 40.7505,
                lng: -73.9965,
                segmentId: nil,
                zoneId: nil,
                notes: nil
            )
            XCTFail("AC-W3: expected CommunityPinWriteError.notAuthenticated to be thrown")
        } catch CommunityPinWriteError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("AC-W3: expected .notAuthenticated, got \(error)")
        }
    }

    // MARK: AC-V1: upsertVote includes Prefer header for upsert semantics

    /// AC-V1: upsertVote request includes `Prefer: resolution=merge-duplicates` header.
    func testUpsertVote_requestIncludesPreferHeader() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedPreferHeader: String? = nil

        WriteMockURLProtocol.requestHandler = { request in
            capturedPreferHeader = request.value(forHTTPHeaderField: "Prefer")
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let pinId = UUID()
        try await pinService.upsertVote(pinId: pinId, vote: .confirm)

        // AC-V1: Prefer header must include resolution=merge-duplicates for upsert semantics.
        XCTAssertNotNil(capturedPreferHeader,
            "AC-V1: upsertVote request must include a Prefer header")
        XCTAssertTrue(capturedPreferHeader?.contains("resolution=merge-duplicates") == true,
            "AC-V1: Prefer header must contain 'resolution=merge-duplicates', got: \(capturedPreferHeader ?? "nil")")
    }

    // MARK: AC-W3 mirror: upsertVote without auth throws

    func testUpsertVote_notAuthenticated_throws() async {
        let service = CommunityPinService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            urlSession: writeMockSession(),
            authService: nil
        )

        do {
            try await service.upsertVote(pinId: UUID(), vote: .dispute)
            XCTFail("Expected .notAuthenticated")
        } catch CommunityPinWriteError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }
    }
}

// MARK: - Own-pin guard logic tests (AC-V4)

/// Tests for the A1 own-pin guard: buttons disabled when pin.authorId == authService.currentUserId.
/// These tests exercise the guard logic directly without instantiating the SwiftUI view.
final class OwnPinGuardTests: XCTestCase {

    // Helper: build a minimal CommunityPin fixture with a given authorId.
    private func makeEphemeralCrowdPin(authorId: UUID?) -> CommunityPin {
        let authorValue: String
        if let id = authorId {
            authorValue = #""\#(id.uuidString)""#
        } else {
            authorValue = "null"
        }

        let json = """
        {
          "id": "\(UUID().uuidString)",
          "pin_type": "enforcement_active",
          "source": "crowd",
          "lifespan": "ephemeral",
          "lat": 40.7505,
          "lng": -73.9965,
          "segment_id": null,
          "zone_id": null,
          "author_id": \(authorValue),
          "author_username": null,
          "created_at": "2026-06-01T10:00:00+00:00",
          "updated_at": "2026-06-01T10:00:00+00:00",
          "expires_at": "2026-06-01T11:00:00+00:00",
          "resolved_at": null,
          "confirm_count": 0,
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
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string) ?? Date()
        }
        return try! decoder.decode(CommunityPin.self, from: Data(json.utf8))
    }

    /// AC-V4: isOwnPin = true when pin.authorId == currentUserId.
    func testOwnPinGuard_sameId_isOwnPin_true() {
        let pin = makeEphemeralCrowdPin(authorId: kUser1)
        // Simulate the guard logic from ReactionsRow.
        let currentUserId: UUID? = kUser1
        let isOwnPin: Bool = {
            guard let authorId = pin.authorId, let currentId = currentUserId else { return false }
            return authorId == currentId
        }()
        XCTAssertTrue(isOwnPin, "AC-V4: isOwnPin must be true when pin.authorId == currentUserId")
    }

    /// AC-V4: isOwnPin = false when pin.authorId != currentUserId.
    func testOwnPinGuard_differentId_isOwnPin_false() {
        let pin = makeEphemeralCrowdPin(authorId: kUser1)
        let currentUserId: UUID? = kUser2
        let isOwnPin: Bool = {
            guard let authorId = pin.authorId, let currentId = currentUserId else { return false }
            return authorId == currentId
        }()
        XCTAssertFalse(isOwnPin, "AC-V4: isOwnPin must be false when IDs differ")
    }

    /// AC-V4: isOwnPin = false when pin.authorId is nil (e.g. open-data pin).
    func testOwnPinGuard_nilAuthorId_isOwnPin_false() {
        let pin = makeEphemeralCrowdPin(authorId: nil)
        let currentUserId: UUID? = kUser1
        let isOwnPin: Bool = {
            guard let authorId = pin.authorId, let currentId = currentUserId else { return false }
            return authorId == currentId
        }()
        XCTAssertFalse(isOwnPin,
            "AC-V4: isOwnPin must be false when pin.authorId is nil")
    }
}

// MARK: - Reactions call discipline tests (AC-V2, AC-V3)

/// Verifies that "Still there?" calls BOTH upsertVote + callExtendPinExpiry (AC-V2)
/// and "Gone" calls ONLY upsertVote (AC-V3).
///
/// Strategy: exercise the CommunityPinService write path with a counting mock.
/// Both calls land on the same WriteMockURLProtocol path; we distinguish them
/// by URL endpoint path.
@MainActor
final class ReactionCallDisciplineTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func makeAuthenticatedWritePair() async -> (CommunityPinService, SupabaseAuthService) {
        let mockSession = authMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )
        AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             authResponseJSON(userId: kUser1))
        }
        await authService.ensureSession()

        let pinService = CommunityPinService(
            supabaseURL: kAuthURL,
            supabaseAnonKey: kAuthAnonKey,
            urlSession: writeMockSession(),
            authService: authService
        )
        return (pinService, authService)
    }

    /// AC-V2: "Still there?" calls BOTH upsertVote(.confirm) AND callExtendPinExpiry.
    ///
    /// We simulate the ReactionsRow.handleStillHere() logic directly on the service.
    func testStillHere_callsBothUpsertAndExtend() async throws {
        let (pinService, _) = await makeAuthenticatedWritePair()
        var votesEndpointCalled = false
        var extendEndpointCalled = false

        WriteMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/votes") { votesEndpointCalled = true }
            if path.contains("/extend_pin_expiry") { extendEndpointCalled = true }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let pinId = UUID()
        // Simulate handleStillHere():
        try await pinService.upsertVote(pinId: pinId, vote: .confirm)
        try await pinService.callExtendPinExpiry(pinId: pinId)

        XCTAssertTrue(votesEndpointCalled,
            "AC-V2: 'Still there?' must call upsertVote (POST /rest/v1/votes)")
        XCTAssertTrue(extendEndpointCalled,
            "AC-V2: 'Still there?' must call callExtendPinExpiry (POST /rest/v1/rpc/extend_pin_expiry)")
    }

    /// AC-V3: "Gone" calls ONLY upsertVote(.dispute) — does NOT call callExtendPinExpiry.
    /// Also verifies the vote value is 'dispute' and the endpoint path is correct.
    func testGone_callsOnlyUpsertDispute() async throws {
        let (pinService, _) = await makeAuthenticatedWritePair()
        var votesEndpointCalled = false
        var extendEndpointCalled = false
        var capturedVoteValue: String? = nil

        WriteMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/votes") {
                votesEndpointCalled = true
                if let body = bodyData(from: request),
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    capturedVoteValue = json["vote"] as? String
                }
            }
            if path.contains("/extend_pin_expiry") { extendEndpointCalled = true }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        let pinId = UUID()
        // Simulate handleGone() — only calls upsertVote, NOT callExtendPinExpiry (AC-V3).
        try await pinService.upsertVote(pinId: pinId, vote: .dispute)

        XCTAssertTrue(votesEndpointCalled,
            "AC-V3: 'Gone' must call upsertVote (POST /rest/v1/votes)")
        XCTAssertFalse(extendEndpointCalled,
            "AC-V3: 'Gone' must NOT call callExtendPinExpiry")
        XCTAssertEqual(capturedVoteValue, "dispute",
            "AC-V3: vote value in body must be 'dispute' for the Gone action")
    }
}

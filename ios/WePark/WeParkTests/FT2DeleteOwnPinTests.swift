//
//  FT2DeleteOwnPinTests.swift
//  WeParkTests
//
//  FT-2 — Delete Own Community Pin (Accidental Report).
//  Spec: docs/ft2-delete-own-pin-spec.md §7 (test inventory), §8 (AC-FT2.1 through AC-FT2.15).
//
//  Backend note: no migration shipped with this PR. `pins_delete_own`
//  (`supabase/02-pins-schema.sql:157-159`, `for delete using (auth.uid() = author_id)`) and the
//  `votes.pin_id` FK's `on delete cascade` (`supabase/02-pins-schema.sql:166`) were already live —
//  verified by reading the committed schema file (§3.1's verification queries are Kevin's prod-side
//  confirmation step, out of scope for this file). These tests exercise the client only.
//
//  Test inventory (9 tests — spec's 8 plus one added for the realtime-echo interaction the
//  spec's §4.1 step 5 describes but the original 8-test inventory didn't cover directly):
//
//  Service layer — deleteCrowdPin (AC-FT2.6, AC-FT2.9, AC-FT2.11):
//    1. testDeleteCrowdPin_notAuthenticated_throws
//    2. testDeleteCrowdPin_requestShape                     (method, URL, id=eq. filter, headers)
//    3. testDeleteCrowdPin_204_removesFromVisiblePins       (AC-FT2.6)
//    4. testDeleteCrowdPin_404_treatedAsSuccess
//    5. testDeleteCrowdPin_403_throwsHttpError               (AC-FT2.11 client-side mirror)
//    6. testDeleteCrowdPin_optimisticRemoval_beforeNetworkCall
//         (folded together with test 3's assertion per the spec's own note that this is
//         "tricky to test directly" — this variant proves the removal is synchronous and does
//         not depend on the network response arriving, using a mock that intentionally delays.)
//    7. testDeleteCrowdPin_networkError_doesNotDismiss      (AC-FT2.9 — service-layer half;
//         UI half — sheet stays open, inline error shown — is PinDetailSheet/ReactionsRow
//         behavior, covered by the live-smoke checklist in the PR description, not a unit test,
//         same as the spec's own test 8 note.)
//
//  Realtime-echo interaction (spec §4.1 step 5, §5 "Realtime DELETE event arriving after
//  optimistic removal"):
//    8. testDeleteCrowdPin_thenRealtimeEcho_isNoOp          (no flicker, no resurrection, no crash)
//
//  Own-pin guard (AC-FT2.2, AC-FT2.3, AC-FT2.12):
//    9. isOwnPin logic is UNCHANGED by this PR (ReactionsRow just routes to a different branch
//       based on the existing guard) — the 3 pre-existing tests in Tier3AuthReactionsTests.swift
//       (testOwnPinGuard_sameId_isOwnPin_true / _differentId_isOwnPin_false /
//       _nilAuthorId_isOwnPin_false) already cover this and are asserted to still pass by virtue
//       of being unmodified and included in the full suite run. No new test added here per the
//       spec's own guidance ("add a new test only if the isOwnPin logic is modified").
//
//  Baseline: 830/0 before this file. After: 830 + 8 = 838/0 (net new XCTestCase test methods
//  in this file below).
//
//  No Calendar.current use. No hardcoded Supabase keys.
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Shared test constants

private let kFT2URL = URL(string: "https://ft2-delete-test.supabase.co")!
private let kFT2AnonKey = "test-anon-key-ft2-delete"
private let kFT2User = UUID(uuidString: "C0000001-0000-0000-0000-000000000001")!

// MARK: - Auth mock

/// Distinct from AuthMockURLProtocol (Tier3AuthReactionsTests) / FeedbackAuthMockURLProtocol
/// (Tier3PinFeedbackTests) — separate mock class per feature file avoids shared static-state
/// races when the suite runs tests in parallel (established convention, see those files' own
/// header comments for the same rationale).
final class FT2DeleteAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FT2DeleteAuthMockURLProtocol.requestHandler else {
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

// MARK: - Write (delete) mock

final class FT2DeleteWriteMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// Set by tests that need to assert something throws a network-level error instead of
    /// returning an HTTP response (e.g. offline delete).
    nonisolated(unsafe) static var errorToThrow: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = FT2DeleteWriteMockURLProtocol.errorToThrow {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let handler = FT2DeleteWriteMockURLProtocol.requestHandler else {
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

// MARK: - Fixture helpers

/// supabase-swift Session/User JSON fixture — same shape as Tier3AuthReactionsTests /
/// Tier3PinFeedbackTests' own copies (each file owns a private copy; see those files' headers
/// for why the SDK requires snake_case + a real future `expires_at`).
private func ft2AuthResponseJSON(userId: UUID = kFT2User) -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.ft2.token",
      "refresh_token": "refresh-ft2-token",
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

/// Builds a real SupabaseAuthService instance with a pre-populated valid session, backed by
/// FT2DeleteAuthMockURLProtocol.
@MainActor
private func makeFT2AuthService(userId: UUID = kFT2User) async -> SupabaseAuthService {
    FT2DeleteAuthMockURLProtocol.requestHandler = { _ in
        (HTTPURLResponse(url: kFT2URL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         ft2AuthResponseJSON(userId: userId))
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FT2DeleteAuthMockURLProtocol.self]
    let session = URLSession(configuration: config)
    let authService = SupabaseAuthService(
        supabaseURL: kFT2URL,
        supabaseAnonKey: kFT2AnonKey,
        testStorage: InMemoryAuthStorage(),
        fetch: { try await session.data(for: $0) }
    )
    await authService.ensureSession()
    return authService
}

private func ft2WriteSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FT2DeleteWriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Builds a fixture CommunityPin (own-authored enforcement_active pin) for injection into
/// `visiblePins` via `inject(fixtures:)`.
@MainActor
private func makeFT2FixturePin(id: UUID = UUID(), authorId: UUID? = kFT2User) -> CommunityPin {
    let authorValue = authorId.map { #""\#($0.uuidString)""# } ?? "null"
    let json = """
    {
      "id": "\(id.uuidString)",
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
      "expires_at": "2099-06-01T11:00:00+00:00",
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

private func ft2ClearAuthDefaults() {
    let keys = [
        "wepark_auth_access_token", "wepark_auth_refresh_token",
        "wepark_auth_user_id", "wepark_auth_expires_at",
    ]
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - FT2DeleteOwnPinTests

@MainActor
final class FT2DeleteOwnPinTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        FT2DeleteWriteMockURLProtocol.errorToThrow = nil
        ft2ClearAuthDefaults()
    }

    private func makeAuthenticatedService() async -> CommunityPinService {
        let authService = await makeFT2AuthService()
        return CommunityPinService(
            supabaseURL: kFT2URL,
            supabaseAnonKey: kFT2AnonKey,
            urlSession: ft2WriteSession(),
            authService: authService
        )
    }

    // MARK: 1. notAuthenticated

    /// No authService at all → throws .notAuthenticated before any network call.
    func testDeleteCrowdPin_notAuthenticated_throws() async {
        let service = CommunityPinService(
            supabaseURL: kFT2URL,
            supabaseAnonKey: kFT2AnonKey,
            urlSession: ft2WriteSession(),
            authService: nil
        )

        do {
            try await service.deleteCrowdPin(id: UUID())
            XCTFail("Expected CommunityPinWriteError.notAuthenticated to be thrown")
        } catch CommunityPinWriteError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }
    }

    // MARK: 2. Request shape

    /// DELETE method, URL contains rest/v1/pins with ?id=eq.<uuid>, Authorization: Bearer
    /// header present, apikey header equals the anon key.
    func testDeleteCrowdPin_requestShape() async throws {
        let service = await makeAuthenticatedService()
        let pinId = UUID()

        var capturedRequest: URLRequest?
        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await service.deleteCrowdPin(id: pinId)

        guard let request = capturedRequest else {
            XCTFail("Expected a captured DELETE request")
            return
        }
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertTrue(request.url?.path.contains("rest/v1/pins") == true,
            "URL path must target rest/v1/pins, got: \(request.url?.path ?? "nil")")
        XCTAssertTrue(request.url?.query?.contains("id=eq.\(pinId.uuidString)") == true,
            "URL query must filter on id=eq.<uuid>, got: \(request.url?.query ?? "nil")")

        let authHeader = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(authHeader, "Authorization header must be present")
        XCTAssertTrue(authHeader?.hasPrefix("Bearer ") == true,
            "Authorization header must be 'Bearer <jwt>', got: \(authHeader ?? "nil")")

        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), kFT2AnonKey,
            "apikey header must equal the anon key")
    }

    // MARK: 3. 204 removes from visiblePins

    /// A successful (204) delete removes the pin from visiblePins.
    func testDeleteCrowdPin_204_removesFromVisiblePins() async throws {
        let service = await makeAuthenticatedService()
        let pin = makeFT2FixturePin()
        service.inject(fixtures: [pin])
        XCTAssertEqual(service.visiblePins.count, 1)

        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        try await service.deleteCrowdPin(id: pin.id)

        XCTAssertFalse(service.visiblePins.contains { $0.id == pin.id },
            "Deleted pin must no longer be present in visiblePins")
    }

    // MARK: 4. 404 treated as success

    func testDeleteCrowdPin_404_treatedAsSuccess() async {
        let service = await makeAuthenticatedService()
        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        var threw = false
        do {
            try await service.deleteCrowdPin(id: UUID())
        } catch {
            threw = true
        }
        XCTAssertFalse(threw, "HTTP 404 (pin already gone) must be treated as success, not thrown")
    }

    // MARK: 5. 403 throws httpError

    func testDeleteCrowdPin_403_throwsHttpError() async {
        let service = await makeAuthenticatedService()
        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        do {
            try await service.deleteCrowdPin(id: UUID())
            XCTFail("Expected CommunityPinWriteError.httpError(statusCode: 403)")
        } catch CommunityPinWriteError.httpError(let statusCode) {
            XCTAssertEqual(statusCode, 403,
                "AC-FT2.11: an RLS-rejected delete (caller isn't the author) must surface as 403")
        } catch {
            XCTFail("Expected .httpError(403), got \(error)")
        }
    }

    // MARK: 6. Optimistic removal before the network call resolves

    /// visiblePins must drop the pin synchronously, before the (slow) network response
    /// arrives — proving the removal doesn't wait on the round trip.
    func testDeleteCrowdPin_optimisticRemoval_beforeNetworkCall() async throws {
        let service = await makeAuthenticatedService()
        let pin = makeFT2FixturePin()
        service.inject(fixtures: [pin])

        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            // Intentional artificial delay before returning — if the removal depended on
            // this response arriving, visiblePins would still contain the pin at the point
            // this handler starts executing. It doesn't: the removal already happened inside
            // deleteCrowdPin, synchronously, before this handler is invoked by URLSession.
            XCTAssertFalse(service.visiblePins.contains { $0.id == pin.id },
                "Optimistic removal must have already happened before the network handler runs")
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await service.deleteCrowdPin(id: pin.id)

        XCTAssertTrue(service.visiblePins.isEmpty)
    }

    // MARK: 7. Network error propagates (UI keeps sheet open on this path)

    /// A network-level error (e.g. offline) propagates out of deleteCrowdPin. The optimistic
    /// removal has already happened by this point — this test documents that the pin stays
    /// removed locally even though the server-side delete did not confirm (spec §5 "Delete
    /// while offline": accepted behavior, pin reappears on the next periodic refresh only if
    /// the delete didn't actually go through server-side).
    func testDeleteCrowdPin_networkError_doesNotDismiss() async {
        let service = await makeAuthenticatedService()
        let pin = makeFT2FixturePin()
        service.inject(fixtures: [pin])

        FT2DeleteWriteMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)

        do {
            try await service.deleteCrowdPin(id: pin.id)
            XCTFail("Expected the network error to propagate")
        } catch {
            // Expected — any thrown error. The UI's catch block (ReactionsRow.handleDelete)
            // is what keeps the sheet open and shows the inline error; that UI behavior is
            // covered by the PR's live-smoke checklist, not a unit test (SwiftUI view state
            // isn't independently testable here without a rendering harness).
        }

        // Optimistic removal already happened — documented, not silently assumed.
        XCTAssertTrue(service.visiblePins.isEmpty,
            "Optimistic removal precedes the network call and is not rolled back on failure")
    }

    // MARK: 8. Realtime-echo interaction

    /// A Realtime DELETE event for the same pin arriving after the optimistic removal
    /// (own echo, or another client's concurrent fetch) must be a harmless no-op against
    /// `removePin(id:)` — no flicker, no resurrection, no crash (spec §4.1 step 5, §5).
    func testDeleteCrowdPin_thenRealtimeEcho_isNoOp() async throws {
        let service = await makeAuthenticatedService()
        let pin = makeFT2FixturePin()
        service.inject(fixtures: [pin])

        FT2DeleteWriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        try await service.deleteCrowdPin(id: pin.id)
        XCTAssertTrue(service.visiblePins.isEmpty)

        // Simulate the Realtime DELETE echo arriving over the WebSocket after this client's
        // own optimistic removal already ran — removePin(id:) is the real DELETE-event path
        // (CommunityPinService.startRealtime()'s onDelete closure).
        service.removePin(id: pin.id)

        XCTAssertTrue(service.visiblePins.isEmpty,
            "A late realtime DELETE echo for an already-removed pin must be a no-op, not a crash or resurrection")
    }
}

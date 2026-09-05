//
//  ZoneMessageWritePathTests.swift
//  WeParkTests
//
//  Community 2.0 S13b (build 20, docs/design/community-2.0-hero-gap-inventory.md WP3) —
//  write-path tests for `ZoneMessageService.sendMessage(zoneId:segmentId:body:)` (the block
//  detail redesign's chat write path) and read-path tests for
//  `ZoneMessageService.fetchMessages(segmentId:)` (the block-scoped chatter thread's fetch,
//  independent of the zone-chip-driven `messages` state `ZoneMessageServiceTests.swift`
//  already covers).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Reuses the SHARED (not file-private) `AuthMockURLProtocol` / `WriteMockURLProtocol` classes
//  declared once in `Tier3AuthReactionsTests.swift` (same reuse precedent as
//  `CommunityPhase2bWritePathTests.swift`'s own header comment) — this file duplicates its own
//  file-private auth-fixture helpers (URL/key/user constants, auth response JSON) rather than
//  importing that file's (which are themselves `private`-scoped), per that same established
//  convention.
//
//  Test inventory (14 tests):
//
//  sendMessage — request shape (7 tests):
//    1. testSendMessage_requestURL_isZoneMessagesTable
//    2. testSendMessage_requestMethod_isPOST
//    3. testSendMessage_payloadShape_zoneIdAuthorIdMessageTypeBody
//    4. testSendMessage_segmentIdProvided_includedInPayload
//    5. testSendMessage_segmentIdNil_omittedFromPayload
//    6. testSendMessage_bodyTrimmed_beforeSend
//    7. testSendMessage_requestHeaders_authorizationBearerAndReturnRepresentation
//
//  sendMessage — return-preference / decode (2 tests):
//    8. testSendMessage_success_decodesInsertedRow
//    9. testSendMessage_httpError_throws
//
//  sendMessage — client-side validation + auth (3 tests):
//   10. testSendMessage_emptyBody_throwsInvalidBody_noNetworkCall
//   11. testSendMessage_notAuthenticated_throwsNotAuthenticated_noNetworkCall
//   12. testSendMessage_optimisticAppend_onlyWhenZoneMatchesSelectedZone
//
//  fetchMessages(segmentId:) (2 tests):
//   13. testFetchMessagesSegmentId_requestIncludesSegmentIdFilter_notZoneId
//   14. testFetchMessagesSegmentId_success_reversesToOldestFirst_doesNotTouchPublishedMessages
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens or Supabase keys.
//

import XCTest
@testable import WePark

// MARK: - Shared fixtures (file-private duplicates — see header)

private let kZWPAuthURL = URL(string: "https://zone-write-test-auth.supabase.co")!
private let kZWPAnonKey = "test-anon-key-zone-write"
private let kZWPUser = UUID(uuidString: "D0000001-0000-0000-0000-000000000001")!

private func zwpAuthResponseJSON(userId: UUID = kZWPUser) -> Data {
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

private func zwpAuthMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zwpWriteMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Same httpBody/httpBodyStream extraction as every other write-path test file in this target
/// (`CommunityPhase2bWritePathTests.swift`'s own `phase2bBodyData(from:)`).
private func zwpBodyData(from request: URLRequest) -> Data? {
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

private func zwpInsertedRowJSON(id: Int = 501, zoneId: String = "nolita", segmentId: String? = nil) -> Data {
    """
    [{
      "id": \(id),
      "zone_id": "\(zoneId)",
      "author_id": "\(kZWPUser.uuidString)",
      "message_type": "user",
      "body": "Testing the write path",
      "related_report_id": null,
      "created_at": "2026-09-05T12:00:00+00:00",
      "author_username": null,
      "author_reputation": null,
      "segment_id": \(segmentId.map { #""\#($0)""# } ?? "null")
    }]
    """.data(using: .utf8)!
}

/// Builds an authenticated `ZoneMessageService` — mirrors
/// `CommunityPhase2bWritePathTests.makePhase2bAuthenticatedPair()`'s exact shape.
@MainActor
private func makeAuthenticatedZoneMessageService(
    writeHandler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) async -> ZoneMessageService {
    let mockSession = zwpAuthMockSession()
    let authService = SupabaseAuthService(
        supabaseURL: kZWPAuthURL,
        supabaseAnonKey: kZWPAnonKey,
        testStorage: InMemoryAuthStorage(),
        fetch: { try await mockSession.data(for: $0) }
    )
    AuthMockURLProtocol.requestHandler = { _ in
        (HTTPURLResponse(url: kZWPAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
         zwpAuthResponseJSON())
    }
    await authService.ensureSession()

    WriteMockURLProtocol.requestHandler = writeHandler

    return ZoneMessageService(
        supabaseURL: kZWPAuthURL,
        supabaseAnonKey: kZWPAnonKey,
        urlSession: zwpWriteMockSession(),
        authService: authService
    )
}

// MARK: - sendMessage: request shape

@MainActor
final class SendMessageRequestShapeTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testSendMessage_requestURL_isZoneMessagesTable() async throws {
        var capturedURL: URL?
        let service = await makeAuthenticatedZoneMessageService { request in
            capturedURL = request.url
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "nolita", body: "hello block")
        XCTAssertEqual(capturedURL?.path, "/rest/v1/zone_messages")
    }

    func testSendMessage_requestMethod_isPOST() async throws {
        var capturedMethod: String?
        let service = await makeAuthenticatedZoneMessageService { request in
            capturedMethod = request.httpMethod
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "nolita", body: "hello block")
        XCTAssertEqual(capturedMethod, "POST")
    }

    func testSendMessage_payloadShape_zoneIdAuthorIdMessageTypeBody() async throws {
        var capturedBody: [String: Any]?
        let service = await makeAuthenticatedZoneMessageService { request in
            if let data = zwpBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "soho", body: "Anyone home?")

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "soho")
        XCTAssertEqual(capturedBody?["author_id"] as? String, kZWPUser.uuidString)
        XCTAssertEqual(capturedBody?["message_type"] as? String, "user")
        XCTAssertEqual(capturedBody?["body"] as? String, "Anyone home?")
    }

    func testSendMessage_segmentIdProvided_includedInPayload() async throws {
        var capturedBody: [String: Any]?
        let service = await makeAuthenticatedZoneMessageService { request in
            if let data = zwpBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON(segmentId: "MOTT STREET|PRINCE STREET|SPRING STREET|W_3"))
        }
        _ = try await service.sendMessage(zoneId: "nolita", segmentId: "MOTT STREET|PRINCE STREET|SPRING STREET|W_3", body: "Swept through")

        XCTAssertEqual(capturedBody?["segment_id"] as? String, "MOTT STREET|PRINCE STREET|SPRING STREET|W_3")
    }

    func testSendMessage_segmentIdNil_omittedFromPayload() async throws {
        var capturedBody: [String: Any]?
        let service = await makeAuthenticatedZoneMessageService { request in
            if let data = zwpBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "nolita", body: "Zone-wide message")

        XCTAssertNil(capturedBody?["segment_id"], "A zone-wide send (segmentId: nil) must omit the column, not send a JSON null")
    }

    func testSendMessage_bodyTrimmed_beforeSend() async throws {
        var capturedBody: [String: Any]?
        let service = await makeAuthenticatedZoneMessageService { request in
            if let data = zwpBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "nolita", body: "  padded with whitespace  \n")

        XCTAssertEqual(capturedBody?["body"] as? String, "padded with whitespace")
    }

    func testSendMessage_requestHeaders_authorizationBearerAndReturnRepresentation() async throws {
        var capturedRequest: URLRequest?
        let service = await makeAuthenticatedZoneMessageService { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        _ = try await service.sendMessage(zoneId: "nolita", body: "hello")

        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "apikey"), kZWPAnonKey)
        XCTAssertTrue(
            capturedRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") ?? false,
            "A write must carry the authenticated user's JWT — RLS checks auth.uid() = author_id"
        )
        // Deliberate return=representation, not the default (return=minimal) — see
        // ZoneMessageService.swift's header for the RLS verdict that makes this safe.
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Prefer"), "return=representation")
    }
}

// MARK: - sendMessage: return-preference / decode

@MainActor
final class SendMessageDecodeTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testSendMessage_success_decodesInsertedRow() async throws {
        let service = await makeAuthenticatedZoneMessageService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             zwpInsertedRowJSON(id: 777, zoneId: "les"))
        }
        let message = try await service.sendMessage(zoneId: "les", body: "hi")
        XCTAssertEqual(message.id, 777)
        XCTAssertEqual(message.zoneId, "les")
        XCTAssertEqual(message.messageType, .user)
    }

    func testSendMessage_httpError_throws() async {
        let service = await makeAuthenticatedZoneMessageService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        do {
            _ = try await service.sendMessage(zoneId: "nolita", body: "hi")
            XCTFail("Expected an httpError to be thrown")
        } catch ZoneMessageWriteError.httpError(let statusCode) {
            XCTAssertEqual(statusCode, 403)
        } catch {
            XCTFail("Expected ZoneMessageWriteError.httpError, got \(error)")
        }
    }
}

// MARK: - sendMessage: client-side validation + auth

@MainActor
final class SendMessageValidationTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testSendMessage_emptyBody_throwsInvalidBody_noNetworkCall() async throws {
        var networkCalled = false
        let service = await makeAuthenticatedZoneMessageService { request in
            networkCalled = true
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    zwpInsertedRowJSON())
        }
        do {
            _ = try await service.sendMessage(zoneId: "nolita", body: "   \n  ")
            XCTFail("Expected invalidBody to be thrown")
        } catch ZoneMessageWriteError.invalidBody {
            // expected
        }
        XCTAssertFalse(networkCalled, "A whitespace-only body must fail client-side before any request is issued")
    }

    func testSendMessage_notAuthenticated_throwsNotAuthenticated_noNetworkCall() async {
        var networkCalled = false
        WriteMockURLProtocol.requestHandler = { request in
            networkCalled = true
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        // No authService injected at all.
        let service = ZoneMessageService(
            supabaseURL: kZWPAuthURL,
            supabaseAnonKey: kZWPAnonKey,
            urlSession: zwpWriteMockSession()
        )
        do {
            _ = try await service.sendMessage(zoneId: "nolita", body: "hi")
            XCTFail("Expected notAuthenticated to be thrown")
        } catch ZoneMessageWriteError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected ZoneMessageWriteError.notAuthenticated, got \(error)")
        }
        XCTAssertFalse(networkCalled)
    }

    func testSendMessage_optimisticAppend_onlyWhenZoneMatchesSelectedZone() async throws {
        let service = await makeAuthenticatedZoneMessageService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             zwpInsertedRowJSON(id: 42, zoneId: "soho"))
        }

        // No zone selected — sendMessage still succeeds, but must not populate `messages`
        // (mirrors setSelectedZone(nil)'s own "no zone = empty feed" contract).
        _ = try await service.sendMessage(zoneId: "soho", body: "hi")
        XCTAssertTrue(service.messages.isEmpty)

        // Selecting a DIFFERENT zone than the message's own zone must still not append.
        service.setSelectedZone("les")
        _ = try await service.sendMessage(zoneId: "soho", body: "hi again")
        XCTAssertTrue(service.messages.isEmpty)
    }
}

// MARK: - fetchMessages(segmentId:)

@MainActor
final class FetchMessagesSegmentIdTests: XCTestCase {

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneMessageService {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneMessageService(supabaseURL: kZWPAuthURL, supabaseAnonKey: kZWPAnonKey, urlSession: session)
    }

    func testFetchMessagesSegmentId_requestIncludesSegmentIdFilter_notZoneId() async throws {
        var capturedURL: URL?
        let service = makeService { request in
            capturedURL = request.url
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        _ = try await service.fetchMessages(segmentId: "BOWERY|HESTER STREET|GRAND STREET|N")

        let query = capturedURL?.query ?? ""
        XCTAssertTrue(query.contains("segment_id=eq."), "Must filter by segment_id, not zone_id")
        XCTAssertFalse(query.contains("zone_id=eq."), "A block-scoped fetch must not also filter by zone_id")
    }

    func testFetchMessagesSegmentId_success_reversesToOldestFirst_doesNotTouchPublishedMessages() async throws {
        let oldest = """
        {"id":1,"zone_id":"nolita","author_id":null,"message_type":"user","body":"first",
         "related_report_id":null,"created_at":"2026-09-05T09:00:00+00:00",
         "author_username":null,"author_reputation":null,"segment_id":"SEG_A"}
        """
        let newest = """
        {"id":2,"zone_id":"nolita","author_id":null,"message_type":"user","body":"second",
         "related_report_id":null,"created_at":"2026-09-05T09:05:00+00:00",
         "author_username":null,"author_reputation":null,"segment_id":"SEG_A"}
        """
        let body = "[\(newest),\(oldest)]".data(using: .utf8)!
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let fetched = try await service.fetchMessages(segmentId: "SEG_A")

        XCTAssertEqual(fetched.map(\.id), [1, 2], "Must reverse server's created_at.desc to oldest-first")
        XCTAssertTrue(service.messages.isEmpty, "This one-shot fetch must NOT populate the zone-chip-driven `messages` array")
    }
}

//
//  ZoneMessageServiceTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 1 — model + service layer (build 20, session S3).
//  Spec: docs/community-2.0-reconciliation-spec.md §1 delta table ("Blockface-anchored chat"),
//  §2.4, §3 Phase 1.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Scope: `Services/ZoneMessageService.swift` (`ZoneMessage`, `ZoneMessageService`,
//  `RealtimeZoneMessageSubscribing`, `MockRealtimeZoneMessageChannel`). Fixture-based fetch
//  tests reuse `PinMockURLProtocol` (declared in `CommunityPinServiceTests.swift`, same test
//  target) rather than declaring a second URLProtocol mock class.
//
//  Test inventory (18 tests):
//
//  Decode — ZoneMessage shape (4 tests):
//    1.  testDecode_userMessage_allFieldsPresent
//    2.  testDecode_systemTrackerMessageType_decodesCorrectly
//    3.  testDecode_nullableFields_decodeToNil
//    4.  testDecode_segmentId_present_isNonNil
//
//  Fetch — network path (5 tests):
//    5.  testFetchMessages_success_reversesToOldestFirst
//    6.  testFetchMessages_emptyArray_clearsToEmptyMessages
//    7.  testFetchMessages_httpError_setsFetchError_leavesMessagesUnchanged
//    8.  testFetchMessages_requestIncludesZoneIdFilter
//    9.  testFetchMessages_noAuthorizationHeader_apiKeyPresent
//
//  Zone selection (3 tests):
//   10.  testSetSelectedZone_nonNil_triggersFetch
//   11.  testSetSelectedZone_nil_clearsMessagesImmediately_noNetworkCall
//   12.  testSetSelectedZone_tracksSelectedZoneId
//
//  Fixture injection (1 test):
//   13.  testInject_replacesMessages
//
//  Realtime — zone gating + wiring (5 tests):
//   14.  testRealtimeInsert_matchingZone_appended
//   15.  testRealtimeInsert_mismatchedZone_dropped
//   16.  testRealtimeInsert_noZoneSelected_dropped
//   17.  testRealtimeInsert_duplicateId_notAppendedTwice
//   18.  testStartRealtime_callsConnectOnRealtimeChannel
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens or Supabase keys.
//

import XCTest
@testable import WePark

// MARK: - Shared test constants

private let kZoneTestURL = URL(string: "https://zone-message-test.supabase.co")!
private let kZoneAnonKey = "test-anon-key-zone-message"

// MARK: - Fixture helpers

/// Same ISO8601-with-fractional-seconds-then-plain decoder strategy used by
/// `ZoneMessageService` itself, duplicated locally per this repo's file-independence
/// convention (matches `CommunityPinServiceTests.swift`'s own duplicated decoder).
private func zoneMessageDecoder() -> JSONDecoder {
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
    return decoder
}

/// Builds one `zone_messages_with_author` JSON row.
private func zoneMessageJSON(
    id: Int = 1,
    zoneId: String = "soho",
    authorId: String? = "A0000000-0000-0000-0000-000000000001",
    messageType: String = "user",
    body: String = "Anyone parked on Prince St right now?",
    relatedReportId: String? = nil,
    createdAt: String = "2026-08-27T09:00:00+00:00",
    authorUsername: String? = "crew_member",
    authorReputation: Int? = 12,
    segmentId: String? = nil
) -> String {
    """
    {
      "id": \(id),
      "zone_id": "\(zoneId)",
      "author_id": \(authorId.map { #""\#($0)""# } ?? "null"),
      "message_type": "\(messageType)",
      "body": "\(body)",
      "related_report_id": \(relatedReportId.map { #""\#($0)""# } ?? "null"),
      "created_at": "\(createdAt)",
      "author_username": \(authorUsername.map { #""\#($0)""# } ?? "null"),
      "author_reputation": \(authorReputation.map { String($0) } ?? "null"),
      "segment_id": \(segmentId.map { #""\#($0)""# } ?? "null")
    }
    """
}

/// Decodes a single `ZoneMessage` fixture — matches the production decode path exactly (JSON
/// → `Data` → `JSONDecoder`), same reasoning as `CommunityPinServiceTests.makeFixturePin`'s own
/// doc comment for why it decodes rather than using a memberwise initializer.
private func makeZoneMessageFixture(
    id: Int = 1,
    zoneId: String = "soho",
    messageType: String = "user",
    body: String = "Test message",
    createdAt: String = "2026-08-27T09:00:00+00:00",
    segmentId: String? = nil
) -> ZoneMessage {
    let json = zoneMessageJSON(id: id, zoneId: zoneId, messageType: messageType, body: body,
                                createdAt: createdAt, segmentId: segmentId)
    return try! zoneMessageDecoder().decode(ZoneMessage.self, from: Data(json.utf8))
}

/// Wraps N message JSON fixtures into a PostgREST-shaped JSON array response body.
private func zoneMessagesArrayJSON(_ messages: [String]) -> Data {
    Data(("[" + messages.joined(separator: ",") + "]").utf8)
}

// MARK: - Decode tests

final class ZoneMessageDecodeTests: XCTestCase {

    private let decoder = zoneMessageDecoder()

    func testDecode_userMessage_allFieldsPresent() throws {
        let json = zoneMessageJSON(id: 42, zoneId: "les", messageType: "user",
                                    body: "Sweeper just came through", segmentId: "Ludlow St|Stanton St|Rivington St|E")
        let message = try decoder.decode(ZoneMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.id, 42)
        XCTAssertEqual(message.zoneId, "les")
        XCTAssertEqual(message.messageType, .user)
        XCTAssertEqual(message.body, "Sweeper just came through")
        XCTAssertEqual(message.segmentId, "Ludlow St|Stanton St|Rivington St|E")
        XCTAssertNotNil(message.authorId)
        XCTAssertNotNil(message.authorUsername)
        XCTAssertEqual(message.authorReputation, 12)
    }

    /// `01-mvp-schema.sql:76`'s CHECK constraint's other value — cross-pollination messages
    /// from the tracker (inserted via a SECURITY DEFINER RPC, not directly by a user).
    func testDecode_systemTrackerMessageType_decodesCorrectly() throws {
        let json = zoneMessageJSON(authorId: nil, messageType: "system_tracker", authorUsername: nil,
                                    authorReputation: nil)
        let message = try decoder.decode(ZoneMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.messageType, .systemTracker)
        XCTAssertNil(message.authorId, "A system message has no human author")
    }

    /// `author_id`/`related_report_id`/`author_username`/`author_reputation`/`segment_id` are
    /// all nullable — a message with none of them set must still decode.
    func testDecode_nullableFields_decodeToNil() throws {
        let json = zoneMessageJSON(authorId: nil, relatedReportId: nil, authorUsername: nil,
                                    authorReputation: nil, segmentId: nil)
        let message = try decoder.decode(ZoneMessage.self, from: Data(json.utf8))

        XCTAssertNil(message.authorId)
        XCTAssertNil(message.relatedReportId)
        XCTAssertNil(message.authorUsername)
        XCTAssertNil(message.authorReputation)
        XCTAssertNil(message.segmentId)
    }

    /// `segment_id` is the Community 2.0 §2.4 addition to `zone_messages` — present on a
    /// blockface-anchored message.
    func testDecode_segmentId_present_isNonNil() throws {
        let json = zoneMessageJSON(segmentId: "Mott St|Prince St|Spring St|W")
        let message = try decoder.decode(ZoneMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.segmentId, "Mott St|Prince St|Spring St|W")
    }
}

// MARK: - Fetch tests

@MainActor
final class ZoneMessageServiceFetchTests: XCTestCase {

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneMessageService {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneMessageService(supabaseURL: kZoneTestURL, supabaseAnonKey: kZoneAnonKey, urlSession: session)
    }

    /// PostgREST returns `created_at.desc` (most-recent-first); `fetchMessages` must reverse
    /// that to oldest-first for display.
    func testFetchMessages_success_reversesToOldestFirst() async {
        let oldest = zoneMessageJSON(id: 1, body: "first", createdAt: "2026-08-27T09:00:00+00:00")
        let newest = zoneMessageJSON(id: 2, body: "second", createdAt: "2026-08-27T09:05:00+00:00")
        // Server order: newest first (what created_at.desc actually returns).
        let body = zoneMessagesArrayJSON([newest, oldest])

        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await service.fetchMessages(zoneId: "soho")

        XCTAssertEqual(service.messages.map(\.id), [1, 2], "messages must publish oldest-first")
        XCTAssertNil(service.fetchError)
    }

    func testFetchMessages_emptyArray_clearsToEmptyMessages() async {
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "[]".data(using: .utf8)!)
        }
        await service.fetchMessages(zoneId: "soho")
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.fetchError)
    }

    /// A non-2xx response sets `fetchError` and leaves `messages` at whatever it was before
    /// (fail soft — same posture as `CommunityPinService.resolveChannelPins`).
    func testFetchMessages_httpError_setsFetchError_leavesMessagesUnchanged() async {
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        service.inject(fixtures: [makeZoneMessageFixture(id: 1)])

        await service.fetchMessages(zoneId: "soho")

        XCTAssertNotNil(service.fetchError)
        XCTAssertEqual(service.messages.map(\.id), [1], "a failed fetch must not blank previously-loaded messages")
    }

    func testFetchMessages_requestIncludesZoneIdFilter() async {
        var capturedURL: URL?
        let service = makeService { request in
            capturedURL = request.url
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        await service.fetchMessages(zoneId: "nolita")

        let query = capturedURL?.query ?? ""
        XCTAssertTrue(query.contains("zone_id=eq.nolita"), "Request must filter by the requested zone_id")
    }

    func testFetchMessages_noAuthorizationHeader_apiKeyPresent() async {
        var capturedRequest: URLRequest?
        let service = makeService { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        await service.fetchMessages(zoneId: "soho")

        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"),
            "zone_messages_select_all permits anonymous read — no Authorization header (AC-D21 precedent)")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "apikey"), kZoneAnonKey)
    }
}

// MARK: - Zone selection tests

@MainActor
final class ZoneMessageServiceZoneSelectionTests: XCTestCase {

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> ZoneMessageService {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ZoneMessageService(supabaseURL: kZoneTestURL, supabaseAnonKey: kZoneAnonKey, urlSession: session)
    }

    func testSetSelectedZone_nonNil_triggersFetch() async {
        let body = zoneMessagesArrayJSON([zoneMessageJSON(id: 7, zoneId: "les")])
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        service.setSelectedZone("les")
        // setSelectedZone's fetch runs on a detached Task — give it a moment to complete
        // (no debounce to wait out, unlike CommunityPinService.onRegionChanged).
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(service.messages.map(\.id), [7])
    }

    func testSetSelectedZone_nil_clearsMessagesImmediately_noNetworkCall() {
        var networkCalled = false
        let service = makeService { request in
            networkCalled = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        service.inject(fixtures: [makeZoneMessageFixture(id: 1)])

        service.setSelectedZone(nil)

        XCTAssertTrue(service.messages.isEmpty, "setSelectedZone(nil) must clear messages synchronously")
        XCTAssertFalse(networkCalled, "setSelectedZone(nil) must not issue a network request")
    }

    func testSetSelectedZone_tracksSelectedZoneId() {
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "[]".data(using: .utf8)!)
        }
        service.setSelectedZone("nolita")
        XCTAssertEqual(service.selectedZoneId, "nolita")

        service.setSelectedZone(nil)
        XCTAssertNil(service.selectedZoneId)
    }
}

// MARK: - Fixture injection tests

@MainActor
final class ZoneMessageServiceInjectionTests: XCTestCase {

    func testInject_replacesMessages() {
        let service = ZoneMessageService(supabaseURL: kZoneTestURL, supabaseAnonKey: kZoneAnonKey,
                                          realtimeChannel: MockRealtimeZoneMessageChannel())
        let fixture = makeZoneMessageFixture(id: 99, body: "injected")
        service.inject(fixtures: [fixture])

        XCTAssertEqual(service.messages.map(\.id), [99])
    }
}

// MARK: - Realtime tests

@MainActor
final class ZoneMessageServiceRealtimeTests: XCTestCase {

    private func makeService(realtimeChannel: MockRealtimeZoneMessageChannel) -> ZoneMessageService {
        ZoneMessageService(supabaseURL: kZoneTestURL, supabaseAnonKey: kZoneAnonKey,
                            realtimeChannel: realtimeChannel)
    }

    private func startAndAwaitConnect(_ service: ZoneMessageService) async {
        service.startRealtime()
        await service.realtimeConnectTask?.value
    }

    func testStartRealtime_callsConnectOnRealtimeChannel() async {
        let mock = MockRealtimeZoneMessageChannel()
        let service = makeService(realtimeChannel: mock)

        await startAndAwaitConnect(service)

        XCTAssertEqual(mock.connectCallCount, 1)
        XCTAssertTrue(mock.isConnected)
    }

    func testRealtimeInsert_matchingZone_appended() async {
        let mock = MockRealtimeZoneMessageChannel()
        let service = makeService(realtimeChannel: mock)
        service.setSelectedZone("soho")
        await startAndAwaitConnect(service)

        let message = makeZoneMessageFixture(id: 5, zoneId: "soho")
        mock.simulateInsert(message)

        XCTAssertTrue(service.messages.contains { $0.id == 5 })
    }

    func testRealtimeInsert_mismatchedZone_dropped() async {
        let mock = MockRealtimeZoneMessageChannel()
        let service = makeService(realtimeChannel: mock)
        service.setSelectedZone("les")
        await startAndAwaitConnect(service)

        let message = makeZoneMessageFixture(id: 6, zoneId: "soho")
        mock.simulateInsert(message)

        XCTAssertFalse(service.messages.contains { $0.id == 6 },
            "A message for a zone other than the selected one must be dropped")
    }

    func testRealtimeInsert_noZoneSelected_dropped() async {
        let mock = MockRealtimeZoneMessageChannel()
        let service = makeService(realtimeChannel: mock)
        // No setSelectedZone(_:) call — selectedZoneId is nil.
        await startAndAwaitConnect(service)

        let message = makeZoneMessageFixture(id: 8, zoneId: "soho")
        mock.simulateInsert(message)

        XCTAssertTrue(service.messages.isEmpty,
            "With no zone selected, a Realtime INSERT must never populate the feed " +
            "(there is no 'all zones' chat view — setSelectedZone(nil)'s own contract)")
    }

    func testRealtimeInsert_duplicateId_notAppendedTwice() async {
        let mock = MockRealtimeZoneMessageChannel()
        let service = makeService(realtimeChannel: mock)
        service.setSelectedZone("soho")
        await startAndAwaitConnect(service)

        let message = makeZoneMessageFixture(id: 9, zoneId: "soho")
        mock.simulateInsert(message)
        mock.simulateInsert(message)

        XCTAssertEqual(service.messages.filter { $0.id == 9 }.count, 1,
            "A duplicate INSERT event for the same id (e.g. a redundant echo) must not double-append")
    }
}

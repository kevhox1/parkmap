//
//  RegularsModelServiceTests.swift
//  WeParkTests
//
//  Regulars network — S5 (iOS model/service layer). Spec: docs/regulars-network-spec.md §3.6
//  (the six named guard tests), §2 (wire shapes). Wire-truth: `supabase/07-regulars-schema.sql`
//  (the merged, QA-fixed migration — see that file's own header for the reconciliation history
//  this session's fixtures are built against). Sequencing: docs/regulars-roadmap.md, session S5.
//
//  Zero UI exercised anywhere in this file — every test targets `Models/Regular.swift` and
//  `Services/RegularsService.swift` only.
//
//  Test inventory (34 tests):
//
//  1. RegularsFlagGuardTests (6) — the six guard tests pre-declared by
//     docs/regulars-network-spec.md §3.6 / docs/regulars-roadmap.md "Flag decision", named
//     verbatim:
//    1.  testRegularsEnabled_defaultsFalse
//    2.  testRegularsSettingsRow_hidden_whenDisabled
//    3.  testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled
//    4.  testAppConstants_regularsHeadStartRange_matchesServerClamp
//    5.  testAppConstants_regularsHeadStartDefault_is15Minutes
//    6.  testRegularNoticeScheduleMode_hidden_whenRegularsDisabled
//
//  2. RegularEdgeCodableTests (5) — wire-shape fidelity against `regular_edges`' real columns:
//    7.  testDecode_regularEdge_matchesSchemaColumns
//    8.  testRoundTrip_regularEdge_decodeEncodeDecode_equalsOriginal
//    9.  testRegularEdge_otherUserId_ownIsLow_returnsHigh
//    10. testRegularEdge_otherUserId_ownIsHigh_returnsLow
//    11. testRegularEdge_otherUserId_neitherMatches_returnsNil
//
//  3. RegularInviteCodableTests (3) — `regular_invites`' nullable redemption fields:
//    12. testDecode_regularInvite_unredeemed_nullableFieldsAreNil
//    13. testDecode_regularInvite_redeemed_nullableFieldsPopulated
//    14. testRoundTrip_regularInvite_decodeEncodeDecode_equalsOriginal
//
//  4. PinNoteCodableTests (2) — `pin_notes`' columns:
//    15. testDecode_pinNote_matchesSchemaColumns
//    16. testRoundTrip_pinNote_decodeEncodeDecode_equalsOriginal
//
//  5. RegularNoticeCodableTests (3) — `regular_notices`, including the Scheduled Departure
//     `scheduled_for` fixture the dispatch specifically calls for:
//    17. testDecode_regularNotice_immediate_scheduledForIsNil
//    18. testDecode_regularNotice_scheduled_scheduledForIsPopulated
//    19. testRoundTrip_regularNotice_scheduled_decodeEncodeDecode_equalsOriginal
//
//  6. RegularInviteRedeemResultDecodeTests (5) — all four `redeem_regular_invite` terminal
//     states, plus one defensive "unrecognized shape" case:
//    20. testDecodeRedeemResult_success_returnsRegularId
//    21. testDecodeRedeemResult_expiredOrUsed
//    22. testDecodeRedeemResult_cannotAddSelf
//    23. testDecodeRedeemResult_blocked
//    24. testDecodeRedeemResult_unrecognizedReason_throws
//
//  7. RegularsServiceWireTests (10) — actual outgoing `URLRequest` shape (URL, headers, body),
//     per this repo's `PushTokenUpsertPayloadTests`/`PushRegistrationServiceWireTests`
//     precedent (`WeParkTests/PushRegistrationServiceTests.swift`) — asserting only on a pure
//     payload dictionary would not have caught PR #101's own missing-`on_conflict` gap, so this
//     file goes straight to the wire for every write/RPC method:
//    25. testCreateInvite_requestBody_containsOnlyCreatedBy
//    26. testCreateInvite_notAuthenticated_throws
//    27. testRedeemInvite_requestShape_pathAndBody
//    28. testSendNotice_requestBody_immediate_containsSenderAndBodyOnly
//    29. testSendNotice_requestBody_scheduled_includesScheduledFor
//    30. testSendNotice_overLengthBody_throwsInvalidNoticeBody_beforeNetworkCall
//    31. testBlock_requestBody_containsUserIdAndBlockedUserId
//    32. testUnblock_requestIsDeleteWithQueryFilters
//    33. testFetchEdges_requestIncludesSelectAndOrderQueryItems
//    34. testFetchNotices_requestIncludesSelectQueryItems
//
//  No Calendar.current. No hardcoded Supabase secrets.
//

import XCTest
@testable import WePark

// MARK: - 1. Flag guard tests (docs/regulars-network-spec.md §3.6)

final class RegularsFlagGuardTests: XCTestCase {

    func testRegularsEnabled_defaultsFalse() {
        XCTAssertFalse(AppConstants.regularsEnabled, "Regulars must ship dark until S14's flip")
    }

    func testRegularsSettingsRow_hidden_whenDisabled() {
        XCTAssertFalse(AppConstants.regularsSettingsRowVisible(enabled: false))
    }

    func testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled() {
        XCTAssertFalse(AppConstants.regularsHeadStartRowVisible(enabled: false))
    }

    func testAppConstants_regularsHeadStartRange_matchesServerClamp() {
        // supabase/07-regulars-schema.sql §S1-1: `check (... between 60 and 3600)`.
        XCTAssertEqual(AppConstants.regularsHeadStartRangeSeconds, 60...3600)
    }

    func testAppConstants_regularsHeadStartDefault_is15Minutes() {
        XCTAssertEqual(AppConstants.regularsHeadStartDefaultSeconds, 900)
    }

    func testRegularNoticeScheduleMode_hidden_whenRegularsDisabled() {
        XCTAssertFalse(AppConstants.regularNoticeScheduleModeVisible(enabled: false))
    }
}

// MARK: - Shared fixture UUIDs / decoder helper

private let kLowUser  = UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!
private let kHighUser = UUID(uuidString: "B0000002-0000-0000-0000-000000000002")!
private let kThirdUser = UUID(uuidString: "C0000003-0000-0000-0000-000000000003")!

/// Matching ISO8601 `Date` encoder for round-trip tests — mirrors
/// `RegularsService.iso8601StringWithFraction(_:)` exactly, so decode→encode→decode round trips
/// don't lose precision against the SAME custom decode strategy `RegularsService.makeDateDecodingJSONDecoder()`
/// uses.
private func makeRoundTripEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(RegularsService.iso8601StringWithFraction(date))
    }
    return encoder
}

// MARK: - 2. RegularEdge wire-shape + logic tests

final class RegularEdgeCodableTests: XCTestCase {

    /// Fixture copied verbatim from `regular_edges`' real columns
    /// (`07-regulars-schema.sql` §S1-2): `low_user_id`, `high_user_id`, `created_at` — no
    /// synthetic `id` column exists on this table.
    private func fixtureJSON() -> Data {
        """
        {
          "low_user_id": "\(kLowUser.uuidString)",
          "high_user_id": "\(kHighUser.uuidString)",
          "created_at": "2026-09-18T10:00:00+00:00"
        }
        """.data(using: .utf8)!
    }

    func testDecode_regularEdge_matchesSchemaColumns() throws {
        let edge = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularEdge.self, from: fixtureJSON())
        XCTAssertEqual(edge.lowUserId, kLowUser)
        XCTAssertEqual(edge.highUserId, kHighUser)
        XCTAssertEqual(edge.id, "\(kLowUser.uuidString)_\(kHighUser.uuidString)")
    }

    func testRoundTrip_regularEdge_decodeEncodeDecode_equalsOriginal() throws {
        let decoder = RegularsService.makeDateDecodingJSONDecoder()
        let original = try decoder.decode(RegularEdge.self, from: fixtureJSON())
        let reEncoded = try makeRoundTripEncoder().encode(original)
        let roundTripped = try decoder.decode(RegularEdge.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }

    func testRegularEdge_otherUserId_ownIsLow_returnsHigh() throws {
        let edge = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularEdge.self, from: fixtureJSON())
        XCTAssertEqual(edge.otherUserId(ownUserId: kLowUser), kHighUser)
    }

    func testRegularEdge_otherUserId_ownIsHigh_returnsLow() throws {
        let edge = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularEdge.self, from: fixtureJSON())
        XCTAssertEqual(edge.otherUserId(ownUserId: kHighUser), kLowUser)
    }

    func testRegularEdge_otherUserId_neitherMatches_returnsNil() throws {
        let edge = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularEdge.self, from: fixtureJSON())
        XCTAssertNil(edge.otherUserId(ownUserId: kThirdUser))
    }
}

// MARK: - 3. RegularInvite wire-shape tests

final class RegularInviteCodableTests: XCTestCase {

    private let kInviteId = UUID(uuidString: "D0000004-0000-0000-0000-000000000004")!

    /// Fixture copied verbatim from `regular_invites`' real columns (§S1-4): `id`, `created_by`,
    /// `created_at`, `expires_at`, `redeemed_by`, `redeemed_at`, `revoked_at`.
    private func fixtureJSON(redeemed: Bool) -> Data {
        let redeemedByLine = redeemed ? "\"\(kHighUser.uuidString)\"" : "null"
        let redeemedAtLine = redeemed ? "\"2026-09-18T10:05:00+00:00\"" : "null"
        return """
        {
          "id": "\(kInviteId.uuidString)",
          "created_by": "\(kLowUser.uuidString)",
          "created_at": "2026-09-18T10:00:00+00:00",
          "expires_at": "2026-09-18T10:10:00+00:00",
          "redeemed_by": \(redeemedByLine),
          "redeemed_at": \(redeemedAtLine),
          "revoked_at": null
        }
        """.data(using: .utf8)!
    }

    func testDecode_regularInvite_unredeemed_nullableFieldsAreNil() throws {
        let invite = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularInvite.self, from: fixtureJSON(redeemed: false))
        XCTAssertEqual(invite.id, kInviteId)
        XCTAssertEqual(invite.createdBy, kLowUser)
        XCTAssertNil(invite.redeemedBy)
        XCTAssertNil(invite.redeemedAt)
        XCTAssertNil(invite.revokedAt)
    }

    func testDecode_regularInvite_redeemed_nullableFieldsPopulated() throws {
        let invite = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularInvite.self, from: fixtureJSON(redeemed: true))
        XCTAssertEqual(invite.redeemedBy, kHighUser)
        XCTAssertNotNil(invite.redeemedAt)
    }

    func testRoundTrip_regularInvite_decodeEncodeDecode_equalsOriginal() throws {
        let decoder = RegularsService.makeDateDecodingJSONDecoder()
        let original = try decoder.decode(RegularInvite.self, from: fixtureJSON(redeemed: true))
        let reEncoded = try makeRoundTripEncoder().encode(original)
        let roundTripped = try decoder.decode(RegularInvite.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }
}

// MARK: - 4. PinNote wire-shape tests

final class PinNoteCodableTests: XCTestCase {

    private let kPinId = UUID(uuidString: "E0000005-0000-0000-0000-000000000005")!

    /// Fixture copied verbatim from `pin_notes`' real columns (§S1-5): `pin_id`, `author_id`,
    /// `body`, `created_at`.
    private func fixtureJSON() -> Data {
        """
        {
          "pin_id": "\(kPinId.uuidString)",
          "author_id": "\(kLowUser.uuidString)",
          "body": "front spot, plug's a little loose",
          "created_at": "2026-09-18T10:00:00+00:00"
        }
        """.data(using: .utf8)!
    }

    func testDecode_pinNote_matchesSchemaColumns() throws {
        let note = try RegularsService.makeDateDecodingJSONDecoder().decode(PinNote.self, from: fixtureJSON())
        XCTAssertEqual(note.pinId, kPinId)
        XCTAssertEqual(note.authorId, kLowUser)
        XCTAssertEqual(note.body, "front spot, plug's a little loose")
        XCTAssertEqual(note.id, kPinId, "Identifiable.id must be the real pin_id primary key, not a synthetic value")
    }

    func testRoundTrip_pinNote_decodeEncodeDecode_equalsOriginal() throws {
        let decoder = RegularsService.makeDateDecodingJSONDecoder()
        let original = try decoder.decode(PinNote.self, from: fixtureJSON())
        let reEncoded = try makeRoundTripEncoder().encode(original)
        let roundTripped = try decoder.decode(PinNote.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }
}

// MARK: - 5. RegularNotice wire-shape tests (incl. Scheduled Departure)

final class RegularNoticeCodableTests: XCTestCase {

    private let kNoticeId = UUID(uuidString: "F0000006-0000-0000-0000-000000000006")!

    /// Fixture copied verbatim from `regular_notices`' real columns (§S1-6): `id`, `sender_id`,
    /// `body`, `scheduled_for`, `created_at`, `expires_at`. The immediate-notice shape is
    /// byte-identical to the pre-Scheduled-Departure row (`scheduled_for: null`).
    private func immediateFixtureJSON() -> Data {
        """
        {
          "id": "\(kNoticeId.uuidString)",
          "sender_id": "\(kLowUser.uuidString)",
          "body": "Moving my car",
          "scheduled_for": null,
          "created_at": "2026-09-18T10:00:00+00:00",
          "expires_at": "2026-09-18T11:00:00+00:00"
        }
        """.data(using: .utf8)!
    }

    /// Scheduled Departure fixture — `scheduled_for` non-null, and `expires_at` correctly
    /// anchored PAST `scheduled_for` (not past `created_at`), per §S1-6's derive-expiry trigger
    /// and the exact bug S1's QA fix round caught (Finding #3).
    private func scheduledFixtureJSON() -> Data {
        """
        {
          "id": "\(kNoticeId.uuidString)",
          "sender_id": "\(kLowUser.uuidString)",
          "body": "I'm out at 2:00 PM",
          "scheduled_for": "2026-09-18T14:00:00+00:00",
          "created_at": "2026-09-18T10:00:00+00:00",
          "expires_at": "2026-09-18T15:00:00+00:00"
        }
        """.data(using: .utf8)!
    }

    func testDecode_regularNotice_immediate_scheduledForIsNil() throws {
        let notice = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularNotice.self, from: immediateFixtureJSON())
        XCTAssertNil(notice.scheduledFor)
        XCTAssertEqual(notice.body, "Moving my car")
    }

    func testDecode_regularNotice_scheduled_scheduledForIsPopulated() throws {
        let notice = try RegularsService.makeDateDecodingJSONDecoder().decode(RegularNotice.self, from: scheduledFixtureJSON())
        XCTAssertNotNil(notice.scheduledFor)
        // expires_at must land AFTER scheduled_for, not merely after created_at — the exact
        // regression S1's QA fix round (Finding #3) caught against the server-side trigger;
        // this asserts the CLIENT decodes that relationship correctly, not the trigger itself
        // (that's supabase/07-regulars-schema-test.sh's job).
        XCTAssertGreaterThan(notice.expiresAt, notice.scheduledFor!)
        XCTAssertGreaterThan(notice.expiresAt, notice.createdAt.addingTimeInterval(3 * 3600),
            "a notice scheduled hours out must not expire shortly after being POSTED")
    }

    func testRoundTrip_regularNotice_scheduled_decodeEncodeDecode_equalsOriginal() throws {
        let decoder = RegularsService.makeDateDecodingJSONDecoder()
        let original = try decoder.decode(RegularNotice.self, from: scheduledFixtureJSON())
        let reEncoded = try makeRoundTripEncoder().encode(original)
        let roundTripped = try decoder.decode(RegularNotice.self, from: reEncoded)
        XCTAssertEqual(original, roundTripped)
    }
}

// MARK: - 6. redeem_regular_invite result-state decode tests

final class RegularInviteRedeemResultDecodeTests: XCTestCase {

    func testDecodeRedeemResult_success_returnsRegularId() throws {
        let json = """
        { "ok": true, "regular_id": "\(kLowUser.uuidString)" }
        """.data(using: .utf8)!
        let result = try RegularsService.decodeRedeemResult(from: json)
        XCTAssertEqual(result, .success(regularId: kLowUser))
    }

    func testDecodeRedeemResult_expiredOrUsed() throws {
        let json = #"{ "ok": false, "reason": "expired_or_used" }"#.data(using: .utf8)!
        let result = try RegularsService.decodeRedeemResult(from: json)
        XCTAssertEqual(result, .expiredOrUsed)
    }

    func testDecodeRedeemResult_cannotAddSelf() throws {
        let json = #"{ "ok": false, "reason": "cannot_add_self" }"#.data(using: .utf8)!
        let result = try RegularsService.decodeRedeemResult(from: json)
        XCTAssertEqual(result, .cannotAddSelf)
    }

    func testDecodeRedeemResult_blocked() throws {
        let json = #"{ "ok": false, "reason": "blocked" }"#.data(using: .utf8)!
        let result = try RegularsService.decodeRedeemResult(from: json)
        XCTAssertEqual(result, .blocked)
    }

    func testDecodeRedeemResult_unrecognizedReason_throws() {
        let json = #"{ "ok": false, "reason": "some_future_reason_this_client_predates" }"#.data(using: .utf8)!
        XCTAssertThrowsError(try RegularsService.decodeRedeemResult(from: json)) { error in
            XCTAssertEqual(error as? RegularsServiceError, .unrecognizedRedeemResult)
        }
    }
}

// MARK: - 7. RegularsService wire-level tests

/// Mock URLProtocol for the auth SDK's own network traffic — scoped to this file only (distinct
/// from every other file's own auth mock, per this repo's established per-file-mock convention).
final class RegularsAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RegularsAuthMockURLProtocol.requestHandler else {
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

/// Mock URLProtocol for `RegularsService`'s own PostgREST/RPC traffic — distinct from
/// `RegularsAuthMockURLProtocol` above.
final class RegularsWireMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RegularsWireMockURLProtocol.requestHandler else {
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

private let kRegularsWireURL = URL(string: "https://regulars-wire-test.supabase.co")!
private let kRegularsAnonKey = "test-anon-key-regulars"
private let kRegularsUser = UUID(uuidString: "10000001-0000-0000-0000-000000000001")!
private let kRegularsTarget = UUID(uuidString: "20000002-0000-0000-0000-000000000002")!

private func regularsWireSessionJSON(userId: UUID = kRegularsUser) -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.regulars-wire-test.token",
      "refresh_token": "refresh-regulars-wire-test",
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

private func regularsWireMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RegularsWireMockURLProtocol.self]
    return URLSession(configuration: config)
}

@MainActor
final class RegularsServiceWireTests: XCTestCase {

    /// Builds a `RegularsService` wired to a pre-authenticated `SupabaseAuthService` (mirrors
    /// `PushRegistrationServiceWireTests.makeAuthenticatedService`'s exact pattern) and a
    /// `RegularsWireMockURLProtocol`-backed `URLSession` for its own traffic.
    private func makeAuthenticatedService() async -> RegularsService {
        let authSession = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RegularsAuthMockURLProtocol.self]
            return config
        }())
        let authService = SupabaseAuthService(
            supabaseURL: kRegularsWireURL,
            supabaseAnonKey: kRegularsAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await authSession.data(for: $0) }
        )
        RegularsAuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kRegularsWireURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             regularsWireSessionJSON())
        }
        await authService.ensureSession()

        return RegularsService(
            supabaseURL: kRegularsWireURL,
            supabaseAnonKey: kRegularsAnonKey,
            authService: authService,
            urlSession: regularsWireMockSession()
        )
    }

    /// Decodes the captured request body as a `[String: Any]` JSON object — the same
    /// "capture the actual outgoing request, not just a pure payload dict" discipline
    /// `PushRegistrationServiceWireTests` establishes. `URLSession` converts `httpBody` into an
    /// `httpBodyStream` once a request passes through a real session (`Tier3AuthReactionsTests.bodyData(from:)`'s
    /// own precedent, mirrored here) — check `httpBody` first, fall back to fully draining the
    /// stream.
    private func decodedBody(_ request: URLRequest) -> [String: Any]? {
        guard let body = bodyData(from: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody, !data.isEmpty { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data.isEmpty ? nil : data
    }

    // MARK: createInvite

    func testCreateInvite_requestBody_containsOnlyCreatedBy() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let echo = """
            [{
              "id": "\(UUID().uuidString)",
              "created_by": "\(kRegularsUser.uuidString)",
              "created_at": "2026-09-18T10:00:00+00:00",
              "expires_at": "2026-09-18T10:10:00+00:00",
              "redeemed_by": null,
              "redeemed_at": null,
              "revoked_at": null
            }]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, echo)
        }

        _ = try await service.createInvite()

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/regular_invites") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")

        let body = decodedBody(request)
        XCTAssertEqual(body?.count, 1, "regular_invites INSERT must send exactly one column: created_by (§S1-4's column-level grant)")
        XCTAssertEqual(body?["created_by"] as? String, kRegularsUser.uuidString)
        XCTAssertNil(body?["created_at"], "created_at must never be client-supplied (S1 QA's backdating exploit)")
        XCTAssertNil(body?["expires_at"], "expires_at must never be client-supplied (S1 QA's TTL-defeat exploit)")
    }

    func testCreateInvite_notAuthenticated_throws() async {
        let service = RegularsService(supabaseURL: kRegularsWireURL, supabaseAnonKey: kRegularsAnonKey, authService: nil)
        do {
            _ = try await service.createInvite()
            XCTFail("expected notAuthenticated to be thrown")
        } catch {
            XCTAssertEqual(error as? RegularsServiceError, .notAuthenticated)
        }
    }

    // MARK: redeemInvite

    func testRedeemInvite_requestShape_pathAndBody() async throws {
        let service = await makeAuthenticatedService()
        let token = UUID()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let echo = #"{ "ok": true, "regular_id": "\#(kRegularsTarget.uuidString)" }"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echo)
        }

        let result = try await service.redeemInvite(token: token)
        XCTAssertEqual(result, .success(regularId: kRegularsTarget))

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/rpc/redeem_regular_invite") == true)
        let body = decodedBody(request)
        XCTAssertEqual(body?.count, 1)
        XCTAssertEqual(body?["p_token"] as? String, token.uuidString)
    }

    // MARK: sendNotice

    func testSendNotice_requestBody_immediate_containsSenderAndBodyOnly() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let echo = """
            [{
              "id": "\(UUID().uuidString)",
              "sender_id": "\(kRegularsUser.uuidString)",
              "body": "Moving my car",
              "scheduled_for": null,
              "created_at": "2026-09-18T10:00:00+00:00",
              "expires_at": "2026-09-18T11:00:00+00:00"
            }]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, echo)
        }

        _ = try await service.sendNotice(body: "Moving my car")

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/regular_notices") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
        let body = decodedBody(request)
        XCTAssertEqual(body?.count, 2, "an immediate notice must send exactly sender_id + body — no scheduled_for key at all")
        XCTAssertEqual(body?["sender_id"] as? String, kRegularsUser.uuidString)
        XCTAssertEqual(body?["body"] as? String, "Moving my car")
        XCTAssertNil(body?["created_at"])
        XCTAssertNil(body?["expires_at"], "expires_at is trigger-derived server-side; the client must never send it")
    }

    func testSendNotice_requestBody_scheduled_includesScheduledFor() async throws {
        let service = await makeAuthenticatedService()
        let scheduledFor = Date(timeIntervalSince1970: 1_800_000_000)

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let echo = """
            [{
              "id": "\(UUID().uuidString)",
              "sender_id": "\(kRegularsUser.uuidString)",
              "body": "I'm out at 2:00 PM",
              "scheduled_for": "2026-09-18T14:00:00+00:00",
              "created_at": "2026-09-18T10:00:00+00:00",
              "expires_at": "2026-09-18T15:00:00+00:00"
            }]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, echo)
        }

        _ = try await service.sendNotice(body: "I'm out at 2:00 PM", scheduledFor: scheduledFor)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        let body = decodedBody(request)
        XCTAssertEqual(body?.count, 3, "a scheduled notice sends sender_id + body + scheduled_for, nothing more")
        XCTAssertNotNil(body?["scheduled_for"])
    }

    func testSendNotice_overLengthBody_throwsInvalidNoticeBody_beforeNetworkCall() async {
        let service = await makeAuthenticatedService()

        var requestCount = 0
        RegularsWireMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }

        let overLong = String(repeating: "x", count: RegularsService.noticeBodyMaxLength + 1)
        do {
            _ = try await service.sendNotice(body: overLong)
            XCTFail("expected invalidNoticeBody to be thrown")
        } catch {
            XCTAssertEqual(error as? RegularsServiceError, .invalidNoticeBody)
        }
        XCTAssertEqual(requestCount, 0, "an over-length body must fail client-side, never spend a round trip")
    }

    // MARK: block / unblock

    func testBlock_requestBody_containsUserIdAndBlockedUserId() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await service.block(userId: kRegularsTarget)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/rest/v1/regular_blocks") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=minimal")
        let body = decodedBody(request)
        XCTAssertEqual(body?.count, 2)
        XCTAssertEqual(body?["user_id"] as? String, kRegularsUser.uuidString)
        XCTAssertEqual(body?["blocked_user_id"] as? String, kRegularsTarget.uuidString)
    }

    func testUnblock_requestIsDeleteWithQueryFilters() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await service.unblock(userId: kRegularsTarget)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "DELETE")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_blocks") == true)
        let userIdFilter = components?.queryItems?.first(where: { $0.name == "user_id" })?.value
        let blockedFilter = components?.queryItems?.first(where: { $0.name == "blocked_user_id" })?.value
        XCTAssertEqual(userIdFilter, "eq.\(kRegularsUser.uuidString)")
        XCTAssertEqual(blockedFilter, "eq.\(kRegularsTarget.uuidString)")
    }

    // MARK: fetch reads

    func testFetchEdges_requestIncludesSelectAndOrderQueryItems() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "[]".data(using: .utf8)!)
        }

        await service.fetchEdges()

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "GET")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_edges") == true)
        XCTAssertNotNil(components?.queryItems?.first(where: { $0.name == "select" }))
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "order" })?.value, "created_at.desc")
        XCTAssertNil(service.edgesFetchError)
    }

    func testFetchNotices_requestIncludesSelectQueryItems() async throws {
        let service = await makeAuthenticatedService()

        var capturedRequest: URLRequest? = nil
        RegularsWireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "[]".data(using: .utf8)!)
        }

        await service.fetchNotices()

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "GET")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_notices") == true)
        let selectValue = components?.queryItems?.first(where: { $0.name == "select" })?.value
        XCTAssertTrue(selectValue?.contains("scheduled_for") == true, "the select list must include scheduled_for or Scheduled Departure notices decode with a silently-nil field")
        XCTAssertNil(service.noticesFetchError)
    }
}

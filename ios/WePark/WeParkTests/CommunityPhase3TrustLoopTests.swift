//
//  CommunityPhase3TrustLoopTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 3 (build 20 S9) — the trust loop: ReactionsRow routing (claim vs
//  confirm/dispute vs delete vs hidden), `claimPin` write-path, profile row formatting
//  (tenure + accuracy divide-by-zero guard), and the "THIS WEEK" leaderboard's pure
//  ranking logic.
//  Spec: docs/community-2.0-reconciliation-spec.md §2.10, §3 Phase 3, §6.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  Test inventory:
//    ReactionsRowKind routing (CommunityPin.reactionsRowKind):
//      1. testReactionsRowKind_openSpot_notOwn_returnsVote
//      2. testReactionsRowKind_enforcementActive_notOwn_returnsVote (existing-type regression)
//      3. testReactionsRowKind_leavingSoon_notOwn_returnsClaim
//      4. testReactionsRowKind_leavingSoon_own_returnsDelete (own-pin guard wins first)
//      5. testReactionsRowKind_openSpot_own_returnsDelete
//      6. testReactionsRowKind_openData_returnsHidden (showsReactionsRow gate still applies)
//      7. testReactionsRowKind_nilCurrentUserId_notOwn_returnsVote
//
//    claimPin write path:
//      8. testClaimPin_trueResponse_returnsTrue
//      9. testClaimPin_falseResponse_returnsFalse_doesNotThrow
//      10. testClaimPin_nonSuccessStatus_throwsHttpError
//      11. testClaimPin_requestUsesRpcPathAndPinIdPayload
//      12. testClaimPin_noAuth_throwsNotAuthenticated
//
//    fetchOwnProfile / fetchLeaderboardPins request shape:
//      13. testFetchOwnProfile_queryFiltersByUserId
//      14. testFetchOwnProfile_decodesRow
//      15. testFetchOwnProfile_emptyArray_returnsNil
//      16. testFetchLeaderboardPins_queryIncludesSourceConfirmCountAndWindow
//      17. testFetchLeaderboardPins_unknownZone_returnsEmptyWithoutNetworkCall
//
//    ProfileRowFormatting.accuracyLabel (AC-P3.3 boundaries):
//      18. testAccuracyLabel_zeroOverZero_returnsEmDash
//      19. testAccuracyLabel_zeroOverFive_returnsZeroPercent
//      20. testAccuracyLabel_fiveOverFive_returnsHundredPercent
//      21. testAccuracyLabel_roundsToNearestPercent
//
//    ProfileRowFormatting.tenure:
//      22. testTenure_underOneWeek_returnsNewThisWeek
//      23. testTenure_twoWeeks_returnsMemberForWeeks
//      24. testTenure_oneMonth_singularWording
//      25. testTenure_sixMonths_returnsMemberForMonths
//      26. testTenure_twoYears_returnsMemberForYears
//
//    CommunityLeaderboard.build:
//      27. testLeaderboard_ranksByConfirmedCountDescending
//      28. testLeaderboard_tiesBrokenByUsernameAscending
//      29. testLeaderboard_capsAtTopFive
//      30. testLeaderboard_ignoresPinsWithNilAuthor
//      31. testLeaderboard_noProfile_omitsYouRow
//      32. testLeaderboard_hasProfile_alreadyInTopFive_noDuplicateRow
//      33. testLeaderboard_hasProfile_belowTopFive_appendsRealRankAndCount
//      34. testLeaderboard_hasProfile_zeroQualifyingReports_appendsNilRankZeroCount
//      35. testLeaderboard_emptyPins_hasProfile_appendsZeroRankRow
//

import XCTest
@testable import WePark

// MARK: - Fixtures

private func phase3Decoder() -> JSONDecoder {
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

/// Local pin fixture builder — `crewFeedPinFixture` in `CrewFeedSectionTests.swift` is
/// `private` to that file (this repo's file-independence convention for test fixtures).
private func phase3PinFixture(
    id: String = "20000000-0000-0000-0000-000000000001",
    pinType: String = "open_spot",
    source: String = "crowd",
    lifespan: String = "ephemeral",
    reportGroupId: String? = nil,
    authorId: String? = "A0000000-0000-0000-0000-000000000001",
    authorUsername: String? = "MulberryMike",
    lat: Double = 40.7230,
    lng: Double = -73.9950,
    createdAt: String = "2026-08-27T09:00:00+00:00",
    confirmCount: Int = 0
) -> CommunityPin {
    let json = """
    {
      "id": "\(id)",
      "pin_type": "\(pinType)",
      "source": "\(source)",
      "lifespan": "\(lifespan)",
      "lat": \(lat),
      "lng": \(lng),
      "segment_id": null,
      "zone_id": "nolita",
      "author_id": \(authorId.map { "\"\($0)\"" } ?? "null"),
      "author_username": \(authorUsername.map { "\"\($0)\"" } ?? "null"),
      "created_at": "\(createdAt)",
      "updated_at": "\(createdAt)",
      "expires_at": null,
      "resolved_at": null,
      "confirm_count": \(confirmCount),
      "dispute_count": 0,
      "meta": null,
      "notes": null,
      "report_group_id": \(reportGroupId.map { "\"\($0)\"" } ?? "null")
    }
    """.data(using: .utf8)!
    // Force-unwrap acceptable in tests (fixture-authoring error should fail loudly).
    return try! phase3Decoder().decode(CommunityPin.self, from: json)
}

private let kPhase3UserA = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
private let kPhase3UserB = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!

/// URLSession sometimes converts `httpBody` to an `httpBodyStream` when a request passes
/// through a session delegate/protocol — same fallback `Tier3AuthReactionsTests.swift`'s
/// (private-scoped) `bodyData(from:)` and `CommunityPhase2bWritePathTests.swift`'s
/// `phase2bBodyData(from:)` already established; duplicated locally per this repo's test-file
/// independence convention (both those helpers are `private` to their own files).
private func phase3BodyData(from request: URLRequest) -> Data? {
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

// MARK: - ReactionsRowKind routing

/// @MainActor required: `phase3PinFixture` decodes `CommunityPin`, whose `Codable`
/// conformance is main-actor-isolated under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting — same reasoning as
/// `FT15B4Tests.swift`'s `FT15IsUpcomingTests`/`FT15ShowsReactionsRowTests`.
@MainActor
final class ReactionsRowKindTests: XCTestCase {

    func testReactionsRowKind_openSpot_notOwn_returnsVote() {
        let pin = phase3PinFixture(pinType: "open_spot", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserB), .vote)
    }

    func testReactionsRowKind_enforcementActive_notOwn_returnsVote() {
        let pin = phase3PinFixture(pinType: "enforcement_active", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserB), .vote)
    }

    func testReactionsRowKind_leavingSoon_notOwn_returnsClaim() {
        let pin = phase3PinFixture(pinType: "leaving_soon", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserB), .claim)
    }

    /// Own-pin guard wins BEFORE the leaving_soon check — an author sees the delete
    /// affordance for their own spot-handoff pin, never a claim button on their own pin.
    func testReactionsRowKind_leavingSoon_own_returnsDelete() {
        let pin = phase3PinFixture(pinType: "leaving_soon", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserA), .delete)
    }

    func testReactionsRowKind_openSpot_own_returnsDelete() {
        let pin = phase3PinFixture(pinType: "open_spot", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserA), .delete)
    }

    /// `showsReactionsRow`'s existing gate (source == .crowd) still applies — an open-data
    /// pin never shows any reactions row at all, regardless of viewer.
    func testReactionsRowKind_openData_returnsHidden() {
        let pin = phase3PinFixture(pinType: "filming", source: "open_data", authorId: nil)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: kPhase3UserB), .hidden)
    }

    func testReactionsRowKind_nilCurrentUserId_notOwn_returnsVote() {
        let pin = phase3PinFixture(pinType: "sweeper_passed", authorId: kPhase3UserA.uuidString)
        XCTAssertEqual(pin.reactionsRowKind(currentUserId: nil), .vote)
    }
}

// MARK: - claimPin write path

@MainActor
final class ClaimPinTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        let keys = [
            "wepark_auth_access_token", "wepark_auth_refresh_token",
            "wepark_auth_user_id", "wepark_auth_expires_at",
        ]
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private let kURL = URL(string: "https://phase3-claim-test.supabase.co")!
    private let kAnonKey = "test-anon-key-phase3-claim"
    private let kUser = UUID(uuidString: "C0000002-0000-0000-0000-000000000001")!

    private func authResponseJSON() -> Data {
        let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
        return """
        {
          "access_token": "eyJ.test.token",
          "refresh_token": "refresh-test-token",
          "token_type": "bearer",
          "expires_in": 3600,
          "expires_at": \(expiresAt),
          "user": {
            "id": "\(kUser.uuidString)",
            "aud": "authenticated",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "is_anonymous": true
          }
        }
        """.data(using: .utf8)!
    }

    private func makeAuthenticatedPair() async -> (CommunityPinService, SupabaseAuthService) {
        let authMockConfig = URLSessionConfiguration.ephemeral
        authMockConfig.protocolClasses = [AuthMockURLProtocol.self]
        let authMockSession = URLSession(configuration: authMockConfig)

        let authService = SupabaseAuthService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await authMockSession.data(for: $0) }
        )
        AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: self.kURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.authResponseJSON())
        }
        await authService.ensureSession()

        let writeConfig = URLSessionConfiguration.ephemeral
        writeConfig.protocolClasses = [WriteMockURLProtocol.self]
        let writeSession = URLSession(configuration: writeConfig)

        let pinService = CommunityPinService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            urlSession: writeSession,
            authService: authService
        )
        return (pinService, authService)
    }

    func testClaimPin_trueResponse_returnsTrue() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        WriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "true".data(using: .utf8)!)
        }

        let claimed = try await pinService.claimPin(pinId: UUID())
        XCTAssertTrue(claimed)
    }

    /// Spec §2.10/§3 Phase 4: `false` is the expected, race-safe "someone beat you to it"
    /// outcome — must NOT throw.
    func testClaimPin_falseResponse_returnsFalse_doesNotThrow() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        WriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "false".data(using: .utf8)!)
        }

        let claimed = try await pinService.claimPin(pinId: UUID())
        XCTAssertFalse(claimed)
    }

    func testClaimPin_nonSuccessStatus_throwsHttpError() async {
        let (pinService, _) = await makeAuthenticatedPair()
        WriteMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data())
        }

        do {
            _ = try await pinService.claimPin(pinId: UUID())
            XCTFail("Expected httpError to be thrown")
        } catch let error as CommunityPinWriteError {
            guard case .httpError(let status) = error else {
                XCTFail("Expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("Expected CommunityPinWriteError, got \(error)")
        }
    }

    func testClaimPin_requestUsesRpcPathAndPinIdPayload() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        let pinId = UUID()
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?

        WriteMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            if let data = phase3BodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "true".data(using: .utf8)!)
        }

        _ = try await pinService.claimPin(pinId: pinId)

        XCTAssertTrue(capturedRequest?.url?.path.contains("rpc/claim_pin") ?? false)
        XCTAssertEqual(capturedBody?["p_pin_id"] as? String, pinId.uuidString)
    }

    func testClaimPin_noAuth_throwsNotAuthenticated() async {
        let pinService = CommunityPinService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            urlSession: .shared,
            authService: nil
        )

        do {
            _ = try await pinService.claimPin(pinId: UUID())
            XCTFail("Expected .notAuthenticated to be thrown")
        } catch CommunityPinWriteError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("Expected CommunityPinWriteError.notAuthenticated, got \(error)")
        }
    }
}

// MARK: - fetchOwnProfile / fetchLeaderboardPins request shape

@MainActor
final class ProfileAndLeaderboardFetchTests: XCTestCase {

    private let kURL = URL(string: "https://phase3-fetch-test.supabase.co")!
    private let kAnonKey = "test-anon-key-phase3-fetch"
    private let kNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeService(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> CommunityPinService {
        PinMockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PinMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CommunityPinService(
            supabaseURL: kURL,
            supabaseAnonKey: kAnonKey,
            nowProvider: { self.kNow },
            urlSession: session
        )
    }

    func testFetchOwnProfile_queryFiltersByUserId() async throws {
        let userId = UUID()
        var capturedURL: String?
        let service = makeService { request in
            capturedURL = request.url?.absoluteString
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        _ = try await service.fetchOwnProfile(userId: userId)

        XCTAssertTrue(capturedURL?.contains("id=eq.\(userId.uuidString)") ?? false, "Got: \(capturedURL ?? "nil")")
        XCTAssertTrue(capturedURL?.contains("rest/v1/profiles") ?? false)
    }

    func testFetchOwnProfile_decodesRow() async throws {
        let userId = UUID()
        let json = """
        [{
          "id": "\(userId.uuidString)",
          "username": "MottStRegular",
          "avatar": "🗽",
          "reputation": 42,
          "created_at": "2026-06-01T00:00:00+00:00",
          "helped_count": 5,
          "accurate_report_count": 3,
          "total_report_count": 4
        }]
        """.data(using: .utf8)!

        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let profile = try await service.fetchOwnProfile(userId: userId)

        XCTAssertEqual(profile?.username, "MottStRegular")
        XCTAssertEqual(profile?.avatar, "🗽")
        XCTAssertEqual(profile?.reputation, 42)
        XCTAssertEqual(profile?.helpedCount, 5)
        XCTAssertEqual(profile?.accurateReportCount, 3)
        XCTAssertEqual(profile?.totalReportCount, 4)
    }

    func testFetchOwnProfile_emptyArray_returnsNil() async throws {
        let service = makeService { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "[]".data(using: .utf8)!)
        }

        let profile = try await service.fetchOwnProfile(userId: UUID())
        XCTAssertNil(profile)
    }

    func testFetchLeaderboardPins_queryIncludesSourceConfirmCountAndWindow() async throws {
        var capturedURL: String?
        let service = makeService { request in
            capturedURL = request.url?.absoluteString
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        _ = try await service.fetchLeaderboardPins(zoneId: "nolita")

        let url = capturedURL ?? ""
        XCTAssertTrue(url.contains("source=eq.crowd"), "Got: \(url)")
        XCTAssertTrue(url.contains("confirm_count=gt.0"), "Got: \(url)")
        XCTAssertTrue(url.contains("created_at=gte."), "Got: \(url)")
        // No expiry/resolved-at filter — trailing-7-day counts must include long-expired
        // ephemeral pins (see fetchLeaderboardPins's doc comment).
        XCTAssertFalse(url.contains("expires_at"), "Got: \(url)")
        XCTAssertFalse(url.contains("resolved_at"), "Got: \(url)")
    }

    func testFetchLeaderboardPins_unknownZone_returnsEmptyWithoutNetworkCall() async throws {
        var callCount = 0
        let service = makeService { request in
            callCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }

        let pins = try await service.fetchLeaderboardPins(zoneId: "soho-les")

        XCTAssertTrue(pins.isEmpty)
        XCTAssertEqual(callCount, 0, "No network call should fire for a zone id with no known bounding box")
    }
}

// MARK: - ProfileRowFormatting.accuracyLabel (AC-P3.3 boundaries)

final class AccuracyLabelTests: XCTestCase {

    func testAccuracyLabel_zeroOverZero_returnsEmDash() {
        XCTAssertEqual(ProfileRowFormatting.accuracyLabel(accurate: 0, total: 0), "—")
    }

    func testAccuracyLabel_zeroOverFive_returnsZeroPercent() {
        XCTAssertEqual(ProfileRowFormatting.accuracyLabel(accurate: 0, total: 5), "0%")
    }

    func testAccuracyLabel_fiveOverFive_returnsHundredPercent() {
        XCTAssertEqual(ProfileRowFormatting.accuracyLabel(accurate: 5, total: 5), "100%")
    }

    func testAccuracyLabel_roundsToNearestPercent() {
        // 2/3 = 66.66...% → rounds to 67%.
        XCTAssertEqual(ProfileRowFormatting.accuracyLabel(accurate: 2, total: 3), "67%")
    }
}

// MARK: - ProfileRowFormatting.tenure

final class TenureFormattingTests: XCTestCase {

    private let kNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testTenure_underOneWeek_returnsNewThisWeek() {
        let createdAt = kNow.addingTimeInterval(-3 * 86400)
        XCTAssertEqual(ProfileRowFormatting.tenure(createdAt: createdAt, now: kNow), "New this week")
    }

    func testTenure_twoWeeks_returnsMemberForWeeks() {
        let createdAt = kNow.addingTimeInterval(-14 * 86400)
        XCTAssertEqual(ProfileRowFormatting.tenure(createdAt: createdAt, now: kNow), "Member for 2 weeks")
    }

    func testTenure_oneMonth_singularWording() {
        let createdAt = kNow.addingTimeInterval(-32 * 86400)
        XCTAssertEqual(ProfileRowFormatting.tenure(createdAt: createdAt, now: kNow), "Member for 1 month")
    }

    func testTenure_sixMonths_returnsMemberForMonths() {
        let createdAt = kNow.addingTimeInterval(-180 * 86400)
        XCTAssertEqual(ProfileRowFormatting.tenure(createdAt: createdAt, now: kNow), "Member for 6 months")
    }

    func testTenure_twoYears_returnsMemberForYears() {
        let createdAt = kNow.addingTimeInterval(-730 * 86400)
        XCTAssertEqual(ProfileRowFormatting.tenure(createdAt: createdAt, now: kNow), "Member for 2 years")
    }
}

// MARK: - CommunityLeaderboard.build

/// @MainActor required — `phase3PinFixture` decodes `CommunityPin`; see
/// `ReactionsRowKindTests`'s doc comment above.
@MainActor
final class CommunityLeaderboardTests: XCTestCase {

    func testLeaderboard_ranksByConfirmedCountDescending() {
        let userA = UUID(), userB = UUID()
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000001", authorId: userA.uuidString, authorUsername: "Alice", confirmCount: 1),
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000002", authorId: userA.uuidString, authorUsername: "Alice", confirmCount: 1),
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000003", authorId: userB.uuidString, authorUsername: "Bob", confirmCount: 1),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: nil, hasProfile: false)

        XCTAssertEqual(entries.map(\.username), ["Alice", "Bob"])
        XCTAssertEqual(entries.first?.confirmedCount, 2)
        XCTAssertEqual(entries.first?.rank, 1)
    }

    func testLeaderboard_tiesBrokenByUsernameAscending() {
        let userA = UUID(), userB = UUID()
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000004", authorId: userB.uuidString, authorUsername: "Zeke", confirmCount: 1),
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000005", authorId: userA.uuidString, authorUsername: "Alice", confirmCount: 1),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: nil, hasProfile: false)

        XCTAssertEqual(entries.map(\.username), ["Alice", "Zeke"])
    }

    func testLeaderboard_capsAtTopFive() {
        let pins = (0..<7).map { i in
            phase3PinFixture(
                id: "30000000-0000-0000-0000-00000000001\(i)",
                authorId: UUID().uuidString,
                authorUsername: "Neighbor\(i)",
                confirmCount: 1
            )
        }

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: nil, hasProfile: false)

        XCTAssertEqual(entries.count, 5)
    }

    func testLeaderboard_ignoresPinsWithNilAuthor() {
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000006", authorId: nil, authorUsername: nil, confirmCount: 1),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: nil, hasProfile: false)

        XCTAssertTrue(entries.isEmpty)
    }

    func testLeaderboard_noProfile_omitsYouRow() {
        let currentUser = UUID()
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000007", authorId: UUID().uuidString, authorUsername: "Someone", confirmCount: 1),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: currentUser, hasProfile: false)

        XCTAssertFalse(entries.contains { $0.username == "You" })
    }

    func testLeaderboard_hasProfile_alreadyInTopFive_noDuplicateRow() {
        let currentUser = UUID()
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000008", authorId: currentUser.uuidString, authorUsername: "Me", confirmCount: 3),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: currentUser, hasProfile: true)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.username, "Me")
        XCTAssertTrue(entries.first?.isCurrentUser ?? false)
    }

    func testLeaderboard_hasProfile_belowTopFive_appendsRealRankAndCount() {
        let currentUser = UUID()
        var pins = (0..<5).map { i in
            phase3PinFixture(
                id: "30000000-0000-0000-0000-00000000002\(i)",
                authorId: UUID().uuidString,
                authorUsername: "Neighbor\(i)",
                confirmCount: 5
            )
        }
        pins.append(phase3PinFixture(id: "30000000-0000-0000-0000-000000000030", authorId: currentUser.uuidString, authorUsername: "Me", confirmCount: 1))

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: currentUser, hasProfile: true)

        XCTAssertEqual(entries.count, 6)
        let youRow = entries.last
        XCTAssertEqual(youRow?.username, "You")
        XCTAssertEqual(youRow?.rank, 6)
        XCTAssertEqual(youRow?.confirmedCount, 1)
        XCTAssertTrue(youRow?.isCurrentUser ?? false)
    }

    /// Has a profile but zero qualifying (confirm_count > 0) pins this week — honest zero,
    /// no fabricated rank (spec's "real data or nothing" principle).
    func testLeaderboard_hasProfile_zeroQualifyingReports_appendsNilRankZeroCount() {
        let currentUser = UUID()
        let pins = [
            phase3PinFixture(id: "30000000-0000-0000-0000-000000000031", authorId: UUID().uuidString, authorUsername: "Someone", confirmCount: 1),
        ]

        let entries = CommunityLeaderboard.build(pins: pins, currentUserId: currentUser, hasProfile: true)

        let youRow = entries.last
        XCTAssertEqual(youRow?.username, "You")
        XCTAssertNil(youRow?.rank)
        XCTAssertEqual(youRow?.confirmedCount, 0)
    }

    func testLeaderboard_emptyPins_hasProfile_appendsZeroRankRow() {
        let currentUser = UUID()

        let entries = CommunityLeaderboard.build(pins: [], currentUserId: currentUser, hasProfile: true)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.username, "You")
        XCTAssertNil(entries.first?.rank)
        XCTAssertEqual(entries.first?.confirmedCount, 0)
    }
}

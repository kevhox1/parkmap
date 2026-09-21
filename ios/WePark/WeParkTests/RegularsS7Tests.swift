//
//  RegularsS7Tests.swift
//  WeParkTests
//
//  Regulars network — S7 (iOS UI session). Spec: docs/regulars-network-spec.md §3.1/§3.2
//  (settings/invite/redemption client surfaces). Sequencing: docs/regulars-roadmap.md, session
//  S7.
//
//  Every test in this file targets PURE, view-free logic — `Services/RegularsInviteRouting.swift`
//  and `RegularInviteView.qrCodeImage(from:)` — per this session's dispatch ("no toolchain — view-
//  model/pure-logic level"). No SwiftUI view body is hosted or inspected anywhere here (this
//  target has no ViewInspector-equivalent dependency); the three new views'
//  (`RegularsSettingsView`/`RegularInviteView`/`RegularInviteRedemptionView`) top-level
//  `AppConstants.regularsEnabled`/`regularsSettingsRowVisible()` guards are therefore verified
//  by READING the source (each view's own header comment states which pure gate it checks) plus
//  the pre-existing S5 guard tests on those same pure functions
//  (`RegularsFlagGuardTests`, `RegularsModelServiceTests.swift`) — not re-tested here, since
//  re-asserting `AppConstants.regularsSettingsRowVisible(enabled: false) == false` a second time
//  in a second file would just duplicate that coverage under a new name. The ONE net-new gating
//  helper this session adds (`RegularsInviteLink.resolveRedemptionToken(from:enabled:)`, the
//  `.onOpenURL` entry point's own gate) IS covered below, since it didn't exist before this
//  session.
//
//  Test inventory (39 tests, updated post-QA-pass-1 — see `docs/qa/pr115-regulars-s7.md`):
//   1. RegularsInviteLinkTests (14) — build/parse round-trip, malformed/foreign-URL rejection,
//      the net-new `resolveRedemptionToken` gating helper, and (QA finding #2) an explicit,
//      documented trailing-slash-is-accepted lock-in test.
//   2. InviteCountdownTests (6) — countdown math against an explicit, fixed clock (no
//      `Date()`/`Calendar.current` internally).
//   3. RegularInviteRedemptionCopyTests (7) — all four result states + the pre-confirm copy,
//      including a banned-word sweep across every string this session's dispatch specifically
//      named (avoid, ticket, fine, evasion, dodge).
//   4. RegularInviteViewQRTests (2) — the CoreImage QR payload/geometry contract.
//   5. RegularsServiceS7WireTests (10) — the three original S7 `RegularsService` additions
//      (`removeRegular`/`cancelInvite`/`fetchProfiles`) at the actual outgoing `URLRequest`
//      level, same discipline as S5's own `RegularsServiceWireTests`; PLUS, added in the QA-fix
//      pass: `fetchInvite(id:)`'s own dedicated wire test (finding #6, matching its three
//      siblings) and three tests on the NEW `regenerateInvite(previousId:)` method (finding #1,
//      the actual fix — revoke-before-create ordering, the nil-previousId first-creation path,
//      and the "a failed revoke must never be followed by a create" guarantee).
//
//  No Calendar.current.
//

import XCTest
@testable import WePark

// MARK: - 1. RegularsInviteLink (build/parse/gate)

final class RegularsInviteLinkTests: XCTestCase {

    private let kToken = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    func testBuild_producesExpectedURLString() {
        let url = RegularsInviteLink.build(token: kToken)
        XCTAssertEqual(url.absoluteString, "wepark://invite/\(kToken.uuidString)")
    }

    func testParse_roundTrip_validURL_returnsToken() {
        let url = RegularsInviteLink.build(token: kToken)
        XCTAssertEqual(RegularsInviteLink.parse(url), kToken)
    }

    func testParse_isCaseInsensitiveForSchemeAndHost() {
        let url = URL(string: "WEPARK://INVITE/\(kToken.uuidString)")!
        XCTAssertEqual(RegularsInviteLink.parse(url), kToken)
    }

    func testParse_tokenCaseInsensitive() {
        let url = URL(string: "wepark://invite/\(kToken.uuidString.lowercased())")!
        XCTAssertEqual(RegularsInviteLink.parse(url), kToken)
    }

    func testParse_rejectsWrongScheme_foreignHTTPSLink() {
        let url = URL(string: "https://invite/\(kToken.uuidString)")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    func testParse_rejectsWrongScheme_differentCustomScheme() {
        // A structurally-identical deep link belonging to a DIFFERENT app must never be
        // silently accepted just because the host/path shape happens to match.
        let url = URL(string: "otherapp://invite/\(kToken.uuidString)")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    func testParse_rejectsWrongHost() {
        let url = URL(string: "wepark://redeem/\(kToken.uuidString)")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    func testParse_rejectsMalformedToken() {
        let url = URL(string: "wepark://invite/not-a-uuid")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    func testParse_rejectsMissingToken() {
        let url = URL(string: "wepark://invite/")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    func testParse_rejectsExtraPathSegments() {
        let url = URL(string: "wepark://invite/\(kToken.uuidString)/extra")!
        XCTAssertNil(RegularsInviteLink.parse(url))
    }

    /// S7 QA finding #2 (`docs/qa/pr115-regulars-s7.md`) — locks in the deliberate,
    /// documented-not-accidental choice to accept a trailing slash as equivalent to no trailing
    /// slash, rather than leaving it an untested assumption about `URL.pathComponents`'s own
    /// normalization behavior. See `RegularsInviteLink.parse(_:)`'s own doc comment for the full
    /// reasoning.
    func testParse_acceptsTrailingSlash_normalizedEquivalentToNoTrailingSlash() {
        let url = URL(string: "wepark://invite/\(kToken.uuidString)/")!
        XCTAssertEqual(RegularsInviteLink.parse(url), kToken)
    }

    // MARK: resolveRedemptionToken (the .onOpenURL gate)

    func testResolveRedemptionToken_enabledTrue_validURL_returnsToken() {
        let url = RegularsInviteLink.build(token: kToken)
        XCTAssertEqual(RegularsInviteLink.resolveRedemptionToken(from: url, enabled: true), kToken)
    }

    func testResolveRedemptionToken_enabledFalse_validURL_returnsNil() {
        // The single most important assertion in this file: even a PERFECTLY valid invite link
        // must be a no-op while Regulars is dark-shipped.
        let url = RegularsInviteLink.build(token: kToken)
        XCTAssertNil(RegularsInviteLink.resolveRedemptionToken(from: url, enabled: false))
    }

    func testResolveRedemptionToken_defaultParameter_matchesShippedFlag() {
        // Same default-parameter-binding discipline as
        // `testRegularsSettingsRow_hidden_whenDisabled` (S5, PR #113 QA pass 1 Finding #1) — the
        // no-argument call must resolve identically to an explicit call with the real flag.
        let url = RegularsInviteLink.build(token: kToken)
        XCTAssertEqual(
            RegularsInviteLink.resolveRedemptionToken(from: url),
            RegularsInviteLink.resolveRedemptionToken(from: url, enabled: AppConstants.regularsEnabled)
        )
    }
}

// MARK: - 2. InviteCountdown (fixed clock only — no Date()/Calendar.current)

final class InviteCountdownTests: XCTestCase {

    private let kExpiresAt = Date(timeIntervalSince1970: 1_800_000_600) // fixed reference instant

    func testRemainingSeconds_beforeExpiry() {
        let now = kExpiresAt.addingTimeInterval(-587) // 9:47 remaining
        XCTAssertEqual(InviteCountdown.remainingSeconds(expiresAt: kExpiresAt, now: now), 587)
    }

    func testRemainingSeconds_exactlyAtExpiry_isZero() {
        XCTAssertEqual(InviteCountdown.remainingSeconds(expiresAt: kExpiresAt, now: kExpiresAt), 0)
    }

    func testRemainingSeconds_afterExpiry_clampsAtZero_neverNegative() {
        let now = kExpiresAt.addingTimeInterval(120)
        XCTAssertEqual(InviteCountdown.remainingSeconds(expiresAt: kExpiresAt, now: now), 0)
    }

    func testIsExpired_falseWhileTimeRemains_trueAtOrPastExpiry() {
        XCTAssertFalse(InviteCountdown.isExpired(expiresAt: kExpiresAt, now: kExpiresAt.addingTimeInterval(-1)))
        XCTAssertTrue(InviteCountdown.isExpired(expiresAt: kExpiresAt, now: kExpiresAt))
        XCTAssertTrue(InviteCountdown.isExpired(expiresAt: kExpiresAt, now: kExpiresAt.addingTimeInterval(1)))
    }

    func testFormatted_minutesAndPaddedSeconds() {
        // Spec §3.2's own worked example, verbatim: "a visible 'expires in 9:47' countdown."
        XCTAssertEqual(InviteCountdown.formatted(remainingSeconds: 587), "9:47")
        XCTAssertEqual(InviteCountdown.formatted(remainingSeconds: 3), "0:03")
        XCTAssertEqual(InviteCountdown.formatted(remainingSeconds: 600), "10:00")
    }

    func testFormatted_zero_returnsExpiredNotZeroColonZero() {
        XCTAssertEqual(InviteCountdown.formatted(remainingSeconds: 0), "Expired")
    }
}

// MARK: - 3. RegularInviteRedemptionCopy (honest, non-punitive copy)

final class RegularInviteRedemptionCopyTests: XCTestCase {

    /// Exact banned-word list from this session's dispatch — checked case-insensitively, as a
    /// substring match, against every string this file exposes.
    private let bannedWords = ["avoid", "ticket", "fine", "evasion", "dodge"]

    private let kRegularId = UUID()

    func testResultCopy_success_withHandle_namesTheRegular() {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: .success(regularId: kRegularId), regularHandle: "MottStRegular")
        XCTAssertTrue(copy.body.contains("MottStRegular"))
    }

    func testResultCopy_success_withoutHandle_stillCelebratesGenerically() {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: .success(regularId: kRegularId), regularHandle: nil)
        XCTAssertFalse(copy.title.isEmpty)
        XCTAssertFalse(copy.body.isEmpty)
    }

    func testResultCopy_expiredOrUsed_isHonestAndNonPunitive() {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: .expiredOrUsed, regularHandle: nil)
        XCTAssertFalse(copy.title.isEmpty)
        XCTAssertFalse(copy.body.isEmpty)
    }

    func testResultCopy_cannotAddSelf_explainsWhatToDoInstead() {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: .cannotAddSelf, regularHandle: nil)
        XCTAssertTrue(copy.body.lowercased().contains("share"))
    }

    func testResultCopy_blocked_isPlainAndDoesNotAssignBlame() {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: .blocked, regularHandle: nil)
        XCTAssertFalse(copy.title.isEmpty)
        XCTAssertFalse(copy.body.isEmpty)
    }

    func testAllCopy_neverContainsAnyBannedWord() {
        let allResults: [RegularInviteRedeemResult] = [
            .success(regularId: kRegularId), .expiredOrUsed, .cannotAddSelf, .blocked,
        ]
        var allStrings: [String] = [
            RegularInviteRedemptionCopy.preConfirmTitle,
            RegularInviteRedemptionCopy.preConfirmBody,
            RegularInviteRedemptionCopy.preConfirmActionTitle,
            RegularInviteRedemptionCopy.preConfirmCancelTitle,
        ]
        for result in allResults {
            let copy = RegularInviteRedemptionCopy.resultCopy(for: result, regularHandle: "Dave")
            allStrings.append(copy.title)
            allStrings.append(copy.body)
        }

        for string in allStrings {
            let lowered = string.lowercased()
            for banned in bannedWords {
                XCTAssertFalse(
                    lowered.contains(banned),
                    "copy string \"\(string)\" must not contain the banned word \"\(banned)\""
                )
            }
        }
    }

    func testIsSuccess_trueOnlyForSuccessCase() {
        XCTAssertTrue(RegularInviteRedeemResult.success(regularId: kRegularId).isSuccess)
        XCTAssertFalse(RegularInviteRedeemResult.expiredOrUsed.isSuccess)
        XCTAssertFalse(RegularInviteRedeemResult.cannotAddSelf.isSuccess)
        XCTAssertFalse(RegularInviteRedeemResult.blocked.isSuccess)
    }
}

// MARK: - 4. RegularInviteView QR generation

final class RegularInviteViewQRTests: XCTestCase {

    func testQRCodeImage_validURLString_returnsNonNilSquareImage() {
        let url = RegularsInviteLink.build(token: UUID())
        guard let image = RegularInviteView.qrCodeImage(from: url.absoluteString) else {
            return XCTFail("expected qrCodeImage(from:) to return a non-nil image for a valid invite URL")
        }
        XCTAssertEqual(image.size.width, image.size.height, "a QR code must render as a square")
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testQRCodeImage_largerScale_producesLargerImage() {
        let url = RegularsInviteLink.build(token: UUID())
        let small = RegularInviteView.qrCodeImage(from: url.absoluteString, scale: 4)
        let large = RegularInviteView.qrCodeImage(from: url.absoluteString, scale: 12)
        guard let small, let large else {
            return XCTFail("expected both QR renders to succeed")
        }
        XCTAssertGreaterThan(large.size.width, small.size.width)
    }
}

// MARK: - 5. RegularsService S7 additions — wire-level tests
//
// Reuses `RegularsAuthMockURLProtocol`/`InMemoryAuthStorage` from
// `RegularsModelServiceTests.swift` (S5, same test target — both `internal` by default) for the
// auth session, but defines its OWN mock URLProtocol/fixtures for `RegularsService`'s own traffic
// (`RegularsS7WireMockURLProtocol`) rather than reusing S5's `RegularsWireMockURLProtocol`, so a
// stray `requestHandler` set by one file's tests can never be read by the other's.

final class RegularsS7WireMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RegularsS7WireMockURLProtocol.requestHandler else {
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

private let kS7WireURL = URL(string: "https://regulars-s7-wire-test.supabase.co")!
private let kS7AnonKey = "test-anon-key-regulars-s7"
private let kS7User = UUID(uuidString: "30000003-0000-0000-0000-000000000003")!
private let kS7Target = UUID(uuidString: "40000004-0000-0000-0000-000000000004")!

private func s7WireSessionJSON() -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.regulars-s7-wire-test.token",
      "refresh_token": "refresh-regulars-s7-wire-test",
      "token_type": "bearer",
      "expires_in": 3600,
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(kS7User.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

private func s7WireMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RegularsS7WireMockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Shared `regular_invites` row-echo fixture for `fetchInvite`/`regenerateInvite`'s wire tests
/// below. Deliberately a TOP-LEVEL function (not an instance method on
/// `RegularsServiceS7WireTests`) — `RegularsAuthMockURLProtocol`/`RegularsS7WireMockURLProtocol`'s
/// `requestHandler` closures are invoked by `URLProtocol.startLoading()` off the main actor, and
/// this file's mock-response closures are assigned from `@MainActor`-isolated test methods; a
/// captured `self.someInstanceMethod()` call inside one of those closures would need to cross an
/// actor boundary this codebase's own `s7WireSessionJSON()`/`regularsWireSessionJSON()` precedent
/// (both ALSO plain top-level functions, same file shape) avoids entirely by never capturing
/// `self` in the first place.
private func s7InviteEchoJSON(id: UUID) -> Data {
    """
    [{
      "id": "\(id.uuidString)",
      "created_by": "\(kS7User.uuidString)",
      "created_at": "2026-09-18T10:00:00+00:00",
      "expires_at": "2026-09-18T10:10:00+00:00",
      "redeemed_by": null,
      "redeemed_at": null,
      "revoked_at": null
    }]
    """.data(using: .utf8)!
}

@MainActor
final class RegularsServiceS7WireTests: XCTestCase {

    private func makeAuthenticatedService() async -> RegularsService {
        let authSession = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RegularsAuthMockURLProtocol.self]
            return config
        }())
        let authService = SupabaseAuthService(
            supabaseURL: kS7WireURL,
            supabaseAnonKey: kS7AnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await authSession.data(for: $0) }
        )
        RegularsAuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kS7WireURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             s7WireSessionJSON())
        }
        await authService.ensureSession()

        return RegularsService(
            supabaseURL: kS7WireURL,
            supabaseAnonKey: kS7AnonKey,
            authService: authService,
            urlSession: s7WireMockSession()
        )
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

    // MARK: removeRegular

    func testRemoveRegular_requestIsDelete_withOrBothOrderingsFilter() async throws {
        let service = await makeAuthenticatedService()
        var capturedRequest: URLRequest?
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await service.removeRegular(otherUserId: kS7Target)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "DELETE")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_edges") == true)
        let query = components?.percentEncodedQuery ?? ""
        XCTAssertTrue(query.contains("low_user_id.eq.\(kS7User.uuidString)"))
        XCTAssertTrue(query.contains("high_user_id.eq.\(kS7Target.uuidString)"))
        XCTAssertTrue(query.contains("low_user_id.eq.\(kS7Target.uuidString)"))
        XCTAssertTrue(query.contains("high_user_id.eq.\(kS7User.uuidString)"))
        XCTAssertTrue(query.hasPrefix("or="), "must use PostgREST's or=(...) combinator to cover both low/high orderings")
    }

    // MARK: cancelInvite

    func testCancelInvite_requestIsPatch_sendsOnlyRevokedAt() async throws {
        let service = await makeAuthenticatedService()
        let inviteId = UUID()
        var capturedRequest: URLRequest?
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await service.cancelInvite(id: inviteId)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "PATCH")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_invites") == true)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "id" })?.value, "eq.\(inviteId.uuidString)")

        guard let body = bodyData(from: request),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("expected a decodable JSON body")
        }
        XCTAssertEqual(json.count, 1, "cancelInvite must send exactly revoked_at — the only client-writable column (§S1-4)")
        XCTAssertNotNil(json["revoked_at"])
    }

    // MARK: fetchProfiles

    func testFetchProfiles_emptyInput_shortCircuitsWithoutNetworkCall() async {
        let service = await makeAuthenticatedService()
        var requestCount = 0
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "[]".data(using: .utf8)!)
        }

        let result = await service.fetchProfiles(ids: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(requestCount, 0)
    }

    func testFetchProfiles_requestShape_noAuthorizationHeader_publicRead() async {
        let service = await makeAuthenticatedService()
        var capturedRequest: URLRequest?
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let echo = """
            [{ "id": "\(kS7Target.uuidString)", "username": "MottStRegular", "avatar": "🥯" }]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echo)
        }

        let result = await service.fetchProfiles(ids: [kS7Target])

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(
            request.value(forHTTPHeaderField: "Authorization"),
            "profiles is a public read — no JWT should be sent, matching CommunityPinService.fetchOwnProfile's own convention"
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "apikey"))
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/profiles") == true)
        XCTAssertEqual(result[kS7Target]?.username, "MottStRegular")
        XCTAssertEqual(result[kS7Target]?.avatar, "🥯")
    }

    func testFetchProfiles_httpError_returnsEmptyDictionary_neverThrows() async {
        let service = await makeAuthenticatedService()
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let result = await service.fetchProfiles(ids: [kS7Target])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: fetchInvite (S7 QA finding #6 — a dedicated wire test matching its three siblings)

    func testFetchInvite_requestShape_pathAndQueryItems() async throws {
        let service = await makeAuthenticatedService()
        let inviteId = UUID()
        var capturedRequest: URLRequest?
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, s7InviteEchoJSON(id: inviteId))
        }

        let fetched = try await service.fetchInvite(id: inviteId)

        guard let request = capturedRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "GET")
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertTrue(components?.path.hasSuffix("/rest/v1/regular_invites") == true)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "id" })?.value, "eq.\(inviteId.uuidString)")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "limit" })?.value, "1")
        XCTAssertNotNil(components?.queryItems?.first(where: { $0.name == "select" }))
        XCTAssertEqual(fetched?.id, inviteId)
    }

    func testFetchInvite_noMatchingRow_returnsNilNotError() async throws {
        let service = await makeAuthenticatedService()
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "[]".data(using: .utf8)!)
        }
        let fetched = try await service.fetchInvite(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: regenerateInvite (S7 QA finding #1 — the actual fix)

    func testRegenerateInvite_previousId_revokesBeforeCreating() async throws {
        let service = await makeAuthenticatedService()
        let previousId = UUID()
        var capturedRequests: [URLRequest] = []
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequests.append(request)
            if request.httpMethod == "PATCH" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, s7InviteEchoJSON(id: UUID()))
        }

        _ = try await service.regenerateInvite(previousId: previousId)

        XCTAssertEqual(capturedRequests.count, 2, "exactly one revoke PATCH, then one create POST — no more, no fewer")
        XCTAssertEqual(capturedRequests[0].httpMethod, "PATCH", "the previous invite must be revoked BEFORE the replacement is created (S7 QA Finding #1)")
        let patchComponents = capturedRequests[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(patchComponents?.queryItems?.first(where: { $0.name == "id" })?.value, "eq.\(previousId.uuidString)")
        XCTAssertEqual(capturedRequests[1].httpMethod, "POST")
        XCTAssertTrue(capturedRequests[1].url?.path.hasSuffix("/rest/v1/regular_invites") == true)
    }

    func testRegenerateInvite_noPreviousId_skipsRevoke_onlyCreates() async throws {
        let service = await makeAuthenticatedService()
        var capturedRequests: [URLRequest] = []
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequests.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, s7InviteEchoJSON(id: UUID()))
        }

        _ = try await service.regenerateInvite(previousId: nil)

        XCTAssertEqual(capturedRequests.count, 1, "first-ever invite creation has nothing to revoke")
        XCTAssertEqual(capturedRequests[0].httpMethod, "POST")
    }

    func testRegenerateInvite_revokeFailsTwice_neverCreatesReplacement() async throws {
        let service = await makeAuthenticatedService()
        let previousId = UUID()
        var capturedRequests: [URLRequest] = []
        RegularsS7WireMockURLProtocol.requestHandler = { request in
            capturedRequests.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await service.regenerateInvite(previousId: previousId)
            XCTFail("expected regenerateInvite to throw when the revoke fails twice in a row")
        } catch {
            // expected — see the assertions below for what actually matters: no create attempt.
        }

        XCTAssertEqual(capturedRequests.count, 2, "retries the revoke exactly once, then gives up")
        XCTAssertTrue(
            capturedRequests.allSatisfy { $0.httpMethod == "PATCH" },
            "a failed revoke must NEVER be followed by a create — that would silently leave two live invites, the exact bug S7 QA Finding #1 fixed"
        )
    }
}

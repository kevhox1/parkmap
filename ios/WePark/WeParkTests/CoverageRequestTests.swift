//
//  CoverageRequestTests.swift
//  WeParkTests
//
//  Open item #39 — "Suggest a neighborhood". Contract: `supabase/11-coverage-requests.sql`
//  header ("THE iOS CONTRACT"). Network tests are URLProtocol-mocked (no live calls); helper
//  names are PREFIXED `CovReq` so they can never shadow another test file's helpers.
//
//  Cases:
//   1. CoverageRequestRulesTests (pure; mirrors the SQL's trim / 2..80 visible / <=500 rules)
//      - testCity_boundaries_twoVisibleToEighty
//      - testCity_blankAndInvisibleOnly_isRejected
//      - testCity_trimsBlankAndInvisibleEdges
//      - testCity_minimumCountsVisibleCharacters_maximumCountsAll
//      - testCity_countsCodePointsNotGraphemes
//      - testCityIssueMessage_emptyIsSilent_shortAndLongHaveCopy
//      - testNote_limitAndEmptyNormalization
//      - testCoarse_roundsToTwoDecimals
//      - testCoarsePair_bothOrNeither_andRanges
//      - testMakeDraft_validNormalizesAndInvalidIsNil
//   2. CoverageRequestServiceTests (URLProtocol-mocked)
//      - testSubmit_sendsReturnMinimal_notRepresentation
//      - testSubmit_bodyHasOnlyTheFourClientWritableColumns
//      - testSubmit_omitsNoteAndCoordinatesWhenAbsent
//      - testSubmit_coordinatesAreSentCoarse
//      - testSubmit_201WithEmptyBody_isSuccess
//      - testSubmit_rateLimit42501_perUserAndGlobal_mapToOneNeutralMessage
//      - testSubmit_otherPermission42501_isNotRateLimited
//      - testSubmit_check23514_mapsInvalidInput
//      - testSubmit_offline_mapsNetwork
//      - testSubmit_noSession_throwsNotSignedIn_andSendsNothing
//   3. SuggestNeighborhoodModelTests
//      - testSubmit_success_endsSent_andSendsCoarseViewedArea
//      - testSubmit_invalidForm_isNotSubmittable_andSendsNothing
//      - testSubmit_doubleTap_sendsOnce
//      - testSubmit_failure_showsMessage_andStaysEditable
//      - testSubmit_withoutSubmitter_showsUnavailableMessage
//   4. CoverageRequestFlagTests
//      - testCoverageRequestsFlag_defaultsFalse
//      - testSuggestAffordance_hidden_whenDisabled
//
//  [COMPILE-UNVERIFIED] Written with no Swift toolchain on this machine.
//

import XCTest
@testable import WePark

// MARK: - 1. Rules (pure)

final class CoverageRequestRulesTests: XCTestCase {

    func testCity_boundaries_twoVisibleToEighty() {
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable(""))
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable("A"))
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable("NY"))
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable(String(repeating: "a", count: 80)))
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable(String(repeating: "a", count: 81)))
    }

    func testCity_blankAndInvisibleOnly_isRejected() {
        let blanks = [
            "   ",
            "\t\t",
            "\u{00A0}\u{00A0}",     // NBSP
            "\u{200B}\u{200B}",     // zero-width space
            "\u{FEFF}\u{FEFF}",     // BOM
            "\u{3000}\u{3000}",     // ideographic space
            "\u{00AD}\u{00AD}",     // soft hyphen
            "\n\r\n",
        ]
        for value in blanks {
            XCTAssertFalse(CoverageRequestRules.isCityAcceptable(value), "should reject \(value.unicodeScalars.map { $0.value })")
        }
    }

    func testCity_trimsBlankAndInvisibleEdges() {
        XCTAssertEqual(CoverageRequestRules.normalizedCity("\u{00A0} Park Slope \u{200B}"), "Park Slope")
        XCTAssertEqual(CoverageRequestRules.normalizedCity("\n\tHoboken\n"), "Hoboken")
        // Inner blanks are kept.
        XCTAssertEqual(CoverageRequestRules.normalizedCity(" Jersey City "), "Jersey City")
    }

    func testCity_minimumCountsVisibleCharacters_maximumCountsAll() {
        // "A B": 3 characters, 2 visible -> acceptable (the SQL strips blanks everywhere for the minimum).
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable("A B"))
        // "A" + trailing ZWSP trims to "A": 1 visible -> rejected.
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable("A\u{200B}"))
        // 80 total characters INCLUDING inner spaces is the maximum; 81 is over even if mostly spaces.
        let eighty = "ab" + String(repeating: " ", count: 76) + "cd"
        XCTAssertEqual(CoverageRequestRules.characterCount(eighty), 80)
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable(eighty))
        let eightyOne = "ab" + String(repeating: " ", count: 77) + "cd"
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable(eightyOne))
    }

    func testCity_countsCodePointsNotGraphemes() {
        // Postgres char_length counts code points. A family emoji is 5 scalars (3 people + 2 ZWJ).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.count, 1, "one grapheme")
        XCTAssertEqual(CoverageRequestRules.characterCount(family), 5, "five code points")
        // 16 x 5 = 80 -> ok; 17 x 5 = 85 -> over the limit even though only 17 graphemes.
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable(String(repeating: family, count: 16)))
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable(String(repeating: family, count: 17)))
        // Plain emoji are one scalar each: 80 ok, 81 over.
        XCTAssertTrue(CoverageRequestRules.isCityAcceptable(String(repeating: "\u{1F600}", count: 80)))
        XCTAssertFalse(CoverageRequestRules.isCityAcceptable(String(repeating: "\u{1F600}", count: 81)))
    }

    func testCityIssueMessage_emptyIsSilent_shortAndLongHaveCopy() {
        XCTAssertNil(CoverageRequestRules.cityIssueMessage(""))
        XCTAssertNil(CoverageRequestRules.cityIssueMessage("   "))
        XCTAssertEqual(CoverageRequestRules.cityIssueMessage("A"), CoverageRequestRules.cityTooShortMessage)
        XCTAssertNil(CoverageRequestRules.cityIssueMessage("Brooklyn"))
        XCTAssertEqual(
            CoverageRequestRules.cityIssueMessage(String(repeating: "a", count: 81)),
            CoverageRequestRules.cityTooLongMessage
        )
    }

    func testNote_limitAndEmptyNormalization() {
        XCTAssertNil(CoverageRequestRules.noteIssueMessage(""))
        XCTAssertNil(CoverageRequestRules.noteIssueMessage(String(repeating: "n", count: 500)))
        XCTAssertEqual(
            CoverageRequestRules.noteIssueMessage(String(repeating: "n", count: 501)),
            CoverageRequestRules.noteTooLongMessage
        )
        // Trailing blanks past 500 are trimmed first (matches the server's order).
        XCTAssertNil(CoverageRequestRules.noteIssueMessage(String(repeating: "n", count: 500) + "   "))
        XCTAssertNil(CoverageRequestRules.normalizedNote(""))
        XCTAssertNil(CoverageRequestRules.normalizedNote("  \u{200B} \n"))
        XCTAssertEqual(CoverageRequestRules.normalizedNote("  Please add Park Slope \n"), "Please add Park Slope")
    }

    func testCoarse_roundsToTwoDecimals() {
        XCTAssertEqual(CoverageRequestRules.coarse(40.712784), 40.71, accuracy: 1e-9)
        XCTAssertEqual(CoverageRequestRules.coarse(-74.005941), -74.01, accuracy: 1e-9)
        XCTAssertEqual(CoverageRequestRules.coarse(40.7449), 40.74, accuracy: 1e-9)
    }

    func testCoarsePair_bothOrNeither_andRanges() {
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: nil, longitude: nil))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: 40.7, longitude: nil))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: nil, longitude: -74.0))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: 91, longitude: -74.0))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: 40.7, longitude: 181))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: .nan, longitude: -74.0))
        XCTAssertNil(CoverageRequestRules.coarsePair(latitude: 40.7, longitude: .infinity))
        let pair = CoverageRequestRules.coarsePair(latitude: 40.6782, longitude: -73.9442)
        XCTAssertEqual(pair?.latitude ?? 0, 40.68, accuracy: 1e-9)
        XCTAssertEqual(pair?.longitude ?? 0, -73.94, accuracy: 1e-9)
    }

    func testMakeDraft_validNormalizesAndInvalidIsNil() {
        let draft = CoverageRequestRules.makeDraft(
            city: "  Park Slope ",
            note: "  ",
            viewedLatitude: 40.6710,
            viewedLongitude: -73.9814
        )
        XCTAssertEqual(draft?.city, "Park Slope")
        XCTAssertNil(draft?.note)
        XCTAssertEqual(draft?.viewedLatitude ?? 0, 40.67, accuracy: 1e-9)
        XCTAssertEqual(draft?.viewedLongitude ?? 0, -73.98, accuracy: 1e-9)

        XCTAssertNil(CoverageRequestRules.makeDraft(city: "A", note: "", viewedLatitude: nil, viewedLongitude: nil))
        XCTAssertNil(CoverageRequestRules.makeDraft(
            city: "Brooklyn", note: String(repeating: "n", count: 501), viewedLatitude: nil, viewedLongitude: nil
        ))
    }
}

// MARK: - URLProtocol mock + fake session

private final class CovReqMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CovReqMockURLProtocol.capturedRequests.append(request)
        guard let handler = CovReqMockURLProtocol.requestHandler else {
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

private func covReqMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CovReqMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func covReqBodyObject(from request: URLRequest) -> [String: Any] {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            collected.append(contentsOf: buffer[0..<read])
        }
        data = collected
    }
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

private func covReqResponse(_ request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url ?? URL(string: "https://example.supabase.co")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
}

@MainActor
private final class CovReqFakeSession: WriteSessionProviding {
    var token: String?
    init(token: String? = "jwt-cov-token") { self.token = token }
    func validAccessToken() async -> String? { token }
}

@MainActor
private func covReqMakeService(token: String? = "jwt-cov-token") -> CoverageRequestService {
    CoverageRequestService(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        supabaseAnonKey: "anon-key-test",
        urlSession: covReqMockSession(),
        session: CovReqFakeSession(token: token)
    )
}

private let covReqDraft = CoverageRequestDraft(
    city: "Park Slope",
    note: "Please add us",
    viewedLatitude: 40.67,
    viewedLongitude: -73.98
)

// MARK: - 2. Service

@MainActor
final class CoverageRequestServiceTests: XCTestCase {

    private func assertSubmitThrows(
        _ expected: CoverageRequestError,
        draft: CoverageRequestDraft = covReqDraft,
        service: CoverageRequestService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await service.submit(draft)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CoverageRequestError {
            XCTAssertEqual(
                error.errorDescription, expected.errorDescription,
                "wrong error: \(error)", file: file, line: line
            )
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testSubmit_sendsReturnMinimal_notRepresentation() async throws {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        let service = covReqMakeService()

        try await service.submit(covReqDraft)

        let request = try XCTUnwrap(CovReqMockURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path.hasSuffix("/rest/v1/coverage_requests"), true)
        let prefer = request.value(forHTTPHeaderField: "Prefer")
        XCTAssertEqual(prefer, "return=minimal")
        XCTAssertFalse((prefer ?? "").contains("representation"),
                       "return=representation 42501s on every insert: clients have no SELECT on this table")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-cov-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSubmit_bodyHasOnlyTheFourClientWritableColumns() async throws {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        let service = covReqMakeService()

        try await service.submit(covReqDraft)

        let body = covReqBodyObject(from: try XCTUnwrap(CovReqMockURLProtocol.capturedRequests.first))
        let allowed: Set<String> = ["city", "note", "viewed_lat", "viewed_lng"]
        XCTAssertTrue(Set(body.keys).isSubset(of: allowed), "unexpected columns: \(body.keys)")
        XCTAssertNil(body["user_id"])
        XCTAssertNil(body["id"])
        XCTAssertNil(body["created_at"])
        XCTAssertEqual(body["city"] as? String, "Park Slope")
        XCTAssertEqual(body["note"] as? String, "Please add us")
    }

    func testSubmit_omitsNoteAndCoordinatesWhenAbsent() async throws {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        let service = covReqMakeService()

        try await service.submit(CoverageRequestDraft(city: "Hoboken", note: nil, viewedLatitude: nil, viewedLongitude: nil))

        let body = covReqBodyObject(from: try XCTUnwrap(CovReqMockURLProtocol.capturedRequests.first))
        XCTAssertEqual(Set(body.keys), ["city"])
    }

    func testSubmit_coordinatesAreSentCoarse() async throws {
        // Through the rules: raw 5-decimal viewed area -> 2-decimal draft -> wire.
        let draft = try XCTUnwrap(CoverageRequestRules.makeDraft(
            city: "Williamsburg", note: "", viewedLatitude: 40.712784, viewedLongitude: -73.961234
        ))
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        let service = covReqMakeService()

        try await service.submit(draft)

        let body = covReqBodyObject(from: try XCTUnwrap(CovReqMockURLProtocol.capturedRequests.first))
        XCTAssertEqual(body["viewed_lat"] as? Double ?? 0, 40.71, accuracy: 1e-9)
        XCTAssertEqual(body["viewed_lng"] as? Double ?? 0, -73.96, accuracy: 1e-9)
    }

    func testSubmit_201WithEmptyBody_isSuccess() async throws {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        let service = covReqMakeService()
        try await service.submit(covReqDraft)   // does not throw
    }

    func testSubmit_rateLimit42501_perUserAndGlobal_mapToOneNeutralMessage() async {
        let perUser = Data("{\"code\":\"42501\",\"details\":null,\"hint\":null,\"message\":\"rate limit exceeded: max 5 coverage request(s) per 1 hour(s)\"}".utf8)
        let global = Data("{\"code\":\"42501\",\"details\":null,\"hint\":null,\"message\":\"rate limit exceeded: coverage requests temporarily unavailable, try again later\"}".utf8)
        for body in [perUser, global] {
            CovReqMockURLProtocol.reset()
            CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 403), body) }
            await assertSubmitThrows(.rateLimited, service: covReqMakeService())
        }
        // Neutral, non-blaming copy.
        let copy = CoverageRequestError.rateLimited.errorDescription ?? ""
        XCTAssertEqual(copy, "We can't take suggestions right now \u{2014} please try again a little later.")
        let lowered = copy.lowercased()
        XCTAssertFalse(lowered.contains("too many"))
        XCTAssertFalse(lowered.contains("you've"))
        XCTAssertFalse(lowered.contains("already"))
    }

    func testSubmit_otherPermission42501_isNotRateLimited() async {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in
            (covReqResponse(request, status: 403),
             Data("{\"code\":\"42501\",\"message\":\"permission denied for table coverage_requests\"}".utf8))
        }
        await assertSubmitThrows(.serverRejected, service: covReqMakeService())
    }

    func testSubmit_check23514_mapsInvalidInput() async {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in
            (covReqResponse(request, status: 400),
             Data("{\"code\":\"23514\",\"message\":\"new row violates check constraint\"}".utf8))
        }
        await assertSubmitThrows(.invalidInput, service: covReqMakeService())
    }

    func testSubmit_offline_mapsNetwork() async {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await assertSubmitThrows(.network, service: covReqMakeService())
    }

    func testSubmit_noSession_throwsNotSignedIn_andSendsNothing() async {
        CovReqMockURLProtocol.reset()
        CovReqMockURLProtocol.requestHandler = { request in (covReqResponse(request, status: 201), Data()) }
        await assertSubmitThrows(.notSignedIn, service: covReqMakeService(token: nil))
        XCTAssertEqual(CovReqMockURLProtocol.capturedRequests.count, 0)
    }
}

// MARK: - 3. Model

@MainActor
private final class CovReqGatedSubmitter: CoverageRequestSubmitting {
    private(set) var drafts: [CoverageRequestDraft] = []
    var errorToThrow: Error?
    private var continuation: CheckedContinuation<Void, Never>?

    func submit(_ draft: CoverageRequestDraft) async throws {
        drafts.append(draft)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        if let errorToThrow {
            throw errorToThrow
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class SuggestNeighborhoodModelTests: XCTestCase {

    private func waitUntilSubmitting(_ model: SuggestNeighborhoodModel) async {
        var spins = 0
        while !model.isSubmitting && spins < 200 {
            await Task.yield()
            spins += 1
        }
    }

    func testSubmit_success_endsSent_andSendsCoarseViewedArea() async {
        let submitter = CovReqGatedSubmitter()
        let model = SuggestNeighborhoodModel(
            viewedLatitude: 40.712784, viewedLongitude: -74.005941, submitter: submitter
        )
        model.city = " Lower Manhattan "
        model.note = ""

        let run = Task { await model.submit() }
        await waitUntilSubmitting(model)
        submitter.release()
        await run.value

        XCTAssertTrue(model.isSent)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(submitter.drafts.count, 1)
        XCTAssertEqual(submitter.drafts.first?.city, "Lower Manhattan")
        XCTAssertNil(submitter.drafts.first?.note)
        XCTAssertEqual(submitter.drafts.first?.viewedLatitude ?? 0, 40.71, accuracy: 1e-9)
        XCTAssertEqual(submitter.drafts.first?.viewedLongitude ?? 0, -74.01, accuracy: 1e-9)
    }

    func testSubmit_invalidForm_isNotSubmittable_andSendsNothing() async {
        let submitter = CovReqGatedSubmitter()
        let model = SuggestNeighborhoodModel(viewedLatitude: nil, viewedLongitude: nil, submitter: submitter)

        XCTAssertFalse(model.canSubmit, "empty city")
        model.city = "A"
        XCTAssertFalse(model.canSubmit, "one visible character")
        XCTAssertEqual(model.cityHint, CoverageRequestRules.cityTooShortMessage)
        model.city = "Hoboken"
        model.note = String(repeating: "n", count: 501)
        XCTAssertFalse(model.canSubmit, "note over 500")
        XCTAssertEqual(model.noteHint, CoverageRequestRules.noteTooLongMessage)

        await model.submit()
        XCTAssertEqual(submitter.drafts.count, 0)
        XCTAssertTrue(model.isEditing)
    }

    func testSubmit_doubleTap_sendsOnce() async {
        let submitter = CovReqGatedSubmitter()
        let model = SuggestNeighborhoodModel(viewedLatitude: nil, viewedLongitude: nil, submitter: submitter)
        model.city = "Hoboken"

        let first = Task { await model.submit() }
        await waitUntilSubmitting(model)
        await model.submit()   // second tap while in flight
        XCTAssertEqual(submitter.drafts.count, 1)

        submitter.release()
        await first.value
        XCTAssertTrue(model.isSent)
        await model.submit()   // after success: also a no-op
        XCTAssertEqual(submitter.drafts.count, 1)
    }

    func testSubmit_failure_showsMessage_andStaysEditable() async {
        let submitter = CovReqGatedSubmitter()
        submitter.errorToThrow = CoverageRequestError.rateLimited
        let model = SuggestNeighborhoodModel(viewedLatitude: nil, viewedLongitude: nil, submitter: submitter)
        model.city = "Hoboken"

        let run = Task { await model.submit() }
        await waitUntilSubmitting(model)
        submitter.release()
        await run.value

        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.errorMessage, CoverageRequestError.rateLimited.errorDescription)
        XCTAssertEqual(model.city, "Hoboken", "the user's text is kept so they can retry")
    }

    func testSubmit_withoutSubmitter_showsUnavailableMessage() async {
        let model = SuggestNeighborhoodModel(viewedLatitude: nil, viewedLongitude: nil)
        model.city = "Hoboken"
        await model.submit()
        XCTAssertEqual(model.errorMessage, SuggestNeighborhoodModel.unavailableMessage)
        XCTAssertTrue(model.isEditing)
    }
}

// MARK: - 4. Flag guards

@MainActor
final class CoverageRequestFlagTests: XCTestCase {

    func testCoverageRequestsFlag_defaultsFalse() {
        XCTAssertFalse(
            AppConstants.coverageRequestsEnabled,
            "coverageRequestsEnabled must ship dark until Kevin confirms migration 11 is applied and verified."
        )
    }

    func testSuggestAffordance_hidden_whenDisabled() {
        XCTAssertFalse(AppConstants.coverageSuggestionVisible(enabled: false))
        XCTAssertTrue(AppConstants.coverageSuggestionVisible(enabled: true))
        XCTAssertEqual(
            AppConstants.coverageSuggestionVisible(),
            AppConstants.coverageSuggestionVisible(enabled: AppConstants.coverageRequestsEnabled),
            "the no-argument call must resolve identically to an explicit call with the real flag value"
        )
    }
}

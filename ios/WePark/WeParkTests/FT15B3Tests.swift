//
//  FT15B3Tests.swift
//  WeParkTests
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B3 (write path + evidence
//  upload). Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.4 (write order),
//  §5.3 (defaults/ceilings), §6.2 (rate limit), §7 (photo evidence & PII), §12.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Scope: Services/CommunityPinService.swift's insertBlockScopedReport(...) + its pure
//  default/ceiling helpers, and Services/PinEvidenceUploader.swift.
//
//  Test inventory (27 tests):
//
//  Pure default/ceiling/lifespan helpers (§5.3, no network):
//    1.  testDefaultReportWindow_filming_24h
//    2.  testDefaultReportWindow_construction_14d
//    3.  testHardCeiling_filming_7d
//    4.  testHardCeiling_construction_90d
//    5.  testLifespanForBlockScopedReport_filming_session
//    6.  testLifespanForBlockScopedReport_construction_durable
//    7.  testLifespanForBlockScopedReport_unsupportedType_nil
//    8.  testResolvedExpiresAt_requestedProvided_used
//    9.  testResolvedExpiresAt_nilRequested_appliesDefault
//   10.  testResolvedExpiresAt_requestedExceedsCeiling_clamped
//
//  insertBlockScopedReport — pre-network guards:
//   11.  testInsertBlockScopedReport_unsupportedPinType_throwsBeforeAnyRequest
//   12.  testInsertBlockScopedReport_emptySelections_throwsBeforeAnyRequest
//   13.  testInsertBlockScopedReport_notAuthenticated_throws
//   14.  testInsertBlockScopedReport_invalidWindow_throwsBeforeAnyRequest
//
//  insertBlockScopedReport — write order + batch shape (§3.4, AC-R4's write-path half):
//   15.  testInsertBlockScopedReport_uploadsEvidenceBeforeAnyPinsInsert
//   16.  testInsertBlockScopedReport_fourRowBatch_allShareOneReportGroupId   (Kevin's canonical case)
//   17.  testInsertBlockScopedReport_eachRowCarriesItsOwnSegmentId
//   18.  testInsertBlockScopedReport_evidenceUploadFails_noPinsRequestSent
//
//  insertBlockScopedReport — partial-failure / rollback decision:
//   19.  testInsertBlockScopedReport_midBatchFailure_rollsBackPriorRows
//   20.  testInsertBlockScopedReport_rateLimit403WithCode42501_throwsRateLimitExceeded
//   21.  testInsertBlockScopedReport_403WithoutMatchingCode_notTreatedAsRateLimit
//
//  insertBlockScopedReport — success path:
//   22.  testInsertBlockScopedReport_success_optimisticallyMergesIntoVisiblePins
//
//  PinEvidenceUploader:
//   23.  testPinEvidenceUploader_objectPathConvention_userIdSlashGroupIdSlashFilename
//   24.  testPinEvidenceUploader_insertsPinEvidenceRow_withReportGroupIdAndUploadedBy
//   25.  testPinEvidenceUploader_recordInsertFails_deletesStorageObject
//   26.  testPinEvidenceUploader_emptyPhotoData_throwsWithoutNetworkCall
//   27.  testPinEvidenceUploader_storageUploadFails_doesNotAttemptRecordInsert
//
//  No Calendar.current use in any new/modified production file.
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Shared fixtures

private let kB3ServiceURL = URL(string: "https://test.supabase.co")!
private let kB3AnonKey = "test-anon-key-not-real"
private let kB3User = UUID(uuidString: "B3000001-0000-0000-0000-000000000001")!
private let kB3Base: TimeInterval = 1_800_000_000
private let kB3Now: Date = Date(timeIntervalSince1970: kB3Base)

private func iso(_ date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    return fmt.string(from: date)
}

/// A valid Supabase Auth SDK `Session` JSON fixture — same shape as
/// Tier3AuthReactionsTests.swift's `authResponseJSON`, duplicated locally (file-private) so
/// this file has no cross-file dependency on that file's private helpers.
private func b3AuthResponseJSON(userId: UUID = kB3User) -> Data {
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

/// Builds a `return=representation`-shaped single-row JSON array for a POST /rest/v1/pins
/// response, matching `CommunityPin`'s `CodingKeys` exactly.
private func b3PinsInsertResponseJSON(
    id: UUID = UUID(),
    pinType: PinType,
    segmentId: String,
    reportGroupId: UUID,
    startsAt: Date,
    expiresAt: Date
) -> Data {
    let lifespan = CommunityPinService.lifespanForBlockScopedReport(pinType: pinType) ?? .session
    let json = """
    [{
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "crowd",
      "lifespan": "\(lifespan.rawValue)",
      "lat": 40.7217,
      "lng": -73.9866,
      "segment_id": "\(segmentId)",
      "zone_id": null,
      "author_id": "\(kB3User.uuidString)",
      "author_username": null,
      "created_at": "2026-08-12T12:00:00+00:00",
      "updated_at": "2026-08-12T12:00:00+00:00",
      "starts_at": "\(iso(startsAt))",
      "expires_at": "\(iso(expiresAt))",
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null,
      "report_group_id": "\(reportGroupId.uuidString)"
    }]
    """
    return Data(json.utf8)
}

/// PostgREST error body shape for a rate-limit rejection
/// (`errcode = 'insufficient_privilege'` → SQLSTATE `42501`).
private func b3RateLimitErrorJSON() -> Data {
    """
    {"code":"42501","details":null,"hint":null,"message":"rate limit exceeded: max 3 block-scoped report(s) per 24 hour(s)"}
    """.data(using: .utf8)!
}

private func b3EvidenceInsertResponseJSON(id: UUID = UUID()) -> Data {
    "[{\"id\":\"\(id.uuidString)\"}]".data(using: .utf8)!
}

// MARK: - FT15B3MockURLProtocol / FT15B3AuthMockURLProtocol

/// Dedicated mock URLProtocol for this file's write-path tests — separate from every other
/// test file's mock (PinMockURLProtocol / WriteMockURLProtocol / FT15B4MockURLProtocol) to
/// avoid shared static-state races when the full suite runs in parallel.
final class FT15B3MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FT15B3MockURLProtocol.requestHandler else {
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

/// Dedicated mock URLProtocol for this file's SupabaseAuthService sign-in calls.
final class FT15B3AuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FT15B3AuthMockURLProtocol.requestHandler else {
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

private func b3AuthMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FT15B3AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func b3WriteMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FT15B3MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Reads the request body (handles the httpBody → httpBodyStream conversion URLSession
/// performs once a request passes through a real session).
private func b3BodyData(from request: URLRequest) -> Data? {
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

/// Routes a captured request by shape: Storage upload (POST .../storage/v1/object/...),
/// pin_evidence insert (POST .../rest/v1/pin_evidence), pins insert (POST .../rest/v1/pins),
/// or pins rollback delete (DELETE .../rest/v1/pins?id=eq...). File-scope (not a method) so
/// mock-handler closures below can call it without capturing `self` (avoids the
/// explicit-self-in-escaping-closures ceremony entirely, and any accidental XCTestCase
/// retain risk that comes with it).
private enum B3RequestKind: Equatable {
    case storageUpload
    case evidenceInsert
    case pinsInsert
    case pinsDelete
    case other
}

private func b3Classify(_ request: URLRequest) -> B3RequestKind {
    let path = request.url?.path ?? ""
    let method = request.httpMethod ?? ""
    if path.contains("/storage/v1/object/pin-evidence/") && method == "POST" { return .storageUpload }
    if path.hasSuffix("/rest/v1/pin_evidence") && method == "POST" { return .evidenceInsert }
    if path.hasSuffix("/rest/v1/pins") && method == "POST" { return .pinsInsert }
    if path.hasSuffix("/rest/v1/pins") && method == "DELETE" { return .pinsDelete }
    return .other
}

// MARK: - Pure helper tests (§5.3)

final class FT15B3DefaultWindowTests: XCTestCase {

    func testDefaultReportWindow_filming_24h() {
        XCTAssertEqual(CommunityPinService.defaultReportWindow(for: .filming), 24 * 3600)
    }

    func testDefaultReportWindow_construction_14d() {
        XCTAssertEqual(CommunityPinService.defaultReportWindow(for: .construction), 14 * 24 * 3600)
    }

    func testHardCeiling_filming_7d() {
        XCTAssertEqual(CommunityPinService.hardCeiling(for: .filming), 7 * 24 * 3600)
    }

    func testHardCeiling_construction_90d() {
        XCTAssertEqual(CommunityPinService.hardCeiling(for: .construction), 90 * 24 * 3600)
    }

    func testLifespanForBlockScopedReport_filming_session() {
        XCTAssertEqual(CommunityPinService.lifespanForBlockScopedReport(pinType: .filming), .session)
    }

    func testLifespanForBlockScopedReport_construction_durable() {
        XCTAssertEqual(CommunityPinService.lifespanForBlockScopedReport(pinType: .construction), .durable)
    }

    func testLifespanForBlockScopedReport_unsupportedType_nil() {
        XCTAssertNil(CommunityPinService.lifespanForBlockScopedReport(pinType: .brokenMeter))
    }

    func testResolvedExpiresAt_requestedProvided_used() {
        let starts = kB3Now
        let requested = starts.addingTimeInterval(3 * 3600)
        let resolved = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: requested)
        XCTAssertEqual(resolved, requested)
    }

    func testResolvedExpiresAt_nilRequested_appliesDefault() {
        let starts = kB3Now
        let resolved = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: nil)
        XCTAssertEqual(resolved, starts.addingTimeInterval(24 * 3600))
    }

    func testResolvedExpiresAt_requestedExceedsCeiling_clamped() {
        let starts = kB3Now
        // filming ceiling is 7 days from starts_at — request 30 days out.
        let requested = starts.addingTimeInterval(30 * 24 * 3600)
        let resolved = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: requested)
        XCTAssertEqual(resolved, starts.addingTimeInterval(7 * 24 * 3600),
            "AC-S8's client-side counterpart: an obviously-out-of-range request must be clamped to the hard ceiling, not sent as-is")
    }
}

// MARK: - insertBlockScopedReport tests

@MainActor
final class FT15B3InsertBlockScopedReportTests: XCTestCase {

    /// Returns a (pinService, authService) pair with a valid session already established.
    private func makeAuthenticatedPair() async -> (CommunityPinService, SupabaseAuthService) {
        let mockSession = b3AuthMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kB3ServiceURL,
            supabaseAnonKey: kB3AnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )
        FT15B3AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kB3ServiceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             b3AuthResponseJSON())
        }
        await authService.ensureSession()

        let pinService = CommunityPinService(
            supabaseURL: kB3ServiceURL,
            supabaseAnonKey: kB3AnonKey,
            nowProvider: { kB3Now },
            urlSession: b3WriteMockSession(),
            authService: authService
        )
        return (pinService, authService)
    }

    private func canonicalSelections() -> [BlockScopedReportSelection] {
        // Kevin's canonical E 2nd St case: 2 blocks × both curbs = 4 blockfaces.
        [
            BlockScopedReportSelection(blockfaceKey: "E 2ND ST|1ST AVE|2ND AVE|N", lat: 40.7217, lng: -73.9866),
            BlockScopedReportSelection(blockfaceKey: "E 2ND ST|1ST AVE|2ND AVE|S", lat: 40.7216, lng: -73.9866),
            BlockScopedReportSelection(blockfaceKey: "E 2ND ST|2ND AVE|3RD AVE|N", lat: 40.7218, lng: -73.9878),
            BlockScopedReportSelection(blockfaceKey: "E 2ND ST|2ND AVE|3RD AVE|S", lat: 40.7217, lng: -73.9878),
        ]
    }

    // MARK: Pre-network guards

    func testInsertBlockScopedReport_unsupportedPinType_throwsBeforeAnyRequest() async {
        let (pinService, _) = await makeAuthenticatedPair()
        var requestFired = false
        FT15B3MockURLProtocol.requestHandler = { request in
            requestFired = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .brokenMeter,
                selections: canonicalSelections(),
                startsAt: kB3Now,
                expiresAt: nil,
                notes: nil,
                evidencePhoto: Data([0x1])
            )
            XCTFail("expected .unsupportedPinType to be thrown")
        } catch BlockScopedReportError.unsupportedPinType(let type) {
            XCTAssertEqual(type, .brokenMeter)
        } catch {
            XCTFail("expected .unsupportedPinType, got \(error)")
        }
        XCTAssertFalse(requestFired, "must not touch the network for an unsupported pin_type")
    }

    func testInsertBlockScopedReport_emptySelections_throwsBeforeAnyRequest() async {
        let (pinService, _) = await makeAuthenticatedPair()
        var requestFired = false
        FT15B3MockURLProtocol.requestHandler = { request in
            requestFired = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming,
                selections: [],
                startsAt: kB3Now,
                expiresAt: nil,
                notes: nil,
                evidencePhoto: Data([0x1])
            )
            XCTFail("expected .emptySelections to be thrown")
        } catch BlockScopedReportError.emptySelections {
            // Expected.
        } catch {
            XCTFail("expected .emptySelections, got \(error)")
        }
        XCTAssertFalse(requestFired, "must not touch the network for an empty selection set")
    }

    func testInsertBlockScopedReport_notAuthenticated_throws() async {
        let service = CommunityPinService(
            supabaseURL: kB3ServiceURL,
            supabaseAnonKey: kB3AnonKey,
            nowProvider: { kB3Now },
            urlSession: b3WriteMockSession(),
            authService: nil
        )

        do {
            _ = try await service.insertBlockScopedReport(
                pinType: .filming,
                selections: canonicalSelections(),
                startsAt: kB3Now,
                expiresAt: nil,
                notes: nil,
                evidencePhoto: Data([0x1])
            )
            XCTFail("expected .notAuthenticated to be thrown")
        } catch BlockScopedReportError.notAuthenticated {
            // Expected.
        } catch {
            XCTFail("expected .notAuthenticated, got \(error)")
        }
    }

    func testInsertBlockScopedReport_invalidWindow_throwsBeforeAnyRequest() async {
        let (pinService, _) = await makeAuthenticatedPair()
        var requestFired = false
        FT15B3MockURLProtocol.requestHandler = { request in
            requestFired = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming,
                selections: canonicalSelections(),
                startsAt: kB3Now,
                expiresAt: kB3Now,   // same instant as startsAt — zero-length window, must be rejected
                notes: nil,
                evidencePhoto: Data([0x1])
            )
            XCTFail("expected .invalidWindow to be thrown")
        } catch BlockScopedReportError.invalidWindow {
            // Expected.
        } catch {
            XCTFail("expected .invalidWindow, got \(error)")
        }
        XCTAssertFalse(requestFired, "must not touch the network for an inverted/zero-length window")
    }

    // MARK: Write order + batch shape (§3.4)

    func testInsertBlockScopedReport_uploadsEvidenceBeforeAnyPinsInsert() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var orderedKinds: [B3RequestKind] = []
        var capturedReportGroupId: UUID? = nil

        FT15B3MockURLProtocol.requestHandler = { request in
            let kind = b3Classify(request)
            orderedKinds.append(kind)
            switch kind {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                if let body = b3BodyData(from: request),
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let groupIdString = json["report_group_id"] as? String {
                    capturedReportGroupId = UUID(uuidString: groupIdString)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                let selection = self.canonicalSelections()[0]
                let starts = kB3Now
                let expires = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: nil)
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3PinsInsertResponseJSON(
                            pinType: .filming, segmentId: selection.blockfaceKey,
                            reportGroupId: capturedReportGroupId ?? UUID(),
                            startsAt: starts, expiresAt: expires
                        ))
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        _ = try await pinService.insertBlockScopedReport(
            pinType: .filming,
            selections: [canonicalSelections()[0]],
            startsAt: kB3Now,
            expiresAt: nil,
            notes: nil,
            evidencePhoto: Data([0x1, 0x2, 0x3])
        )

        XCTAssertEqual(orderedKinds, [.storageUpload, .evidenceInsert, .pinsInsert],
            "§3.4: evidence must be uploaded (Storage object, then pin_evidence row) strictly before any pins row insert")
    }

    func testInsertBlockScopedReport_fourRowBatch_allShareOneReportGroupId() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedReportGroupIds: [String] = []

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                guard let body = b3BodyData(from: request),
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let groupId = json["report_group_id"] as? String,
                      let segmentId = json["segment_id"] as? String else {
                    XCTFail("unreadable pins insert body")
                    return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
                }
                capturedReportGroupIds.append(groupId)
                let starts = kB3Now
                let expires = CommunityPinService.resolvedExpiresAt(pinType: .construction, startsAt: starts, requested: nil)
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3PinsInsertResponseJSON(
                            pinType: .construction, segmentId: segmentId,
                            reportGroupId: UUID(uuidString: groupId) ?? UUID(),
                            startsAt: starts, expiresAt: expires
                        ))
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let result = try await pinService.insertBlockScopedReport(
            pinType: .construction,
            selections: canonicalSelections(),
            startsAt: kB3Now,
            expiresAt: nil,
            notes: "Bowery construction, both curbs",
            evidencePhoto: Data([0x1, 0x2, 0x3])
        )

        XCTAssertEqual(result.insertedPins.count, 4, "AC-R4: exactly 4 pins rows for 2 blocks × both curbs")
        XCTAssertEqual(Set(capturedReportGroupIds).count, 1, "AC-R4: all 4 rows must share one report_group_id")
        XCTAssertEqual(capturedReportGroupIds.first, result.reportGroupId.uuidString)
    }

    func testInsertBlockScopedReport_eachRowCarriesItsOwnSegmentId() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedSegmentIds: [String] = []

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                let body = b3BodyData(from: request)!
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                let segmentId = json["segment_id"] as! String
                capturedSegmentIds.append(segmentId)
                let starts = kB3Now
                let expires = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: nil)
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3PinsInsertResponseJSON(pinType: .filming, segmentId: segmentId, reportGroupId: UUID(), startsAt: starts, expiresAt: expires))
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let selections = canonicalSelections()
        _ = try await pinService.insertBlockScopedReport(
            pinType: .filming, selections: selections, startsAt: kB3Now, expiresAt: nil,
            notes: nil, evidencePhoto: Data([0x1])
        )

        XCTAssertEqual(capturedSegmentIds, selections.map(\.blockfaceKey),
            "AC-R4: each row's segment_id must match its own selection's blockfaceKey, in order")
    }

    func testInsertBlockScopedReport_evidenceUploadFails_noPinsRequestSent() async {
        let (pinService, _) = await makeAuthenticatedPair()
        var pinsRequestFired = false

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            case .pinsInsert:
                pinsRequestFired = true
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming, selections: canonicalSelections(), startsAt: kB3Now, expiresAt: nil,
                notes: nil, evidencePhoto: Data([0x1])
            )
            XCTFail("expected .evidenceUploadFailed to be thrown")
        } catch BlockScopedReportError.evidenceUploadFailed {
            // Expected.
        } catch {
            XCTFail("expected .evidenceUploadFailed, got \(error)")
        }
        XCTAssertFalse(pinsRequestFired, "a failed evidence upload must never reach the pins insert step")
    }

    // MARK: Partial-failure / rollback decision

    func testInsertBlockScopedReport_midBatchFailure_rollsBackPriorRows() async {
        let (pinService, _) = await makeAuthenticatedPair()
        var pinsInsertCount = 0
        var deletedIds: [String] = []

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                pinsInsertCount += 1
                if pinsInsertCount <= 2 {
                    let body = b3BodyData(from: request)!
                    let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                    let segmentId = json["segment_id"] as! String
                    let starts = kB3Now
                    let expires = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: nil)
                    return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                            b3PinsInsertResponseJSON(pinType: .filming, segmentId: segmentId, reportGroupId: UUID(), startsAt: starts, expiresAt: expires))
                } else {
                    // 3rd row fails (e.g. a dropped connection mid-batch).
                    return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
                }
            case .pinsDelete:
                if let query = request.url?.query, query.hasPrefix("id=eq.") {
                    deletedIds.append(String(query.dropFirst("id=eq.".count)))
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming, selections: canonicalSelections(), startsAt: kB3Now, expiresAt: nil,
                notes: nil, evidencePhoto: Data([0x1])
            )
            XCTFail("expected the 3rd row's failure to propagate")
        } catch BlockScopedReportError.pinsInsertFailed {
            // Expected.
        } catch {
            XCTFail("expected .pinsInsertFailed, got \(error)")
        }

        XCTAssertEqual(pinsInsertCount, 3, "must stop attempting further rows after the failure (sequential, not fire-and-forget)")
        XCTAssertEqual(deletedIds.count, 2, "the 2 rows that succeeded before the failure must be rolled back")
    }

    func testInsertBlockScopedReport_rateLimit403WithCode42501_throwsRateLimitExceeded() async {
        let (pinService, _) = await makeAuthenticatedPair()

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                        b3RateLimitErrorJSON())
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming, selections: [canonicalSelections()[0]], startsAt: kB3Now, expiresAt: nil,
                notes: nil, evidencePhoto: Data([0x1])
            )
            XCTFail("expected .rateLimitExceeded to be thrown")
        } catch BlockScopedReportError.rateLimitExceeded {
            // Expected — and the error's localized description must be user-facing, not raw.
            let message = BlockScopedReportError.rateLimitExceeded.errorDescription ?? ""
            XCTAssertFalse(message.contains("42501"), "user-facing copy must not leak the raw PostgREST error code")
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("expected .rateLimitExceeded, got \(error)")
        }
    }

    func testInsertBlockScopedReport_403WithoutMatchingCode_notTreatedAsRateLimit() async {
        let (pinService, _) = await makeAuthenticatedPair()

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                // An unrelated 403 with a DIFFERENT code — must not be misread as the rate limit.
                let body = "{\"code\":\"42501x\",\"message\":\"unrelated\"}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: .filming, selections: [canonicalSelections()[0]], startsAt: kB3Now, expiresAt: nil,
                notes: nil, evidencePhoto: Data([0x1])
            )
            XCTFail("expected .pinsInsertFailed to be thrown")
        } catch BlockScopedReportError.pinsInsertFailed(let statusCode) {
            XCTAssertEqual(statusCode, 403)
        } catch {
            XCTFail("expected .pinsInsertFailed(statusCode: 403), got \(error)")
        }
    }

    // MARK: Success path

    func testInsertBlockScopedReport_success_optimisticallyMergesIntoVisiblePins() async throws {
        let (pinService, _) = await makeAuthenticatedPair()

        FT15B3MockURLProtocol.requestHandler = { request in
            switch b3Classify(request) {
            case .storageUpload:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case .evidenceInsert:
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            case .pinsInsert:
                let body = b3BodyData(from: request)!
                let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
                let segmentId = json["segment_id"] as! String
                let starts = kB3Now
                let expires = CommunityPinService.resolvedExpiresAt(pinType: .filming, startsAt: starts, requested: nil)
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3PinsInsertResponseJSON(pinType: .filming, segmentId: segmentId, reportGroupId: UUID(), startsAt: starts, expiresAt: expires))
            case .pinsDelete, .other:
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        XCTAssertEqual(pinService.visiblePins.count, 0)
        _ = try await pinService.insertBlockScopedReport(
            pinType: .filming, selections: [canonicalSelections()[0]], startsAt: kB3Now, expiresAt: nil,
            notes: nil, evidencePhoto: Data([0x1])
        )
        XCTAssertEqual(pinService.visiblePins.count, 1,
            "a successfully-inserted row should appear immediately, matching insertCrowdPin's Fix 1 pattern")
    }
}

// MARK: - PinEvidenceUploader tests

@MainActor
final class FT15B3PinEvidenceUploaderTests: XCTestCase {

    private func makeAuthenticatedService() async -> SupabaseAuthService {
        let mockSession = b3AuthMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kB3ServiceURL,
            supabaseAnonKey: kB3AnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )
        FT15B3AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kB3ServiceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             b3AuthResponseJSON())
        }
        await authService.ensureSession()
        return authService
    }

    func testPinEvidenceUploader_objectPathConvention_userIdSlashGroupIdSlashFilename() async throws {
        let authService = await makeAuthenticatedService()
        let reportGroupId = UUID()
        var capturedUploadPath: String? = nil

        FT15B3MockURLProtocol.requestHandler = { request in
            if request.url!.path.contains("/storage/v1/object/pin-evidence/") {
                capturedUploadPath = request.url!.path
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    b3EvidenceInsertResponseJSON())
        }

        let uploader = PinEvidenceUploader(
            supabaseURL: kB3ServiceURL, supabaseAnonKey: kB3AnonKey,
            urlSession: b3WriteMockSession(), authService: authService
        )
        let result = try await uploader.upload(photoData: Data([0x1, 0x2]), reportGroupId: reportGroupId)

        let expectedPrefix = "/storage/v1/object/pin-evidence/\(kB3User.uuidString)/\(reportGroupId.uuidString)/"
        XCTAssertTrue(capturedUploadPath?.hasPrefix(expectedPrefix) == true,
            "path convention {auth.uid()}/{report_group_id}/{filename} is fixed by the storage RLS policies; got \(capturedUploadPath ?? "nil")")
        XCTAssertTrue(result.storagePath.hasPrefix("\(kB3User.uuidString)/\(reportGroupId.uuidString)/"))
    }

    func testPinEvidenceUploader_insertsPinEvidenceRow_withReportGroupIdAndUploadedBy() async throws {
        let authService = await makeAuthenticatedService()
        let reportGroupId = UUID()
        var capturedBody: [String: Any]? = nil

        FT15B3MockURLProtocol.requestHandler = { request in
            if request.url!.path.hasSuffix("/rest/v1/pin_evidence") {
                if let body = b3BodyData(from: request) {
                    capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let uploader = PinEvidenceUploader(
            supabaseURL: kB3ServiceURL, supabaseAnonKey: kB3AnonKey,
            urlSession: b3WriteMockSession(), authService: authService
        )
        _ = try await uploader.upload(photoData: Data([0x1]), reportGroupId: reportGroupId)

        XCTAssertEqual(capturedBody?["report_group_id"] as? String, reportGroupId.uuidString)
        XCTAssertEqual(capturedBody?["uploaded_by"] as? String, kB3User.uuidString)
        XCTAssertNotNil(capturedBody?["storage_path"] as? String)
        XCTAssertNil(capturedBody?["pin_id"], "pin_id is intentionally omitted — always null today, per the schema's own comment")
    }

    func testPinEvidenceUploader_recordInsertFails_deletesStorageObject() async throws {
        let authService = await makeAuthenticatedService()
        var storageDeleteFired = false

        FT15B3MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.contains("/storage/v1/object/pin-evidence/") {
                if request.httpMethod == "DELETE" {
                    storageDeleteFired = true
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            if path.hasSuffix("/rest/v1/pin_evidence") {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let uploader = PinEvidenceUploader(
            supabaseURL: kB3ServiceURL, supabaseAnonKey: kB3AnonKey,
            urlSession: b3WriteMockSession(), authService: authService
        )

        do {
            _ = try await uploader.upload(photoData: Data([0x1]), reportGroupId: UUID())
            XCTFail("expected .recordInsertFailed to be thrown")
        } catch PinEvidenceUploadError.recordInsertFailed {
            // Expected.
        } catch {
            XCTFail("expected .recordInsertFailed, got \(error)")
        }
        XCTAssertTrue(storageDeleteFired,
            "a failed pin_evidence insert must ATTEMPT a best-effort delete of the now-orphaned " +
            "Storage object (whether that delete actually succeeds depends on RLS policy, which " +
            "phase 1's schema deliberately does not grant — see PinEvidenceUploader.upload's doc " +
            "comment; this test only verifies the client-side attempt is made)")
    }

    func testPinEvidenceUploader_emptyPhotoData_throwsWithoutNetworkCall() async {
        let authService = await makeAuthenticatedService()
        var requestFired = false
        FT15B3MockURLProtocol.requestHandler = { request in
            requestFired = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let uploader = PinEvidenceUploader(
            supabaseURL: kB3ServiceURL, supabaseAnonKey: kB3AnonKey,
            urlSession: b3WriteMockSession(), authService: authService
        )

        do {
            _ = try await uploader.upload(photoData: Data(), reportGroupId: UUID())
            XCTFail("expected .emptyPhotoData to be thrown")
        } catch PinEvidenceUploadError.emptyPhotoData {
            // Expected.
        } catch {
            XCTFail("expected .emptyPhotoData, got \(error)")
        }
        XCTAssertFalse(requestFired)
    }

    func testPinEvidenceUploader_storageUploadFails_doesNotAttemptRecordInsert() async {
        let authService = await makeAuthenticatedService()
        var evidenceInsertFired = false

        FT15B3MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            if path.contains("/storage/v1/object/pin-evidence/") {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            if path.hasSuffix("/rest/v1/pin_evidence") {
                evidenceInsertFired = true
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        b3EvidenceInsertResponseJSON())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let uploader = PinEvidenceUploader(
            supabaseURL: kB3ServiceURL, supabaseAnonKey: kB3AnonKey,
            urlSession: b3WriteMockSession(), authService: authService
        )

        do {
            _ = try await uploader.upload(photoData: Data([0x1]), reportGroupId: UUID())
            XCTFail("expected .storageUploadFailed to be thrown")
        } catch PinEvidenceUploadError.storageUploadFailed {
            // Expected.
        } catch {
            XCTFail("expected .storageUploadFailed, got \(error)")
        }
        XCTAssertFalse(evidenceInsertFired, "must never attempt the pin_evidence row insert if the Storage upload itself failed")
    }
}

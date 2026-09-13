//
//  CommunityZoneStampingTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2a (build 20 S6) — write-time zone stamping.
//  Community 2.0 S14 (`docs/community-2.0-s14-execution-spec.md`) update: `ResolveZoneIdTests`
//  (a fixed compiled-table lookup) is replaced by `ZoneGeometryTests`, which exercises the same
//  behavior against an explicit `zones: [Zone]` fixture list instead — the compiled
//  three-zone table this file used to test was retired this session.
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2;
//  docs/community-2.0-roadmap.md S6 row (PR #94 QA Finding #3 follow-up);
//  docs/community-2.0-s14-execution-spec.md §5/§6.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (14 tests):
//    ZoneGeometry.zoneId(forLat:lng:in:) / .box(for:in:) — pure functions:
//      1. testZoneId_singleMatch_returnsThatZone
//      2. testZoneId_containmentTieBreak_smallestBoxWins
//      3. testZoneId_noMatch_returnsNil
//      4. testZoneId_boundaryInclusiveEdge_included
//      5. testZoneId_emptyZonesArray_returnsNil
//      6. testBox_unknownId_returnsNil
//      7. testBox_knownId_returnsMatchingZone
//
//    CommunityPinService.resolveZoneId(explicit:lat:lng:zones:) — pure function:
//      8. testResolveZoneId_explicitWins_evenInsideABox
//      9. testResolveZoneId_nilExplicit_insideNolita_returnsNolita
//     10. testResolveZoneId_nilExplicit_outsideAllZones_returnsNil
//     11. testResolveZoneId_emptyZonesArray_neverCrashes_returnsNil
//
//    insertCrowdPin integration — request payload actually carries the resolved value:
//     12. testInsertCrowdPin_noExplicitZone_insideNolita_stampsZoneIdInPayload
//     13. testInsertCrowdPin_noExplicitZone_outsideAllZones_omitsZoneIdKey
//     14. testInsertCrowdPin_explicitZone_notOverriddenByBoxMatch
//     15. testInsertCrowdPin_noExplicitZone_insideNonOriginalZone_stampsZoneIdInPayload (S14:
//         proves the write path's quality improvement for a coordinate outside the original
//         3 boxes but inside a post-migration-shaped zone — AC in the S14 spec)
//

import XCTest
@testable import WePark

// MARK: - Shared zone fixtures

/// Verbatim copy of the values the retired compiled zone-bounds table used to hardcode —
/// kept here as a `[Zone]` fixture so every pre-existing lat/lng test case in this file (and
/// its siblings) keeps asserting the same zone-membership outcomes under the new fetched-list
/// shape.
let zoneStampingFixtureZones: [Zone] = [
    Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930),
    Zone(id: "soho",   name: "SoHo",   latMin: 40.7220, latMax: 40.7237, lngMin: -74.0050, lngMax: -73.9970),
    Zone(id: "les",    name: "LES",    latMin: 40.7145, latMax: 40.7230, lngMin: -73.9920, lngMax: -73.9800),
]

/// A post-migration-shaped zone that was never one of the original three boxes — used to prove
/// the write path now stamps `zone_id` for coordinates the old compiled table would have left
/// `null` (S14 spec's explicit "quality improvement, not just non-regression" AC).
let chelseaFixtureZone = Zone(id: "chelsea", name: "Chelsea", latMin: 40.7359, latMax: 40.7420, lngMin: -74.0090, lngMax: -73.9945)

// MARK: - ZoneGeometry (pure functions, no auth/network needed)

final class ZoneGeometryTests: XCTestCase {

    func testZoneId_singleMatch_returnsThatZone() {
        let result = ZoneGeometry.zoneId(forLat: 40.7230, lng: -73.9950, in: zoneStampingFixtureZones)
        XCTAssertEqual(result, "nolita")
    }

    /// Two overlapping boxes — the smaller-area one must win (spec §3.2's documented
    /// tie-break, load-bearing at 41 zones even though it never mattered at 3
    /// non-overlapping ones).
    func testZoneId_containmentTieBreak_smallestBoxWins() {
        let bigZone = Zone(id: "big", name: "Big", latMin: 40.70, latMax: 40.75, lngMin: -74.02, lngMax: -73.95)
        let smallZone = Zone(id: "small", name: "Small", latMin: 40.715, latMax: 40.725, lngMin: -73.99, lngMax: -73.97)
        let result = ZoneGeometry.zoneId(forLat: 40.72, lng: -73.98, in: [bigZone, smallZone])
        XCTAssertEqual(result, "small")
    }

    func testZoneId_noMatch_returnsNil() {
        let result = ZoneGeometry.zoneId(forLat: 40.70, lng: -74.02, in: zoneStampingFixtureZones)
        XCTAssertNil(result)
    }

    /// Boundary inclusivity — the applied migration's ranges are closed intervals
    /// (`gte`/`lte`-equivalent), matching `RealtimeMergeGate.isWithinRegion`'s own
    /// inclusive-bounds convention.
    func testZoneId_boundaryInclusiveEdge_included() {
        let result = ZoneGeometry.zoneId(forLat: 40.7217, lng: -73.9967, in: zoneStampingFixtureZones)
        XCTAssertEqual(result, "nolita")
    }

    /// First-launch-and-offline edge case (no cache, fetch failed): `zones == []` must never
    /// crash, only ever resolve `nil`.
    func testZoneId_emptyZonesArray_returnsNil() {
        XCTAssertNil(ZoneGeometry.zoneId(forLat: 40.7230, lng: -73.9950, in: []))
    }

    func testBox_unknownId_returnsNil() {
        XCTAssertNil(ZoneGeometry.box(for: "soho-les", in: zoneStampingFixtureZones))
    }

    func testBox_knownId_returnsMatchingZone() {
        let box = ZoneGeometry.box(for: "nolita", in: zoneStampingFixtureZones)
        XCTAssertEqual(box?.id, "nolita")
        XCTAssertEqual(box?.latMin, 40.7217)
    }
}

// MARK: - CommunityPinService.resolveZoneId (pure function, no auth/network needed)

final class ResolveZoneIdTests: XCTestCase {

    func testResolveZoneId_explicitWins_evenInsideABox() {
        // (40.7230, -73.9950) is inside the nolita box, but an explicit zoneId must never
        // be second-guessed by the box-match fallback.
        let result = CommunityPinService.resolveZoneId(explicit: "soho-les", lat: 40.7230, lng: -73.9950, zones: zoneStampingFixtureZones)
        XCTAssertEqual(result, "soho-les")
    }

    func testResolveZoneId_nilExplicit_insideNolita_returnsNolita() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7230, lng: -73.9950, zones: zoneStampingFixtureZones)
        XCTAssertEqual(result, "nolita")
    }

    /// A coordinate outside every known zone box must resolve to a genuinely-null zone_id,
    /// never a guessed/default zone.
    func testResolveZoneId_nilExplicit_outsideAllZones_returnsNil() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.70, lng: -74.02, zones: zoneStampingFixtureZones)
        XCTAssertNil(result)
    }

    /// Community 2.0 S14 AC: an empty `zones` array (first-launch-and-offline) must never
    /// crash `resolveZoneId` — it degrades to `nil`, same as any other unmatched coordinate.
    func testResolveZoneId_emptyZonesArray_neverCrashes_returnsNil() {
        let result = CommunityPinService.resolveZoneId(explicit: nil, lat: 40.7230, lng: -73.9950, zones: [])
        XCTAssertNil(result)
    }
}

// MARK: - insertCrowdPin integration — payload actually carries the resolved zone_id

/// QA pass 1 (PR #95) Finding #5 correction: this does NOT define its own file-scoped mock
/// URLProtocol. It reuses the existing `internal`-scoped `WriteMockURLProtocol` /
/// `AuthMockURLProtocol` classes already declared once in `Tier3AuthReactionsTests.swift` —
/// those classes' `nonisolated(unsafe) static var requestHandler` is genuinely SHARED,
/// mutable, global state across every file in this test target, not file-private. Only the
/// constants/functions below (auth-response fixture JSON, mock-session builders, the request-
/// body decoder) are file-private duplicates of that file's equivalents, so this file doesn't
/// need to import/expose them — the underlying `URLProtocol` classes and their static
/// `requestHandler` slot are shared, and tests across files that both assign
/// `WriteMockURLProtocol.requestHandler` are not safe to run concurrently against each other
/// (a pre-existing property of this test target's mock pattern, not something introduced or
/// fixed here — restructuring it is out of scope for this correction).
private let kZoneStampAuthURL = URL(string: "https://zone-stamp-test.supabase.co")!
private let kZoneStampAnonKey = "test-anon-key-zone-stamp"
private let kZoneStampUser = UUID(uuidString: "B0000001-0000-0000-0000-000000000001")!

private func zoneStampAuthResponseJSON() -> Data {
    let expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970
    return """
    {
      "access_token": "eyJ.test.token",
      "refresh_token": "refresh-test-token",
      "token_type": "bearer",
      "expires_in": 3600,
      "expires_at": \(expiresAt),
      "user": {
        "id": "\(kZoneStampUser.uuidString)",
        "aud": "authenticated",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z",
        "is_anonymous": true
      }
    }
    """.data(using: .utf8)!
}

private func zoneStampAuthMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zoneStampWriteMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WriteMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func zoneStampBodyData(from request: URLRequest) -> Data? {
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
final class InsertCrowdPinZoneStampingTests: XCTestCase {

    /// Community 2.0 S14: constructs `CommunityPinService` with an explicit
    /// `zoneStore: ZoneStore(preloadedZones:)` instead of relying on the old hardcoded table —
    /// `zones` defaults to the original three-box fixture so every pre-S14 lat/lng case keeps
    /// asserting the same outcome.
    private func makeAuthenticatedPair(zones: [Zone] = zoneStampingFixtureZones) async -> (CommunityPinService, SupabaseAuthService) {
        let mockSession = zoneStampAuthMockSession()
        let authService = SupabaseAuthService(
            supabaseURL: kZoneStampAuthURL,
            supabaseAnonKey: kZoneStampAnonKey,
            testStorage: InMemoryAuthStorage(),
            fetch: { try await mockSession.data(for: $0) }
        )
        AuthMockURLProtocol.requestHandler = { _ in
            (HTTPURLResponse(url: kZoneStampAuthURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             zoneStampAuthResponseJSON())
        }
        await authService.ensureSession()

        let pinService = CommunityPinService(
            supabaseURL: kZoneStampAuthURL,
            supabaseAnonKey: kZoneStampAnonKey,
            urlSession: zoneStampWriteMockSession(),
            authService: authService,
            zoneStore: ZoneStore(preloadedZones: zones)
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

    func testInsertCrowdPin_noExplicitZone_insideNolita_stampsZoneIdInPayload() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7230,
            lng: -73.9950,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "nolita",
            "A pin inside the nolita box with no explicit zoneId must be stamped 'nolita' at write time")
    }

    func testInsertCrowdPin_noExplicitZone_outsideAllZones_omitsZoneIdKey() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.70,
            lng: -74.02,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertNil(capturedBody?["zone_id"],
            "A coordinate outside every known zone box must leave zone_id genuinely absent, never a guessed value")
    }

    func testInsertCrowdPin_explicitZone_notOverriddenByBoxMatch() async throws {
        let (pinService, _) = await makeAuthenticatedPair()
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        // (40.7230, -73.9950) box-matches "nolita" — but an explicit zoneId must win.
        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7230,
            lng: -73.9950,
            segmentId: nil,
            zoneId: "soho-les",
            notes: nil
        )

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "soho-les",
            "An explicit caller-supplied zoneId must never be silently replaced by the box-match fallback")
    }

    /// Community 2.0 S14 AC: "a crowd report anywhere in Manhattan now gets a real `zone_id`
    /// instead of `null` outside the old 3 tiny boxes" — proves the write path's quality
    /// improvement, not just non-regression, using a fixture zone shaped like a post-migration
    /// row that was never one of the original three boxes.
    func testInsertCrowdPin_noExplicitZone_insideNonOriginalZone_stampsZoneIdInPayload() async throws {
        let (pinService, _) = await makeAuthenticatedPair(zones: zoneStampingFixtureZones + [chelseaFixtureZone])
        var capturedBody: [String: Any]? = nil

        WriteMockURLProtocol.requestHandler = { request in
            if let body = zoneStampBodyData(from: request) {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        // Inside the chelsea fixture box, outside all three original boxes.
        try await pinService.insertCrowdPin(
            type: .enforcementActive,
            meta: nil,
            lat: 40.7390,
            lng: -74.0000,
            segmentId: nil,
            zoneId: nil,
            notes: nil
        )

        XCTAssertEqual(capturedBody?["zone_id"] as? String, "chelsea",
            "A coordinate outside the original 3 boxes but inside a newly-fetched zone must now be stamped, not left null")
    }
}

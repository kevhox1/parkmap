//
//  FT15B4Tests.swift
//  WeParkTests
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B4 (third fetch channel +
//  consumption). Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §3.4, §9.2,
//  §9.3, §12 (AC-C1 through AC-C5, AC-T1's request-shape half).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Scope: Services/CommunityPinService.swift (Channel 3 request shape,
//  blockScopedRestriction(forBlockfaceKey:), mergeableTypes widening) and the new
//  CommunityPin.isUpcoming(now:) / CommunityPin.showsReactionsRow display extensions
//  (Views/PinMarkerAnnotation.swift). View-file-private formatting logic in
//  BlockDetailView/ParkedCarDetailView/PinDetailSheet (TemporaryRestrictionBanner's
//  windowText, PinDetailSheet's blockfaceSummary/windowSummary) is NOT unit tested here —
//  matches this codebase's existing convention that view-file-private display formatting
//  (RuleRow.compactDaysString, BlockDetailView.sideLabel, etc.) is verified via live-UI
//  smoke / preview, not XCTest. Request-count assertions that changed because of the new
//  channel (2 → 3 concurrent requests) were updated IN PLACE in
//  CommunityPinServiceTests.swift rather than duplicated here.
//
//  Test inventory (22 tests):
//
//  Channel 3 request shape (AC-C1, AC-C2, §3.4):
//    1.  testChannel3Request_sourceCrowd_pinTypeFilmingConstruction   (AC-C1)
//    2.  testChannel3Request_resolvedAtIsNull
//    3.  testChannel3Request_orExpiresAtNullOrFuture
//    4.  testChannel3Request_selectIncludesStartsAtAndReportGroupId  (needed for §9.2 matching)
//    5.  testChannel3Request_selectDoesNotIncludeHasEvidencePhoto    (no backing column yet)
//    6.  testChannel3Request_doesNotFilterOnLifespan                 (session AND durable both fetched)
//    7.  testChannel3Request_doesNotFilterOnStartsAt                 (AC-C2: upcoming pins still fetched)
//    8.  testChannel3Request_apikeyHeaderPresent
//
//  blockScopedRestriction(forBlockfaceKey:) lookup (§9.2, AC-C3's service-layer half):
//    9.  testBlockScopedRestriction_matchingFilmingPin_found
//   10.  testBlockScopedRestriction_matchingConstructionPin_found
//   11.  testBlockScopedRestriction_noMatch_returnsNil
//   12.  testBlockScopedRestriction_reportGroupIdNil_excluded          (open-data filming pin, no match)
//   13.  testBlockScopedRestriction_wrongPinType_excluded              (block-scoped special_event, hypothetical)
//
//  mergeableTypes widened to include .construction (AC-T1's merge-path half):
//   14.  testMergeRealtimeChange_construction_crowdPin_appended
//
//  CommunityPin.isUpcoming(now:) (AC-C2's badge-differentiation half):
//   15.  testIsUpcoming_futureStartsAt_true
//   16.  testIsUpcoming_pastStartsAt_false
//   17.  testIsUpcoming_nilStartsAt_false
//
//  CommunityPin.showsReactionsRow (AC-C4):
//   18.  testShowsReactionsRow_ephemeralCrowd_true             (pre-FT-15 regression check)
//   19.  testShowsReactionsRow_openDataSource_false             (source guard fires first)
//   20.  testShowsReactionsRow_sessionBlockScoped_true          (AC-C4 widen — filming)
//   21.  testShowsReactionsRow_durableBlockScoped_true          (AC-C4 widen — construction)
//   22.  testShowsReactionsRow_sessionCrowd_noReportGroupId_false (widen is report-group-scoped, not lifespan-blind)
//
//  No Calendar.current use in any new/modified production file (AC-D19 convention;
//  verified by manual review of Segment.swift / CommunityPin.swift / CommunityPinService.swift
//  / PinMarkerAnnotation.swift changes in this PR — all new logic uses plain Date comparison
//  or a DateFormatter with .easternTime, never Calendar.current).
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Shared fixtures

private let kB4ServiceURL = URL(string: "https://test.supabase.co")!
private let kB4AnonKey = "test-anon-key-not-real"
private let kB4Base: TimeInterval = 1_800_000_000   // matches CommunityPinServiceTests' kBase epoch
private let kB4Now: Date = Date(timeIntervalSince1970: kB4Base)
private let kB4Past: Date = Date(timeIntervalSince1970: kB4Base - 3600)
private let kB4Future: Date = Date(timeIntervalSince1970: kB4Base + 3600)

/// Same ISO8601-with-fractional-seconds-then-plain decoder strategy used across this
/// project's other CommunityPin test files, duplicated locally (file-scoped) so this file
/// is self-contained.
private func b4Decoder() -> JSONDecoder {
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

/// Builds a fixture `pins_with_author` JSON row. Every FT-15 field (`starts_at`,
/// `report_group_id`) is present-by-default here (unlike FT15ModelTests.swift's
/// `ft15PinFixture`, which defaults to key-absent to test pre-FT-15 payload shapes) —
/// this file is testing Stream B4's consumption logic, which assumes the fields exist.
private func b4PinFixture(
    id: UUID = UUID(),
    pinType: PinType,
    source: PinSource = .crowd,
    lifespan: PinLifespan = .session,
    segmentId: String? = "E 2ND ST|1ST AVE|3RD AVE|N",
    startsAt: Date? = nil,
    expiresAt: Date? = kB4Future,
    resolvedAt: Date? = nil,
    reportGroupId: UUID? = UUID(),
    authorId: UUID? = nil
) -> CommunityPin {
    func iso(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    let metaJSON: String
    switch pinType {
    case .filming:
        metaJSON = "null"
    case .construction:
        metaJSON = "null"
    case .specialEvent:
        metaJSON = #"{ "event_name": "Test Event", "event_type": "other" }"#
    default:
        metaJSON = "null"
    }

    let json = """
    {
      "id": "\(id.uuidString)",
      "pin_type": "\(pinType.rawValue)",
      "source": "\(source.rawValue)",
      "lifespan": "\(lifespan.rawValue)",
      "lat": 40.7217,
      "lng": -73.9866,
      "segment_id": \(segmentId.map { #""\#($0)""# } ?? "null"),
      "zone_id": null,
      "author_id": \(authorId.map { #""\#($0.uuidString)""# } ?? "null"),
      "author_username": null,
      "created_at": "2026-08-11T12:00:00+00:00",
      "updated_at": "2026-08-11T12:05:00+00:00",
      "starts_at": \(startsAt.map { #""\#(iso($0))""# } ?? "null"),
      "expires_at": \(expiresAt.map { #""\#(iso($0))""# } ?? "null"),
      "resolved_at": \(resolvedAt.map { #""\#(iso($0))""# } ?? "null"),
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": \(metaJSON),
      "notes": null,
      "report_group_id": \(reportGroupId.map { #""\#($0.uuidString)""# } ?? "null")
    }
    """

    return try! b4Decoder().decode(CommunityPin.self, from: Data(json.utf8))
}

// MARK: - Channel 3 request shape (AC-C1, AC-C2, §3.4)

@MainActor
final class FT15Channel3RequestTests: XCTestCase {

    /// Captures all requests fired by a single fetch (now 3: open_data, crowd ephemeral,
    /// crowd block-scoped) and returns the block-scoped one's URL, **percent-decoded**
    /// (`removingPercentEncoding`) so substring assertions against literal query syntax
    /// like `in.(filming,construction)` don't depend on whether `URLComponents` happens
    /// to percent-encode `(`, `)`, or `,` (all valid, unencoded, in an RFC 3986 query
    /// component — but not guaranteed by `URLComponents`'s implementation to be left
    /// unencoded, so tests don't assume it either way).
    private func fetchBlockScopedChannelURL() async throws -> String {
        var capturedURLs: [String] = []
        let expectation = expectation(description: "all three fetches fire")
        expectation.expectedFulfillmentCount = 3

        FT15B4MockURLProtocol.requestHandler = { request in
            capturedURLs.append(request.url?.absoluteString ?? "")
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FT15B4MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let service = CommunityPinService(
            supabaseURL: kB4ServiceURL,
            supabaseAnonKey: kB4AnonKey,
            nowProvider: { kB4Now },
            urlSession: session
        )

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        let decodedURLs = capturedURLs.map { $0.removingPercentEncoding ?? $0 }
        guard let url = decodedURLs.first(where: { $0.contains("pin_type=in.(filming,construction)") }) else {
            XCTFail("Expected a request with pin_type=in.(filming,construction). Got: \(decodedURLs)")
            return ""
        }
        return url
    }

    /// AC-C1: Channel 3 fetches source=crowd, pin_type in (filming, construction) — the
    /// exact combination neither Channel 1 (source=eq.open_data) nor Channel 2
    /// (lifespan=eq.ephemeral) would ever return (§3.4's "concrete gap" callout).
    func testChannel3Request_sourceCrowd_pinTypeFilmingConstruction() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertTrue(url.contains("source=eq.crowd"),
            "Channel 3 must filter source=eq.crowd. Got: \(url)")
        XCTAssertTrue(url.contains("pin_type=in.(filming,construction)"),
            "Channel 3 must filter pin_type=in.(filming,construction). Got: \(url)")
    }

    func testChannel3Request_resolvedAtIsNull() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertTrue(url.contains("resolved_at=is.null"),
            "Channel 3 must exclude resolved (3-dispute) pins. Got: \(url)")
    }

    func testChannel3Request_orExpiresAtNullOrFuture() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertTrue(url.contains("expires_at.is.null") && url.contains("expires_at.gt."),
            "Channel 3 must exclude expired pins server-side (expires_at is null OR > now). Got: \(url)")
    }

    /// §9.2's blockfaceKey matching depends on `report_group_id` being present in the
    /// response; §5.1/§9.2's window display depends on `starts_at`. Neither is selected
    /// by Channel 1 or Channel 2's select lists — Channel 3 is the first channel that
    /// needs them.
    func testChannel3Request_selectIncludesStartsAtAndReportGroupId() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertTrue(url.contains("starts_at"),
            "Channel 3's select must include starts_at. Got: \(url)")
        XCTAssertTrue(url.contains("report_group_id"),
            "Channel 3's select must include report_group_id. Got: \(url)")
    }

    /// `has_evidence_photo` has no backing column on the live schema yet
    /// (CommunityPin.swift's decode-only note) — requesting it would make PostgREST
    /// reject the whole query with a 400.
    func testChannel3Request_selectDoesNotIncludeHasEvidencePhoto() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertFalse(url.contains("has_evidence_photo"),
            "Channel 3 must NOT select has_evidence_photo — no backing column exists yet. Got: \(url)")
    }

    /// A block-scoped report is `lifespan = 'session'` or `'durable'` depending on the
    /// write path — Channel 3 must not filter on lifespan at all (unlike Channel 2, which
    /// hardcodes `lifespan=eq.ephemeral`).
    func testChannel3Request_doesNotFilterOnLifespan() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertFalse(url.contains("lifespan="),
            "Channel 3 must not filter on lifespan (session/durable both must be fetched). Got: \(url)")
    }

    /// AC-C2: a pin whose window hasn't started yet (`starts_at` in the future) must
    /// still be fetched — Channel 3 must not add a `starts_at=` filter query item.
    func testChannel3Request_doesNotFilterOnStartsAt() async throws {
        let url = try await fetchBlockScopedChannelURL()
        XCTAssertFalse(url.contains("starts_at="),
            "Channel 3 must not filter on starts_at — upcoming pins must still be fetched (AC-C2). Got: \(url)")
    }

    func testChannel3Request_apikeyHeaderPresent() async throws {
        var capturedRequests: [URLRequest] = []
        let expectation = expectation(description: "all three fetches fire")
        expectation.expectedFulfillmentCount = 3

        FT15B4MockURLProtocol.requestHandler = { request in
            capturedRequests.append(request)
            expectation.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    "[]".data(using: .utf8)!)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FT15B4MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = CommunityPinService(
            supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey,
            nowProvider: { kB4Now }, urlSession: session
        )
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        service.onRegionChanged(region)
        await fulfillment(of: [expectation], timeout: 2.5)

        let blockScopedRequest = capturedRequests.first {
            let decoded = $0.url?.absoluteString.removingPercentEncoding ?? ""
            return decoded.contains("pin_type=in.(filming,construction)")
        }
        XCTAssertEqual(blockScopedRequest?.value(forHTTPHeaderField: "apikey"), kB4AnonKey,
            "Channel 3's request must include the apikey header")
    }
}

// MARK: - blockScopedRestriction(forBlockfaceKey:) lookup (§9.2)

@MainActor
final class FT15BlockScopedRestrictionLookupTests: XCTestCase {

    private let kKey = "E 2ND ST|1ST AVE|3RD AVE|N"

    func testBlockScopedRestriction_matchingFilmingPin_found() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .filming, segmentId: kKey, reportGroupId: UUID())
        service.inject(fixtures: [pin])

        let found = service.blockScopedRestriction(forBlockfaceKey: kKey)
        XCTAssertEqual(found?.id, pin.id)
    }

    func testBlockScopedRestriction_matchingConstructionPin_found() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .construction, lifespan: .durable, segmentId: kKey, reportGroupId: UUID())
        service.inject(fixtures: [pin])

        let found = service.blockScopedRestriction(forBlockfaceKey: kKey)
        XCTAssertEqual(found?.id, pin.id)
    }

    func testBlockScopedRestriction_noMatch_returnsNil() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .filming, segmentId: "OTHER ST|A|B|S", reportGroupId: UUID())
        service.inject(fixtures: [pin])

        XCTAssertNil(service.blockScopedRestriction(forBlockfaceKey: kKey))
    }

    /// An open-data filming pin (Tier 1, `upsert_filming_pin` always writes segment_id =
    /// null and no report_group_id) must never match, even in the pathological case where
    /// its segmentId happens to collide with a blockfaceKey string.
    func testBlockScopedRestriction_reportGroupIdNil_excluded() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .filming, source: .openData, segmentId: kKey, reportGroupId: nil)
        service.inject(fixtures: [pin])

        XCTAssertNil(service.blockScopedRestriction(forBlockfaceKey: kKey),
            "A pin with reportGroupId == nil must never match, even with a colliding segmentId")
    }

    /// Only filming/construction pin types are eligible — a hypothetical block-scoped
    /// special_event-shaped row (not something the write path produces today, but the
    /// lookup's own type filter must not be pinType-blind) must not match.
    func testBlockScopedRestriction_wrongPinType_excluded() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .specialEvent, segmentId: kKey, reportGroupId: UUID())
        service.inject(fixtures: [pin])

        XCTAssertNil(service.blockScopedRestriction(forBlockfaceKey: kKey))
    }
}

// MARK: - mergeableTypes widened to include .construction

@MainActor
final class FT15ConstructionMergeTests: XCTestCase {

    /// construction crowd pin → appended to visiblePins via mergeRealtimeChange.
    /// Mirrors the existing enforcement_active/sweeper_passed crowd-merge tests in
    /// CommunityPinServiceTests.swift (Bug #1 precedent) — construction was missing from
    /// mergeableTypes before this PR (filming was already covered by the Tier 1 line).
    func testMergeRealtimeChange_construction_crowdPin_appended() {
        let service = CommunityPinService(supabaseURL: kB4ServiceURL, supabaseAnonKey: kB4AnonKey, nowProvider: { kB4Now })
        let pin = b4PinFixture(pinType: .construction, lifespan: .durable, expiresAt: nil, reportGroupId: UUID())

        service.mergeRealtimeChange(pin: pin)

        XCTAssertEqual(service.visiblePins.count, 1,
            "construction crowd pin must be appended via mergeRealtimeChange")
        XCTAssertEqual(service.visiblePins.first?.pinType, .construction)
    }
}

// MARK: - CommunityPin.isUpcoming(now:)

/// @MainActor required: `b4PinFixture` decodes `CommunityPin`, whose `Codable`
/// conformance is main-actor-isolated under this project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting — same reason
/// FT15ModelTests.swift's CommunityPin-decoding suites (CommunityPinStartsAtTests,
/// CommunityPinReportGroupIdTests, etc.) are all `@MainActor`, while
/// SegmentBlockfaceKeyTests (which only decodes `Segment`, not `CommunityPin`) is not.
@MainActor
final class FT15IsUpcomingTests: XCTestCase {

    func testIsUpcoming_futureStartsAt_true() {
        let pin = b4PinFixture(pinType: .filming, startsAt: kB4Future)
        XCTAssertTrue(pin.isUpcoming(now: kB4Now))
    }

    func testIsUpcoming_pastStartsAt_false() {
        let pin = b4PinFixture(pinType: .filming, startsAt: kB4Past)
        XCTAssertFalse(pin.isUpcoming(now: kB4Now))
    }

    /// startsAt == nil means "active immediately" (§5.1) — never "upcoming".
    func testIsUpcoming_nilStartsAt_false() {
        let pin = b4PinFixture(pinType: .filming, startsAt: nil)
        XCTAssertFalse(pin.isUpcoming(now: kB4Now))
    }
}

// MARK: - CommunityPin.showsReactionsRow (AC-C4)

/// @MainActor required — see `FT15IsUpcomingTests`'s doc comment above.
@MainActor
final class FT15ShowsReactionsRowTests: XCTestCase {

    /// Pre-FT-15 case, must not regress: ephemeral crowd pin (enforcement_active-shaped)
    /// still shows the reactions row.
    func testShowsReactionsRow_ephemeralCrowd_true() {
        let pin = b4PinFixture(pinType: .filming, source: .crowd, lifespan: .ephemeral, reportGroupId: nil)
        XCTAssertTrue(pin.showsReactionsRow)
    }

    /// Open-data pin (any lifespan) never shows the reactions row — source guard first.
    func testShowsReactionsRow_openDataSource_false() {
        let pin = b4PinFixture(pinType: .filming, source: .openData, lifespan: .ephemeral, reportGroupId: nil)
        XCTAssertFalse(pin.showsReactionsRow)
    }

    /// AC-C4: block-scoped session report (reportGroupId set) → widened gate shows the row.
    func testShowsReactionsRow_sessionBlockScoped_true() {
        let pin = b4PinFixture(pinType: .filming, source: .crowd, lifespan: .session, reportGroupId: UUID())
        XCTAssertTrue(pin.showsReactionsRow)
    }

    /// AC-C4: block-scoped durable report (construction, reportGroupId set) → widened
    /// gate shows the row.
    func testShowsReactionsRow_durableBlockScoped_true() {
        let pin = b4PinFixture(pinType: .construction, source: .crowd, lifespan: .durable, reportGroupId: UUID())
        XCTAssertTrue(pin.showsReactionsRow)
    }

    /// A crowd session/durable pin WITHOUT a reportGroupId (not from the block-scoped
    /// flow) must NOT show the row — the widen is scoped to block-scoped reports only,
    /// not to every session/durable crowd pin_type.
    func testShowsReactionsRow_sessionCrowd_noReportGroupId_false() {
        let pin = b4PinFixture(pinType: .filming, source: .crowd, lifespan: .session, reportGroupId: nil)
        XCTAssertFalse(pin.showsReactionsRow)
    }
}

// MARK: - FT15B4MockURLProtocol

/// Dedicated mock URLProtocol for this file's tests — separate from PinMockURLProtocol
/// (CommunityPinServiceTests.swift) to avoid shared static-state races when the full
/// suite runs in parallel (same pattern as AuthMockURLProtocol / WriteMockURLProtocol in
/// Tier3AuthReactionsTests.swift).
final class FT15B4MockURLProtocol: URLProtocol {

    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FT15B4MockURLProtocol.requestHandler else {
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

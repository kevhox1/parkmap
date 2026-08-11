//
//  FT15ModelTests.swift
//  WeParkTests
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B1 (iOS models).
//  Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §4.3, §5, §12 (AC-I1..AC-I4).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Scope: Models/Segment.swift (`blockfaceKey`) and Models/CommunityPin.swift
//  (`startsAt`, `reportGroupId`, `hasEvidencePhoto`, widened `FilmingMeta.permitId`).
//  Fixture-based only — no network, no Supabase client, no live DB.
//
//  Test inventory (16 tests):
//
//  Segment.blockfaceKey (no @MainActor — matches FT11SegmentDecodeTests precedent;
//  Segment's Codable conformance is declared directly on the struct, not via a
//  separate extension, and is not MainActor-isolated the way CommunityPin's is):
//    1.  testBlockfaceKey_directionAgnostic_fromToSwapped        (AC-I1)
//    2.  testBlockfaceKey_differsBySide                          (AC-I2)
//    3.  testBlockfaceKey_sameFieldsSameKey_stability
//    4.  testBlockfaceKey_differsByStreet
//    5.  testBlockfaceKey_differsByFromTo
//    6.  testBlockfaceKey_formatIsPipeDelimitedFourParts
//
//  CommunityPin.startsAt (@MainActor — decode requires it, same reason as
//  CommunityPinTests.swift's suites):
//    7.  testDecode_startsAt_present_isNonNil                    (AC-I3)
//    8.  testDecode_startsAt_null_isNil                          (AC-I3)
//    9.  testDecode_startsAt_keyAbsent_isNil                     (pre-FT-15 payload shape)
//
//  CommunityPin.reportGroupId:
//   10.  testDecode_reportGroupId_present_isNonNil
//   11.  testDecode_reportGroupId_keyAbsent_isNil
//
//  CommunityPin.hasEvidencePhoto:
//   12.  testDecode_hasEvidencePhoto_true
//   13.  testDecode_hasEvidencePhoto_keyAbsent_defaultsFalse
//
//  FilmingMeta.permitId widened to optional (crowd filming reports have no permit):
//   14.  testDecode_filming_crowdReport_metaNull_noPermitIdRequired
//   15.  testDecode_filming_openData_permitIdStillDecodes_regression
//
//  Round-trip:
//   16.  testEncodeDecode_roundTrip_startsAt_reportGroupId_hasEvidencePhoto
//
//  AC-I4 (no Calendar.current in any new/modified file): verified by manual review —
//  Segment.swift's new `blockfaceKey` and CommunityPin.swift's new fields do only
//  string comparison / Codable decodeIfPresent, no Calendar API of any kind.
//

import XCTest
@testable import WePark

// MARK: - Segment.blockfaceKey (AC-I1, AC-I2)

final class SegmentBlockfaceKeyTests: XCTestCase {

    /// Decodes a Segment from a JSON string. Force-unwrap is acceptable in tests —
    /// a decode failure here is a test-authoring error that should fail loudly.
    /// Mirrors FT11SegmentDecodeTests.decodeSegment(_:).
    private func decodeSegment(
        id: String = "SPRING_ST_WOOSTER_ST_GREENE_ST_N_1",
        street: String = "SPRING STREET",
        from: String = "WOOSTER STREET",
        to: String = "GREENE STREET",
        side: String = "N"
    ) -> Segment {
        let json = """
        {
          "id": "\(id)",
          "from": "\(from)",
          "to": "\(to)",
          "street": "\(street)",
          "side": "\(side)",
          "line": [[40.7248, -74.0032], [40.7249, -74.0021]],
          "rules": [],
          "dominantCategory": null
        }
        """
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    /// AC-I1: two fixture Segments with from/to swapped but otherwise identical
    /// produce the identical blockfaceKey.
    func testBlockfaceKey_directionAgnostic_fromToSwapped() {
        let forward = decodeSegment(from: "WOOSTER STREET", to: "GREENE STREET", side: "N")
        let reversed = decodeSegment(from: "GREENE STREET", to: "WOOSTER STREET", side: "N")

        XCTAssertEqual(
            forward.blockfaceKey, reversed.blockfaceKey,
            "AC-I1: blockfaceKey must be direction-agnostic — swapping from/to must not change the key"
        )
    }

    /// AC-I2: same street/from/to, different side (E vs W) produce different keys.
    func testBlockfaceKey_differsBySide() {
        let eastSide = decodeSegment(from: "WOOSTER STREET", to: "GREENE STREET", side: "E")
        let westSide = decodeSegment(from: "WOOSTER STREET", to: "GREENE STREET", side: "W")

        XCTAssertNotEqual(
            eastSide.blockfaceKey, westSide.blockfaceKey,
            "AC-I2: blockfaceKey must differ by side — E and W of the same block are different blockfaces"
        )
    }

    /// Sanity: decoding the identical JSON twice produces the identical key
    /// (blockfaceKey is a pure function of the decoded fields, no hidden state).
    func testBlockfaceKey_sameFieldsSameKey_stability() {
        let a = decodeSegment()
        let b = decodeSegment()
        XCTAssertEqual(a.blockfaceKey, b.blockfaceKey)
    }

    /// A different street produces a different key even with identical from/to/side.
    func testBlockfaceKey_differsByStreet() {
        let spring = decodeSegment(street: "SPRING STREET")
        let prince = decodeSegment(street: "PRINCE STREET")
        XCTAssertNotEqual(spring.blockfaceKey, prince.blockfaceKey)
    }

    /// A different from/to pair (not just swapped — genuinely different cross streets)
    /// produces a different key.
    func testBlockfaceKey_differsByFromTo() {
        let block1 = decodeSegment(from: "WOOSTER STREET", to: "GREENE STREET")
        let block2 = decodeSegment(from: "GREENE STREET", to: "MERCER STREET")
        XCTAssertNotEqual(block1.blockfaceKey, block2.blockfaceKey)
    }

    /// The key format is `STREET|LOW|HIGH|SIDE` — four pipe-delimited parts, cross
    /// streets alphabetically sorted (GREENE < WOOSTER).
    func testBlockfaceKey_formatIsPipeDelimitedFourParts() {
        let segment = decodeSegment(street: "SPRING STREET", from: "WOOSTER STREET", to: "GREENE STREET", side: "N")
        let parts = segment.blockfaceKey.components(separatedBy: "|")

        XCTAssertEqual(parts.count, 4, "blockfaceKey must have exactly 4 pipe-delimited parts")
        XCTAssertEqual(parts[0], "SPRING STREET")
        XCTAssertEqual(parts[1], "GREENE STREET", "Cross streets must be alphabetically sorted (lo)")
        XCTAssertEqual(parts[2], "WOOSTER STREET", "Cross streets must be alphabetically sorted (hi)")
        XCTAssertEqual(parts[3], "N")
    }
}

// MARK: - CommunityPin fixture helpers (FT-15 fields)

/// ISO 8601 date fixtures, hard-coded (no Calendar.current) — same convention as
/// CommunityPinTests.swift's top-level fixture constants (file-scoped `private`,
/// no collision with the identically-named constants in that file).
private let kFT15CreatedAt  = "2026-08-11T12:00:00+00:00"
private let kFT15UpdatedAt  = "2026-08-11T12:05:00+00:00"
private let kFT15StartsAt   = "2026-08-13T00:00:00+00:00"
private let kFT15ExpiresAt  = "2026-08-14T00:00:00+00:00"
private let kFT15AuthorId   = "C0000000-0000-0000-0000-000000000001"
private let kFT15PinId      = "D0000000-0000-0000-0000-000000000001"
private let kFT15ReportGroupId = "E0000000-0000-0000-0000-000000000001"

/// Same ISO8601-with-fractional-seconds-then-plain decoder strategy as
/// CommunityPinTests.swift's makeDecoder(), duplicated locally (file-scoped) to
/// keep this file self-contained per the additive/no-shared-mutation discipline.
private func ft15Decoder() -> JSONDecoder {
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

/// Builds a fixture `pins_with_author` JSON row with the FT-15 fields
/// (`starts_at`, `report_group_id`, `has_evidence_photo`) as optional overrides —
/// `nil` means "key omitted entirely" (distinct from JSON `null`), so callers can
/// exercise both the pre-FT-15 payload shape (key absent) and the FT-15 shape
/// (key present, possibly null).
private func ft15PinFixture(
    pinType: String,
    source: String = "crowd",
    lifespan: String = "session",
    startsAt: String? = nil,
    startsAtKeyPresent: Bool = false,
    expiresAt: String? = kFT15ExpiresAt,
    reportGroupId: String? = nil,
    reportGroupIdKeyPresent: Bool = false,
    hasEvidencePhoto: Bool? = nil,
    metaJSON: String = "null"
) -> String {
    var fields: [String] = [
        #""id": "\#(kFT15PinId)""#,
        #""pin_type": "\#(pinType)""#,
        #""source": "\#(source)""#,
        #""lifespan": "\#(lifespan)""#,
        #""lat": 40.7217"#,
        #""lng": -73.9866"#,
        #""segment_id": "E 2nd St|1st Ave|3rd Ave|N""#,
        #""zone_id": "zone_east_village""#,
        #""author_id": "\#(kFT15AuthorId)""#,
        #""author_username": "sign_reporter""#,
        #""created_at": "\#(kFT15CreatedAt)""#,
        #""updated_at": "\#(kFT15UpdatedAt)""#,
        expiresAt.map { #""expires_at": "\#($0)""# } ?? #""expires_at": null"#,
        #""resolved_at": null"#,
        #""confirm_count": 0"#,
        #""dispute_count": 0"#,
        #""meta": \#(metaJSON)"#,
        #""notes": null"#,
    ]

    if startsAtKeyPresent || startsAt != nil {
        fields.append(startsAt.map { #""starts_at": "\#($0)""# } ?? #""starts_at": null"#)
    }
    if reportGroupIdKeyPresent || reportGroupId != nil {
        fields.append(reportGroupId.map { #""report_group_id": "\#($0)""# } ?? #""report_group_id": null"#)
    }
    if let hasEvidencePhoto {
        fields.append(#""has_evidence_photo": \#(hasEvidencePhoto)"#)
    }

    return "{ " + fields.joined(separator: ", ") + " }"
}

// MARK: - CommunityPin.startsAt (AC-I3)

/// @MainActor required: CommunityPin's Codable conformance (declared in a separate
/// extension in Models/CommunityPin.swift) is main-actor-isolated under this
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting — same reason
/// CommunityPinTests.swift's decode suites are @MainActor.
@MainActor
final class CommunityPinStartsAtTests: XCTestCase {

    private let decoder = ft15Decoder()

    /// AC-I3: starts_at present in JSON decodes to a non-nil startsAt Date.
    func testDecode_startsAt_present_isNonNil() throws {
        let json = ft15PinFixture(
            pinType: "filming", lifespan: "session",
            startsAt: kFT15StartsAt, startsAtKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNotNil(pin.startsAt, "AC-I3: starts_at present must decode to a non-nil Date")
    }

    /// AC-I3: starts_at: null decodes to startsAt == nil without throwing.
    func testDecode_startsAt_null_isNil() throws {
        let json = ft15PinFixture(
            pinType: "filming", lifespan: "session",
            startsAt: nil, startsAtKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.startsAt, "AC-I3: starts_at: null must decode to nil (not crash)")
    }

    /// The `starts_at` key doesn't exist at all in any pre-FT-15 payload (every pin
    /// row inserted before this migration). startsAt must still decode to nil, not throw.
    func testDecode_startsAt_keyAbsent_isNil() throws {
        let json = ft15PinFixture(
            pinType: "enforcement_active", lifespan: "ephemeral",
            startsAtKeyPresent: false, metaJSON: #"{ "sub_tag": null }"#
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.startsAt, "Pre-FT-15 payload (key absent entirely) must decode startsAt as nil")
    }
}

// MARK: - CommunityPin.reportGroupId

@MainActor
final class CommunityPinReportGroupIdTests: XCTestCase {

    private let decoder = ft15Decoder()

    func testDecode_reportGroupId_present_isNonNil() throws {
        let json = ft15PinFixture(
            pinType: "filming", lifespan: "session",
            reportGroupId: kFT15ReportGroupId, reportGroupIdKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertEqual(pin.reportGroupId?.uuidString.lowercased(), kFT15ReportGroupId.lowercased())
    }

    func testDecode_reportGroupId_keyAbsent_isNil() throws {
        let json = ft15PinFixture(pinType: "sweeper_passed", lifespan: "ephemeral", metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.reportGroupId, "Pre-FT-15 payload must decode reportGroupId as nil")
    }
}

// MARK: - CommunityPin.hasEvidencePhoto

@MainActor
final class CommunityPinHasEvidencePhotoTests: XCTestCase {

    private let decoder = ft15Decoder()

    func testDecode_hasEvidencePhoto_true() throws {
        let json = ft15PinFixture(pinType: "construction", lifespan: "durable",
                                   expiresAt: nil, hasEvidencePhoto: true, metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertTrue(pin.hasEvidencePhoto)
    }

    /// The key doesn't exist in today's `pins_with_author` view at all (§7: no
    /// photo_url or evidence-boolean column is defined there yet) — must default to
    /// false rather than throw.
    func testDecode_hasEvidencePhoto_keyAbsent_defaultsFalse() throws {
        let json = ft15PinFixture(pinType: "filming", lifespan: "session", metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertFalse(pin.hasEvidencePhoto, "Absent has_evidence_photo key must default to false")
    }
}

// MARK: - FilmingMeta.permitId widened to optional

@MainActor
final class FilmingMetaCrowdReportTests: XCTestCase {

    private let decoder = ft15Decoder()

    /// A crowd-reported film shoot (Kevin's E 2nd St placard case, no permit at all)
    /// has meta: null — decodes fine, pin.meta is nil.
    func testDecode_filming_crowdReport_metaNull_noPermitIdRequired() throws {
        let json = ft15PinFixture(
            pinType: "filming", source: "crowd", lifespan: "session",
            startsAt: kFT15StartsAt, startsAtKeyPresent: true,
            reportGroupId: kFT15ReportGroupId, reportGroupIdKeyPresent: true,
            metaJSON: "null"
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .filming)
        XCTAssertEqual(pin.source, .crowd)
        XCTAssertNil(pin.meta, "Crowd filming report with meta: null must decode meta as nil")
        XCTAssertNotNil(pin.startsAt)
        XCTAssertNotNil(pin.reportGroupId)
    }

    /// Regression: the existing Tier 1 open-data filming path (permit_id present)
    /// must continue to decode permitId as a non-nil value after the optional widening.
    func testDecode_filming_openData_permitIdStillDecodes_regression() throws {
        let meta = #"{ "permit_id": "NYC-2026-001", "production_name": "North Six" }"#
        let json = ft15PinFixture(pinType: "filming", source: "open_data", lifespan: "session", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .filming(let m) = pin.meta else {
            XCTFail("Expected PinMeta.filming"); return
        }
        XCTAssertEqual(m.permitId, "NYC-2026-001",
            "Regression: existing open-data filming rows with permit_id must still decode it")
        XCTAssertEqual(m.productionName, "North Six")
    }
}

// MARK: - Round-trip

@MainActor
final class CommunityPinFT15RoundTripTests: XCTestCase {

    private let decoder = ft15Decoder()

    /// Encode → decode preserves startsAt, reportGroupId, and hasEvidencePhoto.
    func testEncodeDecode_roundTrip_startsAt_reportGroupId_hasEvidencePhoto() throws {
        let json = ft15PinFixture(
            pinType: "construction", source: "crowd", lifespan: "durable",
            startsAt: kFT15StartsAt, startsAtKeyPresent: true,
            expiresAt: nil,
            reportGroupId: kFT15ReportGroupId, reportGroupIdKeyPresent: true,
            hasEvidencePhoto: true,
            metaJSON: "null"
        )
        let original = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        let roundTripped = try decoder.decode(CommunityPin.self, from: encoded)

        XCTAssertEqual(roundTripped.startsAt, original.startsAt)
        XCTAssertEqual(roundTripped.reportGroupId, original.reportGroupId)
        XCTAssertEqual(roundTripped.hasEvidencePhoto, original.hasEvidencePhoto)
        XCTAssertTrue(roundTripped.hasEvidencePhoto)
    }
}

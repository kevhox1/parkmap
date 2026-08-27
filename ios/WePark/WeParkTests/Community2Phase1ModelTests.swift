//
//  Community2Phase1ModelTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 1 — model + service layer (build 20, session S3).
//  Spec: docs/community-2.0-reconciliation-spec.md §0 OQ-2, §2.1, §2.2, §2.10, §2.11, §3
//  Phase 1. Schema: supabase/03-community-2.0-schema.sql.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge, matching every other
//  Community 2.0 file's posture.
//
//  Scope: `Models/CommunityPin.swift` (`.openSpot`/`.leavingSoon` pin types + `OpenSpotMeta`/
//  `LeavingSoonMeta` + `positionFraction`/`leavingMinutes`/`claimedBy`),
//  `Services/CommunityPinService.swift` (`ephemeralTTLSeconds(for:leavingMinutes:)`'s new
//  values), `Services/Constants.swift` (`AppConstants.communityEnabled`). Fixture-based only —
//  no network, no Supabase client, no live DB. Follows the `FT15ModelTests.swift` precedent of
//  a dedicated per-feature test file rather than growing `CommunityPinTests.swift` further.
//
//  Test inventory (23 tests):
//
//  Decode — open_spot / leaving_soon pin types (4 tests):
//    1.  testDecode_openSpot_metaNull_decodesSuccessfully
//    2.  testDecode_openSpot_emptyMetaObject_decodesToOpenSpotMetaCase
//    3.  testDecode_leavingSoon_metaNull_decodesSuccessfully
//    4.  testDecode_leavingSoon_emptyMetaObject_decodesToLeavingSoonMetaCase
//
//  Decode — positionFraction (spec §2.2) (3 tests):
//    5.  testDecode_positionFraction_present_isNonNil
//    6.  testDecode_positionFraction_null_isNil
//    7.  testDecode_positionFraction_keyAbsent_isNil
//
//  Decode — leavingMinutes (spec §2.2) (3 tests):
//    8.  testDecode_leavingMinutes_present_isNonNil
//    9.  testDecode_leavingMinutes_null_isNil
//   10.  testDecode_leavingMinutes_keyAbsent_isNil
//
//  Decode — claimedBy (spec §2.2, §2.10) (3 tests):
//   11.  testDecode_claimedBy_present_isNonNil
//   12.  testDecode_claimedBy_null_isNil
//   13.  testDecode_claimedBy_keyAbsent_isNil
//
//  Encode — write-grant boundary (positionFraction/leavingMinutes ARE encoded, claimedBy is
//  NOT — spec §2.2-note) (3 tests):
//   14.  testEncode_positionFractionAndLeavingMinutes_roundTrip
//   15.  testEncode_claimedBy_neverWritesKey_evenWhenPresent
//   16.  testEncodeDecode_roundTrip_claimedBy_doesNotSurvive
//
//  TTL table — ephemeralTTLSeconds(for:leavingMinutes:), Community 2.0 OQ-2 values (5 tests):
//   17.  testEphemeralTTL_openSpot_is3Minutes
//   18.  testEphemeralTTL_leavingSoon_noStatedMinutes_defaultsTo13Minutes
//   19.  testEphemeralTTL_leavingSoon_stated5Minutes_is8Minutes
//   20.  testEphemeralTTL_leavingSoon_stated20Minutes_is23Minutes
//   21.  testEphemeralTTL_leavingSoon_stated10Minutes_is13Minutes
//
//  Dark-ship flag (2 tests):
//   22.  testCommunityEnabled_defaultsFalse
//   23.  testCommunityEnabled_isBoolConstant_notComputedPerCall
//
//  No Calendar.current use in this file or in the code paths it tests.
//  No hardcoded Mapbox tokens or Supabase keys.
//

import XCTest
@testable import WePark

// MARK: - Fixture helpers

private let kC2CreatedAt = "2026-08-27T09:00:00+00:00"
private let kC2UpdatedAt = "2026-08-27T09:05:00+00:00"
private let kC2ExpiresAt = "2026-08-27T09:03:00+00:00"
private let kC2AuthorId  = "F0000000-0000-0000-0000-000000000001"
private let kC2PinId     = "10000000-0000-0000-0000-000000000001"
private let kC2ClaimedBy = "20000000-0000-0000-0000-000000000001"

/// Same ISO8601-with-fractional-seconds-then-plain decoder strategy as
/// `CommunityPinTests.swift`'s `makeDecoder()` / `FT15ModelTests.swift`'s `ft15Decoder()`,
/// duplicated locally (file-scoped) per this repo's additive/no-shared-mutation convention.
private func c2Decoder() -> JSONDecoder {
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

/// Builds a fixture `pins_with_author` JSON row exercising the Community 2.0 Phase 1 columns
/// (`position_fraction`, `leaving_minutes`, `claimed_by`) as optional overrides — `nil` means
/// "key omitted entirely" (distinct from JSON `null`), matching `FT15ModelTests.ft15PinFixture`'s
/// own `...KeyPresent` convention exactly.
private func c2PinFixture(
    pinType: String,
    lifespan: String = "ephemeral",
    expiresAt: String? = kC2ExpiresAt,
    positionFraction: Double? = nil,
    positionFractionKeyPresent: Bool = false,
    leavingMinutes: Int? = nil,
    leavingMinutesKeyPresent: Bool = false,
    claimedBy: String? = nil,
    claimedByKeyPresent: Bool = false,
    metaJSON: String = "null"
) -> String {
    var fields: [String] = [
        #""id": "\#(kC2PinId)""#,
        #""pin_type": "\#(pinType)""#,
        #""source": "crowd""#,
        #""lifespan": "\#(lifespan)""#,
        #""lat": 40.7230"#,
        #""lng": -73.9950"#,
        #""segment_id": "Prince St|Mott St|Elizabeth St|N""#,
        #""zone_id": "soho""#,
        #""author_id": "\#(kC2AuthorId)""#,
        #""author_username": "crew_member""#,
        #""created_at": "\#(kC2CreatedAt)""#,
        #""updated_at": "\#(kC2UpdatedAt)""#,
        expiresAt.map { #""expires_at": "\#($0)""# } ?? #""expires_at": null"#,
        #""resolved_at": null"#,
        #""confirm_count": 0"#,
        #""dispute_count": 0"#,
        #""meta": \#(metaJSON)"#,
        #""notes": null"#,
    ]

    if positionFractionKeyPresent || positionFraction != nil {
        fields.append(positionFraction.map { #""position_fraction": \#($0)"# } ?? #""position_fraction": null"#)
    }
    if leavingMinutesKeyPresent || leavingMinutes != nil {
        fields.append(leavingMinutes.map { #""leaving_minutes": \#($0)"# } ?? #""leaving_minutes": null"#)
    }
    if claimedByKeyPresent || claimedBy != nil {
        fields.append(claimedBy.map { #""claimed_by": "\#($0)""# } ?? #""claimed_by": null"#)
    }

    return "{ " + fields.joined(separator: ", ") + " }"
}

// MARK: - Decode: open_spot / leaving_soon pin types

/// @MainActor required: `CommunityPin`'s `Codable` conformance is main-actor-isolated under
/// this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting — same reason
/// `CommunityPinTests.swift` / `FT15ModelTests.swift`'s decode suites are `@MainActor`.
@MainActor
final class CommunityPinOpenSpotLeavingSoonDecodeTests: XCTestCase {

    private let decoder = c2Decoder()

    func testDecode_openSpot_metaNull_decodesSuccessfully() throws {
        let json = c2PinFixture(pinType: "open_spot", metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .openSpot)
        XCTAssertEqual(pin.source, .crowd)
        XCTAssertEqual(pin.lifespan, .ephemeral)
        XCTAssertNil(pin.meta, "meta: null must decode to pin.meta == nil, not crash")
    }

    func testDecode_openSpot_emptyMetaObject_decodesToOpenSpotMetaCase() throws {
        let json = c2PinFixture(pinType: "open_spot", metaJSON: "{}")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .openSpot = pin.meta else {
            XCTFail("Expected PinMeta.openSpot for an empty meta object, got \(String(describing: pin.meta))")
            return
        }
    }

    func testDecode_leavingSoon_metaNull_decodesSuccessfully() throws {
        let json = c2PinFixture(pinType: "leaving_soon", metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .leavingSoon)
        XCTAssertEqual(pin.source, .crowd)
        XCTAssertEqual(pin.lifespan, .ephemeral)
        XCTAssertNil(pin.meta, "meta: null must decode to pin.meta == nil, not crash")
    }

    func testDecode_leavingSoon_emptyMetaObject_decodesToLeavingSoonMetaCase() throws {
        let json = c2PinFixture(pinType: "leaving_soon", metaJSON: "{}")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .leavingSoon = pin.meta else {
            XCTFail("Expected PinMeta.leavingSoon for an empty meta object, got \(String(describing: pin.meta))")
            return
        }
    }
}

// MARK: - Decode: positionFraction (spec §2.2)

@MainActor
final class CommunityPinPositionFractionTests: XCTestCase {

    private let decoder = c2Decoder()

    func testDecode_positionFraction_present_isNonNil() throws {
        let json = c2PinFixture(
            pinType: "open_spot",
            positionFraction: 0.35, positionFractionKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertEqual(pin.positionFraction, 0.35)
    }

    func testDecode_positionFraction_null_isNil() throws {
        let json = c2PinFixture(
            pinType: "open_spot",
            positionFraction: nil, positionFractionKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.positionFraction, "position_fraction: null must decode to nil, not crash")
    }

    func testDecode_positionFraction_keyAbsent_isNil() throws {
        let json = c2PinFixture(pinType: "enforcement_active", lifespan: "ephemeral")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.positionFraction,
            "Every pre-Community-2.0 pin type/row (key absent entirely) must decode positionFraction as nil")
    }
}

// MARK: - Decode: leavingMinutes (spec §2.2)

@MainActor
final class CommunityPinLeavingMinutesTests: XCTestCase {

    private let decoder = c2Decoder()

    func testDecode_leavingMinutes_present_isNonNil() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            leavingMinutes: 10, leavingMinutesKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertEqual(pin.leavingMinutes, 10)
    }

    func testDecode_leavingMinutes_null_isNil() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            leavingMinutes: nil, leavingMinutesKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.leavingMinutes, "leaving_minutes: null must decode to nil, not crash")
    }

    func testDecode_leavingMinutes_keyAbsent_isNil() throws {
        let json = c2PinFixture(pinType: "sweeper_passed", lifespan: "ephemeral")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.leavingMinutes,
            "Every pre-Community-2.0 pin type/row (key absent entirely) must decode leavingMinutes as nil")
    }
}

// MARK: - Decode: claimedBy (spec §2.2, §2.10)

@MainActor
final class CommunityPinClaimedByTests: XCTestCase {

    private let decoder = c2Decoder()

    func testDecode_claimedBy_present_isNonNil() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            claimedBy: kC2ClaimedBy, claimedByKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertEqual(pin.claimedBy?.uuidString.lowercased(), kC2ClaimedBy.lowercased())
    }

    func testDecode_claimedBy_null_isNil() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            claimedBy: nil, claimedByKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.claimedBy, "claimed_by: null (unclaimed) must decode to nil, not crash")
    }

    func testDecode_claimedBy_keyAbsent_isNil() throws {
        let json = c2PinFixture(pinType: "open_spot")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNil(pin.claimedBy,
            "Every pre-Community-2.0 pin type/row (key absent entirely) must decode claimedBy as nil")
    }
}

// MARK: - Encode: write-grant boundary (spec §2.2-note)

@MainActor
final class CommunityPinPhase1EncodeTests: XCTestCase {

    private let decoder = c2Decoder()

    /// `positionFraction`/`leavingMinutes` ARE granted client `INSERT` privilege (spec
    /// §2.2-note) — they must survive an encode→decode round trip, mirroring
    /// `startsAt`/`reportGroupId`'s existing precedent.
    func testEncode_positionFractionAndLeavingMinutes_roundTrip() throws {
        let json = c2PinFixture(
            pinType: "open_spot",
            positionFraction: 0.6, positionFractionKeyPresent: true,
            leavingMinutes: nil, leavingMinutesKeyPresent: false
        )
        let original = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        let roundTripped = try decoder.decode(CommunityPin.self, from: encoded)

        XCTAssertEqual(roundTripped.positionFraction, original.positionFraction)
        XCTAssertEqual(roundTripped.positionFraction, 0.6)
    }

    /// QA precedent mirrored from `hasEvidencePhoto`'s dedicated test
    /// (`FT15ModelTests.testEncode_hasEvidencePhoto_neverWritesKey_evenWhenTrue`):
    /// `claimed_by` must NEVER appear in `encode(to:)`'s output, even when the decoded value is
    /// non-nil — the column is absent from the anon/authenticated INSERT grant list (spec
    /// §2.2-note), so a future `Encodable`-based write path must never send this key.
    func testEncode_claimedBy_neverWritesKey_evenWhenPresent() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            claimedBy: kC2ClaimedBy, claimedByKeyPresent: true
        )
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNotNil(pin.claimedBy, "Precondition: decoded value must be non-nil for this test to be meaningful")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(pin)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        XCTAssertNotNil(object)
        XCTAssertNil(object?["claimed_by"],
            "encode(to:) must never write claimed_by — the column is absent from the anon/" +
            "authenticated INSERT grant list (spec §2.2-note); only claim_pin's SECURITY " +
            "DEFINER context can ever set it")
    }

    /// Round-trip counterpart to the above: since `encode(to:)` never writes the key, a decoded
    /// `claimedBy` does NOT survive an encode→decode cycle — it always comes back `nil` on the
    /// far side. Mirrors `CommunityPinFT15RoundTripTests`'s own `hasEvidencePhoto` assertion.
    func testEncodeDecode_roundTrip_claimedBy_doesNotSurvive() throws {
        let json = c2PinFixture(
            pinType: "leaving_soon",
            claimedBy: kC2ClaimedBy, claimedByKeyPresent: true
        )
        let original = try decoder.decode(CommunityPin.self, from: Data(json.utf8))
        XCTAssertNotNil(original.claimedBy, "Precondition: original must have decoded non-nil")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        let roundTripped = try decoder.decode(CommunityPin.self, from: encoded)

        XCTAssertNil(roundTripped.claimedBy,
            "claimedBy is decode-only — it must NOT survive an encode→decode round-trip; the " +
            "re-decoded value comes back nil because encode(to:) never writes the key")
    }
}

// MARK: - TTL table: ephemeralTTLSeconds(for:leavingMinutes:) (Community 2.0 OQ-2)

/// Verifies the two net-new TTL branches added to `CommunityPinService.ephemeralTTLSeconds`.
/// `enforcement_active`/`sweeper_passed`/`broken_meter`'s values are covered by
/// `Tier3PinFeedbackTests.FT1MobilePinTTLTests` (updated in place this same session for the
/// OQ-2 reversal) — not duplicated here.
final class Community2Phase1TTLTests: XCTestCase {

    func testEphemeralTTL_openSpot_is3Minutes() {
        XCTAssertEqual(CommunityPinService.ephemeralTTLSeconds(for: .openSpot), 3 * 60,
                       "open_spot pins expire after 3 minutes (spec §6 appendix, net-new)")
    }

    /// Mirrors the server's own `derive_pin_expiry()` trigger default
    /// (`coalesce(new.leaving_minutes, 10) + 3` — `supabase/03-community-2.0-schema.sql` §2.11):
    /// when the caller doesn't know the pin's stated countdown, the client-side TTL table falls
    /// back to the same 10-minute assumption, so display/decay math stays consistent with the
    /// server-authoritative expiry even when `leavingMinutes` isn't threaded through.
    func testEphemeralTTL_leavingSoon_noStatedMinutes_defaultsTo13Minutes() {
        XCTAssertEqual(CommunityPinService.ephemeralTTLSeconds(for: .leavingSoon), 13 * 60,
                       "leaving_soon with no known leavingMinutes defaults to 10+3=13 minutes, " +
                       "matching derive_pin_expiry()'s own coalesce(..., 10) default")
    }

    func testEphemeralTTL_leavingSoon_stated5Minutes_is8Minutes() {
        XCTAssertEqual(
            CommunityPinService.ephemeralTTLSeconds(for: .leavingSoon, leavingMinutes: 5), 8 * 60,
            "leaving_soon TTL = stated minutes + 3 (spec §6 appendix)"
        )
    }

    func testEphemeralTTL_leavingSoon_stated20Minutes_is23Minutes() {
        XCTAssertEqual(
            CommunityPinService.ephemeralTTLSeconds(for: .leavingSoon, leavingMinutes: 20), 23 * 60,
            "leaving_soon TTL = stated minutes + 3 (spec §6 appendix)"
        )
    }

    func testEphemeralTTL_leavingSoon_stated10Minutes_is13Minutes() {
        XCTAssertEqual(
            CommunityPinService.ephemeralTTLSeconds(for: .leavingSoon, leavingMinutes: 10), 13 * 60,
            "leaving_soon TTL = stated minutes + 3 (spec §6 appendix); also confirms the " +
            "explicit-10 path matches the no-argument default path above"
        )
    }
}

// MARK: - Dark-ship flag

/// `AppConstants.communityEnabled` (`Services/Constants.swift`) — the flag the entire
/// Community 2.0 layer hangs off (spec: `docs/community-2.0-roadmap.md` "Drive-test gate
/// applies to the flag-flip, not the merge"). No `@MainActor` needed: mirrors
/// `MoneyMathConstantsTests`/`ParkingGuidePromptGateTests`'s existing precedent
/// (`FT12Tests.swift`) of reading plain `AppConstants`/similar enum static members from a
/// non-actor-isolated `XCTestCase` without issue under this project's default-MainActor-
/// isolation build setting.
final class CommunityEnabledFlagTests: XCTestCase {

    func testCommunityEnabled_defaultsFalse() {
        XCTAssertFalse(AppConstants.communityEnabled,
            "Community 2.0 must ship dark (false) until Kevin flips it post-drive-test")
    }

    /// A `static let` (not `static var`/computed) — guards against a future refactor
    /// accidentally turning this into per-call-site logic that could drift from a single
    /// source of truth.
    func testCommunityEnabled_isBoolConstant_notComputedPerCall() {
        let first = AppConstants.communityEnabled
        let second = AppConstants.communityEnabled
        XCTAssertEqual(first, second)
    }
}

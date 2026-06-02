//
//  CommunityPinTests.swift
//  WeParkTests
//
//  Community 1.0 — iOS model layer unit tests.
//  Spec: docs/typed-pin-schema-spec.md §13 (AC-I1 through AC-I7).
//
//  Strategy:
//   - Pure JSON fixture decode — no network, no Supabase client, no live DB.
//   - All 10 pin types covered (AC-I1).
//   - enforcement_active sub_tag null (AC-I2) and "cleaning_truck" (AC-I3).
//   - expiresAt = null → nil (AC-I4).
//   - resolvedAt set → non-nil Date (AC-I5).
//   - No Calendar.current in this file or in the models it tests (AC-I6).
//   - PinType.rawValue round-trip (AC-I7).
//   - Malformed / unknown-type graceful-fallback (gracefulDecode returns nil).
//
//  Test inventory (30 tests):
//
//  Fixture decode — one per pin_type (10 tests):
//    1.  testDecode_filming
//    2.  testDecode_aspSuspendedToday
//    3.  testDecode_specialEvent
//    4.  testDecode_construction
//    5.  testDecode_signCorrection
//    6.  testDecode_blockNote
//    7.  testDecode_enforcementActive_subTagNull          (AC-I2)
//    8.  testDecode_sweeperPassed
//    9.  testDecode_brokenMeter
//   10.  testDecode_parkedCar
//
//  enforcement_active sub_tag variants (2 tests; covers AC-I2 + AC-I3):
//   11.  testDecode_enforcementActive_subTagNullExplicit   (AC-I2)
//   12.  testDecode_enforcementActive_subTagCleaningTruck  (AC-I3)
//
//  expiresAt / resolvedAt (2 tests):
//   13.  testDecode_expiresAt_null_isNil                   (AC-I4)
//   14.  testDecode_resolvedAt_set_isNonNil                (AC-I5)
//
//  PinType rawValue round-trip — all 10 values (10 tests, AC-I7):
//   15.  testRawValue_filming
//   16.  testRawValue_aspSuspendedToday
//   17.  testRawValue_specialEvent
//   18.  testRawValue_construction
//   19.  testRawValue_signCorrection
//   20.  testRawValue_blockNote
//   21.  testRawValue_enforcementActive
//   22.  testRawValue_sweeperPassed
//   23.  testRawValue_brokenMeter
//   24.  testRawValue_parkedCar
//
//  Graceful fallback (2 tests):
//   25.  testDecode_unknownPinType_throwsDecodingError
//   26.  testGracefulDecode_unknownPinType_returnsNil
//
//  Meta null handling (2 tests):
//   27.  testDecode_metaNull_isNilMeta
//   28.  testDecode_construction_allMetaFieldsOptional
//
//  Source / Lifespan enums (2 tests):
//   29.  testRawValue_source_allCases
//   30.  testRawValue_lifespan_allCases
//
//  Baseline: 243/0. After Community 1.0 model layer: 243 + 37 = 280/0 (total).
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
@testable import WePark

// MARK: - Fixture helpers

/// ISO 8601 dates used across fixtures. Hard-coded strings (no Calendar.current).
private let kCreatedAt  = "2026-06-01T10:00:00+00:00"
private let kUpdatedAt  = "2026-06-01T10:05:00+00:00"
private let kExpiresAt  = "2026-06-01T11:00:00+00:00"
private let kResolvedAt = "2026-06-01T14:00:00+00:00"
private let kAuthorId   = "A0000000-0000-0000-0000-000000000001"
private let kPinId      = "B0000000-0000-0000-0000-000000000001"

/// Returns a `JSONDecoder` configured the same way a real network layer would use:
/// ISO 8601 dates with fractional seconds. This matches the Supabase PostgREST
/// timestamp format (`timestamptz` columns come back as ISO 8601 strings).
private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        // Try ISO8601 with fractional seconds first, then without.
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

/// Wraps per-type meta JSON into a full `CommunityPin` fixture.
private func pinFixture(
    pinType: String,
    source: String = "crowd",
    lifespan: String = "session",
    expiresAt: String? = kExpiresAt,
    resolvedAt: String? = nil,
    metaJSON: String = "null"
) -> String {
    let expiresValue  = expiresAt.map  { #""\#($0)""# } ?? "null"
    let resolvedValue = resolvedAt.map { #""\#($0)""# } ?? "null"
    return """
    {
      "id": "\(kPinId)",
      "pin_type": "\(pinType)",
      "source": "\(source)",
      "lifespan": "\(lifespan)",
      "lat": 40.7505,
      "lng": -73.9965,
      "segment_id": "7th Ave|W 32nd St|W 33rd St",
      "zone_id": "zone_soho_les",
      "author_id": "\(kAuthorId)",
      "author_username": "parkwatcher",
      "created_at": "\(kCreatedAt)",
      "updated_at": "\(kUpdatedAt)",
      "expires_at": \(expiresValue),
      "resolved_at": \(resolvedValue),
      "confirm_count": 3,
      "dispute_count": 1,
      "meta": \(metaJSON),
      "notes": "Test note"
    }
    """
}

// MARK: - CommunityPinDecodeTests

/// @MainActor required: the project uses -default-isolation MainActor, so CommunityPin's
/// Codable conformance is main actor-isolated. Tests that call JSONDecoder.decode(_:from:)
/// with CommunityPin must run on the main actor to satisfy the isolation requirement.
@MainActor
final class CommunityPinDecodeTests: XCTestCase {

    private let decoder = makeDecoder()

    // MARK: - 1. filming

    /// AC-I1: filming pin decodes without error; meta fields are present.
    func testDecode_filming() throws {
        let meta = #"{ "permit_id": "NYC-2026-001", "production_name": "Test Show", "film_office_url": "https://example.com" }"#
        let json = pinFixture(pinType: "filming", source: "open_data", lifespan: "session", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .filming)
        XCTAssertEqual(pin.source, .openData)
        XCTAssertEqual(pin.lifespan, .session)

        guard case .filming(let m) = pin.meta else {
            XCTFail("Expected PinMeta.filming, got \(String(describing: pin.meta))")
            return
        }
        XCTAssertEqual(m.permitId, "NYC-2026-001")
        XCTAssertEqual(m.productionName, "Test Show")
        XCTAssertEqual(m.filmOfficeUrl, "https://example.com")
        XCTAssertEqual(pin.confirmCount, 3)
        XCTAssertEqual(pin.notes, "Test note")
        XCTAssertNotNil(pin.authorUsername)
    }

    // MARK: - 2. asp_suspended_today

    /// AC-I1: asp_suspended_today pin decodes without error.
    func testDecode_aspSuspendedToday() throws {
        let meta = #"{ "suspension_date": "2026-05-25", "reason": "Memorial Day" }"#
        let json = pinFixture(pinType: "asp_suspended_today", source: "crowd", lifespan: "session", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .aspSuspendedToday)
        guard case .aspSuspendedToday(let m) = pin.meta else {
            XCTFail("Expected PinMeta.aspSuspendedToday"); return
        }
        XCTAssertEqual(m.suspensionDate, "2026-05-25")
        XCTAssertEqual(m.reason, "Memorial Day")
    }

    // MARK: - 3. special_event

    /// AC-I1: special_event pin with event_type "marathon" decodes without error.
    func testDecode_specialEvent() throws {
        let meta = #"{ "event_name": "NYC Marathon", "event_type": "marathon" }"#
        let json = pinFixture(pinType: "special_event", source: "open_data", lifespan: "session", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .specialEvent)
        guard case .specialEvent(let m) = pin.meta else {
            XCTFail("Expected PinMeta.specialEvent"); return
        }
        XCTAssertEqual(m.eventName, "NYC Marathon")
        XCTAssertEqual(m.eventType, .marathon)
    }

    // MARK: - 4. construction

    /// AC-I1: construction pin decodes without error; all meta fields optional → nil accepted.
    func testDecode_construction() throws {
        let meta = #"{ "permit_id": "DOT-2026-789", "agency": "Con Edison", "start_date": "2026-06-01", "end_date": "2026-06-15" }"#
        let json = pinFixture(pinType: "construction", source: "hybrid", lifespan: "durable", expiresAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .construction)
        XCTAssertEqual(pin.lifespan, .durable)
        guard case .construction(let m) = pin.meta else {
            XCTFail("Expected PinMeta.construction"); return
        }
        XCTAssertEqual(m.permitId, "DOT-2026-789")
        XCTAssertEqual(m.agency, "Con Edison")
        XCTAssertEqual(m.startDate, "2026-06-01")
        XCTAssertEqual(m.endDate, "2026-06-15")
    }

    // MARK: - 5. sign_correction

    /// AC-I1: sign_correction pin decodes without error.
    func testDecode_signCorrection() throws {
        let meta = #"{ "segment_id": "7th Ave|W 32nd St|W 33rd St", "reported_issue": "Sign says No Parking but should be metered", "existing_rule_text": "No Parking 8am-6pm Mon-Fri" }"#
        let json = pinFixture(pinType: "sign_correction", source: "crowd", lifespan: "correction", expiresAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .signCorrection)
        XCTAssertEqual(pin.lifespan, .correction)
        guard case .signCorrection(let m) = pin.meta else {
            XCTFail("Expected PinMeta.signCorrection"); return
        }
        XCTAssertEqual(m.segmentId, "7th Ave|W 32nd St|W 33rd St")
        XCTAssertEqual(m.reportedIssue, "Sign says No Parking but should be metered")
        XCTAssertEqual(m.existingRuleText, "No Parking 8am-6pm Mon-Fri")
    }

    // MARK: - 6. block_note

    /// AC-I1: block_note pin decodes without error.
    func testDecode_blockNote() throws {
        let meta = #"{ "category": "flooding", "headline": "Standing water at curb after rain" }"#
        let json = pinFixture(pinType: "block_note", source: "crowd", lifespan: "durable", expiresAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .blockNote)
        guard case .blockNote(let m) = pin.meta else {
            XCTFail("Expected PinMeta.blockNote"); return
        }
        XCTAssertEqual(m.category, .flooding)
        XCTAssertEqual(m.headline, "Standing water at curb after rain")
    }

    // MARK: - 7. enforcement_active (sub_tag null — AC-I2 primary fixture)

    /// AC-I1 + AC-I2: enforcement_active with sub_tag null decodes to
    /// .enforcementActive(EnforcementActiveMeta(subTag: nil)).
    func testDecode_enforcementActive_subTagNull() throws {
        let meta = #"{ "sub_tag": null }"#
        let json = pinFixture(pinType: "enforcement_active", source: "crowd", lifespan: "ephemeral", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .enforcementActive)
        XCTAssertEqual(pin.lifespan, .ephemeral)
        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive"); return
        }
        XCTAssertNil(m.subTag,
            "sub_tag: null must decode to EnforcementActiveMeta.subTag == nil (AC-I2)")
    }

    // MARK: - 8. sweeper_passed

    /// AC-I1: sweeper_passed pin decodes without error.
    func testDecode_sweeperPassed() throws {
        let meta = #"{ "direction": "passed" }"#
        let json = pinFixture(pinType: "sweeper_passed", source: "crowd", lifespan: "ephemeral", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .sweeperPassed)
        guard case .sweeperPassed(let m) = pin.meta else {
            XCTFail("Expected PinMeta.sweeperPassed"); return
        }
        XCTAssertEqual(m.direction, .passed)
    }

    // MARK: - 9. broken_meter

    /// AC-I1: broken_meter pin decodes without error.
    func testDecode_brokenMeter() throws {
        let meta = #"{ "meter_id": "M-12345" }"#
        let json = pinFixture(pinType: "broken_meter", source: "crowd", lifespan: "durable", expiresAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .brokenMeter)
        guard case .brokenMeter(let m) = pin.meta else {
            XCTFail("Expected PinMeta.brokenMeter"); return
        }
        XCTAssertEqual(m.meterId, "M-12345")
    }

    // MARK: - 10. parked_car

    /// AC-I1: parked_car pin decodes without error; mirrors W5 ParkedCar fields.
    func testDecode_parkedCar() throws {
        let meta = #"{ "detected_segment_id": "7th Ave|W 32nd St|W 33rd St", "detected_side": "W", "street": "7th Ave", "from_street": "W 32nd St", "to_street": "W 33rd St" }"#
        let json = pinFixture(pinType: "parked_car", source: "crowd", lifespan: "session", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.pinType, .parkedCar)
        guard case .parkedCar(let m) = pin.meta else {
            XCTFail("Expected PinMeta.parkedCar"); return
        }
        XCTAssertEqual(m.detectedSegmentId, "7th Ave|W 32nd St|W 33rd St")
        XCTAssertEqual(m.detectedSide, "W")
        XCTAssertEqual(m.street, "7th Ave")
        XCTAssertEqual(m.fromStreet, "W 32nd St")
        XCTAssertEqual(m.toStreet, "W 33rd St")
    }
}

// MARK: - EnforcementActive sub_tag variant tests (AC-I2, AC-I3)

/// @MainActor required: same isolation reason as CommunityPinDecodeTests above.
@MainActor
final class EnforcementSubTagTests: XCTestCase {

    private let decoder = makeDecoder()

    /// AC-I2: sub_tag field is explicitly JSON null → subTag == nil.
    func testDecode_enforcementActive_subTagNullExplicit() throws {
        let meta = #"{ "sub_tag": null }"#
        let json = pinFixture(pinType: "enforcement_active", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive for sub_tag:null"); return
        }
        XCTAssertNil(m.subTag, "AC-I2: sub_tag null must decode to subTag == nil")
    }

    /// AC-I3: sub_tag = "cleaning_truck" → subTag == .cleaningTruck.
    func testDecode_enforcementActive_subTagCleaningTruck() throws {
        let meta = #"{ "sub_tag": "cleaning_truck" }"#
        let json = pinFixture(pinType: "enforcement_active", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive for sub_tag:cleaning_truck"); return
        }
        XCTAssertEqual(m.subTag, .cleaningTruck,
            "AC-I3: sub_tag:'cleaning_truck' must decode to SubTag.cleaningTruck")
    }

    /// Extra coverage: sub_tag = "parking_agent" → subTag == .parkingAgent.
    func testDecode_enforcementActive_subTagParkingAgent() throws {
        let meta = #"{ "sub_tag": "parking_agent" }"#
        let json = pinFixture(pinType: "enforcement_active", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive"); return
        }
        XCTAssertEqual(m.subTag, .parkingAgent)
    }

    /// Extra coverage: sub_tag = "tow_truck" → subTag == .towTruck.
    func testDecode_enforcementActive_subTagTowTruck() throws {
        let meta = #"{ "sub_tag": "tow_truck" }"#
        let json = pinFixture(pinType: "enforcement_active", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive"); return
        }
        XCTAssertEqual(m.subTag, .towTruck)
    }

    /// sub_tag key absent entirely → subTag == nil (decodeIfPresent safety).
    func testDecode_enforcementActive_subTagKeyAbsent() throws {
        let meta = #"{}"#
        let json = pinFixture(pinType: "enforcement_active", metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected PinMeta.enforcementActive for absent sub_tag key"); return
        }
        XCTAssertNil(m.subTag,
            "Absent sub_tag key must decode to subTag == nil (decodeIfPresent)")
    }
}

// MARK: - expiresAt / resolvedAt tests (AC-I4, AC-I5)

/// @MainActor required: same isolation reason as CommunityPinDecodeTests above.
@MainActor
final class CommunityPinTemporalTests: XCTestCase {

    private let decoder = makeDecoder()

    /// AC-I4: expires_at: null in JSON → pin.expiresAt == nil (no crash, correct nil).
    func testDecode_expiresAt_null_isNil() throws {
        let meta = #"{ "permit_id": "NYC-2026-001" }"#
        let json = pinFixture(pinType: "filming", source: "open_data", lifespan: "session",
                              expiresAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertNil(pin.expiresAt, "AC-I4: expires_at: null must decode to nil (not crash)")
    }

    /// AC-I5: resolved_at set in JSON → pin.resolvedAt is a non-nil Date.
    func testDecode_resolvedAt_set_isNonNil() throws {
        let meta = #"{ "permit_id": "NYC-2026-001" }"#
        let json = pinFixture(pinType: "filming", source: "open_data", lifespan: "session",
                              expiresAt: nil, resolvedAt: kResolvedAt, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertNotNil(pin.resolvedAt, "AC-I5: resolved_at set must decode to a non-nil Date")
    }

    /// expires_at present and non-null → expiresAt is a non-nil Date.
    func testDecode_expiresAt_present_isNonNil() throws {
        let meta = #"{ "sub_tag": null }"#
        let json = pinFixture(pinType: "enforcement_active", source: "crowd", lifespan: "ephemeral",
                              expiresAt: kExpiresAt, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertNotNil(pin.expiresAt, "expires_at present in JSON must decode to non-nil Date")
    }

    /// resolvedAt absent in JSON → pin.resolvedAt == nil.
    func testDecode_resolvedAt_absent_isNil() throws {
        let meta = #"{ "permit_id": "NYC-2026-001" }"#
        let json = pinFixture(pinType: "filming", source: "open_data", lifespan: "session",
                              resolvedAt: nil, metaJSON: meta)
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertNil(pin.resolvedAt, "Absent resolved_at must decode to nil")
    }
}

// MARK: - PinType rawValue round-trip (AC-I7)

final class PinTypeRawValueTests: XCTestCase {

    /// AC-I7 helper: encode a PinType to JSON string, decode back, assert equal.
    private func assertRoundTrip(_ type: PinType, expectedRaw: String, file: StaticString = #file, line: UInt = #line) throws {
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(type)
        let encoded = String(data: data, encoding: .utf8) ?? ""
        // JSON encoder wraps strings in quotes
        XCTAssertEqual(encoded, #""\#(expectedRaw)""#,
            "PinType.\(type) rawValue must encode to \"\(expectedRaw)\"",
            file: file, line: line)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PinType.self, from: data)
        XCTAssertEqual(decoded, type,
            "PinType.\(type) must survive encode→decode round-trip unchanged",
            file: file, line: line)
    }

    func testRawValue_filming()           throws { try assertRoundTrip(.filming, expectedRaw: "filming") }
    func testRawValue_aspSuspendedToday() throws { try assertRoundTrip(.aspSuspendedToday, expectedRaw: "asp_suspended_today") }
    func testRawValue_specialEvent()      throws { try assertRoundTrip(.specialEvent, expectedRaw: "special_event") }
    func testRawValue_construction()      throws { try assertRoundTrip(.construction, expectedRaw: "construction") }
    func testRawValue_signCorrection()    throws { try assertRoundTrip(.signCorrection, expectedRaw: "sign_correction") }
    func testRawValue_blockNote()         throws { try assertRoundTrip(.blockNote, expectedRaw: "block_note") }
    func testRawValue_enforcementActive() throws { try assertRoundTrip(.enforcementActive, expectedRaw: "enforcement_active") }
    func testRawValue_sweeperPassed()     throws { try assertRoundTrip(.sweeperPassed, expectedRaw: "sweeper_passed") }
    func testRawValue_brokenMeter()       throws { try assertRoundTrip(.brokenMeter, expectedRaw: "broken_meter") }
    func testRawValue_parkedCar()         throws { try assertRoundTrip(.parkedCar, expectedRaw: "parked_car") }

    /// AC-I7 guard: CaseIterable confirms exactly 10 cases — no accidental additions.
    func testPinType_exactlyTenCases() {
        XCTAssertEqual(PinType.allCases.count, 10,
            "PinType must have exactly 10 cases as specified in §4.1 + §10.1")
    }
}

// MARK: - Graceful fallback tests

/// @MainActor required: same isolation reason as CommunityPinDecodeTests above.
@MainActor
final class CommunityPinGracefulFallbackTests: XCTestCase {

    private let decoder = makeDecoder()

    /// An unknown pin_type value must throw DecodingError (standard behaviour),
    /// allowing callers to decide how to handle it.
    func testDecode_unknownPinType_throwsDecodingError() {
        let json = pinFixture(pinType: "unknown_future_type", metaJSON: "null")
        XCTAssertThrowsError(
            try decoder.decode(CommunityPin.self, from: Data(json.utf8)),
            "Unknown pin_type must throw DecodingError"
        ) { error in
            // Must be a DecodingError (not some other error type).
            XCTAssertTrue(error is DecodingError,
                "Error must be DecodingError, got: \(error)")
        }
    }

    /// CommunityPin.gracefulDecode returns nil for unknown pin_type (soft-failure path).
    ///
    /// Uses a `Decodable` trampoline to obtain a live `Swift.Decoder` instance and pass it
    /// directly to `CommunityPin.gracefulDecode(from:)`, exercising the actual production
    /// method rather than reimplementing its try/catch inline.
    func testGracefulDecode_unknownPinType_returnsNil() throws {
        let json = pinFixture(pinType: "unknown_future_type", metaJSON: "null")

        // Trampoline: Decodable wrapper whose init receives a Decoder and forwards it
        // to the real CommunityPin.gracefulDecode(from:) static method.
        struct GracefulDecodeTrampoline: Decodable {
            let result: CommunityPin?
            init(from decoder: Decoder) throws {
                result = CommunityPin.gracefulDecode(from: decoder)
            }
        }

        let trampoline = try decoder.decode(GracefulDecodeTrampoline.self, from: Data(json.utf8))
        XCTAssertNil(trampoline.result,
            "CommunityPin.gracefulDecode(from:) must return nil for unknown pin_type, not crash")
    }

    /// Malformed JSON (missing required 'id' field) must throw.
    func testDecode_malformedJSON_missingId_throws() {
        let malformed = """
        {
          "pin_type": "filming",
          "source": "crowd",
          "lifespan": "session",
          "lat": 40.75,
          "lng": -73.99,
          "created_at": "\(kCreatedAt)",
          "updated_at": "\(kUpdatedAt)",
          "confirm_count": 0,
          "dispute_count": 0
        }
        """
        XCTAssertThrowsError(
            try decoder.decode(CommunityPin.self, from: Data(malformed.utf8)),
            "Missing required 'id' must throw DecodingError"
        )
    }
}

// MARK: - Meta null handling

/// @MainActor required: same isolation reason as CommunityPinDecodeTests above.
@MainActor
final class PinMetaNullTests: XCTestCase {

    private let decoder = makeDecoder()

    /// When meta column is JSON null, pin.meta is nil (no crash).
    func testDecode_metaNull_isNilMeta() throws {
        let json = pinFixture(pinType: "broken_meter", source: "crowd", lifespan: "durable",
                              expiresAt: nil, metaJSON: "null")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        XCTAssertNil(pin.meta, "meta: null must decode to pin.meta == nil (not crash)")
    }

    /// construction pin with all meta fields absent (empty object) still decodes —
    /// all fields are optional per §4.3.
    func testDecode_construction_allMetaFieldsOptional() throws {
        let json = pinFixture(pinType: "construction", lifespan: "durable",
                              expiresAt: nil, metaJSON: "{}")
        let pin = try decoder.decode(CommunityPin.self, from: Data(json.utf8))

        guard case .construction(let m) = pin.meta else {
            XCTFail("Expected PinMeta.construction for empty meta object"); return
        }
        XCTAssertNil(m.permitId,  "All construction meta fields are optional — permitId should be nil")
        XCTAssertNil(m.agency,    "All construction meta fields are optional — agency should be nil")
        XCTAssertNil(m.startDate, "All construction meta fields are optional — startDate should be nil")
        XCTAssertNil(m.endDate,   "All construction meta fields are optional — endDate should be nil")
    }
}

// MARK: - Source / Lifespan enum rawValue tests

final class PinAxisEnumTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testRawValue_source_allCases() throws {
        let cases: [(PinSource, String)] = [
            (.openData, "open_data"),
            (.hybrid,   "hybrid"),
            (.crowd,    "crowd"),
        ]
        for (source, raw) in cases {
            let data = try encoder.encode(source)
            let encoded = String(data: data, encoding: .utf8) ?? ""
            XCTAssertEqual(encoded, #""\#(raw)""#, "PinSource.\(source) must encode to \"\(raw)\"")
            let decoded = try decoder.decode(PinSource.self, from: data)
            XCTAssertEqual(decoded, source, "PinSource round-trip failed for \(raw)")
        }
    }

    func testRawValue_lifespan_allCases() throws {
        let cases: [(PinLifespan, String)] = [
            (.ephemeral,  "ephemeral"),
            (.session,    "session"),
            (.durable,    "durable"),
            (.correction, "correction"),
        ]
        for (lifespan, raw) in cases {
            let data = try encoder.encode(lifespan)
            let encoded = String(data: data, encoding: .utf8) ?? ""
            XCTAssertEqual(encoded, #""\#(raw)""#, "PinLifespan.\(lifespan) must encode to \"\(raw)\"")
            let decoded = try decoder.decode(PinLifespan.self, from: data)
            XCTAssertEqual(decoded, lifespan, "PinLifespan round-trip failed for \(raw)")
        }
    }
}

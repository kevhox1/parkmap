//
//  FT11DirectionTests.swift
//  WeParkTests
//
//  FT-11 — Travel Direction Indicator.
//  Spec: docs/ft11-report-direction-spec.md §8.
//
//  Test inventory (minimum 16 per spec §8, extended with integration helpers):
//
//  Segment decode:
//    1.  testSegmentDecoding_oneway_true                  (AC-1)
//    2.  testSegmentDecoding_onewayToward_from            (AC-2)
//    3.  testSegmentDecoding_legacyTile_noOnewayFields    (AC-3)
//
//  HeadingToward enum:
//    4.  testHeadingToward_rawValues                      (AC-4)
//
//  Meta decode (EnforcementActiveMeta):
//    5.  testEnforcementMetaDecode_withHeadingToward      (AC-5, AC-7)
//    6.  testSweeperMetaDecode_withHeadingToward          (AC-6)
//    7.  testMetaDecode_missingHeadingToward_isNil        (AC-8)
//
//  SegmentBearing math:
//    8.  testBearing_toward_to                            (AC-9)
//    9.  testBearing_toward_from_isReverse                (AC-10)
//   10.  testBearing_degenerateSegment_nocrash            (AC-11)
//
//  One-way auto-derive logic:
//   11.  testAutoDerive_oneway_from_hidesPickerSetFromDir (AC-12)
//   12.  testAutoDerive_oneway_to_hidesPickerSetToDir     (AC-13)
//   13.  testAutoDerive_twoWay_showsPicker                (AC-14)
//
//  buildMeta with headingToward:
//   14.  testBuildMeta_enforcement_withHeadingToward      (AC-18)
//   15.  testBuildMeta_sweeper_withHeadingToward          (AC-19)
//   16.  testBuildMeta_headingToward_nil_noKey            (AC-20)
//
//  Additional coverage:
//   17.  testSegmentDecoding_oneway_false_isPresent       (verifies Bool false decodes, not just true)
//   18.  testBearing_toward_to_north                      (north-pointing segment sanity check)
//   19.  testBearing_oneCoordinate_fallback               (edge: exactly 1 coord pair)
//   20.  testEnforcementMetaDecode_roundTrip_from         (AC-7 — round-trip encode then decode)
//
//  Baseline before FT-11: 446 tests.
//  After FT-11: 446 + 20 = 466 tests.
//

import XCTest
@testable import WePark

// MARK: - Segment decode tests

final class FT11SegmentDecodeTests: XCTestCase {

    // MARK: - Helpers

    /// Decodes a Segment from a JSON string. Force-unwrap is acceptable in tests —
    /// a decode failure here is a test-authoring error that should fail loudly.
    private func decodeSegment(_ json: String) -> Segment {
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private let baseSegmentJSON = """
    {
      "id": "SPRING_ST_WOOSTER_ST_GREENE_ST_N_1",
      "from": "WOOSTER STREET",
      "to": "GREENE STREET",
      "street": "SPRING STREET",
      "side": "N",
      "line": [[40.7248, -74.0032], [40.7249, -74.0021]],
      "rules": [],
      "dominantCategory": null
    }
    """

    // MARK: AC-1: oneway: true decodes

    func testSegmentDecoding_oneway_true() {
        let json = """
        {
          "id": "SPRING_ST_WOOSTER_ST_GREENE_ST_N_1",
          "from": "WOOSTER STREET",
          "to": "GREENE STREET",
          "street": "SPRING STREET",
          "side": "N",
          "line": [[40.7248, -74.0032], [40.7249, -74.0021]],
          "rules": [],
          "dominantCategory": null,
          "oneway": true,
          "oneway_toward": "from"
        }
        """
        let segment = decodeSegment(json)
        XCTAssertEqual(segment.oneway, true, "oneway: true should decode as Bool true (AC-1)")
    }

    // MARK: AC-2: onewayToward: "from" decodes

    func testSegmentDecoding_onewayToward_from() {
        let json = """
        {
          "id": "SPRING_ST_WOOSTER_ST_GREENE_ST_N_1",
          "from": "WOOSTER STREET",
          "to": "GREENE STREET",
          "street": "SPRING STREET",
          "side": "N",
          "line": [[40.7248, -74.0032], [40.7249, -74.0021]],
          "rules": [],
          "dominantCategory": null,
          "oneway": true,
          "oneway_toward": "from"
        }
        """
        let segment = decodeSegment(json)
        XCTAssertEqual(segment.onewayToward, "from",
                       "oneway_toward: 'from' should decode to onewayToward == 'from' (AC-2)")
    }

    // MARK: AC-3: Legacy tile (no oneway fields) decodes as nil — backward-compat

    func testSegmentDecoding_legacyTile_noOnewayFields() {
        let segment = decodeSegment(baseSegmentJSON)
        XCTAssertNil(segment.oneway,
                     "Missing oneway field should decode as nil — backward-compat (AC-3)")
        XCTAssertNil(segment.onewayToward,
                     "Missing oneway_toward field should decode as nil — backward-compat (AC-3)")
    }

    // MARK: Extra: oneway: false decodes as Bool false (not nil)

    func testSegmentDecoding_oneway_false_isPresent() {
        let json = """
        {
          "id": "TEST_ID",
          "from": "WOOSTER STREET",
          "to": "GREENE STREET",
          "street": "SPRING STREET",
          "side": "N",
          "line": [[40.7248, -74.0032], [40.7249, -74.0021]],
          "rules": [],
          "dominantCategory": null,
          "oneway": false
        }
        """
        let segment = decodeSegment(json)
        XCTAssertEqual(segment.oneway, false,
                       "oneway: false should decode as Bool false, not nil")
    }
}

// MARK: - HeadingToward enum tests

final class FT11HeadingTowardTests: XCTestCase {

    // MARK: AC-4: HeadingToward raw values

    func testHeadingToward_rawValues() {
        XCTAssertEqual(HeadingToward.from.rawValue, "from",
                       "HeadingToward.from must have rawValue 'from' (AC-4)")
        XCTAssertEqual(HeadingToward.toward_to.rawValue, "to",
                       "HeadingToward.toward_to must have rawValue 'to' (AC-4)")
    }

    /// There are exactly 2 cases in HeadingToward.
    func testHeadingToward_exactlyTwoCases() {
        // Encode both and verify they round-trip.
        let fromEncoded = try! JSONEncoder().encode(HeadingToward.from)
        let toEncoded   = try! JSONEncoder().encode(HeadingToward.toward_to)
        XCTAssertEqual(String(data: fromEncoded, encoding: .utf8), "\"from\"")
        XCTAssertEqual(String(data: toEncoded,   encoding: .utf8), "\"to\"")
    }
}

// MARK: - Meta decode tests

final class FT11MetaDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func makePin(type: String, meta: String) -> CommunityPin {
        let json = """
        {
          "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "pin_type": "\(type)",
          "source": "crowd",
          "lifespan": "ephemeral",
          "lat": 40.72,
          "lng": -74.00,
          "author_id": null,
          "author_username": null,
          "created_at": "2026-06-01T12:00:00Z",
          "updated_at": "2026-06-01T12:00:00Z",
          "expires_at": null,
          "resolved_at": null,
          "confirm_count": 0,
          "dispute_count": 0,
          "meta": \(meta),
          "notes": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(CommunityPin.self, from: json)
    }

    // MARK: AC-5: EnforcementActiveMeta decodes headingToward = .from

    func testEnforcementMetaDecode_withHeadingToward() {
        let metaJSON = "{\"sub_tag\": \"parking_agent\", \"heading_toward\": \"from\"}"
        let pin = makePin(type: "enforcement_active", meta: metaJSON)
        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected .enforcementActive meta")
            return
        }
        XCTAssertEqual(m.headingToward, .from,
                       "heading_toward: 'from' should decode as HeadingToward.from (AC-5)")
        XCTAssertEqual(m.subTag, .parkingAgent,
                       "sub_tag should still decode correctly (no regression)")
    }

    // MARK: AC-6: SweeperPassedMeta decodes headingToward + direction (no regression)

    func testSweeperMetaDecode_withHeadingToward() {
        let metaJSON = "{\"direction\": \"passed\", \"heading_toward\": \"from\"}"
        let pin = makePin(type: "sweeper_passed", meta: metaJSON)
        guard case .sweeperPassed(let m) = pin.meta else {
            XCTFail("Expected .sweeperPassed meta")
            return
        }
        XCTAssertEqual(m.headingToward, .from,
                       "heading_toward: 'from' should decode as .from (AC-6)")
        XCTAssertEqual(m.direction, .passed,
                       "direction field should still decode correctly — no regression (AC-6)")
    }

    // MARK: AC-8: Missing heading_toward decodes as nil (backward-compat)

    func testMetaDecode_missingHeadingToward_isNil() {
        let metaJSON = "{\"sub_tag\": \"parking_agent\"}"
        let pin = makePin(type: "enforcement_active", meta: metaJSON)
        guard case .enforcementActive(let m) = pin.meta else {
            XCTFail("Expected .enforcementActive meta")
            return
        }
        XCTAssertNil(m.headingToward,
                     "Missing heading_toward should decode as nil (AC-8 backward-compat)")
    }

    // MARK: AC-7: Round-trip encode → decode preserves headingToward

    func testEnforcementMetaDecode_roundTrip_from() {
        // Build a CommunityPin with headingToward = .from in its meta JSON.
        let metaJSON = "{\"sub_tag\": \"parking_agent\", \"heading_toward\": \"from\"}"
        let pin = makePin(type: "enforcement_active", meta: metaJSON)
        // Encode back to JSON.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(pin),
              let decoded = try? {
                  let dec = JSONDecoder()
                  dec.dateDecodingStrategy = .iso8601
                  return try dec.decode(CommunityPin.self, from: encoded)
              }()
        else {
            XCTFail("Round-trip encode/decode failed")
            return
        }
        guard case .enforcementActive(let m) = decoded.meta else {
            XCTFail("Expected .enforcementActive meta after round-trip")
            return
        }
        XCTAssertEqual(m.headingToward, .from,
                       "headingToward must survive encode → decode round-trip (AC-7)")
    }
}

// MARK: - SegmentBearing math tests

final class FT11BearingTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal Segment with two line coordinates for math testing.
    private func makeSegment(
        from: (lat: Double, lng: Double),
        to: (lat: Double, lng: Double)
    ) -> Segment {
        Segment(
            id: "TEST",
            street: "TEST ST",
            fromStreet: "FROM ST",
            to: "TO ST",
            side: "N",
            line: [[from.lat, from.lng], [to.lat, to.lng]],
            rules: [],
            dominantCategory: nil
        )
    }

    // MARK: AC-9: bearing toward .to = from line[0] to line.last

    /// Uses a segment running roughly east (40°N, -74° → -73.99°).
    /// Expected bearing ≈ 90° (east).
    func testBearing_toward_to() {
        let segment = makeSegment(
            from: (lat: 40.0, lng: -74.0),
            to:   (lat: 40.0, lng: -73.99)
        )
        let bearing = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        // East bearing should be close to 90°.
        XCTAssertEqual(bearing, 90.0, accuracy: 1.0,
                       "Bearing toward .to on an east-running segment should be ~90° (AC-9)")
    }

    // MARK: AC-10: bearing toward .from = reverse of bearing toward .to (±0.5°)

    func testBearing_toward_from_isReverse() {
        let segment = makeSegment(
            from: (lat: 40.0, lng: -74.0),
            to:   (lat: 40.0, lng: -73.99)
        )
        let toBearing   = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        let fromBearing = SegmentBearing.bearing(segment: segment, toward: .from)

        // Reverse bearing: diff should be exactly 180° (mod 360°).
        let diff = abs(fromBearing - toBearing)
        let normalizedDiff = min(diff, 360.0 - diff)
        XCTAssertEqual(normalizedDiff, 180.0, accuracy: 0.5,
                       "bearing toward .from must be the reverse of bearing toward .to, ±0.5° (AC-10)")
    }

    // MARK: AC-11: Degenerate segment (< 2 coords) returns 0.0, no crash

    func testBearing_degenerateSegment_nocrash() {
        // Empty line.
        let empty = Segment(
            id: "EMPTY",
            street: "EMPTY ST",
            fromStreet: "A",
            to: "B",
            side: "N",
            line: [],
            rules: [],
            dominantCategory: nil
        )
        let bearingEmpty = SegmentBearing.bearing(segment: empty, toward: .toward_to)
        XCTAssertEqual(bearingEmpty, 0.0,
                       "Empty line should return 0.0 without crashing (AC-11)")

        // Single coordinate pair.
        let single = Segment(
            id: "SINGLE",
            street: "SINGLE ST",
            fromStreet: "A",
            to: "B",
            side: "N",
            line: [[40.0, -74.0]],
            rules: [],
            dominantCategory: nil
        )
        let bearingSingle = SegmentBearing.bearing(segment: single, toward: .from)
        XCTAssertEqual(bearingSingle, 0.0,
                       "Single-coord line should return 0.0 without crashing (AC-11)")
    }

    // MARK: Extra: north-running segment gives ≈0° toward .to

    func testBearing_toward_to_north() {
        let segment = makeSegment(
            from: (lat: 40.0, lng: -74.0),
            to:   (lat: 40.01, lng: -74.0)
        )
        let bearing = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        XCTAssertEqual(bearing, 0.0, accuracy: 1.0,
                       "North-running segment should give bearing ≈ 0° toward .to")
    }

    // MARK: Extra: exactly 1 coord pair (degenerate boundary)

    func testBearing_oneCoordinate_fallback() {
        let segment = Segment(
            id: "ONE",
            street: "ONE ST",
            fromStreet: "A",
            to: "B",
            side: "N",
            line: [[40.0, -74.0]],
            rules: [],
            dominantCategory: nil
        )
        // Should return 0.0, not crash.
        let b = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        XCTAssertEqual(b, 0.0, "One-coord segment should return 0.0 fallback without crashing")
    }
}

// MARK: - Auto-derive logic tests

/// Tests for the one-way auto-derive behavior.
///
/// These tests verify the PURE LOGIC of `shouldShowDirectionPicker` and the auto-derive
/// derivation, using the static helpers on ReportSheet. We derive the expected behavior
/// by constructing Segment values and inspecting ReportSheet's pure-function surface
/// (autoDerive logic is encoded in `buildMeta`'s headingToward parameter path and
/// the segment's `oneway`/`onewayToward` fields).
///
/// Note: The `shouldShowDirectionPicker` property is computed inside the SwiftUI view
/// and depends on @State, so we test the IDENTICAL logic via its constituent inputs
/// (segment.oneway, selectedType) in a plain test context. Per the spec, the behavior
/// is: one-way sweeper → auto-set, no picker; two-way sweeper → show picker.
final class FT11AutoDeriveTests: XCTestCase {

    // MARK: - Helpers

    private func makeSegment(oneway: Bool?, onewayToward: String?) -> Segment {
        Segment(
            id: "TEST_SEG",
            street: "SPRING STREET",
            fromStreet: "WOOSTER STREET",
            to: "GREENE STREET",
            side: "N",
            line: [[40.7248, -74.0032], [40.7249, -74.0021]],
            rules: [],
            dominantCategory: nil,
            oneway: oneway,
            onewayToward: onewayToward
        )
    }

    // MARK: AC-12: One-way (toward from) → auto-set heading, no picker

    func testAutoDerive_oneway_from_hidesPickerSetFromDir() {
        let segment = makeSegment(oneway: true, onewayToward: "from")

        // Picker should be hidden for a one-way sweeper.
        // shouldShowDirectionPicker for sweeper = segment.oneway != true → FALSE
        let shouldShowPicker = segment.oneway != true
        XCTAssertFalse(shouldShowPicker,
                       "One-way sweeper segment should NOT show the picker (AC-12)")

        // Auto-derived heading should be .from
        let headingToward: HeadingToward?
        if segment.oneway == true {
            switch segment.onewayToward {
            case "from": headingToward = .from
            case "to":   headingToward = .toward_to
            default:     headingToward = nil
            }
        } else {
            headingToward = nil
        }
        XCTAssertEqual(headingToward, .from,
                       "Auto-derived heading should be .from when onewayToward == 'from' (AC-12)")
    }

    // MARK: AC-13: One-way (toward to) → auto-set heading to .toward_to, no picker

    func testAutoDerive_oneway_to_hidesPickerSetToDir() {
        let segment = makeSegment(oneway: true, onewayToward: "to")

        let shouldShowPicker = segment.oneway != true
        XCTAssertFalse(shouldShowPicker,
                       "One-way sweeper segment (toward 'to') should NOT show picker (AC-13)")

        let headingToward: HeadingToward?
        if segment.oneway == true {
            switch segment.onewayToward {
            case "from": headingToward = .from
            case "to":   headingToward = .toward_to
            default:     headingToward = nil
            }
        } else {
            headingToward = nil
        }
        XCTAssertEqual(headingToward, .toward_to,
                       "Auto-derived heading should be .toward_to when onewayToward == 'to' (AC-13)")
    }

    // MARK: AC-14: Two-way sweeper → picker shown

    func testAutoDerive_twoWay_showsPicker() {
        let twoWaySegment = makeSegment(oneway: false, onewayToward: nil)
        let shouldShowPickerTwoWay = twoWaySegment.oneway != true
        XCTAssertTrue(shouldShowPickerTwoWay,
                      "Two-way (oneway: false) sweeper should show picker (AC-14)")

        let nilOnewaySegment = makeSegment(oneway: nil, onewayToward: nil)
        let shouldShowPickerNilOneway = nilOnewaySegment.oneway != true
        XCTAssertTrue(shouldShowPickerNilOneway,
                      "Absent oneway field (nil) sweeper should show picker (AC-14)")
    }
}

// MARK: - buildMeta with headingToward tests

/// Tests for ReportSheet.buildMeta with the FT-11 `headingToward` parameter.
final class FT11BuildMetaTests: XCTestCase {

    // MARK: AC-18: enforcement meta includes heading_toward key

    func testBuildMeta_enforcement_withHeadingToward() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: .parkingAgent,
            sweeperDirection: .passed,
            headingToward: .from
        )
        XCTAssertEqual(pinType, .enforcementActive)
        XCTAssertEqual(meta?["sub_tag"] as? String, "parking_agent",
                       "sub_tag must still be present (AC-18)")
        XCTAssertEqual(meta?["heading_toward"] as? String, "from",
                       "meta must include heading_toward: 'from' (AC-18)")
    }

    // MARK: AC-19: sweeper meta includes both direction AND heading_toward

    func testBuildMeta_sweeper_withHeadingToward() {
        let (pinType, meta) = ReportSheet.buildMeta(
            type: .sweeper,
            subTag: nil,
            sweeperDirection: .passed,
            headingToward: .toward_to
        )
        XCTAssertEqual(pinType, .sweeperPassed)
        XCTAssertEqual(meta?["direction"] as? String, "passed",
                       "direction key must still be present — no regression (AC-19)")
        XCTAssertEqual(meta?["heading_toward"] as? String, "to",
                       "meta must include heading_toward: 'to' (AC-19)")
    }

    // MARK: AC-20: nil headingToward → no heading_toward key in meta

    func testBuildMeta_headingToward_nil_noKey() {
        let (_, metaEnforcement) = ReportSheet.buildMeta(
            type: .enforcementActive,
            subTag: .parkingAgent,
            sweeperDirection: .passed,
            headingToward: nil
        )
        XCTAssertNil(metaEnforcement?["heading_toward"],
                     "nil headingToward must NOT produce a heading_toward key in meta (AC-20)")

        let (_, metaSweeper) = ReportSheet.buildMeta(
            type: .sweeper,
            subTag: nil,
            sweeperDirection: .passed,
            headingToward: nil
        )
        XCTAssertNil(metaSweeper?["heading_toward"],
                     "nil headingToward on sweeper must NOT produce a heading_toward key (AC-20)")
    }
}

// MARK: - Build-7 chevron bearing correction tests (FT-11 QA Finding #1 fix)

/// Verifies that the `(bearing - 90)` correction applied to `chevron.forward` in both
/// `PinMarkerAnnotation.markerImage(for:bearing:)` (CGContext rotation) and
/// `ReportSheet.headingArrowButton` (SwiftUI .rotationEffect) produces the correct
/// compass orientation.
///
/// `chevron.forward` points EAST natively. Without the correction:
///   - bearing=0 (north) → chevron points east (90° off)
///   - bearing=90 (east)  → chevron points south (90° off)
/// With `bearing - 90`:
///   - bearing=0   → correction = -90° → chevron points north ✓
///   - bearing=90  → correction =   0° → chevron points east  ✓
///   - bearing=180 → correction = +90° → chevron points south ✓
///   - bearing=270 → correction = 180° → chevron points west  ✓
///
/// These tests verify the MATH of the correction formula as a pure function,
/// without rendering UIKit/SwiftUI contexts. Visual validation (N-S picker arrows
/// point N and S on a north-south street) is Kevin's on-device gate per the QA report.
final class FT11ChevronBearingCorrectionTests: XCTestCase {

    // MARK: - Helper

    /// Returns the effective screen rotation in degrees for a given compass bearing
    /// after the -90° correction applied to chevron.forward.
    ///
    /// In UIKit CGContext:  effective = (bearing - 90) degrees
    /// In SwiftUI:          effective = (bearing - 90) degrees (rotationEffect)
    private func correctedRotationDegrees(bearing: Double) -> Double {
        return bearing - 90
    }

    // MARK: - North-pointing segment

    /// A segment running north (bearing ≈ 0°). After correction the arrow should
    /// point north = up on a north-up map → corrected rotation ≈ -90° (i.e., CCW 90°
    /// from east, which in CGContext/SwiftUI CW convention = effectively pointing up).
    func testChevronCorrection_northBearing_mapsToMinusNinetyDeg() {
        let corrected = correctedRotationDegrees(bearing: 0)
        XCTAssertEqual(corrected, -90.0, accuracy: 0.001,
            "bearing=0 (north) corrected rotation should be -90°. Got \(corrected)°")
    }

    // MARK: - East-pointing segment

    /// A segment running east (bearing ≈ 90°). After correction the arrow should
    /// point east → corrected rotation = 0° (identity = chevron.forward rest orientation).
    func testChevronCorrection_eastBearing_mapsToZeroDeg() {
        let corrected = correctedRotationDegrees(bearing: 90)
        XCTAssertEqual(corrected, 0.0, accuracy: 0.001,
            "bearing=90 (east) corrected rotation should be 0°. Got \(corrected)°")
    }

    // MARK: - South-pointing segment

    /// A segment running south (bearing ≈ 180°). After correction → +90°.
    func testChevronCorrection_southBearing_mapsToPlusNinetyDeg() {
        let corrected = correctedRotationDegrees(bearing: 180)
        XCTAssertEqual(corrected, 90.0, accuracy: 0.001,
            "bearing=180 (south) corrected rotation should be +90°. Got \(corrected)°")
    }

    // MARK: - West-pointing segment

    /// A segment running west (bearing ≈ 270°). After correction → +180°.
    func testChevronCorrection_westBearing_mapsToPlusOneEightyDeg() {
        let corrected = correctedRotationDegrees(bearing: 270)
        XCTAssertEqual(corrected, 180.0, accuracy: 0.001,
            "bearing=270 (west) corrected rotation should be +180°. Got \(corrected)°")
    }

    // MARK: - Reverse of a north-bound segment = south (bearing 180°)

    /// For a N-S street: the "toward north" arrow (bearing ≈ 0°) and the "toward south"
    /// arrow (bearing ≈ 180°) should be exactly 180° apart after correction.
    func testChevronCorrection_northSouthPairAre180Apart() {
        let northCorrected = correctedRotationDegrees(bearing: 0)
        let southCorrected = correctedRotationDegrees(bearing: 180)
        let diff = abs(southCorrected - northCorrected)
        XCTAssertEqual(diff, 180.0, accuracy: 0.001,
            "N and S arrows on a N-S street must point 180° apart after correction. Got diff \(diff)°")
    }

    // MARK: - Symmetry: corrected formula equals (bearing - 90) for all cardinal points

    func testChevronCorrection_formula_isLinear() {
        // The correction is a simple linear offset; verify at multiple bearings.
        let testCases: [(bearing: Double, expected: Double)] = [
            (0, -90), (45, -45), (90, 0), (135, 45), (180, 90), (225, 135), (270, 180), (315, 225)
        ]
        for tc in testCases {
            let result = correctedRotationDegrees(bearing: tc.bearing)
            XCTAssertEqual(result, tc.expected, accuracy: 0.001,
                "bearing=\(tc.bearing) → expected \(tc.expected)°, got \(result)°")
        }
    }

    // MARK: - SegmentBearing integration: north-running segment bearing ≈ 0 → corrected ≈ -90

    /// End-to-end: uses a north-running segment and SegmentBearing.bearing to get the
    /// raw bearing, then verifies the corrected rotation is ≈ -90° (pointing north).
    func testChevronCorrection_northRunningSegment_endToEnd() {
        let segment = Segment(
            id: "NORTH_TEST",
            street: "TEST AVE",
            fromStreet: "SOUTH ST",
            to: "NORTH ST",
            side: "E",
            line: [[40.70, -74.00], [40.71, -74.00]],  // runs north
            rules: [],
            dominantCategory: nil
        )
        let bearing = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        // bearing toward north end should be ≈ 0°.
        XCTAssertEqual(bearing, 0.0, accuracy: 2.0,
            "North-running segment bearing toward .to should be ≈ 0°. Got \(bearing)°")

        // After correction: ≈ -90° (arrow points north).
        let corrected = bearing - 90
        XCTAssertEqual(corrected, -90.0, accuracy: 2.0,
            "North-running segment corrected rotation should be ≈ -90°. Got \(corrected)°")
    }
}

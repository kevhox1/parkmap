//
//  ReportTapToPlaceSpecTests.swift
//  WeParkTests
//
//  Open item #22 — docs/report-tap-to-place-spec.md. Pure-logic tests for both work streams:
//
//  Stream 1 — curb-snap-on-display (spec §2):
//    CandidateSegmentSearch.coordinate(atFraction:along:) — the new fraction-walk helper:
//      1.  testCoordinateAtFraction_zero_returnsFirstVertex
//      2.  testCoordinateAtFraction_one_returnsLastVertex
//      3.  testCoordinateAtFraction_half_returnsMidpointOnStraightLine
//      4.  testCoordinateAtFraction_negativeClampedToZero
//      5.  testCoordinateAtFraction_aboveOneClampedToOne
//      6.  testCoordinateAtFraction_multiVertexPolyline_respectsCumulativeLength
//      7.  testCoordinateAtFraction_degeneratePolyline_returnsNil
//
//    CommunityPinAnnotation.resolveDisplayCoordinate(for:segmentByID:) — AC-1 through AC-3:
//      8.  testResolveDisplayCoordinate_positionFractionPresent_interpolatesAlongPolyline
//      9.  testResolveDisplayCoordinate_noPositionFraction_projectsRawCoordOntoPolyline
//      10. testResolveDisplayCoordinate_nilSegmentId_fallsBackToRawLatLng
//      11. testResolveDisplayCoordinate_segmentIdNotInLoadedSet_fallsBackToRawLatLng
//      12. testResolveDisplayCoordinate_degenerateSegmentPolyline_fallsBackToRawLatLng
//
//  Stream 2 — tap-to-reposition (spec §3):
//    ReportSheet.showsRepositionAffordance(communityEnabled:selectedType:allowsReposition:) — AC-7/AC-8:
//      13. testShowsRepositionAffordance_flagOff_false
//      14. testShowsRepositionAffordance_allowsRepositionFalse_false
//      15. testShowsRepositionAffordance_noTypeSelected_false
//      16. testShowsRepositionAffordance_enforcementActive_true
//      17. testShowsRepositionAffordance_sweeper_true
//
//    ReportSheet.effectiveCoordinate(original:repositioned:) — AC-10/AC-13:
//      18. testEffectiveCoordinate_neverRepositioned_returnsOriginal
//      19. testEffectiveCoordinate_repositioned_returnsRepositionedPoint
//
//    CandidateSegmentSearch.reportRepositionCandidates(forTap:lng:in:radius:) — AC-9/AC-11:
//      20. testReportRepositionCandidates_withinRadius_findsSegmentAndCandidates
//      21. testReportRepositionCandidates_outsideRadius_nilSegmentEmptyCandidates
//      22. testReportRepositionCandidates_emptySegments_nilSegmentEmptyCandidates
//
//    ActiveSheet.reportPin id stability — THE landmine (spec §3.2):
//      23. testActiveSheetReportPinId_dependsOnlyOnCoordinate_notSegmentCandidatesOrSource
//      24. testActiveSheetReportPinId_changesWhenCoordinateChanges
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never compiled
//  or run. A Mac `xcodebuild test` pass is a required gate before merge.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixture helpers

/// Minimal two/three-point `Segment` fixture — mirrors this suite's established
/// `candidateFixtureSegment` pattern (`CandidateSegmentSearchTests.swift`), duplicated here
/// per this codebase's own "small per-file fixture helper" house style rather than shared.
private func fixtureSegment(
    id: String = "TEST",
    street: String = "MOTT STREET",
    from: String = "SPRING STREET",
    to: String = "BROOME STREET",
    side: String = "E",
    line: [[Double]] = [[40.7230, -73.9950], [40.7230, -73.9940]]
) -> Segment {
    Segment(
        id: id, street: street, fromStreet: from, to: to, side: side,
        line: line, rules: [], dominantCategory: nil
    )
}

/// Minimal `CommunityPin` fixture, decoded from JSON (no direct memberwise init exists on
/// this model — mirrors `FT11DirectionTests.makePin(type:meta:)`'s established pattern).
private func fixturePin(
    segmentId: String? = nil,
    positionFraction: Double? = nil,
    lat: Double = 40.7230,
    lng: Double = -73.9945
) -> CommunityPin {
    let segmentIdJSON = segmentId.map { "\"\($0)\"" } ?? "null"
    let positionFractionJSON = positionFraction.map { String($0) } ?? "null"
    let json = """
    {
      "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
      "pin_type": "enforcement_active",
      "source": "crowd",
      "lifespan": "ephemeral",
      "lat": \(lat),
      "lng": \(lng),
      "segment_id": \(segmentIdJSON),
      "position_fraction": \(positionFractionJSON),
      "author_id": null,
      "author_username": null,
      "created_at": "2026-06-01T12:00:00Z",
      "updated_at": "2026-06-01T12:00:00Z",
      "expires_at": null,
      "resolved_at": null,
      "confirm_count": 0,
      "dispute_count": 0,
      "meta": null,
      "notes": null
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(CommunityPin.self, from: json)
}

// MARK: - CandidateSegmentSearch.coordinate(atFraction:along:)

final class CoordinateAtFractionTests: XCTestCase {

    /// A straight, ~84m two-point east-west line — easy fraction math (constant latitude,
    /// varying longitude only). Matches `NearestSegmentSnapTests.straightLine()`'s fixture.
    private let straightLine: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9950),
        CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9940)
    ]

    func testCoordinateAtFraction_zero_returnsFirstVertex() {
        let result = CandidateSegmentSearch.coordinate(atFraction: 0.0, along: straightLine)
        XCTAssertEqual(result?.latitude ?? -1, 40.7230, accuracy: 0.0001)
        XCTAssertEqual(result?.longitude ?? -1, -73.9950, accuracy: 0.0001)
    }

    func testCoordinateAtFraction_one_returnsLastVertex() {
        let result = CandidateSegmentSearch.coordinate(atFraction: 1.0, along: straightLine)
        XCTAssertEqual(result?.latitude ?? -1, 40.7230, accuracy: 0.0001)
        XCTAssertEqual(result?.longitude ?? -1, -73.9940, accuracy: 0.0001)
    }

    func testCoordinateAtFraction_half_returnsMidpointOnStraightLine() {
        let result = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: straightLine)
        XCTAssertEqual(result?.longitude ?? -1, -73.9945, accuracy: 0.0001,
            "Midpoint of a straight 2-point line must be the arithmetic average longitude")
    }

    /// Clamping — a stored `positionFraction` should never be negative in practice, but
    /// display-time must never extrapolate PAST the first vertex on malformed data.
    func testCoordinateAtFraction_negativeClampedToZero() {
        let atNegative = CandidateSegmentSearch.coordinate(atFraction: -0.5, along: straightLine)
        let atZero = CandidateSegmentSearch.coordinate(atFraction: 0.0, along: straightLine)
        XCTAssertEqual(atNegative?.latitude, atZero?.latitude)
        XCTAssertEqual(atNegative?.longitude, atZero?.longitude)
    }

    func testCoordinateAtFraction_aboveOneClampedToOne() {
        let atTwo = CandidateSegmentSearch.coordinate(atFraction: 2.0, along: straightLine)
        let atOne = CandidateSegmentSearch.coordinate(atFraction: 1.0, along: straightLine)
        XCTAssertEqual(atTwo?.latitude, atOne?.latitude)
        XCTAssertEqual(atTwo?.longitude, atOne?.longitude)
    }

    /// 3-vertex polyline with an unequal split (short first leg ~8.4m, long second leg
    /// ~413m, both collinear) — fraction 0.5 must land based on CUMULATIVE length across
    /// both legs, not a naive per-vertex-index split (which would incorrectly place 0.5 at
    /// the joint vertex, ~8.4m / ~421m ≈ 0.02 along the real line).
    func testCoordinateAtFraction_multiVertexPolyline_respectsCumulativeLength() {
        let polyline = [
            CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9950),
            CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9949),
            CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9900)
        ]
        let result = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: polyline)
        // At the halfway point of ~421m total, we should be well past the short first leg,
        // deep into the second leg — closer to -73.9925 than to the joint vertex -73.9949.
        XCTAssertNotNil(result)
        XCTAssertLessThan(result?.longitude ?? 0, -73.9920,
            "Fraction 0.5 must reflect cumulative length across both legs, not stop at the short first leg's joint vertex")
    }

    func testCoordinateAtFraction_degeneratePolyline_returnsNil() {
        let result = CandidateSegmentSearch.coordinate(
            atFraction: 0.5, along: [CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9950)]
        )
        XCTAssertNil(result, "A single-vertex polyline has nothing to project onto")
    }
}

// MARK: - CommunityPinAnnotation.resolveDisplayCoordinate(for:segmentByID:) — AC-1 through AC-3

final class ResolveDisplayCoordinateTests: XCTestCase {

    private let line: [[Double]] = [[40.7230, -73.9950], [40.7230, -73.9940]]

    /// AC-2: `positionFraction` present + segment resolves → interpolated point, NOT a fresh
    /// nearest-point projection of the raw (off-line) lat/lng.
    func testResolveDisplayCoordinate_positionFractionPresent_interpolatesAlongPolyline() {
        let segment = fixtureSegment(id: "seg-1", line: line)
        // Raw lat/lng is deliberately off the line (perpendicular offset) — if the fraction
        // branch were bypassed in favor of nearest-point, the result would differ.
        let pin = fixturePin(segmentId: "seg-1", positionFraction: 0.5, lat: 40.7250, lng: -73.9945)

        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            for: pin, segmentByID: ["seg-1": segment]
        )
        XCTAssertEqual(result.latitude, 40.7230, accuracy: 0.0001, "Must land ON the polyline's latitude, not the raw off-line lat")
        XCTAssertEqual(result.longitude, -73.9945, accuracy: 0.0001, "Fraction 0.5 on this straight line is the midpoint longitude")
    }

    /// AC-1: no `positionFraction` + segment resolves → nearest-point projection of the raw
    /// lat/lng onto the polyline.
    func testResolveDisplayCoordinate_noPositionFraction_projectsRawCoordOntoPolyline() {
        let segment = fixtureSegment(id: "seg-1", line: line)
        // ~11m north of the line's midpoint — nearest-point projection should land back on
        // the line at (approximately) the same longitude.
        let pin = fixturePin(segmentId: "seg-1", positionFraction: nil, lat: 40.7231, lng: -73.9945)

        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            for: pin, segmentByID: ["seg-1": segment]
        )
        XCTAssertEqual(result.latitude, 40.7230, accuracy: 0.0001, "Nearest-point projection must land ON the line's latitude")
        XCTAssertEqual(result.longitude, -73.9945, accuracy: 0.0001)
        XCTAssertNotEqual(result.latitude, pin.lat, "Must NOT render at the raw, off-line latitude")
    }

    /// AC-3: nil `segmentId` → raw lat/lng, unchanged (OD-1).
    func testResolveDisplayCoordinate_nilSegmentId_fallsBackToRawLatLng() {
        let pin = fixturePin(segmentId: nil, positionFraction: nil, lat: 40.7231, lng: -73.9945)
        let result = CommunityPinAnnotation.resolveDisplayCoordinate(for: pin, segmentByID: [:])
        XCTAssertEqual(result.latitude, pin.lat)
        XCTAssertEqual(result.longitude, pin.lng)
    }

    /// AC-3: `segmentId` doesn't resolve against the currently-loaded tile set (stale
    /// boundary / OD-1) → raw lat/lng, unchanged.
    func testResolveDisplayCoordinate_segmentIdNotInLoadedSet_fallsBackToRawLatLng() {
        let pin = fixturePin(segmentId: "not-loaded", positionFraction: 0.5, lat: 40.7231, lng: -73.9945)
        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            for: pin, segmentByID: ["other-segment": fixtureSegment(id: "other-segment", line: line)]
        )
        XCTAssertEqual(result.latitude, pin.lat)
        XCTAssertEqual(result.longitude, pin.lng)
    }

    /// A resolved segment with a degenerate (< 2 vertex) polyline has nothing to project
    /// onto — must fall back to raw lat/lng, never crash.
    func testResolveDisplayCoordinate_degenerateSegmentPolyline_fallsBackToRawLatLng() {
        let segment = fixtureSegment(id: "seg-1", line: [[40.7230, -73.9950]])
        let pin = fixturePin(segmentId: "seg-1", positionFraction: 0.5, lat: 40.7231, lng: -73.9945)
        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            for: pin, segmentByID: ["seg-1": segment]
        )
        XCTAssertEqual(result.latitude, pin.lat)
        XCTAssertEqual(result.longitude, pin.lng)
    }
}

// MARK: - ReportSheet.showsRepositionAffordance(communityEnabled:selectedType:allowsReposition:) — AC-7/AC-8

final class ShowsRepositionAffordanceTests: XCTestCase {

    func testShowsRepositionAffordance_flagOff_false() {
        XCTAssertFalse(ReportSheet.showsRepositionAffordance(
            communityEnabled: false, selectedType: .enforcementActive, allowsReposition: true
        ))
    }

    /// AC-8: the in-drive Report button passes `allowsReposition: false` — must hide
    /// regardless of flag/type state.
    func testShowsRepositionAffordance_allowsRepositionFalse_false() {
        XCTAssertFalse(ReportSheet.showsRepositionAffordance(
            communityEnabled: true, selectedType: .enforcementActive, allowsReposition: false
        ))
    }

    func testShowsRepositionAffordance_noTypeSelected_false() {
        XCTAssertFalse(ReportSheet.showsRepositionAffordance(
            communityEnabled: true, selectedType: nil, allowsReposition: true
        ))
    }

    /// AC-7: shows even conceptually when no segment resolved (this function doesn't take
    /// candidates at all — deliberately, per spec §3.1 — so OD-1 can't gate it off).
    func testShowsRepositionAffordance_enforcementActive_true() {
        XCTAssertTrue(ReportSheet.showsRepositionAffordance(
            communityEnabled: true, selectedType: .enforcementActive, allowsReposition: true
        ))
    }

    func testShowsRepositionAffordance_sweeper_true() {
        XCTAssertTrue(ReportSheet.showsRepositionAffordance(
            communityEnabled: true, selectedType: .sweeper, allowsReposition: true
        ))
    }
}

// MARK: - ReportSheet.effectiveCoordinate(original:repositioned:) — AC-10/AC-13

final class EffectiveCoordinateTests: XCTestCase {

    func testEffectiveCoordinate_neverRepositioned_returnsOriginal() {
        let original = CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99)
        let result = ReportSheet.effectiveCoordinate(original: original, repositioned: nil)
        XCTAssertEqual(result.latitude, original.latitude)
        XCTAssertEqual(result.longitude, original.longitude)
    }

    func testEffectiveCoordinate_repositioned_returnsRepositionedPoint() {
        let original = CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99)
        let repositioned = CLLocationCoordinate2D(latitude: 40.73, longitude: -73.98)
        let result = ReportSheet.effectiveCoordinate(original: original, repositioned: repositioned)
        XCTAssertEqual(result.latitude, repositioned.latitude)
        XCTAssertEqual(result.longitude, repositioned.longitude)
    }
}

// MARK: - CandidateSegmentSearch.reportRepositionCandidates(forTap:lng:in:radius:) — AC-9/AC-11

final class ReportRepositionCandidatesTests: XCTestCase {

    func testReportRepositionCandidates_withinRadius_findsSegmentAndCandidates() {
        // `opposite` is deliberately given a DIFFERENT (far-away) line — only its
        // street/cross-street/side identity matters for confirmStreetCandidates' own
        // opposite-curb match; giving it the SAME line as `current` would make the nearest-
        // segment lookup's winner an order-dependent tie (both have identical distance-to-tap),
        // which is not what this test is asserting.
        let current = fixtureSegment(id: "current", from: "SPRING STREET", to: "BROOME STREET", side: "E")
        let opposite = fixtureSegment(
            id: "opposite", from: "SPRING STREET", to: "BROOME STREET", side: "W",
            line: [[40.7250, -73.9950], [40.7250, -73.9940]]
        )

        let result = CandidateSegmentSearch.reportRepositionCandidates(
            forTap: 40.7230, lng: -73.9945, in: [current, opposite], radius: 35
        )
        XCTAssertEqual(result.segment?.id, "current")
        XCTAssertEqual(result.candidates.map(\.id), ["current", "opposite"])
    }

    /// AC-11: a tap beyond the radius must degrade gracefully — nil segment, empty
    /// candidates — never a crash, never a silently-adopted wrong segment.
    func testReportRepositionCandidates_outsideRadius_nilSegmentEmptyCandidates() {
        let segment = fixtureSegment(id: "far")
        // ~110m away — well outside a 35m radius (same convention as this suite's other
        // "35m bound" tests).
        let result = CandidateSegmentSearch.reportRepositionCandidates(
            forTap: 40.7240, lng: -73.9945, in: [segment], radius: 35
        )
        XCTAssertNil(result.segment)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testReportRepositionCandidates_emptySegments_nilSegmentEmptyCandidates() {
        let result = CandidateSegmentSearch.reportRepositionCandidates(
            forTap: 40.7230, lng: -73.9945, in: [], radius: 35
        )
        XCTAssertNil(result.segment)
        XCTAssertTrue(result.candidates.isEmpty)
    }
}

// MARK: - ActiveSheet.reportPin id stability — THE landmine (spec §3.2)

/// Directly verifies the precondition the whole `ReportRepositionUpdate` design relies on:
/// `ActiveSheet.reportPin`'s `Identifiable.id` is keyed ONLY off `coord` — reassigning
/// `segment`/`confirmCandidates`/`streetName`/`coordinateSource` (which this feature never
/// does) would NOT tear down the sheet, but reassigning `coord` (which this feature also
/// never does — the actual landmine) WOULD. Both halves are asserted so a future change that
/// accidentally widens or narrows `id`'s dependency set is caught here, not live.
final class ActiveSheetReportPinIdStabilityTests: XCTestCase {

    func testActiveSheetReportPinId_dependsOnlyOnCoordinate_notSegmentCandidatesOrSource() {
        let coord = CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9945)
        let segment = fixtureSegment(id: "seg-1")
        let a = ActiveSheet.reportPin(
            coord: coord, streetName: "Mott St", segment: nil,
            confirmCandidates: [], coordinateSource: "long-press (resting)"
        )
        let b = ActiveSheet.reportPin(
            coord: coord, streetName: "Spring St", segment: segment,
            confirmCandidates: [segment], coordinateSource: "current GPS (in-drive)"
        )
        XCTAssertEqual(a.id, b.id,
            "id must depend ONLY on coord — this is what makes pushing an update through repositionUpdate (never touching coord) safe")
    }

    func testActiveSheetReportPinId_changesWhenCoordinateChanges() {
        let a = ActiveSheet.reportPin(coord: CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9945), streetName: nil)
        let b = ActiveSheet.reportPin(coord: CLLocationCoordinate2D(latitude: 40.7231, longitude: -73.9946), streetName: nil)
        XCTAssertNotEqual(a.id, b.id,
            "id DOES change with coord — this is exactly why a reposition must never reassign ActiveSheet.reportPin's own coord payload (spec §3.2's landmine)")
    }
}

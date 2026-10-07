//
//  CurbSnapDisplayTests.swift
//  WeParkTests
//
//  Open item #22 — docs/report-tap-to-place-spec.md §2. Pure-logic tests for the
//  curb-snap-on-display half ONLY (display-time projection). This is the half of PR #118
//  carved into its own PR (ios/curb-snap-display) per Kevin's split decision — the OTHER
//  half of #118 (the ReportSheet placement-flow affordance/detent machinery and its own
//  CandidateSegmentSearch candidate-search helper) stays on the original branch
//  (ios/report-tap-to-place) and is NOT duplicated here.
//
//  CandidateSegmentSearch.coordinate(atFraction:along:) — the fraction-walk helper:
//    1.  testCoordinateAtFraction_zero_returnsFirstVertex
//    2.  testCoordinateAtFraction_one_returnsLastVertex
//    3.  testCoordinateAtFraction_half_returnsMidpointOnStraightLine
//    4.  testCoordinateAtFraction_negativeClampedToZero
//    5.  testCoordinateAtFraction_aboveOneClampedToOne
//    6.  testCoordinateAtFraction_multiVertexPolyline_respectsCumulativeLength
//    7.  testCoordinateAtFraction_degeneratePolyline_returnsNil
//
//  CommunityPinAnnotation.resolveDisplayCoordinate(for:segmentByID:) — AC-1 through AC-3:
//    8.  testResolveDisplayCoordinate_positionFractionPresent_interpolatesAlongPolyline
//    9.  testResolveDisplayCoordinate_noPositionFraction_projectsRawCoordOntoPolyline
//    10. testResolveDisplayCoordinate_nilSegmentId_fallsBackToRawLatLng
//    11. testResolveDisplayCoordinate_segmentIdNotInLoadedSet_fallsBackToRawLatLng
//    12. testResolveDisplayCoordinate_degenerateSegmentPolyline_fallsBackToRawLatLng
//
//  CommunityPinAnnotation.resolveDisplayCoordinate(lat:lng:segmentId:positionFraction:
//  segmentByID:) — Kevin's live gate on PR #118, finding F2 — the primitive overload
//  MapViewRepresentable.Coordinator.syncCarPin uses for the parked-car marker (no
//  CommunityPin involved):
//    13. testResolveDisplayCoordinate_carPinShape_nilSegmentId_fallsBackToRawLatLng
//    14. testResolveDisplayCoordinate_carPinShape_segmentResolves_projectsOntoCurb
//
//  CommunityPinAnnotation.resolveCarDisplayCoordinate(lat:lng:segmentId:segmentByID:
//  segments:nearestSegmentRadius:) — live-gate RE-repro (Bowery btwn Houston/Stanton): the
//  primitive overload's raw fallback above turned out to be the COMMON case for an
//  arrival-path parked car (`detectedSegmentID` is always nil on that path), not a rare
//  edge case, so it reproduced the original in-building bug. This function adds a
//  nearest-loaded-segment fallback for the car path ONLY — community pins are unaffected,
//  they still call `resolveDisplayCoordinate` directly (tests 8-14 above, unchanged):
//    15. testResolveCarDisplayCoordinate_nilSegmentId_nearestLoadedSegmentWithinRadius_snapsToCurb
//    16. testResolveCarDisplayCoordinate_nilSegmentId_nothingWithinRadius_fallsBackToRaw
//    17. testResolveCarDisplayCoordinate_detectedSegmentResolves_winsOverNearerLoadedSegment
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

// MARK: - CommunityPinAnnotation.resolveDisplayCoordinate(lat:lng:segmentId:positionFraction:segmentByID:)
// Kevin's live gate on PR #118, finding F2: the primitive overload, exercised directly
// (no `CommunityPin` involved) — this is the exact call shape
// `MapViewRepresentable.Coordinator.syncCarPin` uses for the parked-car marker.

final class ResolveDisplayCoordinatePrimitiveCarPinShapeTests: XCTestCase {

    private let line: [[Double]] = [[40.7230, -73.9950], [40.7230, -73.9940]]

    /// The car path's fallback: no resolvable segment (nil `detectedSegmentID`, or a
    /// segment id that isn't in the currently-loaded tile set) → the raw stored
    /// `latitude`/`longitude`, unchanged — same AC-3 contract as the pin-shaped overload.
    func testResolveDisplayCoordinate_carPinShape_nilSegmentId_fallsBackToRawLatLng() {
        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            lat: 40.7231, lng: -73.9945, segmentId: nil, positionFraction: nil, segmentByID: [:]
        )
        XCTAssertEqual(result.latitude, 40.7231)
        XCTAssertEqual(result.longitude, -73.9945)
    }

    /// THE bug Kevin found live: a parked car with a resolved `detectedSegmentID` rendering
    /// at its raw (off-curb, "inside a building") coordinate. With a resolvable segment and
    /// `positionFraction: nil` (parked cars are never fraction-placed), the marker must
    /// project onto the segment's polyline via nearest-point projection — landing ON the
    /// curb, not at the raw tap/GPS point.
    func testResolveDisplayCoordinate_carPinShape_segmentResolves_projectsOntoCurb() {
        let segment = fixtureSegment(id: "car-seg", line: line)
        let result = CommunityPinAnnotation.resolveDisplayCoordinate(
            lat: 40.7231, lng: -73.9945, segmentId: "car-seg", positionFraction: nil,
            segmentByID: ["car-seg": segment]
        )
        XCTAssertEqual(result.latitude, 40.7230, accuracy: 0.0001,
            "Parked-car marker must project onto its resolved segment's curb, not render at the raw off-line coordinate")
        XCTAssertEqual(result.longitude, -73.9945, accuracy: 0.0001)
    }
}

// MARK: - CommunityPinAnnotation.resolveCarDisplayCoordinate(lat:lng:segmentId:segmentByID:segments:nearestSegmentRadius:)
// Live-gate re-repro (Bowery btwn Houston/Stanton, mid-block car rendering inside a
// building): `resolveDisplayCoordinate`'s raw fallback is the COMMON case for an
// arrival-path parked car (`detectedSegmentID` is always nil on that path,
// `ContentView.swift`'s `onParkHere`) — not a rare edge case. `syncCarPin` now calls THIS
// function instead, which adds a nearest-loaded-segment fallback on top for cars only.
// Community pins are unaffected — they keep calling `resolveDisplayCoordinate` directly.

final class ResolveCarDisplayCoordinateTests: XCTestCase {

    /// A loaded segment near the car's raw coordinate (~11m away, same offset convention as
    /// `ResolveDisplayCoordinateTests`'s `noPositionFraction` case) — the fallback's target.
    private let nearLine: [[Double]] = [[40.7230, -73.9950], [40.7230, -73.9940]]

    /// A loaded segment far from the car's raw coordinate (~334m north — well past any
    /// plausible snap radius) — stands in for "the only tile loaded is nowhere near the
    /// car," proving the far segment is never mistakenly chosen.
    private let farLine: [[Double]] = [[40.7260, -73.9950], [40.7260, -73.9940]]

    /// THE Bowery repro, reduced to a unit test: `detectedSegmentID` is nil (arrival-path
    /// car), but a real curb segment IS loaded nearby. The marker must snap to that
    /// segment's nearest point, not render at the raw in-building coordinate.
    func testResolveCarDisplayCoordinate_nilSegmentId_nearestLoadedSegmentWithinRadius_snapsToCurb() {
        let nearSegment = fixtureSegment(id: "near-seg", line: nearLine)
        let farSegment = fixtureSegment(id: "far-seg", line: farLine)

        let result = CommunityPinAnnotation.resolveCarDisplayCoordinate(
            lat: 40.7231, lng: -73.9945,
            segmentId: nil,
            segmentByID: [:],
            segments: [nearSegment, farSegment],
            nearestSegmentRadius: 35
        )
        XCTAssertEqual(result.latitude, 40.7230, accuracy: 0.0001,
            "Must snap to the nearest LOADED segment's curb, not stay at the raw in-building coordinate")
        XCTAssertEqual(result.longitude, -73.9945, accuracy: 0.0001)
    }

    /// AC-3-equivalent for the car path: nothing loaded within radius (sparse tile coverage,
    /// no tiles loaded yet) — must degrade to raw, never snap across the map to an unrelated
    /// curb far outside the search radius.
    func testResolveCarDisplayCoordinate_nilSegmentId_nothingWithinRadius_fallsBackToRaw() {
        let farSegment = fixtureSegment(id: "far-seg", line: farLine)

        let result = CommunityPinAnnotation.resolveCarDisplayCoordinate(
            lat: 40.7231, lng: -73.9945,
            segmentId: nil,
            segmentByID: [:],
            segments: [farSegment],
            nearestSegmentRadius: 35
        )
        XCTAssertEqual(result.latitude, 40.7231,
            "No segment within radius — must fall back to the raw, unchanged latitude")
        XCTAssertEqual(result.longitude, -73.9945,
            "No segment within radius — must fall back to the raw, unchanged longitude")
    }

    /// Regression guard: a resolved `detectedSegmentID` must still win outright, even when a
    /// DIFFERENT, closer segment exists in the loaded `segments` list — the nearest-segment
    /// search is a fallback for the no-stored-segment case only, never a second opinion that
    /// overrides a real detection.
    func testResolveCarDisplayCoordinate_detectedSegmentResolves_winsOverNearerLoadedSegment() {
        let detectedSegment = fixtureSegment(id: "detected-seg", line: nearLine)
        // Passes directly through the car's raw coordinate (distance 0) — if the
        // implementation ever ran the nearest-segment search instead of honoring the
        // resolved `segmentId`, this decoy would win and the assertion below would fail.
        let decoySegment = fixtureSegment(
            id: "decoy-seg", line: [[40.7231, -73.9945], [40.7231, -73.9944]]
        )

        let result = CommunityPinAnnotation.resolveCarDisplayCoordinate(
            lat: 40.7231, lng: -73.9945,
            segmentId: "detected-seg",
            segmentByID: ["detected-seg": detectedSegment],
            segments: [decoySegment],
            nearestSegmentRadius: 35
        )
        XCTAssertEqual(result.latitude, 40.7230, accuracy: 0.0001,
            "A resolved detectedSegmentID must win outright — never overridden by a nearest-segment search")
        XCTAssertEqual(result.longitude, -73.9945, accuracy: 0.0001)
    }
}

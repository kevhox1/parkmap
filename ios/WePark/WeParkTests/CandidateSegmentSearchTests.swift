//
//  CandidateSegmentSearchTests.swift
//  WeParkTests
//
//  Community 2.0 Phase 2a (build 20 S6) — tests for the extracted W5 candidate-search
//  helper (`CandidateSegmentSearch`), covering both the pre-existing "Wrong street?"
//  35m-alternatives algorithm (now a standalone function, behavior-preserving extraction)
//  and the new "confirm the street" candidate-list construction (current segment +
//  opposite curb + one neighbor each direction).
//
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (11 tests):
//    findCandidateSegments(lat:lng:in:radius:max:) — extraction parity:
//      1. testFindCandidateSegments_withinRadius_included
//      2. testFindCandidateSegments_outsideRadius_excluded            ("35m bound")
//      3. testFindCandidateSegments_dedupesByBlockKey_keepsClosest
//      4. testFindCandidateSegments_sortsNearestFirst_respectsMax
//
//    confirmStreetCandidates(for:in:) — Community 2.0 Phase 2a candidate-list construction:
//      5. testConfirmStreetCandidates_matchesScreenshotFixture_allFourFound
//      6. testConfirmStreetCandidates_onlyOppositeLoaded_returnsTwo
//      7. testConfirmStreetCandidates_noneOtherLoaded_returnsJustCurrent
//      8. testConfirmStreetCandidates_dedupesWhenBothNeighborSearchesMatchSameSegment
//
//    oppositeSideCandidate(of:in:) / neighborSegment(of:sharingCrossStreet:in:):
//      9.  testOppositeSideCandidate_sameSideNotMatched
//      10. testNeighborSegment_noMatch_returnsNil
//      11. testNeighborSegment_ignoresOtherSide
//
//  Community 2.0 Phase 2b (build 20 S7) additions — nearestSegmentSnap(lat:lng:in:radius:),
//  spot-placement curb-snap + position-fraction math (spec §3 Phase 2):
//    12. testNearestSegmentSnap_tapAtFromEndpoint_fractionNearZero
//    13. testNearestSegmentSnap_tapAtMidpoint_fractionNearHalf
//    14. testNearestSegmentSnap_tapAtToEndpoint_fractionNearOne
//    15. testNearestSegmentSnap_tapOutsideRadius_returnsNil
//    16. testNearestSegmentSnap_offsetFromLine_withinRadius_sameFractionSmallDistance
//    17. testNearestSegmentSnap_multipleSegments_picksClosest
//    18. testNearestSegmentSnap_multiVertexPolyline_cumulativeFractionNotPerSubSegment
//    19. testNearestSegmentSnap_emptySegments_returnsNil
//
//  Baseline before this suite: see PR body for the running total.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixture helpers

/// Builds a minimal two-point `Segment` at an explicit coordinate pair — mirrors
/// `FT11DirectionTests.makeSegment(from:to:)`'s pattern (this project's established
/// lightweight-Segment-fixture convention; the direct `Segment(...)` initializer, not a
/// JSON decode, since none of these tests need to exercise `Codable`).
private func candidateFixtureSegment(
    id: String,
    street: String,
    from: String,
    to: String,
    side: String,
    line: [[Double]] = [[40.7230, -73.9950], [40.7232, -73.9948]]
) -> Segment {
    Segment(
        id: id,
        street: street,
        fromStreet: from,
        to: to,
        side: side,
        line: line,
        rules: [],
        dominantCategory: nil
    )
}

// MARK: - findCandidateSegments (extraction parity)

final class FindCandidateSegmentsExtractionTests: XCTestCase {

    /// ~10m north of a segment running along the same latitude — well within the 35m
    /// radius this function is always called with in production (`pinDropRadiusMeters`).
    func testFindCandidateSegments_withinRadius_included() {
        let seg = candidateFixtureSegment(
            id: "A", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
        // ~0.0001 deg lat ≈ 11m north of the line.
        let result = CandidateSegmentSearch.findCandidateSegments(
            lat: 40.7231, lng: -73.9945, in: [seg], radius: 35, max: 4
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.segment.id, "A")
    }

    /// ~110m away — well outside a 35m radius ("35m bound" per the dispatch spec).
    func testFindCandidateSegments_outsideRadius_excluded() {
        let seg = candidateFixtureSegment(
            id: "A", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
        // ~0.001 deg lat ≈ 111m north of the line — outside the 35m radius.
        let result = CandidateSegmentSearch.findCandidateSegments(
            lat: 40.7240, lng: -73.9945, in: [seg], radius: 35, max: 4
        )
        XCTAssertTrue(result.isEmpty, "A segment ~110m away must not pass a 35m radius filter")
    }

    /// Two `Segment` rows sharing the same block key (street|from|to) — e.g. sub-segments
    /// of one long blockface — must collapse to the single closest one.
    func testFindCandidateSegments_dedupesByBlockKey_keepsClosest() {
        let near = candidateFixtureSegment(
            id: "near", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
        let far = candidateFixtureSegment(
            id: "far", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7233, -73.9950], [40.7233, -73.9940]]
        )
        let result = CandidateSegmentSearch.findCandidateSegments(
            lat: 40.7230, lng: -73.9945, in: [near, far], radius: 35, max: 4
        )
        XCTAssertEqual(result.count, 1, "Same block key (street|from|to) must dedupe to one result")
        XCTAssertEqual(result.first?.segment.id, "near", "Dedup must keep the CLOSER of the two")
    }

    /// Multiple distinct BLOCKS (different streets — the block-key dedup is
    /// street|from|to, deliberately side-agnostic, unchanged from the pre-extraction
    /// algorithm) within radius: nearest-first ordering, capped at `max`.
    func testFindCandidateSegments_sortsNearestFirst_respectsMax() {
        let a = candidateFixtureSegment(
            id: "A", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
        let b = candidateFixtureSegment(
            id: "B", street: "MULBERRY STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.72305, -73.9950], [40.72305, -73.9940]]
        )
        let c = candidateFixtureSegment(
            id: "C", street: "ELIZABETH STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7231, -73.9950], [40.7231, -73.9940]]
        )
        let result = CandidateSegmentSearch.findCandidateSegments(
            lat: 40.7230, lng: -73.9945, in: [a, b, c], radius: 35, max: 2
        )
        XCTAssertEqual(result.count, 2, "max: 2 must cap the result count")
        XCTAssertEqual(result.first?.segment.id, "A", "Nearest-first: A is on the query latitude exactly")
    }
}

// MARK: - confirmStreetCandidates(for:in:) — Community 2.0 Phase 2a

final class ConfirmStreetCandidatesTests: XCTestCase {

    /// Fixtures matching design/screenshots/09-report-confirm-street.png exactly:
    /// Mott St — East side (current, btwn Spring & Broome), West side (opposite),
    /// East side btwn Prince & Spring (neighbor toward "from"), East side btwn Broome &
    /// Grand (neighbor toward "to").
    func testConfirmStreetCandidates_matchesScreenshotFixture_allFourFound() {
        let current  = candidateFixtureSegment(id: "current",  street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")
        let opposite = candidateFixtureSegment(id: "opposite", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "W")
        let towardFrom = candidateFixtureSegment(id: "towardFrom", street: "MOTT STREET", from: "PRINCE STREET", to: "SPRING STREET", side: "E")
        let towardTo   = candidateFixtureSegment(id: "towardTo",   street: "MOTT STREET", from: "BROOME STREET", to: "GRAND STREET",  side: "E")
        let unrelated  = candidateFixtureSegment(id: "unrelated", street: "MULBERRY STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")

        let result = CandidateSegmentSearch.confirmStreetCandidates(
            for: current, in: [current, opposite, towardFrom, towardTo, unrelated]
        )

        XCTAssertEqual(result.map(\.id), ["current", "opposite", "towardFrom", "towardTo"],
                        "Order must be: current, opposite curb, neighbor toward from, neighbor toward to")
    }

    /// Only the current segment + its opposite curb are loaded — no neighbors found.
    func testConfirmStreetCandidates_onlyOppositeLoaded_returnsTwo() {
        let current  = candidateFixtureSegment(id: "current",  street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")
        let opposite = candidateFixtureSegment(id: "opposite", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "W")

        let result = CandidateSegmentSearch.confirmStreetCandidates(for: current, in: [current, opposite])

        XCTAssertEqual(result.map(\.id), ["current", "opposite"])
    }

    /// Sparse tile coverage: nothing else loaded on this street at all — the list is just
    /// the current segment, never a placeholder row or a crash.
    func testConfirmStreetCandidates_noneOtherLoaded_returnsJustCurrent() {
        let current = candidateFixtureSegment(id: "current", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")

        let result = CandidateSegmentSearch.confirmStreetCandidates(for: current, in: [current])

        XCTAssertEqual(result.map(\.id), ["current"])
    }

    /// Degenerate "loop" block (fromStreet == to, an unusual but representable tile data
    /// case) makes both neighbor searches query the SAME cross-street value and therefore
    /// find the SAME candidate segment twice — the dedup-by-blockfaceKey guard must keep
    /// only one copy in the result.
    func testConfirmStreetCandidates_dedupesWhenBothNeighborSearchesMatchSameSegment() {
        let current = candidateFixtureSegment(
            id: "current", street: "LOOP STREET", from: "ANCHOR STREET", to: "ANCHOR STREET", side: "E"
        )
        let neighbor = candidateFixtureSegment(
            id: "neighbor", street: "LOOP STREET", from: "OTHER STREET", to: "ANCHOR STREET", side: "E"
        )

        let result = CandidateSegmentSearch.confirmStreetCandidates(for: current, in: [current, neighbor])

        XCTAssertEqual(result.map(\.id), ["current", "neighbor"],
                        "The same neighbor must not be appended twice even when both cross-street lookups match it")
    }
}

// MARK: - oppositeSideCandidate(of:in:) / neighborSegment(of:sharingCrossStreet:in:)

final class CandidateSegmentSearchPredicateTests: XCTestCase {

    func testOppositeSideCandidate_sameSideNotMatched() {
        let a = candidateFixtureSegment(id: "1", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")
        let b = candidateFixtureSegment(id: "2", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")

        let result = CandidateSegmentSearch.oppositeSideCandidate(of: a, in: [a, b])
        XCTAssertNil(result, "A segment with the SAME side must never match as its own opposite")
    }

    func testNeighborSegment_noMatch_returnsNil() {
        let a = candidateFixtureSegment(id: "1", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")

        let result = CandidateSegmentSearch.neighborSegment(of: a, sharingCrossStreet: "SPRING STREET", in: [a])
        XCTAssertNil(result, "No other segment loaded on this street → nil, not a crash")
    }

    func testNeighborSegment_ignoresOtherSide() {
        let a = candidateFixtureSegment(id: "1", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E")
        // Shares the "SPRING STREET" cross-street but on the WEST side — must not count as a
        // same-side neighbor (it's the opposite curb of a DIFFERENT block, not this one).
        let wrongSide = candidateFixtureSegment(id: "2", street: "MOTT STREET", from: "PRINCE STREET", to: "SPRING STREET", side: "W")

        let result = CandidateSegmentSearch.neighborSegment(of: a, sharingCrossStreet: "SPRING STREET", in: [a, wrongSide])
        XCTAssertNil(result)
    }
}

// MARK: - nearestSegmentSnap(lat:lng:in:radius:) — Community 2.0 Phase 2b (build 20 S7)

final class NearestSegmentSnapTests: XCTestCase {

    /// A straight, ~84m two-point east-west line at the query latitude — easy fraction math
    /// (constant latitude, varying longitude only).
    private func straightLine() -> Segment {
        candidateFixtureSegment(
            id: "line", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
    }

    func testNearestSegmentSnap_tapAtFromEndpoint_fractionNearZero() {
        let seg = straightLine()
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7230, lng: -73.9950, in: [seg], radius: 35
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.positionFraction ?? -1, 0.0, accuracy: 0.01)
        XCTAssertEqual(result?.distanceMeters ?? -1, 0.0, accuracy: 1.0)
        XCTAssertEqual(result?.segment.id, "line")
    }

    func testNearestSegmentSnap_tapAtMidpoint_fractionNearHalf() {
        let seg = straightLine()
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7230, lng: -73.9945, in: [seg], radius: 35
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.positionFraction ?? -1, 0.5, accuracy: 0.02)
    }

    func testNearestSegmentSnap_tapAtToEndpoint_fractionNearOne() {
        let seg = straightLine()
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7230, lng: -73.9940, in: [seg], radius: 35
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.positionFraction ?? -1, 1.0, accuracy: 0.01)
    }

    /// ~110m away — well outside a 35m radius (same "35m bound" convention as
    /// `testFindCandidateSegments_outsideRadius_excluded` above).
    func testNearestSegmentSnap_tapOutsideRadius_returnsNil() {
        let seg = straightLine()
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7240, lng: -73.9945, in: [seg], radius: 35
        )
        XCTAssertNil(result, "prototype.html:821 — a tap farther than the radius must return nil (\"Tap closer to a curb\")")
    }

    /// A tap ~11m perpendicular from the midpoint (within the 35m radius) must snap to the
    /// SAME fraction as tapping directly on the line at that point — the position fraction
    /// comes from the perpendicular PROJECTION onto the polyline, not the raw tap point.
    func testNearestSegmentSnap_offsetFromLine_withinRadius_sameFractionSmallDistance() {
        let seg = straightLine()
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.72310, lng: -73.9945, in: [seg], radius: 35
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.positionFraction ?? -1, 0.5, accuracy: 0.02)
        XCTAssertGreaterThan(result?.distanceMeters ?? 0, 5, "A perpendicular offset tap must report a non-trivial distance")
        XCTAssertLessThan(result?.distanceMeters ?? 999, 35, "Must still be within the search radius")
    }

    /// Two segments within radius — the CLOSER one must win, same "keep the nearest match"
    /// contract as `findCandidateSegments`'s own dedup-by-distance logic.
    func testNearestSegmentSnap_multipleSegments_picksClosest() {
        let near = candidateFixtureSegment(
            id: "near", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9940]]
        )
        let far = candidateFixtureSegment(
            id: "far", street: "MULBERRY STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7233, -73.9950], [40.7233, -73.9940]]
        )
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7230, lng: -73.9945, in: [near, far], radius: 35
        )
        XCTAssertEqual(result?.segment.id, "near")
    }

    /// A 3-vertex polyline (short first sub-segment ~8.4m, long second sub-segment
    /// ~413m — both collinear, so this reduces to the same overall line as the 2-point
    /// fixture above): a tap at the JOINT vertex must report a fraction reflecting
    /// CUMULATIVE length across both sub-segments (~0.02), not a naive per-sub-segment
    /// reset (which would read either 0.0 or 1.0 depending on which sub-segment "won").
    func testNearestSegmentSnap_multiVertexPolyline_cumulativeFractionNotPerSubSegment() {
        let seg = candidateFixtureSegment(
            id: "multi", street: "MOTT STREET", from: "SPRING STREET", to: "BROOME STREET", side: "E",
            line: [[40.7230, -73.9950], [40.7230, -73.9949], [40.7230, -73.9900]]
        )
        let result = CandidateSegmentSearch.nearestSegmentSnap(
            lat: 40.7230, lng: -73.9949, in: [seg], radius: 35
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.positionFraction ?? -1, 0.02, accuracy: 0.01,
            "Fraction at the joint vertex must reflect cumulative length (~8.4m / ~421m total), not a per-sub-segment reset to 0 or 1")
    }

    func testNearestSegmentSnap_emptySegments_returnsNil() {
        let result = CandidateSegmentSearch.nearestSegmentSnap(lat: 40.7230, lng: -73.9945, in: [], radius: 35)
        XCTAssertNil(result)
    }
}

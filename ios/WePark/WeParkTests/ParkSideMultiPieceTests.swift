//
//  ParkSideMultiPieceTests.swift
//  WeParkTests
//
//  PR #221 QA blocker: real blockfaces are split into several pieces per side (94% of sides in the
//  bundled tiles; Stanton Bowery-Chrystie is N_0..N_3 and S_0..S_3). The "other curb" must be the
//  piece that FACES the car, not the first piece on the other side. Synthetic multi-piece fixtures
//  (fast, exact) plus the REAL Stanton tiles, and a pin on the address probe direction for a real
//  blockface (Stanton Orchard-Ludlow: north side even, south side odd).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Synthetic multi-piece block

enum ParkSidePieceFixtures {

    /// Three pieces per side along x: [-100,-30], [-30,30], [30,100]. North at y = 12, south at y = 0.
    /// All six share the same street and cross-street pair (like the real tiles). `southFirst` flips
    /// the array order so a "first match" bug cannot hide behind ordering.
    static func block(oneway: Bool? = true, southFirst: Bool = true) -> [Segment] {
        let ranges: [(Double, Double)] = [(-100, -30), (-30, 30), (30, 100)]
        func pieces(side: String, y: Double) -> [Segment] {
            ranges.enumerated().map { index, range in
                let points = [(range.0, y), (range.1, y)].map { point -> [Double] in
                    let c = CurbSnapTestFixtures.coordinate(x: point.0, y: point.1)
                    return [c.latitude, c.longitude]
                }
                return Segment(
                    id: "\(side)_\(index)", street: "STANTON STREET", fromStreet: "BOWERY", to: "CHRYSTIE STREET",
                    side: side, line: points, rules: [], dominantCategory: nil, oneway: oneway
                )
            }
        }
        let south = pieces(side: "S", y: 0)
        let north = pieces(side: "N", y: 12)
        return southFirst ? south + north : north + south
    }
}

final class ParkSideMultiPieceTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fix(x: Double, y: Double, accuracy: Double) -> ParkTrackFix {
        ParkTrackFix(
            coordinate: CurbSnapTestFixtures.coordinate(x: x, y: y), speed: 0,
            horizontalAccuracy: accuracy, timestamp: now
        )
    }

    func testFacingOpposite_picksThePieceInFrontOfThePoint_notTheFirstOne() {
        for southFirst in [true, false] {
            let segments = ParkSidePieceFixtures.block(southFirst: southFirst)
            let north = segments.first { $0.id == "N_2" }
            XCTAssertNotNil(north)
            guard let north else { return }
            let point = CurbSnapTestFixtures.coordinate(x: 60, y: 12)
            guard let facing = ParkSideResolver.facingOpposite(of: north, near: point, in: segments) else {
                return XCTFail("expected an opposite piece")
            }
            XCTAssertEqual(facing.segment.id, "S_2", "southFirst=\(southFirst)")
            XCTAssertEqual(facing.snap.distanceMeters, 12, accuracy: 0.3)
            let along = ParkingAddressGeometry.distanceMeters(point, facing.snap.coordinate)
            XCTAssertEqual(along, 12, accuracy: 0.3, "straight across the street: no slide along the block")
        }
    }

    func testMidBlockPoint_atPieceBoundaries_staysOnTheNearestFacingPiece() {
        let segments = ParkSidePieceFixtures.block()
        let north = segments.first { $0.id == "N_1" }
        guard let north else { return XCTFail("missing N_1") }
        // x = 29 is inside N_1/S_1; x = 31 is inside N_2/S_2.
        let left = ParkSideResolver.facingOpposite(
            of: north, near: CurbSnapTestFixtures.coordinate(x: 29, y: 12), in: segments
        )
        XCTAssertEqual(left?.segment.id, "S_1")
        let right = ParkSideResolver.facingOpposite(
            of: north, near: CurbSnapTestFixtures.coordinate(x: 31, y: 12), in: segments
        )
        XCTAssertEqual(right?.segment.id, "S_2")
    }

    func testAsk_pairsTheCurbsThatFaceEachOther_atEveryPiece() {
        for southFirst in [true, false] {
            let segments = ParkSidePieceFixtures.block(southFirst: southFirst)
            for (x, index) in [(-65.0, 0), (0.0, 1), (60.0, 2)] {
                // Car mid-street, 8 m fix: too close to call.
                let decision = ParkSideResolver.decide(
                    fix: fix(x: x, y: 6, accuracy: 8), track: [], segments: segments, now: now
                )
                guard case .ask(let choice) = decision else {
                    XCTFail("x=\(x) southFirst=\(southFirst): expected .ask, got \(decision)")
                    continue
                }
                XCTAssertEqual(
                    Set([choice.first.segment.id, choice.second.segment.id]), ["S_\(index)", "N_\(index)"],
                    "x=\(x) southFirst=\(southFirst)"
                )
                let apart = ParkingAddressGeometry.distanceMeters(choice.first.coordinate, choice.second.coordinate)
                XCTAssertEqual(apart, 12, accuracy: 0.5, "the two feet are straight across, not a parallelogram")
            }
        }
    }

    func testFarPieceNeverMakesTheDecisionConfident() {
        // The QA repro: with first-match pairing, N_2 was paired with S_0 (60 m away) and went
        // confident. Now the pair is 12 m apart and an 8 m fix mid-street must ask.
        let segments = ParkSidePieceFixtures.block()
        let decision = ParkSideResolver.decide(
            fix: fix(x: 60, y: 6.5, accuracy: 8), track: [], segments: segments, now: now
        )
        guard case .ask = decision else { return XCTFail("expected .ask, got \(decision)") }
    }

    func testAccurateFixOnACurb_isStillConfident_onThePieceInFront() {
        let segments = ParkSidePieceFixtures.block()
        let decision = ParkSideResolver.decide(
            fix: fix(x: 60, y: 11.5, accuracy: 4), track: [], segments: segments, now: now
        )
        guard case .confident(let pick) = decision else { return XCTFail("expected .confident, got \(decision)") }
        XCTAssertEqual(pick.segment.id, "N_2")
    }

    func testSwitched_keepsThePositionAlongTheBlock_andFlippingBackReturns() {
        let segments = ParkSidePieceFixtures.block()
        guard let north = segments.first(where: { $0.id == "N_2" }),
              let snap = CandidateSegmentSearch.nearestPointOnPolyline(
                from: CurbSnapTestFixtures.coordinate(x: 55, y: 12), polyline: north.coordinates
              ) else { return XCTFail("missing fixture") }
        let here = ParkSideOption(segment: north, coordinate: snap.coordinate, fraction: snap.fraction)

        guard let across = ParkSideResolver.switched(from: here, in: segments) else {
            return XCTFail("expected the facing curb")
        }
        XCTAssertEqual(across.segment.id, "S_2")
        XCTAssertEqual(ParkingAddressGeometry.distanceMeters(here.coordinate, across.coordinate), 12, accuracy: 0.3)

        guard let back = ParkSideResolver.switched(from: across, in: segments) else {
            return XCTFail("expected the way back")
        }
        XCTAssertEqual(back.segment.id, "N_2")
        XCTAssertEqual(ParkingAddressGeometry.distanceMeters(here.coordinate, back.coordinate), 0, accuracy: 0.3)
    }

    func testCardModel_flipAndBack_returnsToTheOriginalPieceAndSpot() {
        let segments = ParkSidePieceFixtures.block()
        let decision = ParkSideResolver.decide(
            fix: fix(x: 60, y: 11.5, accuracy: 4), track: [], segments: segments, now: now
        )
        var model = WPParkSideCardModel(decision: decision, segments: segments)
        let original = model.selectedPick
        XCTAssertEqual(original?.segment.id, "N_2")
        model.switchSide()
        XCTAssertEqual(model.selectedPick?.segment.id, "S_2")
        model.switchSide()
        XCTAssertEqual(model.selectedPick?.segment.id, "N_2")
        XCTAssertEqual(model.selectedPick?.coordinate.latitude ?? 0, original?.coordinate.latitude ?? -1, accuracy: 1e-12)
        XCTAssertEqual(model.selectedPick?.coordinate.longitude ?? 0, original?.coordinate.longitude ?? -1, accuracy: 1e-12)
    }

    func testTokenPath_oppositeSnap_isTheFacingPiece() {
        let segments = ParkSidePieceFixtures.block()
        guard let north = segments.first(where: { $0.id == "N_2" }),
              let snap = CandidateSegmentSearch.nearestPointOnPolyline(
                from: CurbSnapTestFixtures.coordinate(x: 55, y: 12), polyline: north.coordinates
              ) else { return XCTFail("missing fixture") }
        let result = CurbSnapResult(
            segment: north, positionFraction: snap.fraction, distanceMeters: 2, snappedCoordinate: snap.coordinate
        )
        XCTAssertEqual(WPParkFlowController.oppositeSnap(of: result, in: segments)?.segment.id, "S_2")
    }

    func testNoParallelOrNoNearbyPiece_returnsNil() {
        let segments = ParkSidePieceFixtures.block()
        guard let north = segments.first(where: { $0.id == "N_1" }) else { return XCTFail("missing N_1") }
        let farAway = CurbSnapTestFixtures.coordinate(x: 0, y: 200)
        XCTAssertNil(ParkSideResolver.facingOpposite(of: north, near: farAway, in: segments))
        XCTAssertNil(ParkSideResolver.facingOpposite(of: north, near: farAway, in: [north]))
    }
}

// MARK: - Real Stanton tiles

final class ParkSideRealStantonTilesTests: XCTestCase {

    /// Every Stanton St segment in the bundled tiles (same `#filePath` precedent as
    /// `UnknownIsRestrictionTests`).
    private static func stantonSegments(reversed: Bool) throws -> [Segment] {
        let tilesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: tilesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [Segment] = []
        for file in files {
            let segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: file))
            all += segments.filter { $0.street == "STANTON STREET" }
        }
        return reversed ? all.reversed() : all
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func midpoint(_ segment: Segment) -> CLLocationCoordinate2D {
        let coords = segment.coordinates
        return CLLocationCoordinate2D(
            latitude: (coords[0].latitude + coords[coords.count - 1].latitude) / 2,
            longitude: (coords[0].longitude + coords[coords.count - 1].longitude) / 2
        )
    }

    /// The truly nearest same-block south piece to `point` (independent of the code under test).
    private func trueNearest(to point: CLLocationCoordinate2D, of north: Segment, in segments: [Segment]) -> Segment? {
        segments
            .filter { $0.side == "S" && $0.street == north.street && $0.fromStreet == north.fromStreet && $0.to == north.to }
            .min { lhs, rhs in
                (CandidateSegmentSearch.nearestPointOnPolyline(from: point, polyline: lhs.coordinates)?.distanceMeters ?? 1e9)
                    < (CandidateSegmentSearch.nearestPointOnPolyline(from: point, polyline: rhs.coordinates)?.distanceMeters ?? 1e9)
            }
    }

    func testBoweryChrystie_pieces_facingCurbIsInFront_inEitherTileOrder() throws {
        for reversed in [false, true] {
            let segments = try Self.stantonSegments(reversed: reversed)
            for id in ["N_1", "N_2", "N_3"] {
                let fullID = "STANTON_STREET_BOWERY_CHRYSTIE_STREET_\(id)"
                guard let north = segments.first(where: { $0.id == fullID }) else {
                    XCTFail("missing \(fullID)"); continue
                }
                guard let facing = trueNearest(to: midpoint(north), of: north, in: segments),
                      let foot = CandidateSegmentSearch.nearestPointOnPolyline(from: midpoint(north), polyline: facing.coordinates)
                else { XCTFail("no facing piece for \(id)"); continue }
                let car = CLLocationCoordinate2D(
                    latitude: (midpoint(north).latitude + foot.coordinate.latitude) / 2,
                    longitude: (midpoint(north).longitude + foot.coordinate.longitude) / 2
                )

                // 1. "Other side" lands on the facing piece, a few metres along the street at most.
                let here = ParkSideOption(segment: north, coordinate: midpoint(north), fraction: 0.5)
                guard let across = ParkSideResolver.switched(from: here, in: segments) else {
                    XCTFail("no switch for \(id)"); continue
                }
                XCTAssertEqual(across.segment.id, facing.id, "\(id) reversed=\(reversed)")
                let slide = ParkingAddressGeometry.distanceMeters(here.coordinate, across.coordinate)
                XCTAssertLessThan(slide, 25, "\(id): other curb is across the street, not \(Int(slide)) m along it")

                // 2. A car between the curbs with an 8 m fix is an ask between the facing pair,
                //    never a confident guess against a far piece.
                let fix = ParkTrackFix(coordinate: car, speed: 0, horizontalAccuracy: 8, timestamp: now)
                let decision = ParkSideResolver.decide(fix: fix, track: [], segments: segments, now: now)
                guard case .ask(let choice) = decision else {
                    XCTFail("\(id) reversed=\(reversed): expected .ask, got \(decision)"); continue
                }
                XCTAssertTrue(
                    [choice.first.segment.id, choice.second.segment.id].contains(facing.id),
                    "\(id): the second button must be the piece in front of the car"
                )
                let apart = ParkingAddressGeometry.distanceMeters(choice.first.coordinate, choice.second.coordinate)
                XCTAssertLessThan(apart, 25, "\(id): the two feet face each other")
            }
        }
    }

    /// Stanton Orchard-Ludlow: the north side is even and the south side is odd (checked against
    /// Apple's geocoder). The address probe must sit on the building side of the SNAPPED curb:
    /// north of the north curb for the N piece, south of the south curb for the S piece.
    func testOrchardLudlow_probeDirection_northCurbProbesNorth_southCurbProbesSouth() throws {
        let segments = try Self.stantonSegments(reversed: false)
        let block = segments.filter { $0.fromStreet == "ORCHARD STREET" && $0.to == "LUDLOW STREET" }
        let north = block.filter { $0.side == "N" }
        let south = block.filter { $0.side == "S" }
        XCTAssertFalse(north.isEmpty)
        XCTAssertFalse(south.isEmpty)
        for piece in north {
            guard let probe = ParkingAddressGeometry.probePoint(line: piece.line, fraction: 0.5, side: "N"),
                  let spot = ParkingAddressGeometry.pointAndTangent(line: piece.line, fraction: 0.5) else {
                XCTFail("no probe for \(piece.id)"); continue
            }
            XCTAssertGreaterThan(probe.latitude, spot.point.latitude, "\(piece.id): north piece probes north (even side)")
        }
        for piece in south {
            guard let probe = ParkingAddressGeometry.probePoint(line: piece.line, fraction: 0.5, side: "S"),
                  let spot = ParkingAddressGeometry.pointAndTangent(line: piece.line, fraction: 0.5) else {
                XCTFail("no probe for \(piece.id)"); continue
            }
            XCTAssertLessThan(probe.latitude, spot.point.latitude, "\(piece.id): south piece probes south (odd side)")
        }
    }
}

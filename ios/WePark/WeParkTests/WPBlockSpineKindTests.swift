//
//  WPBlockSpineKindTests.swift
//  WeParkTests
//
//  PR #234 QA follow-ups for the VoiceOver block spine:
//    - never drop a real curb of a different kind (Cooper Square E E5-E6, 6.2 m of NO_PARKING): a piece
//      is only left off the spine when it matches the piece it lies alongside; otherwise it is its own
//      run, so a car on it keeps its own verdict and the nudge says "End of block" there
//    - audit over EVERY multi-piece blockface: no dropped piece differs in kind from its neighbour
//    - only bridge a gap that continues the line, never a stub running back alongside it
//    - the segment-set version is a hash of the content; reset() clears the piece caches
//  Helpers reuse `Pr2NudgeTrapTiles` (enum namespace); no XCTestCase extensions.
//

import XCTest
import CoreLocation
@testable import WePark

final class WPBlockSpineKindTests: XCTestCase {

    private func ruleOfKind(_ category: WePark.Category) -> ParkingRule {
        ParkingRule(category: category, description: "", days: [], timeRanges: [], anytime: true, arrow: nil)
    }

    private func line(_ points: [(Double, Double)]) -> [[Double]] {
        points.map { point -> [Double] in
            let c = CurbSnapTestFixtures.coordinate(x: point.0, y: point.1)
            return [c.latitude, c.longitude]
        }
    }

    private func piece(
        _ id: String, _ points: [(Double, Double)], category: WePark.Category? = nil
    ) -> Segment {
        Segment(
            id: id, street: "MAIN ST", fromStreet: "A ST", to: "B ST", side: "S", line: line(points),
            rules: category.map { [ruleOfKind($0)] } ?? [], dominantCategory: category, oneway: nil
        )
    }

    // MARK: Different kind is its own run

    func testSyntheticStub_ofAnotherKind_isItsOwnRun_andTheWalkStaysOnIt() throws {
        let main = piece("MAIN", [(0, 0), (100, 0)])
        let stub = piece("STUB", [(100, 0), (96, 0)], category: .noParking)
        let all = [main, stub]
        let onMain = try XCTUnwrap(WPBlockSpine(around: main, in: all))
        XCTAssertEqual(onMain.legs.map { $0.segment.id }, ["MAIN"], "the other-kind curb is not folded into the spine")
        let onStub = try XCTUnwrap(WPBlockSpine(around: stub, in: all))
        XCTAssertEqual(onStub.legs.map { $0.segment.id }, ["STUB"], "its own run")
        // Nudging on the stub never relocates the car onto the main piece.
        if case .move(let step) = WPParkFlowController.nudgeTarget(spine: onStub, on: stub, fraction: 0.2, meters: 3) {
            XCTAssertEqual(step.segment.id, "STUB")
        }
        if case .endOfBlock = WPParkFlowController.nudgeTarget(spine: onStub, on: stub, fraction: 1, meters: 5) {
        } else {
            XCTFail("End of block at the end of its own run")
        }
    }

    func testSyntheticStub_ofTheSameKind_isStillCovered() throws {
        let main = piece("MAIN", [(0, 0), (100, 0)], category: .noParking)
        let stub = piece("STUB", [(100, 0), (96, 0)], category: .noParking)
        let onMain = try XCTUnwrap(WPBlockSpine(around: main, in: [main, stub]))
        XCTAssertEqual(onMain.legs.map { $0.segment.id }, ["MAIN"])
        let onStub = try XCTUnwrap(WPBlockSpine(around: stub, in: [main, stub]))
        XCTAssertEqual(onStub.legs.map { $0.segment.id }, ["MAIN"], "same kind: a car on it is placed on the spine")
    }

    /// Cooper Square E E5-E6: E_3 (6.2 m of NO_PARKING) branches off a block of metered and no-standing
    /// pieces. It must not be silently relocated onto them.
    func testCooperSquare_realNoParkingPiece_keepsItsOwnRun() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        guard let block = blocks.first(where: { $0.key == "COOPER SQUARE|EAST 5TH STREET|EAST 6TH STREET|E" }),
              let piece = block.pieces.first(where: { $0.id.hasSuffix("_E_3") }) else {
            return XCTFail("missing Cooper Square E E5-E6 E_3")
        }
        XCTAssertEqual(piece.dominantCategory, .noParking)
        let own = try XCTUnwrap(WPBlockSpine(around: piece, in: block.pieces))
        XCTAssertEqual(own.legs.map { $0.segment.id }, [piece.id], "its own run")
        for other in block.pieces where other.id != piece.id {
            let spine = try XCTUnwrap(WPBlockSpine(around: other, in: block.pieces))
            XCTAssertFalse(spine.legs.contains { $0.segment.id == piece.id } && spine.legs.count > 1,
                           "\(other.id): E_3 is never folded into the main spine")
        }
        // Walk on it either way: every landing stays on E_3, and it ends.
        for meters in [5.0, -5.0] {
            let walk = Pr2NudgeTrapTiles.walk(block: block.pieces, start: piece, fraction: 0.5, meters: meters)
            XCTAssertNil(walk.failure)
        }
        if case .move(let step) = WPParkFlowController.nudgeTarget(spine: own, on: piece, fraction: 0.2, meters: 3) {
            XCTAssertEqual(step.segment.id, piece.id)
        }
    }

    /// Audit over EVERY multi-piece blockface in the data: a piece left off its own spine is the same
    /// kind of curb as the spine piece nearest it. (A piece of another kind has a spine of its own.)
    func testAudit_noDroppedPieceDiffersInKindFromItsNeighbour() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        XCTAssertGreaterThan(blocks.count, 10_000, "expected all ~10,300 multi-piece blockfaces")
        var problems: [String] = []
        var ownRuns = 0
        var dropped = 0
        for found in blocks {
            autoreleasepool {
                for piece in found.pieces {
                    guard let spine = WPBlockSpine(around: piece, in: found.pieces) else { continue }
                    if spine.legs.contains(where: { $0.segment.id == piece.id }) {
                        if spine.legs.count == 1, found.pieces.count > 1 { ownRuns += 1 }
                        continue
                    }
                    // Dropped from its own spine: it must match the nearest piece that IS on it.
                    dropped += 1
                    guard let point = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: piece.coordinates) else { continue }
                    var nearest: (distance: Double, segment: Segment)?
                    for leg in spine.legs {
                        guard let foot = CandidateSegmentSearch.nearestPointOnPolyline(
                            from: point, polyline: leg.segment.coordinates
                        ) else { continue }
                        if nearest == nil || foot.distanceMeters < (nearest?.distance ?? .infinity) {
                            nearest = (foot.distanceMeters, leg.segment)
                        }
                    }
                    if let neighbour = nearest?.segment, !WPBlockSpine.sameKind(piece, neighbour) {
                        problems.append("\(piece.id) differs in kind from \(neighbour.id)")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\(problems.count) dropped pieces differ in kind, first: \(problems.prefix(5))")
        XCTAssertGreaterThan(ownRuns + dropped, 0)
    }

    // MARK: Bridging

    func testStubRunningBackAlongsideTheLine_isNotBridged() throws {
        // A main line to x = 100 and a 5 m stub 4 m off it, whose near end is within 6 m of the main end
        // and which runs back alongside the line: not a continuation.
        let main = piece("MAIN", [(0, 0), (100, 0)])
        let stub = piece("STUB", [(100, 4), (94, 4)])
        let spine = try XCTUnwrap(WPBlockSpine(around: main, in: [main, stub]))
        XCTAssertEqual(spine.legs.map { $0.segment.id }, ["MAIN"])
        XCTAssertEqual(spine.total, 100, accuracy: 0.5)
        if case .endOfBlock = WPParkFlowController.nudgeTarget(spine: spine, on: main, fraction: 1, meters: 5) {
        } else {
            XCTFail("the end of the line is the end of the block, not a walk back along the stub")
        }
    }

    func testGapInTheLine_isStillBridged() throws {
        let first = piece("FIRST", [(0, 0), (100, 0)])
        let second = piece("SECOND", [(104, 0), (160, 0)])
        let spine = try XCTUnwrap(WPBlockSpine(around: first, in: [first, second]))
        XCTAssertEqual(spine.legs.map { $0.segment.id }, ["FIRST", "SECOND"], "a small gap in the line is bridged")
    }

    // MARK: Version and caches

    func testContentVersion_changesWithTheContent_notJustCountAndEnds() {
        let a = piece("A", [(0, 0), (10, 0)])
        let b = piece("B", [(10, 0), (20, 0)])
        let c = piece("C", [(20, 0), (30, 0)])
        let other = piece("OTHER", [(10, 0), (20, 0)])
        XCTAssertEqual(WPParkFlowController.contentVersion([a, b, c]), WPParkFlowController.contentVersion([a, b, c]))
        XCTAssertNotEqual(
            WPParkFlowController.contentVersion([a, b, c]), WPParkFlowController.contentVersion([a, other, c]),
            "same count, same first and last id, different middle: a different version"
        )
    }

    @MainActor
    func testReset_clearsThePieceCaches() async {
        let segments = ParkSidePieceFixtures.block()
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: segments)
        guard let snap = WPParkFlowController.pendingSnap(on: segments[0], near: nil) else { return XCTFail("no snap") }
        let engine = ParkingRulesEngine()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        flow.enterPending(at: snap, segments: segments, engine: engine, now: now, windowEnd: nil, trip: nil)
        XCTAssertGreaterThan(flow.cachedPieceListCount, 0, "entering a draft caches the street's pieces")
        _ = flow.nudge(meters: 5, point: .zero, metersPerPoint: 0.1, engine: engine, now: now, windowEnd: nil, trip: nil)
        flow.reset()
        XCTAssertEqual(flow.cachedPieceListCount, 0)
    }
}

//
//  WPParkDraftFollowUpTests.swift
//  WeParkTests
//
//  DT35-3 follow-ups from docs/qa/pr224-qa.md: S1 (VoiceOver nudge stops at the end of the block,
//  never onto the cross street), S3 (drag snap reach about half a street), the pending bubble
//  position, and the rest of F1 (mini map when the facing piece barely overlaps). Real tiles for the
//  blocks QA found failing (Lexington E105-106, Madison E74-75, Broadway W101-102 and E10-12), not only
//  synthetic curbs.
//
//  Helpers are enum-namespaced with unique names (no XCTestCase extensions).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Real tiles for the QA blocks

enum Pr2FollowUpTiles {

    /// The block streets QA reported plus their cross streets (so a wrong jump has somewhere to land).
    static let streets: Set<String> = [
        "LEXINGTON AVENUE", "EAST 105TH STREET", "EAST 106TH STREET",
        "MADISON AVENUE", "EAST 74TH STREET", "EAST 75TH STREET",
        "BROADWAY", "WEST 101ST STREET", "WEST 102ND STREET",
        "EAST 10TH STREET", "EAST 11TH STREET", "EAST 12TH STREET"
    ]

    /// The blocks to walk: (street, the two cross streets in either order).
    static let blocks: [(street: String, cross: Set<String>)] = [
        ("LEXINGTON AVENUE", ["EAST 105TH STREET", "EAST 106TH STREET"]),
        ("MADISON AVENUE", ["EAST 74TH STREET", "EAST 75TH STREET"]),
        ("BROADWAY", ["WEST 101ST STREET", "WEST 102ND STREET"]),
        ("BROADWAY", ["EAST 10TH STREET", "EAST 11TH STREET"]),
        ("BROADWAY", ["EAST 11TH STREET", "EAST 12TH STREET"])
    ]

    static func load() throws -> [Segment] {
        let tilesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: tilesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var all: [Segment] = []
        for file in files {
            let segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: file))
            all += segments.filter { streets.contains($0.street) }
        }
        return all
    }

    /// Groups of pieces that make up one blockface (street, side, cross streets), for the QA blocks.
    static func groups(in all: [Segment]) -> [[Segment]] {
        var keyed: [String: [Segment]] = [:]
        for block in blocks {
            for piece in all where piece.street == block.street
                && block.cross.contains(piece.fromStreet) && block.cross.contains(piece.to) {
                keyed["\(piece.street)|\(piece.fromStreet)|\(piece.to)|\(piece.side)", default: []].append(piece)
            }
        }
        return keyed.keys.sorted().compactMap { keyed[$0] }
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

// MARK: - S1: nudges stop at the end of the block

final class WPParkNudgeBlockEndTests: XCTestCase {

    /// Walks `meters` at a time along a block with the pure target function. Every landing must be on
    /// a piece of the SAME blockface (within 1 m), never another street.
    private func walk(
        group: [Segment], meters: Double, startFraction: Double, all: [Segment]
    ) -> (steps: Int, stopped: Bool, stray: String?) {
        guard var segment = group.first else { return (0, false, "empty group") }
        var fraction = startFraction
        for step in 1...400 {
            switch WPParkFlowController.nudgeTarget(on: segment, fraction: fraction, meters: meters, in: all) {
            case .endOfBlock:
                return (step, true, nil)
            case .move(let landing):
                // The step names its own piece: it must be one of the block's, with the coordinate
                // on that curb.
                guard group.contains(where: { $0.id == landing.segment.id }),
                      let foot = CandidateSegmentSearch.nearestPointOnPolyline(
                        from: landing.coordinate, polyline: landing.segment.coordinates
                      ), foot.distanceMeters < 1.0 else {
                    return (step, false, "step \(step) landed off the block (\(segment.id))")
                }
                segment = landing.segment
                fraction = landing.fraction
            }
        }
        return (400, false, nil)
    }

    func testRealBlocks_forwardAndBack_stayOnTheBlockAndStopAtTheEnd() throws {
        let all = try Pr2FollowUpTiles.load()
        let groups = Pr2FollowUpTiles.groups(in: all)
        XCTAssertGreaterThanOrEqual(groups.count, 8, "expected the QA blocks (both sides) in the tiles")
        for group in groups {
            let label = "\(group[0].street) \(group[0].fromStreet)-\(group[0].to) \(group[0].side)"
            for meters in [5.0, -5.0] {
                let result = walk(group: group, meters: meters, startFraction: 0.5, all: all)
                XCTAssertNil(result.stray, "\(label) \(meters): \(result.stray ?? "")")
                XCTAssertTrue(result.stopped, "\(label) \(meters): never reached the end of the block")
            }
        }
    }

    func testAtTheEndOfAPiece_withNoNeighbour_isEndOfBlock_notAJump() {
        let line = [CurbSnapTestFixtures.coordinate(x: 0, y: 0), CurbSnapTestFixtures.coordinate(x: 60, y: 0)]
        let lone = CurbSnapTestFixtures.segment(
            id: "ONLY", street: "MAIN ST", from: "A ST", to: "B ST", side: "S", points: [(0, 0), (60, 0)]
        )
        // Cross street continuing straight on from the end: a different street, must be ignored.
        let cross = CurbSnapTestFixtures.segment(
            id: "CROSS", street: "B ST", from: "MAIN ST", to: "C ST", side: "S", points: [(60, 0), (120, 0)]
        )
        XCTAssertNotNil(line.first)
        if case .endOfBlock = WPParkFlowController.nudgeTarget(on: lone, fraction: 1, meters: 5, in: [lone, cross]) {
        } else {
            XCTFail("at the end of the block the nudge must stop")
        }
        // Part-way: it goes to the end of the piece, not past it.
        guard case .move(let toEnd) = WPParkFlowController.nudgeTarget(on: lone, fraction: 0.95, meters: 10, in: [lone, cross]) else {
            return XCTFail("expected a move to the end")
        }
        XCTAssertLessThan(Pr2FollowUpTiles.meters(toEnd.coordinate, CurbSnapTestFixtures.coordinate(x: 60, y: 0)), 0.5)
    }

    /// The full flow (snap index, verdict, card), on Lexington with E 105th and E 106th present: the
    /// car walks the block and stops; it never lands on a cross street.
    @MainActor
    func testFlow_nudgeToTheEnd_neverLeavesTheStreetAndSide() async throws {
        let all = try Pr2FollowUpTiles.load()
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: all)
        let deadline = Date().addingTimeInterval(10)
        while !flow.indexReady && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(flow.indexReady)

        let engine = ParkingRulesEngine()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for group in Pr2FollowUpTiles.groups(in: all) where group[0].street == "LEXINGTON AVENUE" || group[0].street == "MADISON AVENUE" {
            let start = try XCTUnwrap(group.first)
            let snap = try XCTUnwrap(WPParkFlowController.pendingSnap(on: start, near: nil))
            flow.enterPending(at: snap, segments: all, engine: engine, now: now, windowEnd: nil, trip: nil)
            var ended = false
            for _ in 0..<200 {
                let result = flow.nudge(
                    meters: 5, point: .zero, metersPerPoint: 0.1, engine: engine, now: now, windowEnd: nil, trip: nil
                )
                let landed = try XCTUnwrap(flow.snap?.segment)
                XCTAssertTrue(
                    WPParkFlowController.isSameBlock(landed, start),
                    "\(start.street) \(start.side): nudged onto \(landed.street) \(landed.side) (\(landed.id))"
                )
                if result == .endOfBlock { ended = true; break }
            }
            XCTAssertTrue(ended, "\(start.street) \(start.side): never reported the end of the block")
            flow.reset()
        }
    }

    func testEndOfBlockCopy() {
        XCTAssertEqual(WPParkFlowCopy.endOfBlock, "End of block")
    }
}

// MARK: - S3: drag reach

@MainActor
final class WPParkDragReachTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let engine = ParkingRulesEngine()

    private func readyFlow(_ segments: [Segment]) async -> WPParkFlowController {
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: segments)
        let deadline = Date().addingTimeInterval(5)
        while !flow.indexReady && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return flow
    }

    private func drag(_ flow: WPParkFlowController, y: Double) {
        flow.update(
            point: .zero, coordinate: CurbSnapTestFixtures.coordinate(x: 10, y: y), metersPerPoint: 0.1,
            engine: engine, now: now, windowEnd: nil, trip: nil
        )
    }

    func testReach_isAboutHalfAStreet_notFortyMetres() {
        XCTAssertEqual(WPParkFlowController.dragReachMeters, 10, accuracy: 1e-9)
        XCTAssertEqual(WPParkFlowController.tokenSnapConfig.acquireRadius, 10, accuracy: 1e-9)
        XCTAssertEqual(WPParkFlowController.entrySnapConfig.acquireRadius, WPParkFlowController.snapMeters, accuracy: 1e-9,
                       "entry from Park here and GPS keeps the 40 m foot-point rule")
    }

    func testDrag_overABuilding_saysNoCurb_andNoVerdict() async {
        // One curb at y = 0. A finger 24 m away (mid-lot) used to still get this curb's verdict.
        let flow = await readyFlow([CurbSnapTestFixtures.segment(
            id: "ONLY", street: "MAIN ST", from: "A ST", to: "B ST", side: "S", points: [(-100, 0), (100, 0)]
        )])
        flow.beginDrag(from: .zero)
        drag(flow, y: 5)
        XCTAssertNotNil(flow.snap, "on the street")
        XCTAssertNotNil(flow.model)
        drag(flow, y: 9)
        XCTAssertNotNil(flow.snap, "still within half a street plus tolerance")
        drag(flow, y: 24)
        XCTAssertNil(flow.snap, "24 m from the curb is a building, not the street")
        XCTAssertNil(flow.model, "no verdict for a spot the car is not on")
    }

    func testDrag_acquiresOnlyWithinReach_butKeepsTheCurbALittleLonger() async {
        let flow = await readyFlow([CurbSnapTestFixtures.segment(
            id: "ONLY", street: "MAIN ST", from: "A ST", to: "B ST", side: "S", points: [(-100, 0), (100, 0)]
        )])
        flow.beginDrag(from: .zero)
        drag(flow, y: 14)
        XCTAssertNil(flow.snap, "14 m is past the 10 m reach: not acquired")
        drag(flow, y: 9)
        XCTAssertNotNil(flow.snap)
        drag(flow, y: 11.5)
        XCTAssertNotNil(flow.snap, "kept inside the 12 m release radius (no flicker at the edge)")
        drag(flow, y: 13)
        XCTAssertNil(flow.snap)
    }

    func testPlaceAtGPS_keepsTheWide40mEntryRule() async {
        let segments = [CurbSnapTestFixtures.segment(
            id: "ONLY", street: "MAIN ST", from: "A ST", to: "B ST", side: "S", points: [(-100, 0), (100, 0)]
        )]
        let flow = await readyFlow(segments)
        let placed = flow.placeAt(
            coordinate: CurbSnapTestFixtures.coordinate(x: 10, y: 25), point: .zero, metersPerPoint: 0.1,
            engine: engine, now: now, windowEnd: nil, trip: nil
        )
        XCTAssertTrue(placed, "the user's GPS fix 25 m from the curb still places the car (entry rule)")
    }
}

// MARK: - Bubble and map-move plumbing

@MainActor
final class WPParkBubbleAndMapMoveTests: XCTestCase {

    func testBubble_sitsAboveTheCar_unlessThatWouldCoverThePillAtTheTop() {
        XCTAssertEqual(WPParkLayerV2.bubbleCenterY(carY: 400), 316, accuracy: 1e-9)
        XCTAssertEqual(WPParkLayerV2.bubbleCenterY(carY: 200), 284, accuracy: 1e-9, "near the top it goes below the car")
    }

    func testMapMoved_onlyCountsWhileADraftIsPending() async {
        let flow = WPParkFlowController()
        flow.mapMoved()
        XCTAssertEqual(flow.mapMoveTick, 0, "idle: the map moving costs nothing")
        let segments = [CurbSnapTestFixtures.segment(
            id: "ONLY", street: "MAIN ST", from: "A ST", to: "B ST", side: "S", points: [(-100, 0), (100, 0)]
        )]
        guard let snap = WPParkFlowController.pendingSnap(on: segments[0], near: nil) else { return XCTFail("no snap") }
        flow.enterPending(
            at: snap, segments: segments, engine: ParkingRulesEngine(),
            now: Date(timeIntervalSinceReferenceDate: 800_000_000), windowEnd: nil, trip: nil
        )
        flow.mapMoved()
        flow.mapMoved()
        XCTAssertEqual(flow.mapMoveTick, 2)
        flow.reset()
        flow.mapMoved()
        XCTAssertEqual(flow.mapMoveTick, 2, "after the draft ends it stops counting")
    }
}

// MARK: - F1 remainder: facing piece barely overlaps

final class WPParkMiniMapSmallOverlapTests: XCTestCase {

    private let size = CGSize(width: 320, height: 160)

    func testSmallOverlap_drawsBothCurbsOverTheCarsPieceSpan() throws {
        // North piece 0...100; the facing south piece only overlaps it by 2 m (98...160).
        let north = [CurbSnapTestFixtures.coordinate(x: 0, y: 12), CurbSnapTestFixtures.coordinate(x: 100, y: 12)]
        let south = [CurbSnapTestFixtures.coordinate(x: 98, y: 0), CurbSnapTestFixtures.coordinate(x: 160, y: 0)]
        let layout = try XCTUnwrap(WPParkSideMiniMapLayout.make(
            first: north, second: south, car: CurbSnapTestFixtures.coordinate(x: 40, y: 12),
            travelBearing: nil, size: size
        ))
        XCTAssertEqual(layout.first.first?.x ?? 0, layout.second.first?.x ?? -999, accuracy: 0.05)
        XCTAssertEqual(layout.first.last?.x ?? 0, layout.second.last?.x ?? -999, accuracy: 0.05)
        XCTAssertEqual(layout.first.count, 2)
    }

    func testExtend_carriesAnEndOnAlongItsOwnDirection() {
        let line: [(x: Double, up: Double)] = [(x: 10.0, up: 0.0), (x: 20.0, up: 2.0)]
        let longer = WPParkSideMiniMapLayout.extend(line, lo: 0, hi: 30)
        XCTAssertEqual(longer.first?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(longer.first?.up ?? -1, -2, accuracy: 1e-9)
        XCTAssertEqual(longer.last?.x ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(longer.last?.up ?? -1, 4, accuracy: 1e-9)
        let reversed = WPParkSideMiniMapLayout.extend(Array(line.reversed()), lo: 0, hi: 30)
        XCTAssertEqual(reversed.first?.x ?? -1, 30, accuracy: 1e-9, "direction of the polyline is preserved")
    }

    /// Every piece of the QA blocks, with the piece that faces it: both ends line up in the drawing.
    func testRealBlocks_everyFacingPair_drawsAligned() throws {
        let all = try Pr2FollowUpTiles.load()
        var checked = 0
        var misaligned: [String] = []
        for piece in all where Pr2FollowUpTiles.blocks.contains(where: {
            $0.street == piece.street && $0.cross.contains(piece.fromStreet) && $0.cross.contains(piece.to)
        }) {
            guard let middle = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: piece.coordinates),
                  let facing = ParkSideResolver.facingOpposite(of: piece, near: middle, in: all) else { continue }
            let car = CLLocationCoordinate2D(
                latitude: (middle.latitude + facing.snap.coordinate.latitude) / 2,
                longitude: (middle.longitude + facing.snap.coordinate.longitude) / 2
            )
            guard let layout = WPParkSideMiniMapLayout.make(
                first: piece.coordinates, second: facing.segment.coordinates, car: car,
                travelBearing: nil, size: size
            ) else { continue }
            checked += 1
            let startGap = abs((layout.first.first?.x ?? 0) - (layout.second.first?.x ?? -999))
            let endGap = abs((layout.first.last?.x ?? 0) - (layout.second.last?.x ?? -999))
            if startGap > 0.5 || endGap > 0.5 { misaligned.append(piece.id) }
        }
        XCTAssertGreaterThan(checked, 20)
        XCTAssertTrue(misaligned.isEmpty, "still a trapezoid: \(misaligned.prefix(8))")
    }
}

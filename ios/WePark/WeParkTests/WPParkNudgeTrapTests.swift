//
//  WPParkNudgeTrapTests.swift
//  WeParkTests
//
//  PR #226 QA finding #1: at some junctions between pieces the VoiceOver nudge stopped moving but kept
//  answering "moved" (West End Ave E 66-70, 2nd Ave W E61-62, Cabrini Blvd E W187-190), trapping the car
//  mid-block in both directions. The guarantee tested here, on real tiles:
//    - every nudge either advances the car along the block (coordinate strictly changes) or returns
//      "End of block"; it never reports "moved" without moving
//    - a walk from any piece, either way, ends at a true end of the block within N steps
//    - forward always ends at the same end and back at the other, whichever way pieces are digitised
//  Plus the flow-level check (the car is placed on the chosen piece, so the dead-band cannot undo a
//  crossing). Helpers are enum-namespaced with unique names (no XCTestCase extensions).
//

import XCTest
import CoreLocation
@testable import WePark

enum Pr2NudgeTrapTiles {

    /// Every segment in the bundled tiles, grouped by blockface (street, cross streets, side), only
    /// the groups with more than one piece.
    static func multiPieceBlocks() throws -> [(key: String, pieces: [Segment])] {
        let tilesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: tilesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var keyed: [String: [Segment]] = [:]
        for file in files {
            for piece in try JSONDecoder().decode([Segment].self, from: Data(contentsOf: file)) {
                keyed["\(piece.street)|\(piece.fromStreet)|\(piece.to)|\(piece.side)", default: []].append(piece)
            }
        }
        return keyed.keys.sorted().compactMap { key in
            guard let pieces = keyed[key], pieces.count > 1 else { return nil }
            return (key, pieces)
        }
    }

    /// Flat-earth metres (block scale), no CLLocation garbage in the long loops.
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let north = (b.latitude - a.latitude) * 111_320
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * Double.pi / 180)
        return hypot(east, north)
    }

    /// Piece endpoints that no other piece of the block joins (within 1 m): the real ends of the chain.
    static func chainEnds(_ pieces: [Segment]) -> [CLLocationCoordinate2D] {
        var ends: [CLLocationCoordinate2D] = []
        for piece in pieces {
            guard let first = piece.coordinates.first, let last = piece.coordinates.last else { continue }
            for endpoint in [first, last] {
                let joined = pieces.contains { other in
                    guard other.id != piece.id, let a = other.coordinates.first, let b = other.coordinates.last else {
                        return false
                    }
                    // Real joins are exact (0 m); a short end piece must not make its far end look joined.
                    return meters(endpoint, a) <= 1 || meters(endpoint, b) <= 1
                }
                if !joined { ends.append(endpoint) }
            }
        }
        return ends
    }

    struct Walk {
        var steps = 0
        var end: CLLocationCoordinate2D?
        var failure: String?
    }

    /// Walks `meters` at a time from `start` (a piece, fraction 0.5) until "End of block".
    static func walk(pieces: [Segment], start: Segment, meters step: Double, limit: Int = 400) -> Walk {
        var result = Walk()
        var segment = start
        var fraction = 0.5
        guard var position = CandidateSegmentSearch.coordinate(atFraction: fraction, along: start.coordinates) else {
            result.failure = "no start coordinate"
            return result
        }
        for count in 1...limit {
            switch WPParkFlowController.nudgeTarget(on: segment, fraction: fraction, meters: step, in: pieces) {
            case .endOfBlock:
                result.steps = count
                result.end = position
                return result
            case .move(let landing):
                guard pieces.contains(where: { $0.id == landing.segment.id }) else {
                    result.failure = "step \(count) left the block (\(landing.segment.id))"
                    return result
                }
                let moved = meters(position, landing.coordinate)
                guard moved >= 0.5 else {
                    result.failure = "step \(count) reported a move of \(moved) m on \(landing.segment.id) at fraction \(landing.fraction)"
                    return result
                }
                segment = landing.segment
                fraction = landing.fraction
                position = landing.coordinate
            }
        }
        result.failure = "no end of block within \(limit) steps"
        return result
    }

    /// The whole contract for one block. Returns the first problem, or nil.
    static func check(_ block: (key: String, pieces: [Segment])) -> String? {
        let ends = chainEnds(block.pieces)
        var forwardEnds: [CLLocationCoordinate2D] = []
        var backEnds: [CLLocationCoordinate2D] = []
        for start in block.pieces {
            for step in [5.0, -5.0] {
                let result = walk(pieces: block.pieces, start: start, meters: step)
                if let failure = result.failure { return "\(block.key) from \(start.id) (\(step)): \(failure)" }
                guard let end = result.end else { return "\(block.key): no end" }
                if !ends.contains(where: { meters($0, end) <= 3 }) {
                    return "\(block.key) from \(start.id) (\(step)): stopped at a spot that is not a block end"
                }
                if step > 0 { forwardEnds.append(end) } else { backEnds.append(end) }
            }
        }
        // A clean chain has two ends: forward always ends at one, back at the other.
        if ends.count == 2, let f = forwardEnds.first, let b = backEnds.first, meters(ends[0], ends[1]) > 20 {
            if forwardEnds.contains(where: { meters($0, f) > 3 }) { return "\(block.key): forward ends differ" }
            if backEnds.contains(where: { meters($0, b) > 3 }) { return "\(block.key): back ends differ" }
            if meters(f, b) < 10 { return "\(block.key): forward and back ended at the same place" }
        }
        return nil
    }
}

final class WPParkNudgeTrapTests: XCTestCase {

    /// The three blocks QA found trapped.
    func testQATrapBlocks_walkToTheEnd_bothWays_fromEveryPiece() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        let wanted = [
            "WEST END AVENUE|WEST 66TH STREET|WEST 70TH STREET|E",
            "2ND AVENUE|EAST 62ND STREET|EAST 61ST STREET|W",
            "CABRINI BOULEVARD|WEST 187TH STREET|WEST 190TH STREET|E"
        ]
        for key in wanted {
            guard let block = blocks.first(where: { $0.key == key }) else {
                XCTFail("missing real block \(key)"); continue
            }
            XCTAssertNil(Pr2NudgeTrapTiles.check(block), key)
        }
    }

    /// A broad sample (every 7th multi-piece blockface, all pieces as starts, both directions).
    func testBroadSample_everyWalkTerminatesAtATrueEnd_strictlyAdvancing() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        XCTAssertGreaterThan(blocks.count, 5000, "expected thousands of multi-piece blockfaces")
        var problems: [String] = []
        var checked = 0
        for (index, block) in blocks.enumerated() where index % 7 == 0 {
            checked += 1
            // A pool per block: the walks allocate many temporary objects.
            autoreleasepool {
                if let problem = Pr2NudgeTrapTiles.check(block) { problems.append(problem) }
            }
        }
        XCTAssertGreaterThan(checked, 700)
        XCTAssertTrue(problems.isEmpty, "\(problems.count) problem blocks, first: \(problems.prefix(5))")
    }

    /// Through the flow: the car is placed on the chosen piece, so the incumbent dead-band cannot keep
    /// it on the old one. Walks West End Ave E from every piece; each answer is moved or end of block.
    @MainActor
    func testFlow_westEnd_neverSaysMovedWithoutMoving() async throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        guard let block = blocks.first(where: { $0.key == "WEST END AVENUE|WEST 66TH STREET|WEST 70TH STREET|E" }) else {
            return XCTFail("missing West End Ave E 66-70")
        }
        let flow = WPParkFlowController()
        flow.prepareIndex(segments: block.pieces)
        let deadline = Date().addingTimeInterval(10)
        while !flow.indexReady && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let engine = ParkingRulesEngine()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for start in block.pieces {
            for meters in [5.0, -5.0] {
                guard let snap = WPParkFlowController.pendingSnap(on: start, near: nil) else { continue }
                flow.enterPending(at: snap, segments: block.pieces, engine: engine, now: now, windowEnd: nil, trip: nil)
                var previous = try XCTUnwrap(flow.groundCoordinate)
                var ended = false
                for _ in 0..<300 {
                    let result = flow.nudge(
                        meters: meters, point: .zero, metersPerPoint: 0.1, engine: engine, now: now, windowEnd: nil, trip: nil
                    )
                    let current = try XCTUnwrap(flow.groundCoordinate)
                    if result == .endOfBlock { ended = true; break }
                    XCTAssertEqual(result, .moved)
                    XCTAssertGreaterThan(Pr2NudgeTrapTiles.meters(previous, current), 0.1, "moved without moving from \(start.id)")
                    previous = current
                }
                XCTAssertTrue(ended, "\(start.id) \(meters): never reached End of block")
                flow.reset()
            }
        }
    }
}

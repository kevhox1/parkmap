//
//  WPParkNudgeTrapTests.swift
//  WeParkTests
//
//  The VoiceOver "Move forward / back along the block" contract, on real tiles (PR #226 finding 1, then
//  PR #229 QA findings 1 to 3):
//    - every nudge either advances the car along the block (it really moves, at least 0.5 m) or
//      returns "End of block"; it never reports "moved" without moving, and never leaves the block
//    - from ANY piece, at 0, 0.5 and 1.0 of it, a walk either way reaches "End of block" within N steps
//    - within one connected run of pieces, forward always ends at the same place and back at the other
//      end, whichever piece the walk started on, however the pieces are digitised, on curved blocks
//      (Paladino Ave), and with short overlapping stubs at the end (Bowery, Broadway W125-126)
//  Runs are computed independently here (piece ends within 6 m), so a block with a real gap is checked
//  per connected run. Helpers are enum-namespaced with unique names (no XCTestCase extensions).
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

    /// Connected runs of pieces: a piece belongs to a run when one of its ends is within 6 m of an end
    /// of a piece already in it.
    static func runs(of pieces: [Segment]) -> [[Segment]] {
        var parent = Array(0..<pieces.count)
        func root(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }
        func ends(_ piece: Segment) -> [CLLocationCoordinate2D] {
            let line = piece.coordinates
            guard let first = line.first, let last = line.last else { return [] }
            return [first, last]
        }
        for i in 0..<pieces.count {
            for j in (i + 1)..<max(i + 1, pieces.count) {
                var close = false
                for a in ends(pieces[i]) {
                    for b in ends(pieces[j]) where meters(a, b) <= 6 { close = true }
                }
                if close { parent[root(i)] = root(j) }
            }
        }
        var grouped: [Int: [Segment]] = [:]
        for (index, piece) in pieces.enumerated() { grouped[root(index), default: []].append(piece) }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    /// How far apart the farthest two piece ends of a run are.
    static func extent(of run: [Segment]) -> Double {
        var points: [CLLocationCoordinate2D] = []
        for piece in run {
            if let first = piece.coordinates.first, let last = piece.coordinates.last { points += [first, last] }
        }
        var widest = 0.0
        for a in points {
            for b in points { widest = max(widest, meters(a, b)) }
        }
        return widest
    }

    struct Walk {
        var steps = 0
        var end: CLLocationCoordinate2D?
        var failure: String?
    }

    /// Walks `meters` at a time from `fraction` of `start` until "End of block", on a spine built
    /// around `start` (so the spine's direction and ends are tested for every start piece).
    static func walk(
        block: [Segment], start: Segment, fraction startFraction: Double, meters step: Double, limit: Int = 400
    ) -> Walk {
        var result = Walk()
        guard let spine = WPBlockSpine(around: start, in: block),
              var position = CandidateSegmentSearch.coordinate(atFraction: startFraction, along: start.coordinates)
        else {
            result.failure = "no spine"
            return result
        }
        var segment = start
        var fraction = startFraction
        for count in 1...limit {
            switch WPParkFlowController.nudgeTarget(spine: spine, on: segment, fraction: fraction, meters: step) {
            case .endOfBlock:
                result.steps = count
                result.end = position
                return result
            case .move(let landing):
                guard block.contains(where: { $0.id == landing.segment.id }) else {
                    result.failure = "step \(count) left the block (\(landing.segment.id))"
                    return result
                }
                let moved = meters(position, landing.coordinate)
                guard moved >= 0.5 else {
                    result.failure = "step \(count) reported a move of \(moved) m on \(landing.segment.id)"
                    return result
                }
                segment = landing.segment
                fraction = landing.fraction
                position = landing.coordinate
            }
        }
        result.failure = "no end of block within \(limit) steps from \(start.id)@\(startFraction) (\(step))"
        return result
    }

    /// The whole contract for one block. Returns the first problem, or nil.
    static func check(_ block: (key: String, pieces: [Segment])) -> String? {
        for run in runs(of: block.pieces) {
            // Starts that share a spine share their ends. A real curb of another kind is its own run
            // (its spine is just itself), so group the starts by the pieces their spine runs through.
            var groups: [String: (starts: [Segment], spine: [Segment])] = [:]
            for start in run {
                guard let spine = WPBlockSpine(around: start, in: block.pieces) else {
                    return "\(block.key): no spine around \(start.id)"
                }
                let signature = spine.legs.map { $0.segment.id }.sorted().joined(separator: ",")
                var entry = groups[signature] ?? (starts: [], spine: spine.legs.map { $0.segment })
                entry.starts.append(start)
                groups[signature] = entry
            }
            for group in groups.values {
                var forwardEnds: [CLLocationCoordinate2D] = []
                var backEnds: [CLLocationCoordinate2D] = []
                let onSpine = Set(group.spine.map { $0.id })
                for start in group.starts {
                    for fraction in [0.0, 0.5, 1.0] {
                        for step in [5.0, -5.0] {
                            let result = walk(block: block.pieces, start: start, fraction: fraction, meters: step)
                            if let failure = result.failure { return "\(block.key): \(failure)" }
                            guard let end = result.end else { return "\(block.key): no end" }
                            // A satellite (a covered stub off the spine) answers "End of block" where it
                            // stands when the car is already at the block end: that is the stub, not
                            // the block's end, so only spine pieces vote on where the ends are.
                            guard onSpine.contains(start.id) else { continue }
                            if step > 0 { forwardEnds.append(end) } else { backEnds.append(end) }
                        }
                    }
                }
                // One end for forward, the other for back, whichever piece the walk started on.
                if let f = forwardEnds.first, let b = backEnds.first {
                    if let stray = forwardEnds.first(where: { meters($0, f) > 3 }) {
                        return "\(block.key): forward ends differ by \(meters(stray, f)) m depending on the start"
                    }
                    if let stray = backEnds.first(where: { meters($0, b) > 3 }) {
                        return "\(block.key): back ends differ by \(meters(stray, b)) m depending on the start"
                    }
                    if extent(of: group.spine) > 20, meters(f, b) < 10 {
                        return "\(block.key): forward and back ended at the same place"
                    }
                }
            }
        }
        return nil
    }
}

final class WPParkNudgeTrapTests: XCTestCase {

    private func block(_ key: String, in blocks: [(key: String, pieces: [Segment])]) -> (key: String, pieces: [Segment])? {
        blocks.first { $0.key == key }
    }

    /// The three blocks QA found trapped in PR #226.
    func testQATrapBlocks_walkToTheEnd_bothWays_fromEveryPiece() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        for key in [
            "WEST END AVENUE|WEST 66TH STREET|WEST 70TH STREET|E",
            "2ND AVENUE|EAST 62ND STREET|EAST 61ST STREET|W",
            "CABRINI BOULEVARD|WEST 187TH STREET|WEST 190TH STREET|E"
        ] {
            guard let found = block(key, in: blocks) else { XCTFail("missing real block \(key)"); continue }
            XCTAssertNil(Pr2NudgeTrapTiles.check(found), key)
        }
    }

    /// PR #229 QA finding 1: on a curved block a piece at one end counted as "reversed", so forward
    /// flipped, back ping-ponged and forward from the first piece said "End of block" at once.
    func testPaladino_curvedBlock_forwardAndBackAreStable() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        let paladino = blocks.filter { $0.key.hasPrefix("PALADINO") }
        XCTAssertGreaterThanOrEqual(paladino.count, 2, "expected Paladino Ave east and west")
        for found in paladino {
            XCTAssertNil(Pr2NudgeTrapTiles.check(found), found.key)
            // Forward from the very first piece must not stop at once on a block hundreds of metres long.
            let ordered = found.pieces.sorted { $0.id < $1.id }
            guard let first = ordered.first else { continue }
            let forward = Pr2NudgeTrapTiles.walk(block: found.pieces, start: first, fraction: 0.5, meters: 5)
            let back = Pr2NudgeTrapTiles.walk(block: found.pieces, start: first, fraction: 0.5, meters: -5)
            XCTAssertNil(forward.failure)
            XCTAssertNil(back.failure)
            if let f = forward.end, let b = back.end {
                XCTAssertGreaterThan(Pr2NudgeTrapTiles.meters(f, b), 100, "\(found.key): the two ends are far apart")
            }
        }
    }

    /// PR #229 QA finding 2: a short stub at the block end made the walk alternate main, stub, main.
    func testStubPieces_walkReachesEndOfBlock() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        var named: [(key: String, pieces: [Segment])] = []
        for found in blocks {
            guard let any = found.pieces.first else { continue }
            let labels = "\(any.fromStreet) \(any.to)"
            if any.street == "BOWERY", labels.contains("CANAL"), labels.contains("BAYARD") { named.append(found) }
            if any.street == "BROADWAY", any.side == "E", labels.contains("125"), labels.contains("126") { named.append(found) }
        }
        XCTAssertFalse(named.isEmpty, "expected the Bowery and Broadway W125-126 blocks")
        for found in named {
            XCTAssertNil(Pr2NudgeTrapTiles.check(found), found.key)
        }
    }

    /// A broad sample as large as QA's (every 7th multi-piece blockface plus every one on the long
    /// curved or busy streets), from every piece at 0, 0.5 and 1.0, both ways: every walk reaches an end
    /// within 400 steps, strictly advancing, and the ends are consistent within each connected run.
    func testBroadSample_everyWalkTerminates_endsAreConsistent() throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        XCTAssertGreaterThan(blocks.count, 5000, "expected thousands of multi-piece blockfaces")
        let streets = [
            "AMSTERDAM", "BROADWAY", "COLUMBUS", "RIVERSIDE", "NICHOLAS", "FORT WASHINGTON", "CENTRAL PARK WEST",
            "BOWERY", "EAST END", "WEST 4TH", "CABRINI", "PALADINO"
        ]
        var problems: [String] = []
        var checked = 0
        for (index, found) in blocks.enumerated() {
            let street = found.pieces.first?.street ?? ""
            guard index % 7 == 3 || streets.contains(where: { street.contains($0) }) else { continue }
            checked += 1
            // A pool per block: the walks allocate many temporary objects.
            autoreleasepool {
                if let problem = Pr2NudgeTrapTiles.check(found) { problems.append(problem) }
            }
        }
        XCTAssertGreaterThan(checked, 2000, "sample at least as large as QA's 2,387")
        XCTAssertTrue(problems.isEmpty, "\(problems.count) problem blocks, first: \(problems.prefix(8))")
    }

    /// Through the flow: the car is placed on the chosen piece, so the incumbent dead-band cannot keep
    /// it on the old one. Walks West End Ave E and Paladino from every piece; each answer is moved or
    /// end of block, and "moved" always moved.
    @MainActor
    func testFlow_neverSaysMovedWithoutMoving() async throws {
        let blocks = try Pr2NudgeTrapTiles.multiPieceBlocks()
        var chosen: [(key: String, pieces: [Segment])] = []
        if let westEnd = block("WEST END AVENUE|WEST 66TH STREET|WEST 70TH STREET|E", in: blocks) { chosen.append(westEnd) }
        if let paladino = blocks.first(where: { $0.key.hasPrefix("PALADINO") }) { chosen.append(paladino) }
        XCTAssertEqual(chosen.count, 2)
        let engine = ParkingRulesEngine()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for found in chosen {
            let flow = WPParkFlowController()
            flow.prepareIndex(segments: found.pieces)
            let deadline = Date().addingTimeInterval(10)
            while !flow.indexReady && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            for start in found.pieces {
                for meters in [5.0, -5.0] {
                    guard let snap = WPParkFlowController.pendingSnap(on: start, near: nil) else { continue }
                    flow.enterPending(at: snap, segments: found.pieces, engine: engine, now: now, windowEnd: nil, trip: nil)
                    var previous = try XCTUnwrap(flow.groundCoordinate)
                    var ended = false
                    for _ in 0..<400 {
                        let result = flow.nudge(
                            meters: meters, point: .zero, metersPerPoint: 0.1, engine: engine, now: now,
                            windowEnd: nil, trip: nil
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
}

// MARK: - The spine itself

final class WPBlockSpineTests: XCTestCase {

    /// Pieces drawn in mixed directions along a straight block chain into one spine, one direction.
    func testMixedDirectionPieces_makeOneStraightSpine() {
        let a = CurbSnapTestFixtures.segment(id: "A", side: "S", points: [(0, 0), (40, 0)])
        let b = CurbSnapTestFixtures.segment(id: "B", side: "S", points: [(80, 0), (40, 0)]) // drawn backwards
        let c = CurbSnapTestFixtures.segment(id: "C", side: "S", points: [(80, 0), (120, 0)])
        guard let spine = WPBlockSpine(around: b, in: [c, a, b]) else { return XCTFail("no spine") }
        XCTAssertEqual(spine.legs.map { $0.segment.id }, ["A", "B", "C"])
        XCTAssertEqual(spine.legs.map { $0.reversed }, [false, true, false])
        XCTAssertEqual(spine.total, 120, accuracy: 0.5)
    }

    /// The same spine, whichever piece it is built around.
    func testSpine_isTheSameFromEveryStartPiece() {
        let pieces = [
            CurbSnapTestFixtures.segment(id: "A", side: "S", points: [(0, 0), (40, 0)]),
            CurbSnapTestFixtures.segment(id: "B", side: "S", points: [(40, 0), (80, 30)]),
            CurbSnapTestFixtures.segment(id: "C", side: "S", points: [(80, 30), (80, 90)])
        ]
        let orders = pieces.compactMap { start in
            WPBlockSpine(around: start, in: Array(pieces.reversed()))?.legs.map { $0.segment.id }
        }
        XCTAssertEqual(orders.count, 3)
        XCTAssertTrue(orders.allSatisfy { $0 == orders[0] })
    }

    /// A short stub at the end that overlaps the main piece is not on the spine.
    func testStub_isLeftOffTheSpine_andACarOnItIsPlacedOnTheSpine() throws {
        let main = CurbSnapTestFixtures.segment(id: "MAIN", side: "S", points: [(0, 0), (100, 0)])
        let stub = CurbSnapTestFixtures.segment(id: "STUB", side: "S", points: [(100, 0), (96, 0)])
        let spine = try XCTUnwrap(WPBlockSpine(around: main, in: [main, stub]))
        XCTAssertFalse(spine.legs.contains { $0.segment.id == "STUB" })
        let onStub = try XCTUnwrap(WPBlockSpine(around: stub, in: [main, stub]))
        XCTAssertEqual(onStub.position(of: stub, fraction: 0.5), 98, accuracy: 1)
        // Forward from the end of the main piece is the end of the block, not a bounce onto the stub.
        if case .endOfBlock = WPParkFlowController.nudgeTarget(spine: spine, on: main, fraction: 1, meters: 5) {
        } else {
            XCTFail("at the end of the block the nudge must stop")
        }
    }
}

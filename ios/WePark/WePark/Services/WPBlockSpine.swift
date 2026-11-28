//
//  WPBlockSpine.swift
//  WePark
//
//  DT35-3 (VoiceOver "Move forward / back along the block"): one ordered line through the pieces of a
//  blockface, so a nudge is just "move `meters` along the spine". Real blockfaces are cut into pieces
//  (94% of sides), drawn in either direction, with short stubs at some ends and gaps in a few.
//  Deciding the direction once, from the chain itself, makes "forward" stable on curved blocks and
//  makes "End of block" the same place whichever piece the car started on.
//
//  Built from the pieces of ONE blockface (street, side, both cross streets):
//    1. the connected run around the start piece (piece ends within 6 m of each other);
//    2. piece ends within 1.5 m are one joint; a piece whose two ends are one joint (a tiny spur) is a
//       satellite and is not on the spine;
//    3. the spine is the longest simple path through the joints (a stub that branches off the main
//       line is left out), bridging a small gap only between two loose ends;
//    4. oriented so most of its length runs the way the pieces were digitised.
//  A start piece that is not on the spine (a satellite) is placed at its nearest point on the spine.
//
//  Pure and `nonisolated`. Never logs.
//

import Foundation
import CoreLocation

nonisolated struct WPBlockSpine {

    nonisolated struct Leg {
        let segment: Segment
        /// True when the spine runs from the piece's last vertex to its first.
        let reversed: Bool
        let length: Double
        /// Metres along the spine at which this piece starts.
        let start: Double
    }

    let legs: [Leg]
    let total: Double

    /// Piece ends this close are one joint.
    static let joinMeters = 1.5
    /// Pieces whose ends are this close belong to one run; a gap this small is bridged.
    static let gapMeters = 6.0

    /// The spine of the run of `segment`'s blockface. Nil only for a degenerate piece.
    init?(around segment: Segment, in segments: [Segment]) {
        guard segment.coordinates.count >= 2,
              let built = Self.buildLegs(around: segment, in: segments), !built.isEmpty else { return nil }
        var offset = 0.0
        var placed: [Leg] = []
        for leg in built {
            placed.append(Leg(segment: leg.segment, reversed: leg.reversed, length: leg.length, start: offset))
            offset += leg.length
        }
        legs = placed
        total = offset
    }

    // MARK: Position

    /// Metres along the spine of the point at `fraction` of `segment`.
    func position(of segment: Segment, fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        if let leg = legs.first(where: { $0.segment.id == segment.id }) {
            return leg.start + (leg.reversed ? 1 - clamped : clamped) * leg.length
        }
        // A satellite: where its point is nearest to the spine.
        guard let point = CandidateSegmentSearch.coordinate(atFraction: clamped, along: segment.coordinates) else {
            return 0
        }
        var best: (distance: Double, position: Double)?
        for leg in legs {
            guard let foot = CandidateSegmentSearch.nearestPointOnPolyline(
                from: point, polyline: leg.segment.coordinates
            ) else { continue }
            if best == nil || foot.distanceMeters < (best?.distance ?? .infinity) {
                best = (foot.distanceMeters, leg.start + (leg.reversed ? 1 - foot.fraction : foot.fraction) * leg.length)
            }
        }
        return best?.position ?? 0
    }

    /// The piece, fraction and coordinate at `position` metres along the spine (clamped to its ends).
    func landing(at position: Double) -> WPNudgeStep? {
        let s = min(total, max(0, position))
        guard let leg = legs.last(where: { $0.start <= s }) ?? legs.first, leg.length > 0 else { return nil }
        let local = min(leg.length, max(0, s - leg.start))
        let fraction = leg.reversed ? 1 - local / leg.length : local / leg.length
        guard let coordinate = CandidateSegmentSearch.coordinate(atFraction: fraction, along: leg.segment.coordinates) else {
            return nil
        }
        return WPNudgeStep(segment: leg.segment, fraction: fraction, coordinate: coordinate)
    }

    // MARK: Construction

    private struct Edge {
        let piece: Int?
        let a: Int
        let b: Int
        let weight: Double
    }

    private static func buildLegs(around segment: Segment, in segments: [Segment]) -> [Leg]? {
        var pieces = segments.filter { WPParkFlowController.isSameBlock($0, segment) && $0.coordinates.count >= 2 }
        if !pieces.contains(where: { $0.id == segment.id }) { pieces.append(segment) }
        var seen = Set<String>()
        pieces = pieces.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
        guard let startIndex = pieces.firstIndex(where: { $0.id == segment.id }) else { return nil }
        let lines = pieces.map { $0.coordinates }
        let lengths = lines.map { polylineLength($0) }

        // 1. The run around the start piece.
        var parent = Array(0..<pieces.count)
        func root(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }
        for i in 0..<pieces.count {
            for j in (i + 1)..<max(i + 1, pieces.count) {
                let close = endsClose(lines[i], lines[j])
                if close { parent[root(i)] = root(j) }
            }
        }
        let run = (0..<pieces.count).filter { root($0) == root(startIndex) }

        // 2. Joints and edges.
        var joints: [CLLocationCoordinate2D] = []
        func joint(for c: CLLocationCoordinate2D) -> Int {
            for (index, existing) in joints.enumerated() where metres(existing, c) <= joinMeters { return index }
            joints.append(c)
            return joints.count - 1
        }
        var edges: [Edge] = []
        for i in run {
            // A short piece lying along a longer one (a stub drawn over the end of the block) is
            // covered: it is not a place the walk can end up, or the car would bounce onto it.
            if isCovered(i, lines: lines, lengths: lengths, among: run) { continue }
            guard let first = lines[i].first, let last = lines[i].last else { continue }
            let a = joint(for: first)
            let b = joint(for: last)
            if a != b { edges.append(Edge(piece: i, a: a, b: b, weight: lengths[i])) }
        }
        guard !edges.isEmpty else {
            // Nothing but spurs: the start piece on its own.
            return [Leg(segment: segment, reversed: false, length: lengths[startIndex], start: 0)]
        }

        // 3. Bridge a small gap between two loose ends of different pieces of the run.
        var jointParent = Array(0..<joints.count)
        func jointRoot(_ x: Int) -> Int {
            var r = x
            while jointParent[r] != r { r = jointParent[r] }
            return r
        }
        var degree = [Int](repeating: 0, count: joints.count)
        for edge in edges {
            jointParent[jointRoot(edge.a)] = jointRoot(edge.b)
            degree[edge.a] += 1
            degree[edge.b] += 1
        }
        // Which way the piece at a loose end runs: `inward` points into the piece, `outward` away.
        func tangents(at jointIndex: Int) -> (inward: (east: Double, north: Double), outward: (east: Double, north: Double))? {
            guard let edge = edges.first(where: { $0.piece != nil && ($0.a == jointIndex || $0.b == jointIndex) }),
                  let piece = edge.piece, lines[piece].count >= 2 else { return nil }
            let line = lines[piece]
            let atStart = edge.a == jointIndex
            let end = atStart ? line[0] : line[line.count - 1]
            let next = atStart ? line[1] : line[line.count - 2]
            let inward = unitVector(from: end, to: next)
            return (inward, (-inward.east, -inward.north))
        }
        for p in 0..<joints.count {
            for q in (p + 1)..<max(p + 1, joints.count) where degree[p] == 1 && degree[q] == 1
                && jointRoot(p) != jointRoot(q) && metres(joints[p], joints[q]) <= gapMeters {
                // Only a gap in the line: the piece beyond it must carry on away from this end. A stub
                // running back alongside the line (a few metres off it) is not a continuation.
                guard let here = tangents(at: p), let there = tangents(at: q) else { continue }
                let across = unitVector(from: joints[p], to: joints[q])
                let carriesOn = here.outward.east * there.inward.east + here.outward.north * there.inward.north > 0.3
                let ahead = metres(joints[p], joints[q]) <= joinMeters
                    || across.east * here.outward.east + across.north * here.outward.north >= 0
                guard carriesOn, ahead else { continue }
                edges.append(Edge(piece: nil, a: p, b: q, weight: 0))
                jointParent[jointRoot(p)] = jointRoot(q)
            }
        }
        var adjacency = [[(edge: Int, other: Int)]](repeating: [], count: joints.count)
        for (index, edge) in edges.enumerated() {
            adjacency[edge.a].append((index, edge.b))
            adjacency[edge.b].append((index, edge.a))
        }

        // 4. The longest simple path (real length), first found wins ties.
        var bestWeight = -1.0
        var bestPath: [(edge: Int, from: Int)] = []
        var expansions = 0
        var visited = Set<Int>()
        var path: [(edge: Int, from: Int)] = []
        func walk(_ node: Int, _ weight: Double) {
            if weight > bestWeight + 1e-9 {
                bestWeight = weight
                bestPath = path
            }
            expansions += 1
            guard expansions < 50_000 else { return }
            for next in adjacency[node] where !visited.contains(next.other) {
                visited.insert(next.other)
                path.append((next.edge, node))
                walk(next.other, weight + edges[next.edge].weight)
                path.removeLast()
                visited.remove(next.other)
            }
        }
        for start in 0..<joints.count where !adjacency[start].isEmpty {
            visited = [start]
            path = []
            walk(start, 0)
        }

        // 5. Legs in path order, then orient so most length runs the way it was digitised.
        var legs: [Leg] = []
        for step in bestPath {
            let edge = edges[step.edge]
            guard let piece = edge.piece else { continue }
            legs.append(Leg(segment: pieces[piece], reversed: edge.a != step.from, length: lengths[piece], start: 0))
        }
        guard !legs.isEmpty else { return nil }
        // A run piece left off the spine is only dropped when it is the same kind of curb as the spine
        // piece nearest it (same dominant category and rule categories). A real curb of another kind
        // (say 6 m of no parking beside a metered piece) is its own run: a car on it keeps its own
        // verdict, and the walk never relocates it onto the spine.
        let onSpine = Set(legs.map { $0.segment.id })
        if !onSpine.contains(segment.id), let own = ownRun(
            for: startIndex, pieces: pieces, lines: lines, spine: legs
        ), own {
            return [Leg(segment: segment, reversed: false, length: lengths[startIndex], start: 0)]
        }
        let agree = legs.filter { !$0.reversed }.reduce(0.0) { $0 + $1.length }
        let disagree = legs.filter { $0.reversed }.reduce(0.0) { $0 + $1.length }
        if disagree > agree + 1e-9 {
            legs = legs.reversed().map { Leg(segment: $0.segment, reversed: !$0.reversed, length: $0.length, start: 0) }
        }
        return legs
    }

    // MARK: Geometry

    /// True when the dropped piece at `index` is a different kind of curb from the spine piece nearest
    /// it, so it must not be folded into the spine.
    private static func ownRun(
        for index: Int, pieces: [Segment], lines: [[CLLocationCoordinate2D]], spine: [Leg]
    ) -> Bool? {
        guard let point = CandidateSegmentSearch.coordinate(atFraction: 0.5, along: lines[index]) else { return nil }
        var nearest: (distance: Double, segment: Segment)?
        for leg in spine {
            guard let foot = CandidateSegmentSearch.nearestPointOnPolyline(
                from: point, polyline: leg.segment.coordinates
            ) else { continue }
            if nearest == nil || foot.distanceMeters < (nearest?.distance ?? .infinity) {
                nearest = (foot.distanceMeters, leg.segment)
            }
        }
        guard let neighbour = nearest?.segment else { return nil }
        return !sameKind(pieces[index], neighbour)
    }

    /// Same dominant category and the same set of rule categories.
    static func sameKind(_ a: Segment, _ b: Segment) -> Bool {
        a.dominantCategory == b.dominantCategory
            && Set(a.rules.map { $0.category }) == Set(b.rules.map { $0.category })
    }

    private static func unitVector(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (east: Double, north: Double) {
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * Double.pi / 180)
        let north = (b.latitude - a.latitude) * 111_320
        let norm = hypot(east, north)
        return norm > 0 ? (east / norm, north / norm) : (0, 0)
    }

    /// Pieces shorter than this can be stubs.
    private static let stubMeters = 25.0
    /// A stub counts as covered when three points along it are this close to a longer piece.
    private static let coverMeters = 2.5

    private static func isCovered(
        _ index: Int, lines: [[CLLocationCoordinate2D]], lengths: [Double], among run: [Int]
    ) -> Bool {
        guard lengths[index] < stubMeters else { return false }
        let samples = [0.1, 0.5, 0.9].compactMap {
            CandidateSegmentSearch.coordinate(atFraction: $0, along: lines[index])
        }
        guard samples.count == 3 else { return false }
        for other in run where other != index && lengths[other] > lengths[index] {
            var all = true
            for point in samples {
                // Close to the longer piece AND alongside it (inside its length, not just beyond its end):
                // a piece that merely continues the line past the other's end is not covered.
                guard let foot = CandidateSegmentSearch.nearestPointOnPolyline(from: point, polyline: lines[other]),
                      foot.distanceMeters <= coverMeters,
                      foot.fraction * lengths[other] > 0.2,
                      (1 - foot.fraction) * lengths[other] > 0.2 else { all = false; break }
            }
            if all { return true }
        }
        return false
    }

    /// Any end of `a` within the gap tolerance of any end of `b`.
    private static func endsClose(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        guard let a0 = a.first, let a1 = a.last, let b0 = b.first, let b1 = b.last else { return false }
        for p in [a0, a1] {
            for q in [b0, b1] where metres(p, q) <= gapMeters { return true }
        }
        return false
    }

    static func polylineLength(_ line: [CLLocationCoordinate2D]) -> Double {
        guard line.count >= 2 else { return 0 }
        var sum = 0.0
        for index in 1..<line.count {
            sum += metres(line[index - 1], line[index])
        }
        return sum
    }

    /// Flat-earth metres (block scale): no CLLocation objects, so nothing piles up in tight loops.
    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let north = (b.latitude - a.latitude) * 111_320
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * Double.pi / 180)
        return hypot(east, north)
    }
}

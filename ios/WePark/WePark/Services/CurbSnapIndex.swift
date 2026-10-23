//
//  CurbSnapIndex.swift
//  WePark
//
//  Stream A1 of the fixed-center-pin amendment — docs/longpress-universal-plant-spec.md
//  "Amendment — fixed-center pin with live curb snap" (§A.3 snap rule, §A.6 spatial
//  lookup, §A.9 seam contract). Pure snap engine + spatial index: given the coordinate under
//  a fixed screen-centre pin, which blockface (street + side) does it belong to?
//
//  Pure Foundation / CoreLocation. No SwiftUI, no MapKit, no actor, no instance state that
//  mutates after `init` — A2 (map layer) drives it from a 30 Hz display link and A3
//  (ContentView) builds it on a detached task, so every type here is `nonisolated` (this
//  project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting would otherwise tie
//  them to the main actor; same convention as `ParkingGoals` / `CandidateSegmentSearch`).
//
//  Why a separate index instead of `CandidateSegmentSearch.nearestSegmentSnap`:
//  that function rebuilds a haversine cumulative-length array per candidate segment per
//  call — fine for a one-shot tap, far too heavy for a ~30 Hz query over thousands of
//  segments. This file does the heavy work once, at `init`:
//
//    - Every polyline EDGE (not every segment) is projected to local metres
//      (equirectangular around a fixed NYC origin — the same flat-earth approximation as
//      `CandidateSegmentSearch`'s helpers, 111_320 m/deg latitude).
//    - Edges are bucketed into a 32 m uniform grid. An edge registers in EVERY cell its
//      bounding box crosses (no line rasterisation — bbox is conservative, and NYC edges are
//      short). Very long edges are split into <= 256 m collinear pieces first so a stray
//      vertex cannot register in millions of cells; splitting a straight edge does not
//      change any distance.
//    - Storage is CSR-style flat arrays (cell slot -> range into one edge-index array), so a
//      query never allocates.
//
//  A query visits the pin's cell plus its 8 neighbours (32 m cells, so any point inside the
//  centre cell has every edge within 32 m in that 3x3 block — covers the 30 m release
//  radius), runs a distance-only kernel (no haversine, no sqrt in the inner loop), and
//  computes the expensive foot-point/`positionFraction` for the single winner only, by
//  reusing `CandidateSegmentSearch.nearestPointOnPolyline`.
//
//  Deliberately NOT here: any UI, any flag (`curbPinPlacementEnabled` is A3's), the
//  generation token / detached build (A3), the CADisplayLink (A2), and the "arrow to nearest
//  curb" chip UI (A.3 "No curb in range") — its probe needs no new API, see the wide-config
//  recipe on `resolve`.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — first compile
//  is the Mac gate (see PR body). `nonisolated` on TYPE declarations (SE-0449) has no
//  precedent elsewhere in this repo; it needs the Swift 6.1+ compiler that the project's
//  `SWIFT_DEFAULT_ACTOR_ISOLATION` build setting already requires.
//
//  No Calendar.current. No dates at all.
//

import Foundation
import CoreLocation

// MARK: - CurbSnapConfig

/// Tunable numbers for the snap rule (spec §A.3 — "each MUST exist as a named constant in
/// `CurbSnapConfig`"). Starting values; the designer / Mac gate may tune them.
///
/// Declared with an explicit `init` (every parameter defaulted) rather than `let x = default`
/// stored properties: a `let` with a default value is EXCLUDED from the synthesized memberwise
/// init, so the seam-contract sketch could never have been customised by a test. `CurbSnapConfig()`
/// and `CurbSnapConfig.standard` behave exactly like the contract's all-defaults struct.
nonisolated struct CurbSnapConfig: Equatable {

    /// A blockface becomes eligible to be ACQUIRED only within this many physical metres of
    /// the pin. 24 m covers the centre of a ~48 m avenue (each side ~12-15 m away) and covers
    /// nothing inside a building lot, by design.
    let acquireRadius: Double

    /// The INCUMBENT blockface is kept while it stays within this many metres (1.25x acquire).
    /// Between `acquireRadius` and `releaseRadius` an incumbent is retained but nothing new
    /// is ever acquired.
    let releaseRadius: Double

    /// Anti-flicker dead-band, in SCREEN POINTS (default 14). Multiplied by the live
    /// metres-per-point to get a physical dead-band that is zoom-invariant to the finger.
    let hysteresisPoints: Double

    /// Floor for the physical dead-band (metres), so deep zoom-in never collapses it to nothing.
    let hysteresisMinMeters: Double

    /// Ceiling for the physical dead-band (metres), so zoom-out never makes the snap sticky.
    let hysteresisMaxMeters: Double

    init(
        acquireRadius: Double = 24.0,
        releaseRadius: Double = 30.0,
        hysteresisPoints: Double = 14.0,
        hysteresisMinMeters: Double = 1.5,
        hysteresisMaxMeters: Double = 4.0
    ) {
        self.acquireRadius = acquireRadius
        self.releaseRadius = releaseRadius
        self.hysteresisPoints = hysteresisPoints
        self.hysteresisMinMeters = hysteresisMinMeters
        self.hysteresisMaxMeters = hysteresisMaxMeters
    }

    /// The spec's starting values (24 m / 30 m / 14 pt clamped to 1.5-4 m).
    ///
    /// 14 pt (orchestrator ruling on QA pass 1 of PR #137) rather than the 8 pt first
    /// sketched: a challenger flips at H/2 past the centreline, so §A.3's "commit to a side by
    /// moving ~2 m past the middle" needs H ~ 4 m. At the ~0.28 m/pt entry zoom 14 pt is
    /// H = 3.92 m (flip ~1.96 m past centre), just under the 4.0 m ceiling.
    static let standard = CurbSnapConfig()

    /// `H = clamp(hysteresisPoints x metersPerPoint, hysteresisMinMeters, hysteresisMaxMeters)`.
    ///
    /// A challenger must be closer than the incumbent by MORE than this to take over.
    /// A non-finite or non-positive `metersPerPoint` (map not laid out yet) yields the minimum
    /// rather than propagating NaN into the comparison.
    func hysteresisMeters(metersPerPoint: Double) -> Double {
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return hysteresisMinMeters }
        let raw = hysteresisPoints * metersPerPoint
        return min(hysteresisMaxMeters, max(hysteresisMinMeters, raw))
    }
}

// MARK: - CurbSnapResult / CurbSnapOutcome

/// The winning blockface for a pin position.
///
/// `Equatable` is hand-written: neither `Segment` nor `CLLocationCoordinate2D` is `Equatable`
/// (and we deliberately do NOT add a retroactive `CLLocationCoordinate2D: Equatable`, which
/// would collide with any SDK/other-file definition). The segment compares by `id` (tile ids
/// are unique per blockface-side polyline); the numbers compare exactly.
///
/// DO NOT gate SwiftUI state writes or `onPlacementOutcome` callbacks on `==`: the foot point
/// and `distanceMeters` change on every frame of a pan, so `==` is "false" at ~30 Hz and
/// gating on it writes state per frame (spec A.11 A23; FT-17a measured the jank). Gate on
/// `blockfaceKey` and the outcome case (snapped vs noCurbInRange) instead.
nonisolated struct CurbSnapResult: Equatable {
    /// The winning segment (the nearest one, if a blockface appears in several tiles).
    let segment: Segment

    /// [0,1] from the segment's "from" endpoint to its "to" endpoint — same cumulative-length
    /// convention as `CandidateSegmentSearch.nearestPointOnPolyline` / `pins.position_fraction`.
    let positionFraction: Double

    /// Metres from the pin to the foot point on the curb.
    let distanceMeters: Double

    /// The foot point ON the polyline (the perpendicular projection, not the block midpoint).
    /// This is the coordinate to save — same convention as Spot-open's `SpotPlacementDraft`.
    let snappedCoordinate: CLLocationCoordinate2D

    /// Direction-agnostic blockface identity of the winner — the value to feed back as the
    /// next call's `incumbent`.
    var blockfaceKey: String { segment.blockfaceKey }

    static func == (lhs: CurbSnapResult, rhs: CurbSnapResult) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.positionFraction == rhs.positionFraction
            && lhs.distanceMeters == rhs.distanceMeters
            && lhs.snappedCoordinate.latitude == rhs.snappedCoordinate.latitude
            && lhs.snappedCoordinate.longitude == rhs.snappedCoordinate.longitude
    }
}

nonisolated enum CurbSnapOutcome: Equatable {
    /// A blockface owns the pin.
    case snapped(CurbSnapResult)

    /// Nothing is acquirable (and no incumbent survives within the release radius).
    ///
    /// `nearestMeters` is the distance to the nearest curb the query happened to examine, or
    /// nil if it examined none. The scan covers the pin's 3x3 cell neighbourhood, so a value
    /// is GUARANTEED present whenever a curb is within 32 m and best-effort out to ~64 m;
    /// it is NOT a 100 m probe by itself. For the A.3 "nearest curb within 100 m" chip use the
    /// wide-config recipe documented on `resolve` (it returns the foot point, which
    /// `nearestMeters` alone cannot).
    case noCurbInRange(nearestMeters: Double?)
}

// MARK: - CurbSnapIndex

/// Immutable spatial index over a snapshot of loaded segments. Build once (on a background
/// task — it is `Sendable`), query from any thread. Rebuild when the loaded set changes.
nonisolated final class CurbSnapIndex: @unchecked Sendable {

    // MARK: Tunables (private to the grid; the snap-rule numbers live in `CurbSnapConfig`)

    /// Uniform grid cell edge. Must be >= the release radius for the 3x3 scan to be complete
    /// (`resolve` widens the scan automatically if a caller's config exceeds it).
    static let cellSizeMeters = 32.0

    /// Longer edges are split into pieces of at most this length before bucketing.
    static let maxEdgeLengthMeters = 256.0

    /// Vertices farther than this from the origin are treated as corrupt and dropped
    /// (breaks the polyline at that vertex). NYC fits inside ~60 km.
    static let maxExtentMeters = 200_000.0

    /// Query points beyond this are rejected up front (keeps `Int(floor(...))` in range).
    static let maxQueryExtentMeters = 1_000_000.0

    // Fixed projection origin (lower Manhattan). The repo's geometry helpers use the same
    // equirectangular approximation; over NYC's ~0.4 deg latitude span the longitude scale
    // error is ~0.3%, i.e. < 0.1 m at the 24 m acquire radius.
    private static let originLatitude = 40.7128
    private static let originLongitude = -74.0060
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude =
        111_320.0 * cos(40.7128 * Double.pi / 180.0)

    // MARK: Storage (all immutable after init)

    /// One straight piece of a segment's polyline, in local metres. `dx/dy` are B - A and
    /// `invLenSq` is 1/|B-A|^2 (0 for a zero-length edge, which makes the projection
    /// parameter 0 with no branch in the hot loop).
    private nonisolated struct Edge {
        let ax: Double
        let ay: Double
        let dx: Double
        let dy: Double
        let invLenSq: Double
        /// Index into `segments`.
        let segment: Int32
        /// Dense blockface-group id (see `groupIDs`).
        let group: Int32
    }

    private let segments: [Segment]
    private let edges: ContiguousArray<Edge>

    /// grid-cell key -> cell slot.
    private let cellSlots: [Int64: Int32]
    /// `cellStarts[slot] ..< cellStarts[slot + 1]` is the slot's range in `cellEdgeIndices`.
    private let cellStarts: ContiguousArray<Int32>
    private let cellEdgeIndices: ContiguousArray<Int32>

    /// blockfaceKey -> dense group id; `groupKeys[id]` is the inverse. De-duplication by
    /// blockface falls out of tracking the best edge per GROUP rather than per segment.
    private let groupIDs: [String: Int32]
    private let groupKeys: [String]

    // MARK: Diagnostics

    /// Number of segments the index was built from (including any that contributed no edges).
    var segmentCount: Int { segments.count }

    /// Number of straight edges indexed (after long-edge splitting).
    var edgeCount: Int { edges.count }

    // MARK: - Build

    init(segments: [Segment]) {
        var builtEdges = ContiguousArray<Edge>()
        builtEdges.reserveCapacity(segments.count * 4)
        var builtGroupIDs: [String: Int32] = [:]
        var builtGroupKeys: [String] = []

        for (segmentIndex, segment) in segments.enumerated() {
            let key = segment.blockfaceKey
            let group: Int32
            if let existing = builtGroupIDs[key] {
                group = existing
            } else {
                group = Int32(builtGroupKeys.count)
                builtGroupIDs[key] = group
                builtGroupKeys.append(key)
            }

            // Walk the vertices the same way `Segment.coordinates` does (drop malformed
            // pairs), additionally dropping non-finite / absurdly distant vertices and
            // breaking the chain there. Fewer than 2 usable vertices => no edges, and the
            // segment simply can never be a candidate.
            var havePrevious = false
            var previousX = 0.0
            var previousY = 0.0
            for pair in segment.line {
                guard pair.count >= 2 else { continue }
                let (x, y) = CurbSnapIndex.project(latitude: pair[0], longitude: pair[1])
                guard x.isFinite, y.isFinite,
                      abs(x) <= CurbSnapIndex.maxExtentMeters,
                      abs(y) <= CurbSnapIndex.maxExtentMeters else {
                    havePrevious = false
                    continue
                }
                if havePrevious {
                    CurbSnapIndex.appendEdge(
                        ax: previousX, ay: previousY, bx: x, by: y,
                        segment: Int32(segmentIndex), group: group,
                        into: &builtEdges
                    )
                }
                previousX = x
                previousY = y
                havePrevious = true
            }
        }

        // Bucket edges into the grid. Pass 1 assigns cell slots, counts occupants and records
        // (slot, edge) pairs; pass 2 is a counting-sort fill into one flat array.
        let cell = CurbSnapIndex.cellSizeMeters
        var slots: [Int64: Int32] = [:]
        slots.reserveCapacity(builtEdges.count)
        var counts = ContiguousArray<Int32>()
        var pairSlots = ContiguousArray<Int32>()
        var pairEdges = ContiguousArray<Int32>()
        pairSlots.reserveCapacity(builtEdges.count * 2)
        pairEdges.reserveCapacity(builtEdges.count * 2)

        for (edgeIndex, edge) in builtEdges.enumerated() {
            let bx = edge.ax + edge.dx
            let by = edge.ay + edge.dy
            let cx0 = Int((min(edge.ax, bx) / cell).rounded(.down))
            let cx1 = Int((max(edge.ax, bx) / cell).rounded(.down))
            let cy0 = Int((min(edge.ay, by) / cell).rounded(.down))
            let cy1 = Int((max(edge.ay, by) / cell).rounded(.down))
            for cy in cy0...cy1 {
                for cx in cx0...cx1 {
                    let key = CurbSnapIndex.cellKey(cx, cy)
                    let slot: Int32
                    if let existing = slots[key] {
                        slot = existing
                        counts[Int(existing)] += 1
                    } else {
                        slot = Int32(counts.count)
                        slots[key] = slot
                        counts.append(1)
                    }
                    pairSlots.append(slot)
                    pairEdges.append(Int32(edgeIndex))
                }
            }
        }

        var starts = ContiguousArray<Int32>()
        starts.reserveCapacity(counts.count + 1)
        var running: Int32 = 0
        starts.append(0)
        for count in counts {
            running += count
            starts.append(running)
        }

        var cursors = starts
        var flat = ContiguousArray<Int32>(repeating: 0, count: Int(running))
        for pairIndex in 0..<pairSlots.count {
            let slot = Int(pairSlots[pairIndex])
            flat[Int(cursors[slot])] = pairEdges[pairIndex]
            cursors[slot] += 1
        }

        self.segments = segments
        self.edges = builtEdges
        self.cellSlots = slots
        self.cellStarts = starts
        self.cellEdgeIndices = flat
        self.groupIDs = builtGroupIDs
        self.groupKeys = builtGroupKeys
    }

    // MARK: - Resolve

    /// Resolves the pin coordinate to a blockface per spec §A.3.
    ///
    /// - Parameters:
    ///   - p: the pin's ground coordinate (`mapView.centerCoordinate`).
    ///   - incumbent: the previous winner's `blockfaceKey` (`CurbSnapResult.blockfaceKey`),
    ///     or nil when there is none / for a fresh entry. An unknown key is treated as nil.
    ///   - metersPerPoint: live map scale; converts the dead-band from screen points to metres.
    ///   - config: snap-rule constants.
    ///
    /// Rules, in order:
    ///  1. Candidates are blockfaces whose polyline passes within the radius; a blockface
    ///     present in several tiles is one candidate at its minimum distance (grouping by
    ///     `Segment.blockfaceKey`).
    ///  2. No incumbent (or incumbent beyond `releaseRadius`): the nearest blockface within
    ///     `acquireRadius` wins; otherwise `.noCurbInRange`.
    ///  3. Incumbent within `releaseRadius`: it is kept unless the nearest OTHER blockface is
    ///     within `acquireRadius` AND closer than `incumbentDistance - H` (strictly), where
    ///     `H = config.hysteresisMeters(metersPerPoint:)`.
    ///  4. Ties break on (distance, blockfaceKey, segment id) — never on input order.
    ///
    /// Allocation-free in the candidate scan; the winner's foot point / fraction is computed
    /// once via `CandidateSegmentSearch.nearestPointOnPolyline` (that step allocates a little,
    /// once per call). Its distance is haversine, so it can differ from the scan's flat-earth
    /// distance by ~0.1%: callers must not assert `distanceMeters <= acquireRadius` or compare
    /// it to other thresholds (e.g. the "> 15 m" far-curb rule) with zero tolerance.
    ///
    /// WIDE-CONFIG RECIPE (nearest-curb chip, A.3 "No curb in range"): to find the nearest
    /// curb out to 100 m, call once on settle (not per frame) with no incumbent:
    ///
    ///     index.resolve(pin, incumbent: nil, metersPerPoint: mpp,
    ///                   config: CurbSnapConfig(acquireRadius: 100, releaseRadius: 100))
    ///
    /// The scan widens automatically to a 9x9 cell block (ring 4, >= 128 m) and `.snapped`
    /// carries `snappedCoordinate` (the tap target; bearing = from the pin to it, minus the
    /// camera heading) and `distanceMeters`. `.noCurbInRange` means nothing within 100 m. The
    /// scan ring is capped at 8 cells (17x17), i.e. radii beyond ~256 m are not guaranteed.
    func resolve(
        _ p: CLLocationCoordinate2D,
        incumbent: String?,
        metersPerPoint: Double,
        config: CurbSnapConfig
    ) -> CurbSnapOutcome {
        guard !edges.isEmpty else { return .noCurbInRange(nearestMeters: nil) }

        guard let query = CurbSnapIndex.projectedQuery(p) else {
            return .noCurbInRange(nearestMeters: nil)
        }
        let px = query.x
        let py = query.y

        var incumbentGroup: Int32 = -1
        if let incumbent, let found = groupIDs[incumbent] {
            incumbentGroup = found
        }

        // Cells to scan on each side of the pin's cell. 1 (=> 3x3) for the default config.
        let ring = CurbSnapIndex.scanRing(forRadius: max(config.acquireRadius, config.releaseRadius))

        // Best edge of the incumbent's blockface, and best edge of any OTHER blockface.
        var incumbentD2 = Double.infinity
        var incumbentEdge = -1
        var otherD2 = Double.infinity
        var otherEdge = -1

        forEachCandidateEdge(x: px, y: py, ring: ring) { (edgeIndex: Int) -> Void in
            let edge = edges[edgeIndex]
            let d2 = CurbSnapIndex.distanceSquared(edge, px, py)
            if edge.group == incumbentGroup {
                if isBetter(d2, edgeIndex, than: incumbentD2, incumbentEdge) {
                    incumbentD2 = d2
                    incumbentEdge = edgeIndex
                }
            } else if isBetter(d2, edgeIndex, than: otherD2, otherEdge) {
                otherD2 = d2
                otherEdge = edgeIndex
            }
        }

        let incumbentD = incumbentEdge >= 0 ? incumbentD2.squareRoot() : Double.infinity
        let otherD = otherEdge >= 0 ? otherD2.squareRoot() : Double.infinity
        let nearest = min(incumbentD, otherD)

        var chosenEdge = -1
        if incumbentEdge >= 0 && incumbentD <= config.releaseRadius {
            // Incumbent survives. A challenger must be ACQUIRABLE and beat it by the dead-band.
            let h = config.hysteresisMeters(metersPerPoint: metersPerPoint)
            if otherEdge >= 0 && otherD <= config.acquireRadius && otherD < incumbentD - h {
                chosenEdge = otherEdge
            } else {
                chosenEdge = incumbentEdge
            }
        } else {
            // No usable incumbent: nearest blockface within the acquire radius, if any.
            let best: Int
            let bestD: Double
            if incumbentEdge >= 0, isBetter(incumbentD2, incumbentEdge, than: otherD2, otherEdge) {
                best = incumbentEdge
                bestD = incumbentD
            } else {
                best = otherEdge
                bestD = otherD
            }
            if best >= 0 && bestD <= config.acquireRadius {
                chosenEdge = best
            }
        }

        guard chosenEdge >= 0 else {
            return .noCurbInRange(nearestMeters: nearest.isFinite ? nearest : nil)
        }

        let winner = segments[Int(edges[chosenEdge].segment)]
        // Every indexed segment has >= 2 usable vertices, so this cannot be nil; the guard is
        // belt-and-braces rather than a force-unwrap.
        guard let match = CandidateSegmentSearch.nearestPointOnPolyline(
            from: p,
            polyline: winner.coordinates
        ) else {
            return .noCurbInRange(nearestMeters: nearest.isFinite ? nearest : nil)
        }
        return .snapped(CurbSnapResult(
            segment: winner,
            positionFraction: match.fraction,
            distanceMeters: match.distanceMeters,
            snappedCoordinate: match.coordinate
        ))
    }

    // MARK: - Nearby blockfaces

    /// Every distinct blockface whose polyline passes within `radius` metres of `p`, nearest
    /// first. Backs the placement mode's VoiceOver adjustable element ("swipe up/down to choose
    /// a nearby curb"): at a corner or on a divided street it lists the real candidates the
    /// pin could belong to, instead of only the single winner `resolve` returns.
    ///
    /// - Parameters:
    ///   - p: the pin's ground coordinate (`mapView.centerCoordinate`).
    ///   - radius: metres. Inclusive (`distance <= radius`, same as `resolve`'s acquire test).
    ///     Negative or NaN => empty. A huge or infinite radius is clamped to the scannable block
    ///     (see below) rather than trapping.
    ///
    /// Returns one `CurbSnapResult` per distinct `Segment.blockfaceKey` (a blockface present in
    /// several tiles is one entry, represented by its nearest copy), each carrying the same
    /// foot point / `positionFraction` / `distanceMeters` that `resolve` would report for it.
    ///
    /// Ordering is ascending by the scan's flat-earth distance — the exact metric `resolve`
    /// ranks by — with ties broken on `blockfaceKey` (then segment id when comparing copies of
    /// one blockface), never on input order. Consequently, with no incumbent and
    /// `radius >= config.acquireRadius`, element 0 is exactly the blockface `resolve` acquires
    /// WHEN `resolve` acquires one — a larger radius can list a nearest curb (beyond the acquire
    /// radius) that `resolve` rejects as `noCurbInRange`.
    /// Because the reported `distanceMeters` is haversine, two entries whose distances differ by
    /// under ~0.1% could appear in the reverse order from their reported distances; do not
    /// re-sort the result. For the same reason the radius filter is flat-earth: do not re-filter
    /// on `distanceMeters <= radius` (an entry within ~0.1% of the radius could be dropped).
    ///
    /// Empty when nothing is within `radius`, when the index is empty, or when `p` is not a
    /// usable coordinate (non-finite / absurdly distant). Reuses `resolve`'s grid scan, ring
    /// widening and ring cap: radii up to ~(ring x 32 m) are complete, and the ring is capped
    /// at 8 cells (17x17), so beyond ~256 m the result is best-effort. Allocates (a dictionary
    /// and the result array) — meant for a user gesture, not the 30 Hz display link.
    func nearbyBlockfaces(_ p: CLLocationCoordinate2D, radius: Double) -> [CurbSnapResult] {
        guard !edges.isEmpty, !radius.isNaN, radius >= 0 else { return [] }
        guard let query = CurbSnapIndex.projectedQuery(p) else { return [] }
        let px = query.x
        let py = query.y
        let ring = CurbSnapIndex.scanRing(forRadius: radius)

        // Best edge per blockface group, using the same ranking as `resolve`.
        var bestPerGroup: [Int32: NearbyCandidate] = [:]
        forEachCandidateEdge(x: px, y: py, ring: ring) { (edgeIndex: Int) -> Void in
            let edge = edges[edgeIndex]
            let d2 = CurbSnapIndex.distanceSquared(edge, px, py)
            if let current = bestPerGroup[edge.group] {
                if isBetter(d2, edgeIndex, than: current.distanceSquared, current.edge) {
                    bestPerGroup[edge.group] = NearbyCandidate(group: edge.group, edge: edgeIndex, distanceSquared: d2)
                }
            } else {
                bestPerGroup[edge.group] = NearbyCandidate(group: edge.group, edge: edgeIndex, distanceSquared: d2)
            }
        }

        var inRange: [NearbyCandidate] = []
        for candidate in bestPerGroup.values where candidate.distanceSquared.squareRoot() <= radius {
            inRange.append(candidate)
        }
        // Total order: groups are unique, and group keys are unique, so no two entries compare equal.
        inRange.sort { (a: NearbyCandidate, b: NearbyCandidate) -> Bool in
            if a.distanceSquared != b.distanceSquared { return a.distanceSquared < b.distanceSquared }
            return groupKeys[Int(a.group)] < groupKeys[Int(b.group)]
        }

        var results: [CurbSnapResult] = []
        results.reserveCapacity(inRange.count)
        for candidate in inRange {
            let winner = segments[Int(edges[candidate.edge].segment)]
            // Same belt-and-braces guard as `resolve`: indexed segments always have >= 2 usable
            // vertices, so this never skips an entry in practice.
            guard let match = CandidateSegmentSearch.nearestPointOnPolyline(
                from: p,
                polyline: winner.coordinates
            ) else { continue }
            results.append(CurbSnapResult(
                segment: winner,
                positionFraction: match.fraction,
                distanceMeters: match.distanceMeters,
                snappedCoordinate: match.coordinate
            ))
        }
        return results
    }

    /// Best edge found so far for one blockface group during `nearbyBlockfaces`.
    private nonisolated struct NearbyCandidate {
        let group: Int32
        /// Index into `edges`.
        let edge: Int
        let distanceSquared: Double
    }

    // MARK: - Shared scan internals (used by `resolve` and `nearbyBlockfaces`)

    /// Projects a query coordinate to local metres, or nil when it is non-finite / beyond
    /// `maxQueryExtentMeters` (keeps the later `Int(floor(...))` cell maths in range).
    private static func projectedQuery(_ p: CLLocationCoordinate2D) -> (x: Double, y: Double)? {
        let (x, y) = project(latitude: p.latitude, longitude: p.longitude)
        guard x.isFinite, y.isFinite,
              abs(x) <= maxQueryExtentMeters,
              abs(y) <= maxQueryExtentMeters else {
            return nil
        }
        return (x: x, y: y)
    }

    /// Cells to scan on each side of the pin's cell for a given radius: 1 (=> 3x3) up to 32 m,
    /// widening one cell per further 32 m, capped at 8 (17x17).
    private static func scanRing(forRadius radius: Double) -> Int {
        let ringRaw = (radius / cellSizeMeters).rounded(.up)
        // Clamp in Double BEFORE converting: Int(1e300) traps. NaN radius => default ring.
        return ringRaw.isNaN ? 1 : Int(min(8.0, max(1.0, ringRaw)))
    }

    /// Calls `body` with the index (into `edges`) of every edge registered in the
    /// (2 x ring + 1)^2 cell block around (x, y). An edge registered in several cells in the
    /// block is visited once per cell; both callers keep a running best, so repeats are harmless.
    @inline(__always)
    private func forEachCandidateEdge(x: Double, y: Double, ring: Int, _ body: (Int) -> Void) {
        let cell = CurbSnapIndex.cellSizeMeters
        let pinCellX = Int((x / cell).rounded(.down))
        let pinCellY = Int((y / cell).rounded(.down))
        for cy in (pinCellY - ring)...(pinCellY + ring) {
            for cx in (pinCellX - ring)...(pinCellX + ring) {
                guard let slot = cellSlots[CurbSnapIndex.cellKey(cx, cy)] else { continue }
                var k = Int(cellStarts[Int(slot)])
                let end = Int(cellStarts[Int(slot) + 1])
                while k < end {
                    body(Int(cellEdgeIndices[k]))
                    k += 1
                }
            }
        }
    }

    // MARK: - Tie-breaking

    /// True when candidate edge `a` (squared distance `d2a`) ranks strictly ahead of edge `b`.
    /// `b < 0` means "no current best". Exact distance ties break on blockfaceKey, then on
    /// segment id, so the result never depends on input order (A.11 A3).
    private func isBetter(_ d2a: Double, _ a: Int, than d2b: Double, _ b: Int) -> Bool {
        if b < 0 { return true }
        if d2a < d2b { return true }
        if d2a > d2b { return false }
        let ea = edges[a]
        let eb = edges[b]
        if ea.group != eb.group {
            return groupKeys[Int(ea.group)] < groupKeys[Int(eb.group)]
        }
        return segments[Int(ea.segment)].id < segments[Int(eb.segment)].id
    }

    // MARK: - Geometry kernel

    /// Squared distance (m^2) from (px, py) to the edge. Distance-only: no coordinates, no sqrt.
    @inline(__always)
    private static func distanceSquared(_ edge: Edge, _ px: Double, _ py: Double) -> Double {
        let rx = px - edge.ax
        let ry = py - edge.ay
        var t = (rx * edge.dx + ry * edge.dy) * edge.invLenSq
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        let fx = rx - t * edge.dx
        let fy = ry - t * edge.dy
        return fx * fx + fy * fy
    }

    private static func project(latitude: Double, longitude: Double) -> (Double, Double) {
        (
            (longitude - originLongitude) * metersPerDegreeLongitude,
            (latitude - originLatitude) * metersPerDegreeLatitude
        )
    }

    /// Unique key for a grid cell; `cx`/`cy` are small signed ints (|v| < 2^31).
    private static func cellKey(_ cx: Int, _ cy: Int) -> Int64 {
        (Int64(cx) << 32) | (Int64(cy) & 0xFFFF_FFFF)
    }

    /// Appends A->B, split into collinear pieces of at most `maxEdgeLengthMeters`.
    private static func appendEdge(
        ax: Double, ay: Double, bx: Double, by: Double,
        segment: Int32, group: Int32,
        into edges: inout ContiguousArray<Edge>
    ) {
        let length = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
        let pieces = max(1, Int((length / maxEdgeLengthMeters).rounded(.up)))
        for piece in 0..<pieces {
            let t0 = Double(piece) / Double(pieces)
            let t1 = Double(piece + 1) / Double(pieces)
            let x0 = ax + (bx - ax) * t0
            let y0 = ay + (by - ay) * t0
            let x1 = piece + 1 == pieces ? bx : ax + (bx - ax) * t1
            let y1 = piece + 1 == pieces ? by : ay + (by - ay) * t1
            let dx = x1 - x0
            let dy = y1 - y0
            let lenSq = dx * dx + dy * dy
            edges.append(Edge(
                ax: x0, ay: y0, dx: dx, dy: dy,
                invLenSq: lenSq > 0 ? 1.0 / lenSq : 0,
                segment: segment, group: group
            ))
        }
    }
}

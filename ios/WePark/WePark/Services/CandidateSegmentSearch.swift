//
//  CandidateSegmentSearch.swift
//  WePark
//
//  Extracted W5 "Wrong street?" candidate-search pattern — Community 2.0 Phase 2a (build 20
//  S6). Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2 ("Confirm the street"
//  step... reusing the existing ParkConfirmView 'Wrong street?' 35m-alternatives pattern
//  rather than a new algorithm — extract the shared candidate-search helper if it isn't
//  already a standalone function.").
//
//  Before this file: `ContentView.findCandidateSegments(lat:lng:radius:max:)` was a private
//  instance method reading `tileLoader.segments` implicitly — not reusable outside
//  ContentView. It has been reduced to a thin wrapper delegating to
//  `findCandidateSegments(lat:lng:in:radius:max:)` below; behavior is unchanged (byte-for-byte
//  port of the same dedup-by-block-key algorithm), only the `segments` array is now an
//  explicit parameter instead of a captured property.
//
//  All functions here are pure (`nonisolated`, no actor/SwiftUI/instance dependency) —
//  directly unit-testable, matching this codebase's `RealtimeMergeGate` / `CrewFeedMerge`
//  house style of separating testable decision logic from any view/service that consumes it.
//

import CoreLocation

enum CandidateSegmentSearch {

    // MARK: - W5: findCandidateSegments (extracted, unchanged behavior)

    /// Finds segments within `radius` meters of the given coordinate, sorted by distance.
    /// Port of findCandidateSegments() at index.html:5096-5111.
    ///
    /// Deduplication: groups by block key (street|from|to) — the same block face may span
    /// multiple segments. Returns the closest segment per unique block key, up to `max`
    /// results, sorted nearest-first.
    nonisolated static func findCandidateSegments(
        lat: Double,
        lng: Double,
        in segments: [Segment],
        radius: Double,
        max maxResults: Int
    ) -> [CandidateSegment] {
        let tapCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        // Track closest segment per block key (street|from|to) to deduplicate.
        var bestByBlockKey: [String: (segment: Segment, distance: Double)] = [:]

        for segment in segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: tapCoord, polyline: coords)
            guard dist <= radius else { continue }

            // Block key: same as the PWA's dedup key — street|from|to (case-insensitive).
            // We keep all-caps (as stored in tile data) for consistency.
            let key = "\(segment.street)|\(segment.fromStreet)|\(segment.to)"
            if let existing = bestByBlockKey[key] {
                if dist < existing.distance {
                    bestByBlockKey[key] = (segment, dist)
                }
            } else {
                bestByBlockKey[key] = (segment, dist)
            }
        }

        return bestByBlockKey.values
            .sorted { $0.distance < $1.distance }
            .prefix(maxResults)
            .map { CandidateSegment(segment: $0.segment, distanceMeters: $0.distance) }
    }

    // MARK: - Community 2.0 Phase 2a — "confirm the street" candidates

    /// Up to 4 candidates for the confirm-the-street step: the currently-detected segment,
    /// its opposite curb (same block, other side), and one neighboring block in each
    /// direction along the same street/side — matches design/prototype.html:384-411 /
    /// design/screenshots/09-report-confirm-street.png (4 rows: East side btwn Spring &
    /// Broome [selected], West side same block, East side one block south, East side one
    /// block north).
    ///
    /// `segment` is always included first (and is the initially-highlighted row —
    /// `ReportSheet` seeds its `confirmedSegment` state from the same value). Missing
    /// neighbors (sparse tile coverage at this zoom, or `segment` is at the end of the
    /// street) simply produce a shorter list — never a placeholder row or a crash.
    ///
    /// Deduplicated by `blockfaceKey` (defensive — the three lookups are independent and
    /// could theoretically coincide on sparse or malformed tile data) and capped at 4.
    nonisolated static func confirmStreetCandidates(for segment: Segment, in segments: [Segment]) -> [Segment] {
        var result: [Segment] = [segment]
        var seenKeys: Set<String> = [segment.blockfaceKey]

        func append(_ candidate: Segment?) {
            guard let candidate, !seenKeys.contains(candidate.blockfaceKey) else { return }
            seenKeys.insert(candidate.blockfaceKey)
            result.append(candidate)
        }

        append(oppositeSideCandidate(of: segment, in: segments))
        append(neighborSegment(of: segment, sharingCrossStreet: segment.fromStreet, in: segments))
        append(neighborSegment(of: segment, sharingCrossStreet: segment.to, in: segments))

        return Array(result.prefix(4))
    }

    /// Same block (same street, same UNORDERED from/to cross-street pair), the OTHER side.
    ///
    /// Intentionally a small, independent copy of the same predicate as
    /// `ContentView.oppositeSideSegment(of:in:)` (FT-15/TF2-15, AC-R2) rather than a call
    /// through to that ContentView static — a Services-layer file reaching into
    /// `ContentView` for logic would create the exact Service→View dependency direction this
    /// session's `CommunityZoneBounds` relocation was explicitly trying to avoid the other
    /// way around. Both copies are independently unit-tested; if they ever need to diverge,
    /// that's a sign that one of the two use cases actually needs different matching rules.
    nonisolated static func oppositeSideCandidate(of segment: Segment, in segments: [Segment]) -> Segment? {
        let crossPair: Set<String> = [segment.fromStreet, segment.to]
        return segments.first { candidate in
            candidate.side != segment.side &&
            candidate.street == segment.street &&
            Set([candidate.fromStreet, candidate.to]) == crossPair
        }
    }

    /// A same-street, same-side block whose own cross-street pair includes `crossStreet` —
    /// i.e. the next blockface encountered continuing past `crossStreet` from `segment`.
    /// Returns `nil` if no such segment is currently loaded (sparse tile coverage at this
    /// zoom, or `crossStreet` is the literal end of the street).
    nonisolated static func neighborSegment(
        of segment: Segment,
        sharingCrossStreet crossStreet: String,
        in segments: [Segment]
    ) -> Segment? {
        segments.first { candidate in
            candidate.blockfaceKey != segment.blockfaceKey &&
            candidate.side == segment.side &&
            candidate.street == segment.street &&
            (candidate.fromStreet == crossStreet || candidate.to == crossStreet)
        }
    }

    // MARK: - Community 2.0 Phase 2b (build 20 S7) — spot placement: nearest segment + fraction

    /// Result of `nearestSegmentSnap`: the closest segment to a tapped coordinate, together
    /// with WHERE along that segment the tap landed.
    struct SpotPlacementSnap {
        let segment: Segment

        /// [0,1] from the segment's "from" endpoint to its "to" endpoint — the same
        /// directional convention as `meta.heading_toward` and the `pins.position_fraction`
        /// column (spec §2.2). Computed by cumulative-length interpolation across every
        /// vertex of the segment's polyline, not just the nearest two-point sub-segment in
        /// isolation, so a multi-vertex polyline's fraction is continuous end-to-end.
        let positionFraction: Double

        let distanceMeters: Double

        /// The point ON the segment's polyline at `positionFraction` — NOT the raw tap
        /// coordinate. `insertCrowdPin` should be given THIS coordinate so the eventual map
        /// marker renders snapped to the curb rather than at a possibly-off-the-line tap
        /// point (AC-P2.4).
        let snappedCoordinate: CLLocationCoordinate2D
    }

    /// Finds the single closest segment to a tapped coordinate, within `radius` meters, and
    /// the position along that segment's polyline the tap landed at.
    ///
    /// Port of the prototype's `placeFromEvent` (`design/prototype.html:806-820`): scans
    /// every candidate segment, keeps the nearest point-to-polyline match, and returns nil
    /// when nothing is within `radius` (prototype: "Tap closer to a curb",
    /// `design/prototype.html:821`).
    nonisolated static func nearestSegmentSnap(
        lat: Double,
        lng: Double,
        in segments: [Segment],
        radius: Double
    ) -> SpotPlacementSnap? {
        let tapCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        var best: SpotPlacementSnap? = nil

        for segment in segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            guard let match = nearestPointOnPolyline(from: tapCoord, polyline: coords) else { continue }
            guard match.distanceMeters <= radius else { continue }
            if best == nil || match.distanceMeters < best!.distanceMeters {
                best = SpotPlacementSnap(
                    segment: segment,
                    positionFraction: match.fraction,
                    distanceMeters: match.distanceMeters,
                    snappedCoordinate: match.coordinate
                )
            }
        }
        return best
    }

    /// Finds the nearest point on a multi-vertex polyline to `point`, returning its
    /// distance, its coordinate, and its fraction [0,1] along the ENTIRE polyline (start →
    /// end) via cumulative-length interpolation across every vertex.
    private static func nearestPointOnPolyline(
        from point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> (distanceMeters: Double, fraction: Double, coordinate: CLLocationCoordinate2D)? {
        guard polyline.count >= 2 else { return nil }

        var cumulative: [Double] = [0]
        for i in 1..<polyline.count {
            cumulative.append(cumulative[i - 1] + haversine(from: polyline[i - 1], to: polyline[i]))
        }
        let totalLength = cumulative.last ?? 0

        var bestDistance = Double.infinity
        var bestFraction = 0.0
        var bestCoordinate = polyline[0]

        for i in 0..<(polyline.count - 1) {
            let a = polyline[i], b = polyline[i + 1]
            let (distance, t, closest) = pointToSegmentDistanceDetailed(point: point, a: a, b: b)
            if distance < bestDistance {
                bestDistance = distance
                let segLength = cumulative[i + 1] - cumulative[i]
                let lengthAlong = cumulative[i] + t * segLength
                bestFraction = totalLength > 0 ? lengthAlong / totalLength : 0
                bestCoordinate = closest
            }
        }
        return (bestDistance, min(1, max(0, bestFraction)), bestCoordinate)
    }

    // MARK: - Geometry helpers (duplicated from ContentView — see file header)
    //
    // Already duplicated 3x across this codebase (ContentView, DrivingContextService,
    // LocationService each carry their own haversine/point-to-segment math) — this file
    // follows that existing house style rather than introducing a new shared GeoMath type,
    // to keep ContentView's own copy (used by handleMapTap / handleBlockSelectTap, both
    // outside this file's scope) completely untouched.

    private static func pointToPolylineDistance(
        from point: CLLocationCoordinate2D,
        polyline: [CLLocationCoordinate2D]
    ) -> Double {
        var minDist = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let d = pointToSegmentDistance(point: point, a: polyline[i], b: polyline[i + 1])
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private static func pointToSegmentDistance(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        pointToSegmentDistanceDetailed(point: point, a: a, b: b).distance
    }

    /// Community 2.0 Phase 2b (build 20 S7): same point-to-segment projection math as
    /// `pointToSegmentDistance` above, but also returns `t` (the [0,1] fraction along THIS
    /// two-point sub-segment) and the closest coordinate — needed by
    /// `nearestPointOnPolyline`'s fraction/snap computation. `pointToSegmentDistance` now
    /// delegates here for its distance-only case rather than duplicating the projection math
    /// a second time.
    private static func pointToSegmentDistanceDetailed(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> (distance: Double, t: Double, closest: CLLocationCoordinate2D) {
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            return (haversine(from: point, to: a), 0, a)
        }

        let t = max(0, min(1, (px * bx + py * by) / abLenSq))
        let closestX = t * bx
        let closestY = t * by
        let closestLat = a.latitude  + closestY / metersPerDegLat
        let closestLng = a.longitude + closestX / metersPerDegLng
        let closest = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng)
        return (haversine(from: point, to: closest), t, closest)
    }

    private static func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180.0
        let lat2 = b.latitude * .pi / 180.0
        let dLat = (b.latitude - a.latitude) * .pi / 180.0
        let dLng = (b.longitude - a.longitude) * .pi / 180.0

        let sinDLat = sin(dLat / 2)
        let sinDLng = sin(dLng / 2)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLng * sinDLng
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadius * c
    }
}

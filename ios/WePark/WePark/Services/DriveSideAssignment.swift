//
//  DriveSideAssignment.swift
//  WePark
//
//  Drive-card LEFT/RIGHT correctness (build-27 smoke finding 8, PR #179 re-QA).
//
//  Segments carry a CARDINAL curb side ("N"/"S"/"E"/"W"). The drive card, the voice
//  phrases ("on the left") and the chip colors must name the curb on the DRIVER'S left or
//  right for the current travel direction. This file holds the pure logic:
//
//    1. `DriveSideTravel` resolves a stable TRAVEL BEARING along the matched street's
//       polyline (one-way streets use their legal direction; two-way streets use the
//       polyline direction closest to the heading, with hysteresis near perpendicular;
//       an unknown heading keeps the last known one).
//    2. `DriveSideAssignment.assign` maps the cardinal sides present on the block onto
//       distinct left/right slots for that bearing.
//
//  Why a side used to read "—": the old loop took the FIRST cardinal side that classified
//  as left and the first as right. When both present sides classified the same way (heading
//  near perpendicular to the street, or a diagonal street with e.g. N+E sides) one slot
//  stayed unassigned. Assigning by cross-track score always fills both slots when two or
//  more sides exist. A slot is now blank only when the tile truly has no segment for that
//  curb (data gap).
//
//  Pure value types and statics, all `nonisolated`; no CoreLocation session needed.
//

import Foundation
import CoreLocation

// MARK: - Tunables

enum DriveSideConstants {
    /// Max angle (degrees) between the heading and the nearest street direction for the
    /// street direction to be trusted as the travel bearing. Beyond this (heading roughly
    /// perpendicular to the street, e.g. mid-turn at a corner) the previous direction on
    /// this block is kept so the chips do not flip mid-intersection.
    static let alongStreetToleranceDeg: Double = 60.0
}

// MARK: - Assignment

enum DriveSideAssignment {

    /// Compass bearing of each cardinal curb, degrees clockwise from north.
    nonisolated static func cardinalBearing(_ side: String) -> Double? {
        switch side {
        case "N": return 0
        case "E": return 90
        case "S": return 180
        case "W": return 270
        default: return nil
        }
    }

    /// Maps the cardinal sides present on a block to the driver's left and right curbs.
    ///
    /// Score = sin(angle from travel bearing to the curb): negative is the driver's left,
    /// positive the right. With 2+ sides the lowest score is LEFT and the highest RIGHT
    /// (always distinct). With one side, its sign decides and the other slot is nil.
    nonisolated static func assign(
        sides: [String],
        travelBearing: Double
    ) -> (left: String?, right: String?) {
        var scored: [(side: String, score: Double)] = []
        for side in sides {
            guard let sb = cardinalBearing(side) else { continue }
            var rel = (sb - travelBearing).truncatingRemainder(dividingBy: 360)
            if rel < 0 { rel += 360 }
            var score = sin(rel * .pi / 180)
            if abs(score) < 1e-9 {
                // Curb exactly ahead/behind: break the tie by signed angle so opposite
                // curbs still land on opposite slots (matches the earlier TF2-7 tie-break).
                score = rel < 180 ? 1e-6 : -1e-6
            }
            scored.append((side, score))
        }
        guard !scored.isEmpty else { return (nil, nil) }
        if scored.count == 1 {
            let only = scored[0]
            return only.score < 0 ? (only.side, nil) : (nil, only.side)
        }
        let left = scored.min { $0.score < $1.score }
        let right = scored.max { $0.score < $1.score }
        return (left?.side, right?.side)
    }

    /// Cardinal fallback used only when NO heading has ever been known: N/W = left, S/E = right.
    nonisolated static func cardinalFallback(sides: [String]) -> (left: String?, right: String?) {
        let left = sides.first(where: { $0 == "N" || $0 == "W" }) ?? sides.first
        let right = sides.first(where: { $0 == "S" || $0 == "E" }) ?? (sides.count > 1 ? sides[1] : nil)
        return (left, right)
    }

    /// Polyline direction (both ways) of `segment` near `coordinate`, from the nearest
    /// polyline edge. `nil` for a degenerate line.
    nonisolated static func localBearings(
        of segment: Segment,
        near coordinate: CLLocationCoordinate2D
    ) -> (forward: Double, reverse: Double)? {
        let pts = segment.line.filter { $0.count >= 2 }
        guard pts.count >= 2 else { return nil }
        let cosLat = cos(coordinate.latitude * .pi / 180)
        var bestIndex = 0
        var bestDist = Double.infinity
        for i in 0..<(pts.count - 1) {
            let ax = (pts[i][1] - coordinate.longitude) * cosLat
            let ay = pts[i][0] - coordinate.latitude
            let bx = (pts[i + 1][1] - coordinate.longitude) * cosLat
            let by = pts[i + 1][0] - coordinate.latitude
            let dx = bx - ax
            let dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let px = ax + t * dx
            let py = ay + t * dy
            let d = px * px + py * py
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        let fwd = SegmentBearing.bearingFromTo(
            lat1: pts[bestIndex][0], lng1: pts[bestIndex][1],
            lat2: pts[bestIndex + 1][0], lng2: pts[bestIndex + 1][1]
        )
        return (fwd, (fwd + 180).truncatingRemainder(dividingBy: 360))
    }

    nonisolated static func circularDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }
}

// MARK: - Travel state

/// Remembers the last trustworthy heading and the last street direction per block, so a
/// stationary / unreliable-heading period keeps the previous left/right assignment.
struct DriveSideTravel {

    private var lastHeading: Double?
    private var lastBlockKey: String?
    private var lastBearing: Double?

    nonisolated init() {}

    /// Resolves the bearing to classify sides against for this tick, or `nil` if no heading
    /// has ever been known (caller then uses the cardinal fallback).
    ///
    /// - `heading`: stabilized drive heading; `nil` means unknown/unreliable.
    nonisolated mutating func resolve(
        heading: Double?,
        segment: Segment,
        blockKey: String,
        coordinate: CLLocationCoordinate2D
    ) -> Double? {
        if let heading { lastHeading = heading }
        let local = DriveSideAssignment.localBearings(of: segment, near: coordinate)

        // One-way: the legal direction wins; heading noise cannot flip sides.
        if segment.oneway == true, let local {
            let bearing: Double?
            switch segment.onewayToward {
            case "to": bearing = local.forward
            case "from": bearing = local.reverse
            default: bearing = nil
            }
            if let bearing {
                remember(blockKey, bearing)
                return bearing
            }
        }

        guard let effective = heading ?? lastHeading else {
            // No heading ever: keep a remembered direction for this block if we have one.
            return lastBlockKey == blockKey ? lastBearing : nil
        }

        if let local {
            let dF = DriveSideAssignment.circularDelta(local.forward, effective)
            let dR = DriveSideAssignment.circularDelta(local.reverse, effective)
            let best = dF <= dR ? local.forward : local.reverse
            if min(dF, dR) <= DriveSideConstants.alongStreetToleranceDeg {
                remember(blockKey, best)
                return best
            }
            // Heading roughly perpendicular to the street (mid-turn): keep prior direction.
            if lastBlockKey == blockKey, let lastBearing { return lastBearing }
        }
        return effective
    }

    private nonisolated mutating func remember(_ key: String, _ bearing: Double) {
        lastBlockKey = key
        lastBearing = bearing
    }
}

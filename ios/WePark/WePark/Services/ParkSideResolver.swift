//
//  ParkSideResolver.swift
//  WePark
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 section 1B): decides which curb of a
//  block a "Park here" tap means, or says it cannot and the user must choose.
//
//  Why this exists: the two curbs of a block are 12 to 15 m apart (median 13.8 m in the bundled
//  tiles) and city GPS is 8 to 20 m off, so "the nearest line" is close to a coin flip. Kevin
//  parked on the south side of Stanton St and the app snapped north. The rule here is the one
//  Kevin set: if unsure, ask, never guess. A GPS-nearest tie-break is never used.
//
//  Votes:
//    - Geometry: z = (distance to the second curb - distance to the nearest curb) / sigma, where
//      sigma = max(best reported accuracy, 5 m). Decisive at z >= 2. Fixes are NOT averaged down
//      by sqrt(n): GPS error is correlated.
//    - Heading (two-way streets only): the curb on the right-hand side of the approach bearing.
//      One-way streets and streets with unknown direction cast no heading vote, because heading
//      says nothing about the side there (80% of segments in the tiles are one-way).
//
//  Right/left wording ("Curb on my right") uses the retained approach course as the reference.
//  Never the phone's heading. With no usable course the card says "This side" instead.
//
//  Pure and `nonisolated`; no logging, ever (coordinates are private).
//

import Foundation
import CoreLocation

// MARK: - Constants

nonisolated enum ParkSideConstants {
    /// Curb search radius around the stopped position.
    static let searchRadiusMeters: Double = 35
    /// A fix older than this is not "where the car is".
    static let maxFixAgeSeconds: TimeInterval = 10
    /// Same bar as `AmbientDrivingLook.maxTightHorizontalAccuracyMeters`.
    static let maxHorizontalAccuracyMeters: Double = AmbientDrivingLook.maxTightHorizontalAccuracyMeters
    /// Floor on the position uncertainty.
    static let minSigmaMeters: Double = 5
    /// |z| at or above this is a decisive geometry vote.
    static let decisiveZ: Double = 2
    /// Stopped-position averaging window and speed bound.
    static let stoppedWindowSeconds: TimeInterval = 10
    static let stoppedSpeedMps: Double = 1.0
    /// Approach bearing inputs.
    static let approachWindowSeconds: TimeInterval = 120
    static let approachMinSpeedMps: Double = 2.0
    static let approachMaxCourseAccuracyDegrees: Double = 30
    static let approachMinFixes = 2
    static let approachMaxSpreadDegrees: Double = 25
    /// Moving fixes further than this from the stop are not part of "the approach".
    static let approachMaxDistanceMeters: Double = 60
    /// The approach must run along the street axis within this angle (else he was turning).
    static let approachMaxAxisAngleDegrees: Double = 30
}

// MARK: - Types

nonisolated enum ParkSideBasis: Equatable {
    case geometry
    case pulledRight
    case geometryAndHeading
    case onlyCurb
    case userChose
}

/// Which hand the curb is on, from the driver's seat (relative to the direction of travel).
nonisolated enum ParkSideHand: Equatable {
    case right
    case left
}

/// One curb of a block with the point on it that the car maps to.
nonisolated struct ParkSideOption: Equatable {
    let segment: Segment
    /// Foot point on the curb polyline. This is the coordinate that gets saved.
    let coordinate: CLLocationCoordinate2D
    /// [0,1] along the curb from its "from" endpoint (cumulative-length convention).
    let fraction: Double

    static func == (lhs: ParkSideOption, rhs: ParkSideOption) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.fraction == rhs.fraction
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

nonisolated struct ParkSidePick: Equatable {
    let option: ParkSideOption
    let basis: ParkSideBasis
    /// Where the car was (stopped-position average), before projecting onto the curb.
    let position: CLLocationCoordinate2D
    /// Approach course in degrees when it was usable and ran along the street; nil otherwise.
    /// The reference for "Curb on my right / left".
    let travelBearing: Double?

    var segment: Segment { option.segment }
    var coordinate: CLLocationCoordinate2D { option.coordinate }
    var fraction: Double { option.fraction }

    static func == (lhs: ParkSidePick, rhs: ParkSidePick) -> Bool {
        lhs.option == rhs.option
            && lhs.basis == rhs.basis
            && lhs.travelBearing == rhs.travelBearing
            && lhs.position.latitude == rhs.position.latitude
            && lhs.position.longitude == rhs.position.longitude
    }
}

nonisolated struct ParkSideChoice: Equatable {
    nonisolated enum Reason: Equatable {
        /// The two curbs are too close together for the GPS fix to separate.
        case tooCloseToCall
        /// Geometry and the two-way heading vote pointed at different curbs.
        case signalsDisagree
    }

    /// The nearest curb to the stopped position.
    let first: ParkSideOption
    /// The opposite curb of the same block.
    let second: ParkSideOption
    let reason: Reason
    let position: CLLocationCoordinate2D
    let travelBearing: Double?

    static func == (lhs: ParkSideChoice, rhs: ParkSideChoice) -> Bool {
        lhs.first == rhs.first
            && lhs.second == rhs.second
            && lhs.reason == rhs.reason
            && lhs.travelBearing == rhs.travelBearing
            && lhs.position.latitude == rhs.position.latitude
            && lhs.position.longitude == rhs.position.longitude
    }
}

nonisolated enum ParkSideDecision: Equatable {
    /// One curb, sure enough to show a verdict.
    case confident(ParkSidePick)
    /// Exactly two candidates, no verdict allowed until the user chooses.
    case ask(ParkSideChoice)
    /// No opposite curb in the data: nothing to choose between, no switch offered.
    case onlyCurb(ParkSidePick)
    /// GPS unusable (stale or too inaccurate): pick nothing.
    case weakFix
    /// Nothing within 35 m.
    case noCurb
}

// MARK: - Resolver

nonisolated enum ParkSideResolver {

    /// `now` is injectable so tests control the "fix too old" check.
    static func decide(
        fix: ParkTrackFix,
        track: [ParkTrackFix],
        segments: [Segment],
        now: Date = Date()
    ) -> ParkSideDecision {
        // 1. Fix quality.
        guard let accuracy = fix.horizontalAccuracy,
              accuracy <= ParkSideConstants.maxHorizontalAccuracyMeters,
              now.timeIntervalSince(fix.timestamp) <= ParkSideConstants.maxFixAgeSeconds else {
            return .weakFix
        }

        // 3. Position (done before the curb search so the search uses the steadier point).
        let stopped = stoppedPosition(fix: fix, track: track)
        let position = stopped.coordinate
        let sigma = max(stopped.bestAccuracy ?? accuracy, ParkSideConstants.minSigmaMeters)

        // 2. Candidate pair.
        guard let nearest = CandidateSegmentSearch.nearestSegmentSnap(
            lat: position.latitude, lng: position.longitude,
            in: segments, radius: ParkSideConstants.searchRadiusMeters
        ) else {
            return .noCurb
        }
        let optionA = ParkSideOption(
            segment: nearest.segment, coordinate: nearest.snappedCoordinate, fraction: nearest.positionFraction
        )

        // Approach course (also the right/left reference, so computed whatever the street type).
        let approach = approachBearing(fix: fix, track: track, stop: position)
        let travelBearing = approach.flatMap { bearing in
            runsAlongStreet(bearing: bearing, segment: nearest.segment, fraction: nearest.positionFraction)
                ? bearing : nil
        }

        guard let oppositeSegment = CandidateSegmentSearch.oppositeSideCandidate(of: nearest.segment, in: segments),
              let oppositeSnap = CandidateSegmentSearch.nearestPointOnPolyline(
                from: position, polyline: oppositeSegment.coordinates
              ) else {
            return .onlyCurb(ParkSidePick(
                option: optionA, basis: .onlyCurb, position: position, travelBearing: travelBearing
            ))
        }
        let optionB = ParkSideOption(
            segment: oppositeSegment, coordinate: oppositeSnap.coordinate, fraction: oppositeSnap.fraction
        )

        // 4. Geometry vote. A is the nearest curb by construction, so z >= 0 favours A.
        let z = max(0, (oppositeSnap.distanceMeters - nearest.distanceMeters) / sigma)

        // 5. Heading vote, two-way streets only.
        var headingVoteForA: Bool?
        if nearest.segment.oneway == false, let travelBearing,
           let hand = hand(of: optionA, versus: optionB, travelBearing: travelBearing) {
            headingVoteForA = (hand == .right)
        }

        // 6. Decide. Never break a tie by nearest-GPS.
        if z >= ParkSideConstants.decisiveZ {
            if headingVoteForA == false {
                return .ask(ParkSideChoice(
                    first: optionA, second: optionB, reason: .signalsDisagree,
                    position: position, travelBearing: travelBearing
                ))
            }
            return .confident(ParkSidePick(
                option: optionA,
                basis: headingVoteForA == true ? .geometryAndHeading : .geometry,
                position: position, travelBearing: travelBearing
            ))
        }
        if let voteForA = headingVoteForA {
            // z favours A only (>= 0). Heading for B is overruled once geometry leans A by 1.
            let leansAgainstVote = !voteForA && z >= 1
            if !leansAgainstVote {
                return .confident(ParkSidePick(
                    option: voteForA ? optionA : optionB, basis: .pulledRight,
                    position: position, travelBearing: travelBearing
                ))
            }
        }
        return .ask(ParkSideChoice(
            first: optionA, second: optionB, reason: .tooCloseToCall,
            position: position, travelBearing: travelBearing
        ))
    }

    // MARK: Switching

    /// The opposite curb of `option`'s block at the same position along the street (the current
    /// foot point projected onto the other curb). Nil when the data has no opposite curb.
    static func switched(from option: ParkSideOption, in segments: [Segment]) -> ParkSideOption? {
        guard let opposite = CandidateSegmentSearch.oppositeSideCandidate(of: option.segment, in: segments),
              let snap = CandidateSegmentSearch.nearestPointOnPolyline(
                from: option.coordinate, polyline: opposite.coordinates
              ) else { return nil }
        return ParkSideOption(segment: opposite, coordinate: snap.coordinate, fraction: snap.fraction)
    }

    /// A user's explicit choice of `option`.
    static func userChose(
        _ option: ParkSideOption, position: CLLocationCoordinate2D, travelBearing: Double?
    ) -> ParkSidePick {
        ParkSidePick(option: option, basis: .userChose, position: position, travelBearing: travelBearing)
    }

    // MARK: Right / left

    /// Which hand `option`'s curb is on, relative to `travelBearing`, given the other curb of the
    /// block. Uses a cross product in east/north metres, never the N/S/E/W letters, so it holds on
    /// Manhattan's angled grid. Nil when the two foot points coincide.
    static func hand(of option: ParkSideOption, versus other: ParkSideOption, travelBearing: Double) -> ParkSideHand? {
        let offset = localDelta(from: other.coordinate, to: option.coordinate)
        guard hypot(offset.east, offset.north) >= 0.5 else { return nil }
        let radians = travelBearing * Double.pi / 180
        let travelEast = sin(radians)
        let travelNorth = cos(radians)
        // Positive cross product = the offset points counter-clockwise of travel = to the left.
        let cross = travelEast * offset.north - travelNorth * offset.east
        return cross < 0 ? .right : .left
    }

    // MARK: Position and approach

    /// The stopped position: mean of usable fixes in the last 10 s that are stopped, when the
    /// latest fix is itself stopped; otherwise the latest fix alone.
    static func stoppedPosition(
        fix: ParkTrackFix, track: [ParkTrackFix]
    ) -> (coordinate: CLLocationCoordinate2D, bestAccuracy: Double?) {
        guard isStopped(fix) else { return (fix.coordinate, fix.horizontalAccuracy) }
        let windowStart = fix.timestamp.addingTimeInterval(-ParkSideConstants.stoppedWindowSeconds)
        let pool = uniqueByTimestamp(track + [fix]).filter { candidate in
            candidate.timestamp >= windowStart && candidate.timestamp <= fix.timestamp
                && isStopped(candidate)
                && (candidate.horizontalAccuracy.map { $0 <= ParkSideConstants.maxHorizontalAccuracyMeters } ?? false)
        }
        guard !pool.isEmpty else { return (fix.coordinate, fix.horizontalAccuracy) }
        let count = Double(pool.count)
        let lat = pool.reduce(0.0) { $0 + $1.coordinate.latitude } / count
        let lng = pool.reduce(0.0) { $0 + $1.coordinate.longitude } / count
        let best = pool.compactMap(\.horizontalAccuracy).min()
        return (CLLocationCoordinate2D(latitude: lat, longitude: lng), best)
    }

    /// Approach bearing (degrees), or nil when there was no clean approach: needs at least two
    /// moving fixes (speed >= 2 m/s, course accuracy nil or <= 30 deg) from the last 120 s that are
    /// within 60 m of the stop, whose courses agree within 25 deg of their circular mean.
    static func approachBearing(
        fix: ParkTrackFix, track: [ParkTrackFix], stop: CLLocationCoordinate2D
    ) -> Double? {
        let windowStart = fix.timestamp.addingTimeInterval(-ParkSideConstants.approachWindowSeconds)
        let moving = uniqueByTimestamp(track + [fix]).filter { candidate in
            guard candidate.timestamp >= windowStart, candidate.timestamp <= fix.timestamp,
                  candidate.course != nil,
                  candidate.speed >= ParkSideConstants.approachMinSpeedMps else { return false }
            if let courseAccuracy = candidate.courseAccuracy,
               courseAccuracy > ParkSideConstants.approachMaxCourseAccuracyDegrees { return false }
            let delta = localDelta(from: stop, to: candidate.coordinate)
            return hypot(delta.east, delta.north) <= ParkSideConstants.approachMaxDistanceMeters
        }
        let courses = moving.compactMap(\.course)
        guard courses.count >= ParkSideConstants.approachMinFixes else { return nil }
        var sumEast = 0.0
        var sumNorth = 0.0
        for course in courses {
            sumEast += sin(course * Double.pi / 180)
            sumNorth += cos(course * Double.pi / 180)
        }
        guard hypot(sumEast, sumNorth) > 1e-9 else { return nil }
        let mean = normalize(atan2(sumEast, sumNorth) * 180 / Double.pi)
        let spread = courses.map { angularDifference($0, mean) }.max() ?? 0
        guard spread <= ParkSideConstants.approachMaxSpreadDegrees else { return nil }
        return mean
    }

    /// True when `bearing` is within 30 deg of the street axis (either direction) at `fraction`.
    static func runsAlongStreet(bearing: Double, segment: Segment, fraction: Double) -> Bool {
        guard let spot = ParkingAddressGeometry.pointAndTangent(line: segment.line, fraction: fraction) else {
            return false
        }
        let axis = normalize(atan2(spot.tangent.east, spot.tangent.north) * 180 / Double.pi)
        let difference = angularDifference(bearing, axis)
        let limit = ParkSideConstants.approachMaxAxisAngleDegrees
        return difference <= limit || (180 - difference) <= limit
    }

    // MARK: Small helpers

    private static func isStopped(_ fix: ParkTrackFix) -> Bool {
        fix.speed >= 0 && fix.speed < ParkSideConstants.stoppedSpeedMps
    }

    private static func uniqueByTimestamp(_ fixes: [ParkTrackFix]) -> [ParkTrackFix] {
        var seen = Set<TimeInterval>()
        var result: [ParkTrackFix] = []
        for fix in fixes where seen.insert(fix.timestamp.timeIntervalSinceReferenceDate).inserted {
            result.append(fix)
        }
        return result
    }

    private static func normalize(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Smallest angle between two bearings, in [0, 180].
    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let difference = abs(normalize(a) - normalize(b))
        return difference > 180 ? 360 - difference : difference
    }

    /// East/north metres from `a` to `b` (flat-earth, fine at block scale).
    private static func localDelta(
        from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D
    ) -> (east: Double, north: Double) {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLng = metersPerDegreeLat * cos(a.latitude * Double.pi / 180)
        return (
            (b.longitude - a.longitude) * metersPerDegreeLng,
            (b.latitude - a.latitude) * metersPerDegreeLat
        )
    }
}

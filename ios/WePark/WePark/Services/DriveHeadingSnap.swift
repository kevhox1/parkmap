//
//  DriveHeadingSnap.swift
//  WePark
//
//  TF2-16: Drive Mode heading snap-to-street at low speed/confidence.
//
//  Kevin's build-13 finding: the Drive Mode heading arrow "spins and looks for its
//  direction" at low speed while approaching an intersection or turn. Root cause
//  (LocationService.swift): drive heading is GPS course + EMA, gated at 0.5 m/s
//  (TF2-3). Below ~2-3 m/s GPS course is inherently noisy (derived by comparing
//  successive fixes), and that noise passes the gate and shows up as a visible swing.
//
//  Fix: when the driver is matched to a street segment AND course confidence is low
//  (slow speed and/or poor CLLocation.courseAccuracy), default the heading to the
//  matched segment's own travel-direction bearing instead of the noisy raw GPS course.
//  A hysteresis state machine (`nextHeadingSource`) prevents the source from
//  flip-flopping at the confidence boundary, and exit is gated on speed + course
//  accuracy recovering ONLY (not course/EMA disagreement) so an in-progress turn is
//  never fought — see spec §5.3.
//
//  Pure Foundation only (no CoreLocation/UIKit/SwiftUI import) — matches the
//  SegmentBearing.swift house style. Directly unit-testable with no framework deps.
//
//  Spec: docs/tf2-16-heading-snap-spec.md §5.
//
//  Invariants:
//    - No Calendar.current.
//    - No force-unwraps.
//    - No SwiftUI or UIKit imports — pure math on Doubles/enums.
//

import Foundation

// MARK: - HeadingSourceKind

/// Which source currently drives the Drive Mode camera/puck heading.
enum HeadingSourceKind: Equatable {
    /// Raw GPS course, stabilized by LocationService's EMA (today's behavior).
    case course
    /// The matched street segment's own travel-direction bearing (TF2-16).
    case streetSnap
}

// MARK: - DriveHeadingSnapConstants

/// Named tunables for the heading-snap hysteresis state machine (spec §OQ-2).
///
/// Ship with these defaults; calibrate on Kevin's next on-device drive-test —
/// same pattern as `driveModePitch` / `driveModeCameraSpan`.
enum DriveHeadingSnapConstants {

    /// Speed (m/s) below which — while currently on `.course` — the source may enter
    /// `.streetSnap` (subject to `hasBlockMatch`). On-device-tunable.
    static let enterSpeedMPS: Double = 1.5

    /// Speed (m/s) at or above which — while currently on `.streetSnap` — the source may
    /// exit back to `.course` (requires `courseAccuracy` to also clear `exitCourseAccuracyDeg`).
    /// Deliberately higher than `enterSpeedMPS` so the source can't flip-flop at a single
    /// threshold value (hysteresis, spec item 4).
    static let exitSpeedMPS: Double = 3.0

    /// `CLLocation.courseAccuracy` (degrees) above which — while currently on `.course` —
    /// the source may enter `.streetSnap` (subject to `hasBlockMatch`). On-device-tunable.
    static let enterCourseAccuracyDeg: Double = 45

    /// `CLLocation.courseAccuracy` (degrees) at or below which — while currently on
    /// `.streetSnap` — the source may exit back to `.course` (requires speed to also clear
    /// `exitSpeedMPS`). Deliberately lower than `enterCourseAccuracyDeg` (hysteresis).
    static let exitCourseAccuracyDeg: Double = 25
}

// MARK: - DriveHeadingSnap

/// Pure decision functions for TF2-16 heading-source selection and street-snap bearing.
///
/// All methods are `static` free functions so they are directly testable without
/// constructing any object, and carry no state.
enum DriveHeadingSnap {

    // MARK: - Source selection (hysteresis)

    /// Pure hysteresis state-machine step: decides whether the camera heading should be
    /// driven by raw GPS course or by the matched street segment's own bearing.
    ///
    /// Entering `.streetSnap` is gated on speed and course accuracy only — NOT on
    /// course/EMA disagreement, which is the correct, trustworthy signature of a real
    /// turn in progress and must never be misread as "noise, snap to the old street"
    /// (spec §5.3). Exiting back to `.course` uses the same two signals, so a driver
    /// accelerating out of a turn (where course legitimately swings) is never held on
    /// the pre-turn street's bearing.
    ///
    /// - Parameters:
    ///   - current: The heading source in effect on the previous tick.
    ///   - hasBlockMatch: Whether the driver is currently matched to a street segment
    ///     (`DrivingContextService.matchedSegment != nil`). When `false`, always returns
    ///     `.course` unconditionally (item 5: freeze-on-stop behavior is unchanged;
    ///     `LocationService.stabilizedHeading` already handles that case).
    ///   - speed: Current speed in m/s. Callers should clamp to `>= 0` before calling.
    ///   - courseAccuracy: `CLLocation.courseAccuracy` in degrees; `nil` when unavailable
    ///     or CoreLocation reported an invalid (negative) value.
    /// - Returns: The heading source that should drive the camera/puck on this tick.
    static func nextHeadingSource(
        current: HeadingSourceKind,
        hasBlockMatch: Bool,
        speed: Double,
        courseAccuracy: Double?
    ) -> HeadingSourceKind {
        guard hasBlockMatch else { return .course }

        let lowConfidence =
            speed < DriveHeadingSnapConstants.enterSpeedMPS
            || courseAccuracy == nil
            || courseAccuracy! > DriveHeadingSnapConstants.enterCourseAccuracyDeg

        let highConfidence =
            speed >= DriveHeadingSnapConstants.exitSpeedMPS
            && courseAccuracy != nil
            && courseAccuracy! <= DriveHeadingSnapConstants.exitCourseAccuracyDeg

        switch current {
        case .course:
            return lowConfidence ? .streetSnap : .course
        case .streetSnap:
            return highConfidence ? .course : .streetSnap
        }
    }

    // MARK: - Bearing selection

    /// Selects the heading value to use while the source is `.streetSnap`.
    ///
    /// One-way segments (`oneway == true` with a valid `onewayToward`) always return
    /// that direction's bearing, unconditionally — matches Kevin's explicit direction
    /// (spec item 1). Two-way segments (or malformed/missing one-way data) pick
    /// whichever of the segment's two directions is circularly closer to
    /// `lastGoodHeading` — the last trustworthy EMA value before confidence dropped
    /// (spec item 3). With no `lastGoodHeading` available, defaults to the forward
    /// (`toward_to`) bearing — a stable, deterministic, arbitrary-but-consistent choice
    /// that never oscillates on its own.
    ///
    /// - Parameters:
    ///   - segment: The street segment the driver is currently matched to.
    ///   - lastGoodHeading: `locationService.driveHeading` at the moment of the call
    ///     (the last trustworthy EMA value before confidence dropped), or `nil` if none
    ///     is available yet (e.g. first-ever tick in snap mode).
    /// - Returns: Compass bearing in degrees [0, 360).
    static func snappedHeading(segment: Segment, lastGoodHeading: Double?) -> Double {
        let towardBearing = SegmentBearing.bearing(segment: segment, toward: .toward_to)
        let reverseBearing = (towardBearing + 180).truncatingRemainder(dividingBy: 360)

        if segment.oneway == true {
            switch segment.onewayToward {
            case "to":
                return towardBearing
            case "from":
                return reverseBearing
            default:
                break  // malformed data — fall through to two-way logic
            }
        }

        // Two-way (or oneway data missing/malformed): pick whichever direction is
        // circularly closer to the last known good heading.
        guard let last = lastGoodHeading else { return towardBearing }
        return circularDelta(towardBearing, last) <= circularDelta(reverseBearing, last)
            ? towardBearing : reverseBearing
    }

    // MARK: - Private math

    /// Smallest angular distance between two compass bearings, in [0, 180].
    /// Wraps correctly across the 0°/360° boundary.
    private static func circularDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }
}

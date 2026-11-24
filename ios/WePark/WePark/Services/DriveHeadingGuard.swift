//
//  DriveHeadingGuard.swift
//  WePark
//
//  Wrong-way heading hardening (build-24 field report, Kevin, 2026-11-02: "the current
//  app direction is no good" — a distinct failure class from the known EMA-convergence lag
//  that open item #36 / PR #132 already tracks). Two pure, independently-testable guards
//  sit UPSTREAM of `LocationService.stabilizedHeading`'s EMA:
//
//    1. Course-quality gate (`courseAccuracyQualifies`) — a single GPS course fix whose
//       reported `CLLocation.courseAccuracy` is worse than a threshold contributes nothing;
//       treated exactly like the existing below-speed freeze (OQ-6: freeze, not snap).
//    2. Large-flip confirmation (`DriveHeadingFlipGuard`) — a qualified course that differs
//       from the current smoothed heading by more than a threshold is held, not fed to the
//       EMA, until N consecutive fixes agree with it. Rejects a one-fix glitch outright;
//       still adopts a genuine reversal (e.g. backing into a spot) after N fixes; never
//       holds a progressive sweep (a real U-turn), because no single fix in a progressive
//       sweep differs from the current smoothed heading by more than the flip threshold.
//
//  Both pieces are pure value types — no CLLocationManager, no UIKit, no SwiftUI — so
//  they're directly unit-testable with no real location session (same discipline as
//  `DriveHeadingSnap.swift` / `FinalApproachService.swift`).
//
//  No Calendar.current. No force-unwraps.
//

import Foundation
import CoreLocation

// MARK: - Tuning knobs

/// REAL-ROAD TUNING KNOBS (same precedent as open item #36 / PR #132's EMA-alpha knobs):
/// ship live, calibrate against Kevin's next on-device drive-test — not configuration to
/// treat as final.
enum DriveHeadingGuardConstants {

    /// `CLLocation.courseAccuracy` (degrees) above which a REPORTED course fix is treated as
    /// garbage and contributes nothing to the heading (freeze on last good — same behavior
    /// as the existing below-speed path). A `nil` accuracy (CoreLocation's "unavailable"
    /// sentinel — see `courseAccuracyQualifies` doc below) always passes; this threshold
    /// only screens a fix CoreLocation has POSITIVELY flagged as low-confidence.
    ///
    /// Raise if good fixes are being rejected too often (heading freezes mid-turn — dense
    /// Manhattan canyons can run courseAccuracy high even for a correct course). Lower if a
    /// wrong-way fix is still slipping through (heading briefly points backwards).
    static let maxCourseAccuracyDeg: Double = 45.0

    /// How far a new, gated, speed-qualified course must differ from the CURRENT smoothed
    /// heading before it's treated as a "large flip" requiring confirmation instead of
    /// going straight to the EMA. Lower makes the guard trigger on smaller jumps (safer
    /// against glitches, but can delay a genuine sharp turn registering immediately).
    /// Higher lets more jumps straight through (faster response to a real turn, more
    /// exposure to the wrong-way bug this guard exists to close).
    static let flipThresholdDeg: Double = 120.0

    /// Number of CONSECUTIVE qualified fixes — each within `flipConfirmToleranceDeg` of the
    /// challenger — required before a large flip is adopted. Raise to reject noisier
    /// glitches (costs more lag reversing or finishing a sharp turn). Lower to adopt flips
    /// faster (less lag, more exposure to a one-fix glitch getting adopted).
    static let flipConfirmFixes: Int = 2

    /// How tightly consecutive confirming fixes must agree with the challenger (and each
    /// other) to count as "the same new direction" rather than more noise. Raise to confirm
    /// faster through noisy conditions (e.g. a slow, wandering reverse). Lower to require a
    /// cleaner signal before trusting the flip.
    static let flipConfirmToleranceDeg: Double = 30.0

    // MARK: Idle hold (build-27 smoke finding 10)

    /// Speed (m/s) a fix must reach, for `holdResumeFixes` CONSECUTIVE fixes, to release the
    /// idle heading hold. Well above GPS Doppler noise at standstill (urban canyons report
    /// phantom 0.5-1.5 m/s with a random course) yet below any real driving speed, so a car
    /// pulling away from a light clears it in about two seconds. Raise if the heading still
    /// wanders while stopped; lower if the heading lags noticeably after pulling away.
    static let holdResumeSpeedMPS: Double = 2.0

    /// Consecutive fixes at or above `holdResumeSpeedMPS` required to release the hold.
    /// 2 rejects a single phantom speed spike (one noisy fix) while adding only ~1 s of
    /// latency at 1 Hz GPS.
    static let holdResumeFixes: Int = 2

    /// Displacement (meters) from where the hold began that releases it regardless of
    /// speed. Covers a slow creep (parking crawl below `holdResumeSpeedMPS`): once the car
    /// has really travelled this far, its course is trustworthy again. Chosen above typical
    /// urban GPS jitter at a standstill (3-8 m) so noise alone cannot release the hold.
    static let holdResumeDistanceM: Double = 10.0
}

// MARK: - Idle hold

/// Pure state machine (build-27 smoke finding 10): once the car is stopped, the drive
/// heading HOLDS the last good value until the car has demonstrably moved again.
///
/// Before this, only fixes below `stoppedBelowSpeed` were frozen. GPS speed noise while
/// idle (0.5-2 m/s with a random course, or a 4 m+ position jitter feeding the
/// course-from-movement fallback) leaked through that single threshold and spun the puck.
/// Now a stop ENGAGES the hold, and only sustained speed or real displacement RELEASES it.
struct DriveHeadingHold {

    /// True while the hold is engaged.
    private(set) var isHeld: Bool = false

    private var anchorLat: Double = 0
    private var anchorLng: Double = 0
    private var fastFixes: Int = 0

    nonisolated init() {}

    /// Feeds one fix. Returns `true` when this fix must NOT influence the heading.
    ///
    /// - Parameters:
    ///   - speed: Fix speed in m/s (clamped >= 0 by the caller).
    ///   - coordinate: Fix position.
    ///   - stoppedBelowSpeed: Speed under which the car counts as stopped (engages the hold).
    nonisolated mutating func shouldHold(
        speed: Double,
        coordinate: CLLocationCoordinate2D,
        stoppedBelowSpeed: Double
    ) -> Bool {
        if speed < stoppedBelowSpeed {
            if !isHeld {
                isHeld = true
                anchorLat = coordinate.latitude
                anchorLng = coordinate.longitude
            }
            fastFixes = 0
            return true
        }
        guard isHeld else { return false }

        if speed >= DriveHeadingGuardConstants.holdResumeSpeedMPS {
            fastFixes += 1
        } else {
            fastFixes = 0
        }
        let moved = DriveHeadingHold.distanceMeters(
            lat1: anchorLat, lng1: anchorLng,
            lat2: coordinate.latitude, lng2: coordinate.longitude
        )
        if fastFixes >= DriveHeadingGuardConstants.holdResumeFixes
            || moved >= DriveHeadingGuardConstants.holdResumeDistanceM {
            isHeld = false
            fastFixes = 0
            return false
        }
        return true
    }

    /// Equirectangular distance in meters (accurate to well under 1% at city scale).
    nonisolated static func distanceMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let metersPerDegLat = 111_320.0
        let dy = (lat2 - lat1) * metersPerDegLat
        let dx = (lng2 - lng1) * metersPerDegLat * cos(((lat1 + lat2) / 2) * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Change 1: course-quality gate

/// Pure course-quality gate (wrong-way hardening change 1).
///
/// `courseAccuracy` semantics, verified against Apple's `CLLocation.courseAccuracy`
/// documentation (developer.apple.com, checked 2026-11): Apple's property docs state "when
/// this property contains a negative number, the value in the course property is invalid"
/// — but that line describes the contract for the MANUAL
/// `CLLocation(coordinate:...:course:courseAccuracy:...)` initializer (guidance for callers
/// constructing a `CLLocation`, e.g. test fixtures or GPX tooling), not the observed
/// behavior of OS-generated fixes from a real `CLLocationManager` session. `course` itself
/// carries an INDEPENDENT, long-standing validity sentinel (it predates `courseAccuracy`,
/// which only shipped in iOS 13.4) — already enforced upstream of this gate via the
/// existing `loc.course >= 0 ? loc.course : nil` check in
/// `LocationService.locationManager(_:didUpdateLocations:)`. In practice, devices/OS paths
/// that don't populate `courseAccuracy` (and the iOS Simulator, which frequently reports -1
/// for synthesized/GPX routes) report `courseAccuracy == -1` ALONGSIDE a perfectly
/// legitimate, non-negative `course`. The existing `driveCourseAccuracy` sentinel-parsing
/// tests (`LocationServiceDriveCourseAccuracyTests`, TF2-16 AC-2) already assert exactly
/// this split: `courseAccuracy: -1.0` publishes `driveCourseAccuracy == nil`
/// ("unavailable"), not "course invalid." This gate honors that existing contract: a `nil`
/// (unavailable) accuracy PASSES — rejecting it would brick heading entirely on the
/// Simulator and on any hardware/OS path that never populates the field. Only a REPORTED,
/// numeric accuracy worse than `DriveHeadingGuardConstants.maxCourseAccuracyDeg` is treated
/// as garbage.
///
/// - Parameter courseAccuracy: `CLLocation.courseAccuracy` in degrees, or `nil` when
///   CoreLocation reported a negative ("unavailable") value — matches
///   `LocationService.driveCourseAccuracy`'s existing nil-sentinel contract.
/// - Returns: `true` if a course fix with this accuracy should be allowed to reach the
///   heading pipeline; `false` if it should be dropped (freeze on last good heading, same
///   as the below-speed path).
nonisolated func courseAccuracyQualifies(_ courseAccuracy: CLLocationDirection?) -> Bool {
    guard let accuracy = courseAccuracy else { return true }
    return accuracy <= DriveHeadingGuardConstants.maxCourseAccuracyDeg
}

// MARK: - Change 2: large-flip confirmation

/// The outcome of feeding one new qualified course fix through `DriveHeadingFlipGuard`.
enum DriveHeadingFlipOutcome: Equatable {
    /// Not a large flip (or nothing established to flip from yet) — feed `heading` to the
    /// ordinary alpha-weighted EMA exactly as today.
    case blend(CLLocationDirection)
    /// A large flip is confirmed on THIS fix — adopt `heading` directly, bypassing the EMA
    /// blend, so the puck snaps crisply to the new direction instead of slow-blending
    /// through the wrap.
    case adopt(CLLocationDirection)
    /// A large flip is in progress but not yet confirmed — hold `heading` (the caller's
    /// current smoothed heading, unchanged) and wait for more agreeing fixes.
    case hold(CLLocationDirection)
}

/// Pure state machine (wrong-way hardening change 2): holds a large course flip for
/// `DriveHeadingGuardConstants.flipConfirmFixes` consecutive qualified fixes before
/// adopting it, so a single garbage/reversed fix can't snap the puck the wrong way.
///
/// Fed fix-by-fix from `LocationService.stabilizedHeading` — mirrors
/// `FinalApproachService`'s pure-function-per-tick style, but needs a sliver of
/// cross-tick state (the challenger heading + how many fixes have agreed with it so far),
/// so it's a tiny value type instead of a static function. No CoreLocation session
/// dependency beyond `CLLocationDirection` (a plain `Double` typealias) — directly
/// unit-testable with no framework session.
///
/// Usage contract: call `next(current:candidate:)` ONLY with a candidate that has ALREADY
/// passed the speed gate and `courseAccuracyQualifies` above — this guard's only job is the
/// large-flip confirmation, not re-deriving those other gates.
struct DriveHeadingFlipGuard {

    /// The candidate heading currently being challenged against `current`, or `nil` if no
    /// flip is in progress.
    private var challenger: CLLocationDirection?

    /// Consecutive qualified fixes that have agreed with `challenger` so far.
    private var confirmCount: Int = 0

    init() {}

    /// Feeds one new qualified course fix through the flip guard.
    ///
    /// - `candidate` within `flipThresholdDeg` of `current` (or `current == nil` — nothing
    ///   established yet to flip from): not a large flip at all. Clears any in-progress
    ///   hold and returns `.blend(candidate)` — the ordinary EMA-feed path. A genuine
    ///   U-turn sweeps progressively and never trips this branch, because no single fix in
    ///   a progressive sweep differs from the current smoothed heading by more than
    ///   `flipThresholdDeg`.
    /// - `candidate` IS a large flip:
    ///   - A NEW challenger (doesn't match the one already held, within
    ///     `flipConfirmToleranceDeg`) resets the count to 1 and returns `.hold(current)` —
    ///     the flip is not fed yet.
    ///   - A MATCHING challenger increments the count. Below `flipConfirmFixes`, returns
    ///     `.hold(current)` again. At or above `flipConfirmFixes`, the flip is confirmed:
    ///     clears the hold and returns `.adopt(candidate)` — a crisp jump, not a slow blend
    ///     through the wrap.
    ///
    /// - Parameters:
    ///   - current: The caller's current smoothed heading (`headingEMA`) before this fix,
    ///     or `nil` if none is established yet.
    ///   - candidate: The new, gated, speed-qualified raw course for this fix.
    /// - Returns: The outcome describing how the caller should update its EMA this tick.
    mutating func next(current: CLLocationDirection?, candidate: CLLocationDirection) -> DriveHeadingFlipOutcome {
        guard let current else {
            challenger = nil
            confirmCount = 0
            return .blend(candidate)
        }

        let flipMagnitude = DriveHeadingFlipGuard.circularDelta(candidate, current)
        guard flipMagnitude > DriveHeadingGuardConstants.flipThresholdDeg else {
            // Not a large flip — ordinary path, clear any stale hold.
            challenger = nil
            confirmCount = 0
            return .blend(candidate)
        }

        if let held = challenger,
           DriveHeadingFlipGuard.circularDelta(candidate, held) <= DriveHeadingGuardConstants.flipConfirmToleranceDeg {
            confirmCount += 1
        } else {
            challenger = candidate
            confirmCount = 1
        }

        if confirmCount >= DriveHeadingGuardConstants.flipConfirmFixes {
            // Confirmed — adopt crisply, clear the hold.
            challenger = nil
            confirmCount = 0
            return .adopt(candidate)
        }

        // Still unconfirmed — hold the previous heading.
        return .hold(current)
    }

    /// Smallest angular distance between two compass bearings, in [0, 180]. Wraps correctly
    /// across the 0°/360° boundary. Mirrors `DriveHeadingSnap.circularDelta`; duplicated
    /// rather than shared because that one is `private` to a different file and this is a
    /// two-line pure function.
    nonisolated static func circularDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }
}

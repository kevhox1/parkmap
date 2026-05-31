//
//  FinalApproachService.swift
//  WePark
//
//  W8.5d: Final-approach state machine and voice-gap pure functions.
//
//  All methods are static — no instance, no MKMapView, no AVSpeechSynthesizer,
//  no CoreLocation dependency. Trivially unit-testable (see WeParkTests/W85dTests.swift).
//
//  State machine:
//    .outside    — driver is more than 500m from destination (normal Drive Mode)
//    .approaching — driver is between 50m and 500m (inclusive at 500m, exclusive at 50m)
//    .arrived    — driver is within 50m (inclusive at 50m)
//
//  Voice gaps:
//    .outside    → 12 seconds (matches DRIVING_VOICE_MIN_GAP_S baseline)
//    .approaching → 4 seconds (OQ-2: ~half-block cadence at 30 mph; calibration target)
//    .arrived    → .infinity  (voice suppressed; arrival prompt is the user-facing cue)
//
//  Constants are exposed as static let so unit tests can reference them for boundary
//  coverage without magic numbers.
//
//  No Calendar.current.
//  No hardcoded Mapbox tokens.
//

import Foundation

// MARK: - FinalApproachState

/// The driver's proximity state relative to the Drive Mode destination.
///
/// Drives the approaching-strip visibility, voice cue cadence, and arrival prompt trigger.
/// Equatable so `.onChange(of: finalApproachState)` fires only on real state transitions.
enum FinalApproachState: Equatable {
    /// Driver is more than `FinalApproachService.approachThresholdMeters` from destination.
    case outside
    /// Driver is between the arrival and approach thresholds (500m ≥ distance > 50m).
    case approaching
    /// Driver is within `FinalApproachService.arrivalThresholdMeters` of destination.
    case arrived
}

// MARK: - FinalApproachService

/// Pure-function state machine for Drive Mode final-approach logic.
///
/// All methods are static — no instance state, no side effects, no framework dependencies.
/// `ContentView` calls these functions from `.onChange(of: driveModeDistanceMeters)` to
/// derive state transitions, then acts on those transitions (show/hide strip, change voice
/// gap, fire arrival prompt). W8.5d spec §3.1.
///
/// ## Reuse note (W8.5e–i patrol mode)
/// `finalApproachState(forDistanceMeters:)` is designed for reuse in patrol mode's
/// per-waypoint approach detection. Pass the per-waypoint distance instead of the
/// destination distance — no structural change to this service needed.
enum FinalApproachService {

    // MARK: - Threshold constants

    /// Distance (meters) at which the driver enters the "approaching" state.
    /// Default: 500m (~5.5 Manhattan blocks). Calibration target post-drive-test.
    static let approachThresholdMeters: Double = 500.0

    /// Distance (meters) at which the driver is considered "arrived".
    /// Default: 50m (Manhattan GPS canyon empirical; drive-test calibration target).
    /// AC-DM.20 spec: within 100m; this tighter inner threshold aligns with OQ-4 resolution.
    static let arrivalThresholdMeters: Double = 50.0

    // MARK: - Voice gap constants

    /// Baseline voice cue minimum gap (seconds). Matches `DRIVING_VOICE_MIN_GAP_S` in
    /// `DrivingContextService`. Extracted here so `FinalApproachService.voiceGap(for: .outside)`
    /// stays in sync with the service's baseline.
    static let baselineVoiceGapSeconds: TimeInterval = 12.0

    /// Voice gap during final approach (seconds). OQ-2 resolution: 4s ≈ 54m at 30 mph
    /// (~half a Manhattan block between cues). Calibration target after drive-test.
    static let approachVoiceGapSeconds: TimeInterval = 4.0

    // MARK: - State machine

    /// Returns the `FinalApproachState` for a given distance (meters) to the destination.
    ///
    /// Decision logic (W8.5d spec §3.1):
    /// - `distance <= arrivalThresholdMeters` → `.arrived`
    /// - `distance <= approachThresholdMeters` → `.approaching`
    /// - Otherwise → `.outside`
    ///
    /// Edge cases:
    /// - Negative distance (GPS momentary artifact) is treated as `.arrived` — safe default,
    ///   prevents a no-op when the driver is effectively at the destination.
    /// - Exactly at a threshold is inclusive of the closer-to-destination state
    ///   (e.g., distance == 50m → `.arrived`; distance == 500m → `.approaching`).
    ///
    /// - Parameter distance: Driver's distance from destination in meters.
    ///   Values ≤ 0 are treated as `.arrived`.
    /// - Returns: The current `FinalApproachState`.
    static func finalApproachState(forDistanceMeters distance: Double) -> FinalApproachState {
        if distance <= arrivalThresholdMeters   { return .arrived }
        if distance <= approachThresholdMeters  { return .approaching }
        return .outside
    }

    // MARK: - Voice gap

    /// Returns the minimum voice cue gap (seconds) for a given approach state.
    ///
    /// - `.outside`    → `baselineVoiceGapSeconds` (12s, matches `DrivingContextService` default)
    /// - `.approaching` → `approachVoiceGapSeconds` (4s, elevated cadence during final approach)
    /// - `.arrived`    → `.infinity` (voice suppressed; arrival prompt is the cue)
    ///
    /// When `DrivingContextService.voiceMinGapSeconds` is set to `.infinity`, the
    /// `speakContext` guard (`now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds`)
    /// always returns early — voice is effectively suppressed with no new code path.
    ///
    /// - Parameter state: The current `FinalApproachState`.
    /// - Returns: Minimum gap in seconds between voice cues.
    static func voiceGap(for state: FinalApproachState) -> TimeInterval {
        switch state {
        case .outside:    return baselineVoiceGapSeconds
        case .approaching: return approachVoiceGapSeconds
        case .arrived:    return .infinity
        }
    }
}

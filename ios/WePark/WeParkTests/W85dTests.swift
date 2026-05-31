//
//  W85dTests.swift
//  WeParkTests
//
//  W8.5d unit tests: FinalApproachService pure functions.
//
//  Strategy: pure-function decision layer only (per spec §5 and PR-3/PR-2 precedent).
//  No MKMapView, no AVSpeechSynthesizer, no CoreLocation, no live GPS.
//  All state-machine and voice-gap logic is in FinalApproachService — static, no instance.
//
//  Test inventory (12 tests, target: 8–12 per spec §5):
//
//  State machine — boundary coverage:
//    1. testFinalApproachState_farOutside_isOutside         — distance = 1000 → .outside
//    2. testFinalApproachState_exactApproachThreshold_isApproaching — distance = 500 → .approaching
//    3. testFinalApproachState_insideApproachZone_isApproaching     — distance = 250 → .approaching
//    4. testFinalApproachState_justAboveArrivalThreshold_isApproaching — distance = 51 → .approaching
//    5. testFinalApproachState_exactArrivalThreshold_isArrived    — distance = 50 → .arrived
//    6. testFinalApproachState_nearZero_isArrived                 — distance = 1  → .arrived
//    7. testFinalApproachState_zero_isArrived                     — distance = 0  → .arrived
//    8. testFinalApproachState_negativeInput_isArrived            — distance = -5 → .arrived
//
//  Voice gap:
//    9. testVoiceGap_outside_is12Seconds
//   10. testVoiceGap_approaching_isEscalated      — gap < 12.0 (less than baseline)
//   11. testVoiceGap_arrived_suppressesVoice      — gap == .infinity
//
//  Threshold constants:
//   12. testThresholds_approachIsGreaterThanArrival — approachThreshold > arrivalThreshold
//
//  Baseline before W8.5d: 228/0. After W8.5d: 240/0 (228 + 12 new).
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
@testable import WePark

final class W85dTests: XCTestCase {

    // MARK: - State machine — boundary coverage

    /// AC-1: distance > approachThresholdMeters → .outside
    func testFinalApproachState_farOutside_isOutside() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 1000.0)
        XCTAssertEqual(result, .outside, "1000m is well outside the approach zone (threshold: 500m)")
    }

    /// AC-2: distance == approachThresholdMeters → .approaching (threshold is inclusive)
    func testFinalApproachState_exactApproachThreshold_isApproaching() {
        let distance = FinalApproachService.approachThresholdMeters  // 500.0
        let result = FinalApproachService.finalApproachState(forDistanceMeters: distance)
        XCTAssertEqual(result, .approaching,
            "Exactly at the 500m approach threshold should be .approaching (inclusive)")
    }

    /// AC-2: 499m → .approaching (inside approach zone)
    func testFinalApproachState_justInsideApproachThreshold_isApproaching() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 499.0)
        XCTAssertEqual(result, .approaching, "499m is inside the approach zone")
    }

    /// AC-2: distance = 250 → .approaching
    func testFinalApproachState_insideApproachZone_isApproaching() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 250.0)
        XCTAssertEqual(result, .approaching, "250m is inside the approach zone")
    }

    /// AC-2: distance = 51 → .approaching (just above arrival threshold)
    func testFinalApproachState_justAboveArrivalThreshold_isApproaching() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 51.0)
        XCTAssertEqual(result, .approaching,
            "51m is above the 50m arrival threshold — should be .approaching")
    }

    /// AC-3: distance == arrivalThresholdMeters → .arrived (threshold is inclusive)
    func testFinalApproachState_exactArrivalThreshold_isArrived() {
        let distance = FinalApproachService.arrivalThresholdMeters  // 50.0
        let result = FinalApproachService.finalApproachState(forDistanceMeters: distance)
        XCTAssertEqual(result, .arrived,
            "Exactly at the 50m arrival threshold should be .arrived (inclusive)")
    }

    /// AC-3: distance = 1 → .arrived
    func testFinalApproachState_nearZero_isArrived() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 1.0)
        XCTAssertEqual(result, .arrived, "1m is well within the arrival threshold")
    }

    /// AC-3: distance = 0 → .arrived
    func testFinalApproachState_zero_isArrived() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: 0.0)
        XCTAssertEqual(result, .arrived, "0m (at destination) should be .arrived")
    }

    /// Edge case: negative distance (GPS momentary artifact) → .arrived (safe default).
    /// Prevents a no-op when the driver is effectively at the destination.
    func testFinalApproachState_negativeInput_isArrived() {
        let result = FinalApproachService.finalApproachState(forDistanceMeters: -5.0)
        XCTAssertEqual(result, .arrived,
            "Negative distance (GPS artifact) should be treated as .arrived, not crash or .outside")
    }

    // MARK: - Voice gap

    /// AC-4: .outside → baselineVoiceGapSeconds (12.0)
    func testVoiceGap_outside_is12Seconds() {
        let gap = FinalApproachService.voiceGap(for: .outside)
        XCTAssertEqual(gap, 12.0,
            "Voice gap for .outside should match the DRIVING_VOICE_MIN_GAP_S baseline (12s)")
    }

    /// AC-5: .approaching → escalated gap (less than the 12s baseline)
    func testVoiceGap_approaching_isEscalated() {
        let gap = FinalApproachService.voiceGap(for: .approaching)
        let baseline = FinalApproachService.baselineVoiceGapSeconds
        XCTAssertLessThan(gap, baseline,
            "Voice gap during approach (\(gap)s) should be less than the baseline (\(baseline)s)")
        // Also verify the specific OQ-2 resolved value (4s) is what shipped.
        XCTAssertEqual(gap, 4.0,
            "Approaching voice gap should be 4.0s (OQ-2 resolution — drive-test calibration target)")
    }

    /// AC-6: .arrived → voice suppressed (gap == .infinity)
    func testVoiceGap_arrived_suppressesVoice() {
        let gap = FinalApproachService.voiceGap(for: .arrived)
        XCTAssertEqual(gap, .infinity,
            "Voice gap for .arrived should be .infinity to suppress voice (arrival prompt is the cue)")
    }

    // MARK: - Threshold constants

    /// Ensures approach threshold is strictly greater than arrival threshold.
    /// Invariant: if approachThreshold <= arrivalThreshold, the .approaching state is unreachable.
    func testThresholds_approachIsGreaterThanArrival() {
        XCTAssertGreaterThan(
            FinalApproachService.approachThresholdMeters,
            FinalApproachService.arrivalThresholdMeters,
            "approachThresholdMeters (\(FinalApproachService.approachThresholdMeters)m) " +
            "must be strictly greater than arrivalThresholdMeters " +
            "(\(FinalApproachService.arrivalThresholdMeters)m) — " +
            "if not, the .approaching state is unreachable"
        )
    }
}

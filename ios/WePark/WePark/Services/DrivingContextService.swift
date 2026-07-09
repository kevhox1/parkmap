//
//  DrivingContextService.swift
//  WePark
//
//  W8.5c: Swift port of `getCurrentDrivingContext` (index.html:5557–5587) +
//         `speakDrivingContext` (index.html:5957–5979) merged into one service.
//  CM-2: Cruise Mode extension — `setCruiseMode(_:)` switches voice cadence to
//         `CruiseVoicePolicy` (gate on at least one free/metered side) + Cruise Mode
//         phrasing via `CruiseVoicePolicy.utteranceText(for:)`.
//  TF2-7: Side-level aggregation — `SideOpportunity` + `aggregateSide(segments:side:engine:date:minimumFreeLength:)`
//         replaces single-segment `safetyLabel` calls in `update(...)`.
//         Voice copy updated to use catch-all templates (§4.1) — "Free parking sections on
//         the [side] — check signs." / "Metered on the [side]." / "No parking on either side."
//
//  Responsibilities:
//    - Find the closest block to the driver's GPS position.
//    - Classify N/S/E/W sides as "left" or "right" relative to the driver's heading.
//    - Aggregate ALL segments on each cardinal side via aggregateSide → SideOpportunity.
//    - Compute safety label for each side (wrapped from SideOpportunity for downstream use).
//    - Detect block changes and trigger voice cues via DrivingVoice.
//    - In Cruise Mode: gate announcements via CruiseVoicePolicy.shouldAnnounce, and
//      use CruiseVoicePolicy.utteranceText for Cruise-specific phrasing.
//
//  OQ-4: Voice always speaks real-time status, ignoring W7.5 Park Until filter.
//  Voice minimum gap (DRIVING_VOICE_MIN_GAP_S): 12 seconds default.
//  Calibration of all timing constants deferred to W8.5c-follow after drive-test.
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import CoreLocation
import Observation

// MARK: - DrivingContext

/// Value type describing the current parking context while driving.
/// Left/Right relative to the driver's heading.
struct DrivingContext: Equatable {
    let street: String
    let from: String
    let to: String
    let leftLabel: SafetyLabel
    let rightLabel: SafetyLabel

    /// Block identity key for change detection. Mirrors PWA: `${ctx.street}|${ctx.from}|${ctx.to}`.
    var blockKey: String { "\(street)|\(from)|\(to)" }
}

// MARK: - TF2-7: SideOpportunity

/// Aggregated parking opportunity for one side of the current block.
///
/// Returned by `DrivingContextService.aggregateSide(segments:side:engine:date:minimumFreeLength:)`.
/// Reduces all segments on one cardinal side to a single actionable classification.
///
/// Mapping to voice + card (spec §3.2):
///   `.free`       → "Free parking sections on the [left/right] — check signs."
///   `.metered`    → "Metered on the [left/right]."
///   `.restricted` → (silent in Cruise Mode; "No parking on either side." in destination mode when both restricted)
///   `.unknown`    → (silent)
enum SideOpportunity: Equatable {
    /// At least one qualifying free-now stretch ≥ minimumFreeLength exists on this side.
    case free
    /// No qualifying free stretch; at least one metered segment exists.
    case metered
    /// No free or metered segments — entire side is restricted or no-standing.
    case restricted
    /// No segments found for this side (data gap).
    case unknown
}

// MARK: - Side bearing constants

/// Compass bearing for each cardinal side (degrees from north, clockwise).
/// Port of `SIDE_BEARING` constant from index.html:5532.
private let sideBearing: [String: Double] = ["N": 0, "E": 90, "S": 180, "W": 270]

// MARK: - DrivingContextService

/// Parking commentary engine for Drive Mode.
/// Port of `getCurrentDrivingContext` (index.html:5557–5587) +
/// block-change-detection + `speakDrivingContext` (index.html:5957–5979).
@Observable
final class DrivingContextService {

    // MARK: - Published state

    /// Current driving context. Nil when no segment is within range.
    private(set) var currentContext: DrivingContext?

    /// TF2-16: The segment closest to the driver's GPS position, as found by `update()`'s
    /// existing closest-segment lookup (`findClosestSegment`). Nil when `update()` finds no
    /// segment (mirrors `currentContext == nil`). Purely additive — exposes the same result
    /// `update()` already computes internally; no second matcher/distance-search is introduced.
    /// Consumed by `ContentView.handleLocationUpdate()` as the `hasBlockMatch` / snap-target
    /// input to `DriveHeadingSnap`.
    private(set) var matchedSegment: Segment?

    // MARK: - Block change detection (index.html:5905–5908)

    /// Block key from the most recent call. Nil on first call.
    private var lastBlockKey: String?

    /// Timestamp of the last voice cue. Used for minimum-gap enforcement.
    private var lastSpokenAt: Date = .distantPast

    // MARK: - CM-2: Cruise Mode state

    /// True when the service is operating in Cruise Mode ("Find Parking").
    ///
    /// When true:
    ///   - `CruiseVoicePolicy.shouldAnnounce(context:)` gates each block-change announcement.
    ///     Blocks where both sides are restricted or unknown are silent.
    ///   - `CruiseVoicePolicy.utteranceText(for:)` supplies the announcement text,
    ///     which leads with the parking opportunity ("Free parking on left") rather than
    ///     the neutral destination-mode format ("Left side, free until...").
    ///   - The mute gate (`driveVoiceMuted`) is checked by the caller in `speakContext`
    ///     via `DrivingVoice.speak` — NOT inside `CruiseVoicePolicy.shouldAnnounce`
    ///     (which must remain a pure function of parking context for testability).
    ///
    /// When false (destination mode), the pre-CM-2 unconditional behavior is preserved —
    /// every block change triggers a voice cue (no regression).
    ///
    /// Set via `setCruiseMode(_:)`. Reset to `false` on Drive Mode exit.
    private var isCruiseMode: Bool = false

    // MARK: - Constants

    /// Minimum gap between voice cues (seconds).
    ///
    /// W8.5d: Changed from `private let` (immutable) to `private var` (settable) so
    /// `ContentView`'s `.onChange(of: driveModeDistanceMeters)` can update the gap when
    /// `FinalApproachState` changes:
    ///   - `.outside`    → 12s (baseline, port of DRIVING_VOICE_MIN_GAP_MS = 12000)
    ///   - `.approaching` → 4s  (elevated cadence during final approach, OQ-2)
    ///   - `.arrived`    → .infinity (suppresses voice; arrival prompt is the cue)
    ///
    /// Updated via `setVoiceGap(_:)` called from `ContentView` on the main thread.
    /// Reset to baseline when `DrivingContextService` is re-instantiated at the start
    /// of each Drive Mode session (see `handleDriveModeChange` in `ContentView`).
    /// Calibration deferred to W8.5c-follow after drive-test.
    private var voiceMinGapSeconds: TimeInterval = FinalApproachService.baselineVoiceGapSeconds

    // MARK: - Dependencies

    private let voice: DrivingVoice

    // MARK: - Init

    init(voice: DrivingVoice) {
        self.voice = voice
    }

    // MARK: - W8.5d: Voice gap update

    /// Sets the minimum gap between voice cues for the current Drive Mode session.
    ///
    /// Called from `ContentView`'s `.onChange(of: driveModeDistanceMeters)` handler
    /// (`handleFinalApproachUpdate`) on the main thread when `FinalApproachState` changes.
    ///
    /// Use `FinalApproachService.voiceGap(for:)` to derive the value:
    /// - `.outside`    → 12s (baseline, matches pre-W8.5d constant)
    /// - `.approaching` → 4s  (elevated cadence during final approach)
    /// - `.arrived`    → .infinity (suppresses voice; arrival prompt is the user cue)
    ///
    /// When `gap == .infinity`, the `speakContext` guard
    /// (`now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds`) always returns early,
    /// effectively suppressing voice with no new code path needed.
    ///
    /// Thread safety: must be called from the main thread (same thread as the
    /// `.onChange` modifier — `@Observable` property mutations are safe on main).
    func setVoiceGap(_ gap: TimeInterval) {
        voiceMinGapSeconds = gap
    }

    // MARK: - CM-2: Cruise Mode toggle

    /// Switches the voice cadence policy for the current Drive Mode session.
    ///
    /// Call with `true` immediately after `driveModeActive = true` for Cruise Mode entry,
    /// and with `false` on Drive Mode exit (or destination mode entry).
    ///
    /// When `isCruise == true`:
    ///   - Block-change announcements are gated by `CruiseVoicePolicy.shouldAnnounce(context:)`.
    ///   - Utterance text is generated by `CruiseVoicePolicy.utteranceText(for:)`.
    ///
    /// When `isCruise == false` (destination mode):
    ///   - Every block change triggers a voice cue (pre-CM-2 behavior — no regression).
    ///   - Utterance text is generated by `buildUtteranceText(_:)`.
    ///
    /// Thread safety: must be called from the main thread (same thread as
    /// `handleDriveModeChange` in ContentView — `@Observable` mutations are safe on main).
    func setCruiseMode(_ isCruise: Bool) {
        isCruiseMode = isCruise
    }

    // MARK: - Main update method

    /// Update the driving context for the given GPS position and heading.
    ///
    /// Call this on every `locationUpdateCount` change while Drive Mode is active.
    /// Performs closest-segment lookup, side classification, and block-change detection.
    ///
    /// - Parameters:
    ///   - coordinate: Driver's current GPS coordinate.
    ///   - heading: Stabilized heading in degrees (nil = use fallback convention).
    ///   - segments: Currently-loaded tile segments.
    ///   - engine: ParkingRulesEngine instance for safety label evaluation.
    ///   - date: Current date for rule evaluation. Defaults to `.nowET`.
    func update(
        coordinate: CLLocationCoordinate2D,
        heading: CLLocationDirection?,
        segments: [Segment],
        engine: ParkingRulesEngine,
        date: Date = .nowET
    ) {
        guard !segments.isEmpty else {
            currentContext = nil
            matchedSegment = nil
            return
        }

        // Step 1: Find closest segment overall (port of findClosestSegment, index.html:5560).
        guard let closest = findClosestSegment(to: coordinate, in: segments) else {
            currentContext = nil
            matchedSegment = nil
            return
        }

        // TF2-16: publish the same closest-segment result as a side-channel property —
        // no second matcher/distance-search, purely additive to the existing control flow.
        matchedSegment = closest

        // Step 2: Block identity — street + from + to of the closest segment.
        let block = (street: closest.street, from: closest.fromStreet, to: closest.to)

        // Step 3: Find all sides (N/S/E/W) for this block.
        // TF2-7: We now resolve cardinal side strings, not individual segments.
        let allSides = ["N", "S", "E", "W"]
        let sidesPresent: [(side: String, segment: Segment)] = allSides.compactMap { s in
            guard let seg = findSegment(
                street: block.street, from: block.from, to: block.to, side: s, in: segments
            ) else { return nil }
            return (s, seg)
        }

        // Step 4: Classify left/right cardinal sides (port of sideRelativeToHeading loop, index.html:5568–5571).
        // TF2-7: Resolve cardinal side strings ("N"/"S"/"E"/"W"), not segment references.
        var leftCardinalSide: String? = nil
        var rightCardinalSide: String? = nil

        if let h = heading {
            for (s, _) in sidesPresent {
                let which = sideRelativeToHeading(heading: h, side: s)
                if which == "left" && leftCardinalSide == nil { leftCardinalSide = s }
                else if which == "right" && rightCardinalSide == nil { rightCardinalSide = s }
            }
        }

        // Step 5: Fallback when heading unavailable (index.html:5575–5579).
        // North/West → Left, South/East → Right.
        if leftCardinalSide == nil && rightCardinalSide == nil && !sidesPresent.isEmpty {
            leftCardinalSide = sidesPresent.first(where: { $0.side == "N" || $0.side == "W" })?.side
                ?? sidesPresent.first?.side
            rightCardinalSide = sidesPresent.first(where: { $0.side == "S" || $0.side == "E" })?.side
                ?? (sidesPresent.count > 1 ? sidesPresent[1].side : nil)
        }

        // Step 6: TF2-7 — side-level aggregation replaces single-segment safetyLabel calls.
        // aggregateSide reduces ALL segments on the cardinal side to one SideOpportunity.
        // Pre-filter to the current block (street + from + to) so aggregateSide only sees
        // segments for this block, not other blocks on the same cardinal side.
        // (spec §3.5: "segments: [Segment] — all segments for the current street/from/to combination")
        let blockSegments = segments.filter {
            $0.street == block.street && $0.fromStreet == block.from && $0.to == block.to
        }
        let leftOpp  = leftCardinalSide.map  { DrivingContextService.aggregateSide(segments: blockSegments, side: $0, engine: engine, date: date) } ?? .unknown
        let rightOpp = rightCardinalSide.map { DrivingContextService.aggregateSide(segments: blockSegments, side: $0, engine: engine, date: date) } ?? .unknown
        let leftLabel  = SafetyLabel(for: leftOpp)
        let rightLabel = SafetyLabel(for: rightOpp)

        let context = DrivingContext(
            street: block.street,
            from: block.from,
            to: block.to,
            leftLabel: leftLabel,
            rightLabel: rightLabel
        )
        currentContext = context

        // Step 7: Block-change detection + voice trigger (index.html:5905–5908).
        //
        // CM-2: In Cruise Mode, gate through CruiseVoicePolicy.shouldAnnounce before speaking.
        // In Destination Mode, preserve the pre-CM-2 unconditional behavior (no regression).
        let blockKey = context.blockKey
        if blockKey != lastBlockKey {
            lastBlockKey = blockKey
            if !isCruiseMode {
                // Destination Mode: announce every block change (pre-CM-2 behavior preserved).
                // TF2-7: buildUtteranceText returns "" for the one-restricted+one-unknown case;
                // skip speakContext for empty text to avoid burning the 12s min-gap timer.
                let text = buildUtteranceText(context)
                if !text.isEmpty {
                    speakContext(context, text: text)
                }
            } else if CruiseVoicePolicy.shouldAnnounce(context: context) {
                // Cruise Mode: only announce when at least one side is free or metered.
                speakContext(context, text: CruiseVoicePolicy.utteranceText(for: context))
            }
            // Cruise Mode + all-restricted/unknown: silent (CruiseVoicePolicy.shouldAnnounce returned false).
        }
    }

    // MARK: - Voice cue builder

    /// Speaks the given utterance text via DrivingVoice, subject to the minimum-gap guard.
    ///
    /// CM-2: Takes an explicit `text` parameter rather than computing text internally,
    /// so the caller can inject either destination-mode phrasing (`buildUtteranceText`)
    /// or Cruise Mode phrasing (`CruiseVoicePolicy.utteranceText`).
    ///
    /// The `voiceMinGapSeconds` guard still applies regardless of mode. Mute gating is
    /// handled inside `DrivingVoice.speak` — this method does not need to check it.
    ///
    /// Port of speakDrivingContext (index.html:5957–5979):
    ///   "[StreetName]. Left side, [label]. Right side, [label]."
    ///   Abbreviations expanded: St → Street, Ave → Avenue, Blvd → Boulevard.
    ///   Sides with "No data" are omitted.
    private func speakContext(_ context: DrivingContext, text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds else { return }
        lastSpokenAt = now
        voice.speak(text)
    }

    /// Builds the destination-mode voice utterance text for a driving context.
    ///
    /// TF2-7: Replaced the zone-by-zone format ("Left side, free until Thu 9:30am.
    /// Right side, no parking.") with the same catch-all templates used by
    /// `CruiseVoicePolicy.utteranceText(for:)` — spec §4.3.
    ///
    /// Destination mode retains one meaningful difference from Cruise Mode:
    /// all-restricted blocks are NOT silenced. If both sides are `.restricted`,
    /// destination mode announces: "[Street]. No parking on either side."
    /// This keeps the driver informed in navigation mode (spec §4.3).
    ///
    /// Copy strings (exact — QA verifies against these, spec §4.1):
    ///   - Both free      → "[Street]. Free parking sections on both sides — check signs."
    ///   - Left free only → "[Street]. Free parking sections on the left — check signs."
    ///   - Right free only→ "[Street]. Free parking sections on the right — check signs."
    ///   - No free, left metered only  → "[Street]. Metered on the left."
    ///   - No free, right metered only → "[Street]. Metered on the right."
    ///   - No free, both metered       → "[Street]. Metered on both sides."
    ///   - Both restricted → "[Street]. No parking on either side."
    ///   - One restricted + one unknown → (no announcement — consistent with Cruise Mode)
    func buildUtteranceText(_ context: DrivingContext) -> String {
        let street = expandAbbreviations(titleCase(context.street))
        let leftFree     = context.leftLabel.severity == .free
        let rightFree    = context.rightLabel.severity == .free
        let leftMetered  = context.leftLabel.severity == .metered
        let rightMetered = context.rightLabel.severity == .metered
        let leftRestricted  = context.leftLabel.severity == .restricted
        let rightRestricted = context.rightLabel.severity == .restricted

        let clause: String
        if leftFree && rightFree {
            clause = "Free parking sections on both sides — check signs."
        } else if leftFree {
            clause = "Free parking sections on the left — check signs."
        } else if rightFree {
            clause = "Free parking sections on the right — check signs."
        } else if leftMetered && rightMetered {
            clause = "Metered on both sides."
        } else if leftMetered {
            clause = "Metered on the left."
        } else if rightMetered {
            clause = "Metered on the right."
        } else if leftRestricted && rightRestricted {
            // Destination mode: announce all-restricted blocks (spec §4.3 meaningful difference).
            clause = "No parking on either side."
        } else {
            // One restricted + one unknown, or both unknown — no announcement value.
            // Return empty string; speakContext's min-gap guard still fires but the
            // empty string is harmless when spoken by AVSpeechSynthesizer.
            return ""
        }
        return "\(street). \(clause)"
    }

    // MARK: - TF2-7: Side-level aggregation

    /// Reduces all segments on one cardinal side of the current block to a single
    /// `SideOpportunity` — answers "is there any free stretch, metered zone, or nothing
    /// usable on this side?" rather than exposing zone-by-zone granularity.
    ///
    /// Pure static function contract: no side effects, no stored state, no framework imports.
    /// Testable at zero cost. Mirrors the `CruiseVoicePolicy` / `FinalApproachService` pattern.
    ///
    /// Algorithm (spec §3.5):
    ///   1. Filter `segments` to those matching the given cardinal `side`.
    ///   2. For each matching segment, call `engine.safetyLabel(for: segment, at: date)`.
    ///   3. If any segment has severity `.free` AND its haversine length ≥ `minimumFreeLength`
    ///      → return `.free` immediately (short-circuit — "any free stretch ≥ one car length").
    ///   4. If no `.free` found but any segment has severity `.metered` → return `.metered`.
    ///   5. If segments were found but none were free or metered → return `.restricted`.
    ///   6. If no segments matched the side → return `.unknown`.
    ///
    /// - Parameters:
    ///   - segments: All segments for the current tile region (not pre-filtered to block).
    ///   - side: Cardinal side string — "N", "S", "E", or "W".
    ///   - engine: ParkingRulesEngine for safetyLabel evaluation.
    ///   - date: Evaluation date. Pass `.nowET` in production; inject a fixed date in tests.
    ///   - minimumFreeLength: Minimum free-stretch length in meters to count as qualifying.
    ///     Defaults to 6.0m (one car length — same as the tile-geometry intersection-clip
    ///     setback constant from PR #21, spec §3.3). Injectable for unit tests.
    ///
    /// - Returns: `SideOpportunity` classification for the given side.
    static func aggregateSide(
        segments: [Segment],
        side: String,
        engine: ParkingRulesEngine,
        date: Date,
        minimumFreeLength: Double = 6.0
    ) -> SideOpportunity {
        // Step 1: Filter to segments matching the given cardinal side.
        let sideSegments = segments.filter { $0.side == side }

        // Step 6 (early): no segments found for this side → unknown (data gap).
        guard !sideSegments.isEmpty else { return .unknown }

        var hasMetered = false

        // Steps 2–4: classify each segment.
        for seg in sideSegments {
            let label = engine.safetyLabel(for: seg, at: date)
            switch label.severity {
            case .free:
                // Step 3: check minimum free-stretch length via haversine.
                let length = segmentLengthMeters(seg)
                if length >= minimumFreeLength {
                    return .free  // Short-circuit: qualifying free stretch found.
                }
                // Free segment too short — fall through. Does not count as qualifying.
                // A sub-6m free sliver beside a restricted zone is not actionable.
            case .metered:
                hasMetered = true
            case .restricted, .unknown:
                break
            }
        }

        // Step 4: no qualifying free, but at least one metered.
        if hasMetered { return .metered }

        // Step 5: segments found but none free or metered.
        return .restricted
    }

    /// Computes the haversine length of a segment's polyline in meters.
    ///
    /// Sums the haversine distance between consecutive coordinate pairs in `segment.line`.
    /// Used by `aggregateSide` to check the 6m minimum-free-stretch threshold (spec §3.3).
    ///
    /// Internal (not private) so `TF27Tests` can verify the threshold behaviour directly
    /// without needing to construct a full `ParkingRulesEngine` context.
    /// Accessibility note: `@testable import WePark` exposes `internal` to tests.
    static func segmentLengthMeters(_ segment: Segment) -> Double {
        let coords = segment.line
        guard coords.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            guard coords[i].count >= 2, coords[i+1].count >= 2 else { continue }
            let a = CLLocationCoordinate2D(latitude: coords[i][0], longitude: coords[i][1])
            let b = CLLocationCoordinate2D(latitude: coords[i+1][0], longitude: coords[i+1][1])
            total += staticHaversineMeters(from: a, to: b)
        }
        return total
    }

    /// Static haversine helper for use by `aggregateSide` and `segmentLengthMeters`.
    /// Mirrors the instance `haversineMeters(from:to:)` method; kept static so `aggregateSide`
    /// (which is static) can call it without a service instance.
    private static func staticHaversineMeters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Geometry: closest segment

    /// Finds the segment with the minimum haversine distance from `coordinate`.
    /// Port of findClosestSegment (index.html:5560, which delegates to the tile-level function).
    private func findClosestSegment(to coordinate: CLLocationCoordinate2D, in segments: [Segment]) -> Segment? {
        var closest: Segment? = nil
        var closestDist = Double.infinity

        for seg in segments {
            guard seg.line.count >= 2 else { continue }
            let dist = pointToPolylineDistanceMeters(from: coordinate, line: seg.line)
            if dist < closestDist {
                closestDist = dist
                closest = seg
            }
        }
        return closest
    }

    /// Finds the segment matching a specific block (street + from + to + side).
    private func findSegment(street: String, from: String, to: String, side: String, in segments: [Segment]) -> Segment? {
        segments.first {
            $0.street == street &&
            $0.fromStreet == from &&
            $0.to == to &&
            $0.side == side
        }
    }

    // MARK: - Side classification

    /// Returns "left" or "right" for a cardinal side relative to the driver's heading.
    /// Port of `sideRelativeToHeading` (index.html:5542–5551).
    /// Returns nil if side is unknown.
    private func sideRelativeToHeading(heading: Double, side: String) -> String? {
        guard let sb = sideBearing[side] else { return nil }
        let leftBearing  = (heading - 90 + 360).truncatingRemainder(dividingBy: 360)
        let rightBearing = (heading + 90).truncatingRemainder(dividingBy: 360)
        let dLeft  = bearingDelta(sb, leftBearing)
        let dRight = bearingDelta(sb, rightBearing)
        // TF2-7 QA Finding #1: on an exact tie (heading aligned with the side bearing or its
        // reciprocal — e.g. due-north travel with N/S-labeled sides), the old `dLeft <= dRight`
        // sent BOTH opposite sides to "left", leaving the right chip unassigned ("—"). Break the
        // tie with the SIGNED angle from heading to the side bearing: clockwise (0..<180) → right,
        // counterclockwise → left. Opposite sides then land on opposite relative sides.
        if dLeft == dRight {
            let signed = (sb - heading + 360).truncatingRemainder(dividingBy: 360)
            return signed < 180 ? "right" : "left"
        }
        return dLeft < dRight ? "left" : "right"
    }

    /// Smallest angular distance between two compass bearings (0–180).
    /// Port of `bearingDelta` (index.html:5535–5537).
    private func bearingDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    // MARK: - Geometry helpers

    /// Minimum distance from a point to a polyline defined by [lat, lng] pairs.
    private func pointToPolylineDistanceMeters(
        from coordinate: CLLocationCoordinate2D,
        line: [[Double]]
    ) -> Double {
        var minDist = Double.infinity
        for i in 0..<(line.count - 1) {
            guard line[i].count >= 2, line[i+1].count >= 2 else { continue }
            let a = CLLocationCoordinate2D(latitude: line[i][0], longitude: line[i][1])
            let b = CLLocationCoordinate2D(latitude: line[i+1][0], longitude: line[i+1][1])
            let d = pointToSegmentDistanceMeters(point: coordinate, a: a, b: b)
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private func pointToSegmentDistanceMeters(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            return haversineMeters(from: point, to: a)
        }

        let t = max(0, min(1, (px * bx + py * by) / abLenSq))
        let closestLat = a.latitude  + (t * by) / metersPerDegLat
        let closestLng = a.longitude + (t * bx) / metersPerDegLng
        return haversineMeters(from: point, to: CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng))
    }

    private func haversineMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Text helpers

    /// Converts a string to Title Case.
    private func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Expands common street abbreviations for voice clarity.
    /// Port of speakDrivingContext's replace calls (index.html:5964).
    func expandAbbreviations(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\bSt\\b", with: "Street", options: .regularExpression)
            .replacingOccurrences(of: "\\bAve\\b", with: "Avenue", options: .regularExpression)
            .replacingOccurrences(of: "\\bBlvd\\b", with: "Boulevard", options: .regularExpression)
            .replacingOccurrences(of: "\\bDr\\b", with: "Drive", options: .regularExpression)
            .replacingOccurrences(of: "\\bPl\\b", with: "Place", options: .regularExpression)
            .replacingOccurrences(of: "\\bRd\\b", with: "Road", options: .regularExpression)
    }
}

//
//  DrivingContextService.swift
//  WePark
//
//  W8.5c: Swift port of `getCurrentDrivingContext` (index.html:5557–5587) +
//         `speakDrivingContext` (index.html:5957–5979) merged into one service.
//
//  Responsibilities:
//    - Find the closest block to the driver's GPS position.
//    - Classify N/S/E/W sides as "left" or "right" relative to the driver's heading.
//    - Compute safety label for each side via ParkingRulesEngine.
//    - Detect block changes and trigger voice cues via DrivingVoice.
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

    // MARK: - Block change detection (index.html:5905–5908)

    /// Block key from the most recent call. Nil on first call.
    private var lastBlockKey: String?

    /// Timestamp of the last voice cue. Used for minimum-gap enforcement.
    private var lastSpokenAt: Date = .distantPast

    // MARK: - Constants

    /// Minimum gap between voice cues (seconds). Calibration deferred to W8.5c-follow.
    /// Port of DRIVING_VOICE_MIN_GAP_MS = 12000 (index.html constant).
    private let voiceMinGapSeconds: TimeInterval = 12

    // MARK: - Dependencies

    private let voice: DrivingVoice

    // MARK: - Init

    init(voice: DrivingVoice) {
        self.voice = voice
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
            return
        }

        // Step 1: Find closest segment overall (port of findClosestSegment, index.html:5560).
        guard let closest = findClosestSegment(to: coordinate, in: segments) else {
            currentContext = nil
            return
        }

        // Step 2: Block identity — street + from + to of the closest segment.
        let block = (street: closest.street, from: closest.fromStreet, to: closest.to)

        // Step 3: Find all sides (N/S/E/W) for this block.
        let allSides = ["N", "S", "E", "W"]
        let sidesPresent: [(side: String, segment: Segment)] = allSides.compactMap { s in
            guard let seg = findSegment(
                street: block.street, from: block.from, to: block.to, side: s, in: segments
            ) else { return nil }
            return (s, seg)
        }

        // Step 4: Classify left/right (port of sideRelativeToHeading loop, index.html:5568–5571).
        var leftSeg: Segment? = nil
        var rightSeg: Segment? = nil

        if let h = heading {
            for (s, seg) in sidesPresent {
                let which = sideRelativeToHeading(heading: h, side: s)
                if which == "left" && leftSeg == nil { leftSeg = seg }
                else if which == "right" && rightSeg == nil { rightSeg = seg }
            }
        }

        // Step 5: Fallback when heading unavailable (index.html:5575–5579).
        // North/West → Left, South/East → Right.
        if leftSeg == nil && rightSeg == nil && !sidesPresent.isEmpty {
            leftSeg = sidesPresent.first(where: { $0.side == "N" || $0.side == "W" })?.segment
                ?? sidesPresent.first?.segment
            rightSeg = sidesPresent.first(where: { $0.side == "S" || $0.side == "E" })?.segment
                ?? (sidesPresent.count > 1 ? sidesPresent[1].segment : nil)
        }

        // Step 6: Compute safety labels (index.html:5584–5585).
        let noData = SafetyLabel(text: "No data", severity: .unknown)
        let leftLabel  = leftSeg.map  { engine.safetyLabel(for: $0, at: date) } ?? noData
        let rightLabel = rightSeg.map { engine.safetyLabel(for: $0, at: date) } ?? noData

        let context = DrivingContext(
            street: block.street,
            from: block.from,
            to: block.to,
            leftLabel: leftLabel,
            rightLabel: rightLabel
        )
        currentContext = context

        // Step 7: Block-change detection + voice trigger (index.html:5905–5908).
        let blockKey = context.blockKey
        if blockKey != lastBlockKey {
            lastBlockKey = blockKey
            speakContext(context)
        }
    }

    // MARK: - Voice cue builder

    /// Builds the utterance text for a context and speaks it via DrivingVoice.
    ///
    /// Port of speakDrivingContext (index.html:5957–5979):
    ///   "[StreetName]. Left side, [label]. Right side, [label]."
    ///   Abbreviations expanded: St → Street, Ave → Avenue, Blvd → Boulevard.
    ///   Sides with "No data" are omitted.
    private func speakContext(_ context: DrivingContext) {
        let now = Date()
        guard now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds else { return }
        lastSpokenAt = now

        let text = buildUtteranceText(context)
        voice.speak(text)
    }

    /// Port of speakDrivingContext's text construction (index.html:5964–5970).
    func buildUtteranceText(_ context: DrivingContext) -> String {
        let street = expandAbbreviations(titleCase(context.street))
        var parts = [street + "."]
        let lText = context.leftLabel.text
        let rText = context.rightLabel.text
        if !lText.isEmpty && lText != "No data" {
            parts.append("Left side, \(lText).")
        }
        if !rText.isEmpty && rText != "No data" {
            parts.append("Right side, \(rText).")
        }
        return parts.joined(separator: " ")
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
        return dLeft <= dRight ? "left" : "right"
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

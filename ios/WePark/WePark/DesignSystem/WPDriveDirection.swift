//
//  WPDriveDirection.swift
//  WePark
//
//  DT35-5: direction of travel ("Stanton St · Eastbound") for the Stoop drive street pill.
//  Pure, unit-testable logic; the view only renders the string. Stoop only: the legacy drive card
//  never reads this.
//

import Foundation
import CoreLocation

/// "Eastbound" / "Northbound" for the Stoop drive street pill.
///
/// The axis comes from the tile's own side convention (curb letters N/S mean the street runs
/// crosstown, so the label axis is E/W; E/W curbs mean N/S), not from true north, so
/// Manhattan's 29 degree grid cannot flip a label. Which way along that axis comes from the
/// street's local bearing, picked to agree with the car's raw GPS course.
enum WPDriveDirection {

    /// Beyond this many degrees between the course and the street, the car is mid-turn.
    nonisolated static let alongStreetToleranceDeg: Double = DriveSideConstants.alongStreetToleranceDeg
    /// A street whose line sits within this many degrees of 45 off the axes is a diagonal.
    nonisolated static let diagonalHalfWidthDeg: Double = 10
    /// Largest angle between the street's line and its side-letter axis before we distrust it.
    nonisolated static let axisDisagreementDeg: Double = 60
    /// Worst course accuracy (degrees) we are willing to name a direction from.
    nonisolated static let maxCourseAccuracyDeg: Double = 30

    /// - `heading`: the RAW GPS course (`LocationService.driveHeading`), never the street-snapped
    ///   heading (that would be circular).
    /// - `moving`: the `WPDriveDirectionGate` verdict; speed is gated there, with hysteresis.
    nonisolated static func label(
        segment: Segment?,
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        moving: Bool,
        headingHeld: Bool,
        courseAccuracy: Double?
    ) -> String? {
        guard moving, !headingHeld, let heading, let segment else { return nil }
        if let courseAccuracy, courseAccuracy > maxCourseAccuracyDeg { return nil }
        guard let local = DriveSideAssignment.localBearings(of: segment, near: coordinate) else { return nil }

        let eastWestAxis: Bool
        switch segment.side {
        case "N", "S": eastWestAxis = true
        case "E", "W": eastWestAxis = false
        default: return nil
        }

        // Street line bearing folded to 0..<180, then measured against the side-letter axis.
        let line = local.forward.truncatingRemainder(dividingBy: 180)
        let fromNorthAxis = min(line, 180 - line)          // 0 = due N/S line, 90 = due E/W line
        let offAxis = eastWestAxis ? 90 - fromNorthAxis : fromNorthAxis
        if offAxis > axisDisagreementDeg { return nil }
        if abs(fromNorthAxis - 45) <= diagonalHalfWidthDeg { return nil }

        // Travel bearing: whichever way of the street the course agrees with.
        let dF = DriveSideAssignment.circularDelta(local.forward, heading)
        let dR = DriveSideAssignment.circularDelta(local.reverse, heading)
        guard min(dF, dR) <= alongStreetToleranceDeg else { return nil }
        let t = (dF <= dR ? local.forward : local.reverse) * .pi / 180

        if eastWestAxis { return sin(t) > 0 ? "Eastbound" : "Westbound" }
        return cos(t) > 0 ? "Northbound" : "Southbound"
    }

    /// "Stanton St \u{00B7} Eastbound", or just the street when no direction is known.
    nonisolated static func pillText(street: String, direction: String?) -> String {
        guard let direction else { return street }
        return "\(street) \u{00B7} \(direction)"
    }

    /// VoiceOver: "Street: Stanton St, eastbound".
    nonisolated static func accessibilityText(street: String, direction: String?) -> String {
        guard let direction else { return "Street: \(street)" }
        return "Street: \(street), \(direction.lowercased())"
    }
}

/// Speed hysteresis for the direction label. Opens at 2.0 m/s; closes only after 3 s continuously
/// below 1.0 m/s; between the two the previous state holds, so a slow-down at a light does not
/// flicker. Pure value type: the caller passes the clock.
struct WPDriveDirectionGate: Equatable {
    nonisolated static let openSpeed: Double = 2.0
    nonisolated static let closeSpeed: Double = 1.0
    nonisolated static let closeAfterSeconds: Double = 3.0

    private(set) var isOpen = false
    /// When speed first dropped below `closeSpeed`; nil while at or above it.
    private(set) var slowSince: TimeInterval?

    nonisolated init() {}

    /// A nil speed counts as stopped.
    @discardableResult
    nonisolated mutating func update(speed: Double?, now: TimeInterval) -> Bool {
        let s = speed ?? 0
        if s >= Self.openSpeed {
            isOpen = true
            slowSince = nil
        } else if s >= Self.closeSpeed {
            slowSince = nil
        } else {
            let since = slowSince ?? now
            slowSince = since
            if now - since >= Self.closeAfterSeconds { isOpen = false }
        }
        return isOpen
    }

    nonisolated mutating func reset() {
        isOpen = false
        slowSince = nil
    }
}

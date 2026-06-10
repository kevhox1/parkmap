//
//  SegmentBearing.swift
//  WePark
//
//  FT-11 — Travel Direction Indicator.
//  Pure bearing-computation utility for tile segments.
//
//  `bearing(segment:toward:)` returns the compass bearing (0–360°) in the direction
//  of travel toward the specified segment endpoint. This is used:
//    1. At report time (ReportSheet): orient the two-arrow picker buttons.
//    2. At display time (PinMarkerAnnotation): rotate the directional chevron overlay.
//
//  The atan2 formula is the same as `bearingFromTo` in `LocationService.swift` (lines 303–310)
//  and the `bearingFromTo` function in `index.html:6572–6578`. It is reproduced here
//  because `LocationService.bearingFromTo` is `private` and conceptually tied to live GPS.
//  This utility is a pure, standalone function with no service dependencies.
//
//  Invariants:
//    - No Calendar.current.
//    - No force-unwraps.
//    - No SwiftUI or UIKit imports — pure math on Doubles.
//    - Unit-testable without any iOS framework dependencies (just Foundation).
//

import Foundation

// MARK: - SegmentBearing

/// FT-11: Bearing utility for tile segments.
///
/// All methods are `static` free functions so they are directly testable without
/// constructing any object, and carry no state.
enum SegmentBearing {

    // MARK: - Public API

    /// Returns the compass bearing (0–360°) from the segment's `line` toward the
    /// specified endpoint.
    ///
    /// - `toward: .toward_to` → bearing from `line[0]` toward `line.last`
    ///   (i.e., the direction of travel toward the `to` cross-street).
    /// - `toward: .from` → bearing from `line.last` toward `line[0]`
    ///   (i.e., the direction of travel toward the `fromStreet` cross-street).
    ///
    /// Returns `0.0` (north) without crashing when the segment has fewer than 2
    /// coordinate pairs — this is the defined fallback for degenerate segments
    /// (spec AC-11).
    ///
    /// - Parameters:
    ///   - segment: The tile segment whose `line` provides the polyline geometry.
    ///   - toward: Which endpoint to aim toward.
    /// - Returns: Compass bearing in degrees [0, 360).
    static func bearing(segment: Segment, toward: HeadingToward) -> Double {
        let line = segment.line
        // Degenerate guard: need at least a start and an end coordinate pair.
        guard line.count >= 2,
              let first = line.first,
              let last = line.last,
              first.count >= 2,
              last.count >= 2
        else {
            return 0.0
        }

        switch toward {
        case .toward_to:
            // Travel toward the `to` end: from line[0] → line.last.
            return bearingFromTo(
                lat1: first[0], lng1: first[1],
                lat2: last[0],  lng2: last[1]
            )
        case .from:
            // Travel toward the `fromStreet` end: from line.last → line[0].
            return bearingFromTo(
                lat1: last[0],  lng1: last[1],
                lat2: first[0], lng2: first[1]
            )
        }
    }

    // MARK: - Private math

    /// Compass bearing from (lat1, lng1) to (lat2, lng2), in [0, 360).
    ///
    /// Port of `bearingFromTo` from `LocationService.swift:303–310` and
    /// `index.html:6572–6578`. The formula is the standard spherical-trigonometry
    /// forward bearing using atan2 of sin/cos components.
    ///
    /// Internal (not private) so `FT11DirectionTests` can access it directly
    /// for the isolated math tests (AC-9, AC-10) without needing a full Segment.
    internal static func bearingFromTo(lat1: Double, lng1: Double,
                                       lat2: Double, lng2: Double) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaLambda = (lng2 - lng1) * .pi / 180
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

//
//  ParkTrackBuffer.swift
//  WePark
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 section 1A): a short in-memory
//  trail of recent location fixes, so "Park here" can reason about how the car approached the
//  curb (approach course, stopped-position averaging) instead of trusting one raw GPS point.
//
//  PRIVACY: in memory only. Never persisted, never logged, cleared when Drive Mode ends.
//
//  Pure value types, all `nonisolated` (the module defaults to MainActor isolation, so the
//  resolver and unit tests need the explicit annotation).
//

import Foundation
import CoreLocation

/// One recorded location fix. Field order is the memberwise-init order the spec lists.
nonisolated struct ParkTrackFix: Equatable {
    let coordinate: CLLocationCoordinate2D
    /// GPS course in degrees from true north, nil when CoreLocation reports it invalid.
    let course: Double?
    /// `CLLocation.courseAccuracy` in degrees, nil when invalid.
    let courseAccuracy: Double?
    /// m/s. Negative means "unavailable" (CoreLocation's convention); the resolver never treats
    /// a negative speed as stopped or as moving.
    let speed: Double
    /// `CLLocation.horizontalAccuracy` in metres, nil when invalid (negative).
    let horizontalAccuracy: Double?
    let timestamp: Date

    init(
        coordinate: CLLocationCoordinate2D,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        speed: Double,
        horizontalAccuracy: Double? = nil,
        timestamp: Date
    ) {
        self.coordinate = coordinate
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    /// Builds a fix from a CoreLocation fix, mapping CoreLocation's negative "invalid" sentinels
    /// to nil.
    init(location: CLLocation) {
        self.init(
            coordinate: location.coordinate,
            course: location.course >= 0 ? location.course : nil,
            courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
            speed: location.speed,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            timestamp: location.timestamp
        )
    }

    static func == (lhs: ParkTrackFix, rhs: ParkTrackFix) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.course == rhs.course
            && lhs.courseAccuracy == rhs.courseAccuracy
            && lhs.speed == rhs.speed
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy
            && lhs.timestamp == rhs.timestamp
    }
}

nonisolated enum ParkTrackConstants {
    /// Most fixes kept.
    static let maxFixes = 40
    /// Minimum gap between two kept fixes.
    static let minSpacingSeconds: TimeInterval = 1
    /// Fixes older than this (relative to the newest) are dropped.
    static let maxAgeSeconds: TimeInterval = 120
}

/// Ring buffer of recent fixes: at most 40, at least 1 s apart, nothing older than 120 s.
nonisolated struct ParkTrackBuffer: Equatable {

    private(set) var fixes: [ParkTrackFix] = []

    init() {}

    /// Appends `fix` unless it is less than 1 s after the last kept fix (the buffer keeps the
    /// earlier one), then drops anything older than 120 s and enforces the 40-fix cap.
    /// Returns true when the fix was kept.
    @discardableResult
    mutating func append(_ fix: ParkTrackFix) -> Bool {
        if let last = fixes.last,
           fix.timestamp.timeIntervalSince(last.timestamp) < ParkTrackConstants.minSpacingSeconds {
            return false
        }
        fixes.append(fix)
        let cutoff = fix.timestamp.addingTimeInterval(-ParkTrackConstants.maxAgeSeconds)
        fixes.removeAll { $0.timestamp < cutoff }
        if fixes.count > ParkTrackConstants.maxFixes {
            fixes.removeFirst(fixes.count - ParkTrackConstants.maxFixes)
        }
        return true
    }

    mutating func removeAll() {
        fixes.removeAll()
    }
}

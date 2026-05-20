//
//  DriveRoute.swift
//  WePark
//
//  W8.5a — Domain models for Mapbox Directions API responses.
//  Port of the PWA's Mapbox route shape (see fetchAndRenderRoute at index.html:6252).
//
//  These are the *public* shapes the rest of the app sees. The wire format
//  (Codable mirrors of the raw Mapbox JSON) lives in RouteService.swift
//  as internal types and is converted to these domain models on parse.
//
//  CLLocationCoordinate2D is NOT Equatable by default; conformance is
//  implemented manually so tests can assert on parsed routes without
//  wrapping coordinates.
//

import Foundation
import CoreLocation

/// A driving route returned by the Mapbox Directions API.
struct DriveRoute: Identifiable, Equatable {
    /// Stable per-fetch identifier (assigned client-side; not from Mapbox).
    let id: UUID

    /// Total route distance in meters.
    let distance: CLLocationDistance

    /// Total route duration in seconds.
    let duration: TimeInterval

    /// Full route polyline as ordered coordinates.
    /// Mapbox returns GeoJSON LineString `[lng, lat]` pairs; this array is
    /// already converted to `CLLocationCoordinate2D` (lat, lng).
    let geometry: [CLLocationCoordinate2D]

    /// Turn-by-turn steps, flattened across all legs (single-leg routes are
    /// the common case for a no-waypoint A→B request).
    let steps: [DriveRouteStep]

    init(
        id: UUID = UUID(),
        distance: CLLocationDistance,
        duration: TimeInterval,
        geometry: [CLLocationCoordinate2D],
        steps: [DriveRouteStep]
    ) {
        self.id = id
        self.distance = distance
        self.duration = duration
        self.geometry = geometry
        self.steps = steps
    }

    static func == (lhs: DriveRoute, rhs: DriveRoute) -> Bool {
        lhs.id == rhs.id
            && lhs.distance == rhs.distance
            && lhs.duration == rhs.duration
            && lhs.steps == rhs.steps
            && Self.coordinatesEqual(lhs.geometry, rhs.geometry)
    }

    static func coordinatesEqual(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if a[i].latitude != b[i].latitude || a[i].longitude != b[i].longitude { return false }
        }
        return true
    }
}

/// A single maneuver / step within a `DriveRoute`.
struct DriveRouteStep: Identifiable, Equatable {
    let id: UUID

    /// Step distance in meters.
    let distance: CLLocationDistance

    /// Step duration in seconds.
    let duration: TimeInterval

    /// Coordinate where the maneuver occurs.
    let maneuverLocation: CLLocationCoordinate2D

    /// Mapbox maneuver type, e.g. "turn", "depart", "arrive", "merge", "fork",
    /// "roundabout", "continue", "new name", "off ramp". Stored as a raw string
    /// to stay forward-compatible with new Mapbox values.
    let maneuverType: String

    /// Mapbox maneuver modifier, e.g. "left", "right", "slight right", "uturn".
    /// Nil for `depart` / `arrive`.
    let maneuverModifier: String?

    /// Human-readable instruction text from Mapbox (e.g. "Turn left onto Prince Street").
    let instruction: String

    /// Per-step polyline.
    let geometry: [CLLocationCoordinate2D]

    init(
        id: UUID = UUID(),
        distance: CLLocationDistance,
        duration: TimeInterval,
        maneuverLocation: CLLocationCoordinate2D,
        maneuverType: String,
        maneuverModifier: String?,
        instruction: String,
        geometry: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.distance = distance
        self.duration = duration
        self.maneuverLocation = maneuverLocation
        self.maneuverType = maneuverType
        self.maneuverModifier = maneuverModifier
        self.instruction = instruction
        self.geometry = geometry
    }

    static func == (lhs: DriveRouteStep, rhs: DriveRouteStep) -> Bool {
        lhs.id == rhs.id
            && lhs.distance == rhs.distance
            && lhs.duration == rhs.duration
            && lhs.maneuverLocation.latitude == rhs.maneuverLocation.latitude
            && lhs.maneuverLocation.longitude == rhs.maneuverLocation.longitude
            && lhs.maneuverType == rhs.maneuverType
            && lhs.maneuverModifier == rhs.maneuverModifier
            && lhs.instruction == rhs.instruction
            && DriveRoute.coordinatesEqual(lhs.geometry, rhs.geometry)
    }
}

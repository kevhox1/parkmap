//
//  WPTripDestinationSummary.swift
//  WePark
//
//  R35 F-1 (docs/specs/r35-map-polish-and-trip-destination.md): the one line on the trip map card
//  that says how many curbs near the destination are free for the WHOLE trip.
//
//  Honesty rules (Kevin: never show a fake spot):
//    - A curb counts only when `TripPlanning.isFree` over [arrival, departure] says so (the same
//      gate that draws the green), with strict signs on in Stoop.
//    - If the tiles around the destination are not all loaded, there is no count (`nil`). The card
//      says it is checking, then that the count is not available. It never estimates.
//    - Outside Manhattan coverage nothing is counted and nothing is promised.
//
//  Pure and `nonisolated` (the project defaults to MainActor isolation; tests call it directly).
//  It reuses `WPFreeCurbCounter` for the 2 block radius, the distance and the "nearest" wording, but
//  not its `count`, which only knows a goal window and only returns "nearest" when the count is zero.
//

import CoreLocation
import Foundation

nonisolated enum WPTripDestinationSummary {

    /// What the tiles say about the destination.
    enum Outcome: Equatable {
        /// Outside the Manhattan coverage box: nothing is counted.
        case outsideCoverage
        /// `free` curbs within 2 blocks that are free for the whole trip. `nearestMeters` is the
        /// closest such curb within the 400 m look (nil when none that close, or not fully loaded).
        case counted(free: Int, nearestMeters: Double?)
    }

    static let checkingPrefix = "Checking curbs near "
    static let unavailableLine = "Curb count isn't available right now."
    /// After this long without every tile loaded, the card stops saying "checking".
    static let giveUpSeconds: Double = 10

    // MARK: Counting

    /// The outcome for `destination`, or nil while the tiles for the 2 block radius are not all
    /// loaded (or there is no tile at all there).
    static func outcome(
        destination: TripDestination,
        plan: TripPlan,
        segments: [Segment],
        coverage: WPTileCoverage?,
        engine: ParkingRulesEngine,
        isInsideCoverage: (CLLocationCoordinate2D) -> Bool,
        strictSigns: Bool
    ) -> Outcome? {
        let point = destination.coordinate
        guard isInsideCoverage(point) else { return .outsideCoverage }
        guard let coverage, coverage.covers(point, radiusMeters: WPFreeCurbCounter.radiusMeters) else { return nil }
        let nearestCovered = coverage.covers(point, radiusMeters: WPFreeCurbCounter.coverageProbeMeters)
        var free = 0
        var nearest: Double?
        for segment in segments {
            // Cheap bounding-box reject (about 1.3 km) before the precise distance.
            if let first = segment.line.first, first.count >= 2,
               abs(first[0] - point.latitude) > 0.012 || abs(first[1] - point.longitude) > 0.016 {
                continue
            }
            let distance = WPFreeCurbCounter.distance(from: point, to: segment)
            guard distance <= WPFreeCurbCounter.coverageProbeMeters else { continue }
            guard TripPlanning.isFree(segment: segment, plan: plan, engine: engine, strictSigns: strictSigns) else { continue }
            if distance <= WPFreeCurbCounter.radiusMeters { free += 1 }
            if nearest == nil || distance < nearest! { nearest = distance }
        }
        // A nearest distance is only trusted when every tile out to the 400 m look is loaded.
        return .counted(free: free, nearestMeters: nearestCovered ? nearest : nil)
    }

    // MARK: Wording

    /// The sentence for a known outcome.
    static func line(for outcome: Outcome, destination: TripDestination) -> String {
        switch outcome {
        case .outsideCoverage:
            return "\(subject(destination)) is outside Manhattan. WePark can't show free curbs there yet."
        case .counted(let free, let nearest):
            let prefix = nearPrefix(destination)
            if free == 0 {
                var text = "\(prefix): no free curbs within 2 blocks for your whole trip."
                if let nearest { text += " " + WPFreeCurbCounter.nearestLine(nearest) }
                return text
            }
            let noun = free == 1 ? "1 curb is free" : "\(free) curbs free"
            var text = "\(prefix): \(noun) for your whole trip."
            if let nearest { text += " " + WPFreeCurbCounter.nearestLine(nearest) }
            return text
        }
    }

    /// While the tiles load: "Checking curbs near 350 5th Ave." Never a number.
    static func checkingLine(destination: TripDestination) -> String {
        checkingPrefix + subject(destination) + "."
    }

    /// "Near 350 5th Ave", "Near Penn Station", "Around here" (a point that has no name).
    static func nearPrefix(_ destination: TripDestination) -> String {
        if destination.name == WPPlaceResolver.unnamedMapPoint { return "Around here" }
        if destination.name.hasPrefix("Near ") { return destination.name }
        return "Near \(destination.name)"
    }

    /// The place on its own: "350 5th Ave", "Penn Station", "This part of the map".
    static func subject(_ destination: TripDestination) -> String {
        if destination.name.hasPrefix("Near ") { return String(destination.name.dropFirst("Near ".count)) }
        return destination.name
    }
}

/// What the free-curb summary depends on. Includes the loaded tile SET (an equal-sized swap of
/// tiles must recompute), the plan and the segment count.
struct WPTripSummaryKey: Hashable {
    let lat: Double, lng: Double
    let arrival: Date, departure: Date
    let segments: Int
    let loadedTiles: Set<String>

    init(destination: TripDestination, plan: TripPlan, segments: Int, loadedTiles: Set<String>) {
        lat = destination.latitude; lng = destination.longitude
        arrival = plan.arrival; departure = plan.departure
        self.segments = segments; self.loadedTiles = loadedTiles
    }
}

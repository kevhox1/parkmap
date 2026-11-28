//
//  WPPlaceResolver.swift
//  WePark
//
//  R35 F-1 (docs/specs/r35-map-polish-and-trip-destination.md): turns a search suggestion into a
//  place with the SAME 10 second timeout and the SAME two error strings as the Stoop search sheet
//  (`WPSearchSheetV2.select`), without editing that file. Only the Plan a Trip destination picker
//  uses it for now; pointing the search sheet at it is a listed follow-up.
//
//  Also names a map point ("Near 350 5th Ave") for the planner's default destination.
//
//  `nonisolated`: the project defaults to MainActor isolation and the pure parts are called from
//  synchronous tests.
//

import CoreLocation
import Foundation
import MapKit

/// Thrown when a lookup does not answer in time. Its own type (and `nonisolated`) so the timer
/// child task can create it off the main actor.
nonisolated struct WPPlaceTimeoutError: Error {}

nonisolated enum WPPlaceResolver {

    /// Same as `WPSearchSheetV2.select`.
    static let timeoutSeconds: Double = 10
    /// Same copy as `WPSearchSheetV2.select` (a timeout).
    static let timeoutMessage = "Search timed out. Try again."
    /// Same copy as `WPSearchSheetV2.select` (nothing found, or no connection).
    static let notFoundMessage = "Couldn't find that place. Check your connection and try again."
    /// What the planner calls a map point it could not name (offline, or no address there).
    static let unnamedMapPoint = "This part of the map"

    // MARK: Errors

    /// The plain sentence for a failed lookup.
    static func message(for error: Error) -> String {
        (error is WPPlaceTimeoutError || error is SearchTimeoutError) ? timeoutMessage : notFoundMessage
    }

    // MARK: Resolving

    /// Resolves a suggestion to its first map item, racing a timeout. Throws `WPPlaceTimeoutError`
    /// on timeout, `MKError(.placemarkNotFound)` when there is no result, or the search's own error.
    @MainActor
    static func resolveItem(
        _ completion: MKLocalSearchCompletion, timeout: Double = timeoutSeconds
    ) async throws -> MKMapItem {
        try await withTimeout(seconds: timeout) {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let first = response.mapItems.first else { throw MKError(.placemarkNotFound) }
            return first
        }
    }

    /// Resolves a suggestion to a `TripDestination` (name, address, coordinate).
    @MainActor
    static func resolveDestination(
        _ completion: MKLocalSearchCompletion, timeout: Double = timeoutSeconds
    ) async throws -> TripDestination {
        let item = try await resolveItem(completion, timeout: timeout)
        let coordinate = item.placemark.coordinate
        return TripDestination(
            name: item.name ?? completion.title,
            address: completion.subtitle.isEmpty ? nil : completion.subtitle,
            latitude: coordinate.latitude, longitude: coordinate.longitude
        )
    }

    /// Runs `operation` against a timer: the first to finish wins, the other is cancelled.
    static func withTimeout<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw WPPlaceTimeoutError()
            }
            guard let result = try await group.next() else { throw WPPlaceTimeoutError() }
            group.cancelAll()
            return result
        }
    }

    // MARK: Naming a map point

    /// "Near 350 5th Ave" from a placemark's number and street; "Near 5th Ave" with only a street;
    /// nil when there is nothing street-like to say (the caller falls back to `unnamedMapPoint`).
    static func nearLabel(houseNumber: String?, street: String?) -> String? {
        let street = street?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !street.isEmpty else { return nil }
        let number = houseNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return number.isEmpty ? "Near \(street)" : "Near \(number) \(street)"
    }

    /// Best-effort reverse lookup with a short timeout. Never throws: offline or empty gives nil.
    @MainActor
    static func nearLabel(for coordinate: CLLocationCoordinate2D, timeout: Double = 4) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let geocoder = CLGeocoder()
        let marks: [CLPlacemark]? = try? await withTimeout(seconds: timeout) {
            try await geocoder.reverseGeocodeLocation(location)
        }
        guard let mark = marks?.first else { return nil }
        return nearLabel(houseNumber: mark.subThoroughfare, street: mark.thoroughfare)
    }
}

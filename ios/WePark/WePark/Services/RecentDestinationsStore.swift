//
//  RecentDestinationsStore.swift
//  WePark
//
//  N-1 lift (W8.5c): Moved from inline-in-DriveModeDestinationView.swift to its own file.
//  No behavior change — pure refactor per QA advisory in docs/qa/w8.5b-pass-1-2026-05-20.md.
//
//  UserDefaults-backed list of recent destinations (max 5, MRU ordering).
//  Supports add, delete, and swipe-to-delete.
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import CoreLocation
import Observation

// MARK: - RecentDestination

/// A recently driven-to destination, persisted in UserDefaults.
/// `CLLocationCoordinate2D` is not Codable — latitude/longitude are stored separately.
struct RecentDestination: Codable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - RecentDestinationsStore

/// `UserDefaults`-backed list of recent destinations (max 5, MRU ordering).
/// Supports add, delete, and swipe-to-delete.
@Observable
final class RecentDestinationsStore {

    private(set) var destinations: [RecentDestination] = []
    private let key = AppConstants.recentDestinationsKey
    private static let maxCount = 5

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentDestination].self, from: data) else {
            destinations = []
            return
        }
        destinations = decoded
    }

    /// Inserts a new destination at index 0, truncates to max 5, and persists.
    func add(_ destination: RecentDestination) {
        // Remove existing entry with same name to deduplicate.
        var updated = destinations.filter { $0.name != destination.name }
        updated.insert(destination, at: 0)
        if updated.count > Self.maxCount {
            updated = Array(updated.prefix(Self.maxCount))
        }
        destinations = updated
        persist()
    }

    /// Removes destinations at the given index set and persists.
    /// Note: `Array.remove(atOffsets:)` is defined in SwiftUI's extension, which cannot
    /// be imported in a pure service file. We manually filter by index instead.
    func delete(at offsets: IndexSet) {
        destinations = destinations.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map { $0.element }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

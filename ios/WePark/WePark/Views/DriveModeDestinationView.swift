//
//  DriveModeDestinationView.swift
//  WePark
//
//  W8.5b — Full-screen destination search for Drive Mode.
//
//  Architecture:
//    - Full-screen cover (OQ-2: Option C). Presented over ContentView via .fullScreenCover.
//    - MKLocalSearchCompleter for address suggestions (no third-party search API per spec §2.2).
//    - SearchCompleterDelegate: NSObject, MKLocalSearchCompleterDelegate bridge into @Observable.
//    - RecentDestination: Codable struct stored in UserDefaults (max 5, MRU ordering).
//    - "Start Drive" button (OQ-3: Option B — explicit activation seam for W8.5c).
//
//  Flow:
//    1. User types → completer fires → suggestions shown.
//    2. User taps suggestion → MKLocalSearch resolves to coordinate → "Start Drive" shown.
//    3. User taps "Start Drive" → fetchRoute(alternatives:true) → pickBestParkingAwareRoute →
//       onRouteReady closure fires → dismiss.
//    4. Recent destinations shown when search field is empty.
//
//  Out-of-coverage destinations (OQ-7): allowed with toast warning via ToastService.
//  Recent destinations (OQ-5): 5 entries, swipe-to-delete, swipe-to-delete persists.
//

import SwiftUI
import MapKit
import CoreLocation

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
    func delete(at offsets: IndexSet) {
        destinations.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(destinations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - SearchCompleterDelegate

/// `@Observable` bridge between `MKLocalSearchCompleter` (UIKit NSObject delegate)
/// and SwiftUI. Owned by `DriveModeDestinationView` as a `@State` object.
///
/// Pattern from spec §7 Risk 1: the completer must live in a reference type, not
/// directly in a SwiftUI View struct, or it will be re-created on every render.
@Observable
final class SearchCompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - DriveModeDestinationView

struct DriveModeDestinationView: View {

    // MARK: - Inputs from ContentView

    /// Current visible map region — used to bias completer results toward NYC.
    let currentRegion: MKCoordinateRegion

    /// Currently-loaded tile segments — passed to the scoring engine.
    let segments: [Segment]

    /// User's current GPS location — used as the route origin.
    let userLocation: CLLocationCoordinate2D?

    /// Called when a route is ready (destination + best route resolved).
    /// ContentView uses this to set `activeRoute` and `driveDestinationCoordinate`.
    let onRouteReady: (DriveRoute, CLLocationCoordinate2D) -> Void

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Internal state

    @State private var query: String = ""
    @State private var completerDelegate = SearchCompleterDelegate()
    @State private var recentStore = RecentDestinationsStore()

    /// The selected suggestion (from completer), nil until user taps one.
    @State private var selectedCompletion: MKLocalSearchCompletion? = nil

    /// Resolved coordinate after MKLocalSearch resolves a completion.
    @State private var resolvedCoordinate: CLLocationCoordinate2D? = nil

    /// Display name for the resolved destination.
    @State private var resolvedName: String? = nil

    /// True while route fetch is in progress.
    @State private var isLoadingRoute: Bool = false

    /// Inline error message (network, no routes, location unavailable, etc.).
    @State private var errorMessage: String? = nil

    /// True while MKLocalSearch is resolving a tapped completion.
    @State private var isResolvingAddress: Bool = false

    /// Whether to show a "focus" state in the search field.
    @FocusState private var searchFieldFocused: Bool

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search field
                searchField

                // Error banner (inline, not modal)
                if let error = errorMessage {
                    errorBanner(error)
                }

                // Results or recent list
                if query.isEmpty {
                    recentDestinationsList
                } else {
                    suggestionsList
                }

                Spacer()

                // "Start Drive" button — shown after destination is resolved
                if resolvedCoordinate != nil {
                    startDriveSection
                }
            }
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Bias completer to current map region.
            completerDelegate.completer.region = currentRegion
            // Auto-focus search field so keyboard appears immediately (AC-W85b.2).
            searchFieldFocused = true
        }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                // Cleared — reset resolved state.
                clearResolved()
            }
            completerDelegate.completer.queryFragment = newValue
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search for a destination", text: $query)
                .focused($searchFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
            if !query.isEmpty {
                Button {
                    query = ""
                    clearResolved()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Inline error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Recent destinations list

    private var recentDestinationsList: some View {
        List {
            if recentStore.destinations.isEmpty {
                Section {
                    Text("No recent destinations")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Section("Recent") {
                    ForEach(recentStore.destinations) { recent in
                        Button {
                            selectRecent(recent)
                        } label: {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recent.name)
                                        .foregroundStyle(.primary)
                                        .font(.body)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        recentStore.delete(at: offsets)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Completer suggestions list

    private var suggestionsList: some View {
        List {
            if isResolvingAddress {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Resolving address...")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            } else if let resolvedName {
                // Destination resolved — show confirmation row
                Section("Destination") {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text(resolvedName)
                            .font(.body)
                    }
                }
            } else if completerDelegate.results.isEmpty && !query.isEmpty {
                Section {
                    Text("No results found")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Section("Suggestions") {
                    ForEach(completerDelegate.results, id: \.self) { completion in
                        Button {
                            selectCompletion(completion)
                        } label: {
                            HStack {
                                Image(systemName: "mappin")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(completion.title)
                                        .foregroundStyle(.primary)
                                        .font(.body)
                                    if !completion.subtitle.isEmpty {
                                        Text(completion.subtitle)
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - "Start Drive" section

    private var startDriveSection: some View {
        VStack(spacing: 12) {
            Divider()
            if isLoadingRoute {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding best route...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.vertical, 8)
            } else {
                Button {
                    Task { await fetchRouteAndReturn() }
                } label: {
                    Label("Start Drive", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    /// Selects a completer suggestion and resolves it to a coordinate via MKLocalSearch.
    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        // Dismiss keyboard when a suggestion is selected (AC-W85b.6).
        searchFieldFocused = false
        query = completion.title + (completion.subtitle.isEmpty ? "" : ", \(completion.subtitle)")
        errorMessage = nil
        isResolvingAddress = true
        selectedCompletion = completion

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                self.isResolvingAddress = false
                if let error {
                    self.errorMessage = "Couldn't resolve address — check connection. (\(error.localizedDescription))"
                    self.resolvedCoordinate = nil
                    self.resolvedName = nil
                    return
                }
                guard let item = response?.mapItems.first else {
                    self.errorMessage = "Couldn't resolve address — check connection."
                    self.resolvedCoordinate = nil
                    self.resolvedName = nil
                    return
                }
                self.resolvedCoordinate = item.placemark.coordinate
                self.resolvedName = item.name ?? completion.title
            }
        }
    }

    /// Selects a recent destination (coordinate already stored — no network call).
    /// Per AC-W85b.21: tapping a recent destination uses the stored coordinate directly.
    private func selectRecent(_ recent: RecentDestination) {
        // Dismiss keyboard (AC-W85b.6 equivalent for recents).
        searchFieldFocused = false
        query = recent.name
        errorMessage = nil
        resolvedCoordinate = recent.coordinate
        resolvedName = recent.name
    }

    /// Fetches the best parking-aware route and calls `onRouteReady`.
    private func fetchRouteAndReturn() async {
        guard let destination = resolvedCoordinate else { return }

        // AC-W85b.13: Guard on user location availability.
        guard let origin = userLocation else {
            errorMessage = "Location unavailable. Enable location access in Settings."
            return
        }

        errorMessage = nil
        isLoadingRoute = true

        do {
            let routes = try await RouteService.shared.fetchRoute(
                from: origin,
                to: destination,
                alternatives: true
            )

            // Pick the best parking-aware route (scoring port from spec §4, Step C).
            let engine = ParkingRulesEngine()
            let best = RouteService.pickBestParkingAwareRoute(routes, segments: segments, engine: engine)
                ?? routes[0]

            // Save to recent destinations before dismissing.
            let destinationName = resolvedName ?? "Unknown Destination"
            let recent = RecentDestination(
                id: UUID(),
                name: destinationName,
                latitude: destination.latitude,
                longitude: destination.longitude
            )
            recentStore.add(recent)

            // Out-of-coverage warning toast (OQ-7): allow routing with a toast warning.
            // Delay by 0.3s so the toast appears after the cover dismissal animation.
            if !AppConstants.isInManhattanCoverage(destination) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    ToastService.shared.show(message: "Limited parking data outside Manhattan")
                }
            }

            isLoadingRoute = false
            onRouteReady(best, destination)
            dismiss()

        } catch let routeError as MapboxRouteError {
            isLoadingRoute = false
            errorMessage = friendlyErrorMessage(for: routeError)
        } catch {
            isLoadingRoute = false
            errorMessage = "Route unavailable. Please try again."
        }
    }

    /// Resets the resolved destination state (used when query is cleared).
    private func clearResolved() {
        resolvedCoordinate = nil
        resolvedName = nil
        selectedCompletion = nil
        errorMessage = nil
        isResolvingAddress = false
    }

    /// User-friendly error messages for each `MapboxRouteError` case.
    private func friendlyErrorMessage(for error: MapboxRouteError) -> String {
        switch error {
        case .missingToken:
            return "App configuration error. Please update the app."
        case .network(let message):
            return "Network error. Check your connection. (\(message))"
        case .http(let status):
            return "Route service error (HTTP \(status)). Please try again."
        case .decoding(let message):
            return "Route data error. Please try again. (\(message))"
        case .noRoutes:
            return "No route found to that destination."
        }
    }
}

#Preview {
    DriveModeDestinationView(
        currentRegion: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7831, longitude: -73.9712),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        ),
        segments: [],
        userLocation: CLLocationCoordinate2D(latitude: 40.7831, longitude: -73.9712),
        onRouteReady: { _, _ in }
    )
}

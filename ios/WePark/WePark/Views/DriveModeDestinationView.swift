//
//  DriveModeDestinationView.swift
//  WePark
//
//  W8.5b — Full-screen destination search for Drive Mode.
//  W8.5c — N-1: RecentDestinationsStore moved to Services/RecentDestinationsStore.swift.
//           M-2: routeService is now typed against RouteServicing protocol.
//           Auth gate: "Start Drive" requests location permission when notDetermined.
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
//    3. User taps "Start Drive" → auth gate → fetchRoute(alternatives:true) → pickBestParkingAwareRoute →
//       onRouteReady closure fires → dismiss.
//    4. Recent destinations shown when search field is empty.
//
//  Out-of-coverage destinations (OQ-7): allowed with toast warning via ToastService.
//  Recent destinations (OQ-5): 5 entries, swipe-to-delete, swipe-to-delete persists.
//

import SwiftUI
import MapKit
import CoreLocation

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

    // MARK: - Dependencies (injectable for M-2 protocol seam)

    /// Route service, typed against `RouteServicing` for dependency injection.
    /// Default: `RouteService.shared` (the production singleton).
    let routeService: any RouteServicing

    /// Location service, for auth gate check (AC-W85c.4).
    let locationService: LocationService

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

    /// True while waiting for location authorization (auth gate spinner).
    @State private var isRequestingAuth: Bool = false

    /// Whether to show an alert for denied/restricted location permission.
    @State private var showLocationDeniedAlert: Bool = false

    /// Whether to focus on the search field.
    @FocusState private var searchFieldFocused: Bool

    // MARK: - Init

    /// Primary initializer — uses production `RouteService.shared` and a provided `LocationService`.
    init(
        currentRegion: MKCoordinateRegion,
        segments: [Segment],
        userLocation: CLLocationCoordinate2D?,
        locationService: LocationService,
        onRouteReady: @escaping (DriveRoute, CLLocationCoordinate2D) -> Void,
        routeService: (any RouteServicing)? = nil
    ) {
        self.currentRegion = currentRegion
        self.segments = segments
        self.userLocation = userLocation
        self.locationService = locationService
        self.onRouteReady = onRouteReady
        self.routeService = routeService ?? RouteService.shared
    }

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
        // W8.5c auth gate: when authorization resolves while spinner is shown,
        // clear the spinner and attempt route fetch if now authorized.
        .onChange(of: locationService.isAuthorized) { _, isAuthorized in
            if isRequestingAuth {
                isRequestingAuth = false
                if isAuthorized {
                    Task { await fetchRouteAndReturn() }
                } else {
                    // Became denied/restricted during the wait.
                    let status = CLLocationManager().authorizationStatus
                    if status == .denied || status == .restricted {
                        showLocationDeniedAlert = true
                    }
                }
            }
        }
        .alert("Location Required", isPresented: $showLocationDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Location required for Drive Mode — enable it in Settings.")
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
            } else if isRequestingAuth {
                // Auth gate spinner (AC-W85c.4)
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Requesting location...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.vertical, 8)
            } else {
                Button {
                    handleStartDriveTap()
                } label: {
                    Label("Start Drive", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                // Disable while resolving address (belt-and-suspenders — button is hidden then anyway).
                .disabled(isResolvingAddress)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    /// Handles the "Start Drive" button tap with auth gate (AC-W85c.4).
    private func handleStartDriveTap() {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .notDetermined:
            // Gate: request permission first, then route fetch fires from .onChange.
            isRequestingAuth = true
            locationService.requestAndFetchLocation()
        case .authorizedWhenInUse, .authorizedAlways:
            // Already authorized — proceed directly.
            Task { await fetchRouteAndReturn() }
        case .denied, .restricted:
            // Permission denied — show informational alert (AC-W85c.5).
            showLocationDeniedAlert = true
        @unknown default:
            Task { await fetchRouteAndReturn() }
        }
    }

    /// Selects a completer suggestion and resolves it to a coordinate via MKLocalSearch.
    ///
    /// M-1 fix (PR #29 QA pass-1 M-1): uses the async overload of MKLocalSearch.start()
    /// and races it against a configurable timeout (default 10s, overridable for tests).
    /// If the search does not respond within the timeout the spinner is cleared and an
    /// error message is shown — no indefinite "Resolving address..." hang.
    private func selectCompletion(
        _ completion: MKLocalSearchCompletion,
        timeoutSeconds: Double = 10
    ) {
        // Dismiss keyboard when a suggestion is selected (AC-W85b.6).
        searchFieldFocused = false
        query = completion.title + (completion.subtitle.isEmpty ? "" : ", \(completion.subtitle)")
        errorMessage = nil
        isResolvingAddress = true
        selectedCompletion = completion

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)

        Task { @MainActor in
            do {
                // Race MKLocalSearch.start() against a timeout.
                // withThrowingTaskGroup cancels the losing child when the first child
                // finishes (either returns a value or throws).
                //
                // Both tasks throw on their failure paths so the group result type is
                // non-optional `MKMapItem` — no nil-ambiguity between "search returned
                // no items" and "timeout fired".
                let item: MKMapItem = try await withThrowingTaskGroup(
                    of: MKMapItem.self
                ) { group in
                    // Search task: throws on network/decode errors, or if no map item.
                    group.addTask {
                        let response = try await search.start()
                        guard let first = response.mapItems.first else {
                            throw MKError(.placemarkNotFound)
                        }
                        return first
                    }
                    // Timeout task: sleeps then throws SearchTimeoutError.
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        throw _SearchTimeoutError()
                    }
                    // Await the first child to finish (success or throw).
                    // group.next() is guaranteed non-nil here because we added 2 tasks
                    // and haven't consumed any yet, but we guard for safety.
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        throw _SearchTimeoutError()
                    }
                    group.cancelAll()
                    return result
                }

                self.isResolvingAddress = false
                self.resolvedCoordinate = item.placemark.coordinate
                self.resolvedName = item.name ?? completion.title

            } catch is _SearchTimeoutError {
                self.isResolvingAddress = false
                self.errorMessage = "Search timed out. Try again."
                self.resolvedCoordinate = nil
                self.resolvedName = nil

            } catch {
                self.isResolvingAddress = false
                self.errorMessage = "Couldn't resolve address — check connection. (\(error.localizedDescription))"
                self.resolvedCoordinate = nil
                self.resolvedName = nil
            }
        }
    }

    // _SearchTimeoutError is defined at file scope below so it is accessible from
    // @testable-imported test targets for the M-1 timeout test.

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
            let routes = try await routeService.fetchRoute(
                from: origin,
                to: destination,
                alternatives: true
            )

            // Pick the best parking-aware route (scoring port from spec §4, Step C).
            let engine = ParkingRulesEngine()
            let best = routeService.pickBestParkingAwareRoute(routes, segments: segments, engine: engine, now: .nowET)
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

// MARK: - Sentinel error type for MKLocalSearch timeout (M-1)

/// Sentinel error thrown by the timeout branch inside `selectCompletion`.
/// Internal visibility (not private) so the M-1 unit test can reference it via
/// `@testable import WePark`.  Prefixed with underscore to signal it is an
/// implementation detail, not part of the public API surface.
struct SearchTimeoutError: Error {}

// Internal alias used inside DriveModeDestinationView — exposed for tests as SearchTimeoutError.
// (The view uses `_SearchTimeoutError` in its `catch` clause — this is the same type.)
typealias _SearchTimeoutError = SearchTimeoutError

#Preview {
    DriveModeDestinationView(
        currentRegion: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7831, longitude: -73.9712),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        ),
        segments: [],
        userLocation: CLLocationCoordinate2D(latitude: 40.7831, longitude: -73.9712),
        locationService: LocationService(),
        onRouteReady: { _, _ in }
    )
}

//
//  WPSearchV2.swift
//  WePark
//
//  Phase 2b, B3: the flag-on search sheet (docs/design/wepark-round2, "2 Search Curb Parking").
//  Presented in place of the browse sheet's `BrowseSearchAreaView` ONLY while
//  `AppConstants.designSystemV2Enabled` is true.
//
//    peek         field focused: "My car" (if parked) and recent destinations
//    typing       suggestions from the existing `SearchCompleterDelegate` (MKLocalSearchCompleter);
//                 a place outside coverage stays in the list, muted, "not covered yet"
//    destination  card: name, address, a REAL free-curb count for the selected window, the three
//                 goal chips, "Drive here" (the existing destination mode)
//
//  The free-curb count is computed on device from the loaded segments with the same
//  `WPCurbVerdict.isParkable` gate as the map's green (`WPFreeCurbCounter`). If the tiles for the
//  destination are not loaded the count is hidden. It is never estimated.
//

import MapKit
import SwiftUI

// MARK: - Resolved place

struct WPResolvedPlace: Equatable {
    let name: String
    let address: String?
    let coordinate: CLLocationCoordinate2D

    static func == (a: WPResolvedPlace, b: WPResolvedPlace) -> Bool {
        a.name == b.name && a.address == b.address
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

// MARK: - Sheet

struct WPSearchSheetV2: View {
    let goalInput: WPGoalSheetInput
    let currentRegion: MKCoordinateRegion
    let segments: [Segment]
    /// Which tiles are loaded: the free-curb count shows only when the whole counting radius is.
    let tileCoverage: WPTileCoverage?
    let engine: ParkingRulesEngine
    let userLocation: CLLocationCoordinate2D?
    let locationService: LocationService
    /// "In front of 50 E 1st St" (or the street) for the parked car, nil when none.
    let parkedCarLine: String?
    let onSelectGoal: (ParkingGoal) -> Void
    /// A destination was picked: the host recenters the map there so its tiles load.
    let onDestinationResolved: (CLLocationCoordinate2D) -> Void
    let onShowParkedCar: () -> Void
    /// Route ready: identical hand-off to `BrowseSearchAreaView.onRouteReady`.
    let onRouteReady: (DriveRoute, CLLocationCoordinate2D) -> Void
    let onClose: () -> Void
    var routeService: any RouteServicing = RouteService.shared
    /// Screenshot/test seam: start with a place already resolved.
    var initialPlace: WPResolvedPlace? = nil
    var initialQuery: String = ""

    @State private var query = ""
    @State private var completer = SearchCompleterDelegate()
    @State private var recents = RecentDestinationsStore()
    @State private var place: WPResolvedPlace?
    @State private var isResolving = false
    @State private var isRouting = false
    @State private var errorMessage: String?
    @State private var coverage: [String: Bool] = [:]
    @State private var distances: [String: Double] = [:]
    @State private var count: WPFreeCurbCount?
    @FocusState private var focused: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            if let place {
                destinationCard(place)
            } else {
                searchBody
            }
        }
        .background(WP.card.ignoresSafeArea())
        .onAppear {
            completer.completer.region = currentRegion
            if let initialPlace, place == nil { place = initialPlace }
            if !initialQuery.isEmpty, query.isEmpty { query = initialQuery }
            if place == nil { focused = true }
        }
    }

    // MARK: Search body (peek + typing)

    private var searchBody: some View {
        VStack(spacing: 0) {
            fieldRow
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s5)
                .padding(.bottom, WP.Space.s2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                            .foregroundStyle(WP.noParkText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, WP.Space.s2)
                    }
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        peekRows
                    } else {
                        suggestionRows
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var fieldRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s2))
        return layout {
            HStack(spacing: WP.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.muted)
                    .accessibilityHidden(true)
                TextField("Search an address or place", text: $query)
                    .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search an address or place")
                    .onChange(of: query) { _, newValue in
                        errorMessage = nil
                        completer.completer.queryFragment = newValue
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(WP.muted)
                            .frame(width: WP.Target.minimum, height: WP.Target.minimum)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, WP.Space.s4)
            .frame(maxWidth: .infinity, minHeight: WP.Target.minimum, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
                .strokeBorder(WP.line, lineWidth: WP.Border.fact))

            Button(action: onClose) {
                Text("Cancel")
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .padding(.horizontal, WP.Space.s2)
                    .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Peek rows

    @ViewBuilder
    private var peekRows: some View {
        if let parkedCarLine {
            resultRow(
                icon: "car.fill", iconFilled: true,
                title: "My car", subtitle: parkedCarLine, trailing: nil, muted: false,
                action: { onShowParkedCar() }
            )
        }
        ForEach(recents.destinations) { recent in
            resultRow(
                icon: "clock.fill", iconFilled: false,
                title: recent.name, subtitle: "Recent", trailing: nil, muted: false,
                action: {
                    resolveRecent(recent)
                }
            )
        }
    }

    // MARK: Suggestions

    private var suggestionRows: some View {
        let rows = Array(completer.results.prefix(8))
        return ForEach(rows, id: \.self) { completion in
            let key = Self.key(completion)
            let covered = coverage[key]
            let isOut = covered == false
            resultRow(
                icon: "mappin", iconFilled: false,
                title: completion.title,
                subtitle: isOut
                    ? (completion.subtitle.isEmpty ? "Not covered yet" : "\(completion.subtitle) \u{00B7} not covered yet")
                    : completion.subtitle,
                trailing: distances[key].map(Self.distanceLabel),
                muted: isOut,
                action: { select(completion) }
            )
        }
        .task(id: rows.map(Self.key).joined(separator: "|")) { await classify(rows) }
    }

    private func resultRow(
        icon: String, iconFilled: Bool, title: String, subtitle: String, trailing: String?,
        muted: Bool, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: WP.Space.s3) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(WP.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(iconFilled ? WP.taxi : WP.lifted))
                        .overlay(Circle().strokeBorder(WP.line, lineWidth: iconFilled ? WP.Border.control : WP.Border.fact))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                            .foregroundStyle(muted ? WP.muted : WP.text)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                                .foregroundStyle(WP.muted)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                            .foregroundStyle(WP.muted)
                    }
                }
                .padding(.vertical, WP.Space.s2)
                .frame(minHeight: WP.Control.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            Rectangle().fill(WP.divider).frame(height: 1)
        }
    }

    // MARK: Destination card (B3.3 / B3.4)

    private func destinationCard(_ place: WPResolvedPlace) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    destinationHeader(place)
                    countCard(place)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                            .foregroundStyle(WP.noParkText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    goalChips
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s5)
                .padding(.bottom, WP.Space.s3)
            }
            .scrollBounceBehavior(.basedOnSize)
            driveHere(place)
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s2)
                .padding(.bottom, WP.Space.s4)
        }
        .task(id: CountKey(place: place, goal: goalInput.selectedGoal, segments: segments.count, loadedTiles: tileCoverage?.loadedTiles.count ?? -1, end: goalInput.selectedEnd)) {
            recomputeCount(place)
        }
    }

    private func destinationHeader(_ place: WPResolvedPlace) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s3))
            : AnyLayout(HStackLayout(alignment: .top, spacing: WP.Space.s3))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(placeSubline(place))
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button {
                self.place = nil; count = nil; query = ""; focused = true
            } label: {
                Text("Close")
                    .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
                    .foregroundStyle(WP.text)
                    .padding(.horizontal, WP.Space.s2)
                    .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close destination")
        }
    }

    private func placeSubline(_ place: WPResolvedPlace) -> String {
        var parts: [String] = []
        if let address = place.address, !address.isEmpty { parts.append(address) }
        if let userLocation {
            let meters = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
                .distance(from: CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude))
            parts.append(Self.distanceLabel(meters) + " away")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // The count card. Hidden when the tiles are not loaded; "not covered yet" outside Manhattan.
    @ViewBuilder
    private func countCard(_ place: WPResolvedPlace) -> some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
        if !AppConstants.isInManhattanCoverage(place.coordinate) {
            factCard(shape: shape) {
                Text("Not covered yet")
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                    .foregroundStyle(WP.text)
                Text("WePark covers Manhattan today. Curbs here aren't mapped, so nothing is marked as free.")
                    .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
            }
        } else if let count {
            factCard(shape: shape) {
                if count.count == 0 {
                    Text(WPFreeCurbCounter.headline(count) + ".")
                        .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                        .foregroundStyle(WP.text)
                    if let nearest = count.nearestMeters {
                        Text(WPFreeCurbCounter.nearestLine(nearest))
                            .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                            .foregroundStyle(WP.muted)
                    }
                } else {
                    HStack(alignment: .center, spacing: WP.Space.s3) {
                        Text("\(count.count)")
                            .font(WP.Font.fredoka(40, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(WP.ink)
                            .frame(minWidth: 64, minHeight: 64)
                            .background(RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous).fill(WP.park))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(WPFreeCurbCounter.headline(count))
                                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                                .foregroundStyle(WP.text)
                            Text(WPFreeCurbCounter.windowLine(goal: goalInput.selectedGoal, end: goalInput.selectedEnd, now: goalInput.now))
                                .font(WP.Font.fredoka(14, .medium, relativeTo: .callout))
                                .foregroundStyle(WP.muted)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(count.count) \(WPFreeCurbCounter.headline(count)), "
                        + WPFreeCurbCounter.windowLine(goal: goalInput.selectedGoal, end: goalInput.selectedEnd, now: goalInput.now)
                    )
                }
            }
        }
        // else: tiles not loaded for this place. No count, no estimate.
    }

    private func factCard<Content: View>(shape: RoundedRectangle, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WP.Space.s1) { content() }
            .fixedSize(horizontal: false, vertical: true)
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }

    private var goalChips: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s2))
        return layout {
            ForEach(WPGoalCopy.tileOrder, id: \.rawValue) { goal in
                WPChoiceChip(
                    title: WPGoalCopy.goalName(goal),
                    isSelected: goal == goalInput.selectedGoal,
                    height: 56
                ) { onSelectGoal(goal) }
                .accessibilityAddTraits(goal == goalInput.selectedGoal ? .isSelected : [])
            }
        }
    }

    private func driveHere(_ place: WPResolvedPlace) -> some View {
        Group {
            if isRouting {
                HStack(spacing: WP.Space.s2) {
                    ProgressView()
                    Text("Finding the best route")
                        .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                }
                .frame(maxWidth: .infinity, minHeight: WP.Control.inkPillHeight)
            } else {
                Button("Drive here") { Task { await driveHere(to: place) } }
                    .buttonStyle(.wpInkPill)
                    .accessibilityHint("Starts Drive Mode toward \(place.name)")
            }
        }
    }

    // MARK: Logic

    private struct CountKey: Hashable {
        let lat: Double, lng: Double, goal: String, segments: Int, loadedTiles: Int, end: Date
        init(place: WPResolvedPlace, goal: ParkingGoal, segments: Int, loadedTiles: Int, end: Date) {
            lat = place.coordinate.latitude; lng = place.coordinate.longitude
            self.goal = goal.rawValue; self.segments = segments; self.loadedTiles = loadedTiles; self.end = end
        }
    }

    private func recomputeCount(_ place: WPResolvedPlace) {
        guard AppConstants.isInManhattanCoverage(place.coordinate) else { count = nil; return }
        count = WPFreeCurbCounter.count(
            near: place.coordinate, segments: segments, coverage: tileCoverage, engine: engine,
            from: goalInput.now, until: goalInput.selectedEnd
        )
    }

    nonisolated static func key(_ completion: MKLocalSearchCompletion) -> String {
        "\(completion.title)|\(completion.subtitle)"
    }

    nonisolated static func distanceLabel(_ meters: Double) -> String {
        let miles = meters / 1609.344
        return miles < 0.1 ? "\(Int((meters * 3.28084 / 10).rounded()) * 10) ft" : String(format: "%.1f mi", miles)
    }

    /// Resolves the top suggestions (debounced, at most 4) so out-of-coverage places can be muted
    /// and distances shown. A failed or throttled lookup just leaves the row plain.
    private func classify(_ rows: [MKLocalSearchCompletion]) async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        for completion in rows.prefix(4) {
            let key = Self.key(completion)
            if coverage[key] != nil { continue }
            guard !Task.isCancelled else { return }
            let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
            guard let item = try? await search.start().mapItems.first else { continue }
            let c = item.placemark.coordinate
            coverage[key] = AppConstants.isInManhattanCoverage(c)
            if let userLocation {
                distances[key] = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        focused = false
        errorMessage = nil
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let item: MKMapItem = try await withThrowingTaskGroup(of: MKMapItem.self) { group in
                    group.addTask {
                        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
                        guard let first = response.mapItems.first else { throw MKError(.placemarkNotFound) }
                        return first
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw SearchTimeoutError()
                    }
                    guard let result = try await group.next() else { throw SearchTimeoutError() }
                    group.cancelAll()
                    return result
                }
                let resolved = WPResolvedPlace(
                    name: item.name ?? completion.title,
                    address: completion.subtitle.isEmpty ? nil : completion.subtitle,
                    coordinate: item.placemark.coordinate
                )
                place = resolved
                onDestinationResolved(resolved.coordinate)
            } catch is SearchTimeoutError {
                errorMessage = "Search timed out. Try again."
            } catch {
                errorMessage = "Couldn't find that place. Check your connection and try again."
            }
        }
    }

    private func resolveRecent(_ recent: RecentDestination) {
        focused = false
        let resolved = WPResolvedPlace(name: recent.name, address: nil, coordinate: recent.coordinate)
        place = resolved
        onDestinationResolved(resolved.coordinate)
    }

    private func driveHere(to place: WPResolvedPlace) async {
        let status = locationService.authorizationStatus
        if status == .denied || status == .restricted {
            errorMessage = "Location is off. Turn it on in Settings to get directions."
            return
        }
        guard let origin = userLocation else {
            errorMessage = "Location unavailable. Enable location access in Settings."
            return
        }
        errorMessage = nil
        isRouting = true
        defer { isRouting = false }
        do {
            let routes = try await routeService.fetchRoute(from: origin, to: place.coordinate, alternatives: true)
            guard let first = routes.first else { throw MapboxRouteError.noRoutes }
            let best = routeService.pickBestParkingAwareRoute(routes, segments: segments, engine: engine, now: .nowET) ?? first
            recents.add(RecentDestination(
                id: UUID(), name: place.name,
                latitude: place.coordinate.latitude, longitude: place.coordinate.longitude
            ))
            onRouteReady(best, place.coordinate)
        } catch let routeError as MapboxRouteError {
            switch routeError {
            case .noRoutes: errorMessage = "No route found to that destination."
            case .network: errorMessage = "Network error. Check your connection."
            default: errorMessage = "Route unavailable. Please try again."
            }
        } catch {
            errorMessage = "Route unavailable. Please try again."
        }
    }
}

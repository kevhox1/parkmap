//
//  WPTripDestinationPickerV2.swift
//  Views
//
//  R35 F-1 (docs/specs/r35-map-polish-and-trip-destination.md): the address picker for Plan a Trip.
//  It swaps in place of the planner content inside the same large sheet (no nested sheet).
//
//    empty field   recent destinations
//    typing        suggestions from the existing `SearchCompleterDelegate` (MKLocalSearchCompleter);
//                  a place outside Manhattan stays in the list, muted, "not covered yet"
//    no results    "No places found for 'xyz'. Try a street address."
//
//  Picking a row resolves it with `WPPlaceResolver` (10 second timeout, the same two error strings
//  as the search sheet) and hands a `TripDestination` back to the planner. Recents are saved by the
//  planner when the user taps "Show trip map", not on mere selection.
//
//  Stoop only (reached from `WPTripPlannerV2`, which is flag-on only).
//

import MapKit
import SwiftUI

// MARK: - Logic (pure)

/// What the picker shows, decided from plain values so it is testable without a view.
nonisolated enum WPTripDestinationPickerLogic {

    enum Content: Equatable {
        /// Field empty: recent destinations.
        case recents
        /// Suggestions are showing.
        case suggestions
        /// Typed something, nothing yet, still waiting for the completer.
        case searching
        /// Typed something and the completer answered with nothing.
        case empty(message: String)
    }

    static let notCoveredTitle = "Not covered yet"
    static let notCoveredDetail = "WePark covers Manhattan today. Curbs here aren't mapped, so nothing is marked as free."

    /// R35-13: two places are the same recent only when the name AND the spot match (within about
    /// 11 m). Two "Starbucks" on different blocks are two chips; a repeat of the same one is not.
    static func isSamePlace(_ a: RecentDestination, _ b: RecentDestination) -> Bool {
        a.name == b.name
            && abs(a.latitude - b.latitude) < 0.0001 && abs(a.longitude - b.longitude) < 0.0001
    }

    /// The recent chips on the planner: most recent first, no repeats, never the place already
    /// chosen (matched by name AND coordinate), at most `limit`.
    static func chipRecents(
        _ recents: [RecentDestination], excluding current: TripDestination?, limit: Int = 3
    ) -> [RecentDestination] {
        var shown: [RecentDestination] = []
        for recent in recents {
            if let current, recent.name == current.name,
               abs(recent.latitude - current.latitude) < 0.0001,
               abs(recent.longitude - current.longitude) < 0.0001 { continue }
            if shown.contains(where: { isSamePlace($0, recent) }) { continue }
            shown.append(recent)
            if shown.count == limit { break }
        }
        return shown
    }

    /// R35-12 follow-up: inside Manhattan, but the spot itself has no curbs (a park, plaza or pier).
    static let noCurbsTitle = "No street parking right here"
    static let noCurbsDetail = "This spot has no curbs of its own. The trip map shows the free curbs nearby."

    static func content(query: String, completionCount: Int, settled: Bool) -> Content {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .recents }
        if completionCount > 0 { return .suggestions }
        return settled ? .empty(message: emptyMessage(query: trimmed)) : .searching
    }

    static func emptyMessage(query: String) -> String {
        "No places found for '\(query)'. Try a street address."
    }

    /// The planner's starting destination: the map centre, named when the lookup found a street.
    static func defaultDestination(center: CLLocationCoordinate2D, label: String?) -> TripDestination {
        TripDestination(
            name: label ?? WPPlaceResolver.unnamedMapPoint, address: nil,
            latitude: center.latitude, longitude: center.longitude
        )
    }

    /// True while a destination is still the unedited map-centre default (so a late reverse lookup
    /// may rename it, but never replaces a place the user chose).
    static func isMapCentreDefault(_ destination: TripDestination?, center: CLLocationCoordinate2D?) -> Bool {
        guard let destination, let center else { return false }
        return destination.latitude == center.latitude && destination.longitude == center.longitude
            && destination.address == nil
    }
}

// MARK: - View

struct WPTripDestinationPickerV2: View {
    /// The planner's region centre: biases the suggestions toward where the user is looking.
    let region: MKCoordinateRegion?
    let userLocation: CLLocationCoordinate2D?
    let recents: [RecentDestination]
    let onPick: (TripDestination) -> Void
    let onBack: () -> Void

    @State private var query = ""
    @State private var completer = SearchCompleterDelegate()
    @State private var settled = false
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var coverage: [String: Bool] = [:]
    @State private var distances: [String: Double] = [:]
    @FocusState private var focused: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    private var content: WPTripDestinationPickerLogic.Content {
        WPTripDestinationPickerLogic.content(
            query: query, completionCount: completer.results.count, settled: settled
        )
    }

    var body: some View {
        WPScreenScaffold(
            closeLabel: "Back",
            onClose: onBack,
            title: "Where to?",
            sub: "Search an address or a place. We'll look for curbs that are free for your whole trip."
        ) {
            fieldRow
            if let errorMessage {
                Text(errorMessage)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .foregroundStyle(WP.noParkText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, WP.Space.s1)
            }
            if isResolving {
                HStack(spacing: WP.Space.s2) {
                    ProgressView()
                    Text("Finding that place")
                        .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                        .foregroundStyle(WP.muted)
                }
                .frame(maxWidth: .infinity, minHeight: WP.Control.rowMinHeight, alignment: .leading)
            }
            rows
        }
        .onAppear {
            if let region { completer.completer.region = region }
            focused = true
        }
        .task(id: query) {
            // The completer does not say "no results", it just stays empty. Give it a moment, then
            // call it settled so an empty list can say so.
            settled = false
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            settled = true
        }
        .onChange(of: completer.results.count) { _, count in
            if count > 0 { settled = true }
        }
    }

    // MARK: Field

    private var fieldRow: some View {
        HStack(spacing: WP.Space.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(WP.muted)
                .accessibilityHidden(true)
            TextField("Search an address or place", text: $query)
                .font(WP.Font.fredoka(17, .medium, relativeTo: .body))
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
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WP.muted)
                        .frame(width: WP.Target.minimum, height: WP.Target.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, WP.Space.s4)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
        .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
            .strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        switch content {
        case .recents:
            ForEach(recents) { recent in
                row(
                    icon: "clock.fill", title: recent.name, subtitle: "Recent", trailing: nil, muted: false
                ) {
                    onPick(TripDestination(
                        name: recent.name, address: nil, latitude: recent.latitude, longitude: recent.longitude
                    ))
                }
            }
        case .suggestions:
            let shown = Array(completer.results.prefix(8))
            ForEach(shown, id: \.self) { completion in
                let key = WPSearchSheetV2.key(completion)
                let isOut = coverage[key] == false
                row(
                    icon: "mappin", title: completion.title,
                    subtitle: isOut
                        ? (completion.subtitle.isEmpty
                            ? "Not covered yet" : "\(completion.subtitle) \u{00B7} not covered yet")
                        : completion.subtitle,
                    trailing: distances[key].map(WPSearchSheetV2.distanceLabel),
                    muted: isOut
                ) { select(completion) }
            }
            .task(id: shown.map(WPSearchSheetV2.key).joined(separator: "|")) { await classify(shown) }
        case .searching:
            HStack(spacing: WP.Space.s2) {
                ProgressView()
                Text("Searching")
                    .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                    .foregroundStyle(WP.muted)
            }
            .frame(maxWidth: .infinity, minHeight: WP.Control.rowMinHeight, alignment: .leading)
        case .empty(let message):
            emptyState(message)
        }
    }

    private func emptyState(_ message: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s3))
        return layout {
            Text(message)
                .font(WP.Font.fredoka(16, .medium, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button { query = "" } label: {
                Text("Clear")
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .padding(.horizontal, WP.Space.s3)
                    .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum)
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
        }
        .padding(.vertical, WP.Space.s2)
        .accessibilityElement(children: .contain)
    }

    private func row(
        icon: String, title: String, subtitle: String, trailing: String?, muted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: WP.Space.s3) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(WP.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(WP.lifted))
                        .overlay(Circle().strokeBorder(WP.line, lineWidth: WP.Border.fact))
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
                .frame(maxWidth: .infinity, minHeight: WP.Control.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
            .accessibilityElement(children: .combine)
            Rectangle().fill(WP.divider).frame(height: 1)
        }
    }

    // MARK: Logic

    private func select(_ completion: MKLocalSearchCompletion) {
        focused = false
        errorMessage = nil
        isResolving = true
        Task { @MainActor in
            defer { isResolving = false }
            do {
                let destination = try await WPPlaceResolver.resolveDestination(completion)
                onPick(destination)
            } catch {
                errorMessage = WPPlaceResolver.message(for: error)
            }
        }
    }

    /// Resolves the top suggestions (debounced, at most 4) so out-of-coverage places can be muted
    /// and distances shown. A failed or throttled lookup just leaves the row plain.
    private func classify(_ rows: [MKLocalSearchCompletion]) async {
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        for completion in rows.prefix(4) {
            let key = WPSearchSheetV2.key(completion)
            if coverage[key] != nil { continue }
            guard !Task.isCancelled else { return }
            guard let item = try? await WPPlaceResolver.resolveItem(completion) else { continue }
            let c = item.placemark.coordinate
            coverage[key] = AppConstants.isInManhattanCoverage(c)
            if let userLocation {
                distances[key] = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
                    .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            }
        }
    }
}

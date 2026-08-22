//
//  BrowseSearchAreaView.swift
//  WePark
//
//  FT-20 — search relocated into the browse-mode bottom sheet, per
//  docs/ft20-bottom-sheet-navigation-spec.md §3.2/§3.3/§4.3. Built additively in Stream B
//  alongside the still-live `DriveModeDestinationView.swift`/`.fullScreenCover` path (see
//  §0c); Stream C deleted that file and its call site once this became the ONLY search
//  entry point (`ft20BrowseSheetEnabled == true`), and relocated its shared,
//  non-SwiftUI-specific types (`SearchCompleterDelegate`, `SearchTimeoutError`) to
//  `Services/SearchCompleterDelegate.swift` — `RecentDestinationsStore` already lived in
//  its own `Services/` file since W8.5c's N-1 lift.
//
//  The logic below is a faithful, near-verbatim behavioral port of the deleted
//  `DriveModeDestinationView`'s sub-views (completer delegate reuse, recents list,
//  suggestions list, error banner, auth gate, out-of-coverage toast, timeout-guarded
//  MKLocalSearch resolution).
//
//  Deltas from the original `DriveModeDestinationView`, per spec §4.3 / §3.2 / §3.3:
//    - NavigationStack + "Where to?" title + toolbar Cancel button: REMOVED. This is sheet
//      content, not a modal — collapsing the sheet or clearing the query replaces Cancel
//      (§4.3's own reasoning; design-review finding S5 is the one deliberate addition in
//      its place, below).
//    - Auto-focus-on-appear: REPLACED by expand-on-tap (§3.3) — tapping the search field
//      drives `detentKind` to `.large` (peek/medium must not auto-expand just by existing).
//    - The old "Destination" confirmation row inside `suggestionsList` + the separate
//      `startDriveSection` button below it: REPLACED by one unified `placeState` card
//      (§3.2) — pin + name + subtitle + distance + the OQ-4 parking-near-here summary +
//      a single "Go" button (renamed from "Start Drive" — shorter, and unambiguous now
//      that there's no cruise option on this screen to distinguish it from).
//    - Design-review finding S5: `.scrollDismissesKeyboard(.interactively)` added to both
//      `recentDestinationsList` and `suggestionsList` — the one deliberate addition to
//      "kept verbatim" content, so a user who starts typing, changes their mind, and
//      scrolls the list away (the standard iOS gesture) doesn't get a stuck keyboard now
//      that there's no toolbar Cancel button to fall back on.
//    - No `dismiss()` call after a successful route fetch — this view is `.browseNav`'s
//      sheet CONTENT, not a `.fullScreenCover`. The sheet's disappearance on Go is driven
//      by `driveModeActive` flipping true (spec §6, AC-11/AC-28), wired at ContentView's
//      Drive-Mode boundary (Stream C), not by this view dismissing itself.
//    - QA §0d C2 fix (Stream C): auto-expands `detentKind` to `.large` the instant
//      `errorMessage` is set, so a search/route failure is never invisible behind a
//      collapsed sheet — see the `.onChange(of: errorMessage)` handler below.
//    - QA §0d C1 fix (Stream C): `searchField` reports its OWN intrinsic height rather than
//      the whole view being measured — see `searchField`'s own doc comment.
//    - PR #87 round 5 (2026-08-22, real on-device numbers): the C1 fix above originally used
//      `.background(GeometryReader { ... }.preference(...))` + a `PreferenceKey`. Kevin's
//      `#if DEBUG` readout proved that mechanism delivered `0` at every layout pass, on a
//      real device, with the search field fully rendered — see
//      `BrowseNavigationSheet.swift`'s removed-`PreferenceKey` doc comment for the full
//      root-cause writeup (a `PreferenceKey.reduce` ordering bug, not a height-arithmetic
//      bug). `searchField` now reports its height via `.onGeometryChange(for:of:action:)`
//      (iOS 17+) directly to a caller-supplied closure instead — no `PreferenceKey`
//      involved, so the whole bug class is structurally impossible here now.
//    - §0f Ruling 1 (2026-08-21, third live smoke): `searchField` now carries a small
//      `gearshape` Settings affordance in its TRAILING EDGE — the Apple Maps avatar
//      position. `BrowseNavigationSheet`'s medium-detent action content no longer includes
//      a Settings control at all (see that file's own doc comment) — this is Settings'
//      only remaining entry point in browse mode besides `SettingsView` itself.
//    - §0f "still open" finding: the search field's own fill color is bumped from
//      `.secondarySystemGroupedBackground` to `.systemGray4` + a hairline
//      `Color(.separator)` border, for contrast against the sheet's material — see
//      `searchField`'s own doc comment for the root-cause reasoning.
//

import SwiftUI
import MapKit
import CoreLocation

// MARK: - BrowseSearchAreaView

struct BrowseSearchAreaView: View {

    // MARK: - Inputs from ContentView

    /// Current visible map region — used to bias completer results toward NYC.
    let currentRegion: MKCoordinateRegion

    /// Currently-loaded tile segments — passed to the route scorer and OQ-4's proximity scorer.
    let segments: [Segment]

    /// User's current GPS location — used as the route origin and the place-state distance line.
    let userLocation: CLLocationCoordinate2D?

    /// Location service, for the auth gate (same gate `DriveModeDestinationView` uses).
    let locationService: LocationService

    /// Route service, typed against `RouteServicing` for dependency injection (mirrors
    /// `DriveModeDestinationView`'s M-2 seam).
    let routeService: any RouteServicing

    /// §3.3: the sheet's current detent, as a two-way binding into ContentView's
    /// `@State private var browseSheetDetentKind`. Tapping the search field (below) sets
    /// this to `.large`; ContentView's own drag-driven binding can set it back.
    @Binding var detentKind: BrowseSheetDetentKind

    /// Fires on a successful Go — identical payload to `driveModeDestinationCover`'s
    /// `onRouteReady` today (AC-11). ContentView wires this to the same
    /// `driveModeStyle = .destination; activeRoute = route; driveDestinationCoordinate =
    /// destination; driveModeActive = true` sequence.
    let onRouteReady: (DriveRoute, CLLocationCoordinate2D) -> Void

    /// §0f Ruling 1: fires when the trailing-edge gearshape is tapped. ContentView wires
    /// this to `activeSheet = .settings`, the same target the deleted `gearButtonOverlay`
    /// used. Defaulted to a no-op so the existing render-smoke tests (which don't exercise
    /// Settings) don't all need updating for an unrelated affordance.
    let onSettingsTapped: () -> Void

    /// PR #87 round 5: fires with `searchField`'s own live-measured height every time it
    /// changes (first layout, Dynamic Type change, rotation) via `.onGeometryChange` — see
    /// `searchField`'s own doc comment. `BrowseNavigationSheet` supplies this so the value
    /// lands directly in ITS `@State searchAreaHeight`, which is what actually drives
    /// `BrowseSheetDetentMath.peekHeight`/`.mediumHeight`.
    ///
    /// Deliberately NOT defaulted to a no-op the way `onSettingsTapped` is: unlike Settings,
    /// this callback is the ENTIRE height-measurement mechanism — a silently-ignored default
    /// here would reproduce the exact "nothing ever reports a real height" bug this round
    /// fixed, just moved one layer up. Existing render-smoke tests that don't care about the
    /// measured value pass `{ _ in }` explicitly instead, so the no-op is visible at each
    /// call site rather than implicit.
    let onSearchFieldHeightChange: (CGFloat) -> Void

    // MARK: - Init

    init(
        currentRegion: MKCoordinateRegion,
        segments: [Segment],
        userLocation: CLLocationCoordinate2D?,
        locationService: LocationService,
        detentKind: Binding<BrowseSheetDetentKind>,
        onRouteReady: @escaping (DriveRoute, CLLocationCoordinate2D) -> Void,
        onSearchFieldHeightChange: @escaping (CGFloat) -> Void,
        onSettingsTapped: @escaping () -> Void = {},
        routeService: (any RouteServicing)? = nil
    ) {
        self.currentRegion = currentRegion
        self.segments = segments
        self.userLocation = userLocation
        self.locationService = locationService
        self._detentKind = detentKind
        self.onRouteReady = onRouteReady
        self.onSearchFieldHeightChange = onSearchFieldHeightChange
        self.onSettingsTapped = onSettingsTapped
        self.routeService = routeService ?? RouteService.shared
    }

    // MARK: - Internal state
    //
    // Mirrors `DriveModeDestinationView`'s state near-verbatim — see that file's own
    // doc comments for the original rationale behind each of these.

    @State private var query: String = ""
    @State private var completerDelegate = SearchCompleterDelegate()
    @State private var recentStore = RecentDestinationsStore()

    @State private var selectedCompletion: MKLocalSearchCompletion? = nil
    @State private var resolvedCoordinate: CLLocationCoordinate2D? = nil
    @State private var resolvedName: String? = nil

    /// New for the "place" state (spec §3.2): the suggestion's subtitle (e.g. street
    /// address), shown under the resolved name. Nil for recents — `RecentDestination`
    /// doesn't persist a subtitle, and the place state gracefully omits the line rather
    /// than showing a stale/misleading one.
    @State private var resolvedSubtitle: String? = nil

    /// New for OQ-4: the "parking near here" radius-scan result, computed once when a
    /// destination resolves (not recomputed on every render — `TileLoader.segments` is a
    /// few hundred to a couple thousand entries, cheap but not free).
    @State private var nearbyParkingScore: ParkingProximityScore? = nil

    @State private var isLoadingRoute: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isResolvingAddress: Bool = false
    @State private var isRequestingAuth: Bool = false
    @State private var showLocationDeniedAlert: Bool = false

    @FocusState private var searchFieldFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField

            // §4.2: recents/suggestions/place-state are LARGE-detent-only content — at
            // peek/medium only the search field itself is visible (AC-4). Per Stream A's
            // own doc comment on `BrowseNavigationSheet.searchArea`, gating this
            // internally (rather than needing a second slot on the container) is the
            // intended pattern: "the peek detent grows with it automatically... the point
            // of measuring rather than hardcoding."
            if detentKind == .large {
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                if resolvedCoordinate != nil {
                    placeState
                } else if query.isEmpty {
                    recentDestinationsList
                } else {
                    suggestionsList
                }
            }
        }
        .onAppear {
            completerDelegate.completer.region = currentRegion
        }
        .onChange(of: query) { _, newValue in
            if newValue.isEmpty {
                clearResolved()
            }
            completerDelegate.completer.queryFragment = newValue
        }
        .onChange(of: searchFieldFocused) { _, focused in
            // §3.3: the TextField's own tap already requests focus (standard SwiftUI
            // behavior) and pops the keyboard — this reacts to that by expanding the
            // sheet. Ported from `DriveModeDestinationView`'s `.onAppear { searchFieldFocused
            // = true }` auto-focus, adapted to fire on user-initiated focus rather than on
            // every appearance.
            if focused {
                detentKind = .large
            }
        }
        // FT-20 Stream C / QA §0d C2 fix: the error banner only renders at `.large` (it's
        // inside the `if detentKind == .large` block below), so a search/route failure
        // arriving while the user has collapsed the sheet to peek/medium would otherwise be
        // completely invisible — the request just silently stops, with no feedback. Rather
        // than surface a second, cramped error affordance at peek/medium (there's no room —
        // OQ-3's whole point is "search field alone" at that height), auto-expand to
        // `.large` the instant an error arrives, matching `DriveModeDestinationView`'s
        // original behavior where the banner was always visible (it lived inside a
        // full-screen cover, so there was no smaller state to hide behind).
        .onChange(of: errorMessage) { _, newValue in
            if newValue != nil {
                detentKind = .large
            }
        }
        // W8.5c auth gate: when authorization resolves while spinner is shown, clear the
        // spinner and attempt route fetch if now authorized. Verbatim from
        // `DriveModeDestinationView`.
        .onChange(of: locationService.isAuthorized) { _, isAuthorized in
            if isRequestingAuth {
                isRequestingAuth = false
                if isAuthorized {
                    Task { await fetchRouteAndReturn() }
                } else {
                    let status = locationService.authorizationStatus
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
    //
    // §0f Ruling 1 (2026-08-21, third live smoke): a small `gearshape` Settings button now
    // sits in the field's TRAILING EDGE (the Apple Maps avatar position) — the ONLY change
    // to this row's anatomy versus what shipped in Stream B/C. Everything else (icon,
    // TextField, clear button, the height-reporting `.background`) is kept verbatim.
    //
    // Two hit areas, made unambiguous by construction rather than by careful tuning:
    //   1. `searchFieldTapTarget` (icon + TextField + clear button) — its own
    //      `.contentShape(Rectangle())` + `.onTapGesture` focuses the TextField (expanding
    //      the sheet to `.large`, spec §3.3) from anywhere in that region, not just the
    //      TextField's own glyph rect.
    //   2. `settingsButton` — a sibling `Button` in the same outer `HStack`, occupying its
    //      own fixed frame. SwiftUI lays out `HStack` children in non-overlapping frames,
    //      so the gear's tap target and `searchFieldTapTarget`'s tap target never overlap;
    //      no additional gesture-priority tuning is needed. A `Button`'s own gesture
    //      recognizer also takes priority over an ancestor's `.onTapGesture` by SwiftUI's
    //      ordinary hit-testing, which is why the clear button (nested INSIDE
    //      `searchFieldTapTarget`) still works as its own tap target too.
    private var searchField: some View {
        HStack(spacing: 8) {
            searchFieldTapTarget
            settingsButton
        }
        .padding(10)
        // §0f "still open" finding: `.secondarySystemGroupedBackground` read as "dark
        // field on the sheet's dark blurred material, barely visible" (Kevin, third
        // smoke) — the sheet's own `.presentationBackground` was ALSO missing entirely
        // (`ContentView.swift`'s `browseNavigationSheetContent`, now fixed to
        // `.regularMaterial` matching every other sheet case), compounding the problem.
        // `.systemGray4` is a meaningfully lighter semantic fill than
        // `.secondarySystemGroupedBackground` in dark mode (AC-32: still a system/semantic
        // color, not a new hardcoded hex), and the hairline border gives the field a crisp
        // edge regardless of how translucent the material behind it reads in direct
        // sunlight (TF2-18's carried-over risk, spec §0b S6) — a standard, cheap technique
        // for legibility against blurred/dark material, not a new visual language.
        .background(Color(.systemGray4), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.separator), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // FT-20 Stream C / QA §0d C1 fix: this is the ONLY node in `BrowseSearchAreaView`
        // that reports its height for `BrowseNavigationSheet`'s peek/medium detent math —
        // never the whole view (which can contain a greedy `List` at `.large`).
        // `.onGeometryChange` reads THIS view's own final size (padding included) directly,
        // regardless of how much vertical space its parent offers, since nothing inside it
        // forces vertical expansion.
        //
        // PR #87 round 5 (2026-08-22): replaces a `.background(GeometryReader { ... }
        // .preference(...))` + `PreferenceKey` mechanism that, per Kevin's on-device `#if
        // DEBUG` readout, delivered `0` on every single layout pass despite this field
        // rendering at full height on screen — a `PreferenceKey.reduce` ordering bug (see
        // `BrowseNavigationSheet.swift`'s removed-`PreferenceKey` doc comment for the full
        // root-cause writeup), not anything wrong with what this node measures.
        // `.onGeometryChange(for:of:action:)` (iOS 17+, this project's deployment target)
        // reads a single named view's geometry directly with no cross-tree aggregation step
        // — the entire bug class is structurally impossible with this API, not just
        // avoided for the current tree shape.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
            onSearchFieldHeightChange(newHeight)
        }
    }

    /// Icon + `TextField` + conditional clear button — kept verbatim from
    /// `DriveModeDestinationView`, wrapped in its own tap target (see `searchField`'s doc
    /// comment above) so tapping anywhere in this region focuses the field, not only the
    /// TextField's own glyph rect.
    private var searchFieldTapTarget: some View {
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
        .contentShape(Rectangle())
        .onTapGesture { searchFieldFocused = true }
    }

    /// §0f Ruling 1: the field's trailing-edge Settings affordance — the Apple Maps avatar
    /// position. A distinct sibling in `searchField`'s outer `HStack`, never overlapping
    /// `searchFieldTapTarget`'s hit area (see `searchField`'s doc comment).
    ///
    /// [ACCESSIBILITY TRADE-OFF, flagged rather than silently decided] Apple HIG's own
    /// guidance recommends a 44×44pt minimum tap target; this affordance is deliberately
    /// smaller (32×32pt) to match its "corner affordance, not a co-equal action" framing
    /// (§0f's own words) inside a visually compact, single-line search field — inflating it
    /// to the full 44pt would make it look like a second primary control, which is exactly
    /// what §0f demoted it away from. 32pt is still comfortably tappable and roughly
    /// doubles the raw 17pt glyph's own footprint. If VoiceOver/Switch Control testing
    /// finds this too small in practice, the fix is a larger `.frame` here — this view's
    /// height math (`BrowseSheetDetentMath`) derives from whatever this renders, so it
    /// would flow through automatically.
    private var settingsButton: some View {
        Button(action: onSettingsTapped) {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Open settings")
    }

    // MARK: - Inline error banner (kept verbatim from DriveModeDestinationView)

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
        // Design-review finding S5: the old NavigationStack's Cancel button is gone —
        // this is the standard iOS "scroll the list to dismiss the keyboard" gesture's
        // replacement, since nothing else in this sheet guarantees keyboard dismissal.
        .scrollDismissesKeyboard(.interactively)
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
        // Design-review finding S5 — see recentDestinationsList's identical comment.
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - §3.2: the "place" state

    /// Resolved-destination card: pin + name + subtitle + distance + OQ-4's "parking near
    /// here" summary + a single "Go" button. Replaces `DriveModeDestinationView`'s
    /// two-piece "Destination" list row + separate `startDriveSection` button with one
    /// unified card, per spec §3.2's wireframe.
    private var placeState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(resolvedName ?? "Selected destination")
                        .font(.headline)
                    if let resolvedSubtitle, !resolvedSubtitle.isEmpty {
                        Text(resolvedSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let userLocation, let resolvedCoordinate {
                        Text(distanceText(from: userLocation, to: resolvedCoordinate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let nearbyParkingScore, let summary = nearbyParkingScore.summaryLabel {
                        parkingSummaryLine(bucket: nearbyParkingScore.bucket, label: summary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)

            if isLoadingRoute {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding best route...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if isRequestingAuth {
                // Auth gate spinner (AC-W85c.4 equivalent).
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Requesting location...")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                Button {
                    handleGoTap()
                } label: {
                    // "Go" — renamed from "Start Drive" (spec §3.2): shorter, and reads
                    // unambiguously now that there's no cruise option on this screen to
                    // distinguish it from. Fixes the FT-20 "button text too long"
                    // complaint for the destination path.
                    Label("Go", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .disabled(isResolvingAddress)
                .accessibilityLabel("Go")
                .accessibilityHint("Starts Drive Mode navigating to \(resolvedName ?? "the selected destination").")
            }
        }
        .padding(.bottom, 12)
    }

    /// OQ-4 / design-review finding S2: the bucketed word carries semantic color, reusing
    /// the EXISTING `ParkingColors` green/amber/red (never a new color) — matching every
    /// other place this classification appears on screen (polylines, the ASP banner).
    private func parkingSummaryLine(bucket: ParkingProximityBucket, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "parkingsign.circle.fill")
                .foregroundStyle(.secondary)
            (
                Text("Parking near here: ")
                    .foregroundStyle(.secondary)
                + Text(label)
                    .foregroundStyle(bucket.color ?? .secondary)
                    .fontWeight(.semibold)
            )
        }
        .font(.subheadline)
    }

    /// Distance formatting — same `MeasurementFormatter` + `Measurement<UnitLength>`
    /// pattern `DriveModeBottomCard.formattedDistance` already uses (W8.5c-polish PR-1),
    /// duplicated rather than shared: `DriveModeBottomCard` is Drive-Mode-ACTIVE chrome,
    /// explicitly out of scope for this spec (§2 "Out," §6's hard boundary) — this is a
    /// small, self-contained formatter, not worth threading a shared dependency through
    /// untouched Drive Mode files for.
    private func distanceText(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> String {
        let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        let usesMetricSystem = Locale.current.measurementSystem == .metric
        let measurement: Measurement<UnitLength>
        if usesMetricSystem {
            measurement = Measurement(value: meters / 1000.0, unit: UnitLength.kilometers)
        } else {
            measurement = Measurement(value: meters / 1609.344, unit: UnitLength.miles)
        }
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: measurement) + " away"
    }

    // MARK: - Actions

    /// Handles the "Go" button tap with the same auth gate
    /// `DriveModeDestinationView.handleStartDriveTap` uses (AC-W85c.4).
    private func handleGoTap() {
        let status = locationService.authorizationStatus
        switch status {
        case .notDetermined:
            isRequestingAuth = true
            locationService.requestAndFetchLocation()
        case .authorizedWhenInUse, .authorizedAlways:
            Task { await fetchRouteAndReturn() }
        case .denied, .restricted:
            showLocationDeniedAlert = true
        @unknown default:
            Task { await fetchRouteAndReturn() }
        }
    }

    /// Selects a completer suggestion and resolves it to a coordinate via MKLocalSearch.
    /// Verbatim port of `DriveModeDestinationView.selectCompletion` (M-1's timeout race),
    /// plus capturing `completion.subtitle` and computing the OQ-4 proximity score once
    /// resolved.
    private func selectCompletion(
        _ completion: MKLocalSearchCompletion,
        timeoutSeconds: Double = 10
    ) {
        searchFieldFocused = false
        query = completion.title + (completion.subtitle.isEmpty ? "" : ", \(completion.subtitle)")
        errorMessage = nil
        isResolvingAddress = true
        selectedCompletion = completion

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)

        Task { @MainActor in
            do {
                let item: MKMapItem = try await withThrowingTaskGroup(
                    of: MKMapItem.self
                ) { group in
                    group.addTask {
                        let response = try await search.start()
                        guard let first = response.mapItems.first else {
                            throw MKError(.placemarkNotFound)
                        }
                        return first
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        throw SearchTimeoutError()
                    }
                    guard let result = try await group.next() else {
                        group.cancelAll()
                        throw SearchTimeoutError()
                    }
                    group.cancelAll()
                    return result
                }

                self.isResolvingAddress = false
                self.resolvedCoordinate = item.placemark.coordinate
                self.resolvedName = item.name ?? completion.title
                self.resolvedSubtitle = completion.subtitle.isEmpty ? nil : completion.subtitle
                self.updateNearbyParkingScore()

            } catch is SearchTimeoutError {
                self.isResolvingAddress = false
                self.errorMessage = "Search timed out. Try again."
                self.resolvedCoordinate = nil
                self.resolvedName = nil
                self.resolvedSubtitle = nil

            } catch {
                self.isResolvingAddress = false
                self.errorMessage = "Couldn't resolve address — check connection. (\(error.localizedDescription))"
                self.resolvedCoordinate = nil
                self.resolvedName = nil
                self.resolvedSubtitle = nil
            }
        }
    }

    /// Selects a recent destination (coordinate already stored — no network call).
    /// Per AC-W85b.21 (kept verbatim): tapping a recent destination uses the stored
    /// coordinate directly.
    private func selectRecent(_ recent: RecentDestination) {
        searchFieldFocused = false
        query = recent.name
        errorMessage = nil
        resolvedCoordinate = recent.coordinate
        resolvedName = recent.name
        // Recents don't persist a subtitle (`RecentDestination` has no address field) —
        // the place state gracefully omits the line rather than showing a stale one.
        resolvedSubtitle = nil
        updateNearbyParkingScore()
    }

    /// OQ-4: computes the "parking near here" radius scan once a destination resolves.
    /// A fresh `ParkingRulesEngine()` instance, matching
    /// `DriveModeDestinationView.fetchRouteAndReturn`'s own precedent of instantiating one
    /// locally rather than threading ContentView's shared instance through as a parameter.
    private func updateNearbyParkingScore() {
        guard let resolvedCoordinate else {
            nearbyParkingScore = nil
            return
        }
        let engine = ParkingRulesEngine()
        nearbyParkingScore = ParkingProximityScorer.score(
            near: resolvedCoordinate,
            segments: segments,
            engine: engine
        )
    }

    /// Fetches the best parking-aware route and calls `onRouteReady`. Verbatim port of
    /// `DriveModeDestinationView.fetchRouteAndReturn`, minus the trailing `dismiss()` —
    /// see this file's top-of-file doc comment for why.
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

            let engine = ParkingRulesEngine()
            let best = routeService.pickBestParkingAwareRoute(routes, segments: segments, engine: engine, now: .nowET)
                ?? routes[0]

            let destinationName = resolvedName ?? "Unknown Destination"
            let recent = RecentDestination(
                id: UUID(),
                name: destinationName,
                latitude: destination.latitude,
                longitude: destination.longitude
            )
            recentStore.add(recent)

            // Out-of-coverage warning toast (OQ-7): allow routing with a toast warning.
            if !AppConstants.isInManhattanCoverage(destination) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    ToastService.shared.show(message: "Limited parking data outside Manhattan")
                }
            }

            isLoadingRoute = false
            onRouteReady(best, destination)
            // No dismiss() — see this file's top-of-file doc comment.

        } catch let routeError as MapboxRouteError {
            isLoadingRoute = false
            errorMessage = friendlyErrorMessage(for: routeError)
        } catch {
            isLoadingRoute = false
            errorMessage = "Route unavailable. Please try again."
        }
    }

    /// Resets the resolved destination state (used when query is cleared). AC-14.
    private func clearResolved() {
        resolvedCoordinate = nil
        resolvedName = nil
        resolvedSubtitle = nil
        nearbyParkingScore = nil
        selectedCompletion = nil
        errorMessage = nil
        isResolvingAddress = false
    }

    /// User-friendly error messages for each `MapboxRouteError` case. Verbatim port of
    /// `DriveModeDestinationView.friendlyErrorMessage`.
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

// Note: reuses `SearchTimeoutError` (defined in `Services/SearchCompleterDelegate.swift`,
// internal, "not private so the M-1 unit test can reference it via `@testable import
// WePark`") rather than defining a second sentinel type.

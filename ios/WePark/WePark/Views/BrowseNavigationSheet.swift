//
//  BrowseNavigationSheet.swift
//  WePark
//
//  FT-20 Stream A — browse-mode bottom sheet CONTAINER.
//  docs/ft20-bottom-sheet-navigation-spec.md §4.1/§4.2, §0b findings B1/B2/S1.
//
//  This file owns:
//    - `BrowseSheetDetentMath`: pure, UIKit-free computation of the two CUSTOM detent
//      heights (peek + medium). Kevin ruled OQ-3 (spec §0): NOT system `.medium` — a
//      custom height sized to "search field + exactly three rows and no more," measured
//      from actual rendered content (§0b finding B2), not hardcoded.
//    - `BrowseNavigationSheet`: the sheet's content view. Persistent search-area row on
//      top (Stream A ships a stub, `BrowseSheetSearchAreaStub` — Stream B replaces it,
//      see the note on `searchArea` below) + the medium-detent 3-item action list
//      (Settings / Cruise / Parking 101), built per design-review finding S1 as `List`
//      rows matching `recentDestinationsList`'s anatomy verbatim
//      (`DriveModeDestinationView.swift:269–302`) — NOT the capsule/pill anatomy of
//      FT-18's Bottom Dock, which is floating chrome over a live map and doesn't apply to
//      content living *inside* this sheet.
//
//  Presentation mechanics (the `.browseNav` case's `.presentationDetents` /
//  `.presentationBackgroundInteraction` / `.interactiveDismissDisabled` configuration, and
//  the "dismiss returns to `.browseNav`, not `nil`" rest-state change across every other
//  `ActiveSheet` case) live in `ContentView.swift`, per the existing
//  `ActiveSheet`/`.sheet(item:)` single-host pattern — this file only builds the content.
//
//  Not in this file (Stream B / Stream C, per the spec's §9 work-stream split):
//    - The real search field, `MKLocalSearchCompleter` suggestions, recent-destinations
//      list, the "place" state, and the Go button (Stream B — relocates out of
//      `DriveModeDestinationView`).
//    - Mounting this sheet into `ContentView`'s body, deleting `gearButtonOverlay` /
//      `driveEntryButton`, relocating Park Until, and the Drive-Mode / FT-15 block-select
//      boundary wiring (Stream C).
//

import SwiftUI

// MARK: - BrowseSheetDetentMath

/// Pure computation of FT-20's two custom `.presentationDetents` heights.
///
/// Zero SwiftUI/UIKit dependencies (no `UIScreen`, no `GeometryProxy`) by design, so this
/// logic is fully unit-testable without a simulator — see `BrowseSheetDetentMathTests.swift`.
/// The view layer (`BrowseNavigationSheet`) supplies the measured inputs via
/// `.onGeometryChange` (iOS 17+, this project's deployment target) and a screen-derived
/// `maxAllowedHeight` ceiling.
///
/// ⚠️ Do NOT use system `.medium` anywhere `.browseNav` is configured — design-review
/// finding B1 (docs/design/ft20-bottom-sheet-review.md): every one of the other 11
/// `.presentationDetents` call sites in `ContentView.swift` uses `.medium`/`[.medium,
/// .large]`, which is the easy, wrong thing to copy here. `.medium` is ~40% of the screen;
/// Kevin explicitly rejected that ("WePark's map IS the product"). The values this type
/// computes are fed into `.height(_:)`, never `.medium`.
enum BrowseSheetDetentMath {

    /// Absolute floor for the peek detent — a 44pt touch target (Apple HIG minimum) plus a
    /// grabber/inset allowance. Spec §4.1: "Peek must clear a full 44pt touch target plus
    /// the grabber." Guards against a pathologically short (or not-yet-measured, height 0)
    /// search row producing an unusable, un-tappable peek height.
    static let minimumPeekHeight: CGFloat = 64

    /// Extra vertical space, beyond the measured content itself, allotted to the grabber
    /// affordance the system sheet renders above the content, plus the content's own top
    /// inset.
    static let grabberAndInsetAllowance: CGFloat = 24

    /// Extra vertical space around the 3-row action list accounting for `.insetGrouped`'s
    /// own section top/bottom inset (the `List` row heights themselves are measured
    /// separately via `@ScaledMetric` — see `BrowseNavigationSheet.actionListHeight` — this
    /// covers only the chrome AROUND the rows, not the rows themselves).
    ///
    /// ⚠️ [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK — this is a GUESS, not a measured
    /// constant]. `24` is an unverified estimate of `.insetGrouped`'s real section
    /// top/bottom inset, not something read off rendered UIKit chrome — this machine has no
    /// simulator to measure it precisely, and real-world `.insetGrouped` section insets are
    /// commonly larger than this (often 35–50pt combined top+bottom, depending on iOS
    /// version). Do NOT treat this value as trustworthy until Kevin's on-device smoke
    /// explicitly confirms it: check that the 3rd row (Parking 101) isn't clipped and there
    /// is no dead space below it, at default Dynamic Type, before relying on this number for
    /// anything. If the smoke shows either symptom, adjust this one constant —
    /// `BrowseSheetDetentMath`'s own unit tests don't (and structurally can't) pin its exact
    /// value, since it's a physical UIKit layout constant, not derivable logic.
    static let listSectionChromeAllowance: CGFloat = 24

    /// Peek height = grabber/inset allowance + the measured height of the persistent
    /// search area, floored at `minimumPeekHeight`.
    static func peekHeight(searchAreaHeight: CGFloat) -> CGFloat {
        max(minimumPeekHeight, searchAreaHeight + grabberAndInsetAllowance)
    }

    /// Medium height = peek height + the measured height of the 3-row action list
    /// ("search + exactly three rows and no more" — OQ-3), clamped to `maxAllowedHeight`
    /// so a large Dynamic Type size can never drive this custom detent up to, or past,
    /// `.large` (design-review finding B2). Above that ceiling `.large` is what the user
    /// gets instead, and the ordinary (not `.scrollDisabled`) `List` handles whatever
    /// content doesn't fit — the same fallback any other system sheet content gets.
    static func mediumHeight(
        searchAreaHeight: CGFloat,
        actionListHeight: CGFloat,
        maxAllowedHeight: CGFloat
    ) -> CGFloat {
        let raw = peekHeight(searchAreaHeight: searchAreaHeight) + actionListHeight
        return min(raw, maxAllowedHeight)
    }
}

// MARK: - BrowseSheetDetentKind

/// FT-20 Stream A: which of `.browseNav`'s three detents is currently selected, tracked as
/// a semantic kind rather than a raw `PresentationDetent`.
///
/// The two `.height(_:)` detents' actual values change whenever `BrowseSheetDetentMath`
/// re-measures the sheet's content (Dynamic Type change, first layout, etc.) — storing the
/// raw `PresentationDetent` directly in `@State` would go stale the instant the underlying
/// height it was capturing changes (e.g. `.height(96)` selected, then a Dynamic Type change
/// re-measures peek to `.height(112)` — the stored selection no longer matches any entry in
/// the `.presentationDetents` array). Tracking "which kind" instead of "which value" avoids
/// that class of bug entirely.
enum BrowseSheetDetentKind: Equatable {
    case peek, medium, large
}

/// Builds the `.presentationDetents(selection:)` binding for `.browseNav` from a semantic
/// `BrowseSheetDetentKind` binding plus the current measured peek/medium heights.
func browseSheetDetentSelectionBinding(
    kind: Binding<BrowseSheetDetentKind>,
    peekHeight: CGFloat,
    mediumHeight: CGFloat
) -> Binding<PresentationDetent> {
    Binding<PresentationDetent>(
        get: {
            switch kind.wrappedValue {
            case .peek: return .height(peekHeight)
            case .medium: return .height(mediumHeight)
            case .large: return .large
            }
        },
        set: { newValue in
            if newValue == .large {
                kind.wrappedValue = .large
            } else if newValue == .height(mediumHeight) {
                kind.wrappedValue = .medium
            } else {
                kind.wrappedValue = .peek
            }
        }
    )
}

// MARK: - BrowseNavigationSheet

/// The `.browseNav` sheet's content.
///
/// **Public interface Stream B builds against:**
///   - `searchArea`: a `@ViewBuilder` slot for the sheet's persistent top row. Stream A
///     passes `BrowseSheetSearchAreaStub()` at the `ContentView.swift` call site. Stream B
///     relocates `DriveModeDestinationView`'s real `searchField` (+ suggestions/recents/
///     place-state content, shown only at the `.large` detent per spec §4.2) into that same
///     slot — no other change to this type is required for that swap. The slot's rendered
///     height directly drives the peek detent (`BrowseSheetDetentMath.peekHeight`), so
///     Stream B's real search field should stay close in height to the stub's single-line
///     row at rest; if the real content is taller for structural reasons (e.g. wrapping at
///     large Dynamic Type), that's fine — the peek detent grows with it automatically,
///     which is the point of measuring rather than hardcoding.
///   - `onSettingsTapped` / `onCruiseTapped` / `onParkingGuideTapped`: the 3-item list's row
///     actions. `ContentView` wires these to `activeSheet = .settings`, `enterCruiseMode()`
///     (AC-18 — no intermediate menu), and `activeSheet = .parkingGuide` respectively.
///   - `onPeekHeightChange` / `onMediumHeightChange`: fire whenever the measured content
///     changes (initial layout, Dynamic Type change, etc.) with the two already-computed,
///     already-clamped detent heights. `ContentView` stores these into the `@State` it
///     feeds into `.presentationDetents([.height(peek), .height(medium), .large], ...)`.
struct BrowseNavigationSheet<SearchArea: View>: View {

    // MARK: Public interface
    //
    // `searchArea` stores the already-built view, not a closure — the `@ViewBuilder`
    // attribute lives on this initializer's parameter instead (the same pattern this
    // codebase already uses once, `FAQHelpView.swift:76`'s `@ViewBuilder content: () ->
    // some View`), rather than on the stored property directly. Attaching `@ViewBuilder`
    // to a stored closure-typed property is real, but version/context-sensitive Swift
    // syntax this file's author has no toolchain to verify — the init-parameter form is
    // the unambiguous, universally-supported one.

    let searchArea: SearchArea
    let onSettingsTapped: () -> Void
    let onCruiseTapped: () -> Void
    let onParkingGuideTapped: () -> Void
    let onPeekHeightChange: (CGFloat) -> Void
    let onMediumHeightChange: (CGFloat) -> Void

    init(
        @ViewBuilder searchArea: () -> SearchArea,
        onSettingsTapped: @escaping () -> Void,
        onCruiseTapped: @escaping () -> Void,
        onParkingGuideTapped: @escaping () -> Void,
        onPeekHeightChange: @escaping (CGFloat) -> Void,
        onMediumHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.searchArea = searchArea()
        self.onSettingsTapped = onSettingsTapped
        self.onCruiseTapped = onCruiseTapped
        self.onParkingGuideTapped = onParkingGuideTapped
        self.onPeekHeightChange = onPeekHeightChange
        self.onMediumHeightChange = onMediumHeightChange
    }

    // MARK: Measured content heights

    @State private var searchAreaHeight: CGFloat = 0

    /// Dynamic-Type-responsive single-row height for the 3-item action list, via
    /// `@ScaledMetric` rather than `GeometryReader`/`.onGeometryChange` on the `List`
    /// itself.
    ///
    /// `List` is a UIKit-bridged, flexible/greedy-sizing container: left unconstrained, it
    /// expands to fill whatever vertical space its parent offers, rather than reporting an
    /// intrinsic "3 rows tall" size — a system sheet's content is laid out against the
    /// FULL `.large`-sized container regardless of which detent is currently visible (the
    /// detent only crops what's exposed), so measuring `actionList`'s own rendered geometry
    /// directly would report something close to that full container height, not "3 rows."
    /// That would silently defeat the entire "search + exactly three rows and no more"
    /// promise (OQ-3) the custom medium detent exists for. `@ScaledMetric` sidesteps this
    /// by measuring what a single row's height SHOULD be (scaled with Dynamic Type, same as
    /// system-sized list rows), independent of how much space `List` is offered — the
    /// computed `actionListHeight` below then constrains `actionList`'s own frame, so it
    /// can never grow past what was reported.
    @ScaledMetric(relativeTo: .body) private var singleActionRowHeight: CGFloat = 44

    /// 3 rows (Settings / Cruise / Parking 101) at the Dynamic-Type-scaled row height,
    /// plus `.insetGrouped`'s own section chrome allowance.
    private var actionListHeight: CGFloat {
        singleActionRowHeight * 3 + BrowseSheetDetentMath.listSectionChromeAllowance
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            searchArea
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                    searchAreaHeight = newHeight
                }

            actionList
                .frame(height: actionListHeight)
        }
        // Re-report on every measured change (initial layout, Dynamic Type change, device
        // rotation) — `.onGeometryChange`'s action already fires on first layout, so this
        // covers all subsequent changes too. `actionListHeight` is computed (not measured
        // via geometry), so it's covered by watching `singleActionRowHeight` instead.
        .onChange(of: searchAreaHeight) { _, _ in reportHeights() }
        .onChange(of: singleActionRowHeight) { _, _ in reportHeights() }
        .onAppear { reportHeights() }
    }

    // MARK: - S1: medium-detent 3-item list

    /// Settings / Cruise / Parking 101 — `List` + `Section`, `.listStyle(.insetGrouped)`,
    /// SF Symbol leading icon + label, per design-review finding S1. Order matches the
    /// spec's own canonical listing (§0's OQ-3 ruling, §2, §4.2, AC-15). Height is
    /// constrained by the caller (`body`, above) to `actionListHeight` — NOT
    /// `.scrollDisabled`, so content that doesn't fit at extreme Dynamic Type sizes (where
    /// `.large` itself becomes the active detent, per `BrowseSheetDetentMath.mediumHeight`'s
    /// clamp) is still reachable by scrolling, same as any other system sheet content.
    private var actionList: some View {
        List {
            Section {
                Button(action: onSettingsTapped) {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityLabel("Open settings")

                // "Cruise" (not "Drive Mode", not a menu) — Kevin's terminology ruling
                // (spec §3.1): entering Drive Mode WITH a destination is the
                // search→place→Go path; this button means driving with NO destination.
                // Reuses `car.front.waves.right.fill` from the soon-to-be-deleted
                // `driveEntryButton`'s "Find Parking nearby" menu item
                // (`ContentView.swift` ~1637).
                Button(action: onCruiseTapped) {
                    Label("Cruise", systemImage: "car.front.waves.right.fill")
                }
                .accessibilityHint("Starts Drive Mode with no destination, to find parking nearby.")

                Button(action: onParkingGuideTapped) {
                    Label("Parking 101", systemImage: "questionmark.circle")
                }
                .accessibilityLabel("Parking 101 guide")
                .accessibilityHint("Opens the beginner's guide to reading NYC parking signs.")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Height reporting

    private func reportHeights() {
        onPeekHeightChange(BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight))
        onMediumHeightChange(
            BrowseSheetDetentMath.mediumHeight(
                searchAreaHeight: searchAreaHeight,
                actionListHeight: actionListHeight,
                maxAllowedHeight: Self.maxAllowedMediumHeight
            )
        )
    }

    /// Ceiling for the medium detent (design-review finding B2's clamp), kept meaningfully
    /// under `.large` (~90% of screen per spec §4.2's table) so the custom medium detent
    /// can never reach or exceed it. Read here in the view layer (not inside
    /// `BrowseSheetDetentMath`) so the clamp math itself stays a pure, UIKit-free,
    /// unit-testable function.
    ///
    /// [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK] Design-review finding B2 explicitly
    /// calls for verifying both detent heights "at default and at least one accessibility
    /// size (e.g., AX3) before merge" — this machine has no simulator. Kevin/QA: please
    /// confirm at AX3 that the medium detent still reads as "search + three rows," not a
    /// clipped or scroll-required list, before sign-off.
    ///
    /// Reads the height off the app's active `UIWindowScene` rather than `UIScreen.main`
    /// (QA docs/qa/ft20-stream-a-pr85.md Finding #5 — `UIScreen.main` is on Apple's
    /// deprecation-direction path since iOS 13; per-scene sizing is the supported
    /// replacement). Falls back to `UIScreen.main` only if no window scene is connected yet
    /// (e.g. a very early launch timing edge case), which this single-window/single-scene
    /// app should never actually hit in practice.
    private static var maxAllowedMediumHeight: CGFloat {
        let screenHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height
            ?? UIScreen.main.bounds.height
        return screenHeight * 0.75
    }
}

// MARK: - BrowseSheetSearchAreaStub

/// FT-20 Stream A placeholder for the sheet's persistent top row. Visually modeled on
/// `DriveModeDestinationView.searchField` (`DriveModeDestinationView.swift:218–242`) so the
/// measured peek height Stream A ships with is a realistic approximation of what Stream B's
/// real search field will measure to — not a guess.
///
/// Stream B (§4.3) replaces this stub with the real relocated search field + suggestions/
/// recents/place-state content passed via `BrowseNavigationSheet`'s generic `searchArea:`
/// parameter. This type itself is not part of the public interface Stream B needs to keep;
/// it exists only so Stream A's container has something real to render and measure, and so
/// Stream C has something to mount before Stream B lands.
struct BrowseSheetSearchAreaStub: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Search for a destination")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search for a destination")
        .accessibilityHint("Stream A placeholder — Stream B replaces this with the real search field.")
    }
}

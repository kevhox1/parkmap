//
//  BrowseNavigationSheet.swift
//  WePark
//
//  FT-20 — browse-mode bottom sheet CONTAINER. Built in Stream A, real content wired by
//  Stream B, mounted live by Stream C (`ft20BrowseSheetEnabled == true`).
//  docs/ft20-bottom-sheet-navigation-spec.md §4.1/§4.2, §0b findings B1/B2/S1, §0d C1.
//
//  This file owns:
//    - `BrowseSheetDetentMath`: pure, UIKit-free computation of the two CUSTOM detent
//      heights (peek + medium). Kevin ruled OQ-3 (spec §0): NOT system `.medium` — a
//      custom height sized to "search field + exactly three rows and no more," measured
//      from actual rendered content (§0b finding B2), not hardcoded.
//    - `BrowseSheetSearchAreaHeightPreferenceKey`: the QA §0d C1 fix — how the search
//      field's own height reaches this container without ever measuring the large-detent-
//      only `List` content mounted alongside it. See its own doc comment below.
//    - `BrowseNavigationSheet`: the sheet's content view. Persistent search-area row on
//      top (`Views/BrowseSearchAreaView.swift`, Stream C's live entry point — see the note
//      on `searchArea` below) + the medium-detent 3-item action list (Settings / Cruise /
//      Parking 101), built per design-review finding S1 as `List` rows matching
//      `recentDestinationsList`'s anatomy verbatim — NOT the capsule/pill anatomy of
//      FT-18's Bottom Dock, which is floating chrome over a live map and doesn't apply to
//      content living *inside* this sheet.
//
//  Presentation mechanics (the `.browseNav` case's `.presentationDetents` /
//  `.presentationBackgroundInteraction` / `.interactiveDismissDisabled` configuration, and
//  the "dismiss returns to `.browseNav`, not `nil`" rest-state change across every other
//  `ActiveSheet` case) live in `ContentView.swift`, per the existing
//  `ActiveSheet`/`.sheet(item:)` single-host pattern — this file only builds the content.
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
    ///
    /// ⚠️ [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK — this is a GUESS, not a measured
    /// constant]. Same caveat as `listSectionChromeAllowance` below, and previously missing
    /// here despite carrying the identical risk: `24` is an unverified estimate of how much
    /// vertical space `.presentationDragIndicator(.visible)`'s grabber plus the system
    /// sheet's own top content inset actually consumes — not something read off rendered
    /// UIKit chrome, since this machine has no simulator. If this OVERESTIMATES the real
    /// system chrome, the peek detent's visible content area ends up TALLER than
    /// `searchAreaHeight` alone, exposing a slice of `actionList` below the search field
    /// (grabber, a gap, then the first action row) — a plausible contributor to the
    /// "peek shows the Settings row" live-smoke bug. If it UNDERESTIMATES, peek instead
    /// crops the bottom of the search field. Kevin's on-device smoke should confirm peek
    /// shows exactly the search field and nothing else, at default Dynamic Type, before
    /// this constant is trusted — same gate `listSectionChromeAllowance` already carries.
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

    /// FT-20 Stream C bugfix (QA live-smoke, two-bug report): whether a `searchAreaHeight`
    /// value is a genuine measurement worth reporting into `ContentView`'s PERSISTENT
    /// `browseSheetPeekHeight`/`browseSheetMediumHeight` state, or an unmeasured placeholder
    /// that should be ignored.
    ///
    /// `BrowseNavigationSheet` is torn down and recreated — losing its own
    /// `@State searchAreaHeight`, which reinitializes to `0` — every time browse mode's
    /// sheet is replaced by ANY other `ActiveSheet` case (Settings, Parking 101, a pin tap,
    /// a block tap...) and the user returns to `.browseNav`. `.sheet(item:)` is a single
    /// host with distinct `id`s per case (`ContentView.swift`'s `ActiveSheet.id`), so this
    /// is not a rare edge case — it is the STEADY-STATE behavior on every such round trip,
    /// not just the Parking 101 path that surfaced it.
    ///
    /// Without this guard, `BrowseNavigationSheet.body`'s `.onAppear` (which unconditionally
    /// called `reportHeights()`) would fire with the freshly-reset `searchAreaHeight == 0`
    /// on every remount, computing `peekHeight(0)` / `mediumHeight(0, ...)` — the
    /// unmeasured-floor values — and OVERWRITE `ContentView`'s already-correct, persisted
    /// heights with those degenerate ones, before the real `GeometryReader` measurement
    /// arrives a moment later and corrects them again. That churn (good height → degenerate
    /// floor height → corrected height, repeated on every sheet round-trip) is real and
    /// reachable; whether a live-`.presentationDetents` resize reliably "catches up" to the
    /// correction on every occurrence could not be confirmed without a device, but the churn
    /// itself is an unforced, easily-avoidable defect — this guard removes it entirely by
    /// simply never reporting a not-yet-measured value in the first place.
    static func isGenuineMeasurement(searchAreaHeight: CGFloat) -> Bool {
        searchAreaHeight > 0
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

// MARK: - BrowseSheetSearchAreaHeightPreferenceKey

/// FT-20 Stream C fix for QA §0d Finding C1 (`docs/qa/ft20-stream-b-pr86.md`): the height
/// that drives `BrowseSheetDetentMath.peekHeight`/`.mediumHeight` must come from ONLY the
/// sheet's always-visible top row (the search field), never from `searchArea`'s full
/// rendered content.
///
/// Why not `.onGeometryChange` on the whole `searchArea` slot (Stream A's original
/// approach)? Because Stream B's real content (`BrowseSearchAreaView`) conditionally
/// renders a `List` (recents/suggestions) inside `searchArea` once `detentKind == .large`
/// — and, per `actionList`'s own doc comment below, a system sheet's content is laid out
/// against the FULL `.large`-sized container regardless of which detent is *currently
/// selected* (the detent only crops what's exposed). So the moment the user is at
/// `.large`, measuring the whole `searchArea` view's geometry reports something close to
/// the full container height, not "the search field alone" — corrupting
/// `peekHeight`/`mediumHeight` for however long that inflated value is live, exactly the
/// `List`-greedy-sizing trap `actionListHeight` was already built to avoid, reintroduced in
/// a spot Stream A never anticipated (Stream B's real content didn't exist yet).
///
/// The fix: `BrowseSearchAreaView.searchField` (the one node that's ALWAYS visible,
/// regardless of detent) reports its own intrinsic height directly via this
/// `PreferenceKey`, which bubbles up through the view tree to `BrowseNavigationSheet.body`
/// unaffected by whatever large-detent-only content (`List`, place-state card, error
/// banner) happens to be mounted alongside it. This is the textbook use case for
/// `PreferenceKey` — communicating a value up an arbitrary intermediate view hierarchy that
/// the ancestor (`BrowseNavigationSheet`, generic over `SearchArea: View`) has no structural
/// knowledge of. No `List` is ever measured by this mechanism; `actionListHeight`'s own
/// `@ScaledMetric`-derived "constrain, don't measure" technique is untouched below.
struct BrowseSheetSearchAreaHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    /// Exactly one reporter is expected in the tree (the search field's own `.background`
    /// probe) — `reduce` still must be total per `PreferenceKey`'s protocol requirement, so
    /// this takes the newest report rather than summing/maxing, which would silently
    /// misbehave if a future caller nested a second reporter.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

    /// FT-20 Stream C bugfix (QA live-smoke, two-bug report): classifies a
    /// `PresentationDetent` reported back by the system (via `.presentationDetents`'s
    /// `selection` binding's `set` callback) into a `BrowseSheetDetentKind`, given the
    /// CURRENTLY measured peek/medium heights — or `nil` if `newValue` doesn't exactly
    /// match `.large` or either currently-known custom height.
    ///
    /// A `nil` result is not rare: it's guaranteed to happen whenever `peekHeight`/
    /// `mediumHeight` are actively changing relative to whatever value the system is
    /// echoing back — a Dynamic Type change mid-drag (the scenario Stream A's original QA
    /// Finding #4 flagged and pinned a test for, without fixing), or — newly live once
    /// Stream C wired up `BrowseSearchAreaView`'s real content — `BrowseNavigationSheet`
    /// remounting fresh every time browse mode's sheet is replaced by another `ActiveSheet`
    /// case and restored (see `BrowseSheetDetentMath.isGenuineMeasurement`'s doc comment):
    /// each such remount churns `peekHeight`/`mediumHeight` through transient values while
    /// `.onPreferenceChange` catches up, and this classification function's caller is
    /// reading whatever `PresentationDetent` UIKit happens to report during that window.
    ///
    /// The OLD behavior (Stream A, previously pinned by
    /// `BrowseSheetDetentSelectionBindingTests`' now-updated "falls back to peek" tests —
    /// see that suite's history) silently reclassified ANY unmatched value as `.peek` —
    /// meaning a genuine
    /// medium/large selection could be collapsed to peek purely from float staleness, with
    /// no user action involved. Callers of this function must PRESERVE the current kind
    /// when it returns `nil`, not force a fallback — "we didn't recognize this echo" is not
    /// evidence the user dragged to peek.
    static func classify(
        _ detent: PresentationDetent,
        peekHeight: CGFloat,
        mediumHeight: CGFloat
    ) -> BrowseSheetDetentKind? {
        if detent == .large {
            return .large
        } else if detent == .height(mediumHeight) {
            return .medium
        } else if detent == .height(peekHeight) {
            return .peek
        }
        return nil
    }
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
            // Unrecognized values (see `BrowseSheetDetentKind.classify`'s doc comment)
            // preserve the current kind rather than forcing `.peek` — a stale echo during
            // a height remeasurement/remount race is not evidence of a real user selection.
            if let classified = BrowseSheetDetentKind.classify(
                newValue, peekHeight: peekHeight, mediumHeight: mediumHeight
            ) {
                kind.wrappedValue = classified
            }
        }
    )
}

// MARK: - BrowseNavigationSheet

/// The `.browseNav` sheet's content.
///
/// **Public interface Stream B builds against:**
///   - `searchArea`: a `@ViewBuilder` slot for the sheet's persistent top row. Stream C
///     mounts `BrowseSearchAreaView` here (Stream A's stub, `BrowseSheetSearchAreaStub`, is
///     gone — the real content has been live since Stream B). The peek/medium detent math
///     does NOT measure this slot's overall geometry (QA C1 fix — see
///     `BrowseSheetSearchAreaHeightPreferenceKey`'s doc comment): `BrowseSearchAreaView`'s
///     own always-visible `searchField` node reports its intrinsic height directly via that
///     preference key, so the large-detent-only content (recents/suggestions/place state/
///     error banner) mounted alongside it can never corrupt `peekHeight`/`mediumHeight`,
///     no matter how tall a `List` inside it gets asked to lay out.
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

            actionList
                .frame(height: actionListHeight)
        }
        // FT-20 Stream C / QA C1 fix: read the search field's OWN reported height via the
        // preference key above, not `searchArea`'s overall geometry — see
        // `BrowseSheetSearchAreaHeightPreferenceKey`'s doc comment for why measuring the
        // whole slot is unsafe once it can contain a `List`.
        .onPreferenceChange(BrowseSheetSearchAreaHeightPreferenceKey.self) { newHeight in
            searchAreaHeight = newHeight
        }
        // Re-report on every measured change (initial layout, Dynamic Type change, device
        // rotation) — the preference fires on first layout, so this covers all subsequent
        // changes too. `actionListHeight` is computed (not measured via geometry), so it's
        // covered by watching `singleActionRowHeight` instead.
        //
        // FT-20 Stream C bugfix (QA live-smoke, two-bug report): every one of these three
        // call sites is guarded by `BrowseSheetDetentMath.isGenuineMeasurement` — see its
        // doc comment. `searchAreaHeight` resets to `0` every time this view remounts (any
        // round trip through another `ActiveSheet` case), and reporting that not-yet-
        // measured value would overwrite `ContentView`'s already-correct, persisted
        // `browseSheetPeekHeight`/`browseSheetMediumHeight` with the unmeasured-floor
        // values, only to correct them again a moment later once the real
        // `GeometryReader` measurement arrives. Skipping the report entirely until a
        // genuine measurement exists removes that churn outright: the persisted heights
        // simply hold their last-known-good value across a remount instead of round-
        // tripping through a degenerate one.
        .onChange(of: searchAreaHeight) { _, newValue in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: newValue) else { return }
            reportHeights()
        }
        .onChange(of: singleActionRowHeight) { _, _ in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
        .onAppear {
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
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

// Note: `BrowseSheetSearchAreaStub` (Stream A's placeholder search row) is gone — Stream B
// replaced it at the `ContentView.swift` call site with the real `BrowseSearchAreaView`,
// and Stream C is what makes that call site live. Nothing referenced the stub anymore, so
// it was deleted rather than left as dead code.

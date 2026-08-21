//
//  BrowseNavigationSheet.swift
//  WePark
//
//  FT-20 — browse-mode bottom sheet CONTAINER. Built in Stream A, real content wired by
//  Stream B, mounted live by Stream C (`ft20BrowseSheetEnabled == true`).
//  docs/ft20-bottom-sheet-navigation-spec.md §4.1/§4.2, §0b findings B1/B2, §0e, §0f.
//
//  This file owns:
//    - `BrowseSheetDetentMath`: pure, UIKit-free computation of the two CUSTOM detent
//      heights (peek + medium). Kevin ruled OQ-3 (spec §0): NOT system `.medium` — a
//      custom height sized to "search field + action content and no more," measured
//      from actual rendered content (§0b finding B2), not hardcoded.
//    - `BrowseSheetSearchAreaHeightPreferenceKey`: the QA §0d C1 fix — how the search
//      field's own height reaches this container without ever measuring the large-detent-
//      only `List` content mounted alongside it. See its own doc comment below.
//    - `BrowseNavigationSheet`: the sheet's content view. Persistent search-area row on
//      top (`Views/BrowseSearchAreaView.swift`, Stream C's live entry point — see the note
//      on `searchArea` below) + the medium-detent action content below it.
//
//      ⚠️ Kevin's third live-smoke ruling (spec §0f, 2026-08-21) is the CURRENT authority
//      on this hierarchy, superseding §0e Ruling 1 (a horizontal 3-icon row), which itself
//      superseded design-review finding S1 (`List` rows). §0f's finding: three equal
//      controls asserted Settings/Cruise/Parking 101 mattered equally, and they don't —
//      Apple Maps itself has no in-app settings button; the only entry point is a small
//      avatar in the search field's trailing edge. The rebuilt hierarchy, top to bottom:
//        1. Search field, with a small `gearshape` Settings affordance in its TRAILING
//           EDGE (`BrowseSearchAreaView.searchField`, this file has no part in it).
//        2. One prominent primary button — `car.fill` + "Find a Spot" — filled, full-
//           width, unmistakably the main action. Still calls `onCruiseTapped`
//           (`enterCruiseMode()`) — §0f Ruling 2 is a LABEL change ("Cruise" → "Find a
//           Spot" in user-facing copy only), not a refactor. Internal identifiers
//           (`enterCruiseMode()`, `driveModeStyle`, `.cruise`, and this file's own
//           `onCruiseTapped` closure name) are deliberately left alone.
//        3. A quiet tertiary text link — "New to parking?" — opens Parking 101. A link,
//           not a button; visually subordinate to both of the above.
//      Do NOT "restore" the three-icon row or the `List` citing S1/§0e — §0f is the
//      authority. See `actionColumn`'s own doc comment for the full anatomy history.
//
//  Presentation mechanics (the `.browseNav` case's `.presentationDetents` /
//  `.presentationBackgroundInteraction` / `.presentationBackground` /
//  `.interactiveDismissDisabled` configuration, and the "dismiss returns to `.browseNav`,
//  not `nil`" rest-state change across every other `ActiveSheet` case) live in
//  `ContentView.swift`, per the existing `ActiveSheet`/`.sheet(item:)` single-host pattern
//  — this file only builds the content.
//

import SwiftUI

// MARK: - BrowseSheetDetentMath

/// Pure computation of FT-20's two custom `.presentationDetents` heights.
///
/// Zero SwiftUI/UIKit dependencies (no `UIScreen`, no `GeometryProxy`) by design, so this
/// logic is fully unit-testable without a simulator — see `BrowseSheetDetentMathTests.swift`.
/// The view layer (`BrowseNavigationSheet`) supplies the measured inputs via
/// `.onGeometryChange`-style preference reporting and a screen-derived `maxAllowedHeight`
/// ceiling.
///
/// ⚠️ Do NOT use system `.medium` anywhere `.browseNav` is configured — design-review
/// finding B1 (docs/design/ft20-bottom-sheet-review.md): every one of the other 11
/// `.presentationDetents` call sites in `ContentView.swift` uses `.medium`/`[.medium,
/// .large]`, which is the easy, wrong thing to copy here. `.medium` is ~40% of the screen;
/// Kevin explicitly rejected that ("WePark's map IS the product"). The values this type
/// computes are fed into `.height(_:)`, never `.medium`.
enum BrowseSheetDetentMath {

    /// Nominal floor for the peek detent — a 44pt touch target (Apple HIG minimum) plus a
    /// grabber/inset allowance. Spec §4.1: "Peek must clear a full 44pt touch target plus
    /// the grabber." This is a SOFT floor for `peekHeight` below (see that function's doc
    /// comment for why it can't be an unconditional floor anymore) but stays the load-
    /// bearing value everywhere else a "how tall must peek realistically be" figure is
    /// needed (e.g. `ContentView`'s own initial `@State` placeholder, before any real
    /// measurement has landed).
    static let minimumPeekHeight: CGFloat = 64

    /// ⚠️ REMOVED 2026-08-21 (spec §0f) — root-cause note kept here rather than silently
    /// deleted, because an agent grepping for "why did the peek fix change" needs the full
    /// history, not just a diff.
    ///
    /// This constant used to add a guessed allowance on top of the measured search-area
    /// height to account for the SYSTEM's own `.presentationDragIndicator` grab-handle
    /// region, which this file's content sits below. It went through two live-smoke
    /// rounds — `24`, then `24 → 12` (removing a real double-count of
    /// `BrowseSearchAreaView.searchField`'s own `.padding(.vertical, 12)`, which the
    /// height-reporting `GeometryReader` was already capturing since it's attached AFTER
    /// that padding, `BrowseSearchAreaView.swift:241–260`) — and the bug (peek revealing a
    /// sliver of the medium-detent action content) SURVIVED BOTH attempts. Kevin's report
    /// after the `12` fix: *"the three buttons are peaking."*
    ///
    /// Root cause: the true footprint of the system's grab-indicator region is a private
    /// UIKit/SwiftUI layout detail this codebase has no API to read and this environment
    /// (no simulator, no device) has no way to measure. Both `24` and `12` were guesses.
    /// `peekHeight` ADDED that guess on top of a fully-measured `searchAreaHeight`, and
    /// because this file's content is laid out against the FULL `.large`-sized container
    /// regardless of the currently-selected detent (only the visible WINDOW from the top
    /// changes size — see `BrowseSheetSearchAreaHeightPreferenceKey`'s doc comment for the
    /// same fact applied to `searchArea`), any overshoot in that guess directly exposed
    /// that many points of whatever sits immediately below `searchArea` in `body`'s
    /// `VStack(spacing: 0)` — the action content. A guessed additive constant can, by
    /// construction, only be verified by looking at a rendered device, which contradicts
    /// this bug having already shipped, been "fixed," and shipped broken again twice.
    ///
    /// The fix is architectural, not a third guess: `peekHeight` below no longer adds
    /// anything to `searchAreaHeight` — instead it's derived FROM `searchAreaHeight` (a
    /// value this file fully controls and measures precisely) and hard-clamped so it can
    /// never reach `actionContentTopOffset`, regardless of what the system's own grabber
    /// chrome ends up costing on top of whatever `.height(_:)` value is presented. See
    /// `peekHeight`'s doc comment for the construction, and
    /// `BrowseSheetPeekInvariantTests` for the regression test this bug now has.

    /// Vertical gap, authored and rendered directly by this file (not a guess about
    /// external system chrome), between the search area and the action content in
    /// `BrowseNavigationSheet.body`'s `VStack`. Gives the peek/medium boundary genuine
    /// visual breathing room and — more importantly — a real, testable margin the
    /// `peekHeight` clamp below can rely on.
    static let interSectionGutter: CGFloat = 8

    /// Safety margin subtracted from the measured search-area height before flooring, so
    /// that even in the "no clamp needed" branch of `peekHeight` (realistic, non-degenerate
    /// content), peek sits comfortably under `searchAreaHeight` rather than flush against
    /// it — cheap, additional insurance against the system's own grabber chrome (whatever
    /// its true footprint turns out to be) nudging the visible window a few points past
    /// where our content ends.
    static let peekSafetyMargin: CGFloat = 8

    /// The minimum gap, below `actionContentTopOffset`, that `peekHeight`'s hard clamp
    /// enforces — i.e. how far "strictly less than" must be, not just "less than or equal
    /// to." A named constant rather than a bare `1` so the invariant it protects is
    /// self-documenting at the call site.
    private static let peekToActionContentMinimumGap: CGFloat = 1

    /// The vertical offset, from the top of the sheet's rendered content, at which the
    /// action content (the "Find a Spot" primary button) begins — i.e. the exact boundary
    /// `peekHeight` must never cross. `searchArea` renders first, then `interSectionGutter`
    /// of blank space, then the action content — see `BrowseNavigationSheet.body`.
    static func actionContentTopOffset(searchAreaHeight: CGFloat) -> CGFloat {
        searchAreaHeight + interSectionGutter
    }

    /// Peek height: derived from the measured search-area height, floored at
    /// `minimumPeekHeight` for a realistic 44pt-plus-grabber touch target, but HARD-CLAMPED
    /// so it can never reach `actionContentTopOffset` — i.e. it is now structurally
    /// impossible for peek to reveal any of the action content, regardless of what the
    /// system's own (unmeasurable, from this environment) grab-indicator chrome costs on
    /// top of the presented `.height(_:)` value. See `BrowseSheetDetentMath`'s removed-
    /// constant doc comment (above `interSectionGutter`) for the two-live-smoke-round
    /// history this construction replaces.
    ///
    /// Priority ordering, stated explicitly because the two goals can conflict at
    /// pathologically small inputs: "never reveal action content" wins over "meet the
    /// nominal `minimumPeekHeight` floor." This is deliberate and safe in practice —
    /// `searchAreaHeight` values small enough to trigger the clamp (roughly ≤56pt) are not
    /// reachable from a real rendered search field (its own fixed `.padding(10)` +
    /// `.padding(.vertical, 12)`, `BrowseSearchAreaView.swift:241–244`, put its realistic
    /// minimum well above that), and the true degenerate case — `searchAreaHeight == 0`,
    /// the unmeasured `@State` default — never reaches a live `.presentationDetents` call
    /// in the first place: `BrowseNavigationSheet`'s own `isGenuineMeasurement` guard
    /// refuses to report it, and `ContentView`'s initial placeholder is hardcoded straight
    /// to `minimumPeekHeight`, bypassing this function entirely (`ContentView.swift`'s
    /// `browseSheetPeekHeight` `@State` default).
    static func peekHeight(searchAreaHeight: CGFloat) -> CGFloat {
        let candidate = max(minimumPeekHeight, searchAreaHeight - peekSafetyMargin)
        let ceiling = actionContentTopOffset(searchAreaHeight: searchAreaHeight)
            - peekToActionContentMinimumGap
        return max(0, min(candidate, ceiling))
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

    /// Medium height = the full offset to the top of the action content
    /// (`actionContentTopOffset`) + the measured height of that action content itself
    /// ("search + Find-a-Spot + New-to-parking, and no more" — OQ-3/§0f), clamped to
    /// `maxAllowedHeight` so a large Dynamic Type size can never drive this custom detent
    /// up to, or past, `.large` (design-review finding B2).
    ///
    /// Deliberately NOT expressed as `peekHeight(...) + actionColumnHeight` (the Stream C
    /// formula this replaces) — `peekHeight`'s own clamp exists purely to protect the PEEK
    /// detent's crop boundary and has nothing to do with how tall the FULL medium content
    /// actually is; reusing it here was itself part of what made the old formula fragile
    /// (a change aimed at fixing peek could silently move medium too). `mediumHeight` now
    /// derives independently from the same `searchAreaHeight`/`interSectionGutter` values
    /// via `actionContentTopOffset`.
    static func mediumHeight(
        searchAreaHeight: CGFloat,
        actionColumnHeight: CGFloat,
        maxAllowedHeight: CGFloat
    ) -> CGFloat {
        let raw = actionContentTopOffset(searchAreaHeight: searchAreaHeight) + actionColumnHeight
        return min(raw, maxAllowedHeight)
    }

    /// Height of the medium-detent action content — §0f's rebuilt hierarchy: one
    /// full-width primary button ("Find a Spot") + a vertical gap + one tertiary text link
    /// ("New to parking?") + top/bottom padding around the whole column.
    ///
    /// Pure and UIKit-free, mirroring `peekHeight`/`mediumHeight` above and the "derive,
    /// don't measure a greedy container" discipline this file has used since Stream A/QA
    /// finding C1 — an `HStack`/`VStack` of plain `Button`s and `Text` isn't greedy the way
    /// `List` is, but computing from values we control (rather than a second geometry-
    /// measurement mechanism) keeps this file's one battle-tested approach to sizing
    /// consistent across every anatomy change it's been through (List rows → 3-icon row →
    /// this). `primaryButtonLabelLineHeight`/`linkLineHeight` are `@ScaledMetric` at the
    /// call site (`BrowseNavigationSheet`), so this formula is Dynamic-Type-aware end to
    /// end; the padding/spacing constants are plain values WE author and render directly
    /// (not guesses about system UIKit chrome), so none of them need an on-device-
    /// verification flag the way the removed `grabberAndInsetAllowance` did.
    static func actionColumnHeight(
        primaryButtonLabelLineHeight: CGFloat,
        primaryButtonVerticalPadding: CGFloat,
        columnSpacing: CGFloat,
        linkLineHeight: CGFloat,
        columnVerticalPadding: CGFloat
    ) -> CGFloat {
        let primaryButtonHeight = primaryButtonLabelLineHeight + (primaryButtonVerticalPadding * 2)
        return primaryButtonHeight + columnSpacing + linkLineHeight + (columnVerticalPadding * 2)
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
/// — and a system sheet's content is laid out against the FULL `.large`-sized container
/// regardless of which detent is *currently selected* (the detent only crops what's
/// exposed) — see `BrowseSheetDetentMath.peekHeight`'s doc comment for the same fact
/// underpinning the peek-clamp fix. So the moment the user is at `.large`, measuring the
/// whole `searchArea` view's geometry reports something close to the full container
/// height, not "the search field alone" — corrupting `peekHeight`/`mediumHeight` for
/// however long that inflated value is live, exactly the `List`-greedy-sizing trap
/// `actionColumnHeight` was already built to avoid, reintroduced in a spot Stream A never
/// anticipated (Stream B's real content didn't exist yet).
///
/// The fix: `BrowseSearchAreaView.searchField` (the one node that's ALWAYS visible,
/// regardless of detent) reports its own intrinsic height directly via this
/// `PreferenceKey`, which bubbles up through the view tree to `BrowseNavigationSheet.body`
/// unaffected by whatever large-detent-only content (`List`, place-state card, error
/// banner) happens to be mounted alongside it. This is the textbook use case for
/// `PreferenceKey` — communicating a value up an arbitrary intermediate view hierarchy that
/// the ancestor (`BrowseNavigationSheet`, generic over `SearchArea: View`) has no structural
/// knowledge of. No `List` is ever measured by this mechanism; `actionColumnHeight`'s own
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
/// **Public interface Stream B/C build against:**
///   - `searchArea`: a `@ViewBuilder` slot for the sheet's persistent top row. Mounts
///     `BrowseSearchAreaView`, which now also owns the trailing-edge Settings gear (§0f
///     Ruling 1) — this container has no part in that wiring; `ContentView` passes
///     `onSettingsTapped` straight into `BrowseSearchAreaView`'s own initializer. The
///     peek/medium detent math does NOT measure this slot's overall geometry (QA C1 fix —
///     see `BrowseSheetSearchAreaHeightPreferenceKey`'s doc comment): `BrowseSearchAreaView`'s
///     own always-visible `searchField` node reports its intrinsic height directly via that
///     preference key, so the large-detent-only content (recents/suggestions/place state/
///     error banner) mounted alongside it can never corrupt `peekHeight`/`mediumHeight`,
///     no matter how tall a `List` inside it gets asked to lay out.
///   - `onCruiseTapped` / `onParkingGuideTapped`: the action column's two row actions.
///     `ContentView` wires these to `enterCruiseMode()` (AC-18 — no intermediate menu) and
///     `activeSheet = .parkingGuide` respectively. (Settings is no longer part of this
///     container's own action content — see `searchArea` above.)
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
    let onCruiseTapped: () -> Void
    let onParkingGuideTapped: () -> Void
    let onPeekHeightChange: (CGFloat) -> Void
    let onMediumHeightChange: (CGFloat) -> Void

    init(
        @ViewBuilder searchArea: () -> SearchArea,
        onCruiseTapped: @escaping () -> Void,
        onParkingGuideTapped: @escaping () -> Void,
        onPeekHeightChange: @escaping (CGFloat) -> Void,
        onMediumHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.searchArea = searchArea()
        self.onCruiseTapped = onCruiseTapped
        self.onParkingGuideTapped = onParkingGuideTapped
        self.onPeekHeightChange = onPeekHeightChange
        self.onMediumHeightChange = onMediumHeightChange
    }

    // MARK: Measured content heights

    @State private var searchAreaHeight: CGFloat = 0

    /// Dynamic-Type-responsive line height for the primary "Find a Spot" button's label,
    /// via `@ScaledMetric` rather than `GeometryReader`/`.onGeometryChange` on
    /// `actionColumn` itself. Unlike the `List` this hierarchy replaced (§0e/§0f), a plain
    /// `VStack` of a `Button` and a `Text` is NOT a greedy, UIKit-bridged container — left
    /// unconstrained it would report its true intrinsic size, not "however much space the
    /// parent offers." Measuring it directly would therefore actually be safe here. This
    /// still derives the height from `@ScaledMetric` constants instead, matching the same
    /// "compute from values we control, don't add a second geometry-measurement mechanism"
    /// discipline the rest of this file uses (see `BrowseSheetDetentMath.actionColumnHeight`'s
    /// doc comment) — one fewer moving part for a change that's purely about anatomy, not
    /// about solving a new sizing problem.
    @ScaledMetric(relativeTo: .headline) private var primaryButtonLabelLineHeight: CGFloat = 22

    /// Dynamic-Type-responsive line height for the "New to parking?" tertiary link.
    @ScaledMetric(relativeTo: .subheadline) private var linkLineHeight: CGFloat = 18

    /// Vertical padding inside the primary button, matching the "Go" button's own
    /// `.padding(.vertical, 14)` (`BrowseSearchAreaView.placeState`) for visual rhythm
    /// between the two full-width primary actions a user encounters in this sheet.
    private let primaryButtonVerticalPadding: CGFloat = 14

    /// Gap between the primary button and the tertiary link beneath it.
    private let actionColumnSpacing: CGFloat = 10

    /// Top/bottom padding around the whole action column, matching
    /// `BrowseSearchAreaView.searchField`'s own `.padding(.vertical, 12)` for visual rhythm
    /// with the row above it.
    private let actionColumnVerticalPadding: CGFloat = 12

    /// Primary-button height + spacing + link height + top/bottom padding — see
    /// `BrowseSheetDetentMath.actionColumnHeight`'s doc comment for the full derivation.
    private var actionColumnHeight: CGFloat {
        BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: primaryButtonLabelLineHeight,
            primaryButtonVerticalPadding: primaryButtonVerticalPadding,
            columnSpacing: actionColumnSpacing,
            linkLineHeight: linkLineHeight,
            columnVerticalPadding: actionColumnVerticalPadding
        )
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            searchArea

            // Fixed-height spacer, NOT `Spacer()` — a greedy `Spacer()` here would expand
            // to fill the sheet's full `.large`-sized layout pass (this file's content is
            // laid out at full size regardless of the currently-selected detent — see
            // `BrowseSheetDetentMath.peekHeight`'s doc comment) and push `actionColumn` to
            // the BOTTOM of a near-screen-height container instead of directly beneath
            // `searchArea`. `Color.clear.frame(height:)` has a fixed intrinsic size, so it
            // sits exactly where `BrowseSheetDetentMath.interSectionGutter` says it should.
            Color.clear
                .frame(height: BrowseSheetDetentMath.interSectionGutter)

            actionColumn
                .frame(height: actionColumnHeight)
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
        // changes too. `actionColumnHeight` is computed (not measured via geometry), so
        // it's covered by watching its two `@ScaledMetric` inputs instead.
        //
        // FT-20 Stream C bugfix (QA live-smoke, two-bug report): every one of these call
        // sites is guarded by `BrowseSheetDetentMath.isGenuineMeasurement` — see its doc
        // comment. `searchAreaHeight` resets to `0` every time this view remounts (any
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
        .onChange(of: primaryButtonLabelLineHeight) { _, _ in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
        .onChange(of: linkLineHeight) { _, _ in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
        .onAppear {
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
    }

    // MARK: - §0f Ruling 1: the rebuilt medium-detent action column

    /// One prominent primary button ("Find a Spot") + one quiet tertiary text link ("New to
    /// parking?"). Replaces the horizontal 3-icon row (§0e Ruling 1), which itself replaced
    /// design-review finding S1's `List` rows.
    ///
    /// ⚠️ This is Kevin's THIRD live-smoke ruling on this hierarchy (spec §0f,
    /// 2026-08-21) — do not "restore" either prior anatomy citing S1 or §0e. The finding:
    /// *"I think cruise is more important than settings or parking 101."* Three equal
    /// controls (icon row) or three equal rows (`List`) both assert Settings/Cruise/Parking
    /// 101 matter equally; they don't. Apple Maps itself has no in-app settings button —
    /// the only entry point is a small avatar in the search field's trailing edge. Settings
    /// is demoted out of this column entirely (see `BrowseSearchAreaView.searchField`);
    /// what remains here is exactly one primary action and one subordinate link.
    ///
    /// **"Cruise" → "Find a Spot" (§0f Ruling 2, label only):** Kevin revisited his own
    /// §3.1 terminology ruling after seeing it running — "Cruise" names a mode, not a job,
    /// and nothing in the word says parking. This is a LABEL change: `onCruiseTapped` still
    /// calls the exact same `enterCruiseMode()` entry path (`ContentView.swift`), and
    /// internal identifiers (`enterCruiseMode()`, `driveModeStyle`, `.cruise`, and this
    /// file's own `onCruiseTapped` closure name) are deliberately left alone — renaming
    /// them would be churn with no user-facing benefit. Build 18's patrol mode inherits
    /// this "find a spot" vocabulary (a note, not new scope here).
    private var actionColumn: some View {
        VStack(spacing: actionColumnSpacing) {
            Button(action: onCruiseTapped) {
                Label("Find a Spot", systemImage: "car.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, primaryButtonVerticalPadding)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Find a Spot")
            .accessibilityHint("Starts Drive Mode with no destination, to find parking nearby.")

            Button(action: onParkingGuideTapped) {
                Text("New to parking?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New to parking?")
            .accessibilityHint("Opens the beginner's guide to reading NYC parking signs.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, actionColumnVerticalPadding)
    }

    // MARK: - Height reporting

    private func reportHeights() {
        onPeekHeightChange(BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight))
        onMediumHeightChange(
            BrowseSheetDetentMath.mediumHeight(
                searchAreaHeight: searchAreaHeight,
                actionColumnHeight: actionColumnHeight,
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
    /// confirm at AX3 that the medium detent still reads as "search + Find a Spot + New to
    /// parking?", not a clipped layout, before sign-off.
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

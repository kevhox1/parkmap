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
//      on `searchArea` below) + the medium-detent 3-item action row (Settings / Cruise /
//      Parking 101).
//
//      ⚠️ Kevin's live-smoke Ruling 1 (spec §0e, 2026-08-21) OVERRIDES design-review
//      finding S1. S1 originally called for `List` rows matching `recentDestinationsList`'s
//      anatomy verbatim. On-device, that anatomy clipped the 3rd row at medium (`.insetGrouped`
//      needs ~190-210pt of real section chrome for 3 rows; the old budget was only 156pt)
//      AND its SF Symbol for "Cruise" didn't resolve (see `actionList`'s doc comment below).
//      Kevin's ruling replaces it with three circular icon buttons + label beneath, evenly
//      distributed — the Apple Maps action-row pattern. Do NOT "restore" the `List` citing
//      S1; the live-smoke ruling is the authority here, per spec §0e's own framing.
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

    /// Extra vertical space, beyond `searchAreaHeight`, allotted to the SYSTEM's own
    /// grab-indicator region — the chrome `.presentationDragIndicator(.visible)` renders
    /// ABOVE this file's SwiftUI content tree, entirely outside it.
    ///
    /// ⚠️ ROOT CAUSE of the "peek reveals the first action row" live-smoke bug (found
    /// 2026-08-21) and the FIX, recorded here rather than just silently changed:
    ///
    /// This constant used to be `24` and its doc comment claimed it covered TWO things —
    /// "the grabber affordance... plus the content's own top inset." That second thing was
    /// a double-count. `BrowseSearchAreaView.searchField`'s height-reporting
    /// `GeometryReader` (`BrowseSearchAreaView.swift:253-260`) is attached AFTER
    /// `.padding(.vertical, 12)` (`BrowseSearchAreaView.swift:244`), so `searchAreaHeight`
    /// ALREADY includes that top inset — it's the search bar's own true rendered height,
    /// padding and all. Adding a *second*, separate allowance for "the content's own top
    /// inset" on top of a measurement that already contains it inflated `peekHeight`
    /// (`searchAreaHeight + grabberAndInsetAllowance`, below) past what was needed to show
    /// just the grabber + search field. Since this sheet's content is laid out against the
    /// full `.large`-sized container regardless of detent (`body`'s `VStack(spacing: 0) {
    /// searchArea; actionList }`), that excess budget exposed a sliver of `actionList` —
    /// exactly the bug Kevin's live smoke observed.
    ///
    /// Fix: `12` = the old `24` minus the `12`pt top-inset component that's already
    /// counted inside `searchAreaHeight` (matches `searchField`'s own explicit
    /// `.padding(.vertical, 12)` exactly), leaving only the system grabber's own footprint.
    ///
    /// ⚠️ [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK — the remaining `12` is still a
    /// GUESS, not a measured constant]. The double-count is now removed by construction,
    /// but the true size of the system's own grab-indicator region is still not something
    /// this Linux VPS can read off rendered UIKit chrome. Kevin's on-device smoke should
    /// confirm peek shows exactly the search field and nothing else, at default Dynamic
    /// Type, before this remaining `12` is trusted.
    static let grabberAndInsetAllowance: CGFloat = 12

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

    /// Medium height = peek height + the measured height of the 3-item action row
    /// ("search + exactly three rows and no more" — OQ-3), clamped to `maxAllowedHeight`
    /// so a large Dynamic Type size can never drive this custom detent up to, or past,
    /// `.large` (design-review finding B2). Above that ceiling `.large` is what the user
    /// gets instead — the action row itself doesn't scroll (it's a fixed horizontal row of
    /// 3 icon buttons, not a `List`), but `.large`'s own content area comfortably fits it
    /// even at extreme Dynamic Type sizes.
    ///
    /// `actionListHeight` is a generic name for "the medium-detent action content's height,
    /// whatever its anatomy" — unchanged as a parameter label across Kevin's live-smoke
    /// Ruling 1 (List rows → horizontal icon row) specifically so this pure function, and
    /// the tests pinning it, didn't need to churn for a rendering-only change. See
    /// `actionRowHeight(iconDiameter:iconLabelSpacing:labelLineHeight:verticalPadding:)`
    /// below for how the CALLER (`BrowseNavigationSheet.actionListHeight`) now computes the
    /// value passed in here.
    static func mediumHeight(
        searchAreaHeight: CGFloat,
        actionListHeight: CGFloat,
        maxAllowedHeight: CGFloat
    ) -> CGFloat {
        let raw = peekHeight(searchAreaHeight: searchAreaHeight) + actionListHeight
        return min(raw, maxAllowedHeight)
    }

    /// Height of the horizontal 3-icon action row (Kevin's live-smoke Ruling 1, spec §0e —
    /// OVERRIDES design-review finding S1's `List`-row anatomy): icon diameter + the gap
    /// between icon and label + the label's own line height + top/bottom padding.
    ///
    /// Pure and UIKit-free, mirroring `peekHeight`/`mediumHeight` above and the "derive,
    /// don't measure a greedy container" discipline `actionListHeight` already used for the
    /// deleted `List` (see `BrowseSheetSearchAreaHeightPreferenceKey`'s doc comment for why
    /// measuring is unsafe here) — an `HStack` of `Button`s isn't greedy the way `List` is,
    /// but this keeps the same battle-tested "compute from values we control" approach
    /// rather than introducing a second geometry-measurement mechanism for a rendering-only
    /// change. `iconDiameter`/`labelLineHeight` are `@ScaledMetric` at the call site
    /// (`BrowseNavigationSheet`), so this formula is Dynamic-Type-aware end to end;
    /// `iconLabelSpacing`/`verticalPadding` are plain constants WE author and render
    /// directly (not guesses about system UIKit chrome), so no on-device-verification flag
    /// is needed for them the way `grabberAndInsetAllowance` above needs one.
    static func actionRowHeight(
        iconDiameter: CGFloat,
        iconLabelSpacing: CGFloat,
        labelLineHeight: CGFloat,
        verticalPadding: CGFloat
    ) -> CGFloat {
        iconDiameter + iconLabelSpacing + labelLineHeight + (verticalPadding * 2)
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
/// exposed) — see `BrowseNavigationSheet.actionIconDiameter`'s doc comment for the same
/// fact applied to `actionList`. So the moment the user is at `.large`, measuring the
/// whole `searchArea` view's geometry reports something close to the full container
/// height, not "the search field alone" — corrupting `peekHeight`/`mediumHeight` for
/// however long that inflated value is live, exactly the `List`-greedy-sizing trap
/// `actionListHeight` was already built to avoid, reintroduced in a spot Stream A never
/// anticipated (Stream B's real content didn't exist yet).
///
/// The fix: `BrowseSearchAreaView.searchField` (the one node that's ALWAYS visible,
/// regardless of detent) reports its own intrinsic height directly via this
/// `PreferenceKey`, which bubbles up through the view tree to `BrowseNavigationSheet.body`
/// unaffected by whatever large-detent-only content (`List`, place-state card, error
/// banner) happens to be mounted alongside it. This is the textbook use case for
/// `PreferenceKey` — communicating a value up an arbitrary intermediate view hierarchy that
/// the ancestor (`BrowseNavigationSheet`, generic over `SearchArea: View`) has no structural
/// knowledge of. No `List` is ever measured by this mechanism; `actionListHeight`'s own
/// `@ScaledMetric`-derived "constrain, don't measure" technique (now via `actionIconDiameter`/
/// `actionLabelLineHeight`, Kevin's live-smoke Ruling 1) is untouched below.
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

    /// Dynamic-Type-responsive diameter for each circular icon button, via `@ScaledMetric`
    /// rather than `GeometryReader`/`.onGeometryChange` on `actionList` itself.
    ///
    /// Unlike the `List` this replaces (Kevin's live-smoke Ruling 1, spec §0e — see
    /// `actionList`'s own doc comment), an `HStack` of plain `Button`s is NOT a greedy,
    /// UIKit-bridged container — left unconstrained it would report its true intrinsic
    /// size, not "however much space the parent offers." Measuring it directly would
    /// therefore actually be safe here. This still derives the height from `@ScaledMetric`
    /// constants instead, matching the same "compute from values we control, don't add a
    /// second geometry-measurement mechanism" discipline the rest of this file uses (see
    /// `BrowseSheetDetentMath.actionRowHeight`'s doc comment) — one fewer moving part for a
    /// change that's purely about anatomy, not about solving a new sizing problem.
    @ScaledMetric(relativeTo: .body) private var actionIconDiameter: CGFloat = 44

    /// Dynamic-Type-responsive line height for each icon's label (`.caption`-styled text
    /// beneath the icon circle).
    @ScaledMetric(relativeTo: .caption) private var actionLabelLineHeight: CGFloat = 16

    /// Gap between an icon circle and its label — a value this view authors and renders
    /// directly (not an estimate of external UIKit chrome), so it needs no on-device
    /// verification flag the way `BrowseSheetDetentMath.grabberAndInsetAllowance` does.
    private let actionRowIconLabelSpacing: CGFloat = 6

    /// Top/bottom padding around the action row, matching `BrowseSearchAreaView.searchField`'s
    /// own `.padding(.vertical, 12)` for visual rhythm with the row above it.
    private let actionRowVerticalPadding: CGFloat = 12

    /// Icon diameter + icon-label spacing + label line height + top/bottom padding — see
    /// `BrowseSheetDetentMath.actionRowHeight`'s doc comment for the full derivation.
    private var actionListHeight: CGFloat {
        BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: actionIconDiameter,
            iconLabelSpacing: actionRowIconLabelSpacing,
            labelLineHeight: actionLabelLineHeight,
            verticalPadding: actionRowVerticalPadding
        )
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
        // covered by watching its two `@ScaledMetric` inputs instead.
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
        .onChange(of: actionIconDiameter) { _, _ in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
        .onChange(of: actionLabelLineHeight) { _, _ in
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
        .onAppear {
            guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: searchAreaHeight) else { return }
            reportHeights()
        }
    }

    // MARK: - Kevin's live-smoke Ruling 1: medium-detent 3-icon action row

    /// Settings · Cruise · Parking 101 — three circular icon buttons, evenly distributed
    /// across the row, with a label beneath each (the Apple Maps action-row pattern).
    ///
    /// ⚠️ This is Kevin's live-smoke Ruling 1 (spec §0e, 2026-08-21) and it OVERRIDES
    /// design-review finding S1, which originally specified `List` rows. Do not "restore"
    /// the `List` citing S1 — see this file's top-of-file doc comment. Two independent
    /// on-device findings drove the ruling:
    ///   1. At medium, the 3rd `List` row (Parking 101) was clipped — `.insetGrouped`
    ///      needs roughly 190-210pt of real section chrome for 3 rows, but the old budget
    ///      (`singleActionRowHeight * 3 + listSectionChromeAllowance`) was only 156pt.
    ///      Deleting `List` removes that chrome question entirely — `actionListHeight` is
    ///      now derived purely from what this file actually renders (see
    ///      `BrowseSheetDetentMath.actionRowHeight`), no more List-section guesswork.
    ///   2. The `List` anatomy's "Cruise" row used `car.front.waves.right.fill`, which does
    ///      NOT exist in Apple's SF Symbols catalog (verified against the SF Symbols name
    ///      list — the real `car.front.waves...` family is `.up`/`.up.fill`/`.down`/
    ///      `.down.fill`/`.left.and.right.and.up`/`.left.and.right.and.up.fill`; there is
    ///      no `.right.fill` variant). Kevin's screenshot showed exactly the signature of
    ///      an unresolved SF Symbol (blank icon, misaligned label) — likely broken since
    ///      the symbol was first reused from the deleted `driveEntryButton`'s menu, where
    ///      nobody visually noticed. Substituted `car.fill` — already used elsewhere in
    ///      this app (`ContentView.recenterButtonStack`'s "Find my car" button) and
    ///      confirmed to resolve. In this horizontal layout the icon IS the button, so an
    ///      unresolved symbol is far more visible than it was as a small leading glyph in a
    ///      `List` row.
    ///
    /// Order matches the spec's own canonical listing (§0's OQ-3 ruling, §2, §4.2, AC-15).
    /// Height is constrained by the caller (`body`, above) to `actionListHeight`.
    private var actionList: some View {
        HStack(spacing: 0) {
            actionButton(
                systemImage: "gearshape.fill",
                label: "Settings",
                accessibilityLabel: "Open settings",
                action: onSettingsTapped
            )

            // "Cruise" (not "Drive Mode", not a menu) — Kevin's terminology ruling (spec
            // §3.1): entering Drive Mode WITH a destination is the search→place→Go path;
            // this button means driving with NO destination. See this view's doc comment
            // above for why the icon is `car.fill`, not the spec's originally-named
            // `car.front.waves.right.fill` (confirmed not a real SF Symbol).
            actionButton(
                systemImage: "car.fill",
                label: "Cruise",
                accessibilityLabel: "Cruise",
                accessibilityHint: "Starts Drive Mode with no destination, to find parking nearby.",
                action: onCruiseTapped
            )

            actionButton(
                systemImage: "questionmark.circle.fill",
                label: "Parking 101",
                accessibilityLabel: "Parking 101 guide",
                accessibilityHint: "Opens the beginner's guide to reading NYC parking signs.",
                action: onParkingGuideTapped
            )
        }
        .padding(.vertical, actionRowVerticalPadding)
    }

    /// One circular icon + label button inside `actionList`. `.frame(maxWidth: .infinity)`
    /// on each button is what evenly distributes all three across the row's full width;
    /// `.buttonStyle(.plain)` keeps this file's own `VStack` layout (icon circle, then
    /// label) from being reinterpreted as default button chrome.
    private func actionButton(
        systemImage: String,
        label: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: actionRowIconLabelSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: actionIconDiameter * 0.4, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: actionIconDiameter, height: actionIconDiameter)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
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

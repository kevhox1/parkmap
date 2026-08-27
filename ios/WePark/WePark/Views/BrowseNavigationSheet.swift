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
//    - The search-field height plumbing (`searchAreaBuilder`'s `(CGFloat) -> Void`
//      parameter, `handleSearchFieldHeightChange` below): the QA §0d C1 fix — how the
//      search field's own height reaches this container without ever measuring the
//      large-detent-only `List` content mounted alongside it. PR #87 round 5 replaced the
//      original `PreferenceKey`-based mechanism with `.onGeometryChange` after a real
//      on-device readout proved the `PreferenceKey` never delivered a non-zero value — see
//      the doc comment where `BrowseSheetSearchAreaHeightPreferenceKey` used to live, just
//      below `BrowseSheetDetentKind`, for the full root-cause writeup.
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
    ///
    /// ⚠️ ROUND 4 UPDATE (2026-08-21, PR #87 4th pass): the clamp above was necessary but
    /// NOT sufficient. Kevin's next screenshot showed the OPPOSITE failure — at peek there
    /// was no visible search field AT ALL, just the grabber and a clipped sliver of the
    /// "Find a Spot" button. Root cause, found by inspection (no device available): this
    /// file's `body` VStack lays out THREE children — `searchArea` (intrinsic size, no
    /// frame), `interSectionGutter` (a HARD `.frame(height:)`, fully fixed), and
    /// `actionColumn` (also a HARD `.frame(height:)`, fully fixed). When the container
    /// offers less total height than the two FIXED children alone need (gutter + full
    /// actionColumn, ~110pt — bigger than any realistic peek height), SwiftUI's layout
    /// negotiation honors the fixed-size children's exact request FIRST and gives the one
    /// flexible/intrinsic child (`searchArea`) whatever's left over — which, once the fixed
    /// siblings already exceed the offered height, is nothing. `searchArea` was being
    /// squeezed to near-zero, and the fixed `actionColumn` below it was still claiming (and
    /// rendering into) its full 100+pt regardless, with the outer sheet simply clipping the
    /// overflow from the bottom. That is why NO peek-height arithmetic could ever have
    /// fixed this: the bug wasn't in what number `peekHeight` computed, it was that
    /// `actionColumn` and its gutter were unconditionally IN THE LAYOUT TREE at peek,
    /// competing with `searchArea` for space it needed and losing. The real fix is in
    /// `BrowseNavigationSheet.body` — `actionColumn`/the gutter are now only mounted when
    /// `BrowseSheetDetentKind.showsActionContent` is true (i.e. never at `.peek`), which
    /// both (a) makes the action content structurally impossible to render at peek
    /// (Task 1's invariant) and (b) frees the space `searchArea` needs to render at its
    /// real, full height (Task 2's fix) — the two problems shared one cause.

    /// Vertical gap, authored and rendered directly by this file (not a guess about
    /// external system chrome), between the search area and the action content in
    /// `BrowseNavigationSheet.body`'s `VStack`. Only actually occupies space when the
    /// action content is mounted (`BrowseSheetDetentKind.showsActionContent`) — see the
    /// round-4 doc comment above. Gives the peek/medium boundary genuine visual breathing
    /// room and — more importantly — a real, testable margin the `peekHeight` clamp below
    /// can rely on.
    static let interSectionGutter: CGFloat = 8

    /// Extra headroom ADDED on top of the measured search-area height when computing the
    /// peek candidate (see `peekHeight` below), so the full search field — not a
    /// bottom-cropped sliver of it — sits comfortably inside the peek window with a couple
    /// points to spare. This is safe to be generous with now, unlike the removed
    /// `grabberAndInsetAllowance`: `peekHeight`'s hard clamp against
    /// `actionContentTopOffset` still applies (belt-and-braces), AND — as of round 4 —
    /// `actionColumn` is no longer even mounted at peek, so there is nothing for a generous
    /// peek height to reveal even if this constant is bigger than it needs to be.
    ///
    /// Deliberately kept SMALLER than `interSectionGutter` (rather than equal to it), so
    /// `minimumPeekHeight`'s floor stays reachable for genuinely small measured inputs
    /// instead of the ceiling clamp always winning outright — see `peekHeight`'s own doc
    /// comment for the three-way priority ordering (floor / candidate / ceiling) this value
    /// participates in.
    static let peekBreathingRoom: CGFloat = 4

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

    /// Peek height: derived from the measured search-area height PLUS `peekBreathingRoom`
    /// (round 4 — see that constant's doc comment for why this flipped from subtractive to
    /// additive), floored at `minimumPeekHeight` for a realistic 44pt-plus-grabber touch
    /// target, but HARD-CLAMPED so it can never reach `actionContentTopOffset` — i.e. it is
    /// structurally impossible for peek's presented HEIGHT to reach into the action
    /// content's region, regardless of what the system's own (unmeasurable, from this
    /// environment) grab-indicator chrome costs on top of the presented `.height(_:)`
    /// value. This clamp is now BELT-AND-BRACES, not the only line of defense: as of round
    /// 4, `BrowseNavigationSheet.body` also never MOUNTS `actionColumn` at peek at all (see
    /// `BrowseSheetDetentKind.showsActionContent`), so there is nothing in that region to
    /// reveal even if this clamp were somehow bypassed. See `BrowseSheetDetentMath`'s
    /// removed-constant doc comment (above `interSectionGutter`) for the two-live-smoke-
    /// round history this construction replaces, and its round-4 addendum for why a pure
    /// height-arithmetic fix could never have been sufficient on its own.
    ///
    /// Priority ordering, stated explicitly because the two goals can conflict at
    /// pathologically small inputs: "never reach the action content's region" wins over
    /// "meet the nominal `minimumPeekHeight` floor." This is deliberate and safe in
    /// practice — `searchAreaHeight` values small enough to trigger the clamp (roughly
    /// ≤56pt) are not reachable from a real rendered search field (its own fixed
    /// `.padding(10)` + `.padding(.vertical, 12)`, `BrowseSearchAreaView.swift:241–244`,
    /// put its realistic minimum well above that), and the true degenerate case —
    /// `searchAreaHeight == 0`, the unmeasured `@State` default — never reaches a live
    /// `.presentationDetents` call in the first place: `BrowseNavigationSheet`'s own
    /// `isGenuineMeasurement` guard refuses to report it, and `ContentView`'s initial
    /// placeholder is hardcoded straight to `minimumPeekHeight`, bypassing this function
    /// entirely (`ContentView.swift`'s `browseSheetPeekHeight` `@State` default).
    static func peekHeight(searchAreaHeight: CGFloat) -> CGFloat {
        let candidate = max(minimumPeekHeight, searchAreaHeight + peekBreathingRoom)
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

// MARK: - Search-field height measurement (PR #87 round 5 — see below for why this is no
// longer a `PreferenceKey`)

/// ⚠️ REMOVED 2026-08-22 (PR #87 round 5) — `BrowseSheetSearchAreaHeightPreferenceKey`, a
/// `PreferenceKey` this file used to define here. Root-cause note kept in place rather than
/// silently deleted, matching this file's own convention for `BrowseSheetDetentMath`'s
/// removed `grabberAndInsetAllowance` — an agent grepping for "why did the search-height
/// measurement change" needs the full history, not just a diff.
///
/// **What it was for (still true — read `BrowseSearchAreaView.searchField`'s own doc
/// comment for the current version of this reasoning):** the height driving
/// `BrowseSheetDetentMath.peekHeight`/`.mediumHeight` must come from ONLY the sheet's
/// always-visible top row (the search field), never from `searchArea`'s full rendered
/// content — `BrowseSearchAreaView` can mount a `List` (recents/suggestions) inside
/// `searchArea` at `.large`, and a system sheet's content is laid out against the FULL
/// `.large`-sized container regardless of which detent is *currently selected* (the detent
/// only crops what's exposed) — see `BrowseSheetDetentMath.peekHeight`'s doc comment for the
/// same fact underpinning the peek-clamp fix. Measuring the whole `searchArea` slot would
/// report something close to the full container height at `.large`, corrupting
/// `peekHeight`/`mediumHeight` — the exact `List`-greedy-sizing trap `actionColumnHeight` was
/// already built to avoid, reintroduced in a spot Stream A never anticipated. **This
/// constraint is unchanged by round 5** — the replacement mechanism below still measures
/// `searchField` alone, never the whole slot.
///
/// **Why it was removed:** Kevin's `#if DEBUG` readout (requested explicitly for this
/// purpose after three rounds of guessed height constants) showed `searchH: 0.0` on a real
/// device, at the medium detent, WITH the search field visibly rendered at full size on
/// screen — i.e. the field genuinely had non-zero height, and the measurement reported zero
/// anyway. Every downstream symptom across rounds 1–4 (peek snapping to medium at cold
/// launch, the "three buttons are peaking" bug, the search field looking squeezed) was
/// height arithmetic performed on an input that had never once been real.
///
/// **Root cause, confirmed against `PreferenceKey`'s documented `reduce` contract, not
/// guessed:** SwiftUI calls a `PreferenceKey`'s `reduce(value:nextValue:)` for EVERY sibling
/// branch in the observed subtree during layout, including branches that never call
/// `.preference(key:value:)` explicitly — those branches still contribute the key's
/// `defaultValue` (`0` here) to the merge. This file's `reduce` was `value = nextValue()`
/// ("last write wins"), which is exactly wrong for that contract: whichever branch is
/// visited LAST in the merge — real reporter or not — wins outright, and a defaultValue
/// contribution from a later branch silently overwrites a real value from an earlier one.
/// (This is a documented, general SwiftUI `PreferenceKey` pitfall — Apple's own guidance is
/// that a `reduce` implementation should make the key's `defaultValue` the reduce operator's
/// IDENTITY element, e.g. `value = max(value, nextValue())` for a non-negative measurement
/// like this one, so merging in a defaultValue from an unrelated branch can never clobber a
/// real one.)
///
/// The `#if DEBUG` `.overlay(alignment:) { debugReadout }` this file added in round 4 to get
/// the readout that found this bug is itself exactly this kind of branch: it renders no
/// `.preference` of its own, so it silently contributes `defaultValue` (0) to every `reduce`
/// pass once attached — chained BEFORE `.onPreferenceChange` in `body`, so its 0 could
/// overwrite `searchField`'s real report on the very passes where SwiftUI happened to visit
/// it last. (`BrowseSheetSearchAreaHeightPreferenceKeyTests`' `testReduce_withZeroNextValue_
/// producesZero` / `testReduce_withMultipleContributingProbes_takesTheLastOne`, previously in
/// `FT20StreamCTests.swift`, pinned this exact "last write wins" behavior as INTENTIONAL — an
/// earlier round's understandable but incorrect read of the bug report, since `reduce`
/// invoked directly with hand-fed values can't reproduce a bug that's about HOW MANY TIMES
/// and in WHAT ORDER SwiftUI itself calls `reduce` across the live tree. Those two tests were
/// removed along with the `PreferenceKey` rather than "fixed," since there is no `reduce` to
/// test anymore — see `FT20StreamCTests.swift`'s own note where that class used to live.)
///
/// **The fix — not a `reduce` patch, a mechanism swap:** `searchField` now reports its height
/// via `.onGeometryChange(for:of:action:)` (iOS 17+, this project's deployment target)
/// straight to a caller-supplied closure — see `BrowseSearchAreaView.searchField`'s doc
/// comment and `handleSearchFieldHeightChange` below. `.onGeometryChange` reads one named
/// view's own geometry directly; there is no cross-tree aggregation step at all, so this
/// entire bug class — not just this instance of it — is structurally impossible with this
/// API, including against any FUTURE sibling this file's actively-iterated `body` grows
/// (another debug overlay, another conditional branch). A `reduce(value:nextValue:) { value =
/// max(value, nextValue()) }` patch would also have fixed today's specific symptom, but
/// remains a class of bug this file would need to re-derive correctly every time its view
/// tree shape changes; `.onGeometryChange` removes the class outright, which is why it was
/// chosen over the smaller patch.

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
    // Community 2.0 Phase 1 (S4, `docs/community-2.0-reconciliation-spec.md` §1 delta table,
    // §3 Phase 1): `.large` is this ladder's pre-existing THIRD rung — it was already a live,
    // reachable member of `.browseNav`'s `.presentationDetents` array before this session (see
    // `ContentView.browseNavigationSheetContent`), used today only to give
    // `BrowseSearchAreaView`'s recents/suggestions/error-banner content room to render at full
    // height. The spec calls for a "third, taller state" for the crew feed — mapping that onto
    // this ALREADY-EXISTING `.large` case (rather than inventing a fourth detent height) is
    // this session's explicit, minimal-diff choice for the highest-regression-risk file in the
    // spec: zero new detent math, zero new classification logic, zero new
    // `.presentationDetents` array entry. See `BrowseNavigationSheet.body`'s `crewFeed` slot
    // doc comment for where the new content actually mounts.
    case peek, medium, large

    /// FT-20 Stream C, PR #87 round 4: whether `BrowseNavigationSheet`'s medium-detent
    /// action content (the "Find a Spot" button + "New to parking?" link) should be MOUNTED
    /// in the view tree at all for this detent kind — `false` only at `.peek`. This is a
    /// conditional-rendering gate, not a visual/opacity one: at peek the action content is
    /// not merely invisible, it doesn't exist in the layout tree, so (a) it is structurally
    /// impossible for it to render regardless of any height-math error (three prior
    /// arithmetic-only attempts each moved the bug instead of killing it — see
    /// `BrowseSheetDetentMath`'s round-4 doc comment), and (b) the search field is no
    /// longer squeezed for layout space by fixed-height siblings it doesn't need to share
    /// space with at peek in the first place. See `BrowseNavigationSheet.body`'s own doc
    /// comment for the full reasoning and the layout-squeeze root cause this also fixes.
    var showsActionContent: Bool { self != .peek }

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
///   - `searchArea`: a `@ViewBuilder` slot for the sheet's persistent top row, called with
///     this container's own `handleSearchFieldHeightChange` so the built view can report its
///     search field's live height back up (PR #87 round 5 — see below). Mounts
///     `BrowseSearchAreaView`, which now also owns the trailing-edge Settings gear (§0f
///     Ruling 1) — this container has no part in that wiring; `ContentView` passes
///     `onSettingsTapped` straight into `BrowseSearchAreaView`'s own initializer. The
///     peek/medium detent math does NOT measure this slot's overall geometry (QA C1 fix —
///     see the doc comment where `BrowseSheetSearchAreaHeightPreferenceKey` used to live, just
///     below `BrowseSheetDetentKind`): `BrowseSearchAreaView`'s own always-visible
///     `searchField` node reports its intrinsic height directly via `.onGeometryChange`, so
///     the large-detent-only content (recents/suggestions/place state/error banner) mounted
///     alongside it can never corrupt `peekHeight`/`mediumHeight`, no matter how tall a
///     `List` inside it gets asked to lay out.
///   - `onCruiseTapped` / `onParkingGuideTapped`: the action column's two row actions.
///     `ContentView` wires these to `enterCruiseMode()` (AC-18 — no intermediate menu) and
///     `activeSheet = .parkingGuide` respectively. (Settings is no longer part of this
///     container's own action content — see `searchArea` above.)
///   - `onPeekHeightChange` / `onMediumHeightChange`: fire whenever the measured content
///     changes (initial layout, Dynamic Type change, etc.) with the two already-computed,
///     already-clamped detent heights. `ContentView` stores these into the `@State` it
///     feeds into `.presentationDetents([.height(peek), .height(medium), .large], ...)`.
///   - `detentKind`: (round 4, PR #87) the CURRENT `BrowseSheetDetentKind` selection —
///     `ContentView`'s own `browseSheetDetentKind` `@State`, read-only here. Drives whether
///     `actionColumn` is mounted at all (`BrowseSheetDetentKind.showsActionContent`) — see
///     `body`'s own doc comment for why this is a conditional-rendering gate, not a
///     `.presentationDetents` height problem.
///   - `crewFeed`: Community 2.0 Phase 1 (S4; QA pass 1 PR #94 Finding #2 fix) — a
///     `@ViewBuilder` slot CALLED ONLY when `detentKind == .large` **AND**
///     `AppConstants.communityEnabled` (see `body`'s mount-site doc comment for the full
///     reasoning). Defaults to `{ EmptyView() }` so every pre-existing call site (and any
///     future one that doesn't care about the crew feed) compiles unchanged — `CrewFeed`
///     infers to `EmptyView` when the parameter is omitted. The flag check lives on the
///     `if` itself (the MOUNT), not just inside the content the closure builds — QA's
///     finding: a child that resolves to `EmptyView()` is still a distinct `VStack` child
///     that claims a share of `.frame(maxHeight:)`'s layout split, so gating only the
///     closure's CONTENT (this file's original approach) was not sufficient to guarantee
///     AC-P1.3's "flag false = zero behavioral or visual change" — gating the `if` itself
///     is. `ContentView`'s own `if AppConstants.communityEnabled` guard inside its
///     `crewFeed:` closure is now a second, redundant-but-harmless line of defense.
struct BrowseNavigationSheet<SearchArea: View, CrewFeed: View>: View {

    // MARK: Public interface
    //
    // `searchAreaBuilder` stores the BUILDER closure, not an already-built view — a change
    // from the original Stream A/B/C shape (`let searchArea: SearchArea`, built once in
    // `init`), made in PR #87 round 5 specifically so the built view can be handed THIS
    // instance's own `handleSearchFieldHeightChange` as its height-reporting callback.
    //
    // That callback mutates `@State searchAreaHeight`, and `@State`'s storage is only
    // correctly connected to its persistent per-identity box once SwiftUI has "mounted" a
    // struct instance and is evaluating its `body` — NOT yet during that instance's own
    // `init()` (a well-known SwiftUI pitfall: `self` inside `init` is a freshly-constructed
    // value whose `@State` wrapper hasn't been grafted onto persistent storage yet). Building
    // `SearchArea` inside `init` — the old shape — worked fine when it only needed static
    // inputs, but would have captured a stale, disconnected `self` if it needed to reference
    // `handleSearchFieldHeightChange` there. Calling `searchAreaBuilder(...)` from `body`
    // instead (see `body` below) always sees the current render pass's live, correctly-wired
    // `self`. The `@ViewBuilder` attribute stays on the initializer's parameter (the same
    // pattern this codebase already uses for `FAQHelpView.swift:76`'s `@ViewBuilder content:
    // () -> some View`, now with a parameter of its own — the same shape `ForEach`'s own
    // `@ViewBuilder content: (Element) -> Content` uses), rather than on the stored property
    // directly, for the same "no toolchain to verify a stored-property `@ViewBuilder`" reason
    // as before.

    let searchAreaBuilder: (@escaping (CGFloat) -> Void) -> SearchArea
    let detentKind: BrowseSheetDetentKind
    let onCruiseTapped: () -> Void
    let onParkingGuideTapped: () -> Void
    let onPeekHeightChange: (CGFloat) -> Void
    let onMediumHeightChange: (CGFloat) -> Void

    /// Community 2.0 Phase 1 (S4) — see this struct's own doc comment for the full
    /// "why `.large`, why a builder, why the default" reasoning. Built (not stored
    /// pre-built) for the same `self`-liveness reason `searchAreaBuilder` is a builder —
    /// though unlike `searchArea` this closure takes no parameters, since the crew feed
    /// doesn't participate in this file's height-measurement plumbing (`.large` is a system
    /// detent with a fixed, container-derived height; nothing here needs to measure it).
    let crewFeedBuilder: () -> CrewFeed

    init(
        @ViewBuilder searchArea: @escaping (@escaping (CGFloat) -> Void) -> SearchArea,
        detentKind: BrowseSheetDetentKind,
        onCruiseTapped: @escaping () -> Void,
        onParkingGuideTapped: @escaping () -> Void,
        onPeekHeightChange: @escaping (CGFloat) -> Void,
        onMediumHeightChange: @escaping (CGFloat) -> Void,
        @ViewBuilder crewFeed: @escaping () -> CrewFeed = { EmptyView() }
    ) {
        self.searchAreaBuilder = searchArea
        self.detentKind = detentKind
        self.onCruiseTapped = onCruiseTapped
        self.onParkingGuideTapped = onParkingGuideTapped
        self.onPeekHeightChange = onPeekHeightChange
        self.onMediumHeightChange = onMediumHeightChange
        self.crewFeedBuilder = crewFeed
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

    /// ⚠️ PR #87 ROUND 4 (2026-08-21) — read this before touching peek/medium layout again.
    ///
    /// Three prior rounds tried to fix "peek reveals the action content" purely by tuning
    /// `BrowseSheetDetentMath.peekHeight`'s arithmetic (a guessed grabber allowance, then
    /// `24 → 12`, then a hard clamp against `actionContentTopOffset`). All three were
    /// locally correct and the bug survived every one — because `actionColumn` and its
    /// gutter were unconditionally IN THIS VStack regardless of detent, and a system
    /// `.sheet`'s custom `.height(_:)` detent is a genuine LAYOUT CONSTRAINT, not just a
    /// crop window: when the offered height is smaller than the sum of this stack's FIXED-
    /// size children (`interSectionGutter` + `actionColumn`, both hard `.frame(height:)`,
    /// together comfortably bigger than any realistic peek height), SwiftUI's layout
    /// negotiation satisfies those fixed children first and gives `searchArea` — the one
    /// child with no hard frame of its own — whatever's left over, which at peek was
    /// nothing. That is the root cause of BOTH symptoms Kevin's 4th screenshot showed at
    /// once: the search field disappearing (squeezed to ~0) AND the "Find a Spot" button
    /// still rendering, clipped (its fixed frame was honored regardless of the tiny offered
    /// height).
    ///
    /// The fix: `actionColumn`/the gutter are now only MOUNTED
    /// (`BrowseSheetDetentKind.showsActionContent`, i.e. never at `.peek`) — not merely
    /// hidden. This is a conditional-rendering gate, not an opacity one, deliberately:
    /// opacity/`.hidden()` still RESERVE the same fixed layout space, which would leave the
    /// exact space-squeeze bug above intact even with the button invisible. Removing the
    /// nodes from the tree is what both (a) makes the action content structurally
    /// impossible to reveal at peek regardless of any future height-math change, and (b)
    /// frees the room `searchArea` needs to render at its real size. `searchArea` also
    /// carries a defensive `.frame(minHeight:)` floor below, independent of this fix, so a
    /// future regression that reintroduces a competing fixed sibling can't silently squeeze
    /// it below a usable touch target again.
    var body: some View {
        VStack(spacing: 0) {
            // PR #87 round 5: `searchAreaBuilder` is called HERE, in `body`, not in `init`
            // — see `searchAreaBuilder`'s own doc comment for why passing
            // `handleSearchFieldHeightChange` requires a live, mounted `self`.
            searchAreaBuilder(handleSearchFieldHeightChange)
                // Defensive floor (Task 2): guarantees `searchArea` is never laid out
                // shorter than a usable touch target, independent of whatever else shares
                // this VStack. Belt-and-braces alongside the conditional-rendering fix
                // above — `minHeight` only raises the floor, it never shrinks a genuinely
                // taller measurement (Dynamic Type, etc.).
                .frame(minHeight: BrowseSheetDetentMath.minimumPeekHeight)

            // Gutter + actionColumn are ONLY mounted when NOT at peek — see this property's
            // own doc comment above for why this must be conditional rendering, not opacity.
            if detentKind.showsActionContent {
                // Fixed-height spacer, NOT `Spacer()` — a greedy `Spacer()` here would
                // expand to fill the sheet's full `.large`-sized layout pass and push
                // `actionColumn` to the BOTTOM of a near-screen-height container instead of
                // directly beneath `searchArea`. `Color.clear.frame(height:)` has a fixed
                // intrinsic size, so it sits exactly where
                // `BrowseSheetDetentMath.interSectionGutter` says it should.
                Color.clear
                    .frame(height: BrowseSheetDetentMath.interSectionGutter)

                actionColumn
                    .frame(height: actionColumnHeight)
            }

            // Community 2.0 Phase 1 (S4, QA pass 1 PR #94 Finding #2 — BLOCKING, both fixed):
            // the crew feed mounts ONLY at `.large` — this is the "third, taller state" the
            // spec calls for (§3 Phase 1), layered onto the pre-existing `.large` rung rather
            // than a new detent height (see `BrowseSheetDetentKind`'s own doc comment).
            // Deliberately a SEPARATE `if` from `showsActionContent` above (even though
            // `.large` implies `showsActionContent == true`) so the condition reads as "only
            // at large," not "only when action content shows" — the two happen to overlap
            // today but mean different things.
            //
            // Fix (a) — gate the MOUNT, not just the content: `AppConstants.communityEnabled`
            // is checked HERE, at the `if`, not only inside `ContentView`'s `crewFeed:`
            // closure (which resolves to `EmptyView()` when the flag is off, per its own doc
            // comment above). QA's finding: a `EmptyView`-producing child is still a DISTINCT
            // VStack child asking for `.frame(maxHeight:)`'s layout share — SwiftUI's stack
            // layout splits leftover space among however many unbounded-flexible children
            // EXIST, regardless of whether their content is visually empty. Checking the flag
            // here means the branch's body (and the `.frame` modifier below) is never even
            // evaluated while `communityEnabled == false` — the `.large` VStack has the exact
            // same two children (`searchArea`, conditionally `actionColumn`) it had before
            // this PR, not a third empty one. `ContentView`'s own `if AppConstants.communityEnabled`
            // guard inside its `crewFeed:` closure is now belt-and-braces (dead code once this
            // outer check is false), kept as a second line of defense rather than removed.
            //
            // Fix (b) — bounded frame, not a second competing "infinity" sibling:
            // `BrowseSearchAreaView`'s recents/suggestions/error-banner content ALSO expands
            // at `.large` (pre-existing, unchanged by this PR) and lives inside `searchArea`
            // above, which has no hard frame of its own — it relies on being the sheet's ONE
            // unbounded-flexible child to receive the VStack's full leftover height, the exact
            // "List inside this VStack is greedy and needs an explicit bound, not a second
            // implicit one" lesson `docs/ft20-bottom-sheet-navigation-spec.md` §0d finding C1
            // already paid for once (`actionColumnHeight`'s own formula-based, not measured,
            // sizing is that fix's other half). `.frame(maxHeight: .infinity)` here would make
            // THIS the VStack's second unbounded-flexible child, and SwiftUI has no way to
            // know search's `List` "deserves" more of the split than the crew feed —
            // `searchArea`'s list would likely lose roughly half its rendered height purely
            // from this PR's addition, flag on. Capping the crew feed at
            // `crewFeedMaxHeight` (an explicit, formula-based ceiling — same "compute from a
            // value we control, don't rely on being the sole greedy child" discipline as
            // `actionColumnHeight`/`maxAllowedMediumHeight` below) guarantees `searchArea`
            // keeps AT LEAST half of `.large`'s available height regardless of how tall the
            // crew feed's own content gets, while still giving the feed a generously large,
            // independently-scrolling region of its own.
            //
            // [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK] Same posture as
            // `maxAllowedMediumHeight` below — this machine has no simulator. Kevin/QA: with
            // `communityEnabled` flipped `true` locally, confirm at `.large` that (1) the
            // search recents/suggestions list still renders at a usable height when the crew
            // feed is also present, and (2) the crew feed itself isn't uncomfortably cramped
            // by the cap on a smaller device (SE-class). Flag-off: confirm this whole branch
            // renders nothing at all (byte-identical VStack child count to `origin/main`).
            if detentKind == .large, AppConstants.communityEnabled {
                crewFeedBuilder()
                    .frame(maxHeight: Self.crewFeedMaxHeight)
            }
        }
        // Re-report on every measured change (initial layout, Dynamic Type change, device
        // rotation). `searchAreaHeight` itself is now set directly by
        // `handleSearchFieldHeightChange` (passed into `searchAreaBuilder` above), which
        // also re-reports there — no separate `.onPreferenceChange`/`.onChange(of:
        // searchAreaHeight)` pair is needed anymore (PR #87 round 5). `actionColumnHeight`
        // is computed (not measured via geometry), so it's covered by watching its two
        // `@ScaledMetric` inputs below instead.
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

    /// PR #87 round 5: receives `BrowseSearchAreaView.searchField`'s live-measured height —
    /// threaded through `searchAreaBuilder` (see that property's doc comment for why this
    /// must be called from `body`, not captured at `init` time) rather than delivered via a
    /// `PreferenceKey`. Folds together what `.onPreferenceChange` and the subsequent
    /// `.onChange(of: searchAreaHeight)` used to do as two separate steps: store the raw
    /// measurement, then conditionally re-report the computed detent heights.
    /// `.onGeometryChange` (`BrowseSearchAreaView.searchField`'s side of this) already only
    /// invokes its action when the measured value actually changes, so there's no longer a
    /// distinct "did the observed value change" event to react to separately.
    private func handleSearchFieldHeightChange(_ newHeight: CGFloat) {
        searchAreaHeight = newHeight
        guard BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: newHeight) else { return }
        reportHeights()
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
        Self.activeScreenHeight * 0.75
    }

    /// Community 2.0 Phase 1 (S4, QA pass 1 PR #94 Finding #2 — BLOCKING): explicit ceiling
    /// on the crew feed's height at `.large`, so it is NOT a second unbounded-flexible
    /// `VStack` sibling competing with `searchArea`'s own greedy `List` for the sheet's
    /// leftover space (see the mount site's own doc comment in `body` for the full
    /// reasoning). Half the screen height is generous for the feed's own scrollable content
    /// while guaranteeing `searchArea` keeps at least the other half, regardless of how much
    /// content either side has.
    ///
    /// [COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK] — same posture as
    /// `maxAllowedMediumHeight` above; this ratio is a reasoned starting point, not a
    /// measured one. Revisit if Kevin's live smoke shows either side cramped.
    private static var crewFeedMaxHeight: CGFloat {
        Self.activeScreenHeight * 0.5
    }

    /// Shared screen-height lookup for `maxAllowedMediumHeight`/`crewFeedMaxHeight` — reads
    /// the height off the app's active `UIWindowScene` rather than `UIScreen.main` (QA
    /// docs/qa/ft20-stream-a-pr85.md Finding #5 — `UIScreen.main` is on Apple's
    /// deprecation-direction path since iOS 13; per-scene sizing is the supported
    /// replacement). Falls back to `UIScreen.main` only if no window scene is connected yet
    /// (e.g. a very early launch timing edge case), which this single-window/single-scene
    /// app should never actually hit in practice. Extracted (S4 QA fix) so the two ceiling
    /// computations above share one lookup instead of duplicating it.
    private static var activeScreenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height
            ?? UIScreen.main.bounds.height
    }
}

// Note: `BrowseSheetSearchAreaStub` (Stream A's placeholder search row) is gone — Stream B
// replaced it at the `ContentView.swift` call site with the real `BrowseSearchAreaView`,
// and Stream C is what makes that call site live. Nothing referenced the stub anymore, so
// it was deleted rather than left as dead code.

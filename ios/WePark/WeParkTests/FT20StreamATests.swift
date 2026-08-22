//
//  FT20StreamATests.swift
//  WeParkTests
//
//  FT-20 Stream A — browse-mode bottom sheet CONTAINER.
//  docs/ft20-bottom-sheet-navigation-spec.md §4.1/§4.2, §0b findings B1/B2.
//
//  `BrowseSheetDetentMath` is a pure, UIKit-free function — no simulator/rendering
//  required, so it's covered directly here (mirroring the `paddingForBannerState` /
//  `gearButtonVisible` / `recenterButtonStackVisible` precedent already established in
//  FT13Tests.swift / FT18Tests.swift). `BrowseNavigationSheet`'s actual on-screen rendering
//  (row anatomy, detent behavior, keyboard avoidance) has no ViewInspector/snapshot library
//  in this repo and is out of reach on this Linux VPS — it's covered by Kevin's on-device
//  live-UI smoke per this project's standing protocol, not by these tests.
//
//  Also covers `browseSheetDetentSelectionBinding` (QA docs/qa/ft20-stream-a-pr85.md
//  Finding #4) — its get/set classification logic operates on plain `PresentationDetent`/
//  `CGFloat` values, not views, so it's unit-testable via `Binding(get:set:)` against a
//  simple reference-type stand-in for `@State`, with no SwiftUI rendering required either.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import SwiftUI
@testable import WePark

final class BrowseSheetDetentMathTests: XCTestCase {

    // MARK: - peekHeight
    //
    // §0f (2026-08-21, third live smoke): the old `peekHeight` formula — measured search
    // height + a guessed `grabberAndInsetAllowance` constant for the system's own
    // grab-indicator chrome — survived TWO fix attempts (24 → 12) and Kevin still saw
    // "the three buttons are peaking." The tests below are DELIBERATELY REWRITTEN, not
    // just re-pinned, because the underlying formula changed: `peekHeight` no longer adds
    // an unverifiable guess on top of `searchAreaHeight` at all — it's derived FROM it and
    // hard-clamped below `actionContentTopOffset`. See `BrowseSheetDetentMath.peekHeight`'s
    // doc comment for the full construction, and `BrowseSheetPeekInvariantTests` below for
    // the invariant test this history specifically asked for.
    //
    // ⚠️ PR #87 ROUND 4 (2026-08-21): the formula flipped AGAIN — `peekHeight` now ADDS
    // `peekBreathingRoom` on top of `searchAreaHeight` instead of subtracting
    // `peekSafetyMargin` from it. This is a DELIBERATE behavior change, not a formula
    // detail: Kevin's 4th screenshot showed the search field missing ENTIRELY at peek, and
    // round-4's root cause (see `BrowseSheetDetentMath`'s and `BrowseNavigationSheet.body`'s
    // own doc comments) was that `actionColumn` was unconditionally in the layout tree,
    // squeezing `searchArea` for space. Subtracting a margin from `searchAreaHeight` made
    // that worse, not better — it guaranteed peek's presented height was always LESS than
    // the field's own real size. Now that `actionColumn` is conditionally removed from the
    // tree at peek (so it can never bleed through regardless of this number), peek height
    // can safely be generous: it now guarantees the FULL search field fits, with a few
    // points to spare, rather than deliberately under-shooting it. The two tests below are
    // rewritten (not just re-pinned) to match; the invariant suite further down
    // (`BrowseSheetPeekInvariantTests`) is UNCHANGED — "peek strictly below
    // actionContentTopOffset" still holds under the new formula, it's still the load-
    // bearing regression guard, just no longer the ONLY line of defense.

    func testPeekHeight_isAtOrAboveMeasuredSearchHeightForRealisticContent() {
        // DELIBERATE BEHAVIOR CHANGE from the round-3 formula (see this section's own
        // comment above): a realistic rendered search field (~66pt at default Dynamic
        // Type) must now be FULLY CONTAINED in the peek window, not bottom-cropped. The
        // round-3 formula asserted the opposite (`result < 66`) — that under-shoot is
        // exactly what round 4's screenshot showed going wrong (no visible search field at
        // peek at all).
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 66)
        XCTAssertGreaterThan(
            result, 66,
            "Peek height must comfortably exceed the measured search-area height for " +
            "realistic content, now that `actionColumn` can never be mounted at peek to " +
            "bleed through a generous peek height (BrowseSheetDetentKind.showsActionContent)."
        )
    }

    func testPeekHeight_flooredAtMinimumForAGenuinelyShortSearchArea() {
        // DELIBERATE BEHAVIOR CHANGE: this test previously used searchAreaHeight == 66,
        // the same input as the test above — under the OLD subtractive formula that
        // happened to land exactly on the floor. Under the new additive formula, 66 lands
        // well above the floor (see the test above), so this test now uses a genuinely
        // short search-area height (58pt — plausible at a smaller Dynamic Type size) chosen
        // specifically to land in the floor-binding range: `minimumPeekHeight` (64) is
        // still ≤ `actionContentTopOffset(58) - 1` (65) at this input, so the nominal
        // 44pt-plus-grabber floor (spec §4.1) is what determines the result, not the
        // ceiling clamp — see `BrowseSheetDetentMath.peekHeight`'s doc comment for the
        // three-way (floor / candidate / ceiling) priority ordering this pins.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 58)
        XCTAssertEqual(
            result, BrowseSheetDetentMath.minimumPeekHeight,
            "For search-area heights short enough that floor and ceiling both exceed the " +
            "additive candidate, peek should land exactly at `minimumPeekHeight` (spec " +
            "§4.1: 'Peek must clear a full 44pt touch target plus the grabber')."
        )
    }

    func testPeekHeight_degenerateZeroInput_deliberatelyBelowNominalFloor() {
        // DELIBERATE BEHAVIOR CHANGE, called out explicitly per this PR's own instructions:
        // the OLD test here asserted peekHeight(0) == minimumPeekHeight (64). The NEW
        // formula prioritizes "never reveal action content" over "meet the nominal floor"
        // for this specific degenerate input — see `BrowseSheetDetentMath.peekHeight`'s
        // doc comment for why that's safe: searchAreaHeight == 0 is the unmeasured `@State`
        // placeholder, which never reaches a live `.presentationDetents` call (guarded by
        // `isGenuineMeasurement` elsewhere, and `ContentView`'s own initial `@State`
        // default bypasses this function, hardcoded straight to `minimumPeekHeight`). This
        // test pins the new, intentional behavior rather than silently dropping coverage.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 0)
        XCTAssertLessThan(
            result, BrowseSheetDetentMath.minimumPeekHeight,
            "At the degenerate searchAreaHeight == 0 input, peek intentionally lands BELOW " +
            "the nominal floor — the clamp against actionContentTopOffset wins for this " +
            "unreachable-in-production input. See this test's own comment."
        )
        XCTAssertGreaterThanOrEqual(result, 0, "Peek height must never be negative.")
    }

    func testPeekHeight_negativeInput_clampsToNonNegative() {
        // DELIBERATE BEHAVIOR CHANGE (see the zero-input test above for the full
        // reasoning): a negative input (should never happen in practice — GeometryProxy
        // heights are never negative) now clamps to 0 rather than the nominal floor, since
        // `actionContentTopOffset` for a negative searchAreaHeight is itself small/negative.
        // Still never negative, still never reachable in production (same guards as above).
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: -10)
        XCTAssertEqual(result, 0)
    }

    func testPeekHeight_growsWithLargerMeasuredContent() {
        // Dynamic Type at a large accessibility size inflates the search row — the peek
        // detent must grow to match, not stay pinned at a small default.
        let small = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 80)
        let large = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 200)
        XCTAssertGreaterThan(
            large, small,
            "Peek height must scale with the measured content, not be a fixed constant " +
            "(design-review finding B2 — Dynamic Type support)."
        )
    }

    // §0f: "peek is STILL wrong... deserves a test that fails if it comes back." The
    // dedicated invariant coverage for that lives in `BrowseSheetPeekInvariantTests`, its
    // own top-level suite at the bottom of this file — it doesn't matter what
    // `peekHeight`'s formula does internally, so it's kept separate from this class's
    // formula-level tests above.

    // MARK: - mediumHeight

    func testMediumHeight_isActionContentTopOffsetPlusColumnHeightWhenUnderTheCeiling() {
        let searchHeight: CGFloat = 60
        let columnHeight: CGFloat = 120
        let ceiling: CGFloat = 1000  // effectively unreachable — isolates the "no clamp" path

        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionColumnHeight: columnHeight,
            maxAllowedHeight: ceiling
        )

        let expectedOffset = BrowseSheetDetentMath.actionContentTopOffset(searchAreaHeight: searchHeight)
        XCTAssertEqual(
            result, expectedOffset + columnHeight,
            "Medium height should be exactly actionContentTopOffset (search height + " +
            "inter-section gutter) + the measured action-column height — 'search + Find a " +
            "Spot + New to parking?, and no more' (OQ-3/§0f) — when nothing forces a clamp. " +
            "DELIBERATELY changed from the old `peekHeight(...) + actionColumnHeight` " +
            "relation — see `BrowseSheetDetentMath.mediumHeight`'s doc comment for why " +
            "conflating medium's sizing with peek's own clamp was itself part of the bug."
        )
    }

    func testMediumHeight_clampsAtCeilingForRunawayDynamicType() {
        // Simulates an AX5-class Dynamic Type size where the search row and action column
        // would, uncapped, sum past what should ever be reachable by the "custom" medium
        // detent.
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: 300,
            actionColumnHeight: 900,
            maxAllowedHeight: 500
        )
        XCTAssertEqual(
            result, 500,
            "Medium height must never exceed maxAllowedHeight — design-review finding B2: " +
            "a runaway Dynamic Type size must not push the custom medium detent up to, or " +
            "past, `.large`."
        )
    }

    func testMediumHeight_neverExceedsMaxAllowedHeightAcrossARangeOfInputs() {
        let ceiling: CGFloat = 400
        for searchHeight in stride(from: CGFloat(0), through: 400, by: 50) {
            for columnHeight in stride(from: CGFloat(0), through: 800, by: 100) {
                let result = BrowseSheetDetentMath.mediumHeight(
                    searchAreaHeight: searchHeight,
                    actionColumnHeight: columnHeight,
                    maxAllowedHeight: ceiling
                )
                XCTAssertLessThanOrEqual(
                    result, ceiling,
                    "mediumHeight(\(searchHeight), \(columnHeight)) exceeded the clamp ceiling."
                )
            }
        }
    }

    func testMediumHeight_isAtLeastActionContentTopOffsetEvenWhenNotClamped() {
        // Sanity: medium must always be at least as tall as the offset to where the action
        // content begins (i.e. it always fully contains the search area + gutter).
        let searchHeight: CGFloat = 60
        let offset = BrowseSheetDetentMath.actionContentTopOffset(searchAreaHeight: searchHeight)
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionColumnHeight: 10,
            maxAllowedHeight: offset + 100
        )
        XCTAssertGreaterThanOrEqual(result, offset)
    }

    // MARK: - Regression guard: this is a CUSTOM detent, never `.medium`

    /// Design-review finding B1: an earlier draft of the spec's own §4.1 code sample used
    /// system `.medium` (~40% of screen) for the middle detent, directly contradicting
    /// Kevin's OQ-3 ruling. This isn't something `BrowseSheetDetentMath` itself can
    /// "regress" (it has no notion of `.medium` at all — that's exactly the point: the
    /// computed value is a plain `CGFloat` fed into `.height(_:)`), but this test pins the
    /// expectation that a realistic medium height (search field + Find a Spot + New to
    /// parking?, default Dynamic Type) lands nowhere near a typical device's
    /// ~40%-of-screen `.medium` value, so a future regression that silently reintroduces a
    /// system-fraction-sized default would be caught here.
    func testMediumHeight_realisticContentIsFarShorterThanSystemMediumFraction() {
        // Rough values for "search field (single line) + the §0f action column
        // (Find-a-Spot button + New-to-parking link) at default Dynamic Type" — see
        // BrowseSearchAreaView.searchField / BrowseNavigationSheet.actionColumn. §0f's
        // action column (~130pt) is even shorter than §0e's already-shrunk 3-icon row
        // (~90pt), so this test's own assertion (comfortably under a system `.medium`
        // fraction) only gets easier to satisfy, not harder.
        let realisticSearchHeight: CGFloat = 66
        let realisticColumnHeight: CGFloat = 130
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: realisticSearchHeight,
            actionColumnHeight: realisticColumnHeight,
            maxAllowedHeight: 1000
        )
        // A typical iPhone's system `.medium` detent is roughly 400-450pt (~40-50% of a
        // ~850-930pt screen height minus safe areas). The realistic content-fit value
        // should be comfortably under that, not approaching it.
        XCTAssertLessThan(
            result, 350,
            "A realistic 'search field + Find a Spot + New to parking?' medium height " +
            "should be well under a typical device's system `.medium` fraction — if this " +
            "test starts failing because the computed value crept up near ~400pt+, check " +
            "for an accidental reintroduction of `.medium`-shaped sizing (design-review " +
            "finding B1)."
        )
    }
}

// MARK: - The peek invariant (§0f: "deserves a test that fails if it comes back")

/// This bug has now shipped, been "fixed," and shipped broken again TWICE (24 →
/// 12 → still broken, per Kevin's third live smoke). This suite pins the OUTCOME rather
/// than any particular internal formula, so it fails regardless of how `peekHeight`'s
/// implementation changes in the future, as long as the underlying regression reappears.
final class BrowseSheetPeekInvariantTests: XCTestCase {

    /// The core invariant: for ANY measured search-area height (including the full
    /// Dynamic-Type range, from a tiny custom size up through AX5-class accessibility
    /// sizes), `peekHeight` must be STRICTLY LESS THAN `actionContentTopOffset` — the exact
    /// point at which `BrowseNavigationSheet.body`'s action content begins. Peek showing
    /// LESS than the full search field (a few points of trimmed bottom padding) is an
    /// acceptable, minor cosmetic cost; peek showing ANY of the action content is the bug
    /// that has now survived two fix attempts.
    func testPeekHeight_isStrictlyLessThanActionContentTopOffset_acrossRealisticDynamicTypeRange() {
        // 40...400 comfortably spans "smallest real search field" through "AX5-class
        // accessibility Dynamic Type" — see BrowseSearchAreaView.searchField's fixed
        // padding (10 inner + 12 outer, each doubled) for why a real rendered field is
        // essentially never shorter than ~40pt even at the smallest text size.
        for searchAreaHeight in stride(from: CGFloat(40), through: 400, by: 4) {
            let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight)
            let actionTop = BrowseSheetDetentMath.actionContentTopOffset(searchAreaHeight: searchAreaHeight)
            XCTAssertLessThan(
                peek, actionTop,
                "peekHeight(\(searchAreaHeight)) = \(peek) reached actionContentTopOffset " +
                "(\(actionTop)) — this is the exact 'buttons peeking' live-smoke bug " +
                "(spec §0f, 2026-08-21), now regressed."
            )
        }
    }

    /// Same invariant, restated directly against `mediumHeight`'s own offset math (rather
    /// than `actionContentTopOffset` in isolation), since that's the function that actually
    /// determines how tall the medium detent — and therefore where the action content
    /// really sits — becomes at runtime.
    func testPeekHeight_isStrictlyLessThanMediumHeight_acrossRealisticDynamicTypeRange() {
        for searchAreaHeight in stride(from: CGFloat(40), through: 400, by: 8) {
            for columnHeight in stride(from: CGFloat(80), through: 300, by: 40) {
                let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight)
                let medium = BrowseSheetDetentMath.mediumHeight(
                    searchAreaHeight: searchAreaHeight,
                    actionColumnHeight: columnHeight,
                    maxAllowedHeight: 2000  // effectively unreachable, isolates the relation itself
                )
                XCTAssertLessThan(
                    peek, medium,
                    "peekHeight(\(searchAreaHeight)) must always be strictly less than " +
                    "mediumHeight(\(searchAreaHeight), \(columnHeight)) — peek is a strict " +
                    "subset of medium's content, never equal to or past it."
                )
            }
        }
    }

    /// Sanity floor: even where the clamp against `actionContentTopOffset` wins over the
    /// nominal `minimumPeekHeight` floor, peek must still clear SOME reasonable non-zero
    /// touch target for any search-area height a real rendered field could produce.
    func testPeekHeight_clearsAReasonableTouchTargetAcrossRealisticDynamicTypeRange() {
        for searchAreaHeight in stride(from: CGFloat(40), through: 400, by: 8) {
            let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight)
            XCTAssertGreaterThan(
                peek, 30,
                "peekHeight(\(searchAreaHeight)) = \(peek) is too short to be a usable " +
                "touch target for any realistically-rendered search field."
            )
        }
    }

    /// PR #87 ROUND 4 — new invariant, added alongside the round-4 fix (spec brief's
    /// explicit ask: "a test that the search field's measured height is non-zero for
    /// realistic inputs, if that's expressible as pure logic"). `BrowseSearchAreaView`'s
    /// actual on-screen rendered height isn't reachable from this pure-math suite (no
    /// ViewInspector/snapshot tooling, no simulator on this machine — see this file's
    /// top-of-file comment) — the closest expressible-as-pure-logic proxy is this: for any
    /// realistic measured `searchAreaHeight`, `peekHeight` must be large enough to contain
    /// the ENTIRE search area, not crop it. This is the exact invariant round 4 changed:
    /// the round-3 formula subtracted a margin (guaranteeing under-shoot, i.e. cropping);
    /// this one adds one (guaranteeing the full field fits). If this regresses back to
    /// `peek < searchAreaHeight`, the search field is being cropped again, which is one of
    /// the two symptoms round 4 fixed.
    func testPeekHeight_fullyContainsTheSearchArea_acrossRealisticDynamicTypeRange() {
        for searchAreaHeight in stride(from: CGFloat(40), through: 400, by: 4) {
            let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchAreaHeight)
            XCTAssertGreaterThanOrEqual(
                peek, searchAreaHeight,
                "peekHeight(\(searchAreaHeight)) = \(peek) is SHORTER than the measured " +
                "search area — the field would be bottom-cropped at peek, the exact " +
                "'no visible search field at peek' symptom from Kevin's 4th live smoke."
            )
        }
    }
}

// MARK: - BrowseSheetDetentKind.showsActionContent Tests
//
// PR #87 ROUND 4: the actual fix for "peek reveals the action content" (three prior
// arithmetic-only attempts never killed it — see `BrowseNavigationSheet.body`'s doc
// comment) is that `actionColumn`/its gutter are now conditionally MOUNTED, gated by this
// property, rather than sized to be invisible. This is pure Swift enum logic — no view
// rendering needed — so it's directly unit-testable, unlike the actual on-screen
// conditional-rendering behavior it drives (Kevin's live-UI smoke covers that).
final class BrowseSheetDetentKindShowsActionContentTests: XCTestCase {

    func testPeek_doesNotShowActionContent() {
        XCTAssertFalse(
            BrowseSheetDetentKind.peek.showsActionContent,
            "Peek must never show the action column — this is the structural (not " +
            "height-arithmetic) guarantee round 4 introduced."
        )
    }

    func testMedium_showsActionContent() {
        XCTAssertTrue(BrowseSheetDetentKind.medium.showsActionContent)
    }

    func testLarge_showsActionContent() {
        XCTAssertTrue(BrowseSheetDetentKind.large.showsActionContent)
    }
}

// MARK: - browseSheetDetentSelectionBindingTests

/// QA docs/qa/ft20-stream-a-pr85.md Finding #4: `browseSheetDetentSelectionBinding`'s
/// get/set classification logic is pure Swift operating on `PresentationDetent`/`CGFloat`
/// values, not views — it doesn't need SwiftUI rendering or a simulator to unit test, unlike
/// `BrowseNavigationSheet`'s own on-screen behavior. This suite covers the get/set round-trip
/// and, specifically, the edge case QA flagged as highest-risk: a `newValue` reported to
/// `set` that doesn't exactly match either measured custom height (e.g. a Dynamic Type change
/// re-measures `peekHeight`/`mediumHeight` between `get` and the next `set` call).
///
/// A minimal reference-type wrapper stands in for `@State` here — `Binding(get:set:)` doesn't
/// require SwiftUI's property-wrapper machinery, only a place to read/write from, so no view
/// hosting or ViewInspector-style tooling is needed.
final class BrowseSheetDetentSelectionBindingTests: XCTestCase {

    private final class KindBox {
        var kind: BrowseSheetDetentKind
        init(_ kind: BrowseSheetDetentKind) { self.kind = kind }
    }

    private func makeBinding(
        box: KindBox,
        peekHeight: CGFloat,
        mediumHeight: CGFloat
    ) -> Binding<PresentationDetent> {
        browseSheetDetentSelectionBinding(
            kind: Binding(get: { box.kind }, set: { box.kind = $0 }),
            peekHeight: peekHeight,
            mediumHeight: mediumHeight
        )
    }

    // MARK: get

    func testGet_peekKindReturnsHeightDetentAtPeekHeight() {
        let box = KindBox(.peek)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        XCTAssertEqual(binding.wrappedValue, .height(96))
    }

    func testGet_mediumKindReturnsHeightDetentAtMediumHeight() {
        let box = KindBox(.medium)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        XCTAssertEqual(binding.wrappedValue, .height(260))
    }

    func testGet_largeKindReturnsSystemLarge() {
        let box = KindBox(.large)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        XCTAssertEqual(binding.wrappedValue, .large)
    }

    // MARK: set — exact matches

    func testSet_largeValueClassifiesAsLargeKind() {
        let box = KindBox(.peek)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        binding.wrappedValue = .large
        XCTAssertEqual(box.kind, .large)
    }

    func testSet_exactMediumHeightValueClassifiesAsMediumKind() {
        let box = KindBox(.peek)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        binding.wrappedValue = .height(260)
        XCTAssertEqual(box.kind, .medium)
    }

    func testSet_exactPeekHeightValueClassifiesAsPeekKind() {
        let box = KindBox(.large)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        binding.wrappedValue = .height(96)
        XCTAssertEqual(box.kind, .peek)
    }

    // MARK: set — round-trip

    func testSetThenGet_roundTripsForAllThreeKinds() {
        let box = KindBox(.peek)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)

        binding.wrappedValue = .large
        XCTAssertEqual(binding.wrappedValue, .large)

        binding.wrappedValue = .height(260)
        XCTAssertEqual(binding.wrappedValue, .height(260))

        binding.wrappedValue = .height(96)
        XCTAssertEqual(binding.wrappedValue, .height(96))
    }

    // MARK: set — the remeasurement edge case (QA Finding #4's highest-risk scenario)
    //
    // FT-20 Stream C bugfix (live-smoke two-bug report): the OLD behavior pinned by these
    // two tests — silently reclassifying ANY unmatched `newValue` as `.peek` — was
    // identified as the mechanism behind the "peek shows the Settings row" live bug once
    // Stream C's real remount cycles (browse sheet round-tripping through Settings/Parking
    // 101/etc.) started actually changing `peekHeight`/`mediumHeight` at runtime, turning
    // this dormant Stream A risk into a reachable one. `BrowseSheetDetentKind.classify`
    // now returns `nil` for an unmatched value, and `browseSheetDetentSelectionBinding`'s
    // `set` PRESERVES the current kind instead of forcing `.peek` — these tests are updated
    // to pin the NEW (fixed) behavior; see `BrowseSheetDetentKind.classify`'s doc comment.

    /// If a Dynamic Type change re-measures `peekHeight`/`mediumHeight` between when SwiftUI
    /// last read this binding's `get` and the next `set` callback (e.g. mid-drag, or a
    /// remeasurement racing a detent-change notification, or — newly relevant — a
    /// `BrowseNavigationSheet` remount churning the measured heights), `newValue` may not
    /// exactly equal either `.height(peekHeight)` or `.height(mediumHeight)` as currently
    /// measured. The fix: preserve whatever kind was already selected rather than guessing
    /// `.peek` — an unrecognized echo is not evidence the user dragged anywhere.
    func testSet_valueNotMatchingEitherCustomHeightPreservesCurrentKind() {
        let box = KindBox(.large)
        // Binding constructed with a STALE mediumHeight (300), simulating the get/set race:
        // the reported newValue reflects a value from BEFORE a remeasurement changed
        // mediumHeight, so it no longer exactly equals the binding's current mediumHeight.
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 300)
        binding.wrappedValue = .height(260)  // close to, but not exactly, the current mediumHeight (300)
        XCTAssertEqual(
            box.kind, .large,
            "An unrecognized newValue (a stale echo during a height remeasurement/remount " +
            "race) must PRESERVE the current kind, not force `.peek` — see " +
            "`BrowseSheetDetentKind.classify`'s doc comment. The old fallback-to-`.peek` " +
            "behavior (QA docs/qa/ft20-stream-a-pr85.md Finding #4, previously pinned by " +
            "this test) was identified as a likely contributor to the FT-20 Stream C " +
            "live-smoke bug where the browse sheet's peek detent unexpectedly revealed the " +
            "medium-detent action list."
        )
    }

    /// Same scenario as above but for an arbitrary, unrelated height value (not close to
    /// either detent) — confirms kind-preservation isn't specific to "near-miss" values.
    func testSet_arbitraryUnmatchedHeightPreservesCurrentKind() {
        let box = KindBox(.medium)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        binding.wrappedValue = .height(500)
        XCTAssertEqual(box.kind, .medium)
    }

    /// A `.peek`-kind box receiving an unmatched value must also stay `.peek` — the
    /// preservation behavior isn't just "anything defaults to non-peek."
    func testSet_arbitraryUnmatchedHeightPreservesPeekKind() {
        let box = KindBox(.peek)
        let binding = makeBinding(box: box, peekHeight: 96, mediumHeight: 260)
        binding.wrappedValue = .height(500)
        XCTAssertEqual(box.kind, .peek)
    }
}

// MARK: - BrowseSheetDetentKind.classify Tests

/// FT-20 Stream C bugfix: direct unit coverage of the pure classification function
/// `browseSheetDetentSelectionBinding`'s `set` closure now delegates to — see
/// `BrowseSheetDetentKind.classify`'s doc comment for the full rationale.
final class BrowseSheetDetentKindClassifyTests: XCTestCase {

    func testClassify_exactPeekMatch() {
        XCTAssertEqual(
            BrowseSheetDetentKind.classify(.height(96), peekHeight: 96, mediumHeight: 260),
            .peek
        )
    }

    func testClassify_exactMediumMatch() {
        XCTAssertEqual(
            BrowseSheetDetentKind.classify(.height(260), peekHeight: 96, mediumHeight: 260),
            .medium
        )
    }

    func testClassify_largeMatch() {
        XCTAssertEqual(
            BrowseSheetDetentKind.classify(.large, peekHeight: 96, mediumHeight: 260),
            .large
        )
    }

    func testClassify_unmatchedValueReturnsNil() {
        XCTAssertNil(
            BrowseSheetDetentKind.classify(.height(500), peekHeight: 96, mediumHeight: 260),
            "A value matching neither .large nor either current custom height must return " +
            "nil so the caller can preserve the current kind, not guess."
        )
    }

    func testClassify_staleNearMissMediumValueReturnsNil() {
        // The exact QA Finding #4 scenario: a value that WAS mediumHeight a moment ago,
        // before a remeasurement (or a BrowseNavigationSheet remount) moved it.
        XCTAssertNil(
            BrowseSheetDetentKind.classify(.height(260), peekHeight: 96, mediumHeight: 300)
        )
    }

    func testClassify_degenerateZeroHeightsStillClassifyExactly() {
        // Even in a degenerate not-yet-measured scenario (peek/medium both at their
        // floor-derived values), exact matches still classify correctly — this function
        // has no independent notion of "measured vs. unmeasured," only exact equality.
        XCTAssertEqual(
            BrowseSheetDetentKind.classify(
                .height(BrowseSheetDetentMath.minimumPeekHeight),
                peekHeight: BrowseSheetDetentMath.minimumPeekHeight,
                mediumHeight: 220
            ),
            .peek
        )
    }
}

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

    func testPeekHeight_addsGrabberAllowanceToMeasuredSearchHeight() {
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 60)
        XCTAssertEqual(
            result,
            60 + BrowseSheetDetentMath.grabberAndInsetAllowance,
            "Peek height should be the measured search-area height plus the grabber/inset allowance."
        )
    }

    func testPeekHeight_flooredAtMinimumForAVeryShortOrUnmeasuredSearchArea() {
        // searchAreaHeight: 0 simulates the very first layout pass, before
        // .onGeometryChange has fired even once.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 0)
        XCTAssertEqual(
            result,
            BrowseSheetDetentMath.minimumPeekHeight,
            "An unmeasured (height 0) or pathologically short search area must never " +
            "produce a peek detent shorter than the 44pt-touch-target-plus-grabber floor " +
            "(spec §4.1: 'Peek must clear a full 44pt touch target plus the grabber')."
        )
    }

    func testPeekHeight_floorAppliesEvenForNegativeInput() {
        // Defensive: GeometryProxy heights should never be negative in practice, but the
        // floor must hold regardless of what's fed in.
        let result = BrowseSheetDetentMath.peekHeight(searchAreaHeight: -10)
        XCTAssertEqual(result, BrowseSheetDetentMath.minimumPeekHeight)
    }

    func testPeekHeight_growsWithLargerMeasuredContent() {
        // Dynamic Type at a large accessibility size inflates the search row — the peek
        // detent must grow to match, not stay pinned at a small default.
        let small = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 50)
        let large = BrowseSheetDetentMath.peekHeight(searchAreaHeight: 140)
        XCTAssertGreaterThan(
            large, small,
            "Peek height must scale with the measured content, not be a fixed constant " +
            "(design-review finding B2 — Dynamic Type support)."
        )
    }

    // MARK: - mediumHeight

    func testMediumHeight_isPeekPlusActionListWhenUnderTheCeiling() {
        let searchHeight: CGFloat = 60
        let listHeight: CGFloat = 180
        let ceiling: CGFloat = 1000  // effectively unreachable — isolates the "no clamp" path

        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionListHeight: listHeight,
            maxAllowedHeight: ceiling
        )

        let expectedPeek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchHeight)
        XCTAssertEqual(
            result, expectedPeek + listHeight,
            "Medium height should be exactly peek height + the measured 3-row action list " +
            "height — 'search + exactly three rows and no more' (OQ-3) — when nothing " +
            "forces a clamp."
        )
    }

    func testMediumHeight_clampsAtCeilingForRunawayDynamicType() {
        // Simulates an AX5-class Dynamic Type size where the search row and 3 rows would,
        // uncapped, sum past what should ever be reachable by the "custom" medium detent.
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: 300,
            actionListHeight: 900,
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
            for listHeight in stride(from: CGFloat(0), through: 800, by: 100) {
                let result = BrowseSheetDetentMath.mediumHeight(
                    searchAreaHeight: searchHeight,
                    actionListHeight: listHeight,
                    maxAllowedHeight: ceiling
                )
                XCTAssertLessThanOrEqual(
                    result, ceiling,
                    "mediumHeight(\(searchHeight), \(listHeight)) exceeded the clamp ceiling."
                )
            }
        }
    }

    func testMediumHeight_isAtLeastPeekHeightEvenWhenClamped() {
        // Sanity: the clamp should never be so aggressive that medium collapses below peek
        // for realistic inputs (ceiling comfortably above the peek floor).
        let searchHeight: CGFloat = 60
        let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: searchHeight)
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: searchHeight,
            actionListHeight: 10,
            maxAllowedHeight: peek + 100
        )
        XCTAssertGreaterThanOrEqual(result, peek)
    }

    // MARK: - Regression guard: this is a CUSTOM detent, never `.medium`

    /// Design-review finding B1: an earlier draft of the spec's own §4.1 code sample used
    /// system `.medium` (~40% of screen) for the middle detent, directly contradicting
    /// Kevin's OQ-3 ruling. This isn't something `BrowseSheetDetentMath` itself can
    /// "regress" (it has no notion of `.medium` at all — that's exactly the point: the
    /// computed value is a plain `CGFloat` fed into `.height(_:)`), but this test pins the
    /// expectation that a realistic medium height (search field + 3 short rows, default
    /// Dynamic Type) lands nowhere near a typical device's ~40%-of-screen `.medium` value,
    /// so a future regression that silently reintroduces a system-fraction-sized default
    /// would be caught here.
    func testMediumHeight_realisticContentIsFarShorterThanSystemMediumFraction() {
        // Rough measured values for "search field (single line) + 3 List rows at default
        // Dynamic Type" — see BrowseSearchAreaView.searchField / actionList's row count.
        let realisticSearchHeight: CGFloat = 60
        let realisticListHeight: CGFloat = 170   // ~3 rows × ~44pt insetGrouped row + section insets
        let result = BrowseSheetDetentMath.mediumHeight(
            searchAreaHeight: realisticSearchHeight,
            actionListHeight: realisticListHeight,
            maxAllowedHeight: 1000
        )
        // A typical iPhone's system `.medium` detent is roughly 400-450pt (~40-50% of a
        // ~850-930pt screen height minus safe areas). The realistic content-fit value
        // should be comfortably under that, not approaching it.
        XCTAssertLessThan(
            result, 350,
            "A realistic 'search field + 3 short rows' medium height should be well under " +
            "a typical device's system `.medium` fraction — if this test starts failing " +
            "because the computed value crept up near ~400pt+, check for an accidental " +
            "reintroduction of `.medium`-shaped sizing (design-review finding B1)."
        )
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

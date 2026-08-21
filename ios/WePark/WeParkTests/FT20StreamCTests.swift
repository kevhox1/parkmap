//
//  FT20StreamCTests.swift
//  WeParkTests
//
//  FT-20 Stream C — ContentView integration: flipping `ft20BrowseSheetEnabled`, the
//  Drive Mode boundary (spec §6, AC-28/AC-29a, design-review S3), and the FT-15
//  block-select entry settling window (spec §5.1, design-review S4).
//  docs/ft20-bottom-sheet-navigation-spec.md.
//
//  Both boundary rules below are extracted as pure functions — no SwiftUI/view
//  dependency — mirroring the `recenterButtonStackVisible` /
//  `shouldClearBlockSelectOnDriveModeEntry` precedent already established in this test
//  target: the actual on-screen "no frame shows both" / "first tap after entry is safely
//  ignored" claims are Kevin's live-UI smoke (see the PR's smoke checklist), not something
//  this Linux VPS can render or time. What IS covered here is the decision logic these
//  claims are built on.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

// MARK: - browseSheetBoundaryTarget(driveModeBecameActive:) Tests

final class BrowseSheetDriveBoundaryTests: XCTestCase {

    func testDriveModeEntry_targetsHidden() {
        XCTAssertEqual(
            browseSheetBoundaryTarget(driveModeBecameActive: true),
            .hidden,
            "AC-28: the browse sheet must force-hide unconditionally the instant Drive Mode " +
            "becomes active — never peek, matching the FT-15 block-select precedent."
        )
    }

    func testDriveModeExit_targetsBrowseNavAtPeek() {
        XCTAssertEqual(
            browseSheetBoundaryTarget(driveModeBecameActive: false),
            .browseNavAtPeek,
            "AC-29a: the browse sheet must reappear at PEEK on Drive Mode exit — not " +
            "wherever it was left (spec §6: a completed drive session, stale search state)."
        )
    }
}

// MARK: - blockSelectTapShouldBeIgnored(now:guardUntil:) Tests

final class BlockSelectEntrySettlingGuardTests: XCTestCase {

    func testNilGuard_neverIgnoresTaps() {
        XCTAssertFalse(
            blockSelectTapShouldBeIgnored(now: .now, guardUntil: nil),
            "Outside the entry settling window (guardUntil == nil, e.g. block-select has " +
            "been active a while, or mode was never entered) taps must never be ignored."
        )
    }

    func testTapBeforeGuardDeadline_isIgnored() {
        let now = Date(timeIntervalSince1970: 1000)
        let guardUntil = Date(timeIntervalSince1970: 1000.35)
        XCTAssertTrue(
            blockSelectTapShouldBeIgnored(now: now, guardUntil: guardUntil),
            "Design-review S4: a tap arriving before the settling deadline — while the " +
            "confirmationDialog/browse-sheet dismiss animations and blockSelectBar's " +
            "appear animation may still be visually in flight — must be ignored, not " +
            "misinterpreted as the user's first deliberate blockface selection."
        )
    }

    func testTapExactlyAtGuardDeadline_isNotIgnored() {
        let deadline = Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(
            blockSelectTapShouldBeIgnored(now: deadline, guardUntil: deadline),
            "The comparison is a strict `now < guardUntil` — a tap landing exactly AT the " +
            "deadline (not before it) is treated as settled, not ignored. Pins the boundary " +
            "condition explicitly so a future off-by-one is a visible diff."
        )
    }

    func testTapAfterGuardDeadline_isNotIgnored() {
        let now = Date(timeIntervalSince1970: 3000.5)
        let guardUntil = Date(timeIntervalSince1970: 3000)
        XCTAssertFalse(
            blockSelectTapShouldBeIgnored(now: now, guardUntil: guardUntil),
            "Once the settling window has elapsed, ordinary block-select taps must be " +
            "processed normally — the guard is a brief entry-only window, not a standing gate."
        )
    }
}

// MARK: - BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight:) Tests
//
// FT-20 Stream C bugfix: live-smoke found two bugs (the peek detent revealing the medium
// action list's first row at cold launch; the whole browse sheet vanishing after visiting
// Parking 101 and panning the map) traced to `BrowseNavigationSheet` reporting degenerate,
// not-yet-measured heights into `ContentView`'s PERSISTENT `browseSheetPeekHeight`/
// `browseSheetMediumHeight` state every time it remounts (any round trip through another
// `ActiveSheet` case resets its own `@State searchAreaHeight` to 0). This guard is what
// `BrowseNavigationSheet.body`'s `.onAppear`/`.onChange` handlers now check before calling
// `reportHeights()` — see `BrowseSheetDetentMath.isGenuineMeasurement`'s doc comment.
final class BrowseSheetDetentMathGenuineMeasurementTests: XCTestCase {

    func testZeroHeight_isNotGenuine() {
        XCTAssertFalse(
            BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: 0),
            "A height of exactly 0 is `BrowseNavigationSheet.searchAreaHeight`'s @State " +
            "default — reachable on every fresh mount, including every remount after " +
            "another ActiveSheet case (Settings, Parking 101, a pin/block tap...) is " +
            "dismissed back to .browseNav. It must never be treated as a real measurement."
        )
    }

    func testNegativeHeight_isNotGenuine() {
        // Defensive: GeometryProxy heights should never be negative in practice, but a
        // degenerate/invalid measurement must not be treated as genuine either.
        XCTAssertFalse(BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: -5))
    }

    func testPositiveHeight_isGenuine() {
        XCTAssertTrue(BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: 1))
        XCTAssertTrue(BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: 68))
    }

    func testVerySmallPositiveHeight_isStillGenuine() {
        // Any positive value, however small, is a REAL GeometryReader report, not the
        // unmeasured placeholder — `BrowseSheetDetentMath.peekHeight`'s own floor
        // (minimumPeekHeight) is what protects against a pathologically short real
        // measurement; this guard's only job is distinguishing "never measured" from
        // "measured."
        XCTAssertTrue(BrowseSheetDetentMath.isGenuineMeasurement(searchAreaHeight: 0.01))
    }
}

// MARK: - grabberAndInsetAllowance / peek-shows-only-search invariant Tests
//
// FT-20 Stream C live-smoke, PR #87 follow-up (2026-08-21): the `isGenuineMeasurement`
// guard above fixed the REMOUNT-churn manifestation of "peek reveals the medium-detent
// action row," but the bug also reproduced on a fresh cold launch, where no remount has
// happened yet — a STEADY-STATE sizing error, not a remount race. Root cause:
// `grabberAndInsetAllowance`'s old value (24) double-counted `BrowseSearchAreaView.
// searchField`'s own `.padding(.vertical, 12)` top inset — once as part of the measured
// `searchAreaHeight` (the height-reporting `GeometryReader` is attached AFTER that
// padding), and again as part of the allowance meant to ALSO cover "the content's own top
// inset." See `BrowseSheetDetentMath.grabberAndInsetAllowance`'s doc comment for the full
// derivation of the fix (24 → 12).
final class BrowseSheetGrabberAllowanceRegressionTests: XCTestCase {

    func testGrabberAndInsetAllowance_noLongerDoubleCountsSearchFieldsOwnTopInset() {
        // Pins the corrected value so a future edit can't silently reintroduce the
        // double-count by creeping the constant back up toward the old 24.
        XCTAssertEqual(
            BrowseSheetDetentMath.grabberAndInsetAllowance, 12,
            "grabberAndInsetAllowance should represent ONLY the system grab-indicator's " +
            "own footprint now that searchField's own top inset is already inside " +
            "searchAreaHeight (BrowseSearchAreaView.swift's GeometryReader is attached " +
            "AFTER .padding(.vertical, 12)) — see the constant's doc comment for the full " +
            "derivation."
        )
    }

    func testPeekHeight_grabberAllowanceStaysASmallSliverOfARealisticSearchField() {
        // Regression guard for the "peek reveals the action row" live-smoke bug at cold
        // launch: the gap between peekHeight and the measured search area must stay a
        // small grabber-only sliver, not balloon back up toward double-counting territory.
        let realisticSearchHeight: CGFloat = 64
        let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: realisticSearchHeight)
        XCTAssertLessThan(
            peek - realisticSearchHeight, 20,
            "The gap between peekHeight and the measured search area should stay a small " +
            "grabber-only sliver (well under the old 24pt figure) — a value creeping back " +
            "up would reintroduce the peek-reveals-the-action-row bug."
        )
    }
}

// MARK: - BrowseSheetDetentMath.actionRowHeight(...) Tests
//
// FT-20 Stream C / Kevin's live-smoke Ruling 1 (spec §0e, 2026-08-21): the medium-detent
// action list's anatomy changed from `List` rows (design-review finding S1, overridden) to
// a horizontal 3-icon row. `actionRowHeight` is the pure, UIKit-free formula
// `BrowseNavigationSheet.actionListHeight` now derives its `.frame(height:)` constraint
// from (icon diameter + icon-label spacing + label line height + top/bottom padding),
// mirroring `peekHeight`/`mediumHeight`'s existing pure-function precedent so it's directly
// unit-testable without a simulator, per this file's own established convention.
final class BrowseSheetActionRowHeightTests: XCTestCase {

    func testActionRowHeight_sumsAllFourComponents() {
        let result = BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: 44,
            iconLabelSpacing: 6,
            labelLineHeight: 16,
            verticalPadding: 12
        )
        // 44 + 6 + 16 + (12 * 2) = 90
        XCTAssertEqual(result, 90)
    }

    func testActionRowHeight_verticalPaddingIsAppliedTwiceForTopAndBottom() {
        let withoutPadding = BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: 44, iconLabelSpacing: 6, labelLineHeight: 16, verticalPadding: 0
        )
        let withPadding = BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: 44, iconLabelSpacing: 6, labelLineHeight: 16, verticalPadding: 12
        )
        XCTAssertEqual(
            withPadding, withoutPadding + 24,
            "verticalPadding represents both top AND bottom, so it must contribute twice " +
            "its value to the total row height."
        )
    }

    func testActionRowHeight_growsWithLargerDynamicTypeInputs() {
        // Simulates the `@ScaledMetric`-driven growth `actionIconDiameter`/
        // `actionLabelLineHeight` would report at a larger Dynamic Type size —
        // `actionRowHeight` itself has no notion of Dynamic Type, only of the values fed
        // in, so this pins that the formula scales monotonically with its inputs.
        let defaultSize = BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: 44, iconLabelSpacing: 6, labelLineHeight: 16, verticalPadding: 12
        )
        let accessibilitySize = BrowseSheetDetentMath.actionRowHeight(
            iconDiameter: 70, iconLabelSpacing: 6, labelLineHeight: 26, verticalPadding: 12
        )
        XCTAssertGreaterThan(
            accessibilitySize, defaultSize,
            "actionRowHeight must grow when its Dynamic-Type-scaled inputs grow — a " +
            "regression here would mean the medium detent stops making room for a larger " +
            "action row at accessibility text sizes, reintroducing a clipped-row class of " +
            "bug (the same class of bug S1's List anatomy shipped with)."
        )
    }

    func testActionRowHeight_zeroInputsProduceZero() {
        // Sanity/degenerate case: all-zero inputs should sum to exactly zero, not some
        // hidden floor — `BrowseSheetDetentMath.peekHeight`'s own `minimumPeekHeight` is
        // what protects the OVERALL peek detent from a pathologically small value; this
        // formula itself has no independent floor.
        XCTAssertEqual(
            BrowseSheetDetentMath.actionRowHeight(
                iconDiameter: 0, iconLabelSpacing: 0, labelLineHeight: 0, verticalPadding: 0
            ),
            0
        )
    }
}

// MARK: - BrowseSheetSearchAreaHeightPreferenceKey Tests
//
// QA pass 1 on PR #87 flagged the C1 preference-key mechanism as shipping with zero
// regression coverage. These pin `defaultValue` and `reduce`'s documented behavior
// directly, including the zero-value and multiple-probe cases the live-smoke bug report
// specifically asked to be checked.
final class BrowseSheetSearchAreaHeightPreferenceKeyTests: XCTestCase {

    func testDefaultValue_isZero() {
        XCTAssertEqual(
            BrowseSheetSearchAreaHeightPreferenceKey.defaultValue, 0,
            "The default (no reporter in the tree yet) must be 0 — the value " +
            "`BrowseNavigationSheet`'s `isGenuineMeasurement` guard treats as unmeasured."
        )
    }

    func testReduce_withNoPriorValue_takesTheReportedValue() {
        var value = BrowseSheetSearchAreaHeightPreferenceKey.defaultValue
        BrowseSheetSearchAreaHeightPreferenceKey.reduce(value: &value) { 68 }
        XCTAssertEqual(value, 68)
    }

    func testReduce_withZeroNextValue_producesZero() {
        // The exact scenario behind the live bug: a reduce pass where the reporter's
        // subtree is momentarily absent/unmeasured (e.g. mid-remount) and reports back to
        // the PreferenceKey's own defaultValue (0).
        var value: CGFloat = 68
        BrowseSheetSearchAreaHeightPreferenceKey.reduce(value: &value) { 0 }
        XCTAssertEqual(
            value, 0,
            "reduce takes the newest report unconditionally (documented 'last write wins' " +
            "behavior) — a reporter that (re)fires with 0 legitimately zeroes out the " +
            "accumulated value. This is why the degenerate-value protection lives in " +
            "`BrowseNavigationSheet`'s call sites (`isGenuineMeasurement`), not in this " +
            "PreferenceKey — reduce itself has no notion of 'ignore this report.'"
        )
    }

    func testReduce_withMultipleContributingProbes_takesTheLastOne() {
        // Only one reporter exists in production today (`searchField`'s own `.background`
        // probe — confirmed by grep, see BrowseNavigationSheet.swift's doc comment), but
        // `reduce` must be `PreferenceKey`-protocol-total for however many probes SwiftUI
        // ends up combining. This pins "last write wins" — NOT max/sum — so a future
        // second reporter (an accidental duplicate, or an intentional future addition)
        // gets a well-understood, tested combination rule rather than silent misbehavior.
        var value = BrowseSheetSearchAreaHeightPreferenceKey.defaultValue
        BrowseSheetSearchAreaHeightPreferenceKey.reduce(value: &value) { 40 }
        BrowseSheetSearchAreaHeightPreferenceKey.reduce(value: &value) { 68 }
        BrowseSheetSearchAreaHeightPreferenceKey.reduce(value: &value) { 12 }
        XCTAssertEqual(
            value, 12,
            "reduce is 'take the newest report' (last-write-wins), not max/sum — pinned so " +
            "a future change to this combination rule is a deliberate, visible diff."
        )
    }
}

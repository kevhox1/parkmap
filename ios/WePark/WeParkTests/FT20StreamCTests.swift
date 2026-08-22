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
import SwiftUI
import MapKit
import CoreLocation
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

// MARK: - grabberAndInsetAllowance — REMOVED 2026-08-21 (spec §0f)
//
// FT-20 Stream C live-smoke, PR #87 follow-up: `BrowseSheetGrabberAllowanceRegressionTests`
// used to pin `grabberAndInsetAllowance == 12` and "the gap between peekHeight and the
// measured search area stays a small grabber-only sliver." Both tests PASSED on the `12`
// fix, and Kevin's THIRD live smoke still found "the three buttons are peaking" — i.e.
// these tests were pinning a formula that was still wrong, not catching the regression.
// `grabberAndInsetAllowance` is deleted, not re-tuned to a third guessed value — see
// `BrowseSheetDetentMath`'s doc comment (the constant's removal note, kept in place of the
// deleted declaration) for the full root-cause writeup. The REPLACEMENT invariant coverage
// — "peek can never reach the action content, for ANY input, by construction" — lives in
// `FT20StreamATests.swift`'s `BrowseSheetPeekInvariantTests`, which is deliberately a
// top-level suite (not scoped to one constant) so it can't be quietly narrowed again.

// MARK: - BrowseSheetDetentMath.actionColumnHeight(...) Tests
//
// FT-20 Stream C / Kevin's THIRD live-smoke ruling (spec §0f, 2026-08-21): the medium-
// detent action content's anatomy changed AGAIN — from the horizontal 3-icon row (§0e
// Ruling 1, itself already a replacement for design-review finding S1's `List` rows) to
// one primary "Find a Spot" button + one tertiary "New to parking?" link, a vertical
// column. `actionRowHeight` (§0e) is renamed `actionColumnHeight` (§0f) to match — this is
// an internal Swift API name, not a user-visible string or one of the identifiers Kevin's
// §0f Ruling 2 explicitly protects (`enterCruiseMode()`/`driveModeStyle`/`.cruise`), so
// renaming it to track the anatomy it now describes is in scope. `actionColumnHeight` is
// the pure, UIKit-free formula `BrowseNavigationSheet.actionColumnHeight` now derives its
// `.frame(height:)` constraint from (primary-button label height + button's own vertical
// padding×2 + column spacing + link label height + column's own vertical padding×2),
// mirroring `peekHeight`/`mediumHeight`'s existing pure-function precedent so it's directly
// unit-testable without a simulator, per this file's own established convention.
final class BrowseSheetActionColumnHeightTests: XCTestCase {

    func testActionColumnHeight_sumsAllComponents() {
        let result = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22,
            primaryButtonVerticalPadding: 14,
            columnSpacing: 10,
            linkLineHeight: 18,
            columnVerticalPadding: 12
        )
        // primaryButtonHeight = 22 + (14 * 2) = 50
        // total = 50 + 10 + 18 + (12 * 2) = 102
        XCTAssertEqual(result, 102)
    }

    func testActionColumnHeight_primaryButtonPaddingIsAppliedTwiceForTopAndBottom() {
        let withoutPadding = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22, primaryButtonVerticalPadding: 0,
            columnSpacing: 10, linkLineHeight: 18, columnVerticalPadding: 12
        )
        let withPadding = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22, primaryButtonVerticalPadding: 14,
            columnSpacing: 10, linkLineHeight: 18, columnVerticalPadding: 12
        )
        XCTAssertEqual(
            withPadding, withoutPadding + 28,
            "primaryButtonVerticalPadding represents both top AND bottom of the button " +
            "itself, so it must contribute twice its value to the total column height."
        )
    }

    func testActionColumnHeight_columnPaddingIsAppliedTwiceForTopAndBottom() {
        let withoutPadding = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22, primaryButtonVerticalPadding: 14,
            columnSpacing: 10, linkLineHeight: 18, columnVerticalPadding: 0
        )
        let withPadding = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22, primaryButtonVerticalPadding: 14,
            columnSpacing: 10, linkLineHeight: 18, columnVerticalPadding: 12
        )
        XCTAssertEqual(
            withPadding, withoutPadding + 24,
            "columnVerticalPadding represents both top AND bottom of the WHOLE column, " +
            "so it must contribute twice its value to the total column height."
        )
    }

    func testActionColumnHeight_growsWithLargerDynamicTypeInputs() {
        // Simulates the `@ScaledMetric`-driven growth `primaryButtonLabelLineHeight`/
        // `linkLineHeight` would report at a larger Dynamic Type size —
        // `actionColumnHeight` itself has no notion of Dynamic Type, only of the values
        // fed in, so this pins that the formula scales monotonically with its inputs.
        let defaultSize = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 22, primaryButtonVerticalPadding: 14,
            columnSpacing: 10, linkLineHeight: 18, columnVerticalPadding: 12
        )
        let accessibilitySize = BrowseSheetDetentMath.actionColumnHeight(
            primaryButtonLabelLineHeight: 44, primaryButtonVerticalPadding: 14,
            columnSpacing: 10, linkLineHeight: 32, columnVerticalPadding: 12
        )
        XCTAssertGreaterThan(
            accessibilitySize, defaultSize,
            "actionColumnHeight must grow when its Dynamic-Type-scaled inputs grow — a " +
            "regression here would mean the medium detent stops making room for a larger " +
            "action column at accessibility text sizes, reintroducing a clipped-content " +
            "class of bug (the same class of bug S1's List anatomy shipped with)."
        )
    }

    func testActionColumnHeight_zeroInputsProduceZero() {
        // Sanity/degenerate case: all-zero inputs should sum to exactly zero, not some
        // hidden floor — `BrowseSheetDetentMath.peekHeight`'s own floor/clamp logic is
        // what protects the OVERALL peek detent from a pathologically small value; this
        // formula itself has no independent floor.
        XCTAssertEqual(
            BrowseSheetDetentMath.actionColumnHeight(
                primaryButtonLabelLineHeight: 0, primaryButtonVerticalPadding: 0,
                columnSpacing: 0, linkLineHeight: 0, columnVerticalPadding: 0
            ),
            0
        )
    }
}

// MARK: - BrowseSheetSearchAreaHeightPreferenceKey Tests — REMOVED 2026-08-22 (PR #87 round 5)
//
// QA pass 1 on PR #87 flagged the C1 preference-key mechanism as shipping with zero
// regression coverage; the class that used to live here (`BrowseSheetSearchAreaHeightPreferenceKeyTests`)
// was added in response, pinning `BrowseSheetSearchAreaHeightPreferenceKey.defaultValue`/`.reduce`'s
// behavior directly.
//
// ⚠️ Those tests were WRONG in a way worth recording rather than quietly deleting: they
// called `reduce` directly with hand-fed values and asserted the exact "last write wins"
// behavior (`testReduce_withZeroNextValue_producesZero`,
// `testReduce_withMultipleContributingProbes_takesTheLastOne`) as CORRECT, INTENTIONAL
// design — reasoning that degenerate-value protection belonged in `BrowseNavigationSheet`'s
// `isGenuineMeasurement` guard, not in `reduce` itself. That reasoning missed the actual bug:
// SwiftUI calls `reduce` once per SIBLING BRANCH in the observed subtree, including branches
// that never call `.preference(key:value:)` explicitly (they implicitly contribute
// `defaultValue`) — a fact no amount of hand-feeding `reduce` in isolation can exercise, since
// it's about how many times and in what order the LIVE VIEW TREE causes SwiftUI to invoke
// `reduce`, not about `reduce`'s own per-call logic. On a real device, this file's `#if
// DEBUG` `.overlay` (a defaultValue-contributing sibling once attached) silently zeroed out
// `searchField`'s real report on some layout passes — see
// `BrowseNavigationSheet.swift`'s removed-`PreferenceKey` doc comment (just below
// `BrowseSheetDetentKind`) for the full root-cause writeup and citations.
//
// The `PreferenceKey` this class tested no longer exists — `searchField` reports its height
// via `.onGeometryChange` now, which has no `reduce`/cross-tree-aggregation step to test.
// Replacement coverage, exercising the ACTUAL mechanism (not hand-fed values in isolation),
// is `SearchFieldHeightMeasurementTests` below.

// MARK: - Search-field height measurement Tests (PR #87 round 5)
//
// Exercises the REPLACEMENT mechanism end to end: `BrowseSearchAreaView.searchField`'s real
// `.onGeometryChange` firing through an actual (headless) SwiftUI layout pass — not a
// hand-fed value — feeding into `BrowseSheetDetentMath.peekHeight`'s existing "fully
// contains the search field" invariant (already covered at the pure-math level by
// `FT20StreamATests.swift`'s `BrowseSheetPeekInvariantTests
// .testPeekHeight_fullyContainsTheSearchArea_acrossRealisticDynamicTypeRange`; this suite's
// job is closing the gap THAT test can't cover — "does a real measurement ever reach the
// math in the first place," which is exactly where round 1–4's bug lived).
//
// [COMPILE-UNVERIFIED / NEEDS ON-MAC XCTEST CONFIRMATION] `UIHostingController` +
// `layoutIfNeeded()` off a live window is a commonly-used pattern for forcing SwiftUI
// `GeometryReader`/`.onGeometryChange` effects to fire in XCTest, but this machine has no
// Xcode/simulator to confirm it actually fires synchronously here — if it doesn't, Kevin/QA
// will see this fail on first run on the Mac, not silently pass while testing nothing.
@MainActor
final class SearchFieldHeightMeasurementTests: XCTestCase {

    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    func testSearchField_onGeometryChange_reportsANonZeroHeight() {
        var reportedHeight: CGFloat = 0
        let view = BrowseSearchAreaView(
            currentRegion: region,
            segments: [],
            userLocation: nil,
            locationService: LocationService(),
            detentKind: .constant(.peek),
            onRouteReady: { _, _ in },
            onSearchFieldHeightChange: { reportedHeight = $0 }
        )
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        XCTAssertGreaterThan(
            reportedHeight, 0,
            "This is the exact regression round 5 fixes: a fully-rendered search field " +
            "(non-zero on screen) must report a non-zero measured height. `searchH: 0.0` " +
            "on a real device with the field visibly rendered was the round-4 bug report " +
            "this test guards against — see BrowseNavigationSheet.swift's removed-" +
            "PreferenceKey doc comment."
        )
    }

    func testSearchField_realMeasurement_producesAPeekHeightThatFullyContainsIt() {
        var reportedHeight: CGFloat = 0
        let view = BrowseSearchAreaView(
            currentRegion: region,
            segments: [],
            userLocation: nil,
            locationService: LocationService(),
            detentKind: .constant(.peek),
            onRouteReady: { _, _ in },
            onSearchFieldHeightChange: { reportedHeight = $0 }
        )
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Only meaningful once we know a real measurement actually arrived — otherwise
        // this degenerates into the pure-math test `BrowseSheetPeekInvariantTests` already
        // covers with a hardcoded input, which proves nothing new about the mechanism.
        XCTAssertGreaterThan(reportedHeight, 0, "Precondition: a real measurement must land first.")

        let peek = BrowseSheetDetentMath.peekHeight(searchAreaHeight: reportedHeight)
        XCTAssertGreaterThanOrEqual(
            peek, reportedHeight,
            "A realistic, ACTUALLY-MEASURED (not hand-picked) search field height must " +
            "produce a peek detent tall enough to fully contain the field — the exact " +
            "property `BrowseSheetDetentMath.peekBreathingRoom` exists to guarantee."
        )
    }
}

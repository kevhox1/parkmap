//
//  LongPressParkPopupTests.swift
//  WeParkTests
//
//  Open item #17 (2026-09-11, S13c gate) — two independent fixes to the resting
//  long-press popup:
//    (a) the "first attempt always dismisses immediately, second attempt stays up" bug
//        (`MapViewRepresentable.Coordinator.handleLongPress` now fires on `.ended`, not
//        `.began`) — pure UIKit gesture-recognizer state-machine behavior. `UIGestureRecognizer
//        .state` is get-only, settable only via live touch injection, so it cannot be driven
//        from an XCTest unit test without a running app + real/synthetic touches. No test is
//        added for (a); it is gesture plumbing, verified live instead (see PR test plan).
//    (b) `communityEnabled == true` slims the popup to a single-purpose park-confirm card
//        (`LongPressParkConfirmCard`); `communityEnabled == false` keeps the legacy
//        three-button confirmationDialog byte-identical. The only genuinely pure,
//        unit-testable surface of (b) is the flag fork itself
//        (`ContentView.longPressPresentationMode(communityEnabled:)`) — tested below, same
//        "extract the decision, test the decision" pattern as
//        `CommunityS13aTests.CommunityMapChromeVisibleTests`.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (2 tests):
//    1. testPresentationMode_flagOff_returnsLegacyThreeButtonDialog
//    2. testPresentationMode_flagOn_returnsParkConfirmCard
//
//  Open item #17 residual (2026-09-11, core-parking-16 session): the tentative "car will go
//  here" marker at the long-press point. `ContentView.pendingParkPinCoordinate(communityEnabled:
//  pendingLongPressCoord:)` is the pure gate that keeps `MapViewRepresentable
//  .pendingParkCoordinate` `nil` for flag-off builds even though `pendingLongPressCoord` is
//  ALSO set (unconditionally) by the legacy three-button-dialog long-press flow — see that
//  function's own doc comment. `ContentView.pendingParkPinCoordinateTests` below covers all 4
//  flag × coordinate-presence combinations.
//

import CoreLocation
import XCTest
@testable import WePark

final class LongPressPresentationModeTests: XCTestCase {

    /// Flag off: the legacy three-button confirmationDialog is the ONLY report entry point
    /// for flag-off users — must never be replaced or slimmed.
    func testPresentationMode_flagOff_returnsLegacyThreeButtonDialog() {
        XCTAssertEqual(
            ContentView.longPressPresentationMode(communityEnabled: false),
            .legacyThreeButtonDialog
        )
    }

    /// Flag on: reporting has its own dedicated entry (S13a Report pill + grid), so the
    /// resting long-press slims to the park-confirm card.
    func testPresentationMode_flagOn_returnsParkConfirmCard() {
        XCTAssertEqual(
            ContentView.longPressPresentationMode(communityEnabled: true),
            .parkConfirmCard
        )
    }
}

// MARK: - pendingParkPinCoordinate (open item #17 residual, 2026-09-11)

final class PendingParkPinCoordinateTests: XCTestCase {

    private let coord = CLLocationCoordinate2D(latitude: 40.7186, longitude: -73.9941)

    /// Flag off + a coordinate present (the legacy dialog DOES set `pendingLongPressCoord`) —
    /// must still return `nil`. This is the exact scenario the function exists to guard:
    /// flag-off long-press must stay byte-identical, with no tentative marker ever drawn.
    func testFlagOff_coordinatePresent_returnsNil() {
        XCTAssertNil(
            ContentView.pendingParkPinCoordinate(communityEnabled: false, pendingLongPressCoord: coord)
        )
    }

    func testFlagOff_noCoordinate_returnsNil() {
        XCTAssertNil(
            ContentView.pendingParkPinCoordinate(communityEnabled: false, pendingLongPressCoord: nil)
        )
    }

    func testFlagOn_coordinatePresent_passesThrough() {
        let result = ContentView.pendingParkPinCoordinate(communityEnabled: true, pendingLongPressCoord: coord)
        XCTAssertEqual(result?.latitude, coord.latitude)
        XCTAssertEqual(result?.longitude, coord.longitude)
    }

    func testFlagOn_noCoordinate_returnsNil() {
        XCTAssertNil(
            ContentView.pendingParkPinCoordinate(communityEnabled: true, pendingLongPressCoord: nil)
        )
    }
}

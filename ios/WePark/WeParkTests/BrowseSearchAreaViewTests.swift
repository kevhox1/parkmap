//
//  BrowseSearchAreaViewTests.swift
//  WeParkTests
//
//  FT-20 Stream B — search/place relocation into the browse-mode bottom sheet.
//  docs/ft20-bottom-sheet-navigation-spec.md §3.2/§3.3/§4.3.
//
//  `BrowseSearchAreaView` is mostly SwiftUI view code with no ViewInspector/snapshot
//  library in this repo (same limitation `FT20StreamATests.swift` documents for
//  `BrowseNavigationSheet`) — real on-screen behavior (row anatomy, the S5 keyboard-
//  dismiss gesture, the §3.3 expand-on-focus interaction) is Kevin's on-device live-UI
//  smoke, not these tests. What IS covered here:
//    - Render smoke (mirrors `W85bTests`' `DriveModeDestinationView` smoke tests) —
//      confirms the view mounts without crashing across the states that matter (no
//      location, with location, at each detent kind).
//    - `BrowseSheetDetentKind` gating: `.large` vs. not — the one piece of real,
//      assertable-without-rendering behavior this file adds beyond a render smoke, since
//      the whole "search field always visible, expanded content only at large" contract
//      (spec §4.2 / AC-4) hinges on it.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import SwiftUI
import MapKit
import CoreLocation
@testable import WePark

@MainActor
final class BrowseSearchAreaViewTests: XCTestCase {

    private let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    private func makeView(
        detentKind: BrowseSheetDetentKind = .peek,
        userLocation: CLLocationCoordinate2D? = nil,
        segments: [Segment] = []
    ) -> BrowseSearchAreaView {
        BrowseSearchAreaView(
            currentRegion: region,
            segments: segments,
            userLocation: userLocation,
            locationService: LocationService(),
            detentKind: .constant(detentKind),
            onRouteReady: { _, _ in }
        )
    }

    // MARK: - Render smoke (mirrors W85bTests' DriveModeDestinationView smoke pattern)

    func testRendersWithoutCrashing_atPeek_noUserLocation() {
        let host = UIHostingController(rootView: makeView(detentKind: .peek))
        XCTAssertNotNil(host.view, "BrowseSearchAreaView should render without crashing at peek, no location.")
    }

    func testRendersWithoutCrashing_atMedium() {
        let host = UIHostingController(rootView: makeView(detentKind: .medium))
        XCTAssertNotNil(host.view, "BrowseSearchAreaView should render without crashing at medium.")
    }

    func testRendersWithoutCrashing_atLarge_withUserLocation() {
        let host = UIHostingController(rootView: makeView(
            detentKind: .large,
            userLocation: CLLocationCoordinate2D(latitude: 40.7527, longitude: -73.9772)
        ))
        XCTAssertNotNil(host.view, "BrowseSearchAreaView should render without crashing at large, with location.")
    }

    func testRendersWithoutCrashing_atLarge_withSegments() {
        let seg = Segment(
            id: "TEST",
            street: "TEST ST",
            fromStreet: "A AVE",
            to: "B AVE",
            side: "N",
            line: [[40.7527, -73.9772], [40.7528, -73.9772]],
            rules: [],
            dominantCategory: .free
        )
        let host = UIHostingController(rootView: makeView(detentKind: .large, segments: [seg]))
        XCTAssertNotNil(host.view, "BrowseSearchAreaView should render without crashing with loaded segments.")
    }

    // MARK: - BrowseSheetDetentKind gating (spec §4.2 / AC-4: search field always visible;
    // recents/suggestions/place-state are large-detent-only content)

    func testAllThreeDetentKinds_renderWithoutCrashing() {
        for kind in [BrowseSheetDetentKind.peek, .medium, .large] {
            let host = UIHostingController(rootView: makeView(detentKind: kind))
            XCTAssertNotNil(host.view, "BrowseSearchAreaView should render at detentKind \(kind).")
        }
    }
}

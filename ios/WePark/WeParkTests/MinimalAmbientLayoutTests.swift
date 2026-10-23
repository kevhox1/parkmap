//
//  MinimalAmbientLayoutTests.swift
//  WeParkTests
//
//  Addendum 3 (`docs/design/goal-first-ambient-design.md`, "minimal ambient screen", layout half
//  A3.1-A3.5) — unit tests for the new pure decision functions behind the flag-on ambient
//  screen's rail, More sheet, and floating-chrome suppression:
//    - `ambientRecenterButtonVisible` — the rail's conditional third circle (A3.2 / flag #5:
//      "Recenter's off-center test belongs in a small pure function with a unit test").
//    - `moreMenuVisibleRows` / `MoreMenuRow` — the More sheet's row gating and copy (A3.4).
//    - `ContentView.communityMapFloatingChromeVisible` — Report + "?" floating-layer
//      suppression flag-on, with flag-off equivalence to the pre-Addendum-3 formula (A3.4).
//    - `ActiveSheet.moreMenu` — id uniqueness and rest-state behavior.
//  The flag-off guards for the rail / dock / sheets that are pure SwiftUI layout (not callable
//  from a test) are verified by code inspection + the live smoke, same disclosure
//  `DM2GoalSelectorTests` makes for the Search icon; `DriveModeDefaultFlagTests` carries the
//  Addendum 3 flag-off guard tests for the pure gates.
//
//  `nonisolated`-pure functions only are called from these synchronous tests (project default
//  actor isolation is MainActor). `WePark.Category` is not referenced here.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
import MapKit
@testable import WePark

final class MinimalAmbientLayoutTests: XCTestCase {

    // MARK: - Fixtures

    /// Visible region centered on (40.75, -73.98) spanning 0.01 deg lat x 0.008 deg lng.
    /// Central 50% = +/-0.0025 lat, +/-0.002 lng from center.
    private let regionCenter = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.98)
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: regionCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
    }

    private func user(latOffset: Double = 0, lngOffset: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: regionCenter.latitude + latOffset,
            longitude: regionCenter.longitude + lngOffset
        )
    }

    // MARK: - ambientRecenterButtonVisible (A3.2)

    func testRecenter_authorized_userAtCenter_hidden() {
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: user(), visibleRegion: region
        ), "A3.2: Recenter is absent while centered on the user.")
    }

    func testRecenter_authorized_userInsideCentralHalf_hidden() {
        // 0.0024 < 0.0025 (lat quarter-span), 0.0019 < 0.002 (lng quarter-span).
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedAlways,
            userLocation: user(latOffset: 0.0024, lngOffset: -0.0019),
            visibleRegion: region
        ))
    }

    func testRecenter_authorized_userOutsideCentralHalf_latitude_shows() {
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse,
            userLocation: user(latOffset: 0.0026),
            visibleRegion: region
        ), "A3.2: shows once the dot is outside the central 50% on the latitude axis.")
    }

    func testRecenter_authorized_userOutsideCentralHalf_longitude_shows() {
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse,
            userLocation: user(lngOffset: -0.0021),
            visibleRegion: region
        ), "A3.2: shows once the dot is outside the central 50% on the longitude axis.")
    }

    func testRecenter_authorized_panAwayFarFromUser_shows() {
        // The user panned the map ~0.05 deg north; their dot is now far off-screen.
        let pannedRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.80, longitude: -73.98),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: user(), visibleRegion: pannedRegion
        ), "A3.2: Recenter appears only after the user pans away.")
    }

    func testRecenter_authorized_afterRecenterOnUser_hidesAgain() {
        // `recenterMap(on:)` sets a 400m street-level region centered on the user.
        let recentered = MKCoordinateRegion(
            center: user(),
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: user(), visibleRegion: recentered
        ))
    }

    func testRecenter_authorized_noFix_hidden() {
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: nil, visibleRegion: region
        ), "no fix means no dot to return to.")
    }

    func testRecenter_notDetermined_alwaysShows() {
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .notDetermined, userLocation: nil, visibleRegion: region
        ), "A3.2(b): it is the route to the permission prompt.")
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .notDetermined, userLocation: user(), visibleRegion: region
        ))
    }

    func testRecenter_deniedOrRestricted_hiddenEvenWhenFarAway() {
        let far = user(latOffset: 1.0, lngOffset: 1.0)
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .denied, userLocation: far, visibleRegion: region
        ))
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .restricted, userLocation: far, visibleRegion: region
        ))
    }

    // MARK: - moreMenuVisibleRows (A3.4 "Shown when" column)

    func testMoreRows_everythingOn_priorityOrder() {
        XCTAssertEqual(
            moreMenuVisibleRows(communityEnabled: true, hasParkedCar: true, fullPaletteMode: true),
            [.report, .mapKey, .showAllRules, .findMyCar, .parkUntil]
        )
    }

    func testMoreRows_minimal_alwaysRowsOnly() {
        XCTAssertEqual(
            moreMenuVisibleRows(communityEnabled: false, hasParkedCar: false, fullPaletteMode: false),
            [.mapKey, .showAllRules],
            "What the colors mean and Show all parking rules are always shown."
        )
    }

    func testMoreRows_reportRequiresCommunityFlag() {
        XCTAssertTrue(moreMenuVisibleRows(
            communityEnabled: true, hasParkedCar: false, fullPaletteMode: false
        ).contains(.report))
        XCTAssertFalse(moreMenuVisibleRows(
            communityEnabled: false, hasParkedCar: true, fullPaletteMode: true
        ).contains(.report))
    }

    func testMoreRows_findMyCarRequiresParkedCar() {
        XCTAssertTrue(moreMenuVisibleRows(
            communityEnabled: false, hasParkedCar: true, fullPaletteMode: false
        ).contains(.findMyCar))
        XCTAssertFalse(moreMenuVisibleRows(
            communityEnabled: true, hasParkedCar: false, fullPaletteMode: true
        ).contains(.findMyCar))
    }

    func testMoreRows_parkUntilRequiresFullPaletteMode() {
        XCTAssertTrue(moreMenuVisibleRows(
            communityEnabled: false, hasParkedCar: false, fullPaletteMode: true
        ).contains(.parkUntil))
        XCTAssertFalse(moreMenuVisibleRows(
            communityEnabled: true, hasParkedCar: true, fullPaletteMode: false
        ).contains(.parkUntil))
    }

    func testMoreRows_showAllRulesAndMapKey_presentInEveryCombination() {
        for community in [true, false] {
            for parked in [true, false] {
                for palette in [true, false] {
                    let rows = moreMenuVisibleRows(
                        communityEnabled: community, hasParkedCar: parked, fullPaletteMode: palette
                    )
                    XCTAssertTrue(rows.contains(.mapKey))
                    XCTAssertTrue(rows.contains(.showAllRules))
                }
            }
        }
    }

    func testMoreRows_reportIsFirstWhenShown() {
        let rows = moreMenuVisibleRows(communityEnabled: true, hasParkedCar: true, fullPaletteMode: true)
        XCTAssertEqual(rows.first, MoreMenuRow.report, "A3.4: Report is row 1.")
    }

    // MARK: - MoreMenuRow copy (A3.4 table, verbatim)

    func testMoreRowCopy_matchesAddendumTable() {
        XCTAssertEqual(MoreMenuRow.report.title, "Report")
        XCTAssertEqual(MoreMenuRow.report.subtitle, "Tell neighbors what you see")
        XCTAssertEqual(MoreMenuRow.report.symbolName, "flag.fill")

        XCTAssertEqual(MoreMenuRow.mapKey.title, "What the colors mean")
        XCTAssertEqual(MoreMenuRow.mapKey.subtitle, "Green, red, and the rest")
        XCTAssertEqual(MoreMenuRow.mapKey.symbolName, "questionmark.circle.fill")

        XCTAssertEqual(MoreMenuRow.showAllRules.title, "Show all parking rules")
        XCTAssertEqual(MoreMenuRow.showAllRules.subtitle, "See every kind of rule, not just one goal")
        XCTAssertEqual(MoreMenuRow.showAllRules.symbolName, "paintpalette.fill")

        XCTAssertEqual(MoreMenuRow.findMyCar.title, "Find my car")
        XCTAssertEqual(MoreMenuRow.findMyCar.subtitle, "Show where you parked")
        XCTAssertEqual(MoreMenuRow.findMyCar.symbolName, "car.fill")

        XCTAssertEqual(MoreMenuRow.parkUntil.title, "Park until a set time")
        XCTAssertEqual(MoreMenuRow.parkUntil.subtitle, "Pick your own time")
        XCTAssertEqual(MoreMenuRow.parkUntil.symbolName, "clock.fill")
    }

    // MARK: - communityMapFloatingChromeVisible (A3.4 suppression)

    func testFloatingChrome_flagOn_neverRenders() {
        XCTAssertFalse(ContentView.communityMapFloatingChromeVisible(
            chromeVisible: true, driveModeDefaultEnabled: true
        ), "A3.4: Report and \"?\" live in More flag-on, so the floating layer is suppressed.")
        XCTAssertFalse(ContentView.communityMapFloatingChromeVisible(
            chromeVisible: false, driveModeDefaultEnabled: true
        ))
    }

    func testFloatingChrome_flagOff_passesThroughUnchanged() {
        XCTAssertTrue(ContentView.communityMapFloatingChromeVisible(
            chromeVisible: true, driveModeDefaultEnabled: false
        ))
        XCTAssertFalse(ContentView.communityMapFloatingChromeVisible(
            chromeVisible: false, driveModeDefaultEnabled: false
        ))
    }

    // MARK: - ActiveSheet.moreMenu

    func testMoreMenuSheetId_isStable() {
        XCTAssertEqual(ActiveSheet.moreMenu.id, "moreMenu")
    }

    func testMoreMenuSheetId_doesNotCollideWithOtherCases() {
        let ids: Set<String> = [
            ActiveSheet.moreMenu.id,
            ActiveSheet.mapKeyLegend.id,
            ActiveSheet.browseNav.id,
            ActiveSheet.settings.id,
            ActiveSheet.parkUntil.id,
            ActiveSheet.identityPrompt.id,
            ActiveSheet.parkingGuide.id,
            ActiveSheet.notificationRationale.id,
        ]
        XCTAssertEqual(ids.count, 8)
    }

    func testRestState_isNeverTheMoreMenu() {
        // Dismissing More (Done / swipe) must land on the ambient rest state, not re-open it.
        XCTAssertNil(driveModeDefaultRestStateSheet(driveModeDefaultEnabled: true))
        switch driveModeDefaultRestStateSheet(driveModeDefaultEnabled: false) {
        case .browseNav:
            break
        default:
            XCTFail("flag off must still rest on .browseNav")
        }
    }
}

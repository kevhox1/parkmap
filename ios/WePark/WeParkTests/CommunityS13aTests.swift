//
//  CommunityS13aTests.swift
//  WeParkTests
//
//  Community 2.0 S13a (build 20) — map chrome parity: persistent Report pill, "?" map-key
//  legend, zone-boundary overlay.
//  Spec: docs/design/community-2.0-hero-gap-inventory.md WP1 + WP2 +
//  docs/community-2.0-roadmap.md S13a row + locked decision #6.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (19 tests):
//    MapKeyLegendView content — curb colors VERBATIM, live pins match the shipped marker set:
//      1. testCurbColorEntries_count
//      2. testCurbColorEntries_red_matchesPrototypeVerbatim
//      3. testCurbColorEntries_orange_matchesPrototypeVerbatim
//      4. testCurbColorEntries_amber_matchesPrototypeVerbatim
//      5. testCurbColorEntries_green_matchesPrototypeVerbatim
//      6. testCurbColorEntries_gray_matchesPrototypeVerbatim
//      7. testCurbColorEntries_colorsMatchParkingColorsConstants
//      8. testLivePinEntries_count
//      9. testLivePinEntries_labelsMatchShippedMarkerSet
//      10. testLivePinEntries_noConstructionOrBlockNoteRow_notRenderedOnMap
//      11. testFooterText_doesNotClaimPulseAnimation
//
//    ContentView.communityMapChromeVisible — Report pill / "?" button gating, both flag
//    states + every mode-exclusion:
//      12. testChromeVisible_flagOff_alwaysHidden
//      13. testChromeVisible_flagOn_noModesActive_visible
//      14. testChromeVisible_flagOn_driveModeActive_hidden
//      15. testChromeVisible_flagOn_blockSelectModeActive_hidden
//      16. testChromeVisible_flagOn_spotPlacementActive_hidden
//
//    ContentView.resolveHomeZoneId — zone-overlay home-zone-label selection priority:
//      17. testResolveHomeZoneId_parkedCarWins_evenWhenViewportInDifferentZone
//      18. testResolveHomeZoneId_noParkedCar_fallsBackToViewportCenter
//      19. testResolveHomeZoneId_neitherResolves_returnsNil
//
//    MapViewRepresentable zone-boundary pure helpers — boxes → overlay specs:
//      20. testZoneBoundaryCoordinates_fourCornersInBoxOrder
//      21. testZoneLabelCoordinate_insetFromTopLeftCorner_staysInsideBox
//      22. testZoneDisplayName_knownZones
//      23. testZoneDisplayName_unknownZone_fallsBackToUppercasedId
//      24. testCommunityZoneIds_matchesSeededZones
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - MapKeyLegendView content

final class MapKeyLegendViewContentTests: XCTestCase {

    func testCurbColorEntries_count() {
        XCTAssertEqual(MapKeyLegendView.curbColorEntries.count, 5,
            "design/prototype.html's legend array has exactly 5 rows")
    }

    func testCurbColorEntries_red_matchesPrototypeVerbatim() {
        let entry = MapKeyLegendView.curbColorEntries.first { $0.name == "Red" }
        XCTAssertEqual(entry?.description, "a restriction is active right now")
    }

    func testCurbColorEntries_orange_matchesPrototypeVerbatim() {
        let entry = MapKeyLegendView.curbColorEntries.first { $0.name == "Orange" }
        XCTAssertEqual(entry?.description, "free now, but a restriction starts within 6 hours")
    }

    func testCurbColorEntries_amber_matchesPrototypeVerbatim() {
        let entry = MapKeyLegendView.curbColorEntries.first { $0.name == "Amber" }
        XCTAssertEqual(entry?.description, "metered — pay or move")
    }

    func testCurbColorEntries_green_matchesPrototypeVerbatim() {
        let entry = MapKeyLegendView.curbColorEntries.first { $0.name == "Green" }
        XCTAssertEqual(entry?.description, "free right now, nothing posted near-term")
    }

    func testCurbColorEntries_gray_matchesPrototypeVerbatim() {
        let entry = MapKeyLegendView.curbColorEntries.first { $0.name == "Gray" }
        XCTAssertEqual(entry?.description, "no data — the sign on the pole is the only truth")
    }

    /// Colors must reuse the sacred `ParkingColors` constants — never a one-off literal
    /// that could silently drift from the actual map palette.
    func testCurbColorEntries_colorsMatchParkingColorsConstants() {
        let byName = Dictionary(uniqueKeysWithValues: MapKeyLegendView.curbColorEntries.map { ($0.name, $0.color) })
        XCTAssertEqual(byName["Red"], ParkingColors.restricted)
        XCTAssertEqual(byName["Orange"], ParkingColors.restrictionComingSoon)
        XCTAssertEqual(byName["Amber"], ParkingColors.meteredActive)
        XCTAssertEqual(byName["Green"], ParkingColors.freeComfortably)
        XCTAssertEqual(byName["Gray"], ParkingColors.unknown)
    }

    func testLivePinEntries_count() {
        XCTAssertEqual(MapKeyLegendView.livePinEntries.count, 4,
            "the legend must describe exactly the 4 pin types the map actually renders as markers (enforcement, sweeper, leaving-soon, open-spot) — not the prototype's 6-row pinLegend")
    }

    func testLivePinEntries_labelsMatchShippedMarkerSet() {
        let labels = Set(MapKeyLegendView.livePinEntries.map(\.label))
        XCTAssertEqual(labels, [
            "Enforcement active",
            "Sweeper passed",
            "Leaving soon (handoff)",
            "Open spot (passerby)",
        ])
    }

    /// Locked decision #6's standing exception: this legend must never promise a marker the
    /// map doesn't actually draw. `.construction` (closure) and `.blockNote` are NOT in
    /// `ContentView.mapMarkerTypes(communityEnabled:)` — they must not appear here either.
    func testLivePinEntries_noConstructionOrBlockNoteRow_notRenderedOnMap() {
        let labels = MapKeyLegendView.livePinEntries.map(\.label)
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("closure") })
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("block note") })
    }

    /// This app has no pulse/fade expiry ANIMATION — a pin is simply removed from
    /// `visiblePins` once its TTL passes. The footer must not claim one (the prototype's
    /// own footer does: "Pins pulse when fresh and fade as they expire").
    func testFooterText_doesNotClaimPulseAnimation() {
        XCTAssertFalse(MapKeyLegendView.footerText.localizedCaseInsensitiveContains("pulse"))
    }
}

// MARK: - ContentView.communityMapChromeVisible

final class CommunityMapChromeVisibleTests: XCTestCase {

    func testChromeVisible_flagOff_alwaysHidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: false,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: false
        ))
    }

    func testChromeVisible_flagOn_noModesActive_visible() {
        XCTAssertTrue(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: false
        ))
    }

    func testChromeVisible_flagOn_driveModeActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: true,
            blockSelectModeActive: false,
            spotPlacementActive: false
        ))
    }

    func testChromeVisible_flagOn_blockSelectModeActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: true,
            spotPlacementActive: false
        ))
    }

    func testChromeVisible_flagOn_spotPlacementActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: true
        ))
    }
}

// MARK: - ContentView.resolveHomeZoneId

final class ResolveHomeZoneIdTests: XCTestCase {

    /// A parked car inside the "les" box, with the viewport centered inside "nolita" — the
    /// car must win, matching `updatePushZoneFromParkedCarOrLocation`'s own priority.
    func testResolveHomeZoneId_parkedCarWins_evenWhenViewportInDifferentZone() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: 40.7200, parkedCarLng: -73.9850,   // inside "les"
            viewportCenterLat: 40.7230, viewportCenterLng: -73.9950  // inside "nolita"
        )
        XCTAssertEqual(result, "les")
    }

    func testResolveHomeZoneId_noParkedCar_fallsBackToViewportCenter() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: nil, parkedCarLng: nil,
            viewportCenterLat: 40.7225, viewportCenterLng: -74.0000  // inside "soho"
        )
        XCTAssertEqual(result, "soho")
    }

    func testResolveHomeZoneId_neitherResolves_returnsNil() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: nil, parkedCarLng: nil,
            viewportCenterLat: 40.70, viewportCenterLng: -74.02  // outside all three boxes
        )
        XCTAssertNil(result)
    }
}

// MARK: - MapViewRepresentable zone-boundary pure helpers

final class ZoneBoundaryHelperTests: XCTestCase {

    private let sampleBox: (latMin: Double, latMax: Double, lngMin: Double, lngMax: Double) = (
        latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930
    )

    func testZoneBoundaryCoordinates_fourCornersInBoxOrder() {
        let coords = MapViewRepresentable.zoneBoundaryCoordinates(box: sampleBox)
        XCTAssertEqual(coords.count, 4)
        // NW → NE → SE → SW
        XCTAssertEqual(coords[0].latitude, sampleBox.latMax)
        XCTAssertEqual(coords[0].longitude, sampleBox.lngMin)
        XCTAssertEqual(coords[1].latitude, sampleBox.latMax)
        XCTAssertEqual(coords[1].longitude, sampleBox.lngMax)
        XCTAssertEqual(coords[2].latitude, sampleBox.latMin)
        XCTAssertEqual(coords[2].longitude, sampleBox.lngMax)
        XCTAssertEqual(coords[3].latitude, sampleBox.latMin)
        XCTAssertEqual(coords[3].longitude, sampleBox.lngMin)
    }

    func testZoneLabelCoordinate_insetFromTopLeftCorner_staysInsideBox() {
        let coord = MapViewRepresentable.zoneLabelCoordinate(box: sampleBox)
        // Inset from the top-left (max lat, min lng) corner — strictly inside the box on
        // both axes, never sitting exactly on an edge.
        XCTAssertLessThan(coord.latitude, sampleBox.latMax)
        XCTAssertGreaterThan(coord.latitude, sampleBox.latMin)
        XCTAssertGreaterThan(coord.longitude, sampleBox.lngMin)
        XCTAssertLessThan(coord.longitude, sampleBox.lngMax)
        // Closer to the top-left corner than to the box's center.
        XCTAssertLessThan(sampleBox.latMax - coord.latitude, (sampleBox.latMax - sampleBox.latMin) / 2)
        XCTAssertLessThan(coord.longitude - sampleBox.lngMin, (sampleBox.lngMax - sampleBox.lngMin) / 2)
    }

    func testZoneDisplayName_knownZones() {
        XCTAssertEqual(MapViewRepresentable.zoneDisplayName("nolita"), "NOLITA")
        XCTAssertEqual(MapViewRepresentable.zoneDisplayName("soho"), "SOHO")
        XCTAssertEqual(MapViewRepresentable.zoneDisplayName("les"), "LES")
    }

    func testZoneDisplayName_unknownZone_fallsBackToUppercasedId() {
        XCTAssertEqual(MapViewRepresentable.zoneDisplayName("soho-les"), "SOHO-LES")
    }

    func testCommunityZoneIds_matchesSeededZones() {
        XCTAssertEqual(MapViewRepresentable.communityZoneIds, ["nolita", "soho", "les"])
    }
}

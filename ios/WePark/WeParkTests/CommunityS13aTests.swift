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
//  S13c Fix #1 (docs/design/community-2.0-final-parity-audit.md §2 item 1) updated
//  `resolveHomeZoneId`'s signature (viewport → device location) — the 3 tests below that
//  named "viewport" were renamed/re-asserted accordingly, and 2 new tests added for the
//  "neither car nor device location" / "car with no device-location fix at all" cases.
//
//  Open item #17 follow-up (2026-09-11): Kevin's live smoke of `b500c95a` found the Report
//  pill / "?" button drawing over the corners of the new long-press park-confirm card —
//  `communityMapChromeVisible` gained a 5th parameter, `longPressParkConfirmActive`, same
//  exclusion shape as `spotPlacementActive`. One test added (16a below); the 4 existing
//  gating tests were updated to pass the new parameter explicitly (all `false`), not given
//  a default, matching this function's existing "every case explicit" style.
//
//  Test inventory (27 tests):
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
//      16a. testChromeVisible_flagOn_longPressParkConfirmActive_hidden
//
//    ContentView.resolveHomeZoneId (S13c Fix #1) — car > device location > nil, NEVER viewport:
//      17. testResolveHomeZoneId_parkedCarWins_evenWhenDeviceLocationInDifferentZone
//      18. testResolveHomeZoneId_noParkedCar_fallsBackToDeviceLocation
//      19. testResolveHomeZoneId_neitherResolves_returnsNil
//      19a. testResolveHomeZoneId_noCarNoDeviceLocation_returnsNil
//      19b. testResolveHomeZoneId_parkedCarResolves_withNoDeviceLocationAtAll
//
//    MapViewRepresentable zone-boundary pure helpers — boxes → overlay specs:
//      20. testZoneBoundaryCoordinates_fourCornersInBoxOrder
//      21. testZoneLabelCoordinate_insetFromTopLeftCorner_staysInsideBox
//
//    Community 2.0 S14 (`docs/community-2.0-s14-execution-spec.md`) additions/changes:
//      - `resolveHomeZoneId` gained a `zones: [Zone]` parameter — tests 17-19b updated to pass
//        an explicit fixture (same lat/lng values as before); one new test added
//        (empty-`zones`-array tolerance).
//      - `MapViewRepresentable.zoneDisplayName(_:)`/`.communityZoneIds` are RETIRED along with
//        the compiled zone-bounds table — their tests are removed, replaced by
//        `MapViewRepresentableZoneBoundaryTests` below, which exercises the live
//        `syncZoneBoundaries(enabled:homeZone:on:)` render path against a `Coordinator` +
//        plain `MKMapView()` (same pattern already established in `W85bTests.swift`/
//        `FT10Tests.swift` — no `UIWindowScene` synthesis, no test-only production branching).
//        20a. testSyncZoneBoundaries_nonOriginalZoneName_rendersRealNameNotRawId
//        20b. testSyncZoneBoundaries_nilHomeZone_removesExistingOverlayAndLabel
//
//  No Calendar.current use. No hardcoded Mapbox/Supabase secrets.
//

import XCTest
import CoreLocation
import MapKit
import SwiftUI
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
            spotPlacementActive: false,
            longPressParkConfirmActive: false
        ))
    }

    func testChromeVisible_flagOn_noModesActive_visible() {
        XCTAssertTrue(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: false,
            longPressParkConfirmActive: false
        ))
    }

    func testChromeVisible_flagOn_driveModeActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: true,
            blockSelectModeActive: false,
            spotPlacementActive: false,
            longPressParkConfirmActive: false
        ))
    }

    func testChromeVisible_flagOn_blockSelectModeActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: true,
            spotPlacementActive: false,
            longPressParkConfirmActive: false
        ))
    }

    func testChromeVisible_flagOn_spotPlacementActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: true,
            longPressParkConfirmActive: false
        ))
    }

    /// Open item #17 follow-up (2026-09-11): the Report pill / "?" button must hide while
    /// the long-press park-confirm card is up — Kevin's live-smoke finding (b500c95a) was
    /// the pill/button drawing over the card's corners.
    func testChromeVisible_flagOn_longPressParkConfirmActive_hidden() {
        XCTAssertFalse(ContentView.communityMapChromeVisible(
            communityEnabled: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: false,
            longPressParkConfirmActive: true
        ))
    }
}

// MARK: - ContentView.resolveHomeZoneId (S13c Fix #1: car > device location > nil, NEVER viewport)

/// Community 2.0 S14: stands in for the retired compiled zone-bounds table — same lat/lng
/// values every test below already assumed.
private let resolveHomeZoneIdFixtureZones: [Zone] = [
    Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930),
    Zone(id: "soho",   name: "SoHo",   latMin: 40.7220, latMax: 40.7237, lngMin: -74.0050, lngMax: -73.9970),
    Zone(id: "les",    name: "LES",    latMin: 40.7145, latMax: 40.7230, lngMin: -73.9920, lngMax: -73.9800),
]

final class ResolveHomeZoneIdTests: XCTestCase {

    /// A parked car inside the "les" box, with the device's current location inside
    /// "nolita" — the car must win, matching `updatePushZoneFromParkedCarOrLocation`'s own
    /// priority.
    func testResolveHomeZoneId_parkedCarWins_evenWhenDeviceLocationInDifferentZone() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: 40.7200, parkedCarLng: -73.9850,   // inside "les"
            deviceLocationLat: 40.7230, deviceLocationLng: -73.9950,  // inside "nolita"
            zones: resolveHomeZoneIdFixtureZones
        )
        XCTAssertEqual(result, "les")
    }

    /// No car parked — falls back to the device's current location (S13c: NOT the map
    /// viewport, which was the exact bug the audit pinned).
    func testResolveHomeZoneId_noParkedCar_fallsBackToDeviceLocation() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: nil, parkedCarLng: nil,
            deviceLocationLat: 40.7225, deviceLocationLng: -74.0000,  // inside "soho"
            zones: resolveHomeZoneIdFixtureZones
        )
        XCTAssertEqual(result, "soho")
    }

    /// Neither a parked car nor a device-location fix resolves to a seeded zone — must
    /// return nil (no box, no label), never a viewport-derived guess.
    func testResolveHomeZoneId_neitherResolves_returnsNil() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: nil, parkedCarLng: nil,
            deviceLocationLat: 40.70, deviceLocationLng: -74.02,  // outside every box
            zones: resolveHomeZoneIdFixtureZones
        )
        XCTAssertNil(result)
    }

    /// No parked car AND no device-location fix at all (both nil) — must return nil, not
    /// crash or fall through to some other signal.
    func testResolveHomeZoneId_noCarNoDeviceLocation_returnsNil() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: nil, parkedCarLng: nil,
            deviceLocationLat: nil, deviceLocationLng: nil,
            zones: resolveHomeZoneIdFixtureZones
        )
        XCTAssertNil(result)
    }

    /// Parked car resolves to a seeded zone even when there's no device-location fix at all
    /// (nil lat/lng) — the car alone is sufficient, matching production's
    /// `locationService.userLocation == nil` (permission not yet granted) case.
    func testResolveHomeZoneId_parkedCarResolves_withNoDeviceLocationAtAll() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: 40.7230, parkedCarLng: -73.9950,   // inside "nolita"
            deviceLocationLat: nil, deviceLocationLng: nil,
            zones: resolveHomeZoneIdFixtureZones
        )
        XCTAssertEqual(result, "nolita")
    }

    /// Community 2.0 S14 AC: an empty `zones` array (first-launch-and-offline) must never
    /// crash — it degrades to `nil`, same as any other unmatched coordinate.
    func testResolveHomeZoneId_emptyZonesArray_returnsNil() {
        let result = ContentView.resolveHomeZoneId(
            parkedCarLat: 40.7230, parkedCarLng: -73.9950,
            deviceLocationLat: nil, deviceLocationLng: nil,
            zones: []
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

    // Community 2.0 S14: `MapViewRepresentable.zoneDisplayName(_:)` and `.communityZoneIds`
    // are both retired — `syncZoneBoundaries` now reads `zone.name.uppercased()` directly off
    // the fetched `Zone` object (see `MapViewRepresentableZoneBoundaryTests` below for live
    // coverage of that rendering path with a non-original zone name).
}

// MARK: - MapViewRepresentable.Coordinator.syncZoneBoundaries (Community 2.0 S14)

/// Live-render coverage for `syncZoneBoundaries(enabled:homeZone:on:)` against a real
/// `Coordinator` + plain `MKMapView()` — same "minimal `MapViewRepresentable(...)` +
/// `makeCoordinator()` + bare `MKMapView()`" pattern already established in
/// `W85bTests.swift`/`FT10Tests.swift` for this file's other Coordinator sync methods. No
/// `UIWindowScene` synthesis, no production code branching for test purposes.
@MainActor
final class MapViewRepresentableZoneBoundaryTests: XCTestCase {

    private func makeCoordinator() -> MapViewRepresentable.Coordinator {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.990),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        @State var regionState = region
        @State var selectedID: String? = nil

        let repr = MapViewRepresentable(
            region: $regionState,
            selectedSegmentID: $selectedID,
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: MapViewRepresentable.OverlayPayload(generation: 0),
            activeRoute: nil,
            destinationCoordinate: nil,
            coordinatorActions: MapViewRepresentable.CoordinatorActions()
        )
        return repr.makeCoordinator()
    }

    /// Spec AC: "renders any `Zone`'s box/label correctly, including a zone whose name isn't
    /// one of the original three (e.g. 'Hell's Kitchen' renders as
    /// 'YOUR SQUARE · HELL'S KITCHEN', not a raw id)."
    func testSyncZoneBoundaries_nonOriginalZoneName_rendersRealNameNotRawId() {
        let coordinator = makeCoordinator()
        let mapView = MKMapView()
        let hellsKitchen = Zone(
            id: "hells-kitchen", name: "Hell's Kitchen",
            latMin: 40.7484, latMax: 40.7685, lngMin: -74.0090, lngMax: -73.9910
        )

        coordinator.syncZoneBoundaries(enabled: true, homeZone: hellsKitchen, on: mapView)

        XCTAssertTrue(mapView.overlays.contains { $0 is ZoneBoundaryPolygon })
        let label = mapView.annotations.compactMap { $0 as? ZoneLabelAnnotation }.first
        XCTAssertEqual(label?.labelText, "YOUR SQUARE · HELL'S KITCHEN")
    }

    /// `enabled: false` (or a `nil` home zone) must remove whatever box/label was previously
    /// shown — never leave a stale zone's box on screen once it's no longer the user's own.
    func testSyncZoneBoundaries_nilHomeZone_removesExistingOverlayAndLabel() {
        let coordinator = makeCoordinator()
        let mapView = MKMapView()
        let nolita = Zone(id: "nolita", name: "Nolita", latMin: 40.7217, latMax: 40.7256, lngMin: -73.9967, lngMax: -73.9930)

        coordinator.syncZoneBoundaries(enabled: true, homeZone: nolita, on: mapView)
        XCTAssertTrue(mapView.overlays.contains { $0 is ZoneBoundaryPolygon })

        coordinator.syncZoneBoundaries(enabled: true, homeZone: nil, on: mapView)
        XCTAssertFalse(mapView.overlays.contains { $0 is ZoneBoundaryPolygon })
        XCTAssertFalse(mapView.annotations.contains { $0 is ZoneLabelAnnotation })
    }
}

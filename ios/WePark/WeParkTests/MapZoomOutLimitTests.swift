//
//  MapZoomOutLimitTests.swift
//  WeParkTests
//
//  PR #89 (2026-08-23): hard camera zoom-out limit.
//  Kevin's original call after seeing the fully-zoomed-out state on device: "cant we
//  just lock it so that you cant zoom too far out?"
//
//  PR #89 follow-up (2026-08-23, zoom-out-limit-tighten): the first-pass ~53,000m limit
//  (framing all of NYC's basemap) still left an 8.3km→53km band where the basemap rendered
//  but zero parking polylines did — the same "looks broken" complaint in milder form. Kevin,
//  on review: "I think locking where data ends makes sense." The limit now derives from
//  `AppConstants.polylineHideSpanThreshold` instead of the tile grid's basemap-framing box,
//  so the camera can never reach the empty-polyline band in the first place.
//
//  Scope note: `mapView.setCameraZoomRange(_:animated:)` itself is a UIKit call on a
//  live `MKMapView` — not meaningfully unit-testable without a windowed view (the exact
//  anti-pattern spec §5 / AC-6 in DriveCameraTiltTests.swift forbids). That call is
//  verified by the mandatory live-UI smoke, not here (see PR body).
//
//  What IS testable, and what these tests lock in: the derivation of
//  `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` itself — a pure constant —
//  and its documented relationship to the other camera/loading constants already in the
//  codebase (`altitudeForSpan`, `AppConstants.polylineHideSpanThreshold`,
//  `TileLoader.maxLoadSpanDegrees`), following the same "documented, named threshold" test
//  pattern as `TileLoaderZoomCrashTests.testMaxLoadSpanDegrees_isDocumentedValue`.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

final class MapZoomOutLimitTests: XCTestCase {

    // MARK: Test 1: constant locked to the documented, derived value

    /// Independently reproduces the arithmetic (without calling the production
    /// `altitudeForSpan` helper) to lock in the current numeric value and catch any
    /// unintentional drift in the formula itself.
    ///
    /// Derivation (see `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` doc
    /// comment for the full writeup): raw altitude at
    /// `AppConstants.polylineHideSpanThreshold` (0.04°) is ≈8,285m. Applying
    /// `zoomOutMarginFactor` (0.9, i.e. 10% headroom on the span) targets 0.036°, which
    /// converts via the same halfHeight / tan(15°) formula to ≈7,456.6m.
    func testMaxZoomOutCenterCoordinateDistance_isDocumentedValue() {
        let targetSpan = 0.04 * 0.9 // AppConstants.polylineHideSpanThreshold * zoomOutMarginFactor
        let halfHeightMeters = (targetSpan / 2.0) * 111_000
        let expected = halfHeightMeters / tan(15.0 * .pi / 180.0)

        XCTAssertEqual(
            MapViewRepresentable.maxZoomOutCenterCoordinateDistance, expected, accuracy: 1.0,
            "maxZoomOutCenterCoordinateDistance changed — derived from " +
            "AppConstants.polylineHideSpanThreshold (0.04°) × zoomOutMarginFactor (0.9). " +
            "Update this test alongside the constant's doc comment if either input is " +
            "intentionally retuned on-device."
        )
    }

    // MARK: Test 2: the limit stays inside the polyline-hide threshold, with a small margin

    /// Using `altitudeForSpan` in reverse logic: confirms the chosen altitude corresponds
    /// to a visible latitude span that stays UNDER `AppConstants.polylineHideSpanThreshold`
    /// — the entire point of the tightened limit is that the camera can no longer reach the
    /// span where polylines vanish. Also confirms the margin is a "hair," not most of the
    /// range (Kevin's framing), by bounding it to no more than 25% below the threshold.
    func testMaxZoomOutCenterCoordinateDistance_staysInsidePolylineHideThresholdWithMargin() {
        let halfHeightMeters = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            * tan(15.0 * .pi / 180.0)
        let impliedVisibleLatSpan = (2 * halfHeightMeters) / 111_000

        XCTAssertLessThan(
            impliedVisibleLatSpan, AppConstants.polylineHideSpanThreshold,
            "The zoom-out limit's implied visible span (\(impliedVisibleLatSpan)°) must " +
            "stay under AppConstants.polylineHideSpanThreshold " +
            "(\(AppConstants.polylineHideSpanThreshold)°) — otherwise the camera could " +
            "reach the empty-polyline band this limit exists to make unreachable."
        )

        XCTAssertGreaterThan(
            impliedVisibleLatSpan, AppConstants.polylineHideSpanThreshold * 0.75,
            "The zoom-out limit's implied visible span (\(impliedVisibleLatSpan)°) is more " +
            "than 25% under AppConstants.polylineHideSpanThreshold " +
            "(\(AppConstants.polylineHideSpanThreshold)°) — that's more than \"a hair of " +
            "headroom\" (Kevin's framing); the margin has drifted from a small buffer " +
            "toward re-clipping usable zoom range."
        )
    }

    // MARK: Test 3: the camera limit and the polyline threshold cannot silently drift apart

    /// The whole point of deriving `maxZoomOutCenterCoordinateDistance` FROM
    /// `AppConstants.polylineHideSpanThreshold` (rather than a second, independently-tuned
    /// hardcoded number) is that the two can never drift apart without this test catching
    /// it. This re-derives the expected implied span directly from the live
    /// `AppConstants` value at test time — if someone reverts the camera constant to a
    /// hardcoded literal (undoing the derivation) and later retunes the polyline threshold,
    /// this is the test that fails.
    func testMaxZoomOutCenterCoordinateDistance_tracksPolylineHideThreshold() {
        let halfHeightMeters = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            * tan(15.0 * .pi / 180.0)
        let impliedVisibleLatSpan = (2 * halfHeightMeters) / 111_000

        let expectedSpan = AppConstants.polylineHideSpanThreshold
            * MapViewRepresentable.zoomOutMarginFactor

        XCTAssertEqual(
            impliedVisibleLatSpan, expectedSpan, accuracy: 0.0001,
            "maxZoomOutCenterCoordinateDistance's implied visible span " +
            "(\(impliedVisibleLatSpan)°) no longer matches " +
            "AppConstants.polylineHideSpanThreshold × zoomOutMarginFactor " +
            "(\(expectedSpan)°) — the camera zoom-out ceiling and the polyline-hide gate " +
            "have drifted apart. If polylineHideSpanThreshold was intentionally retuned, " +
            "maxZoomOutCenterCoordinateDistance must be computed FROM the new value (it " +
            "already should be, automatically — check it wasn't hardcoded back to a " +
            "literal)."
        )
    }

    // MARK: Test 4: recenter / Drive Mode camera calls are not clipped

    /// `recenterMap(on:)` (400m span) and Drive Mode's follow camera
    /// (`driveModeCameraSpan` = 0.003°) both target altitudes far tighter than the new
    /// zoom-out ceiling. This test locks in that neither is clipped by
    /// `setCameraZoomRange` — which applies to BOTH gestures AND programmatic camera calls.
    ///
    /// Note: `ContentView`'s cold-launch default region (0.07° lat span) is deliberately
    /// NOT included here — see
    /// `testInitialBrowseRegion_isNowIntentionallyClampedAtLaunch` below, which documents
    /// that call IS now clipped, on purpose.
    func testMaxZoomOutCenterCoordinateDistance_doesNotClipRecenterOrDriveModeCalls() {
        // recenterMap(on:) uses a fixed 400m span — converted to an equivalent
        // "span in degrees" for apples-to-apples comparison via altitudeForSpan.
        let recenterSpanDegrees = 400.0 / 111_000
        let recenterAltitude = MapViewRepresentable.altitudeForSpan(recenterSpanDegrees)

        // Drive Mode's tight follow camera.
        let driveAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )

        for (name, altitude) in [
            ("recenterMap (400m)", recenterAltitude),
            ("Drive Mode follow camera", driveAltitude),
        ] {
            XCTAssertLessThan(
                altitude, MapViewRepresentable.maxZoomOutCenterCoordinateDistance,
                "\(name) targets an altitude (\(altitude)m) that is not comfortably " +
                "under the new zoom-out ceiling " +
                "(\(MapViewRepresentable.maxZoomOutCenterCoordinateDistance)m) — " +
                "setCameraZoomRange would clip this call."
            )
        }
    }

    // MARK: Test 5: the cold-launch default region is now intentionally clamped

    /// `ContentView`'s cold-launch default `region` (0.07° lat / 0.05° lng span, set before
    /// any recenter logic runs) is WIDER than the tightened zoom-out ceiling. When the
    /// launch-priority fallback leaves that default region in place — out-of-coverage or
    /// location-denied users, `performLaunchSetup`'s Priority 3 — `setCameraZoomRange`
    /// immediately clamps the initial camera down to the ceiling instead of the wider
    /// default.
    ///
    /// This is documented and intentional, not a regression: it moves cold-launch framing
    /// closer to where polylines actually render (≈0.036° vs the old 0.07°, where zero
    /// polylines were visible either way — 0.07° is already past
    /// `AppConstants.polylineHideSpanThreshold`). See
    /// `MapViewRepresentable.maxZoomOutCenterCoordinateDistance`'s "Known side effect" doc
    /// comment paragraph.
    ///
    /// If this assertion ever flips (the default region altitude drops below the ceiling),
    /// it most likely means the ceiling was loosened again — reconcile with that doc
    /// comment rather than deleting this test.
    func testInitialBrowseRegion_isNowIntentionallyClampedAtLaunch() {
        let initialRegionLatSpan = 0.07
        let initialRegionAltitude = MapViewRepresentable.altitudeForSpan(initialRegionLatSpan)

        XCTAssertGreaterThan(
            initialRegionAltitude, MapViewRepresentable.maxZoomOutCenterCoordinateDistance,
            "ContentView's cold-launch default region (0.07° lat span, altitude " +
            "\(initialRegionAltitude)m) is no longer wider than " +
            "maxZoomOutCenterCoordinateDistance " +
            "(\(MapViewRepresentable.maxZoomOutCenterCoordinateDistance)m) — the " +
            "documented \"launch is clamped down to the ceiling\" behavior no longer " +
            "applies. Update this test and the doc comment together if that's intentional."
        )
    }

    // MARK: Test 6: the camera limit is tighter than TileLoader's load backstop

    /// `TileLoader.maxLoadSpanDegrees` (0.5°) is the OUTER backstop that stops tile
    /// loading entirely — it exists to guard a transient mid-gesture span independent of
    /// how far the user can actually zoom (see `AppConstants.polylineHideSpanThreshold`'s
    /// doc comment for the full "three-layer, defense in depth" relationship). This test
    /// confirms the new steady-state camera ceiling sits comfortably inside that backstop,
    /// i.e. the user's reachable zoom range never gets far enough out to trip the
    /// load-skip guard — tiles keep loading throughout the whole reachable range.
    func testMaxZoomOutCenterCoordinateDistance_isTighterThanTileLoadBackstop() {
        let loadBackstopAltitude = MapViewRepresentable.altitudeForSpan(
            TileLoader.maxLoadSpanDegrees
        )

        XCTAssertLessThan(
            MapViewRepresentable.maxZoomOutCenterCoordinateDistance, loadBackstopAltitude,
            "The camera zoom-out ceiling (\(MapViewRepresentable.maxZoomOutCenterCoordinateDistance)m) " +
            "must stay under TileLoader's load-skip backstop altitude " +
            "(\(loadBackstopAltitude)m, from maxLoadSpanDegrees = " +
            "\(TileLoader.maxLoadSpanDegrees)°) — otherwise the reachable zoom range " +
            "could hit the point where TileLoader stops loading tiles altogether."
        )
    }
}

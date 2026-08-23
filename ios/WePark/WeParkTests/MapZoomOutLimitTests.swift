//
//  MapZoomOutLimitTests.swift
//  WeParkTests
//
//  PR #89 follow-up (2026-08-23): hard camera zoom-out limit.
//  Kevin's explicit call after seeing the fully-zoomed-out state on device: "cant we
//  just lock it so that you cant zoom too far out?"
//
//  Scope note: `mapView.setCameraZoomRange(_:animated:)` itself is a UIKit call on a
//  live `MKMapView` — not meaningfully unit-testable without a windowed view (the exact
//  anti-pattern spec §5 / AC-6 in DriveCameraTiltTests.swift forbids). That call is
//  verified by the mandatory live-UI smoke, not here (see PR body).
//
//  What IS testable, and what these tests lock in: the derivation of
//  `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` itself — a pure constant —
//  and its documented relationship to the other camera/loading constants already in the
//  codebase (`altitudeForSpan`, `TileLoader.maxLoadSpanDegrees`), following the same
//  "documented, named threshold" test pattern as
//  `TileLoaderZoomCrashTests.testMaxLoadSpanDegrees_isDocumentedValue`.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

final class MapZoomOutLimitTests: XCTestCase {

    // MARK: Test 1: constant locked to the documented, derived value

    /// The limit is a single named constant so it's trivially tunable (per Kevin's
    /// "one number to tune after seeing it on-device" instruction) — this test locks in
    /// the chosen value (53,000m) and fails loudly, not silently, if someone changes it,
    /// prompting an update to this test's rationale comment alongside the constant's doc
    /// comment.
    ///
    /// Derivation (see `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` doc
    /// comment for the full arithmetic): NYC's tile coverage is ~0.182° lat × 0.113° lng
    /// (index.json). Taking the binding N–S dimension (~20,200m), applying a 1.4× margin
    /// (28,280m full height), and converting to altitude via the same
    /// halfHeight / tan(15°) formula `altitudeForSpan` uses elsewhere in this file
    /// yields ≈52,770m, rounded to 53,000m.
    func testMaxZoomOutCenterCoordinateDistance_isDocumentedValue() {
        XCTAssertEqual(
            MapViewRepresentable.maxZoomOutCenterCoordinateDistance, 53_000,
            "maxZoomOutCenterCoordinateDistance changed — derived from NYC's real tile " +
            "coverage (~0.182° lat × 0.113° lng, index.json) plus a 1.4× margin. Update " +
            "this test alongside the constant's doc comment if the value is " +
            "intentionally retuned on-device."
        )
    }

    // MARK: Test 2: the limit actually frames all of NYC (not a partial crop)

    /// Using `altitudeForSpan` in reverse logic: confirms the chosen altitude corresponds
    /// to a visible latitude span comfortably larger than NYC's own tile-coverage span
    /// (0.182°), so the camera limit genuinely "frames the whole city with margin" rather
    /// than clipping it. Computed via the same formula the constant's derivation used:
    /// halfHeightMeters = altitude × tan(15°); visibleSpan = 2 × halfHeightMeters / 111,000.
    func testMaxZoomOutCenterCoordinateDistance_framesAllOfNYCWithMargin() {
        let nycTileCoverageLatSpan = 0.182 // index.json: 80 rows × ~0.002275° rowSize

        let halfHeightMeters = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            * tan(15.0 * .pi / 180.0)
        let impliedVisibleLatSpan = (2 * halfHeightMeters) / 111_000

        XCTAssertGreaterThan(
            impliedVisibleLatSpan, nycTileCoverageLatSpan,
            "The zoom-out limit's implied visible span (\(impliedVisibleLatSpan)°) must " +
            "exceed NYC's own tile-coverage span (\(nycTileCoverageLatSpan)°) — otherwise " +
            "the camera limit would clip the city instead of framing it with margin."
        )

        // "Shortly past it," not wildly past it — guard against an overcorrection that
        // reintroduces a large empty-void margin. 2× NYC's own span is a generous upper
        // bound on "comfortable margin."
        XCTAssertLessThan(
            impliedVisibleLatSpan, nycTileCoverageLatSpan * 2,
            "The zoom-out limit's implied visible span (\(impliedVisibleLatSpan)°) is " +
            "more than 2× NYC's tile-coverage span (\(nycTileCoverageLatSpan)°) — that's " +
            "excess margin drifting back toward the empty-void feel this limit exists to fix."
        )
    }

    // MARK: Test 3: no existing programmatic camera call is clipped by the new limit

    /// Every existing programmatic `setRegion`/`setCamera` call in the app targets a span
    /// far tighter than the new zoom-out ceiling (ContentView's initial region: 0.07° lat
    /// / 0.05° lng; `recenterMap`: 400m; Drive Mode: `driveModeCameraSpan` = 0.003°). This
    /// test locks in that none of those approach the new ceiling, so `setCameraZoomRange`
    /// — which applies to BOTH gestures AND programmatic camera calls — cannot silently
    /// clip any of them. If this ever fails, a wider programmatic camera call was added
    /// somewhere and needs to be reconciled with the zoom-out limit (widen the limit, or
    /// confirm the wider call is intentional and should be exempted).
    func testMaxZoomOutCenterCoordinateDistance_doesNotClipExistingProgrammaticCameraCalls() {
        // ContentView's initial region span (widest browse-mode `setRegion` target today).
        let initialRegionLatSpan = 0.07
        let initialRegionAltitude = MapViewRepresentable.altitudeForSpan(initialRegionLatSpan)

        // recenterMap(on:) uses a fixed 400m span — converted to an equivalent
        // "span in degrees" for apples-to-apples comparison via altitudeForSpan.
        let recenterSpanDegrees = 400.0 / 111_000
        let recenterAltitude = MapViewRepresentable.altitudeForSpan(recenterSpanDegrees)

        // Drive Mode's tight follow camera.
        let driveAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )

        for (name, altitude) in [
            ("initial browse region (0.07°)", initialRegionAltitude),
            ("recenterMap (400m)", recenterAltitude),
            ("Drive Mode follow camera", driveAltitude),
        ] {
            XCTAssertLessThan(
                altitude, MapViewRepresentable.maxZoomOutCenterCoordinateDistance,
                "\(name) targets an altitude (\(altitude)m) that is not comfortably " +
                "under the new zoom-out ceiling (\(MapViewRepresentable.maxZoomOutCenterCoordinateDistance)m) " +
                "— setCameraZoomRange would clip this call."
            )
        }
    }

    // MARK: Test 4: the camera limit is tighter than TileLoader's load backstop

    /// `TileLoader.maxLoadSpanDegrees` (0.5°) is the OUTER backstop that stops tile
    /// loading entirely — it exists to guard a transient mid-gesture span independent of
    /// how far the user can actually zoom (see both constants' doc comments for the full
    /// "defense in depth" relationship). This test confirms the new steady-state camera
    /// ceiling sits comfortably inside that backstop, i.e. the user's reachable zoom range
    /// never gets far enough out to trip the load-skip guard — tiles keep loading
    /// throughout the whole reachable range.
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

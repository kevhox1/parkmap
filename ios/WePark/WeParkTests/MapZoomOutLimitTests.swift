//
//  MapZoomOutLimitTests.swift
//  WeParkTests
//
//  PR #89 (2026-08-23): hard camera zoom-out limit.
//  Kevin's original call after seeing the fully-zoomed-out state on device: "cant we
//  just lock it so that you cant zoom too far out?"
//
//  PR #89 follow-up round 1 (2026-08-23, zoom-out-limit-tighten): the first-pass ~53,000m
//  limit (framing all of NYC's basemap) still left an 8.3km→53km band where the basemap
//  rendered but zero parking polylines did — the same "looks broken" complaint in milder
//  form. Kevin, on review: "I think locking where data ends makes sense." The limit was
//  derived from `AppConstants.polylineHideSpanThreshold` instead of the tile grid's
//  basemap-framing box, so the camera could never reach the empty-polyline band.
//
//  PR #89 follow-up round 2 (2026-08-23, this file's current state): round 1's premise
//  is REVERSED. Kevin, on device with the ~7,457m ceiling: "i think we need to have
//  farther zoom. All of manhattan is probably the right gate... The spot we are right now
//  is awkward and difficult to understand what your looking at unless you actually know
//  manhattan really well." Locking to the data-availability edge produced a limit that was
//  too tight for orientation. The limit is now derived from
//  `AppConstants.manhattanCoverageBounds` — the tile grid's actual coverage extent — instead
//  of `polylineHideSpanThreshold`. The two constants are deliberately DECOUPLED as of this
//  round: `polylineHideSpanThreshold` stays at 0.04° (perf reasons, unrelated to zoom-out
//  framing), while the camera ceiling widens independently to ~41.5km. See
//  `MapViewRepresentable.maxZoomOutCenterCoordinateDistance`'s doc comment for the full
//  writeup of both rounds.
//
//  Scope note: `mapView.setCameraZoomRange(_:animated:)` itself is a UIKit call on a
//  live `MKMapView` — not meaningfully unit-testable without a windowed view (the exact
//  anti-pattern spec §5 / AC-6 in DriveCameraTiltTests.swift forbids). That call is
//  verified by the mandatory live-UI smoke, not here (see PR body).
//
//  What IS testable, and what these tests lock in: the derivation of
//  `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` itself — a pure constant —
//  and its documented relationship to the other camera/loading constants already in the
//  codebase (`altitudeForSpan`, `AppConstants.manhattanCoverageBounds`,
//  `TileLoader.maxLoadSpanDegrees`), following the same "documented, named threshold" test
//  pattern as `TileLoaderZoomCrashTests.testMaxLoadSpanDegrees_isDocumentedValue`.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

final class MapZoomOutLimitTests: XCTestCase {

    // MARK: Test 1: constant locked to the documented, coverage-derived value

    /// Independently reproduces the arithmetic (without calling the production
    /// `altitudeForSpan` helper) to lock in the current numeric value and catch any
    /// unintentional drift in the formula itself.
    ///
    /// Derivation (see `MapViewRepresentable.maxZoomOutCenterCoordinateDistance` doc
    /// comment for the full writeup): the tile grid's coverage lat span
    /// (`AppConstants.manhattanCoverageBounds.latMax - .latMin`) is 0.182° (40.882 − 40.700).
    /// Applying `manhattanCoverageZoomOutMarginFactor` (1.1, i.e. +10% headroom on the span)
    /// targets 0.2002°, which converts via the same halfHeight / tan(15°) formula to
    /// ≈41,467m.
    func testMaxZoomOutCenterCoordinateDistance_isDocumentedValue() {
        let coverageLatSpan = AppConstants.manhattanCoverageBounds.latMax
            - AppConstants.manhattanCoverageBounds.latMin
        let targetSpan = coverageLatSpan * 1.1 // manhattanCoverageZoomOutMarginFactor
        let halfHeightMeters = (targetSpan / 2.0) * 111_000
        let expected = halfHeightMeters / tan(15.0 * .pi / 180.0)

        XCTAssertEqual(
            MapViewRepresentable.maxZoomOutCenterCoordinateDistance, expected, accuracy: 1.0,
            "maxZoomOutCenterCoordinateDistance changed — derived from " +
            "AppConstants.manhattanCoverageBounds' lat span (0.182°) × " +
            "manhattanCoverageZoomOutMarginFactor (1.1). Update this test alongside the " +
            "constant's doc comment if either input is intentionally retuned on-device."
        )

        // Sanity check against the spec's target: "roughly 41 km."
        XCTAssertEqual(expected, 41_470, accuracy: 200,
            "Expected altitude drifted from the ~41.5km target Kevin asked for " +
            "(\"all of Manhattan with a little breathing room\") — re-verify the coverage " +
            "bounds and margin factor are still what's intended.")
    }

    // MARK: Test 2: the limit now frames the coverage box, not the polyline-hide gate

    /// Round 1 ("zoom-out-limit-tighten") had a test here — `...staysInsidePolylineHideThreshold
    /// WithMargin` — asserting the camera ceiling stayed UNDER `AppConstants
    /// .polylineHideSpanThreshold`. That assertion is now DELIBERATELY FALSE: the premise
    /// ("lock where data ends") was reversed in round 2 ("all of Manhattan is the right
    /// gate"). Deleting that test outright rather than "softening" it — a weakened assertion
    /// would silently stop testing anything meaningful. This test pins the NEW relationship
    /// instead: the ceiling now frames the tile grid's coverage extent, and sits FAR outside
    /// (not inside) the polyline-hide threshold — that gap (~8.3km→~41.5km of basemap-only
    /// zoom) is the accepted, documented trade-off, not a bug to guard against.
    func testMaxZoomOutCenterCoordinateDistance_impliedSpanMatchesCoverageExtentNotPolylineThreshold() {
        let halfHeightMeters = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            * tan(15.0 * .pi / 180.0)
        let impliedVisibleLatSpan = (2 * halfHeightMeters) / 111_000

        let coverageLatSpan = AppConstants.manhattanCoverageBounds.latMax
            - AppConstants.manhattanCoverageBounds.latMin

        // The implied span now matches the MARGINED coverage extent, not the polyline gate.
        XCTAssertEqual(
            impliedVisibleLatSpan, coverageLatSpan * 1.1, accuracy: 0.0005,
            "The zoom-out limit's implied visible span (\(impliedVisibleLatSpan)°) no longer " +
            "matches the margined tile-grid coverage extent " +
            "(\(coverageLatSpan * 1.1)°) — the camera ceiling's derivation source changed " +
            "without updating this test, or vice versa."
        )

        // And it is now well OUTSIDE (wider than) the polyline-hide gate — the opposite of
        // round 1's invariant, and intentional: lines fade well before the camera limit.
        XCTAssertGreaterThan(
            impliedVisibleLatSpan, AppConstants.polylineHideSpanThreshold * 4,
            "The zoom-out ceiling's implied span (\(impliedVisibleLatSpan)°) is no longer " +
            "comfortably wider than AppConstants.polylineHideSpanThreshold " +
            "(\(AppConstants.polylineHideSpanThreshold)°) — if this shrank back toward the " +
            "polyline gate, the two constants may have been accidentally re-coupled."
        )
    }

    // MARK: Test 3: the camera limit tracks coverage bounds, not the polyline threshold

    /// The whole point of deriving `maxZoomOutCenterCoordinateDistance` FROM
    /// `AppConstants.manhattanCoverageBounds` (rather than a second, independently-tuned
    /// hardcoded number, or — as round 1 had it — from `polylineHideSpanThreshold`) is that
    /// the camera ceiling and the coverage box can never drift apart without this test
    /// catching it. This re-derives the expected implied span directly from the live
    /// `AppConstants.manhattanCoverageBounds` value at test time — if someone reverts the
    /// camera constant to a hardcoded literal (undoing the derivation) and later retunes the
    /// coverage bounds (e.g. the tile grid grows), this is the test that fails.
    ///
    /// Round 1's analogous test (`...tracksPolylineHideThreshold`) asserted coupling to
    /// `polylineHideSpanThreshold` instead — that coupling no longer exists as of round 2;
    /// this test replaces it rather than leaving a stale, now-false assertion in place.
    func testMaxZoomOutCenterCoordinateDistance_tracksManhattanCoverageBounds() {
        let halfHeightMeters = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            * tan(15.0 * .pi / 180.0)
        let impliedVisibleLatSpan = (2 * halfHeightMeters) / 111_000

        let coverageLatSpan = AppConstants.manhattanCoverageBounds.latMax
            - AppConstants.manhattanCoverageBounds.latMin
        let expectedSpan = coverageLatSpan
            * MapViewRepresentable.manhattanCoverageZoomOutMarginFactor

        XCTAssertEqual(
            impliedVisibleLatSpan, expectedSpan, accuracy: 0.0001,
            "maxZoomOutCenterCoordinateDistance's implied visible span " +
            "(\(impliedVisibleLatSpan)°) no longer matches " +
            "AppConstants.manhattanCoverageBounds' lat span × " +
            "manhattanCoverageZoomOutMarginFactor (\(expectedSpan)°) — the camera zoom-out " +
            "ceiling and the tile grid's coverage extent have drifted apart. If the coverage " +
            "bounds were intentionally changed (tile grid grew/shrank), " +
            "maxZoomOutCenterCoordinateDistance must be computed FROM the new value (it " +
            "already should be, automatically — check it wasn't hardcoded back to a literal)."
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
    /// `testInitialBrowseRegion_isNoLongerClampedAtLaunch` below, which documents that call
    /// is now well inside the (much wider) ceiling too.
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

    // MARK: Test 5: the cold-launch default region is no longer clamped at launch

    /// Round 1: `ContentView`'s cold-launch default `region` (0.07° lat / 0.05° lng span,
    /// ~14,499m altitude, set before any recenter logic runs) was WIDER than the
    /// then-tightened ~7,457m zoom-out ceiling, so `setCameraZoomRange` immediately clamped
    /// the initial camera down to the ceiling. This test asserted that clamping as
    /// intentional.
    ///
    /// Round 2 (this file's current state): the ceiling widened to ~41,467m — well past the
    /// default region's ~14,499m altitude — so the default region is no longer clamped at
    /// all. This inverts round 1's assertion; renamed (rather than re-using the old name
    /// with flipped logic) so a diff makes the reversal obvious.
    ///
    /// If this assertion ever flips back (the default region altitude exceeds the ceiling
    /// again), it most likely means the ceiling was tightened again — reconcile with
    /// `MapViewRepresentable.maxZoomOutCenterCoordinateDistance`'s doc comment rather than
    /// deleting this test.
    func testInitialBrowseRegion_isNoLongerClampedAtLaunch() {
        let initialRegionLatSpan = 0.07
        let initialRegionAltitude = MapViewRepresentable.altitudeForSpan(initialRegionLatSpan)

        XCTAssertLessThan(
            initialRegionAltitude, MapViewRepresentable.maxZoomOutCenterCoordinateDistance,
            "ContentView's cold-launch default region (0.07° lat span, altitude " +
            "\(initialRegionAltitude)m) is no longer narrower than " +
            "maxZoomOutCenterCoordinateDistance " +
            "(\(MapViewRepresentable.maxZoomOutCenterCoordinateDistance)m) — the " +
            "documented \"launch is no longer clamped\" behavior no longer applies. Update " +
            "this test and the doc comment together if that's intentional."
        )
    }

    // MARK: Test 6: the camera limit is tighter than TileLoader's load backstop

    /// `TileLoader.maxLoadSpanDegrees` (0.5°) is the OUTER backstop that stops tile
    /// loading entirely — it exists to guard a transient mid-gesture span independent of
    /// how far the user can actually zoom (see `AppConstants.polylineHideSpanThreshold`'s
    /// doc comment for the full "three-layer, defense in depth" relationship). This test
    /// confirms the new steady-state camera ceiling (~41,467m, ~0.2° span) sits comfortably
    /// inside that backstop (0.5° span, ~103,500m altitude), i.e. the user's reachable zoom
    /// range never gets far enough out to trip the load-skip guard — tiles keep loading
    /// throughout the whole reachable range even after the round-2 widening.
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

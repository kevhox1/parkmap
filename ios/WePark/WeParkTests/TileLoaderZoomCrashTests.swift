//
//  TileLoaderZoomCrashTests.swift
//  WeParkTests
//
//  Zoom-out crash fix (2026-08-23): Kevin hit a reproducible crash on-device when
//  zooming far out — already archived in build 17, with external TestFlight testers
//  live. Root cause: `TileLoader.tileKeys(forRegion:)` converted the visible region
//  into a row/col tile range and looped EVERY combination with no upper bound before
//  checking `tileSet` membership. The tile grid is fine-grained (rowSize ≈ 0.00227°,
//  colSize ≈ 0.00226°), so span growth exploded the iteration count — world-scale
//  spans reached ~12.6 billion iterations, each doing a string interpolation + Set
//  lookup. That is a watchdog termination presenting as a crash. Kevin's separate
//  "still some lag when scrolling and zooming" report is treated as the SAME loop at
//  smaller scale (no evidence points elsewhere).
//
//  A second, independent failure mode: `Int(floor(x))` TRAPS at runtime (not merely
//  slow) for non-finite (NaN/±infinity) or out-of-`Int`-range `Double` input. MapKit
//  is known to report a degenerate `region.span` (very large or non-finite
//  `latitudeDelta`) when the camera is at extreme pitch/altitude mid-gesture — a
//  reachable path to an INSTANT crash rather than a hang.
//
//  Fix (`TileLoader.swift`):
//    1. `tileKeys(forRegion:...)` bails out to `[]` if any of the derived
//       south/north/west/east bounds are non-finite, BEFORE any Int conversion.
//    2. Row/col ranges are clamped to the tile grid's ACTUAL extent (`gridRows` /
//       `gridCols`, from index.json's `gridSize`) via `clampToInt` — which never
//       traps — before the nested loop runs. This bounds iteration count to
//       roughly `(gridRows + 2·buffer) × (gridCols + 2·buffer)` for ANY input,
//       valid or not, independent of the requested viewport's span.
//    3. `TileLoader.maxLoadSpanDegrees` (0.5°) gates `loadTiles(forRegion:)` itself:
//       above that span, no tile-key computation or bundle decode happens at all —
//       NYC's real tile coverage is only ~0.182° lat × 0.113° lng (index.json
//       latMin/latMax/lngMin/lngMax), so a 0.5°+ viewport already shows all of NYC
//       as a sub-pixel smear before this method would even run.
//
//  This file tests the pure, `Bundle`-independent `TileLoader.tileKeys(forRegion:
//  gridRows:gridCols:latMin:lngMin:rowSize:colSize:tileSet:buffer:)` static function
//  directly — no `TileLoader` instance, no `index.json` bundle load, no simulator.
//  A synthetic small grid (10 rows × 8 cols) is used throughout so test assertions
//  don't depend on the real ~1,071-tile production tile set.
//
//  This PR is COMPILE-UNVERIFIED (written on a Linux VPS with no Xcode/simulator/
//  Swift toolchain) — Kevin must confirm `xcodebuild test` passes AND run the
//  on-device pinch-to-world-zoom smoke checklist in the PR body before merge.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Synthetic grid fixture

/// A small, fully-controlled tile grid used across every test in this file so
/// assertions don't depend on the real production tile set (1,071 tiles across an
/// 80×50 grid) or require loading `index.json` from a bundle.
///
/// Mirrors the real grid's shape (sparse — not every row/col combination is a real
/// tile) without its scale, so tests stay fast and their expected results stay
/// hand-verifiable.
private enum SyntheticGrid {
    static let gridRows = 10
    static let gridCols = 8
    static let latMin = 40.70
    static let lngMin = -74.02
    static let rowSize = 0.01
    static let colSize = 0.01

    /// A sparse tile set: every (row, col) EXCEPT the four grid corners and a few
    /// interior cells. Deliberately excludes (0, 0) and (gridRows-1, gridCols-1) so
    /// tests can distinguish "clamped into range" from "clamped into a real tile".
    static let tileSet: Set<String> = {
        var set = Set<String>()
        for r in 0..<gridRows {
            for c in 0..<gridCols {
                if r == 0 && c == 0 { continue }                       // corner, excluded
                if r == gridRows - 1 && c == gridCols - 1 { continue }  // corner, excluded
                set.insert("\(r)_\(c)")
            }
        }
        return set
    }()

    /// Total real tiles: full grid minus the two excluded corners.
    static var totalTileCount: Int { gridRows * gridCols - 2 }

    static func call(_ region: MKCoordinateRegion, buffer: Int = 2) -> [String] {
        TileLoader.tileKeys(
            forRegion: region,
            gridRows: gridRows,
            gridCols: gridCols,
            latMin: latMin,
            lngMin: lngMin,
            rowSize: rowSize,
            colSize: colSize,
            tileSet: tileSet,
            buffer: buffer
        )
    }
}

private func region(
    lat: CLLocationDegrees,
    lng: CLLocationDegrees,
    latSpan: CLLocationDegrees,
    lngSpan: CLLocationDegrees
) -> MKCoordinateRegion {
    MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
        span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lngSpan)
    )
}

// MARK: - Group 1: Grid-extent clamping (the primary crash fix)

final class TileLoaderGridClampingTests: XCTestCase {

    /// A viewport comfortably inside the grid returns exactly the real tiles it
    /// overlaps (sanity check that clamping doesn't change in-bounds behavior).
    func testTileKeys_normalInBoundsRegion_returnsOverlappingRealTiles() {
        // Center on row ~5, col ~4 with a small span (buffer 0 for a precise check).
        let r = region(
            lat: SyntheticGrid.latMin + 5.5 * SyntheticGrid.rowSize,
            lng: SyntheticGrid.lngMin + 4.5 * SyntheticGrid.colSize,
            latSpan: SyntheticGrid.rowSize * 0.5,
            lngSpan: SyntheticGrid.colSize * 0.5
        )
        let keys = SyntheticGrid.call(r, buffer: 0)
        XCTAssertEqual(keys, ["5_4"], "A tight in-bounds viewport should return exactly the tile it centers on")
    }

    /// A viewport spanning the ENTIRE globe (180° lat, 360° lng) must not hang or
    /// crash, and — since the clamp covers the grid's full extent — must return
    /// exactly every real tile in the grid (no more, no fewer).
    func testTileKeys_worldSpanRegion_returnsBoundedFullGridCoverage() {
        let r = region(lat: 0, lng: 0, latSpan: 180, lngSpan: 360)
        let keys = SyntheticGrid.call(r)
        XCTAssertEqual(
            Set(keys).count, SyntheticGrid.totalTileCount,
            "A world-span viewport must be clamped to the grid's real extent and " +
            "return every real tile exactly once — not hang, and not silently drop tiles"
        )
        XCTAssertEqual(Set(keys), SyntheticGrid.tileSet, "World-span result must equal the full real tile set")
    }

    /// A region entirely outside the tile grid's coverage (e.g. mid-ocean, far from
    /// latMin/lngMin) must clamp into range WITHOUT accidentally producing false
    /// hits — the synthetic grid's corner (0,0) is deliberately NOT a real tile, so
    /// a viewport southwest of the whole grid, which clamps to (0,0), must return
    /// empty.
    func testTileKeys_regionEntirelyOutsideGrid_returnsEmptyNotFalseHits() {
        // Center far southwest of the grid's coverage — clamps toward row 0 / col 0.
        let r = region(
            lat: SyntheticGrid.latMin - 50,
            lng: SyntheticGrid.lngMin - 50,
            latSpan: 0.01,
            lngSpan: 0.01
        )
        let keys = SyntheticGrid.call(r, buffer: 0)
        XCTAssertEqual(keys, [], "Clamping into range must not fabricate hits for tiles that don't exist")
    }

    /// A region far outside the grid to the northeast clamps to the opposite
    /// (also-excluded) corner and must likewise return empty.
    func testTileKeys_regionFarNortheastOfGrid_returnsEmpty() {
        let r = region(
            lat: SyntheticGrid.latMin + 500,
            lng: SyntheticGrid.lngMin + 500,
            latSpan: 0.01,
            lngSpan: 0.01
        )
        let keys = SyntheticGrid.call(r, buffer: 0)
        XCTAssertEqual(keys, [], "A far-northeast region should clamp to the excluded far corner and return empty")
    }

    /// Hard upper bound: for ANY input (even absurd, off-grid, huge spans), the
    /// number of loop iterations — and therefore the result size — is bounded by
    /// the grid's real extent plus buffer, never by the viewport.
    func testTileKeys_anySpan_resultNeverExceedsGridTileCount() {
        let spans: [CLLocationDegrees] = [0.001, 1, 10, 50, 180, 1000, 1_000_000]
        for span in spans {
            let r = region(lat: 0, lng: 0, latSpan: span, lngSpan: span)
            let keys = SyntheticGrid.call(r)
            XCTAssertLessThanOrEqual(
                keys.count, SyntheticGrid.totalTileCount,
                "Result for span \(span)° must never exceed the grid's total real tile count"
            )
        }
    }
}

// MARK: - Group 2: Degenerate / inverted span handling

final class TileLoaderDegenerateSpanTests: XCTestCase {

    /// A negative span inverts south/north (and west/east), producing rowMin >
    /// rowMax after the math — must return empty, not crash or silently mis-render.
    ///
    /// `buffer: 0` is explicit here (rather than the default 2): the buffer widens
    /// the row/col range on both ends, so a MILDLY inverted span can be "rescued"
    /// back into a valid (non-empty) range by a large-enough buffer. This test
    /// isolates the inversion-guard behavior itself, independent of the buffer.
    func testTileKeys_negativeSpan_returnsEmpty() {
        let r = region(
            lat: SyntheticGrid.latMin + 5 * SyntheticGrid.rowSize,
            lng: SyntheticGrid.lngMin + 4 * SyntheticGrid.colSize,
            latSpan: -0.02,
            lngSpan: -0.02
        )
        let keys = SyntheticGrid.call(r, buffer: 0)
        XCTAssertEqual(keys, [], "A degenerate/inverted span must return no tiles, not crash")
    }

    /// A zero span (center point, no area) is a valid degenerate case that must
    /// still resolve to at most the single tile containing that point.
    func testTileKeys_zeroSpan_resolvesToAtMostOneRealTileAtBufferZero() {
        let r = region(
            lat: SyntheticGrid.latMin + 5.5 * SyntheticGrid.rowSize,
            lng: SyntheticGrid.lngMin + 4.5 * SyntheticGrid.colSize,
            latSpan: 0,
            lngSpan: 0
        )
        let keys = SyntheticGrid.call(r, buffer: 0)
        XCTAssertEqual(keys, ["5_4"], "A zero-span region should still resolve to the single containing tile")
    }
}

// MARK: - Group 3: Non-finite region math (the Int-conversion-trap path)

final class TileLoaderNonFiniteRegionTests: XCTestCase {

    /// NaN latitude span (a value MapKit can plausibly report mid-gesture at
    /// extreme camera pitch) must return empty rather than trapping in
    /// `Int(floor(x))`. Reaching this assertion at all is the pass condition —
    /// pre-fix, this call would have crashed the process.
    func testTileKeys_nanLatitudeSpan_returnsEmptyWithoutTrapping() {
        let r = region(lat: 40.75, lng: -73.98, latSpan: .nan, lngSpan: 0.01)
        let keys = SyntheticGrid.call(r)
        XCTAssertEqual(keys, [], "NaN span must degrade to no tiles, not trap")
    }

    /// NaN center latitude (e.g. an invalid camera/location state) must likewise
    /// short-circuit to empty.
    func testTileKeys_nanCenterLatitude_returnsEmptyWithoutTrapping() {
        let r = region(lat: .nan, lng: -73.98, latSpan: 0.01, lngSpan: 0.01)
        let keys = SyntheticGrid.call(r)
        XCTAssertEqual(keys, [], "NaN center latitude must degrade to no tiles, not trap")
    }

    /// Infinite span (theoretically reachable via degenerate MapKit camera state)
    /// makes `south`/`north` themselves non-finite (`0 - .infinity == -.infinity`),
    /// so this hits the same finite-guard bailout as the NaN cases above — must not
    /// trap, and must return a bounded (here: empty) result.
    func testTileKeys_infiniteSpan_returnsBoundedResultWithoutTrapping() {
        let r = region(lat: 0, lng: 0, latSpan: .infinity, lngSpan: .infinity)
        let keys = SyntheticGrid.call(r)
        XCTAssertLessThanOrEqual(
            keys.count, SyntheticGrid.totalTileCount,
            "Infinite span must clamp to a bounded result, not trap or hang"
        )
    }

    /// A span so large that `floor((south - latMin) / rowSize)` would exceed
    /// `Int.max` if converted directly — must clamp instead of trapping.
    func testTileKeys_outOfIntRangeSpan_returnsBoundedResultWithoutTrapping() {
        // 1e300 degrees is absurd but finite — floor(1e300 / 0.01) is still finite
        // as a Double, yet vastly exceeds Int64.max, which is exactly the case
        // `Int(floor(x))` cannot handle without trapping.
        let r = region(lat: 0, lng: 0, latSpan: 1e300, lngSpan: 1e300)
        let keys = SyntheticGrid.call(r)
        XCTAssertLessThanOrEqual(
            keys.count, SyntheticGrid.totalTileCount,
            "An out-of-Int-range (but finite) span must clamp, not trap"
        )
    }
}

// MARK: - Group 4: clampToInt — the trap-free Double→Int conversion helper

final class TileLoaderClampToIntTests: XCTestCase {

    func testClampToInt_valueWithinRange_returnsValue() {
        XCTAssertEqual(TileLoader.clampToInt(5.7, lower: 0, upper: 10), 5)
    }

    func testClampToInt_valueBelowLower_clampsToLower() {
        XCTAssertEqual(TileLoader.clampToInt(-100, lower: 0, upper: 10), 0)
    }

    func testClampToInt_valueAboveUpper_clampsToUpper() {
        XCTAssertEqual(TileLoader.clampToInt(9999, lower: 0, upper: 10), 10)
    }

    func testClampToInt_nan_clampsToLowerBound() {
        // NaN comparisons are always false, so without an explicit isFinite guard
        // this would fall through to `Int(NaN)`, which traps. `value > 0` on NaN is
        // also false, so NaN clamps to `lower` — documented, deterministic behavior.
        XCTAssertEqual(TileLoader.clampToInt(.nan, lower: 0, upper: 10), 0)
    }

    func testClampToInt_positiveInfinity_clampsToUpper() {
        XCTAssertEqual(TileLoader.clampToInt(.infinity, lower: 0, upper: 10), 10)
    }

    func testClampToInt_negativeInfinity_clampsToLower() {
        XCTAssertEqual(TileLoader.clampToInt(-.infinity, lower: 0, upper: 10), 0)
    }

    func testClampToInt_valueExceedingIntMaxAsDouble_clampsToUpperWithoutTrapping() {
        // Far larger than Int64.max — `Int(1e300)` traps. clampToInt must not.
        XCTAssertEqual(TileLoader.clampToInt(1e300, lower: 0, upper: 79), 79)
    }
}

// MARK: - Group 5: maxLoadSpanDegrees — documented, named threshold

final class TileLoaderMaxLoadSpanTests: XCTestCase {

    /// The threshold is a single named constant so it's trivially tunable — this
    /// test locks in the chosen value (0.5°) and will fail loudly (not silently) if
    /// someone changes it, prompting an update to this test's rationale comment.
    func testMaxLoadSpanDegrees_isDocumentedValue() {
        XCTAssertEqual(
            TileLoader.maxLoadSpanDegrees, 0.5,
            "maxLoadSpanDegrees changed — chosen from NYC's real tile coverage " +
            "(~0.182° lat × 0.113° lng, index.json). Update this test alongside " +
            "the constant's doc comment if the value is intentionally retuned."
        )
    }
}

//
//  CurbSnapNearbyBlockfacesTests.swift
//  WeParkTests
//
//  Tests for `CurbSnapIndex.nearbyBlockfaces(_:radius:)` — the distance-ordered list of real
//  nearby curbs that backs the placement mode's VoiceOver adjustable element
//  (docs/design/curb-pin-placement-design.md section 4). Shares fixtures with the A1 engine
//  tests (CurbSnapTestFixtures.swift).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Geometry convention (see CurbSnapTestFixtures): local metres, x = east, y = north.
//  Two-sided street: north curb "N" at y = +7.5, south curb "S" at y = -7.5.
//
//  Distance tolerances are >= 0.15 m wherever the scan's flat-earth metric and the reported
//  haversine distance can differ (PR #137 QA nit).
//
//  Test inventory (9 tests, 1 class):
//    CurbSnapNearbyBlockfacesTests:
//      1. testNearby_twoSidedStreet_returnsBothSidesOrderedByDistance
//      2. testNearby_blockfaceInTwoTiles_oneEntryAtNearestCopy
//      3. testNearby_radiusBoundary_justInsideAndJustOutside
//      4. testNearby_nothingInRange_returnsEmpty
//      5. testNearby_wideRadius_findsCurbBeyondThreeByThreeBlock
//      6. testNearby_consistentWithResolve_firstElementIsTheAcquiredBlockface
//      7. testNearby_exactTie_deterministicAcross100ShuffledInputOrders
//      8. testNearby_hugeNaNInfiniteRadius_doesNotTrap
//      9. testNearby_syntheticGrid_sortedAndOneEntryPerBlockface
//
//  Helper names carry a unique `cnb` prefix and are file-private — no XCTestCase extension
//  (compile-failure class 4).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers

private func cnbPoint(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
    CurbSnapTestFixtures.coordinate(x: x, y: y)
}

/// Metres between two coordinates using the fixtures' flat-earth scale.
private func cnbMetersBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let metersPerDegLat = 111_320.0
    let metersPerDegLng = 111_320.0 * cos(40.7128 * Double.pi / 180.0)
    let dx = (a.longitude - b.longitude) * metersPerDegLng
    let dy = (a.latitude - b.latitude) * metersPerDegLat
    return (dx * dx + dy * dy).squareRoot()
}

private func cnbKeys(_ results: [CurbSnapResult]) -> [String] {
    results.map { (result: CurbSnapResult) -> String in result.blockfaceKey }
}

private func cnbDistances(_ results: [CurbSnapResult]) -> [Double] {
    results.map { (result: CurbSnapResult) -> Double in result.distanceMeters }
}

private let cnbKeyN = CurbSnapTestFixtures.key(side: "N")
private let cnbKeyS = CurbSnapTestFixtures.key(side: "S")

/// The standard two-sided street: N curb at y=+7.5, S curb at y=-7.5.
private func cnbTwoSidedStreet() -> [Segment] {
    [
        CurbSnapTestFixtures.eastWestCurb(id: "NB-N1", side: "N", y: 7.5),
        CurbSnapTestFixtures.eastWestCurb(id: "NB-S1", side: "S", y: -7.5),
    ]
}

// MARK: - nearbyBlockfaces

final class CurbSnapNearbyBlockfacesTests: XCTestCase {

    // 1
    func testNearby_twoSidedStreet_returnsBothSidesOrderedByDistance() {
        let index = CurbSnapIndex(segments: cnbTwoSidedStreet())

        // Pin 2 m north of the centreline: N is 5.5 m away, S is 9.5 m away.
        let nearNorth = index.nearbyBlockfaces(cnbPoint(0, 2), radius: 24)
        XCTAssertEqual(cnbKeys(nearNorth), [cnbKeyN, cnbKeyS])
        if nearNorth.count == 2 {
            XCTAssertEqual(nearNorth[0].distanceMeters, 5.5, accuracy: 0.15)
            XCTAssertEqual(nearNorth[1].distanceMeters, 9.5, accuracy: 0.15)
            // Foot points sit ON the curbs (x = 0, y = +/-7.5), not at the block midpoint.
            XCTAssertEqual(cnbMetersBetween(nearNorth[0].snappedCoordinate, cnbPoint(0, 7.5)), 0, accuracy: 0.15)
            XCTAssertEqual(cnbMetersBetween(nearNorth[1].snappedCoordinate, cnbPoint(0, -7.5)), 0, accuracy: 0.15)
        }

        // Mirror: 2 m south of the centreline flips the order.
        let nearSouth = index.nearbyBlockfaces(cnbPoint(0, -2), radius: 24)
        XCTAssertEqual(cnbKeys(nearSouth), [cnbKeyS, cnbKeyN])
    }

    // 2
    func testNearby_blockfaceInTwoTiles_oneEntryAtNearestCopy() {
        // Same blockface in two tiles (from/to swapped, different id, farther away), plus an
        // unrelated blockface between them in distance.
        let copy1 = CurbSnapTestFixtures.eastWestCurb(id: "NB-T1", from: "A ST", to: "B ST", side: "N", y: 3)
        let copy2 = CurbSnapTestFixtures.eastWestCurb(id: "NB-T2", from: "B ST", to: "A ST", side: "N", y: 12)
        XCTAssertEqual(copy1.blockfaceKey, copy2.blockfaceKey, "fixture sanity: same blockface")
        let other = CurbSnapTestFixtures.eastWestCurb(id: "NB-O1", street: "OTHER ST", side: "S", y: -8)
        let index = CurbSnapIndex(segments: [copy2, other, copy1])

        let results = index.nearbyBlockfaces(cnbPoint(0, 0), radius: 24)
        XCTAssertEqual(results.count, 2, "two distinct blockfaces, not three segments")
        XCTAssertEqual(cnbKeys(results), [copy1.blockfaceKey, other.blockfaceKey])
        if results.count == 2 {
            XCTAssertEqual(results[0].segment.id, "NB-T1", "the nearer copy represents the blockface")
            XCTAssertEqual(results[0].distanceMeters, 3.0, accuracy: 0.15)
            XCTAssertEqual(results[1].segment.id, "NB-O1")
            XCTAssertEqual(results[1].distanceMeters, 8.0, accuracy: 0.15)
        }
    }

    // 3
    func testNearby_radiusBoundary_justInsideAndJustOutside() {
        // One curb 15 m north of the pin.
        let curb = CurbSnapTestFixtures.eastWestCurb(id: "NB-B1", side: "N", y: 15)
        let index = CurbSnapIndex(segments: [curb])
        let pin = cnbPoint(0, 0)

        XCTAssertEqual(index.nearbyBlockfaces(pin, radius: 15.5).count, 1, "15.5 m radius includes a 15 m curb")
        XCTAssertEqual(index.nearbyBlockfaces(pin, radius: 14.5).count, 0, "14.5 m radius excludes a 15 m curb")

        // The same boundary on the other side of a 32 m cell edge (curb at y = 33, pin in the
        // cell below) so the boundary is not only tested inside one cell.
        let farCurb = CurbSnapTestFixtures.eastWestCurb(id: "NB-B2", side: "S", y: 33)
        let farIndex = CurbSnapIndex(segments: [farCurb])
        XCTAssertEqual(farIndex.nearbyBlockfaces(cnbPoint(0, 10), radius: 23.5).count, 1)
        XCTAssertEqual(farIndex.nearbyBlockfaces(cnbPoint(0, 10), radius: 22.5).count, 0)
    }

    // 4
    func testNearby_nothingInRange_returnsEmpty() {
        let pin = cnbPoint(0, 0)

        // Empty index.
        XCTAssertTrue(CurbSnapIndex(segments: []).nearbyBlockfaces(pin, radius: 100).isEmpty)

        // Curb present but out of range.
        let farCurb = CurbSnapTestFixtures.eastWestCurb(id: "NB-E1", side: "N", y: 40)
        let index = CurbSnapIndex(segments: [farCurb])
        XCTAssertTrue(index.nearbyBlockfaces(pin, radius: 24).isEmpty)

        // Zero and negative radii find nothing when no curb passes through the pin.
        XCTAssertTrue(index.nearbyBlockfaces(pin, radius: 0).isEmpty)
        XCTAssertTrue(index.nearbyBlockfaces(pin, radius: -5).isEmpty)

        // A pin sitting on a curb is found by a (near-)zero radius.
        let onCurb = CurbSnapIndex(segments: [CurbSnapTestFixtures.eastWestCurb(id: "NB-E2", side: "N", y: 0)])
        XCTAssertEqual(onCurb.nearbyBlockfaces(pin, radius: 0.01).count, 1)

        // A pin far outside the city is rejected rather than scanned.
        let offMap = CLLocationCoordinate2D(latitude: -80, longitude: 170)
        XCTAssertTrue(index.nearbyBlockfaces(offMap, radius: 24).isEmpty)
    }

    // 5
    func testNearby_wideRadius_findsCurbBeyondThreeByThreeBlock() {
        // A curb 80 m north is outside the pin cell's 3x3 block (reach is 32-64 m) but inside
        // a 100 m radius, which widens the scan automatically.
        let near = CurbSnapTestFixtures.eastWestCurb(id: "NB-W1", street: "NEAR ST", side: "S", y: -10)
        let far = CurbSnapTestFixtures.eastWestCurb(id: "NB-W2", street: "FAR ST", side: "N", y: 80)
        let index = CurbSnapIndex(segments: [far, near])
        let pin = cnbPoint(0, 0)

        let wide = index.nearbyBlockfaces(pin, radius: 100)
        XCTAssertEqual(cnbKeys(wide), [near.blockfaceKey, far.blockfaceKey])
        if wide.count == 2 {
            XCTAssertEqual(wide[0].distanceMeters, 10.0, accuracy: 0.15)
            XCTAssertEqual(wide[1].distanceMeters, 80.0, accuracy: 0.15)
            XCTAssertEqual(cnbMetersBetween(wide[1].snappedCoordinate, cnbPoint(0, 80)), 0, accuracy: 0.15)
        }

        // The default-scale radius does not reach it.
        XCTAssertEqual(cnbKeys(index.nearbyBlockfaces(pin, radius: 24)), [near.blockfaceKey])
    }

    // 6
    func testNearby_consistentWithResolve_firstElementIsTheAcquiredBlockface() {
        let index = CurbSnapIndex(segments: CurbSnapTestFixtures.syntheticGrid(columns: 5, rows: 5))
        let config = CurbSnapConfig.standard
        var rng = CurbSnapTestRNG(seed: 0xB10C)
        var snappedCount = 0
        var emptyCount = 0
        for iteration in 0..<300 {
            let pin = cnbPoint(rng.nextDouble(in: -150, 150), rng.nextDouble(in: -150, 150))
            let outcome = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: config)
            let nearby = index.nearbyBlockfaces(pin, radius: config.acquireRadius)
            switch outcome {
            case .snapped(let result):
                snappedCount += 1
                guard let first = nearby.first else {
                    XCTFail("iteration \(iteration): resolve snapped but nearbyBlockfaces was empty")
                    continue
                }
                XCTAssertEqual(first.blockfaceKey, result.blockfaceKey, "iteration \(iteration)")
                XCTAssertEqual(first.segment.id, result.segment.id, "iteration \(iteration)")
                XCTAssertEqual(first.distanceMeters, result.distanceMeters, accuracy: 0.15, "iteration \(iteration)")
                XCTAssertEqual(first.positionFraction, result.positionFraction, accuracy: 1e-9, "iteration \(iteration)")
            case .noCurbInRange:
                emptyCount += 1
                XCTAssertTrue(nearby.isEmpty, "iteration \(iteration): resolve found no curb but nearby returned \(nearby.count)")
            }
        }
        // Both branches must actually be exercised for the comparison to mean anything.
        XCTAssertGreaterThan(snappedCount, 20)
        XCTAssertGreaterThan(emptyCount, 20)
    }

    // 7
    func testNearby_exactTie_deterministicAcross100ShuffledInputOrders() {
        // Identical geometry on different sides => exactly equal distance, different keys.
        // The tie breaks on blockfaceKey ("...|N" < "...|S"), never on input order.
        let n = CurbSnapTestFixtures.eastWestCurb(id: "NB-TN", side: "N", y: 5)
        let s = CurbSnapTestFixtures.eastWestCurb(id: "NB-TS", side: "S", y: 5)
        let far = CurbSnapTestFixtures.eastWestCurb(id: "NB-TF", street: "FAR ST", side: "E", y: -20)
        let expected = [cnbKeyN, cnbKeyS, far.blockfaceKey]
        var rng = CurbSnapTestRNG(seed: 0xB7)
        for iteration in 0..<100 {
            let shuffled = CurbSnapTestFixtures.shuffled([n, s, far], using: &rng)
            let index = CurbSnapIndex(segments: shuffled)
            let results = index.nearbyBlockfaces(cnbPoint(0, 0), radius: 30)
            XCTAssertEqual(cnbKeys(results), expected, "iteration \(iteration)")
        }
    }

    // 8
    func testNearby_hugeNaNInfiniteRadius_doesNotTrap() {
        let index = CurbSnapIndex(segments: cnbTwoSidedStreet())
        let pin = cnbPoint(0, 2)

        // Huge and +infinite radii clamp to the capped scan block: both curbs are found.
        XCTAssertEqual(index.nearbyBlockfaces(pin, radius: 1e300).count, 2)
        XCTAssertEqual(index.nearbyBlockfaces(pin, radius: Double.greatestFiniteMagnitude).count, 2)
        XCTAssertEqual(index.nearbyBlockfaces(pin, radius: Double.infinity).count, 2)

        // NaN and negative-infinite radii match nothing.
        XCTAssertTrue(index.nearbyBlockfaces(pin, radius: Double.nan).isEmpty)
        XCTAssertTrue(index.nearbyBlockfaces(pin, radius: -Double.infinity).isEmpty)

        // Bad query points never trap.
        let nanPoint = CLLocationCoordinate2D(latitude: Double.nan, longitude: Double.nan)
        let infinitePoint = CLLocationCoordinate2D(latitude: Double.infinity, longitude: -Double.infinity)
        XCTAssertTrue(index.nearbyBlockfaces(nanPoint, radius: 24).isEmpty)
        XCTAssertTrue(index.nearbyBlockfaces(infinitePoint, radius: 1e300).isEmpty)
    }

    // 9
    func testNearby_syntheticGrid_sortedAndOneEntryPerBlockface() {
        let index = CurbSnapIndex(segments: CurbSnapTestFixtures.syntheticGrid(columns: 5, rows: 5))
        var rng = CurbSnapTestRNG(seed: 0x5027)
        var multiEntryCount = 0
        for iteration in 0..<100 {
            let pin = cnbPoint(rng.nextDouble(in: -150, 150), rng.nextDouble(in: -150, 150))
            let radius = rng.nextDouble(in: 5, 90)
            let results = index.nearbyBlockfaces(pin, radius: radius)

            let keys = cnbKeys(results)
            XCTAssertEqual(Set(keys).count, keys.count, "iteration \(iteration): duplicate blockface")

            let distances = cnbDistances(results)
            for i in 1..<max(distances.count, 1) {
                // Allow the flat-earth-vs-haversine slack documented on the API.
                XCTAssertLessThanOrEqual(distances[i - 1], distances[i] + 0.15, "iteration \(iteration): not ascending")
            }
            for distance in distances {
                // Radius filter uses the flat-earth metric; reported distance is haversine.
                XCTAssertLessThanOrEqual(distance, radius + 0.15, "iteration \(iteration): beyond radius")
            }
            if results.count > 1 { multiEntryCount += 1 }
        }
        XCTAssertGreaterThan(multiEntryCount, 20, "the sweep must exercise multi-entry results")
    }
}

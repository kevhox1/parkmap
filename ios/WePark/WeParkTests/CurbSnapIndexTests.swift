//
//  CurbSnapIndexTests.swift
//  WeParkTests
//
//  Stream A1 — correctness tests for the pure curb-snap engine (`CurbSnapIndex`,
//  `CurbSnapConfig`, `CurbSnapResult`, `CurbSnapOutcome`). Spec:
//  docs/longpress-universal-plant-spec.md §A.3 (snap rule), §A.9 (seam contract),
//  §A.11 (acceptance criteria A1-A5). Timing lives in CurbSnapIndexPerformanceTests.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Geometry convention (see CurbSnapTestFixtures): local metres, x = east, y = north.
//  Two-sided street used throughout: north curb "N" at y = +7.5, south curb "S" at y = -7.5
//  (15 m apart), x in [-100, 100]. Hysteresis sims use curb "S" at y = 0 and "N" at y = 15.
//
//  Test inventory (42 tests, 8 classes):
//    CurbSnapConfigTests:
//      1.  testConfig_defaults_matchSpec
//      2.  testConfig_hysteresisMeters_scalesAndClamps
//      3.  testConfig_hysteresisMeters_nonFiniteScale_returnsMinimum
//    CurbSnapEquatableTests:
//      4.  testResult_equatable_comparesIdAndNumbers
//      5.  testOutcome_equatable_distinguishesCases
//    CurbSnapResolveBasicTests (A.11 A1):
//      6.  testResolve_emptySegments_noCurb
//      7.  testResolve_withinAcquire_returnsSegmentFractionDistanceAndOnLineSnap
//      8.  testResolve_twoSidedStreet_picksNearestSide
//      9.  testResolve_positionFraction_multiVertex_matchesNearestPointOnPolyline
//      10. testResolve_pastEndOfPolyline_clampsFractionAndSnapsToVertex
//      11. testResolve_invalidQueryPoint_noCurb
//    CurbSnapRadiiTests (A.11 A5):
//      12. testResolve_beyondReleaseRadius_noCurbInRange_withNearestMeters
//      13. testResolve_acquireBand_noIncumbent_doesNotAcquire
//      14. testResolve_acquireBand_incumbentRetainedInReleaseBand
//      15. testResolve_incumbentBeyondRelease_isDropped
//      16. testResolve_releaseBand_challengerNotAcquirableInBand
//      17. testResolve_releaseBand_acquirableChallengerBeyondDeadband_takesOver
//      18. testResolve_unknownIncumbent_treatedAsNone
//    CurbSnapDedupAndTieTests (A.11 A3, A4):
//      19. testResolve_blockfaceInTwoTiles_resolvesOnceAtNearestCopy
//      20. testResolve_incumbentDistanceIsMinAcrossBlockfaceCopies
//      21. testResolve_exactTie_deterministicAcross100ShuffledInputOrders
//      22. testResolve_mirroredGeometryTie_deterministicAcross100ShuffledInputOrders
//    CurbSnapHysteresisTests (A.11 A2):
//      23. testHysteresis_sweepUp_flipsExactlyOnce
//      24. testHysteresis_sweepDown_flipsExactlyOnce
//      25. testHysteresis_noIncumbentStart_picksNearestThenSticks
//      26. testHysteresis_roundTrip_flipPointsSeparatedByDeadband
//      27. testHysteresis_jitterOnCenterline_zeroFlips
//      28. testHysteresis_noisyCrossing_flipsExactlyOnce
//      29. testHysteresis_deadbandTracksMetersPerPoint
//    CurbSnapGridRobustnessTests:
//      30. testIndex_edgeRegistersInEveryCellItsBBoxCrosses_longDiagonal
//      31. testIndex_cellBoundarySweep_alwaysFindsCurb
//      32. testIndex_longEdge_isSplitIntoPieces
//      33. testIndex_degenerateAndMalformedPolylines_neverCrash_andAreIgnored
//      34. testIndex_zeroLengthPolyline_snapsToItsPoint
//      35. testIndex_malformedMiddlePair_matchesCoordinatesSemantics
//    CurbSnapCustomConfigTests (QA pass 1 fix round: non-default config, scan widening):
//      36. testConfig_customInit_overridesEachField
//      37. testResolve_customSmallRadii_changeAcquireAndRelease
//      38. testHysteresis_customDeadband_movesFlipPoint
//      39. testResolve_wideConfigRecipe_100m_findsCurbBeyondThe3x3Block
//      40. testResolve_wideConfigRecipe_100m_boundariesAndCorners
//      41. testResolve_scanWidening_50mRadiusUsesRingTwo
//      42. testResolve_hugeOrNonFiniteRadius_doesNotTrap
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers (unique `csi` prefix — no XCTestCase extension)

private func csiPoint(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
    CurbSnapTestFixtures.coordinate(x: x, y: y)
}

/// Unwraps `.snapped`, failing the test (and returning nil) otherwise.
private func csiSnapped(
    _ outcome: CurbSnapOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) -> CurbSnapResult? {
    guard case .snapped(let result) = outcome else {
        XCTFail("expected .snapped, got \(outcome)", file: file, line: line)
        return nil
    }
    return result
}

/// Distance in metres between two coordinates using the same flat-earth scale as the fixtures.
private func csiMetersBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let metersPerDegLat = 111_320.0
    let metersPerDegLng = 111_320.0 * cos(40.7128 * Double.pi / 180.0)
    let dx = (a.longitude - b.longitude) * metersPerDegLng
    let dy = (a.latitude - b.latitude) * metersPerDegLat
    return (dx * dx + dy * dy).squareRoot()
}

/// Feeds each pin position through `resolve`, threading the incumbent exactly like the
/// live driver will (previous winner's key). Returns the winner key per step.
private func csiRun(
    index: CurbSnapIndex,
    path: [CLLocationCoordinate2D],
    startIncumbent: String?,
    metersPerPoint: Double,
    config: CurbSnapConfig = CurbSnapConfig.standard
) -> [String?] {
    var incumbent = startIncumbent
    var keys: [String?] = []
    for point in path {
        let outcome = index.resolve(point, incumbent: incumbent, metersPerPoint: metersPerPoint, config: config)
        if case .snapped(let result) = outcome {
            incumbent = result.blockfaceKey
            keys.append(result.blockfaceKey)
        } else {
            keys.append(nil)
        }
    }
    return keys
}

/// Number of times consecutive entries differ.
private func csiFlipCount(_ keys: [String?]) -> Int {
    var flips = 0
    for i in 1..<max(keys.count, 1) where keys[i] != keys[i - 1] {
        flips += 1
    }
    return flips
}

/// Index of the first step whose key differs from the previous one, or nil.
private func csiFirstFlipIndex(_ keys: [String?]) -> Int? {
    for i in 1..<max(keys.count, 1) where keys[i] != keys[i - 1] {
        return i
    }
    return nil
}

private let csiKeyN = CurbSnapTestFixtures.key(side: "N")
private let csiKeyS = CurbSnapTestFixtures.key(side: "S")

/// The standard two-sided street: N curb at y=+7.5, S curb at y=-7.5.
private func csiTwoSidedStreet() -> [Segment] {
    [
        CurbSnapTestFixtures.eastWestCurb(id: "N1", side: "N", y: 7.5),
        CurbSnapTestFixtures.eastWestCurb(id: "S1", side: "S", y: -7.5),
    ]
}

/// Two parallel curbs 15 m apart for the hysteresis sims: S at y=0, N at y=15.
private func csiParallelCurbs() -> [Segment] {
    [
        CurbSnapTestFixtures.eastWestCurb(id: "HS", side: "S", y: 0),
        CurbSnapTestFixtures.eastWestCurb(id: "HN", side: "N", y: 15),
    ]
}

/// Path along the y axis (x = 0) from `from` to `to` in `steps` equal steps (inclusive).
private func csiYPath(from: Double, to: Double, steps: Int) -> [CLLocationCoordinate2D] {
    (0...steps).map { (i: Int) -> CLLocationCoordinate2D in
        let t = Double(i) / Double(steps)
        return csiPoint(0, from + (to - from) * t)
    }
}

// MARK: - CurbSnapConfig

final class CurbSnapConfigTests: XCTestCase {

    func testConfig_defaults_matchSpec() {
        let config = CurbSnapConfig()
        XCTAssertEqual(config.acquireRadius, 24.0)
        XCTAssertEqual(config.releaseRadius, 30.0)
        XCTAssertEqual(config.hysteresisPoints, 14.0)
        XCTAssertEqual(config.hysteresisMinMeters, 1.5)
        XCTAssertEqual(config.hysteresisMaxMeters, 4.0)
        XCTAssertEqual(config, CurbSnapConfig.standard)
        // release = 1.25x acquire (spec §A.3 step 3)
        XCTAssertEqual(config.releaseRadius, config.acquireRadius * 1.25, accuracy: 1e-9)
    }

    func testConfig_hysteresisMeters_scalesAndClamps() {
        let config = CurbSnapConfig()
        // ~entry zoom (0.28 m/pt): 14 pt = 3.92 m, just inside the 4.0 ceiling.
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0.28), 3.92, accuracy: 1e-9)
        // Deep zoom-in: floor.
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0.05), 1.5, accuracy: 1e-9)
        // Zoom-out: ceiling.
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 2.0), 4.0, accuracy: 1e-9)
        // Exactly at the boundaries.
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 1.5 / 14.0), 1.5, accuracy: 1e-9)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0.5), 4.0, accuracy: 1e-9)
    }

    func testConfig_hysteresisMeters_nonFiniteScale_returnsMinimum() {
        let config = CurbSnapConfig()
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: .nan), 1.5)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0), 1.5)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: -3), 1.5)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: .infinity), 1.5)
    }
}

// MARK: - Equatable conformances

final class CurbSnapEquatableTests: XCTestCase {

    private func makeResult(
        id: String = "N1",
        fraction: Double = 0.5,
        distance: Double = 4.0,
        x: Double = 0,
        y: Double = 7.5
    ) -> CurbSnapResult {
        CurbSnapResult(
            segment: CurbSnapTestFixtures.eastWestCurb(id: id, side: "N", y: 7.5),
            positionFraction: fraction,
            distanceMeters: distance,
            snappedCoordinate: csiPoint(x, y)
        )
    }

    func testResult_equatable_comparesIdAndNumbers() {
        XCTAssertEqual(makeResult(), makeResult())
        XCTAssertNotEqual(makeResult(), makeResult(id: "OTHER"))
        XCTAssertNotEqual(makeResult(), makeResult(fraction: 0.6))
        XCTAssertNotEqual(makeResult(), makeResult(distance: 4.5))
        XCTAssertNotEqual(makeResult(), makeResult(x: 1))
    }

    func testOutcome_equatable_distinguishesCases() {
        XCTAssertEqual(CurbSnapOutcome.noCurbInRange(nearestMeters: nil),
                       CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
        XCTAssertEqual(CurbSnapOutcome.noCurbInRange(nearestMeters: 31),
                       CurbSnapOutcome.noCurbInRange(nearestMeters: 31))
        XCTAssertNotEqual(CurbSnapOutcome.noCurbInRange(nearestMeters: 31),
                          CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
        XCTAssertNotEqual(CurbSnapOutcome.noCurbInRange(nearestMeters: 31),
                          CurbSnapOutcome.snapped(makeResult()))
        XCTAssertEqual(CurbSnapOutcome.snapped(makeResult()), CurbSnapOutcome.snapped(makeResult()))
    }
}

// MARK: - Basic resolve

final class CurbSnapResolveBasicTests: XCTestCase {

    func testResolve_emptySegments_noCurb() {
        let index = CurbSnapIndex(segments: [])
        XCTAssertEqual(index.edgeCount, 0)
        XCTAssertEqual(index.segmentCount, 0)
        let outcome = index.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(outcome, CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
        // Incumbent on an empty index is also fine.
        let withIncumbent = index.resolve(csiPoint(0, 0), incumbent: csiKeyN, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(withIncumbent, CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
    }

    // A.11 A1
    func testResolve_withinAcquire_returnsSegmentFractionDistanceAndOnLineSnap() {
        let index = CurbSnapIndex(segments: csiTwoSidedStreet())
        // 4.5 m north of the north curb's centre-line... pin at y=12, curb at y=7.5, x=20.
        let outcome = index.resolve(csiPoint(20, 12), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let result = csiSnapped(outcome) else { return }

        XCTAssertEqual(result.segment.id, "N1")
        XCTAssertEqual(result.blockfaceKey, csiKeyN)
        XCTAssertEqual(result.distanceMeters, 4.5, accuracy: 0.05)
        // x spans -100...100, so x=20 is 120/200 of the way along.
        XCTAssertEqual(result.positionFraction, 0.6, accuracy: 1e-4)
        // Snapped point is the perpendicular foot: same x, on the curb's northing.
        let expected = csiPoint(20, 7.5)
        XCTAssertEqual(result.snappedCoordinate.latitude, expected.latitude, accuracy: 1e-7)
        XCTAssertEqual(result.snappedCoordinate.longitude, expected.longitude, accuracy: 1e-7)
    }

    func testResolve_twoSidedStreet_picksNearestSide() {
        let index = CurbSnapIndex(segments: csiTwoSidedStreet())
        let north = index.resolve(csiPoint(0, 3), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(north)?.segment.id, "N1")
        let south = index.resolve(csiPoint(0, -3), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(south)?.segment.id, "S1")
        // Ground-truth distances: 4.5 m to N from y=3; 4.5 m to S from y=-3.
        XCTAssertEqual(csiSnapped(north)?.distanceMeters ?? -1, 4.5, accuracy: 0.05)
        XCTAssertEqual(csiSnapped(south)?.distanceMeters ?? -1, 4.5, accuracy: 0.05)
        // Pushed to the far end of the street's width, still the near side.
        let farNorth = index.resolve(csiPoint(0, 14), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(farNorth)?.segment.id, "N1")
    }

    func testResolve_positionFraction_multiVertex_matchesNearestPointOnPolyline() {
        // L-shaped polyline (0,0) -> (100,0) -> (100,50); total ~150 m.
        let l = CurbSnapTestFixtures.segment(
            id: "L1", side: "E", points: [(0, 0), (100, 0), (100, 50)]
        )
        let index = CurbSnapIndex(segments: [l])
        let pin = csiPoint(110, 30)
        let outcome = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let result = csiSnapped(outcome) else { return }

        // Reuse contract: the winner's fraction/foot come straight from the existing helper.
        guard let reference = CandidateSegmentSearch.nearestPointOnPolyline(from: pin, polyline: l.coordinates) else {
            XCTFail("reference helper returned nil")
            return
        }
        XCTAssertEqual(result.positionFraction, reference.fraction, accuracy: 1e-12)
        XCTAssertEqual(result.distanceMeters, reference.distanceMeters, accuracy: 1e-9)
        XCTAssertEqual(result.snappedCoordinate.latitude, reference.coordinate.latitude, accuracy: 1e-12)
        XCTAssertEqual(result.snappedCoordinate.longitude, reference.coordinate.longitude, accuracy: 1e-12)

        // Hand-computed expectation (continuous across the corner, not per-sub-segment):
        // 100 m first leg + 30 m of the 50 m second leg => 130/150.
        XCTAssertEqual(result.positionFraction, 130.0 / 150.0, accuracy: 0.003)
        XCTAssertEqual(result.distanceMeters, 10.0, accuracy: 0.1)
    }

    func testResolve_pastEndOfPolyline_clampsFractionAndSnapsToVertex() {
        let seg = CurbSnapTestFixtures.eastWestCurb(id: "E1", side: "N", y: 0, x0: 0, x1: 100)
        let index = CurbSnapIndex(segments: [seg])

        let beyondTo = index.resolve(csiPoint(110, 5), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let atEnd = csiSnapped(beyondTo) else { return }
        XCTAssertEqual(atEnd.positionFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(csiMetersBetween(atEnd.snappedCoordinate, csiPoint(100, 0)), 0, accuracy: 0.01)
        XCTAssertEqual(atEnd.distanceMeters, sqrt(125.0), accuracy: 0.1)

        let beforeFrom = index.resolve(csiPoint(-10, 5), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let atStart = csiSnapped(beforeFrom) else { return }
        XCTAssertEqual(atStart.positionFraction, 0.0, accuracy: 1e-9)
        XCTAssertEqual(csiMetersBetween(atStart.snappedCoordinate, csiPoint(0, 0)), 0, accuracy: 0.01)
    }

    func testResolve_invalidQueryPoint_noCurb() {
        let index = CurbSnapIndex(segments: csiTwoSidedStreet())
        let nan = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        XCTAssertEqual(index.resolve(nan, incumbent: nil, metersPerPoint: 0.28, config: .standard),
                       CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
        let inf = CLLocationCoordinate2D(latitude: .infinity, longitude: 0)
        XCTAssertEqual(index.resolve(inf, incumbent: nil, metersPerPoint: 0.28, config: .standard),
                       CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
        // Absurdly far (but finite) query must not trap on Int conversion.
        let farAway = CLLocationCoordinate2D(latitude: -80, longitude: 170)
        XCTAssertEqual(index.resolve(farAway, incumbent: nil, metersPerPoint: 0.28, config: .standard),
                       CurbSnapOutcome.noCurbInRange(nearestMeters: nil))
    }
}

// MARK: - Radii (acquire vs release)

final class CurbSnapRadiiTests: XCTestCase {

    /// A single east-west curb at y = 0.
    private func makeIndex() -> CurbSnapIndex {
        CurbSnapIndex(segments: [CurbSnapTestFixtures.eastWestCurb(id: "R1", side: "N", y: 0)])
    }

    // A.11 A5
    func testResolve_beyondReleaseRadius_noCurbInRange_withNearestMeters() {
        let index = makeIndex()
        let outcome = index.resolve(csiPoint(0, 31), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard case .noCurbInRange(let nearest) = outcome else {
            XCTFail("expected .noCurbInRange, got \(outcome)")
            return
        }
        // 31 m is inside the 3x3 cell neighbourhood (32 m), so the probe must report it.
        XCTAssertEqual(nearest ?? -1, 31.0, accuracy: 0.1)

        // Even with the key as incumbent, 31 m is past the 30 m release radius.
        let withIncumbent = index.resolve(csiPoint(0, 31), incumbent: csiKeyN, metersPerPoint: 0.28, config: .standard)
        if case .snapped = withIncumbent { XCTFail("incumbent must be dropped beyond release radius") }

        // Far away: no curb, and no crash.
        let far = index.resolve(csiPoint(0, 400), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        if case .snapped = far { XCTFail("400 m away must not snap") }
    }

    func testResolve_acquireBand_noIncumbent_doesNotAcquire() {
        let index = makeIndex()
        // 23 m: inside acquire -> acquired.
        let inside = index.resolve(csiPoint(0, 23), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(inside)?.segment.id, "R1")
        // 27 m: in the 24-30 band -> NOT acquired.
        let band = index.resolve(csiPoint(0, 27), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard case .noCurbInRange(let nearest) = band else {
            XCTFail("a curb in the 24-30 m band must not be acquired, got \(band)")
            return
        }
        XCTAssertEqual(nearest ?? -1, 27.0, accuracy: 0.1)
    }

    func testResolve_acquireBand_incumbentRetainedInReleaseBand() {
        let index = makeIndex()
        let retained = index.resolve(csiPoint(0, 27), incumbent: csiKeyN, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(retained)?.segment.id, "R1")
        XCTAssertEqual(csiSnapped(retained)?.distanceMeters ?? -1, 27.0, accuracy: 0.1)
    }

    func testResolve_incumbentBeyondRelease_isDropped() {
        let index = makeIndex()
        let dropped = index.resolve(csiPoint(0, 33), incumbent: csiKeyN, metersPerPoint: 0.28, config: .standard)
        if case .snapped = dropped { XCTFail("33 m is beyond the 30 m release radius") }
    }

    func testResolve_releaseBand_challengerNotAcquirableInBand() {
        // A at y=0, B at y=53. Pin at y=27: dA=27 (release band), dB=26 (also > 24).
        let a = CurbSnapTestFixtures.eastWestCurb(id: "A", side: "S", y: 0)
        let b = CurbSnapTestFixtures.eastWestCurb(id: "B", side: "N", y: 53)
        let index = CurbSnapIndex(segments: [a, b])
        let pin = csiPoint(0, 27)

        // Incumbent A: B is closer by ~1 m, but B is not acquirable at 26 m, and 1 m < H anyway.
        let kept = index.resolve(pin, incumbent: csiKeyS, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(kept)?.segment.id, "A")

        // Use a pin where B is closer by far more than the dead-band yet still outside acquire:
        // y=28.5 => dA=28.5 (retained), dB=24.5 (> 24, not acquirable), gap 4 m > H.
        let stillKept = index.resolve(csiPoint(0, 28.5), incumbent: csiKeyS, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(stillKept)?.segment.id, "A",
                       "a challenger outside the acquire radius must never take over, whatever the gap")

        // No incumbent at all there: neither is acquirable.
        let none = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: .standard)
        if case .snapped = none { XCTFail("neither curb is within the 24 m acquire radius") }
    }

    func testResolve_releaseBand_acquirableChallengerBeyondDeadband_takesOver() {
        let a = CurbSnapTestFixtures.eastWestCurb(id: "A", side: "S", y: 0)
        let b = CurbSnapTestFixtures.eastWestCurb(id: "B", side: "N", y: 53)
        let index = CurbSnapIndex(segments: [a, b])
        // y=29.5 => dA=29.5 (still inside release), dB=23.5 (inside acquire), gap 6 m > H=3.92.
        let outcome = index.resolve(csiPoint(0, 29.5), incumbent: csiKeyS, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.segment.id, "B")
    }

    func testResolve_unknownIncumbent_treatedAsNone() {
        let index = makeIndex()
        let outcome = index.resolve(csiPoint(0, 5), incumbent: "NOT|A|REAL|KEY", metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.segment.id, "R1")
        // ...and it does not grant release-radius leniency.
        let band = index.resolve(csiPoint(0, 27), incumbent: "NOT|A|REAL|KEY", metersPerPoint: 0.28, config: .standard)
        if case .snapped = band { XCTFail("unknown incumbent must not retain anything") }
    }
}

// MARK: - Dedup and deterministic ties

final class CurbSnapDedupAndTieTests: XCTestCase {

    // A.11 A4
    func testResolve_blockfaceInTwoTiles_resolvesOnceAtNearestCopy() {
        // Same blockface in two tiles: second copy has from/to swapped (blockfaceKey sorts them),
        // a different id, and is farther away. Another block's curb sits between them.
        let copy1 = CurbSnapTestFixtures.eastWestCurb(id: "T1", from: "A ST", to: "B ST", side: "N", y: 3)
        let copy2 = CurbSnapTestFixtures.eastWestCurb(id: "T2", from: "B ST", to: "A ST", side: "N", y: 12)
        XCTAssertEqual(copy1.blockfaceKey, copy2.blockfaceKey, "fixture sanity: same blockface")
        let other = CurbSnapTestFixtures.eastWestCurb(id: "O1", street: "OTHER ST", side: "S", y: -8)
        let index = CurbSnapIndex(segments: [copy2, other, copy1])

        let outcome = index.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let result = csiSnapped(outcome) else { return }
        XCTAssertEqual(result.blockfaceKey, copy1.blockfaceKey)
        XCTAssertEqual(result.segment.id, "T1", "the nearer copy represents the blockface")
        XCTAssertEqual(result.distanceMeters, 3.0, accuracy: 0.05)
    }

    func testResolve_incumbentDistanceIsMinAcrossBlockfaceCopies() {
        // Blockface K has a FAR copy (12 m) and a NEAR copy (2 m). Rival R is 6.5 m away.
        // If the incumbent's distance were taken from the far copy (12 m), R would beat it by
        // more than the 3.92 m dead-band (12 - 3.92 = 8.08 > 6.5) and wrongly take over.
        let far = CurbSnapTestFixtures.eastWestCurb(id: "KFAR", side: "N", y: 12)
        let near = CurbSnapTestFixtures.eastWestCurb(id: "KNEAR", side: "N", y: 2)
        let rival = CurbSnapTestFixtures.eastWestCurb(id: "R", street: "RIVAL ST", side: "S", y: -6.5)
        let index = CurbSnapIndex(segments: [far, rival, near])

        let outcome = index.resolve(csiPoint(0, 0), incumbent: csiKeyN, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.segment.id, "KNEAR")
    }

    // A.11 A3
    func testResolve_exactTie_deterministicAcross100ShuffledInputOrders() {
        // Identical geometry, different sides => exactly equal distance, different keys.
        // Tie must break on blockfaceKey ("...|N" < "...|S"), never on input order.
        let n = CurbSnapTestFixtures.eastWestCurb(id: "TN", side: "N", y: 5)
        let s = CurbSnapTestFixtures.eastWestCurb(id: "TS", side: "S", y: 5)
        let far = CurbSnapTestFixtures.eastWestCurb(id: "TF", street: "FAR ST", side: "E", y: -20)
        var rng = CurbSnapTestRNG(seed: 0xA3)
        for iteration in 0..<100 {
            let shuffled = CurbSnapTestFixtures.shuffled([n, s, far], using: &rng)
            let index = CurbSnapIndex(segments: shuffled)
            let outcome = index.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard)
            XCTAssertEqual(csiSnapped(outcome)?.blockfaceKey, csiKeyN, "iteration \(iteration)")
        }
    }

    func testResolve_mirroredGeometryTie_deterministicAcross100ShuffledInputOrders() {
        // Curbs mirrored about the pin: distances are equal up to floating-point noise. Whichever
        // side wins, it must be the SAME side for every input order.
        let north = CurbSnapTestFixtures.eastWestCurb(id: "MN", side: "N", y: 8)
        let south = CurbSnapTestFixtures.eastWestCurb(id: "MS", side: "S", y: -8)
        var rng = CurbSnapTestRNG(seed: 0xA33)
        var winners = Set<String>()
        for _ in 0..<100 {
            let shuffled = CurbSnapTestFixtures.shuffled([north, south], using: &rng)
            let index = CurbSnapIndex(segments: shuffled)
            let outcome = index.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard)
            if let key = csiSnapped(outcome)?.blockfaceKey { winners.insert(key) }
        }
        XCTAssertEqual(winners.count, 1, "winner must not depend on input order: \(winners)")
    }
}

// MARK: - Hysteresis (A.11 A2)

final class CurbSnapHysteresisTests: XCTestCase {

    private let keyS = CurbSnapTestFixtures.key(side: "S")   // curb at y = 0
    private let keyN = CurbSnapTestFixtures.key(side: "N")   // curb at y = 15
    private let mpp = 0.28                                    // H = 14 x 0.28 = 3.92 m

    func testHysteresis_sweepUp_flipsExactlyOnce() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        // y = -3 ... 18 at 1 m steps, starting on the south curb.
        let path = csiYPath(from: -3, to: 18, steps: 21)
        let keys = csiRun(index: index, path: path, startIncumbent: keyS, metersPerPoint: mpp)
        XCTAssertEqual(csiFlipCount(keys), 1)
        XCTAssertEqual(keys.first ?? nil, keyS)
        XCTAssertEqual(keys.last ?? nil, keyN)
        // Flip point: dN < dS - 3.92 => 15 - y < y - 3.92 => y > 9.46 => first 1 m step is
        // y = 10 (index 13, since y = -3 + index).
        XCTAssertEqual(csiFirstFlipIndex(keys), 13)
        XCTAssertFalse(keys.contains { $0 == nil }, "both curbs are within acquire radius over the whole sweep")
    }

    func testHysteresis_sweepDown_flipsExactlyOnce() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        let path = csiYPath(from: 18, to: -3, steps: 21)
        let keys = csiRun(index: index, path: path, startIncumbent: keyN, metersPerPoint: mpp)
        XCTAssertEqual(csiFlipCount(keys), 1)
        XCTAssertEqual(keys.first ?? nil, keyN)
        XCTAssertEqual(keys.last ?? nil, keyS)
        // Flip point: dS < dN - 3.92 => y < 5.54 => first 1 m step down is y = 5
        // (index 13, since y = 18 - index).
        XCTAssertEqual(csiFirstFlipIndex(keys), 13)
    }

    func testHysteresis_noIncumbentStart_picksNearestThenSticks() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        let path = csiYPath(from: 1, to: 14, steps: 13)
        let keys = csiRun(index: index, path: path, startIncumbent: nil, metersPerPoint: mpp)
        XCTAssertEqual(keys.first ?? nil, keyS)
        XCTAssertEqual(keys.last ?? nil, keyN)
        XCTAssertEqual(csiFlipCount(keys), 1)
    }

    func testHysteresis_roundTrip_flipPointsSeparatedByDeadband() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        // 0.1 m steps, up from -3 to 18 then back down to -3.
        let up = csiYPath(from: -3, to: 18, steps: 210)
        let down = csiYPath(from: 18, to: -3, steps: 210)
        let keys = csiRun(index: index, path: up + down, startIncumbent: keyS, metersPerPoint: mpp)
        XCTAssertEqual(csiFlipCount(keys), 2, "one flip each way, none in between")

        // Recover the two flip northings.
        var flipYs: [Double] = []
        let ys = (up + down).map { ($0.latitude - csiPoint(0, 0).latitude) * 111_320.0 }
        for i in 1..<keys.count where keys[i] != keys[i - 1] {
            flipYs.append(ys[i])
        }
        XCTAssertEqual(flipYs.count, 2)
        guard flipYs.count == 2 else { return }
        XCTAssertEqual(flipYs[0], 9.46, accuracy: 0.15)   // S -> N going up
        XCTAssertEqual(flipYs[1], 5.54, accuracy: 0.15)   // N -> S coming back
        // The two thresholds sit H/2 = 1.96 m either side of the centreline (y = 7.5), so the
        // band between them is H = 3.92 m wide (0.1 m sampling): it does not come back inside it.
        XCTAssertGreaterThan(flipYs[0] - flipYs[1], 3.5)
        XCTAssertLessThan(flipYs[0] - flipYs[1], 4.5)
    }

    func testHysteresis_jitterOnCenterline_zeroFlips() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        // Pin hovers on the centreline (y = 7.5) with +/-0.3 m jitter, alternating plus
        // pseudo-random. Both starting incumbents must hold: zero flips.
        var rng = CurbSnapTestRNG(seed: 0x51DE)
        var path: [CLLocationCoordinate2D] = []
        for i in 0..<300 {
            let jitter = i % 2 == 0 ? 0.3 : -0.3
            path.append(csiPoint(rng.nextDouble(in: -2, 2), 7.5 + jitter))
            path.append(csiPoint(rng.nextDouble(in: -2, 2), 7.5 + rng.nextDouble(in: -0.3, 0.3)))
        }
        for start in [keyS, keyN] {
            let keys = csiRun(index: index, path: path, startIncumbent: start, metersPerPoint: mpp)
            XCTAssertEqual(csiFlipCount(keys), 0, "incumbent \(start) flickered")
            XCTAssertTrue(keys.allSatisfy { $0 == start })
        }
    }

    func testHysteresis_noisyCrossing_flipsExactlyOnce() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        // Drift from y=4 to y=11 in 0.05 m steps with +/-0.3 m deterministic noise on top.
        var rng = CurbSnapTestRNG(seed: 0xC0FFEE)
        var path: [CLLocationCoordinate2D] = []
        for i in 0...140 {
            let y = 4.0 + Double(i) * 0.05 + rng.nextDouble(in: -0.3, 0.3)
            path.append(csiPoint(0, y))
        }
        let keys = csiRun(index: index, path: path, startIncumbent: keyS, metersPerPoint: mpp)
        XCTAssertEqual(csiFlipCount(keys), 1)
        XCTAssertEqual(keys.last ?? nil, keyN)
    }

    func testHysteresis_deadbandTracksMetersPerPoint() {
        let index = CurbSnapIndex(segments: csiParallelCurbs())

        func flipNorthing(metersPerPoint: Double) -> Double? {
            let path = csiYPath(from: 4, to: 12, steps: 160)   // 0.05 m steps
            let keys = csiRun(index: index, path: path, startIncumbent: keyS, metersPerPoint: metersPerPoint)
            guard let flip = csiFirstFlipIndex(keys) else { return nil }
            return 4.0 + Double(flip) * 0.05
        }

        // Deep zoom (0.05 m/pt): H clamps to 1.5 => flip at y > 8.25.
        guard let fine = flipNorthing(metersPerPoint: 0.05) else { XCTFail("no flip at fine zoom"); return }
        XCTAssertEqual(fine, 8.25, accuracy: 0.1)
        // Zoomed out (1.0 m/pt): H clamps to 4.0 => flip at y > 9.5.
        guard let coarse = flipNorthing(metersPerPoint: 1.0) else { XCTFail("no flip at coarse zoom"); return }
        XCTAssertEqual(coarse, 9.5, accuracy: 0.1)
        XCTAssertGreaterThan(coarse, fine + 1.0)
    }
}

// MARK: - Grid / robustness

final class CurbSnapGridRobustnessTests: XCTestCase {

    func testIndex_edgeRegistersInEveryCellItsBBoxCrosses_longDiagonal() {
        // 707 m diagonal (-250,-250) -> (250,250): crosses ~16 cells in each axis. Query points
        // far from either endpoint (so only correct bbox registration can find the edge).
        let diagonal = CurbSnapTestFixtures.segment(
            id: "D1", side: "E", points: [(-250, -250), (250, 250)]
        )
        let index = CurbSnapIndex(segments: [diagonal])
        // Distance from (px, py) to the line y = x is |px - py| / sqrt(2).
        let probes: [(Double, Double)] = [(40, 20), (-120, -100), (150, 170), (0, 12), (200, 190)]
        for probe in probes {
            let expected = abs(probe.0 - probe.1) / sqrt(2.0)
            let outcome = index.resolve(csiPoint(probe.0, probe.1), incumbent: nil, metersPerPoint: 0.28, config: .standard)
            guard let result = csiSnapped(outcome) else { continue }
            XCTAssertEqual(result.distanceMeters, expected, accuracy: 0.15, "probe \(probe)")
        }
    }

    func testIndex_cellBoundarySweep_alwaysFindsCurb() {
        // Curb along y=0; pin 20 m south of it, swept across every 32 m cell boundary in x.
        let seg = CurbSnapTestFixtures.eastWestCurb(id: "B1", side: "N", y: 0, x0: -200, x1: 200)
        let index = CurbSnapIndex(segments: [seg])
        var x = -100.0
        while x <= 100.0 {
            let outcome = index.resolve(csiPoint(x, -20), incumbent: nil, metersPerPoint: 0.28, config: .standard)
            let result = csiSnapped(outcome)
            XCTAssertEqual(result?.distanceMeters ?? -1, 20.0, accuracy: 0.1, "x=\(x)")
            x += 0.5
        }
        // And the vertical boundary: curb along x=0 (north-south), pin swept in y.
        let ns = CurbSnapTestFixtures.segment(id: "B2", side: "E", points: [(0, -200), (0, 200)])
        let nsIndex = CurbSnapIndex(segments: [ns])
        var y = -100.0
        while y <= 100.0 {
            let outcome = nsIndex.resolve(csiPoint(-20, y), incumbent: nil, metersPerPoint: 0.28, config: .standard)
            XCTAssertEqual(csiSnapped(outcome)?.distanceMeters ?? -1, 20.0, accuracy: 0.1, "y=\(y)")
            y += 0.5
        }
    }

    func testIndex_longEdge_isSplitIntoPieces() {
        // 600 m straight edge => ceil(600 / 256) = 3 collinear pieces.
        let long = CurbSnapTestFixtures.eastWestCurb(id: "LONG", side: "N", y: 0, x0: 0, x1: 600)
        let index = CurbSnapIndex(segments: [long])
        XCTAssertEqual(index.edgeCount, 3)
        XCTAssertEqual(index.segmentCount, 1)
        // Splitting must not change any distance or the fraction.
        let outcome = index.resolve(csiPoint(300, 10), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.distanceMeters ?? -1, 10.0, accuracy: 0.05)
        XCTAssertEqual(csiSnapped(outcome)?.positionFraction ?? -1, 0.5, accuracy: 1e-4)
    }

    func testIndex_degenerateAndMalformedPolylines_neverCrash_andAreIgnored() {
        let good = CurbSnapTestFixtures.eastWestCurb(id: "GOOD", side: "N", y: 5)

        func raw(_ id: String, _ line: [[Double]]) -> Segment {
            Segment(id: id, street: "BAD ST", fromStreet: "A ST", to: "B ST", side: "E",
                    line: line, rules: [], dominantCategory: nil)
        }
        let lat = 40.7128, lng = -74.0060
        let bad: [Segment] = [
            raw("EMPTY", []),
            raw("ONE", [[lat, lng]]),
            raw("SHORTPAIR", [[lat], [lat]]),
            raw("NAN", [[Double.nan, Double.nan], [Double.nan, Double.nan]]),
            raw("INF", [[Double.infinity, lng], [lat, lng]]),
            raw("FARAWAY", [[0.0, 0.0], [0.0001, 0.0001]]),    // ~8,000 km from NYC: dropped
        ]

        let onlyBad = CurbSnapIndex(segments: bad)
        XCTAssertEqual(onlyBad.edgeCount, 0)
        XCTAssertEqual(
            onlyBad.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard),
            CurbSnapOutcome.noCurbInRange(nearestMeters: nil)
        )

        // Mixed with a good segment: the good one still resolves, the bad ones never win.
        let mixed = CurbSnapIndex(segments: bad + [good])
        XCTAssertEqual(mixed.edgeCount, 1)
        let outcome = mixed.resolve(csiPoint(0, 0), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.segment.id, "GOOD")
    }

    func testIndex_zeroLengthPolyline_snapsToItsPoint() {
        // Two identical vertices: zero-length edge. Distance is point distance; fraction 0.
        let dot = CurbSnapTestFixtures.segment(id: "DOT", side: "N", points: [(10, 10), (10, 10)])
        let index = CurbSnapIndex(segments: [dot])
        XCTAssertEqual(index.edgeCount, 1)
        let outcome = index.resolve(csiPoint(10, 15), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        guard let result = csiSnapped(outcome) else { return }
        XCTAssertEqual(result.segment.id, "DOT")
        XCTAssertEqual(result.distanceMeters, 5.0, accuracy: 0.05)
        XCTAssertEqual(result.positionFraction, 0.0, accuracy: 1e-12)
        XCTAssertEqual(csiMetersBetween(result.snappedCoordinate, csiPoint(10, 10)), 0, accuracy: 0.01)
        // Beyond acquire: nothing.
        let far = index.resolve(csiPoint(10, 40), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        if case .snapped = far { XCTFail("dot is 30 m away") }
    }

    func testIndex_malformedMiddlePair_matchesCoordinatesSemantics() {
        // `Segment.coordinates` drops pairs with < 2 numbers and joins the neighbours; the index
        // must index the same polyline, or the foot point and the scan would disagree.
        let a = csiPoint(0, 0), b = csiPoint(100, 0)
        let seg = Segment(
            id: "MALFORMED", street: "MAIN ST", fromStreet: "A ST", to: "B ST", side: "N",
            line: [[a.latitude, a.longitude], [40.7], [b.latitude, b.longitude]],
            rules: [], dominantCategory: nil
        )
        XCTAssertEqual(seg.coordinates.count, 2, "fixture sanity")
        let index = CurbSnapIndex(segments: [seg])
        XCTAssertEqual(index.edgeCount, 1)
        let outcome = index.resolve(csiPoint(50, 6), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(outcome)?.distanceMeters ?? -1, 6.0, accuracy: 0.05)
        XCTAssertEqual(csiSnapped(outcome)?.positionFraction ?? -1, 0.5, accuracy: 1e-3)
    }
}

// MARK: - Non-default config + scan widening

final class CurbSnapCustomConfigTests: XCTestCase {

    /// A single east-west curb at northing 0, x in [-100, 100] (key == csiKeyN).
    private func makeCurbIndex() -> CurbSnapIndex {
        CurbSnapIndex(segments: [CurbSnapTestFixtures.eastWestCurb(id: "W1", side: "N", y: 0)])
    }

    func testConfig_customInit_overridesEachField() {
        let config = CurbSnapConfig(
            acquireRadius: 10,
            releaseRadius: 12,
            hysteresisPoints: 20,
            hysteresisMinMeters: 0.5,
            hysteresisMaxMeters: 9
        )
        XCTAssertEqual(config.acquireRadius, 10)
        XCTAssertEqual(config.releaseRadius, 12)
        XCTAssertEqual(config.hysteresisPoints, 20)
        XCTAssertEqual(config.hysteresisMinMeters, 0.5)
        XCTAssertEqual(config.hysteresisMaxMeters, 9)
        XCTAssertNotEqual(config, CurbSnapConfig.standard)
        // 20 pt x 0.28 = 5.6 m, inside [0.5, 9]; 20 pt x 1.0 clamps to the 9 m ceiling.
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 0.28), 5.6, accuracy: 1e-9)
        XCTAssertEqual(config.hysteresisMeters(metersPerPoint: 1.0), 9.0, accuracy: 1e-9)

        // Partial override keeps the other defaults.
        let partial = CurbSnapConfig(acquireRadius: 50)
        XCTAssertEqual(partial.acquireRadius, 50)
        XCTAssertEqual(partial.releaseRadius, 30.0)
        XCTAssertEqual(partial.hysteresisPoints, 14.0)
    }

    func testResolve_customSmallRadii_changeAcquireAndRelease() {
        let index = makeCurbIndex()
        let tight = CurbSnapConfig(acquireRadius: 10, releaseRadius: 12)
        // 11 m: outside the custom acquire radius (the 24 m default would acquire it).
        let none = index.resolve(csiPoint(0, 11), incumbent: nil, metersPerPoint: 0.28, config: tight)
        if case .snapped = none { XCTFail("11 m is outside a 10 m acquire radius") }
        let standard = index.resolve(csiPoint(0, 11), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        XCTAssertEqual(csiSnapped(standard)?.segment.id, "W1")
        // Incumbent retained at 11.5 m (inside the 12 m release), dropped at 13 m.
        let kept = index.resolve(csiPoint(0, 11.5), incumbent: csiKeyN, metersPerPoint: 0.28, config: tight)
        XCTAssertEqual(csiSnapped(kept)?.segment.id, "W1")
        let dropped = index.resolve(csiPoint(0, 13), incumbent: csiKeyN, metersPerPoint: 0.28, config: tight)
        if case .snapped = dropped { XCTFail("13 m is outside a 12 m release radius") }
    }

    func testHysteresis_customDeadband_movesFlipPoint() {
        // Pin the dead-band to exactly 6 m (min == max == 6) regardless of zoom:
        // flip when dN < dS - 6 => 15 - y < y - 6 => y > 10.5 => first 1 m step y = 11 (index 14).
        let index = CurbSnapIndex(segments: csiParallelCurbs())
        let fixedSix = CurbSnapConfig(hysteresisMinMeters: 6, hysteresisMaxMeters: 6)
        XCTAssertEqual(fixedSix.hysteresisMeters(metersPerPoint: 0.28), 6.0, accuracy: 1e-9)
        let path = csiYPath(from: -3, to: 18, steps: 21)
        let keys = csiRun(
            index: index,
            path: path,
            startIncumbent: csiKeyS,
            metersPerPoint: 0.28,
            config: fixedSix
        )
        XCTAssertEqual(csiFlipCount(keys), 1)
        XCTAssertEqual(csiFirstFlipIndex(keys), 14)
    }

    // The recipe documented on `CurbSnapIndex.resolve` for the nearest-curb chip.
    func testResolve_wideConfigRecipe_100m_findsCurbBeyondThe3x3Block() {
        let index = makeCurbIndex()
        let wide = CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)
        let pin = csiPoint(30, -80)   // 80 m south of the curb: far outside the 3x3 block

        // The default config cannot see (or acquire) it.
        let narrow = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: .standard)
        if case .snapped = narrow { XCTFail("80 m is outside the default 24 m acquire radius") }

        // The wide config returns the foot point and distance for the chip.
        let outcome = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: wide)
        guard let result = csiSnapped(outcome) else { return }
        XCTAssertEqual(result.segment.id, "W1")
        XCTAssertEqual(result.distanceMeters, 80.0, accuracy: 0.15)
        XCTAssertEqual(csiMetersBetween(result.snappedCoordinate, csiPoint(30, 0)), 0, accuracy: 0.05)
        // x = 30 on [-100, 100] => 130/200 along.
        XCTAssertEqual(result.positionFraction, 130.0 / 200.0, accuracy: 1e-4)
    }

    func testResolve_wideConfigRecipe_100m_boundariesAndCorners() {
        let index = makeCurbIndex()
        let wide = CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)

        // Just inside / just outside 100 m, with the pin at every 1 m offset within a 32 m cell
        // (the 9x9 block must cover from any position in the cell).
        var offset = 0.0
        while offset < 32.0 {
            let insideY = -(99.0 + offset / 100.0)
            let inside = index.resolve(csiPoint(offset, insideY), incumbent: nil, metersPerPoint: 0.28, config: wide)
            XCTAssertEqual(csiSnapped(inside)?.segment.id, "W1", "offset \(offset)")

            let outsideDistance = 104.0 + offset / 100.0
            let outside = index.resolve(csiPoint(offset, -outsideDistance), incumbent: nil, metersPerPoint: 0.28, config: wide)
            guard case .noCurbInRange(let nearest) = outside else {
                XCTFail("expected .noCurbInRange at ~104 m, got \(outside) (offset \(offset))")
                return
            }
            // ~104 m is inside the guaranteed (>= 128 m) scan, so the probe reports it.
            XCTAssertEqual(nearest ?? -1, outsideDistance, accuracy: 0.3, "offset \(offset)")
            offset += 1.0
        }

        // Diagonal (corner) approach: the curb ends at x = 100; a pin 70 m past the end and
        // 70 m south is sqrt(9800) ~ 98.99 m from the endpoint.
        let corner = index.resolve(csiPoint(170, -70), incumbent: nil, metersPerPoint: 0.28, config: wide)
        let snapped = csiSnapped(corner)
        XCTAssertEqual(snapped?.distanceMeters ?? -1, sqrt(9800.0), accuracy: 0.3)
        XCTAssertEqual(snapped?.positionFraction ?? -1, 1.0, accuracy: 1e-9)

        // Far beyond the scan: nothing, and no crash.
        let farAway = index.resolve(csiPoint(0, -400), incumbent: nil, metersPerPoint: 0.28, config: wide)
        if case .snapped = farAway { XCTFail("400 m is outside the wide probe") }
    }

    func testResolve_scanWidening_50mRadiusUsesRingTwo() {
        // 50 m radius => ceil(50 / 32) = 2 rings (5x5 block). A curb 45 m away is outside the
        // 3x3 block's guaranteed reach, so it is only found by the widened scan.
        let index = makeCurbIndex()
        let config = CurbSnapConfig(acquireRadius: 50, releaseRadius: 50)
        for offset in stride(from: 0.0, to: 32.0, by: 4.0) {
            let outcome = index.resolve(csiPoint(offset, -45), incumbent: nil, metersPerPoint: 0.28, config: config)
            XCTAssertEqual(csiSnapped(outcome)?.distanceMeters ?? -1, 45.0, accuracy: 0.1, "offset \(offset)")
        }
        // Same pin with the default config: not acquired.
        let narrow = index.resolve(csiPoint(0, -45), incumbent: nil, metersPerPoint: 0.28, config: .standard)
        if case .snapped = narrow { XCTFail("45 m is outside the default acquire radius") }
    }

    func testResolve_hugeOrNonFiniteRadius_doesNotTrap() {
        let index = makeCurbIndex()
        // Finite but enormous: the ring must be clamped in Double BEFORE converting to Int.
        let huge = CurbSnapConfig(acquireRadius: 1e300, releaseRadius: 1e300)
        let hugeOutcome = index.resolve(csiPoint(0, -5), incumbent: nil, metersPerPoint: 0.28, config: huge)
        XCTAssertEqual(csiSnapped(hugeOutcome)?.segment.id, "W1")
        let infinite = CurbSnapConfig(acquireRadius: .infinity, releaseRadius: .infinity)
        let infiniteOutcome = index.resolve(csiPoint(0, -5), incumbent: nil, metersPerPoint: 0.28, config: infinite)
        XCTAssertEqual(csiSnapped(infiniteOutcome)?.segment.id, "W1")
        // NaN radii: nothing satisfies `<= NaN`, so no curb; the point is that it does not crash.
        let nan = CurbSnapConfig(acquireRadius: .nan, releaseRadius: .nan)
        let nanOutcome = index.resolve(csiPoint(0, -5), incumbent: nil, metersPerPoint: 0.28, config: nan)
        if case .snapped = nanOutcome { XCTFail("NaN radii must not acquire anything") }
    }
}

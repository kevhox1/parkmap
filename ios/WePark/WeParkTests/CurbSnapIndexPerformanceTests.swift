//
//  CurbSnapIndexPerformanceTests.swift
//  WeParkTests
//
//  Stream A1 — performance + scale-correctness tests for `CurbSnapIndex` on a synthetic
//  ~5k-segment fixture. Spec: docs/longpress-universal-plant-spec.md §A.6 ("build target
//  < 60 ms for ~5k segments, query target < 1 ms on iPhone 12-class, both asserted with
//  `measure {}` tests on a synthetic 5k-segment fixture (budget numbers are targets to be
//  confirmed at the Mac gate, not guarantees)") and §A.11 A6.
//
//  TIMING IS MEASUREMENT, NOT A GATE. `measure {}` records the average in the xcresult /
//  console; nothing here asserts a wall-clock number. CORRECTNESS is asserted always (every
//  query in the timed loops is checked to have snapped, so a "fast" index that returns
//  nothing cannot pass).
//
//  READING THE NUMBERS: each resolve measure block runs 1,000 queries, so
//  per-query time = reported average / 1,000. The index-build block builds once per
//  iteration. Debug builds inflate both by roughly an order of magnitude (no inlining, bounds
//  checks, exclusivity checks) — record the Release-config numbers against the A.6 targets:
//    xcodebuild test -project ios/WePark/WePark.xcodeproj -scheme WePark \
//      -destination 'platform=iOS Simulator,name=<sim>' -configuration Release \
//      ENABLE_TESTABILITY=YES -only-testing:WeParkTests/CurbSnapIndexPerformanceTests
//  (and note simulator-on-Mac-CPU is faster than an iPhone 12; the A.6 target is device-class).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  Test inventory (6 tests):
//    1. testPerf_indexBuild_5kSegments                      (measure)
//    2. testPerf_resolve_noIncumbent_1000Queries_5kSegments (measure)
//    3. testPerf_resolve_withIncumbent_1000Queries_5kSegments (measure)
//    4. testPerf_resolve_30HzSweep_threeSeconds_5kSegments  (measure)
//    5. testFixture_isAboutFiveThousandSegments_withUniqueBlockfaces
//    6. testResolve_matchesBruteForce_syntheticFixture      (correctness oracle, no timing)
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers (unique `csp` prefix)

/// Pin position for the k-th deterministic query on the 50x50 grid: always within ~13 m of
/// some curb (columns are 100 m apart with curbs at +/-7 m, blocks tile the y axis).
private func cspQueryPoint(_ rng: inout CurbSnapTestRNG, columns: Int, rows: Int) -> CLLocationCoordinate2D {
    let column = Int(rng.nextUInt64() % UInt64(columns))
    let row = Int(rng.nextUInt64() % UInt64(rows))
    let centerX = Double(column - columns / 2) * 100.0
    let y0 = Double(row - rows / 2) * 80.0
    let x = centerX + rng.nextDouble(in: -20, 20)
    let y = y0 + rng.nextDouble(in: 0, 80)
    return CurbSnapTestFixtures.coordinate(x: x, y: y)
}

private func cspQueryPoints(count: Int, seed: UInt64, columns: Int, rows: Int) -> [CLLocationCoordinate2D] {
    var rng = CurbSnapTestRNG(seed: seed)
    var points: [CLLocationCoordinate2D] = []
    points.reserveCapacity(count)
    for _ in 0..<count {
        points.append(cspQueryPoint(&rng, columns: columns, rows: rows))
    }
    return points
}

// MARK: - Performance

final class CurbSnapIndexPerformanceTests: XCTestCase {

    private static let columns = 50
    private static let rows = 50

    /// ~5k segments (50 x 50 blocks x 2 sides = 5,000). `lazy`: XCTest instantiates the class
    /// once per test method up front, and only the perf tests need the fixture built.
    private lazy var fixture: [Segment] = CurbSnapTestFixtures.syntheticGrid(
        columns: CurbSnapIndexPerformanceTests.columns,
        rows: CurbSnapIndexPerformanceTests.rows
    )

    func testFixture_isAboutFiveThousandSegments_withUniqueBlockfaces() {
        XCTAssertEqual(fixture.count, 5_000)
        XCTAssertEqual(Set(fixture.map { $0.blockfaceKey }).count, 5_000, "every fixture blockface is unique")
        let index = CurbSnapIndex(segments: fixture)
        XCTAssertEqual(index.segmentCount, 5_000)
        XCTAssertEqual(index.edgeCount, 5_000 * 3, "3 edges per 4-vertex polyline, none long enough to split")
    }

    func testPerf_indexBuild_5kSegments() {
        let segments = fixture
        var lastEdgeCount = 0
        measure {
            let index = CurbSnapIndex(segments: segments)
            lastEdgeCount = index.edgeCount
        }
        XCTAssertEqual(lastEdgeCount, 15_000)
    }

    func testPerf_resolve_noIncumbent_1000Queries_5kSegments() {
        let index = CurbSnapIndex(segments: fixture)
        let points = cspQueryPoints(
            count: 1_000, seed: 0xA6,
            columns: CurbSnapIndexPerformanceTests.columns, rows: CurbSnapIndexPerformanceTests.rows
        )
        var snappedCount = 0
        measure {
            var snapped = 0
            for point in points {
                let outcome = index.resolve(point, incumbent: nil, metersPerPoint: 0.28, config: .standard)
                if case .snapped = outcome { snapped += 1 }
            }
            snappedCount = snapped
        }
        XCTAssertEqual(snappedCount, points.count, "every query point is within ~13 m of a curb")
    }

    func testPerf_resolve_withIncumbent_1000Queries_5kSegments() {
        let index = CurbSnapIndex(segments: fixture)
        let points = cspQueryPoints(
            count: 1_000, seed: 0xA7,
            columns: CurbSnapIndexPerformanceTests.columns, rows: CurbSnapIndexPerformanceTests.rows
        )
        var snappedCount = 0
        measure {
            var snapped = 0
            var incumbent: String? = nil
            for point in points {
                let outcome = index.resolve(point, incumbent: incumbent, metersPerPoint: 0.28, config: .standard)
                if case .snapped(let result) = outcome {
                    snapped += 1
                    incumbent = result.blockfaceKey
                }
            }
            snappedCount = snapped
        }
        XCTAssertEqual(snappedCount, points.count)
    }

    /// 3 s of a 30 Hz display link with the pin sliding along a block at walking speed
    /// (0.15 m/tick), incumbent threaded tick to tick — the real driver loop's shape.
    func testPerf_resolve_30HzSweep_threeSeconds_5kSegments() {
        let index = CurbSnapIndex(segments: fixture)
        // Slide along the y axis in column 25 (x = 0), between its two curbs (+/-7 m).
        let path: [CLLocationCoordinate2D] = (0..<90).map { (tick: Int) -> CLLocationCoordinate2D in
            CurbSnapTestFixtures.coordinate(x: Double(tick % 3) * 0.2 - 0.2, y: Double(tick) * 0.15)
        }
        var snappedCount = 0
        measure {
            var snapped = 0
            var incumbent: String? = nil
            for point in path {
                let outcome = index.resolve(point, incumbent: incumbent, metersPerPoint: 0.28, config: .standard)
                if case .snapped(let result) = outcome {
                    snapped += 1
                    incumbent = result.blockfaceKey
                }
            }
            snappedCount = snapped
        }
        XCTAssertEqual(snappedCount, path.count)
    }

    // MARK: Correctness oracle

    /// The grid index must agree with a brute-force scan over every segment (the existing
    /// `nearestPointOnPolyline` per segment, de-duplicated by blockface) wherever the answer
    /// is not a near-tie. 20 x 20 grid (800 segments), 300 deterministic points that include
    /// positions between columns (some out of range => `.noCurbInRange`).
    func testResolve_matchesBruteForce_syntheticFixture() {
        let columns = 20, rows = 20
        let segments = CurbSnapTestFixtures.syntheticGrid(columns: columns, rows: rows)
        let index = CurbSnapIndex(segments: segments)
        let config = CurbSnapConfig.standard

        var rng = CurbSnapTestRNG(seed: 0xB007)
        var compared = 0
        var snappedExpected = 0
        var noCurbExpected = 0

        for _ in 0..<300 {
            // Anywhere within the grid, columns +/- 50 m so a good share lands > 24 m from a curb.
            let column = Int(rng.nextUInt64() % UInt64(columns))
            let row = Int(rng.nextUInt64() % UInt64(rows))
            let x = Double(column - columns / 2) * 100.0 + rng.nextDouble(in: -50, 50)
            let y = Double(row - rows / 2) * 80.0 + rng.nextDouble(in: 0, 80)
            let pin = CurbSnapTestFixtures.coordinate(x: x, y: y)

            // Brute force: best distance per blockface via the existing helper.
            var bestByKey: [String: (distance: Double, id: String)] = [:]
            for segment in segments {
                guard let match = CandidateSegmentSearch.nearestPointOnPolyline(from: pin, polyline: segment.coordinates) else { continue }
                let key = segment.blockfaceKey
                if let existing = bestByKey[key], existing.distance <= match.distanceMeters { continue }
                bestByKey[key] = (match.distanceMeters, segment.id)
            }
            let ranked = bestByKey.sorted { lhs, rhs in
                lhs.value.distance != rhs.value.distance ? lhs.value.distance < rhs.value.distance : lhs.key < rhs.key
            }
            guard let top = ranked.first else { continue }
            let runnerUpGap = ranked.count > 1 ? ranked[1].value.distance - top.value.distance : Double.infinity

            // Skip answers the flat-earth kernel and the haversine reference could legitimately
            // disagree on: a near-tie for first place, or a pin right at the acquire boundary.
            if runnerUpGap < 0.3 { continue }
            if abs(top.value.distance - config.acquireRadius) < 0.3 { continue }

            let outcome = index.resolve(pin, incumbent: nil, metersPerPoint: 0.28, config: config)
            compared += 1
            if top.value.distance <= config.acquireRadius {
                snappedExpected += 1
                guard case .snapped(let result) = outcome else {
                    XCTFail("expected snap to \(top.key) at (\(x), \(y)), got \(outcome)")
                    continue
                }
                XCTAssertEqual(result.blockfaceKey, top.key, "at (\(x), \(y))")
                XCTAssertEqual(result.distanceMeters, top.value.distance, accuracy: 1e-6, "at (\(x), \(y))")
            } else {
                noCurbExpected += 1
                if case .snapped(let result) = outcome {
                    XCTFail("expected no curb at (\(x), \(y)) (nearest \(top.value.distance) m), got \(result.blockfaceKey)")
                }
            }
        }

        // The oracle must actually exercise both branches, or it proves little.
        XCTAssertGreaterThan(compared, 200)
        XCTAssertGreaterThan(snappedExpected, 20)
        XCTAssertGreaterThan(noCurbExpected, 20)
    }
}

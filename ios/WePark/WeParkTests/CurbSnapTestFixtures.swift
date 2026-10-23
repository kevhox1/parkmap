//
//  CurbSnapTestFixtures.swift
//  WeParkTests
//
//  Shared fixtures for the Stream A1 curb-snap engine tests (CurbSnapIndexTests,
//  CurbSnapIndexPerformanceTests). Spec: docs/longpress-universal-plant-spec.md §A.9 / §A.11.
//
//  Geometry is authored in LOCAL METRES (x = east, y = north) around the engine's own fixed
//  projection origin and converted to lat/lng with the same flat-earth constants the repo's
//  geometry helpers use, so a fixture curb "15 m from the pin" really is ~15 m from the pin
//  (to ~0.1%, the haversine-vs-flat-earth difference).
//
//  Everything is an `enum` namespace with uniquely-named statics — NO `extension XCTestCase`
//  (compile-failure class 4: helper-name shadowing across test files).
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain.
//

import XCTest
import CoreLocation
@testable import WePark

enum CurbSnapTestFixtures {

    // Same origin / scale as CurbSnapIndex's private projection. Duplicated on purpose: the
    // tests must not depend on the engine's private constants to author their geometry.
    private static let originLat = 40.7128
    private static let originLng = -74.0060
    private static let metersPerDegLat = 111_320.0
    private static let metersPerDegLng = 111_320.0 * cos(40.7128 * Double.pi / 180.0)

    /// Local metres (east, north) -> coordinate.
    static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: originLat + y / metersPerDegLat,
            longitude: originLng + x / metersPerDegLng
        )
    }

    /// A Segment whose polyline is the given local-metre points.
    static func segment(
        id: String,
        street: String = "MAIN ST",
        from: String = "A ST",
        to: String = "B ST",
        side: String,
        points: [(Double, Double)]
    ) -> Segment {
        let line: [[Double]] = points.map { (point: (Double, Double)) -> [Double] in
            let c = coordinate(x: point.0, y: point.1)
            return [c.latitude, c.longitude]
        }
        return Segment(
            id: id,
            street: street,
            fromStreet: from,
            to: to,
            side: side,
            line: line,
            rules: [],
            dominantCategory: nil
        )
    }

    /// A straight east-west curb at northing `y`, spanning x in [x0, x1].
    static func eastWestCurb(
        id: String,
        street: String = "MAIN ST",
        from: String = "A ST",
        to: String = "B ST",
        side: String,
        y: Double,
        x0: Double = -100,
        x1: Double = 100
    ) -> Segment {
        segment(id: id, street: street, from: from, to: to, side: side, points: [(x0, y), (x1, y)])
    }

    /// The `blockfaceKey` a fixture built with the given parts will have (mirrors
    /// `Segment.blockfaceKey`'s documented format without calling it).
    static func key(street: String = "MAIN ST", from: String = "A ST", to: String = "B ST", side: String) -> String {
        let lo = from <= to ? from : to
        let hi = from <= to ? to : from
        return "\(street)|\(lo)|\(hi)|\(side)"
    }

    /// Synthetic city: `columns` x `rows` N-S blocks (100 m between columns, 80 m blocks),
    /// two curbs per block at x = column +/- 7 m. 4-vertex polylines with a small kink.
    /// `columns * rows * 2` segments, all blockface keys unique.
    static func syntheticGrid(columns: Int, rows: Int) -> [Segment] {
        var result: [Segment] = []
        result.reserveCapacity(columns * rows * 2)
        for i in 0..<columns {
            for j in 0..<rows {
                let centerX = Double(i - columns / 2) * 100.0
                let y0 = Double(j - rows / 2) * 80.0
                for (side, offset) in [("E", 7.0), ("W", -7.0)] {
                    let x = centerX + offset
                    let points: [(Double, Double)] = [
                        (x, y0),
                        (x + 0.3, y0 + 27.0),
                        (x - 0.3, y0 + 53.0),
                        (x, y0 + 80.0),
                    ]
                    result.append(segment(
                        id: "G\(i)-\(j)-\(side)",
                        street: "AVE \(i)",
                        from: "ST \(j)",
                        to: "ST \(j + 1)",
                        side: side,
                        points: points
                    ))
                }
            }
        }
        return result
    }

    /// Deterministic Fisher-Yates shuffle driven by a seeded generator.
    static func shuffled<T>(_ items: [T], using rng: inout CurbSnapTestRNG) -> [T] {
        var copy = items
        guard copy.count > 1 else { return copy }
        for i in stride(from: copy.count - 1, to: 0, by: -1) {
            let j = Int(rng.nextUInt64() % UInt64(i + 1))
            copy.swapAt(i, j)
        }
        return copy
    }
}

/// SplitMix64 — tiny deterministic generator so fixtures/sweeps are reproducible run to run.
struct CurbSnapTestRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [lo, hi).
    mutating func nextDouble(in lo: Double, _ hi: Double) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return lo + (hi - lo) * unit
    }
}

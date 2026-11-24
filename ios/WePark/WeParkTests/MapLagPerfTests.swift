//
//  MapLagPerfTests.swift
//  WeParkTests
//
//  perf/map-lag: unit tests for the two pure skip-if-unchanged decisions that remove
//  redundant main-thread work during map pan/zoom and Drive Mode:
//    - `OverlayClassificationCache` (reuse per-segment classification for identical inputs)
//    - `TileLoader.canSkipRebuild` (do not re-publish an identical `segments` array)
//
//  Compile-failure-class notes: the system under test is `nonisolated`, so it is callable from
//  these sync tests; no XCTestCase extensions; no bare `Category`/`Protocol`/`Method`/`Ivar`.
//

import XCTest
@testable import WePark

final class MapLagPerfTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - OverlayClassificationCache

    func testCacheReusesValueForIdenticalKey() {
        let cache = OverlayClassificationCache<Int>()
        let key = OverlayClassificationKey(now: t0, mode: .currentState)
        var computeCalls = 0
        let first = cache.value(for: "a", key: key, compute: { computeCalls += 1; return 7 })
        let second = cache.value(for: "a", key: key, compute: { computeCalls += 1; return 99 })
        XCTAssertEqual(first, 7)
        XCTAssertEqual(second, 7)
        XCTAssertEqual(computeCalls, 1)
    }

    func testCacheComputesPerSegmentId() {
        let cache = OverlayClassificationCache<Int>()
        let key = OverlayClassificationKey(now: t0, mode: .currentState)
        XCTAssertEqual(cache.value(for: "a", key: key, compute: { 1 }), 1)
        XCTAssertEqual(cache.value(for: "b", key: key, compute: { 2 }), 2)
        XCTAssertEqual(cache.count, 2)
    }

    func testCacheInvalidatesWhenNowChanges() {
        let cache = OverlayClassificationCache<Int>()
        let k1 = OverlayClassificationKey(now: t0, mode: .currentState)
        let k2 = OverlayClassificationKey(now: t0.addingTimeInterval(60), mode: .currentState)
        _ = cache.value(for: "a", key: k1, compute: { 1 })
        XCTAssertEqual(cache.value(for: "a", key: k2, compute: { 2 }), 2)
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheInvalidatesWhenParkUntilInputsChange() {
        let cache = OverlayClassificationCache<Bool>()
        let target = t0.addingTimeInterval(3600)
        let base = OverlayClassificationKey(
            now: t0, mode: .parkUntil(target: target, ignoringMeteredPayment: false)
        )
        let otherTarget = OverlayClassificationKey(
            now: t0, mode: .parkUntil(target: target.addingTimeInterval(1), ignoringMeteredPayment: false)
        )
        let otherFlag = OverlayClassificationKey(
            now: t0, mode: .parkUntil(target: target, ignoringMeteredPayment: true)
        )
        XCTAssertTrue(cache.value(for: "a", key: base, compute: { true }))
        XCTAssertFalse(cache.value(for: "a", key: otherTarget, compute: { false }))
        XCTAssertTrue(cache.value(for: "a", key: otherFlag, compute: { true }))
    }

    func testCacheModesDoNotShareKeys() {
        let a = OverlayClassificationKey(now: t0, mode: .currentState)
        let b = OverlayClassificationKey(
            now: t0, mode: .parkUntil(target: t0, ignoringMeteredPayment: false)
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - TileLoader.canSkipRebuild

    func testNeverSkipsFirstRebuild() {
        XCTAssertFalse(TileLoader.canSkipRebuild(
            lastKeys: nil, lastVersion: -1, keys: ["1_1"], cacheVersion: 0
        ))
    }

    func testSkipsWhenKeysAndCacheUnchanged() {
        XCTAssertTrue(TileLoader.canSkipRebuild(
            lastKeys: ["1_1", "1_2"], lastVersion: 3, keys: ["1_1", "1_2"], cacheVersion: 3
        ))
    }

    func testDoesNotSkipWhenKeysChange() {
        XCTAssertFalse(TileLoader.canSkipRebuild(
            lastKeys: ["1_1"], lastVersion: 3, keys: ["1_1", "1_2"], cacheVersion: 3
        ))
        XCTAssertFalse(TileLoader.canSkipRebuild(
            lastKeys: ["1_1", "1_2"], lastVersion: 3, keys: ["1_2", "1_1"], cacheVersion: 3
        ))
    }

    func testDoesNotSkipWhenCacheContentsChange() {
        XCTAssertFalse(TileLoader.canSkipRebuild(
            lastKeys: ["1_1"], lastVersion: 3, keys: ["1_1"], cacheVersion: 4
        ))
    }
}

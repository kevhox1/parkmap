//
//  OverlayClassificationCache.swift
//  WePark
//
//  perf/map-lag: `ContentView.rebuildOverlays(at:)` re-classifies EVERY loaded segment
//  (~2,000+ at street zoom) on the main thread each time the visible tile window shifts -
//  once per tile crossing while driving, once per settled pan/zoom in browse. The engine's
//  answer for a segment is a pure function of (segment, `now`, and for Park Until the target
//  and the metered-payment flag), and consecutive rebuilds reuse the same `lastEvaluatedAt`,
//  so almost every segment's answer is identical to the previous rebuild's. This cache
//  remembers those answers for one exact input key and drops them all the moment the key
//  changes, so a result is only ever reused for byte-identical inputs: behavior-preserving.
//
//  Reference type on purpose: it is held in ContentView as a plain `@State` box and mutated
//  during rebuilds. A value type in `@State` would invalidate the whole body on every
//  mutation, which is the exact cost this exists to avoid.
//
//  Pure Foundation, no UI. `nonisolated` so sync unit tests can call it directly.
//

import Foundation

nonisolated struct OverlayClassificationKey: Equatable {
    /// Which classification the cached values belong to (default 5-state vs Park Until).
    enum Mode: Equatable {
        case currentState
        case parkUntil(target: Date, ignoringMeteredPayment: Bool)
        /// Plan a Trip window (separate from `parkUntil` so a trip never shares cached answers).
        case trip(arrival: Date, departure: Date)
    }

    let now: Date
    let mode: Mode
}

nonisolated final class OverlayClassificationCache<Value> {
    /// Safety valve so a long session cannot grow the table without bound. Far above the
    /// number of segments ever loaded at once.
    static var maxEntries: Int { 50_000 }

    private var key: OverlayClassificationKey?
    private var values: [String: Value] = [:]

    init() {}

    /// Number of cached entries (tests).
    var count: Int { values.count }

    /// Returns the cached value for `id` under `key`, computing and storing it on a miss.
    /// A different `key` than the previous call discards everything first.
    func value(
        for id: String,
        key newKey: OverlayClassificationKey,
        compute: () -> Value
    ) -> Value {
        if key != newKey || values.count > Self.maxEntries {
            key = newKey
            values.removeAll(keepingCapacity: true)
        }
        if let hit = values[id] { return hit }
        let computed = compute()
        values[id] = computed
        return computed
    }
}

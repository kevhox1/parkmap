//
//  TileLoader.swift
//  WePark
//
//  Responsible for:
//    1. Parsing tiles/index.json on init (lazy, one-time).
//    2. Mapping a visible MKCoordinateRegion to the set of tile keys that
//       intersect it — port of getTilesForBounds() from index.html:2221.
//    3. Loading and decoding tile_R_C.json files from the app bundle on demand.
//    4. Returning a flat [Segment] for the caller (ContentView) to render.
//
//  Uses the @Observable macro (iOS 17+, Observation framework) instead of
//  ObservableObject so that ContentView automatically re-renders when `segments`
//  changes without needing an explicit Combine import.
//
//  ⚠️  Bundle layout: Xcode's PBXFileSystemSynchronizedRootGroup flattens
//  Resources/ subdirectories into the app bundle root. All resource reads use
//  Bundle.main.url(forResource:withExtension:) — NEVER construct
//  Bundle.main.bundlePath + "/tiles/..." paths; they silently fail at runtime.
//  (Confirmed in W1a QA finding #1, docs/ios-mvp-spec.md §4.2.)
//

import Foundation
import MapKit
import Observation

// MARK: - Index JSON shape

private struct TileIndex: Decodable {
    let gridSize: GridSize
    let latMin: Double
    let latMax: Double
    let lngMin: Double
    let lngMax: Double
    let rowSize: Double
    let colSize: Double
    let totalSegments: Int
    let totalTiles: Int
    let tiles: [TileEntry]

    struct GridSize: Decodable {
        let rows: Int
        let cols: Int
    }

    struct TileEntry: Decodable {
        let row: Int
        let col: Int
        let filename: String
        let segmentCount: Int
    }
}

// MARK: - TileLoader

@Observable
@MainActor
final class TileLoader {

    // MARK: Observable state
    /// All segments currently loaded in memory (from tiles that have been fetched).
    /// ContentView observes this via @Observable — updates trigger a re-render.
    private(set) var segments: [Segment] = []

    // MARK: Private state
    private var tileIndex: TileIndex?
    /// Quick lookup: "row_col" → true, for tiles that actually exist.
    private var tileSet: Set<String> = []
    /// In-memory cache of decoded segments per tile key ("row_col").
    private var cache: [String: [Segment]] = [:]
    /// Tracks the most-recently-requested region. In-flight Tasks read this
    /// at execution time (not capture time) so rapid panning can't cause a
    /// late-finishing Task to overwrite segments with a stale viewport.
    private var currentRegion: MKCoordinateRegion?

    // MARK: Init
    init() {
        loadIndex()
    }

    // MARK: - Public API

    /// Called when the visible map region changes. Loads any tiles that
    /// intersect the new bounds and aren't already cached. The `segments`
    /// property updates when new tiles finish loading, triggering a re-render.
    func loadTiles(forRegion region: MKCoordinateRegion) {
        // Update currentRegion first. Any Task that finishes after a later
        // pan will read this value at execution time, not the captured arg.
        currentRegion = region

        let keys = tileKeys(forRegion: region)
        let uncached = keys.filter { cache[$0] == nil }
        guard !uncached.isEmpty else {
            // All tiles already cached — still rebuild in case currentRegion
            // advanced while a prior Task was in flight.
            rebuildSegments(forKeys: keys)
            return
        }

        // Decode each uncached tile concurrently then merge back on the main actor.
        Task { @MainActor in
            await withTaskGroup(of: (String, [Segment]?).self) { group in
                for key in uncached {
                    group.addTask {
                        let decoded = await self.decodeTile(key: key)
                        return (key, decoded)
                    }
                }
                for await (key, decoded) in group {
                    if let segs = decoded {
                        self.cache[key] = segs
                    } else {
                        // Mark as empty so we don't retry on every pan.
                        self.cache[key] = []
                    }
                }
            }
            // Use self.currentRegion — NOT the captured `region` argument —
            // so a Task that finishes late always renders the live viewport.
            guard let liveRegion = self.currentRegion else { return }
            rebuildSegments(forKeys: tileKeys(forRegion: liveRegion))
        }
    }

    // MARK: - Private helpers

    /// Parses index.json from the bundle. Builds the tileSet lookup.
    private func loadIndex() {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "json") else {
            print("[TileLoader] index.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let idx = try JSONDecoder().decode(TileIndex.self, from: data)
            tileIndex = idx
            tileSet = Set(idx.tiles.map { "\($0.row)_\($0.col)" })
            print("[TileLoader] index loaded: \(idx.totalTiles) tiles, \(idx.totalSegments) segments")
        } catch {
            print("[TileLoader] failed to load index.json: \(error)")
        }
    }

    /// Decodes a single tile from the bundle off the main actor to avoid blocking UI.
    /// Key format: "row_col" e.g. "12_7" → resource name "tile_12_7".
    /// Returns nil if the file is missing or malformed.
    private nonisolated func decodeTile(key: String) async -> [Segment]? {
        let resourceName = "tile_\(key)"
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            // Some keys derived from the region may not correspond to existing tiles —
            // the tile set is sparse across Manhattan.  Suppress noise.
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Segment].self, from: data)
        } catch {
            print("[TileLoader] failed to decode \(resourceName).json: \(error)")
            return nil
        }
    }

    /// Computes which tile keys overlap the given map region.
    /// Ported from getTilesForBounds() in index.html:2221.
    ///
    /// The JS uses Leaflet `bounds.getSouth/getNorth/getWest/getEast`; we
    /// replicate those from the MKCoordinateRegion center + span.
    ///
    /// Buffer = 2 extra tiles in each direction for smoother panning,
    /// matching the PWA's `const buffer = 2`.
    private func tileKeys(forRegion region: MKCoordinateRegion) -> [String] {
        guard let idx = tileIndex else { return [] }

        let halfLat = region.span.latitudeDelta / 2.0
        let halfLng = region.span.longitudeDelta / 2.0
        let south = region.center.latitude  - halfLat
        let north = region.center.latitude  + halfLat
        let west  = region.center.longitude - halfLng
        let east  = region.center.longitude + halfLng

        let buffer = 2
        let rowMin = Int(floor((south - idx.latMin) / idx.rowSize)) - buffer
        let rowMax = Int(floor((north - idx.latMin) / idx.rowSize)) + buffer
        let colMin = Int(floor((west  - idx.lngMin) / idx.colSize)) - buffer
        let colMax = Int(floor((east  - idx.lngMin) / idx.colSize)) + buffer

        // Guard against degenerate ranges (e.g. zoomed out so far that rowMin > rowMax
        // after clamping would produce an empty range — shouldn't happen but be safe).
        guard rowMin <= rowMax, colMin <= colMax else { return [] }

        var result: [String] = []
        for r in rowMin...rowMax {
            for c in colMin...colMax {
                let key = "\(r)_\(c)"
                if tileSet.contains(key) {
                    result.append(key)
                }
            }
        }
        return result
    }

    /// Flattens all cached segments for the given tile keys into `self.segments`.
    private func rebuildSegments(forKeys keys: [String]) {
        var flat: [Segment] = []
        flat.reserveCapacity(keys.count * 40) // rough average ~40 segs/tile
        for key in keys {
            if let segs = cache[key] {
                flat.append(contentsOf: segs)
            }
        }
        segments = flat
    }
}

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
//  W4 fix-pass-1 (2026-05-11): Added LRU eviction to `cache`. Previously the cache
//  grew monotonically — after 5 minutes of panning Manhattan, all 1,028 tiles and
//  their decoded [Segment] arrays would accumulate in RAM (~200–500 MB). The cache
//  is now capped at `maxCachedTiles`. On eviction the LRU tile is removed, freeing
//  its [Segment] array. The evicted tile will be re-decoded on next access (from the
//  bundle, which is cheap — ~1ms per tile on the simulator).
//
//  Rendering architecture refactor (2026-05-11): Cap raised from 50 → 200.
//  With MKMultiPolyline overlays (6 total, replacing 40k MapPolylines), per-render
//  cost is negligible. The previous cap of 50 tiles caused cache thrashing during
//  aggressive panning — evicted tiles were immediately re-requested, producing the
//  "only upper-Manhattan rendering" symptom Kevin observed. 200 tiles × ~25 KB decoded
//  ≈ 5 MB segment data — well within budget. Total tile set is 1,028 tiles × ~25 KB
//  ≈ 25 MB; caching all 1,028 would be fine too, but 200 (~25%) is conservative.
//
//  Zoom-out crash fix (2026-08-23): `tileKeys(forRegion:)` previously looped every
//  row/col combination in the viewport's bounds with NO upper limit before checking
//  membership in `tileSet`. The tile grid is fine-grained (rowSize ≈ 0.00227°,
//  colSize ≈ 0.00226°), so a wide-enough viewport made that loop explode — a 50°
//  span is ~484M iterations, a world-scale span is ~12.6B — each doing a string
//  interpolation + Set lookup. That is a watchdog termination presenting as a crash
//  on-device. Separately, `Int(floor(x))` TRAPS at runtime for non-finite (NaN/inf)
//  or out-of-Int-range `Double` input; MapKit can report a degenerate `region.span`
//  (observed pattern: absurd or non-finite `latitudeDelta`) when the camera is at
//  extreme pitch/altitude mid-gesture, which would crash instantly rather than hang.
//  Fixed by (1) bailing out on non-finite region math before any Int conversion, and
//  (2) clamping row/col ranges to the tile grid's ACTUAL extent (`gridSize.rows` /
//  `gridSize.cols` from index.json) before looping, via `clampToInt` — which never
//  traps. See `tileKeys(forRegion:)` and `maxLoadSpanDegrees` below.
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
    /// Bounded by `maxCachedTiles` via LRU eviction. (W4 fix-pass-1.)
    private var cache: [String: [Segment]] = [:]
    /// LRU access-order list. Most-recently-used key is at the end.
    /// Invariant: `lruOrder.count == cache.count` at all times (excluding empty-tile sentinels,
    /// which are stored as [] in cache but still count against the cap).
    private var lruOrder: [String] = []
    /// Maximum number of tiles to keep in cache simultaneously.
    /// Raised to 200 in the rendering-architecture refactor (2026-05-11).
    /// At ~40 segments/tile × ~25KB decoded/tile, 200 tiles ≈ ~5 MB of segment data.
    /// The previous cap of 50 caused cache thrashing that contributed to the
    /// "only upper-Manhattan rendering" symptom. 200 = ~25% of all 1,028 tiles.
    private let maxCachedTiles = 200
    /// Tracks the most-recently-requested region. In-flight Tasks read this
    /// at execution time (not capture time) so rapid panning can't cause a
    /// late-finishing Task to overwrite segments with a stale viewport.
    private var currentRegion: MKCoordinateRegion?

    /// Maximum visible-region span (in degrees, checked on both axes) above which
    /// `loadTiles` does no work at all — no `tileKeys` computation, no decode
    /// `Task`s, no cache touches.
    ///
    /// Chosen from the data, not taste: the tile grid's actual coverage (index.json)
    /// is `latMin: 40.7, latMax: 40.882` (0.182° lat) × `lngMin: -74.02, lngMax:
    /// -73.907` (0.113° lng) — all of NYC is ~0.18° across at its widest. At a 0.5°
    /// span, all of NYC already renders as a sub-pixel smear (2.7× its largest
    /// dimension) well before this method would even run — and
    /// `ContentView.polylineHideSpanThreshold` (0.04°) already stops *rendering*
    /// polylines far earlier than that. This constant is the outer backstop: it
    /// stops *loading* (tile-key computation + bundle decode) once the viewport is
    /// so wide that no amount of loaded data could produce a visible parking
    /// segment. 0.5° leaves headroom so a user panning slightly past the city edge
    /// doesn't flicker the loader on/off at the boundary.
    ///
    /// Kevin: tune on-device if 0.5° feels too eager/lazy to cut off loading.
    static let maxLoadSpanDegrees: Double = 0.5

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

        // Zoomed out past NYC's actual coverage — no tile could produce a visible
        // segment at this scale. Skip tileKeys/decode entirely rather than doing
        // (now-bounded, but still pointless) grid work. See `maxLoadSpanDegrees`.
        guard region.span.latitudeDelta <= Self.maxLoadSpanDegrees,
              region.span.longitudeDelta <= Self.maxLoadSpanDegrees else {
            return
        }

        let keys = tileKeys(forRegion: region)
        let uncached = keys.filter { cache[$0] == nil }
        guard !uncached.isEmpty else {
            // All tiles already cached — touch each key to refresh LRU order,
            // then rebuild. This prevents tiles in active view from being evicted.
            for key in keys { touchInCache(key: key) }
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
                    let segs = decoded ?? []
                    self.insertIntoCache(key: key, segments: segs)
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
    /// Thin instance wrapper around the pure `Self.tileKeys(forRegion:...)` below —
    /// supplies the grid parameters parsed from `index.json` at init time. See that
    /// static function for the full algorithm and crash-fix rationale.
    private func tileKeys(forRegion region: MKCoordinateRegion) -> [String] {
        guard let idx = tileIndex else { return [] }
        return Self.tileKeys(
            forRegion: region,
            gridRows: idx.gridSize.rows,
            gridCols: idx.gridSize.cols,
            latMin: idx.latMin,
            lngMin: idx.lngMin,
            rowSize: idx.rowSize,
            colSize: idx.colSize,
            tileSet: tileSet
        )
    }

    /// Pure tile-key computation: no `Bundle`/`TileIndex`-loading dependency, directly
    /// unit-testable without needing to load `index.json` from a bundle (same
    /// "pure, directly testable" pattern as the `static func` decision helpers in
    /// `MapViewRepresentable`). The instance method `tileKeys(forRegion:)` above is
    /// the production call site, supplying grid parameters from the parsed
    /// `TileIndex`.
    ///
    /// The JS uses Leaflet `bounds.getSouth/getNorth/getWest/getEast`; we
    /// replicate those from the MKCoordinateRegion center + span.
    ///
    /// `buffer` = 2 extra tiles in each direction for smoother panning,
    /// matching the PWA's `const buffer = 2`.
    ///
    /// Crash fix (2026-08-23): row/col ranges are clamped to the tile grid's ACTUAL
    /// extent (`gridRows` / `gridCols`) before the loop below runs, and all
    /// Double→Int conversions go through `clampToInt` instead of `Int(floor(...))`.
    /// Without the clamp, a viewport spanning far beyond NYC (up to world-scale)
    /// produced a row/col range in the hundreds of millions to billions — each cell
    /// visited to do a miss lookup in `tileSet` — a watchdog-timeout crash. Without
    /// the finite/`clampToInt` guards, a non-finite or absurdly large `region.span`
    /// (MapKit can report one mid-gesture at extreme pitch) would TRAP immediately in
    /// `Int(floor(x))` instead of hanging. The grid's real extent is only 80 rows ×
    /// 50 cols (index.json `gridSize`), so after clamping this loop is bounded at
    /// roughly `(rows + 2·buffer) × (cols + 2·buffer)` ≈ 84 × 54 ≈ 4,536 iterations
    /// for ANY input, valid or not.
    static func tileKeys(
        forRegion region: MKCoordinateRegion,
        gridRows: Int,
        gridCols: Int,
        latMin: Double,
        lngMin: Double,
        rowSize: Double,
        colSize: Double,
        tileSet: Set<String>,
        buffer: Int = 2
    ) -> [String] {
        let halfLat = region.span.latitudeDelta / 2.0
        let halfLng = region.span.longitudeDelta / 2.0
        let south = region.center.latitude  - halfLat
        let north = region.center.latitude  + halfLat
        let west  = region.center.longitude - halfLng
        let east  = region.center.longitude + halfLng

        // Bail out on non-finite region math (NaN/inf) BEFORE any Int conversion.
        // `Int(floor(x))` traps at runtime for non-finite input — this guard turns
        // a potential instant crash into "no tiles for this frame".
        guard south.isFinite, north.isFinite, west.isFinite, east.isFinite else {
            return []
        }

        let rowMinRaw = floor((south - latMin) / rowSize) - Double(buffer)
        let rowMaxRaw = floor((north - latMin) / rowSize) + Double(buffer)
        let colMinRaw = floor((west  - lngMin) / colSize) - Double(buffer)
        let colMaxRaw = floor((east  - lngMin) / colSize) + Double(buffer)

        // Clamp to the tile grid's ACTUAL extent, not the viewport. Every tile that
        // exists has row in [0, gridRows - 1] and col in [0, gridCols - 1] (see
        // index.json); any row/col outside that range is guaranteed to miss
        // `tileSet.contains` anyway, so clamping first only removes iterations that
        // could never have produced a hit — no functional change for any viewport
        // that actually overlaps NYC, and a hard bound on iteration count for any
        // viewport that doesn't.
        let rowBound = max(0, gridRows - 1)
        let colBound = max(0, gridCols - 1)

        let rowMin = clampToInt(rowMinRaw, lower: 0, upper: rowBound)
        let rowMax = clampToInt(rowMaxRaw, lower: 0, upper: rowBound)
        let colMin = clampToInt(colMinRaw, lower: 0, upper: colBound)
        let colMax = clampToInt(colMaxRaw, lower: 0, upper: colBound)

        // Guard against degenerate/inverted ranges (e.g. a region entirely outside
        // the grid, where clamping pins both min and max to the same bound but on
        // opposite sides — or a genuinely inverted south > north input).
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

    /// Converts a `Double` to an `Int` clamped into `[lower, upper]`.
    ///
    /// Unlike `Int(value)` / `Int(floor(value))`, this NEVER traps: non-finite
    /// (NaN/±infinity) or out-of-`Int`-range input clamps to the nearest bound
    /// instead of crashing. Used by `tileKeys(forRegion:...)` to convert
    /// region-derived row/col bounds that may be garbage (mid-gesture MapKit state,
    /// or a viewport far outside the tile grid) into safe grid indices.
    static func clampToInt(_ value: Double, lower: Int, upper: Int) -> Int {
        guard value.isFinite else { return value > 0 ? upper : lower }
        if value <= Double(lower) { return lower }
        if value >= Double(upper) { return upper }
        return Int(value)
    }

    // MARK: - LRU cache helpers

    /// Inserts or updates a key in the cache, then evicts the LRU entry if
    /// the cache has grown beyond `maxCachedTiles`.
    private func insertIntoCache(key: String, segments: [Segment]) {
        if cache[key] != nil {
            // Already present — treat as an access, move to MRU end.
            lruOrder.removeAll { $0 == key }
        }
        cache[key] = segments
        lruOrder.append(key)
        evictIfNeeded()
    }

    /// Records an access hit for an already-cached key, moving it to the MRU end.
    /// No-op if the key is not in cache.
    private func touchInCache(key: String) {
        guard cache[key] != nil else { return }
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
    }

    /// Evicts the least-recently-used entry while the cache exceeds `maxCachedTiles`.
    private func evictIfNeeded() {
        while cache.count > maxCachedTiles, let oldest = lruOrder.first {
            cache.removeValue(forKey: oldest)
            lruOrder.removeFirst()
        }
    }

    // MARK: - Segment rebuild

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

//
//  Segment.swift
//  WePark
//
//  Codable mirror of each element in a tile_R_C.json array.
//
//  Observed tile JSON shape (from tile_0_3.json):
//  {
//    "id":   "SOUTH_STREET_WHITEHALL_STREET_OLD_SLIP_E_9",
//    "street": "SOUTH STREET",
//    "from": "WHITEHALL STREET",
//    "to":   "OLD SLIP",
//    "side": "E",
//    "line": [[40.701848,-74.010871],[40.70179,-74.01112],...],
//      // coordinate pairs are [lat, lng] — note: NOT [lng, lat] like GeoJSON.
//      // This matches the PWA which reads line[i][0] as lat and line[i][1] as lng.
//    "rules": [...],                       // array of ParkingRule
//    "dominantCategory": "NO_STANDING"     // pre-computed by build script; may be absent on
//                                          // a small number of edge segments — handle nil.
//  }
//
//  CodingKeys note: all JSON keys are already lowercase/snake_case Swift-compatible
//  via the default JSONDecoder strategy, EXCEPT "from" which is a Swift keyword.
//  We define explicit CodingKeys to map "from" → `fromStreet`.
//
//  W3 change: removed `polylineColor` — coloring is now handled entirely by
//  ParkingRulesEngine.currentStateColor(for:at:), which encodes CURRENT STATE
//  rather than static category. ContentView calls the engine directly.
//

import Foundation
import CoreLocation

struct Segment: Codable, Identifiable {
    let id: String

    /// Street name in all-caps, e.g. "SOUTH STREET".
    let street: String

    /// Cross street at the start of the segment ("from" in JSON).
    let fromStreet: String

    /// Cross street at the end of the segment.
    let to: String

    /// Side of the street: "E", "W", "N", or "S".
    let side: String

    /// Ordered coordinate pairs — each element is [lat, lng].
    /// Stored as [[Double]] to match the JSON; use `coordinates` for CLLocationCoordinate2D.
    let line: [[Double]]

    /// Parking rules for this segment.
    let rules: [ParkingRule]

    /// Pre-computed most-restrictive category, written by the tile build script.
    /// Nil on a small number of segments — callers should fall back to
    /// `ParkingRulesEngine.dominantCategory(rules:)`.
    let dominantCategory: Category?

    // MARK: - FT-11: One-way data (decoded optionally — tile regen ships separately)

    /// True when the segment's street is one-way. Nil/absent = treat as two-way.
    ///
    /// Populated by the tile pipeline once @backend-data ships the `build/preprocess.js` change.
    /// Until then this is nil for all segments, and code that checks it falls back gracefully
    /// (sweeper → show direction picker instead of auto-deriving).
    let oneway: Bool?

    /// Which endpoint legal one-way travel heads toward: `"from"` or `"to"`.
    ///
    /// Non-nil only when `oneway == true`. Nil when the street is two-way or when the tile
    /// predates the FT-11 pipeline change. iOS uses this to auto-derive the sweeper
    /// direction without asking the user.
    let onewayToward: String?

    // MARK: - Computed helpers

    /// Converts raw `line` pairs to Core Location coordinates for MapKit.
    var coordinates: [CLLocationCoordinate2D] {
        line.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    /// Midpoint of the segment (used for viewport-intersection culling).
    var midpoint: CLLocationCoordinate2D? {
        let coords = coordinates
        guard !coords.isEmpty else { return nil }
        let mid = coords.count / 2
        return coords[mid]
    }

    // MARK: - Init
    //
    // Explicit memberwise init so callers that predate FT-11 (including tests)
    // don't need to supply `oneway` / `onewayToward`. Default is nil for both —
    // semantically identical to "data absent from tile" (treat as two-way).
    //
    // The synthesised memberwise init would require ALL stored properties,
    // which would break every Segment(…dominantCategory:) call site in the test suite.
    init(
        id: String,
        street: String,
        fromStreet: String,
        to: String,
        side: String,
        line: [[Double]],
        rules: [ParkingRule],
        dominantCategory: Category?,
        oneway: Bool? = nil,
        onewayToward: String? = nil
    ) {
        self.id             = id
        self.street         = street
        self.fromStreet     = fromStreet
        self.to             = to
        self.side           = side
        self.line           = line
        self.rules          = rules
        self.dominantCategory = dominantCategory
        self.oneway         = oneway
        self.onewayToward   = onewayToward
    }

    // MARK: - CodingKeys
    enum CodingKeys: String, CodingKey {
        case id
        case street
        case fromStreet = "from"   // "from" is a reserved word in Swift
        case to
        case side
        case line
        case rules
        case dominantCategory
        // FT-11: one-way fields (optional — absent on pre-FT-11 tiles)
        case oneway
        case onewayToward = "oneway_toward"
    }
}

// MARK: - FT-15 / TF2-15: blockfaceKey

extension Segment {
    /// Direction-agnostic blockface identity: `STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE`.
    ///
    /// Spec: `docs/ft15-tf215-temporary-block-restrictions-spec.md` §4.3.
    ///
    /// This is the single source of truth for block identity used on both the write
    /// path (building `pins.segment_id` when a user taps blocks to report a temporary
    /// restriction) and the read path (matching a viewed `Segment` against
    /// `visiblePins`). Cross streets are alphabetically sorted so two `Segment` rows
    /// describing the same physical blockface — e.g. one per direction of a divided
    /// street's sub-segments, or rows that happen to store `from`/`to` swapped —
    /// still resolve to the identical key.
    ///
    /// Deliberately reads `street`, `fromStreet`, `to`, and `side` verbatim off the
    /// already-decoded tile data — no street-name normalization, no fuzzy matching,
    /// no on-device re-derivation of anything. Block identity never depends on
    /// text a user typed or picked; see the spec's §4.1 rationale for why an
    /// on-device equivalent of the FT-14 build-time name normalizer is explicitly
    /// out of scope here.
    ///
    /// Note on casing: `blockfaceKey` does NOT uppercase anything itself — no
    /// `.uppercased()` call anywhere in this property. Segment values happen to
    /// already be all-caps because the tile-build pipeline guarantees it (see this
    /// file's own top-of-file doc comment: "Street name in all-caps"), so the key is
    /// uppercase *as a consequence of the source data*, not because this property
    /// normalizes it. If a future tile source ever stops guaranteeing that, this key
    /// would silently start mixing case rather than normalizing — that's intentional
    /// per the "verbatim, zero-touch reads" design (§4.1), not an oversight.
    var blockfaceKey: String {
        let (lo, hi) = fromStreet <= to ? (fromStreet, to) : (to, fromStreet)
        return "\(street)|\(lo)|\(hi)|\(side)"
    }
}

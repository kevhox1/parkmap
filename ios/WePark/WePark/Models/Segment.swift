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

    /// The display color for this segment's polyline.
    var polylineColor: Color {
        (dominantCategory ?? .unknown).swiftUIColor
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
    }
}

// MARK: - Color import for polylineColor
import SwiftUI

//
//  ParkingRule.swift
//  WePark
//
//  Codable mirror of the rule objects embedded in each Segment in the tile JSONs.
//
//  Tile JSON shape (from tile_0_3.json, confirmed):
//  {
//    "category": "NO_STANDING",
//    "description": "NO STANDING ANYTIME <-> ...",
//    "days": [0,1,2,3,4,5,6],       // 0=Sun … 6=Sat; always present, may be empty
//    "timeRanges": [                  // always present, may be empty []
//      { "start": 420, "end": 600 }  // minutes since midnight
//    ],
//    "anytime": true,                 // true → rule applies all hours on matching days
//    "arrow": "both"                  // "both" | "towards" | "away" — sign arrow direction
//  }
//
//  All fields are present in observed tile data; treat as non-optional for now
//  but use safe decoding patterns just in case older/edge tiles omit extras.
//

import Foundation

struct TimeRange: Codable, Equatable {
    /// Start time in minutes since midnight (e.g. 420 = 7:00 AM).
    let start: Int
    /// End time in minutes since midnight (e.g. 600 = 10:00 AM).
    let end: Int
}

struct ParkingRule: Codable {
    /// Parking restriction category.
    let category: Category

    /// Human-readable sign text from the source NYC DOT data.
    let description: String

    /// Days of week this rule is active (0=Sunday … 6=Saturday).
    /// An empty array means no specific day — check `anytime`.
    let days: [Int]

    /// Time windows this rule is active on matching days.
    /// An empty array + anytime==true means the rule is active around the clock.
    let timeRanges: [TimeRange]

    /// When true, the rule is active at all hours on the matching days;
    /// `timeRanges` is ignored for scheduling purposes.
    let anytime: Bool

    /// Sign arrow direction.
    /// One of: "both", "towards", "away", or absent.
    /// Optional because a small number of legacy segments may omit it.
    let arrow: String?
}

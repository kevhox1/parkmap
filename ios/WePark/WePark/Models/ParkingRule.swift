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

// MARK: - Midnight-aware semantics
//
// The tile pipeline's `parseTimeStr` maps "MIDNIGHT" to minute 0, so "9AM-MIDNIGHT" is stored
// as {start: 540, end: 0}. An end of 0 therefore means 24:00 of the SAME day, never "the start
// of the day". A range whose end is > 0 and <= start (11PM-1AM) genuinely wraps into the next
// calendar day. Every minute-of-day comparison in the app goes through these helpers so the
// map, the cards, the labels and the hero cannot disagree.
extension TimeRange {
    /// End minute normalized to 1...1440 (0 -> 1440, "midnight").
    nonisolated var endMinute: Int { end == 0 ? 1440 : end }

    /// True when the window continues past midnight into the next calendar day (e.g. 11PM-1AM).
    /// A range ending exactly at midnight does NOT wrap.
    nonisolated var wrapsPastMidnight: Bool { start >= endMinute }

    /// True when `minute` falls in the part of the window anchored on the rule's own day.
    nonisolated func containsOnAnchorDay(minute: Int) -> Bool {
        minute >= start && minute < (wrapsPastMidnight ? 1440 : endMinute)
    }

    /// True when `minute` falls in the part of a wrapping window that spills into the day after
    /// its anchor day (the 12AM-1AM tail of an 11PM-1AM range).
    nonisolated func spillContains(minute: Int) -> Bool {
        wrapsPastMidnight && minute < end
    }
}

extension ParkingRule {
    /// Whether `tr` (one of this rule's ranges) is in effect at (`dayOfWeek`, `minuteOfDay`),
    /// honoring the rule's days for the anchor day and the previous day's spill past midnight.
    /// Empty `days` means every day when `emptyDaysMeansEveryDay` (the metered convention).
    nonisolated func rangeActive(_ tr: TimeRange, dayOfWeek: Int, minuteOfDay: Int, emptyDaysMeansEveryDay: Bool) -> Bool {
        func dayMatches(_ d: Int) -> Bool {
            days.isEmpty ? emptyDaysMeansEveryDay : days.contains(d)
        }
        if dayMatches(dayOfWeek) && tr.containsOnAnchorDay(minute: minuteOfDay) { return true }
        let previous = (dayOfWeek + 6) % 7
        return dayMatches(previous) && tr.spillContains(minute: minuteOfDay)
    }
}

struct ParkingRule: Codable, Equatable {
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

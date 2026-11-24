//
//  ASPSuspension.swift
//  WePark
//
//  Codable model for asp-2026.json. Lives in Shared/ (with the JSON itself) so the app and the App Clip
//  read ONE suspension calendar; both bundles get the file via the synchronized Shared group.
//
//  File shape:
//  {
//    "year": 2026,
//    "dates": [
//      { "date": "2026-01-01", "reason": "New Year's Day" },
//      ...
//    ]
//  }
//
//  Source: docs/ios-mvp-spec.md §4.4 — data extracted from
//  ASP_SUSPENSIONS_2026 constant at index.html:2031–2072.
//

import Foundation

/// A single ASP suspension date with its plain-English reason.
nonisolated struct ASPSuspension: Codable, Equatable, Sendable {
    /// Suspension date in ISO-8601 format: "yyyy-MM-dd" (ET-zone date, no time component).
    let date: String
    /// Human-readable reason shown in the ASP banner, e.g. "Memorial Day".
    let reason: String
}

/// Top-level container decoded from asp-2026.json.
nonisolated struct ASPSuspensionCalendar: Codable, Sendable {
    /// Calendar year (e.g. 2026). Used for sanity checks, not for business logic.
    let year: Int
    /// Ordered list of suspended dates for the year.
    let dates: [ASPSuspension]
}

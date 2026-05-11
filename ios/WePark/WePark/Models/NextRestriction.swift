//
//  NextRestriction.swift
//  WePark
//
//  Value type returned by ParkingRulesEngine.nextRestriction(for:at:).
//  Swift port of the { hours, label, cat, rule } object from
//  computeNextRestrictionHours() at index.html:5315.
//
//  Optionality rationale:
//  - `hours` is always present (defaults to 168.0 = one week when no restriction found).
//  - `label` is a human-readable category name ("ASP Mon/Thu", "No Parking", etc.)
//    nil when no restriction was found within the 14-day window.
//  - `category` and `rule` are nil when no relevant restriction rule was found,
//    or when hours == 168 (the "no restriction" sentinel).
//
//  Consumer contract:
//  - hours == 0 means "active right now" — the block is currently restricted.
//  - 0 < hours < 168 means "coming up" — block is free but restriction starts in `hours`.
//  - hours >= 168 means "no upcoming restriction in the 14-day window" — safe for
//    extended parking. NotificationScheduler treats this as "no notification needed".
//

import Foundation

struct NextRestriction: Equatable {

    /// Hours until the next restriction starts.
    /// - 0: restriction is active right now.
    /// - 0..<168: restriction coming within the 14-day window.
    /// - 168: no restriction found (sentinel, matches JS return value).
    let hours: Double

    /// Human-readable category label, e.g. "ASP Mon/Thu", "No Parking".
    /// Nil when no restriction was found (hours == 168).
    let label: String?

    /// The parking category of the upcoming restriction, if any.
    let category: Category?

    /// The specific rule that produces the restriction, if any.
    /// Consumers can inspect this for detailed time-range display.
    let rule: ParkingRule?

    /// Convenience: true when the restriction is active right now.
    var isActiveNow: Bool { hours == 0 }

    /// Convenience: true when no restriction was found in the 14-day window.
    var isUnrestricted: Bool { hours >= 168 }
}

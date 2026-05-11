//
//  ASPSuspensionService.swift
//  WePark
//
//  Loads asp-2026.json from the app bundle and answers suspension queries.
//  PWA equivalent: isASPSuspended() at index.html:2135.
//
//  Bundle layout note (W1a QA finding #1): Xcode's PBXFileSystemSynchronizedRootGroup
//  flattens Resources/ into the bundle root. Use Bundle.main.url(forResource:withExtension:)
//  — never construct paths manually with bundlePath + "/...".
//
//  Thread safety: this class is intentionally not @Observable — the suspension
//  calendar is loaded once at init and never changes. It is safe to call from
//  any thread after init (reads only from an immutable Dictionary).
//

import Foundation

// MARK: - Banner state

/// The three possible states for the ASP status banner.
/// Consumed by W7's ASPBanner view; logic belongs here in the service.
/// PWA equivalent: renderASPStatusBanner() at index.html:2093.
enum SuspensionBannerState: Equatable {
    /// ASP is suspended today — show red banner with reason.
    case todaySuspended(reason: String)
    /// ASP is suspended tomorrow — show yellow banner with reason.
    case tomorrowSuspended(reason: String)
    /// ASP is in effect (neither today nor tomorrow is suspended).
    case aspInEffect
}

// MARK: - ASPSuspensionService

final class ASPSuspensionService {

    // MARK: - Private state

    /// Dictionary keyed by "yyyy-MM-dd" strings for O(1) lookup.
    /// Populated from asp-2026.json on init; never mutated after that.
    private let suspensionsByDate: [String: String]   // date → reason

    // MARK: - Init

    /// Loads and decodes asp-2026.json from the app bundle.
    /// Prints a warning to the console if the file is missing or malformed;
    /// the service degrades gracefully (all dates treated as non-suspended).
    init() {
        guard let url = Bundle.main.url(forResource: "asp-2026", withExtension: "json") else {
            print("[ASPSuspensionService] asp-2026.json not found in bundle — suspension calendar unavailable")
            suspensionsByDate = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let calendar = try JSONDecoder().decode(ASPSuspensionCalendar.self, from: data)
            var dict: [String: String] = [:]
            dict.reserveCapacity(calendar.dates.count)
            for entry in calendar.dates {
                dict[entry.date] = entry.reason
            }
            suspensionsByDate = dict
            print("[ASPSuspensionService] loaded \(dict.count) suspension dates for \(calendar.year)")
        } catch {
            print("[ASPSuspensionService] failed to decode asp-2026.json: \(error)")
            suspensionsByDate = [:]
        }
    }

    // MARK: - Public API

    /// Returns true if the given date (evaluated in ET) is in the suspension calendar.
    /// PWA equivalent: isASPSuspended(dateStr) at index.html:2135.
    func isSuspended(_ date: Date) -> Bool {
        let key = date.toETDateString()
        return suspensionsByDate[key] != nil
    }

    /// Returns the suspension reason if the given date is suspended, nil otherwise.
    func reasonForSuspension(_ date: Date) -> String? {
        let key = date.toETDateString()
        return suspensionsByDate[key]
    }

    /// Returns the banner state for the ASP status banner based on today and tomorrow (ET).
    /// PWA equivalent: the three-state logic inside renderASPStatusBanner() at index.html:2093.
    ///
    /// States, in priority order:
    ///   1. Today is suspended  → .todaySuspended(reason:)
    ///   2. Tomorrow is suspended → .tomorrowSuspended(reason:)
    ///   3. Otherwise → .aspInEffect
    func suspensionState(at now: Date = .nowET) -> SuspensionBannerState {
        let today = now
        if let reason = reasonForSuspension(today) {
            return .todaySuspended(reason: reason)
        }
        // "Tomorrow" in ET calendar — add 1 day to ET midnight of today
        let tomorrow = now.startOfDayET(offsetDays: 1)
        if let reason = reasonForSuspension(tomorrow) {
            return .tomorrowSuspended(reason: reason)
        }
        return .aspInEffect
    }
}

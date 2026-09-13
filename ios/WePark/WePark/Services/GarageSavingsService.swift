//
//  GarageSavingsService.swift
//  WePark
//
//  Community 2.0 S13c — garage-savings stat.
//  Spec: docs/design/community-2.0-final-parity-audit.md §3, Option A (Kevin's accepted
//  derivation — replaces the cut, unverifiable "tickets dodged this month" idea).
//
//  The problem this solves: `CrewFeedSection`'s S9 header comment documents that "tickets
//  dodged" was deliberately never built — there's no honest way to know a ticket that WOULD
//  have been issued but wasn't. This stat is the honest replacement: it accrues real elapsed
//  parked TIME (a fact the app already has) into a dollar-equivalent using a rate this app
//  already cites elsewhere (`MoneyMathConstants.garageMonthlyManhattanLow`, the Parking 101
//  guide's own "$500/mo" figure), rather than fabricating a "would have happened" number.
//
//  Accrual trigger: `ContentView`'s "I left — clear pin" action
//  (`.parkedCarDetail` → `onClearPin`) — the moment a completed parking session's duration
//  becomes knowable (`now - parkedCar.parkedAt`).
//
//  Storage tier: `UserDefaults.standard`, same tier as `ReminderOffsets`/`hasEverParkedKey`
//  (`Services/ParkPinService.swift`) — device-local, no schema change, no account needed,
//  consistent with this product's zero-friction, no-login model.
//
//  Month-boundary reset: this codebase's existing ET-arithmetic convention
//  (`Calendar.easternTime.dateComponents(...)`, `Services/Date+ET.swift`) — NEVER
//  `Calendar.current`, since a user's device may be in any time zone and this app's "month"
//  is always an America/New_York calendar month.
//
//  No import SwiftUI — pure service (QA invariant, matches ReminderOffsets/ParkPinService).
//

import Foundation

// MARK: - GarageSavingsService

/// Device-local accrual + read of the "$X back in your pocket this month" running total.
///
/// Usage:
///   let service = GarageSavingsService()  // uses UserDefaults.standard
///   let total = service.currentMonthTotal()
///   // ... on "I left — clear pin": ...
///   service.recordSessionEnded(parkedAt: car.parkedAt)
struct GarageSavingsService {

    private let defaults: UserDefaults

    /// UserDefaults key for the running-total dollar amount accrued so far in the CURRENT ET
    /// calendar month. A plain `Double` (not currency-formatted) — formatting happens at
    /// display time (`GarageSavingsCopy.summary(total:)`).
    private static let totalKey = "wepark_garage_savings_total"

    /// UserDefaults key for the "yyyy-MM" ET-month string the persisted total belongs to.
    /// When this doesn't match the CURRENT ET month at read/accrue time, the total resets to
    /// 0 before anything is added or returned — a read-time/write-time reset (no background
    /// timer needed), matching this codebase's general "derive fresh from the clock" style
    /// (e.g. `ASPSuspensionService.suspensionState(at:)`).
    private static let monthKey = "wepark_garage_savings_month"

    /// Designated init — accepts any `UserDefaults` instance so tests can inject an
    /// ephemeral suite instead of polluting `UserDefaults.standard` (mirrors
    /// `ParkingGuidePromptGate`'s / `ReminderOffsets`'s own test-injection convention).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The running total accrued so far in the CURRENT ET calendar month, as of `now`.
    /// Returns 0 if the persisted total belongs to a prior ET month (the month rolled over
    /// since the last accrual) — never a stale carry-over total from last month.
    func currentMonthTotal(now: Date = .nowET) -> Double {
        guard defaults.string(forKey: Self.monthKey) == Self.etMonthKey(for: now) else { return 0 }
        return defaults.double(forKey: Self.totalKey)
    }

    /// Records a completed parking session ending at `now` (the "I left — clear pin" moment)
    /// and accrues its dollar-equivalent (`duration in hours × garageSavingsHourlyRate`) into
    /// the running total, resetting first if the persisted total belongs to a prior ET month.
    ///
    /// `parkedAt` in the future (clock skew, or a malformed car) clamps to a zero-duration,
    /// zero-dollar accrual rather than subtracting from the total.
    ///
    /// - Returns: the new running total, so a caller can display it immediately without a
    ///   second read.
    @discardableResult
    func recordSessionEnded(parkedAt: Date, now: Date = .nowET) -> Double {
        let hours = max(0, now.timeIntervalSince(parkedAt)) / 3600
        let delta = hours * MoneyMathConstants.garageSavingsHourlyRate

        let currentMonth = Self.etMonthKey(for: now)
        let baseline = (defaults.string(forKey: Self.monthKey) == currentMonth)
            ? defaults.double(forKey: Self.totalKey)
            : 0

        let newTotal = baseline + delta
        defaults.set(newTotal, forKey: Self.totalKey)
        defaults.set(currentMonth, forKey: Self.monthKey)
        return newTotal
    }

    /// "yyyy-MM" in America/New_York time — a simple, string-comparable month key so a month
    /// boundary is detected without any manual day-counting. Uses `Calendar.easternTime`
    /// (this codebase's blessed ET-arithmetic primitive, `Services/Date+ET.swift`) — NOT
    /// `Calendar.current`, which would tie "month" to the device's time zone rather than
    /// NYC's.
    ///
    /// `nonisolated` explicit (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — a pure,
    /// stateless function like this must stay callable from a plain synchronous `XCTestCase`
    /// without `await`, matching `ZoneGeometry.box(for:in:)`'s own precedent.
    nonisolated static func etMonthKey(for date: Date) -> String {
        let comps = Calendar.easternTime.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
    }
}

// MARK: - GarageSavingsCopy

/// The garage-savings stat's display copy, kept in exactly ONE place so a future wording
/// change (Kevin may still adjust at his gate, per this session's dispatch instruction) is a
/// one-line diff rather than a grep across every consumer.
enum GarageSavingsCopy {
    /// "$X back in your pocket this month — no garage needed" — audit copy option #3
    /// (`docs/design/community-2.0-final-parity-audit.md` §3): closest in tone to the
    /// Parking 101 guide's own "money back in your pocket" framing, reusing established
    /// voice rather than inventing a new one. Rounds to the nearest whole dollar — a stat
    /// this casual doesn't need cents.
    ///
    /// `nonisolated` explicit (build's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — pure,
    /// no actor state, same reasoning as `GarageSavingsService.etMonthKey(for:)` above.
    nonisolated static func summary(total: Double) -> String {
        "$\(Int(total.rounded())) back in your pocket this month \u{2014} no garage needed"
    }
}

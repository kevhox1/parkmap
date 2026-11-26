//
//  WPPhase6bLogic.swift
//  WePark
//
//  Stoop Phase 6b: pure copy and logic for Plan a Trip (round-2 B14) and the blocking / empty /
//  limit states (B18). No SwiftUI, no flags: the views in `WPTripPlannerV2.swift` and
//  `WPStateScreens.swift` only draw what these return.
//
//  Trip rules kept from `TripPlanning`: the verdict is the SAME one free rule as every live goal
//  (`ParkingRulesEngine.isFree(from: arrival, until: departure)`); validation, the 7 day cap, the
//  quick picks and the caveat all come from there. This file only words them for the new screens.
//

import Foundation

// MARK: - Trip copy

nonisolated enum WPTripCopy {
    static let title = "Plan a trip"
    static let sub = "See where you can leave your car for a whole visit."
    static let quickPicksLabel = "QUICK PICKS"
    static let arrive = "Arrive"
    static let leave = "Leave"
    static let showMap = "Show trip map"
    static let planNote = "Up to 7 days. This is a plan, not the live map."
    /// The "rules can change" caveat, always visible on the planner and on the trip map card.
    static let caveat = TripPlanning.caveat
    static let mapHeadline = "Green curbs are free for your whole trip, until"
    static let changeDates = "Change dates"
    static let backToLive = "Back to live map"
    static let noGreenLine = "No curbs on this map are marked free for the whole trip. Check the signs on the street."

    /// Title and detail of an inline problem box. `field` says which date row is drawn in red.
    struct Problem: Equatable {
        enum Field: Equatable { case arrive, leave }
        let title: String
        let detail: String
        let field: Field
    }

    static func problem(for validation: TripPlanValidation) -> Problem? {
        switch validation {
        case .valid:
            return nil
        case .departureNotAfterArrival:
            return Problem(title: "Leave has to be after Arrive", detail: "Pick a later day or time for Leave.", field: .leave)
        case .arrivalInPast:
            return Problem(title: "Arrive can't be in the past", detail: "To park right now, use the live map.", field: .arrive)
        case .tooLong:
            return Problem(title: "A trip can be up to 7 days", detail: "Pick a Leave within 7 days of Arrive.", field: .leave)
        }
    }

    // MARK: Quick picks

    static func quickPickTitle(_ pick: TripQuickPick) -> String {
        switch pick {
        case .todayEvening: return "Today"
        case .tomorrow: return "Tomorrow"
        case .thisWeekend: return "This weekend"
        }
    }

    /// The window the pick would set, in the round-2 wording ("5 to 10 PM"). When the pick has
    /// already passed (`plan == nil`) it says so instead of showing a stale window.
    static func quickPickRange(_ pick: TripQuickPick, plan: TripPlan?, now: Date) -> String {
        guard let plan else { return "Already passed" }
        return rangeLabel(plan, now: now)
    }

    // MARK: Labels

    /// "5 to 10 PM", "9 AM to 6 PM", "Sat 10 AM to Sun 6 PM".
    static func rangeLabel(_ plan: TripPlan, now: Date) -> String {
        let cal = Calendar.easternTime
        if cal.isDate(plan.arrival, inSameDayAs: plan.departure) {
            let a = clock(plan.arrival), d = clock(plan.departure)
            // "5 to 10 PM": the meridiem is said once when both ends share it.
            if let aMer = meridiem(of: a), let dMer = meridiem(of: d), aMer == dMer {
                return nbsp("\(a.dropLast(aMer.count + 1)) to \(d)")
            }
            return nbsp("\(a) to \(d)")
        }
        return nbsp("\(weekday(plan.arrival)) \(clock(plan.arrival)) to \(weekday(plan.departure)) \(clock(plan.departure))")
    }

    /// The tag under "TRIP PLAN · NOT LIVE": "Sat 11/28 10 AM to Sun 11/29 6 PM". A date in another
    /// calendar year than `now` carries a two-digit year ("Sat 1/2/27").
    static func tagDates(_ plan: TripPlan, now: Date) -> String {
        nbsp("\(stamp(plan.arrival, now: now)) to \(stamp(plan.departure, now: now))")
    }

    /// "Sun 6 PM": the end of the window, the big line of the trip card.
    static func untilLabel(_ plan: TripPlan) -> String {
        nbsp("\(weekday(plan.departure)) \(clock(plan.departure))")
    }

    /// "From Sat 10 AM · 32 hours".
    static func fromLabel(_ plan: TripPlan) -> String {
        nbsp("From \(weekday(plan.arrival)) \(clock(plan.arrival)) \u{00B7} \(durationLabel(plan))")
    }

    /// "32 hours" under two days; "3 days" or "3 days 4 h" from two days up.
    static func durationLabel(_ plan: TripPlan) -> String {
        let hours = max(1, Int((plan.departure.timeIntervalSince(plan.arrival) / 3600).rounded()))
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24, rest = hours % 24
        return rest == 0 ? "\(days) days" : "\(days) days \(rest) h"
    }

    /// The Arrive / Leave row text ("Sat, Nov 28 \u{00B7} 10:00 AM").
    static func rowStamp(_ date: Date) -> String {
        let cal = Calendar.easternTime
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let h = c.hour ?? 0, m = c.minute ?? 0
        let h12 = h % 12 == 0 ? 12 : h % 12
        let minutes = m < 10 ? "0\(m)" : "\(m)"
        return nbsp("\(weekday(date)), \(months[max(0, (c.month ?? 1) - 1)]) \(c.day ?? 1) \u{00B7} \(h12):\(minutes) \(h < 12 ? "AM" : "PM")")
    }

    // MARK: Street-cleaning calendar

    /// "Holiday changes for 2027 aren't out yet" when the bundled calendar does not reach the plan.
    /// `nil` when it covers the whole plan.
    static func calendarNotice(_ plan: TripPlan, arrivalCovered: Bool, departureCovered: Bool) -> (title: String, detail: String)? {
        if arrivalCovered && departureCovered { return nil }
        let cal = Calendar.easternTime
        let year = cal.component(.year, from: departureCovered ? plan.arrival : plan.departure)
        return ("Holiday changes for \(year) aren't out yet", "This plan uses the posted signs only. Check again closer to your trip.")
    }

    // MARK: Formatting (Eastern time)

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func weekday(_ date: Date) -> String {
        weekdays[max(0, min(6, Calendar.easternTime.component(.weekday, from: date) - 1))]
    }

    /// "10 AM", "10:30 AM", or "midnight" (never "12 AM").
    private static func clock(_ date: Date) -> String {
        let c = Calendar.easternTime.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        if h == 0 && m == 0 { return "midnight" }
        let h12 = h % 12 == 0 ? 12 : h % 12
        let suffix = h < 12 ? "AM" : "PM"
        if m == 0 { return "\(h12) \(suffix)" }
        return "\(h12):\(m < 10 ? "0\(m)" : "\(m)") \(suffix)"
    }

    private static func meridiem(of clock: String) -> String? {
        if clock.hasSuffix("AM") { return "AM" }
        if clock.hasSuffix("PM") { return "PM" }
        return nil
    }

    private static func stamp(_ date: Date, now: Date) -> String {
        let cal = Calendar.easternTime
        let c = cal.dateComponents([.year, .month, .day], from: date)
        var md = "\(c.month ?? 1)/\(c.day ?? 1)"
        if c.year != cal.component(.year, from: now) { md += "/\(String(format: "%02d", (c.year ?? 0) % 100))" }
        return "\(weekday(date)) \(md) \(clock(date))"
    }

    /// A non-breaking space between a time and its AM/PM, so a narrow line wraps between words and
    /// never inside "10 AM".
    private static func nbsp(_ text: String) -> String {
        text.replacingOccurrences(of: " AM", with: "\u{00A0}AM").replacingOccurrences(of: " PM", with: "\u{00A0}PM")
    }
}

// MARK: - Trip screen gating

/// What the trip map shows. One place, so a test can pin "live actions are hidden while planning".
nonisolated enum WPTripChrome {
    /// While a plan shows there is no "you" dot, goals, Start driving, Park here, Report or Spot Pass.
    static func showsLiveControls(tripActive: Bool) -> Bool {
        TripModeGating.showsLiveActions(tripActive: tripActive)
    }

    /// The dashed frame and the "TRIP PLAN · NOT LIVE" tag draw only for a plan, and only in Stoop.
    static func showsPlanFrame(tripActive: Bool, stoop: Bool) -> Bool { tripActive && stoop }
}

// MARK: - Blocking, empty and limit state copy (B18)

nonisolated enum WPStateCopy {
    struct Screen: Equatable {
        var over: String?
        var title: String
        var sub: String
        var primary: String?
        var secondary: String?
    }

    /// B18.1. Drive mode only: the map and search still work without location.
    static let noLocation = Screen(
        over: nil,
        title: "Driving mode needs your location",
        sub: "WePark can't tell which curb is on your left or right without it. The map and search still work.",
        primary: "Open Settings",
        secondary: "Search an address instead"
    )

    /// B18.7. `place` is the neighborhood the phone is in, when known.
    static func outsideCoverage(place: String?, canSuggest: Bool) -> Screen {
        Screen(
            over: place.map { "You're in \($0)" },
            title: "WePark covers Manhattan for now",
            sub: "Tell us where you park and we'll use it to decide where to go next.",
            primary: canSuggest ? "Suggest this neighborhood" : nil,
            secondary: "Show Manhattan"
        )
    }

    /// B18.5. Saved-on-the-phone claim: the parked car and its reminders really are local.
    static let serverDown = Screen(
        over: nil,
        title: "WePark is having trouble",
        sub: "Our servers aren't answering. Your parked car and its reminders are saved on this phone and still work.",
        primary: "Try again",
        secondary: "Open My Car"
    )

    /// B18.8.
    static let account = Screen(
        over: nil,
        title: "We couldn't sign you in",
        sub: "Karma and Spot Pass need an account. The map, driving mode and reminders work without one.",
        primary: "Try again",
        secondary: "Continue without an account"
    )

    /// B18.9.
    static let noCar = Screen(
        over: "My car",
        title: "No parked car yet",
        sub: "When you park, tap Park here. Your spot, its end time and your reminders will be kept here.",
        primary: "Find parking",
        secondary: nil
    )
    static let noCarToken = "Your car token appears on the map once you've parked."

    /// B18.6: bottom card over an empty map.
    static let noCurbsTitle = "We couldn't load the curbs here"
    static let noCurbsBody = "Nothing is drawn, so nothing here means park or don't. Read the signs on the street."
    static let tryAgain = "Try again"

    /// Limit rows (B18.2 to B18.4): the dashed coral row above the thing it limits.
    struct Limit: Equatable {
        let message: String
        let fix: String
    }

    static func offline(asOf: String) -> Limit {
        Limit(message: "You're offline. This is what we knew at \(asOf).", fix: "Retry")
    }
    static let whileUsingOnly = Limit(message: "WePark can't notice when you drive off.", fix: "Settings")
    static let notificationsOff = Limit(message: "Notifications are off, so reminders can't reach you.", fix: "Turn on")
}

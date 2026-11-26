//
//  WPMapLogic.swift
//  WePark
//
//  Phase 2a (design system v0.1 main map): pure, unit-testable logic behind the flag-on map.
//  Nothing here reads UI state. Every time and every verdict comes from the existing engine
//  (`ParkingGoals`, `ParkingRulesEngine`); this file only formats and gates.
//
//  Product rules enforced here:
//    - Never show a spot that isn't a spot: a curb is base-map green only when the engine says it
//      is free for the WHOLE window AND the sign data is readable (`WPCurbVerdict`).
//    - Copy: "midnight", never "12 AM"; "For days" shows the real end date the ladder picked.
//

import Foundation

// MARK: - Curb verdict (base-map green gate)

enum WPCurbVerdict {

    /// True when the segment carries no readable sign data: the shared no-sign-data state
    /// (`Segment.hasNoSignData`: empty rules or the synthetic "NO DATA" rule, which `isFree`
    /// already treats as never free), or any rule the tile pipeline could not classify
    /// (`UNKNOWN`). Such a curb never draws green.
    ///
    /// The `UNKNOWN`-category part is a flag-on-only extra: `isFree` still ignores `UNKNOWN`
    /// rules for the live app (a separate data audit decides that), so only this gate refuses
    /// them.
    nonisolated static func hasUnreadableSigns(_ segment: Segment) -> Bool {
        segment.hasNoSignData || segment.rules.contains { $0.category == .unknown }
    }

    /// Non-goal fallback state (no window): the engine's current state, except that unreadable
    /// signs are `.unknown` (the synthetic NO DATA rule would otherwise read as "restricted").
    nonisolated static func currentState(segment: Segment, engine: ParkingRulesEngine, at now: Date) -> CurrentState {
        hasUnreadableSigns(segment) ? .unknown : engine.currentState(for: segment, at: now)
    }

    /// Base-map green: readable signs AND nothing restricts a private car anywhere in
    /// `[from, until]` (strict meter rule, same `isFree` every goal uses).
    nonisolated static func isParkable(
        segment: Segment,
        engine: ParkingRulesEngine,
        from: Date,
        until: Date
    ) -> Bool {
        guard !hasUnreadableSigns(segment) else { return false }
        return engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: false)
    }

    /// Detail-mode ("Show all sign details") classification of a curb for a goal window.
    /// Green still means free for the whole window. Everything else keeps the five-style
    /// vocabulary, derived from the engine's current-state answer.
    nonisolated static func detailTag(
        segment: Segment,
        engine: ParkingRulesEngine,
        from: Date,
        until: Date
    ) -> CurrentState {
        if hasUnreadableSigns(segment) { return .unknown }
        if engine.isFree(segment: segment, from: from, until: until, ignoringMeteredPayment: false) {
            return .freeComfortably
        }
        switch engine.currentState(for: segment, at: from) {
        case .restrictedNow: return .restrictedNow
        case .meteredActive: return .meteredActive
        case .unknown: return .unknown
        // Free right now, but something starts inside the window: "changes soon".
        case .freeComfortably, .freeButRestrictionSoon: return .freeButRestrictionSoon
        }
    }
}

// MARK: - Goal copy

enum WPGoalCopy {

    /// "7 AM", "1:11 AM", "midnight".
    nonisolated static func clock(_ date: Date) -> String {
        let cal = Calendar.easternTime
        let c = cal.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        if hour == 0 && minute == 0 { return "midnight" }
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "AM" : "PM"
        let body = minute == 0 ? "\(h12)" : "\(h12):" + (minute < 10 ? "0\(minute)" : "\(minute)")
        return "\(body)\u{00A0}\(suffix)"
    }

    nonisolated static func dayDiff(from: Date, to: Date) -> Int {
        let cal = Calendar.easternTime
        return cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to)).day ?? 0
    }

    /// "Wed 12/2".
    nonisolated static func weekdayDate(_ date: Date) -> String {
        ParkingGoals.weekdayDateLabel(for: date)
    }

    /// "Wed, Dec 2".
    nonisolated static func longDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = .easternTime
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE, MMM d"
        return fmt.string(from: date)
    }

    /// For days ends at an ET midnight; the last day that is fully clear is the day before it.
    nonisolated static func lastClearDay(forDaysEnd end: Date) -> Date {
        end.addingTimeInterval(-1)
    }

    /// Whole days the window spans (7, 3 or 1 for the 8 / 4 / 2 ladder).
    nonisolated static func spanDays(forDaysEnd end: Date, from now: Date) -> Int {
        max(1, dayDiff(from: now, to: end) - 1)
    }

    nonisolated static func dayWord(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// Large headline end time.
    nonisolated static func headlineEnd(goal: ParkingGoal, end: Date, now: Date) -> String {
        switch goal {
        case .parkAndForget:
            return longDate(lastClearDay(forDaysEnd: end))
        case .freeOvernight, .freeFewHours:
            let time = clock(end)
            let days = dayDiff(from: now, to: end)
            if days <= 0 { return time }
            if days == 1 { return time == "midnight" ? "midnight tonight" : "\(time) tomorrow" }
            return "\(weekdayDate(end)) \(time)"
        }
    }

    /// Tile sub-line: "until 1:11 AM", "until 7 AM", "until Wed 12/2".
    nonisolated static func tileUntil(goal: ParkingGoal, end: Date) -> String {
        switch goal {
        case .parkAndForget:
            return "until " + weekdayDate(lastClearDay(forDaysEnd: end))
        case .freeOvernight, .freeFewHours:
            return "until " + clock(end)
        }
    }

    /// "8 h 49 min from now", "3 h from now", "45 min from now".
    nonisolated static func countdown(goal: ParkingGoal, end: Date, now: Date) -> String {
        if goal == .parkAndForget {
            let n = spanDays(forDaysEnd: end, from: now)
            return "Until midnight, \(n == 1 ? "1 day" : "\(n) days") from now"
        }
        let minutes = max(1, Int((end.timeIntervalSince(now) / 60).rounded()))
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min from now" }
        if m == 0 { return "\(h) h from now" }
        return "\(h) h \(m) min from now"
    }

    /// Flat fact line under the headline (sparse / stepped-down / empty), using the real span.
    nonisolated static func guardLine(kind: EmptyMapGuardKind, forDaysEnd end: Date?, now: Date) -> String {
        let n = end.map { spanDays(forDaysEnd: $0, from: now) }
        switch kind {
        case .sparse:
            if let n { return "Only a few blocks nearby are clear for \(dayWord(n))." }
            return kind.bannerCopy
        case .steppedDown:
            if let n { return "Nothing nearby is clear for a full week. Showing curbs clear for \(dayWord(n))." }
            return kind.bannerCopy
        case .empty:
            return "No clear spots found very nearby. Try Overnight, or pan the map."
        }
    }

    nonisolated static func lead(detailMode: Bool, loading: Bool) -> String {
        if loading { return "Green curbs will be free from now until" }
        return detailMode ? "Solid green curbs are free from now until" : "Green curbs are free from now until"
    }

    nonisolated static func goalName(_ goal: ParkingGoal) -> String {
        switch goal {
        case .freeFewHours: return "A few hours"
        case .freeOvernight: return "Overnight"
        case .parkAndForget: return "For days"
        }
    }

    /// Order of the tiles, left to right.
    nonisolated static let tileOrder: [ParkingGoal] = [.freeFewHours, .freeOvernight, .parkAndForget]
}

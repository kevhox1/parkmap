//
//  WPForDaysUntil.swift
//  WePark
//
//  DT35-1 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR4): the For-days "Free until" picker.
//  Pure, unit-testable logic only. Nothing here reads UI state; every verdict comes from the
//  existing engine (`WPCurbVerdict.isParkable`), and the map keeps its single-target green loop:
//  the only new thing is WHICH end that loop is handed.
//
//  Product rules enforced here:
//    - The earliest end you can pick is the Overnight end, so green(For days) nests inside
//      green(Overnight). Anything earlier clamps up.
//    - The latest is midnight after day 8 (same top as the auto ladder).
//    - Never show a fake spot: if nothing nearby is clear until the picked time, the map is
//      coloured for the latest 30 minute step that still has a clear curb, and the copy says
//      so. Green is never coloured for a time other than the one shown.
//

import Foundation

// MARK: - Constants

/// Tunables for the picker (own enum, house style: `DriveSideConstants`).
nonisolated enum ForDaysUntilConstants {
    /// Grid step in minutes (wall clock, ET).
    static let stepMinutes = 30
    /// The range tops out at the start of this day offset ("midnight after day 8").
    static let lastDayOffset = 8
    /// Quick time chips, 24 h clock hours. "Midnight" is a separate chip.
    static let quickHours: [Int] = [7, 9, 12, 17]
    /// Below this fraction of the Overnight-end clear count, a fallback is called "thin".
    static let thinDensityThreshold: Double = 0.25
    /// UserDefaults key. Seconds since 1970 of the picked end; 0 or absent = Auto.
    static let defaultsKey = "wepark.forDaysUntil"
}

// MARK: - Grid + clamp

nonisolated enum ForDaysUntil {

    /// Earliest selectable end: the Overnight end (honours the morning-hour lever).
    static func minEnd(now: Date, morningHour: Int) -> Date {
        ParkingGoals.overnightEnd(from: now, morningHour: morningHour)
    }

    /// Latest selectable end: the start of day 8 ("midnight").
    static func maxEnd(now: Date) -> Date {
        now.startOfDayET(offsetDays: ForDaysUntilConstants.lastDayOffset)
    }

    /// Every selectable end, ascending, on the 30 minute wall-clock grid, from `minEnd` to
    /// `maxEnd` inclusive. DST: spring-forward's missing wall-clock slots are skipped (a slot
    /// that does not exist is not a slot); on fall-back day the repeated hour has a single
    /// entry per slot (the first occurrence).
    static func grid(now: Date, morningHour: Int) -> [Date] {
        let cal = Calendar.easternTime
        let lo = minEnd(now: now, morningHour: morningHour)
        let hi = maxEnd(now: now)
        guard lo < hi else { return [hi] }
        let slotsPerDay = 24 * 60 / ForDaysUntilConstants.stepMinutes
        var result: [Date] = []
        for dayOffset in 0...ForDaysUntilConstants.lastDayOffset {
            let dayStart = now.startOfDayET(offsetDays: dayOffset)
            for slot in 0..<slotsPerDay {
                if dayOffset == ForDaysUntilConstants.lastDayOffset && slot > 0 { break }
                let minutes = slot * ForDaysUntilConstants.stepMinutes
                let hour = minutes / 60
                let minute = minutes % 60
                let date: Date
                if slot == 0 {
                    date = dayStart
                } else {
                    guard let candidate = cal.date(
                        bySettingHour: hour, minute: minute, second: 0, of: dayStart
                    ) else { continue }
                    let parts = cal.dateComponents([.hour, .minute], from: candidate)
                    guard parts.hour == hour, parts.minute == minute else { continue }
                    date = candidate
                }
                if date >= lo && date <= hi && result.last != date { result.append(date) }
            }
        }
        if result.first != lo { result.insert(lo, at: 0) }
        return result
    }

    /// Floors `date` onto the grid. `clamped` is true when `date` was earlier than the Overnight
    /// end (the "Overnight already covers this" case). Later than the top clamps down silently.
    static func snap(_ date: Date, grid: [Date]) -> (date: Date, clamped: Bool) {
        guard let first = grid.first, let last = grid.last else { return (date, false) }
        if date < first { return (first, true) }
        if date >= last { return (last, false) }
        let floored = grid.last(where: { $0 <= date }) ?? first
        return (floored, false)
    }

    /// The neighbouring grid entry, or nil at the ends of the range.
    static func step(from date: Date, by delta: Int, grid: [Date]) -> Date? {
        guard !grid.isEmpty else { return nil }
        let index = grid.lastIndex(where: { $0 <= date }) ?? 0
        let target = index + delta
        guard grid.indices.contains(target) else { return nil }
        return grid[target]
    }

    /// True for an exact ET midnight. A midnight end belongs to the night before it.
    static func isMidnight(_ date: Date) -> Bool {
        let parts = Calendar.easternTime.dateComponents([.hour, .minute], from: date)
        return parts.hour == 0 && parts.minute == 0
    }

    /// Day chip index (0 = today ... 7) an end belongs to. A midnight end is the end of the day
    /// before it ("midnight Tuesday night" is Tuesday).
    static func dayIndex(of end: Date, now: Date) -> Int {
        let reference = isMidnight(end) ? end.addingTimeInterval(-1) : end
        return max(0, WPGoalCopy.dayDiff(from: now, to: reference))
    }

    /// The same time of day on another chip day, clamped to the range. Midnight stays midnight
    /// (the night of the new day).
    static func retarget(
        _ current: Date, toDay day: Int, now: Date, grid: [Date]
    ) -> (date: Date, clamped: Bool) {
        let cal = Calendar.easternTime
        let target: Date
        if isMidnight(current) {
            target = now.startOfDayET(offsetDays: day + 1)
        } else {
            let parts = cal.dateComponents([.hour, .minute], from: current)
            target = cal.date(
                bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0,
                of: now.startOfDayET(offsetDays: day)
            ) ?? now.startOfDayET(offsetDays: day)
        }
        return snap(target, grid: grid)
    }

    /// A quick time on a chip day. `hour == nil` is midnight (the night of that day).
    static func quick(
        hour: Int?, onDay day: Int, now: Date, grid: [Date]
    ) -> (date: Date, clamped: Bool) {
        let cal = Calendar.easternTime
        let target: Date
        if let hour {
            target = cal.date(
                bySettingHour: hour, minute: 0, second: 0, of: now.startOfDayET(offsetDays: day)
            ) ?? now.startOfDayET(offsetDays: day)
        } else {
            target = now.startOfDayET(offsetDays: day + 1)
        }
        return snap(target, grid: grid)
    }

    /// A stored pick, or nil (Auto) when there is none or it is at or before the current minimum.
    /// Run on launch and on foreground so a stale "Monday 5 PM" never lingers.
    static func restoredPick(stored: TimeInterval, now: Date, morningHour: Int) -> Date? {
        guard stored > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stored)
        return date > minEnd(now: now, morningHour: morningHour) ? date : nil
    }
}

// MARK: - Fallback resolution

/// What kind of banner a manual pick needs.
nonisolated enum ForDaysFallbackKind: Equatable {
    /// Something nearby is clear, but not until the requested time: the map shows the best end.
    case fallback
    /// Not even the Overnight end has a clear curb nearby.
    case empty

    /// Maps onto the existing banner kind so chip / icon styling is reused (no new case).
    var guardKind: EmptyMapGuardKind {
        switch self {
        case .fallback: return .steppedDown
        case .empty: return .empty
        }
    }
}

/// The resolved manual For-days window. `effective` is the only end the map is coloured for.
nonisolated struct WPForDaysState: Equatable {
    var requested: Date
    /// T*: equals `requested` unless `isFallback`; equals the Overnight end when `.empty`
    /// (display only, nothing is coloured green then).
    var effective: Date
    var isFallback: Bool
    /// Segments clear from now until `effective` (0 when `.empty`).
    var greenCount: Int
    /// nil when the request itself has clear curbs (no banner).
    var kind: ForDaysFallbackKind?
    /// Fallback with very few curbs: adds "Only a few curbs." to the banner.
    var thin: Bool

    var guardKind: EmptyMapGuardKind? { kind?.guardKind }
}

nonisolated enum ForDaysFallback {

    /// Segments clear from `from` until `until` under the strict base-map predicate.
    static func clearCount(
        segments: [Segment], engine: ParkingRulesEngine, from: Date, until: Date
    ) -> Int {
        segments.reduce(0) { total, segment in
            guard segment.coordinates.count >= 2 else { return total }
            return WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: until)
                ? total + 1 : total
        }
    }

    /// True when at least one segment is clear. Early exit; used by the search.
    static func anyClear(
        segments: [Segment], engine: ParkingRulesEngine, from: Date, until: Date
    ) -> Bool {
        segments.contains { segment in
            segment.coordinates.count >= 2
                && WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: until)
        }
    }

    /// Finds the effective end `T*`.
    ///
    /// Clear-until is monotonic (clear until T implies clear until any earlier time), so the
    /// clear count never rises as the end moves later, and a binary search over the grid finds
    /// the latest step that still has a clear curb. `grid[0]` is the Overnight end, so the result
    /// is never earlier than it (nesting), and never later than `requested`.
    static func resolve(
        requested: Date,
        grid: [Date],
        anyClear: (Date) -> Bool,
        count: (Date) -> Int
    ) -> WPForDaysState {
        guard let minEnd = grid.first else {
            return WPForDaysState(
                requested: requested, effective: requested, isFallback: false,
                greenCount: 0, kind: .empty, thin: false
            )
        }
        let requestedIndex = grid.lastIndex(where: { $0 <= requested }) ?? 0
        let wanted = grid[requestedIndex]

        if anyClear(wanted) {
            return WPForDaysState(
                requested: wanted, effective: wanted, isFallback: false,
                greenCount: count(wanted), kind: nil, thin: false
            )
        }
        // Nothing is clear until the request. Even the Overnight end?
        guard requestedIndex > 0, anyClear(minEnd) else {
            return WPForDaysState(
                requested: wanted, effective: minEnd, isFallback: false,
                greenCount: 0, kind: .empty, thin: false
            )
        }
        // grid[lo] has a clear curb, grid[hi] has none.
        var lo = 0
        var hi = requestedIndex
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if anyClear(grid[mid]) { lo = mid } else { hi = mid }
        }
        let best = grid[lo]
        let bestCount = count(best)
        let minCount = lo == 0 ? bestCount : count(minEnd)
        let thin = minCount > 0
            && Double(bestCount) < ForDaysUntilConstants.thinDensityThreshold * Double(minCount)
        return WPForDaysState(
            requested: wanted, effective: best, isFallback: true,
            greenCount: bestCount, kind: .fallback, thin: thin
        )
    }
}

// MARK: - Copy

nonisolated enum WPForDaysCopy {

    private static func format(_ date: Date, _ pattern: String) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = .easternTime
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    /// "Tue 9 AM", or "midnight Tue night" (a midnight end is the end of the night before).
    static func stamp(_ end: Date) -> String {
        if ForDaysUntil.isMidnight(end) {
            return "midnight " + format(end.addingTimeInterval(-1), "EEE") + " night"
        }
        return format(end, "EEE") + " " + WPGoalCopy.clock(end)
    }

    /// VoiceOver form: "Tuesday 9 AM", "midnight Tuesday night".
    static func spokenStamp(_ end: Date) -> String {
        if ForDaysUntil.isMidnight(end) {
            return "midnight " + format(end.addingTimeInterval(-1), "EEEE") + " night"
        }
        return format(end, "EEEE") + " " + WPGoalCopy.clock(end)
    }

    /// Headline end: "Tue 12/1, 9 AM". Midnight reads "midnight Tue night".
    static func headline(end: Date) -> String {
        if ForDaysUntil.isMidnight(end) { return stamp(end) }
        return WPGoalCopy.weekdayDate(end) + ", " + WPGoalCopy.clock(end)
    }

    /// Tile sub-line: "until Tue 9 AM".
    static func tile(end: Date) -> String { "until " + stamp(end) }

    /// "1 day 4 h from now", "2 days from now"; under a day it reads like the other goals.
    static func countdown(end: Date, now: Date) -> String {
        let totalMinutes = max(1, Int((end.timeIntervalSince(now) / 60).rounded()))
        if totalMinutes < 24 * 60 {
            return WPGoalCopy.countdown(goal: .freeOvernight, end: end, now: now)
        }
        var days = totalMinutes / (24 * 60)
        var hours = Int((Double(totalMinutes % (24 * 60)) / 60).rounded())
        if hours == 24 { days += 1; hours = 0 }
        let dayText = days == 1 ? "1 day" : "\(days) days"
        return hours == 0 ? "\(dayText) from now" : "\(dayText) \(hours) h from now"
    }

    // MARK: Banner

    static let clampNote = "Overnight already covers this. Use Overnight for earlier."
    static let emptyDetail = "No clear curbs found very nearby. Try Overnight, or pan the map."
    static let thinSuffix = " Only a few curbs."

    static func bannerTitle(requested: Date) -> String {
        "Nothing nearby is free until \(stamp(requested))."
    }

    static func bannerDetail(_ state: WPForDaysState) -> String {
        switch state.kind {
        case .fallback:
            return "Best nearby: free until \(stamp(state.effective))." + (state.thin ? thinSuffix : "")
        case .empty:
            return emptyDetail
        case nil:
            return ""
        }
    }

    /// One VoiceOver sentence for the whole banner.
    static func bannerSpoken(_ state: WPForDaysState) -> String {
        let title = "Nothing nearby is free until \(spokenStamp(state.requested))."
        switch state.kind {
        case .fallback:
            return title + " Best nearby: free until \(spokenStamp(state.effective))."
                + (state.thin ? thinSuffix : "")
        case .empty:
            return title + " " + emptyDetail
        case nil:
            return ""
        }
    }

    /// Short chip phrase (complete, never clipped).
    static func chip(_ state: WPForDaysState) -> String? {
        switch state.kind {
        case .fallback: return "Best nearby: until \(stamp(state.effective))"
        case .empty: return "No clear curbs nearby"
        case nil: return nil
        }
    }

    static func announcement(effective: Date) -> String {
        "Best nearby is now free until \(spokenStamp(effective))"
    }

    // MARK: Picker labels

    static let autoValue = "Auto"

    static func requestRowLabel(isFallback: Bool) -> String {
        isFallback ? "You asked for:" : "Free until:"
    }

    /// Day chip title: "Today", "Tomorrow", then "Wed", "Thu"...
    static func dayTitle(offset: Int, now: Date) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            return format(now.startOfDayET(offsetDays: offset).addingTimeInterval(12 * 3600), "EEE")
        }
    }

    /// Quick chip title: "7 AM", "12 PM", "Midnight".
    static func quickTitle(hour: Int?) -> String {
        guard let hour else { return "Midnight" }
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12)\u{00A0}\(hour < 12 ? "AM" : "PM")"
    }
}

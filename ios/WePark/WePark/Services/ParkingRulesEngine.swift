//
//  ParkingRulesEngine.swift
//  WePark
//
//  Swift port of the NYC parking rules logic from index.html.
//  The output contract is byte-identical label strings to the PWA for the same inputs.
//
//  Port map (JS function → Swift method):
//    actionableSafetyLabel(seg)           → safetyLabel(for:at:)         [index.html:5457]
//    computeNextRestrictionHours(seg)     → nextRestriction(for:at:)     [index.html:5315]
//    computeHoursUntilASP(cat,rule,...)   → computeHoursUntilASP(...)    [index.html:3911]
//    computeHoursUntilActive(rule,...)    → computeHoursUntilActive(...) [index.html:3809]
//    meteredStatusLabel(seg)              → meteredStatus(for:at:)       [index.html:5378]
//    mostRestrictiveCategory(rules)       → dominantCategory(rules:)     [index.html:2141]
//    getNextRestrictionTimeLabel(hours)   → nextRestrictionTimeLabel(...)[index.html:5429]
//    isScheduleActiveAt(rule,day,min)     → isScheduleActive(rule:...)   [index.html:1705]
//
//  All time math uses Calendar.easternTime / TimeZone.easternTime.
//  Never use Calendar.current — the device may be in any time zone.
//
//  R4 (docs/ios-mvp-spec.md §7): notifications must use absolute Unix time computed
//  via the ET calendar so they fire at the correct NYC moment regardless of where
//  the device is.
//

import Foundation
import SwiftUI

// MARK: - ParkingRulesEngine

final class ParkingRulesEngine {

    // MARK: - Dependencies

    private let aspService: ASPSuspensionService

    // MARK: - Constants

    /// Threshold for "restriction coming soon" (Option B dynamic state color).
    /// A block whose next restriction starts within this window shows orange.
    /// Spec §3.7 / palette doc §2.1: lowered from 24h to 6h (W4.5) — serves the
    /// short-stay visitor as the primary map-color persona. See docs/ios-color-threshold-spec.md.
    private static let nearFutureWindow: TimeInterval = 6 * 3600   // 6 hours

    // MARK: - Init

    init(aspService: ASPSuspensionService = ASPSuspensionService()) {
        self.aspService = aspService
    }

    // MARK: - Public API: label strings

    /// Driver-facing parking status.
    /// Port of actionableSafetyLabel(seg) at index.html:5457.
    ///
    /// Output examples (byte-identical to PWA for same inputs):
    ///   "Free until Thursday 9:30 AM"
    ///   "No parking"
    ///   "No standing"
    ///   "No parking (truck loading)"
    ///   "Restricted"
    ///   "No parking (ASP Mon/Thu)"
    ///   "paid until 7pm"          ← metered active (stripped from "Metered (paid until 7pm)")
    ///   "free until 9am"          ← metered, currently free
    ///   "Free"                    ← no restrictions at all
    ///   "No data"                 ← empty rules array
    func safetyLabel(for segment: Segment, at now: Date = .nowET) -> SafetyLabel {
        let rules = segment.rules
        guard !rules.isEmpty else {
            return SafetyLabel(text: "No data", severity: .unknown)
        }

        let restriction = nextRestriction(for: segment, at: now)
        let dom = segment.dominantCategory ?? dominantCategory(rules: rules)

        // Active restriction right now → red
        if restriction.isActiveNow {
            switch restriction.category {
            case .noStanding:
                return SafetyLabel(text: "No standing", severity: .restricted)
            case .noParking:
                return SafetyLabel(text: "No parking", severity: .restricted)
            case .truckLoading:
                return SafetyLabel(text: "No parking (truck loading)", severity: .restricted)
            case .special:
                return SafetyLabel(text: "Restricted", severity: .restricted)
            case let cat where cat?.isASP == true:
                // "No parking (ASP Mon/Thu)" — matches JS line 5472-5473
                let label = cat?.label ?? restriction.label ?? "ASP"
                return SafetyLabel(text: "No parking (\(label))", severity: .restricted)
            default:
                return SafetyLabel(text: "Restricted", severity: .restricted)
            }
        }

        // Upcoming ASP or NO_PARKING / TRUCK_LOADING restriction → "Free until <when>"
        if restriction.hours < 168 {
            if let cat = restriction.category, cat.isASP {
                let timeLabel = nextRestrictionTimeLabel(hours: restriction.hours, now: now)
                return SafetyLabel(text: "Free until \(timeLabel)", severity: .free)
            }
            if restriction.category == .noParking || restriction.category == .truckLoading {
                let timeLabel = nextRestrictionTimeLabel(hours: restriction.hours, now: now)
                return SafetyLabel(text: "Free until \(timeLabel)", severity: .free)
            }
        }

        // Metered block — use meteredStatus which formats "paid until 7pm" / "free until 9am"
        // JS checks: if (dom === 'METERED' || rules.some(r => r.category === 'METERED'))
        if dom == .metered || rules.contains(where: { $0.category == .metered }) {
            let lbl = meteredStatus(for: segment, at: now)
            // lbl is like "Metered (paid until 7pm)" or "Metered (free until 9am)"
            // Strip "Metered (" prefix and ")" suffix to get the inner part — matches JS:
            //   lbl.replace(/^Metered \(|\)$/g, '')
            let stripped = stripMeteredWrapper(lbl)
            let severity: SafetyLabel.Severity = lbl.localizedCaseInsensitiveContains("paid until") ? .metered : .free
            return SafetyLabel(text: stripped, severity: severity)
        }

        // No upcoming restriction at all
        return SafetyLabel(text: "Free", severity: .free)
    }

    /// Hours until the next parking restriction, with metadata.
    /// Port of computeNextRestrictionHours(seg) at index.html:5315.
    ///
    /// Returns hours == 0 when a restriction is active right now.
    /// Returns hours == 168 when no restriction is found (sentinel, same as JS).
    /// Skips METERED rules ("not a move-your-car restriction").
    func nextRestriction(for segment: Segment, at now: Date = .nowET) -> NextRestriction {
        let rules = segment.rules
        guard !rules.isEmpty else {
            return NextRestriction(hours: 168, label: "No restrictions", category: nil, rule: nil)
        }

        let dayOfWeek = now.dayOfWeekET
        let minuteOfDay = now.minuteOfDayET

        var soonestHours: Double = 168
        var soonestLabel: String? = "No restrictions"
        var soonestCategory: Category? = nil
        var soonestRule: ParkingRule? = nil

        for rule in rules {
            let cat = rule.category

            // NO_STANDING and SPECIAL: if active right now, return immediately.
            // Port of JS lines 5332-5336.
            if cat == .noStanding || cat == .special {
                if rule.anytime || isScheduleActive(rule: rule, dayOfWeek: dayOfWeek, minuteOfDay: minuteOfDay) {
                    let label = cat == .noStanding
                        ? "No standing zone (active now)"
                        : "Special restriction (active now)"
                    return NextRestriction(hours: 0, label: label, category: cat, rule: rule)
                }
            }

            // NO_PARKING and TRUCK_LOADING: check active now, then compute hours until.
            // Port of JS lines 5338-5349.
            if cat == .noParking || cat == .truckLoading {
                if isScheduleActive(rule: rule, dayOfWeek: dayOfWeek, minuteOfDay: minuteOfDay) {
                    let label = cat == .noParking ? "No parking active now" : "Truck loading active now"
                    return NextRestriction(hours: 0, label: label, category: cat, rule: rule)
                }
                let h = computeHoursUntilActive(rule: rule, currentDay: dayOfWeek, currentMinutes: minuteOfDay)
                if h < soonestHours {
                    soonestHours = h
                    soonestLabel = cat == .noParking ? "No Parking" : "Truck Loading"
                    soonestCategory = cat
                    soonestRule = rule
                }
            }

            // ASP categories: check if active now, then walk 14 days.
            // Port of JS lines 5351-5363.
            if cat.isASP {
                let isAspDay = cat.isASPDay(dayOfWeek)
                    && (rule.days.isEmpty || rule.days.contains(dayOfWeek))
                if isAspDay
                    && isScheduleActive(rule: rule, dayOfWeek: dayOfWeek, minuteOfDay: minuteOfDay)
                    && !aspService.isSuspended(now) {
                    let label = "\(cat.label) active now"
                    return NextRestriction(hours: 0, label: label, category: cat, rule: rule)
                }
                let h = computeHoursUntilASP(category: cat, rule: rule, currentDay: dayOfWeek, currentMinutes: minuteOfDay, from: now)
                if h < soonestHours {
                    soonestHours = h
                    soonestLabel = cat.label
                    soonestCategory = cat
                    soonestRule = rule
                }
            }

            // METERED: skip (not a move-your-car restriction) — matches JS line 5365-5368.
            if cat == .metered { continue }
        }

        return NextRestriction(hours: soonestHours, label: soonestLabel, category: soonestCategory, rule: soonestRule)
    }

    /// Human-readable metered status.
    /// Port of meteredStatusLabel(seg) at index.html:5378.
    ///
    /// Returns strings like:
    ///   "Metered (paid until 7pm)"
    ///   "Metered (free until 9am)"
    ///   "Metered (free for 2d)"
    ///   "Metered (free)"
    ///   "Metered"  ← no metered rules found
    func meteredStatus(for segment: Segment, at now: Date = .nowET) -> String {
        let meterRules = segment.rules.filter { $0.category == .metered }
        guard !meterRules.isEmpty else { return "Metered" }

        let dow = now.dayOfWeekET
        let minute = now.minuteOfDayET

        // Active right now? Check each metered rule's time ranges.
        // Port of JS lines 5391-5395.
        for rule in meterRules {
            if !rule.days.isEmpty && !rule.days.contains(dow) { continue }
            for tr in rule.timeRanges {
                if minute >= tr.start && minute <= tr.end {
                    return "Metered (paid until \(formatMinutes(tr.end)))"
                }
            }
        }

        // Find next activation today or later this week.
        // Port of JS lines 5398-5413.
        var bestMinutes = Int.max
        outer: for dayOff in 0..<7 {
            let d = (dow + dayOff) % 7
            for rule in meterRules {
                if !rule.days.isEmpty && !rule.days.contains(d) { continue }
                for tr in rule.timeRanges {
                    let minutesUntil: Int
                    if dayOff == 0 {
                        // Same day: only consider start times in the future
                        guard tr.start > minute else { continue }
                        minutesUntil = tr.start - minute
                    } else {
                        // Future day: minutes to midnight + full days + start
                        minutesUntil = (1440 - minute) + (dayOff - 1) * 1440 + tr.start
                    }
                    if minutesUntil < bestMinutes {
                        bestMinutes = minutesUntil
                    }
                }
            }
            // JS breaks out of the outer loop once it finds any match on this day offset.
            // We replicate: if we found something this dayOff, stop checking later days.
            if bestMinutes != Int.max { break outer }
        }

        if bestMinutes == Int.max { return "Metered (free)" }
        if bestMinutes < 1440 {
            let nextStart = (minute + bestMinutes) % 1440
            return "Metered (free until \(formatMinutes(nextStart)))"
        }
        let days = bestMinutes / 1440
        return "Metered (free for \(days)d)"
    }

    /// Most-restrictive category across a rule set.
    /// Port of mostRestrictiveCategory(ruleSet) at index.html:2141.
    /// Lower priority number = more restrictive.
    func dominantCategory(rules: [ParkingRule]) -> Category {
        guard !rules.isEmpty else { return .unknown }
        var best: Category = .unknown
        var bestPriority = 999
        for rule in rules {
            let cat = rule.category
            if cat.priority < bestPriority {
                bestPriority = cat.priority
                best = cat
            }
        }
        return best
    }

    // MARK: - Public API: Option B dynamic state color

    /// Classifies the segment's current parking state for dynamic color rendering.
    /// This is the core of Option B (spec §3.7 / palette doc §2.1).
    ///
    /// Classification logic:
    ///   1. If a restriction is active right now → .restrictedNow
    ///   2. If a restriction starts within nearFutureWindow (6h) → .freeButRestrictionSoon
    ///   3. If the block is metered and currently in paid hours → .meteredActive
    ///   4. If free with no imminent restriction → .freeComfortably
    ///   5. Unknown / no rules → .unknown
    func currentState(for segment: Segment, at now: Date = .nowET) -> CurrentState {
        let rules = segment.rules
        guard !rules.isEmpty else { return .unknown }

        let restriction = nextRestriction(for: segment, at: now)

        // Active restriction → red
        if restriction.isActiveNow { return .restrictedNow }

        // Upcoming restriction within nearFutureWindow → orange
        // Only non-metered restrictions count for the "soon" warning.
        // (Metered gets its own color from step 3 below.)
        if restriction.hours < ParkingRulesEngine.nearFutureWindow / 3600.0 {
            // If the only "soonest" category is a non-metered restriction, show orange.
            if let cat = restriction.category, cat != .metered {
                return .freeButRestrictionSoon
            }
        }

        // Metered active right now → amber-yellow
        let dom = segment.dominantCategory ?? dominantCategory(rules: rules)
        if dom == .metered || rules.contains(where: { $0.category == .metered }) {
            let dayOfWeek = now.dayOfWeekET
            let minuteOfDay = now.minuteOfDayET
            let meterRules = rules.filter { $0.category == .metered }
            let isMeteredNow = meterRules.contains { rule in
                if !rule.days.isEmpty && !rule.days.contains(dayOfWeek) { return false }
                return rule.timeRanges.contains { tr in
                    minuteOfDay >= tr.start && minuteOfDay <= tr.end
                }
            }
            if isMeteredNow { return .meteredActive }
        }

        // Free comfortably — either FREE category, or no restriction within 6h
        return .freeComfortably
    }

    /// Convenience: returns the SwiftUI color for the segment's current state.
    /// Port of the pseudocode in palette doc §2.2.
    func currentStateColor(for segment: Segment, at now: Date = .nowET) -> Color {
        currentState(for: segment, at: now).swiftUIColor
    }

    /// Convenience check: is the metered segment currently in paid hours?
    /// Used by ContentView to set lineWidth: 4 for metered segments (palette doc §2.3).
    func isMeteredActive(for segment: Segment, at now: Date = .nowET) -> Bool {
        currentState(for: segment, at: now) == .meteredActive
    }

    // MARK: - Private: schedule active check

    /// Returns true if the rule is active at the given day-of-week / minute-of-day.
    /// Port of isScheduleActiveAt(schedule, dayOfWeek, minuteOfDay) at index.html:1705.
    ///
    /// Logic:
    ///   - anytime == true  → always active
    ///   - day not in rule.days → not active
    ///   - timeRanges empty → active all day on matching days
    ///   - otherwise: check each time range
    func isScheduleActive(rule: ParkingRule, dayOfWeek: Int, minuteOfDay: Int) -> Bool {
        if rule.anytime { return true }
        guard !rule.days.isEmpty else { return false }
        if !rule.days.contains(dayOfWeek) { return false }
        if rule.timeRanges.isEmpty { return true }

        return rule.timeRanges.contains { tr in
            if tr.start < tr.end {
                return minuteOfDay >= tr.start && minuteOfDay < tr.end
            } else {
                // Overnight range wraps midnight: e.g., start=1380 (11pm), end=60 (1am)
                return minuteOfDay >= tr.start || minuteOfDay < tr.end
            }
        }
    }

    // MARK: - Private: hours-until helpers

    /// Computes hours until the next activation of a non-ASP rule (NO_PARKING, TRUCK_LOADING).
    /// Port of computeHoursUntilActive(rule, currentDay, currentMinutes) at index.html:3809.
    ///
    /// Walks up to 8 days forward (covers a full week + 1 guard), returns 168 if never found.
    private func computeHoursUntilActive(rule: ParkingRule, currentDay: Int, currentMinutes: Int) -> Double {
        if rule.anytime { return 0 }
        guard !rule.days.isEmpty else { return 168 }

        if isScheduleActive(rule: rule, dayOfWeek: currentDay, minuteOfDay: currentMinutes) { return 0 }

        for offset in 0..<8 {
            let checkDay = (currentDay + offset) % 7
            guard rule.days.contains(checkDay) else { continue }

            if rule.timeRanges.isEmpty {
                // Rule is active all day on this day.
                if offset == 0 {
                    // We're currently on this day — but isScheduleActive returned false,
                    // meaning we're past the end of the day's window.
                    // Edge case: timeRanges empty + offset 0 should have returned 0 above.
                    // Per JS: "if offset === 0 return 0" — but we only get here if NOT active,
                    // which for empty-timeRanges always-day-active means we're mid-day.
                    // JS explicitly returns 0 here; we match.
                    return 0
                }
                let hoursToMidnight = Double(1440 - currentMinutes) / 60.0
                return hoursToMidnight + Double(offset - 1) * 24.0
            }

            // Walk through this day's time ranges and find the earliest future start.
            for tr in rule.timeRanges {
                let startMin = tr.start
                if offset == 0 && startMin <= currentMinutes { continue }
                if offset == 0 {
                    return Double(startMin - currentMinutes) / 60.0
                } else {
                    let hoursToMidnight = Double(1440 - currentMinutes) / 60.0
                    return hoursToMidnight + Double(offset - 1) * 24.0 + Double(startMin) / 60.0
                }
            }
        }
        return 168
    }

    /// Computes hours until the next ASP restriction window for the given category and rule.
    /// Port of computeHoursUntilASP(cat, rule, currentDay, currentMinutes) at index.html:3911.
    ///
    /// This is the 14-day walker. It constructs real Date objects (not day/minute offsets) so
    /// that ASP suspension skipping uses the actual calendar date — critical for end-of-month
    /// and year-boundary edge cases.
    ///
    /// Boundary cases handled (R2 in docs/ios-mvp-spec.md §7):
    ///
    /// 1. EMPTY timeRanges + offset == 0:
    ///    The JS checks `if (offset === 0 && now >= start && now < start+24h) return 0`.
    ///    An ASP rule with no time ranges is "active all day" on matching ASP days.
    ///    If offset == 0 and we're within that day's window, return 0 (active now).
    ///    If the day is past midnight (start == midnight, and now is after midnight but
    ///    past the day's 24h window — can't happen since offset is 0 = today), fall through.
    ///
    /// 2. EMPTY timeRanges + offset > 0:
    ///    The matching day is in the future; return hours from now to midnight of that day
    ///    (i.e., the start of that calendar date).
    ///
    /// 3. start <= now in the FIRST matching time range:
    ///    The restriction started in the past but may still be active. The `now >= start`
    ///    check in the JS handles this — if the window is currently open, return 0.
    ///    We rely on nextRestriction() already checking isActive and returning 0 for the
    ///    currently-open window before calling this helper for future windows.
    ///
    /// 4. start > now: return (start - now) in hours. This is the normal future case.
    ///
    /// 5. ASP-suspended dates: skip entirely. The walker increments `offset` and tries
    ///    the next calendar date. This means a block adjacent to a holiday returns the
    ///    next non-suspended matching day — never the suspended day.
    private func computeHoursUntilASP(
        category: Category,
        rule: ParkingRule,
        currentDay: Int,
        currentMinutes: Int,
        from now: Date
    ) -> Double {
        let cal = Calendar.easternTime

        for offset in 0..<14 {
            // Construct the ET midnight of the candidate date.
            guard let checkMidnight = cal.date(byAdding: .day, value: offset, to: now.startOfDayET()) else {
                continue
            }

            // Day-of-week for this candidate date.
            let checkDay = checkMidnight.dayOfWeekET

            // Must be an ASP day for this category.
            guard category.isASPDay(checkDay) else { continue }

            // Rule.days may further restrict which days this rule applies (e.g., a rule
            // might have category ASP_MON_THU but days = [1] only — applies Mondays only).
            if !rule.days.isEmpty && !rule.days.contains(checkDay) { continue }

            // Skip ASP-suspended dates.
            if aspService.isSuspended(checkMidnight) { continue }

            // No time ranges: the rule is "active all day" on this ASP day.
            if rule.timeRanges.isEmpty {
                // JS: if (offset === 0 && now >= start && now < start + 24h) return 0
                // "start" here is midnight of the check date.
                let endOfDay = checkMidnight.addingTimeInterval(24 * 3600)
                if offset == 0 && now >= checkMidnight && now < endOfDay {
                    return 0
                }
                // Future day: hours from now to midnight of that day.
                if checkMidnight > now {
                    return checkMidnight.timeIntervalSince(now) / 3600.0
                }
                // start <= now but we're at offset > 0: this shouldn't happen in practice
                // (offset > 0 means checkMidnight > now by construction), but guard anyway.
                continue
            }

            // Walk time ranges and find the earliest future start.
            for tr in rule.timeRanges {
                // Construct the absolute Date for the start of this time range on checkMidnight.
                let startHour = tr.start / 60
                let startMin = tr.start % 60
                guard let startDate = cal.date(
                    bySettingHour: startHour, minute: startMin, second: 0, of: checkMidnight
                ) else { continue }

                // Construct end date (handles overnight wrap: tr.start > tr.end).
                let endHour = tr.end / 60
                let endMin = tr.end % 60
                var endDate: Date
                if tr.start < tr.end {
                    endDate = cal.date(bySettingHour: endHour, minute: endMin, second: 0, of: checkMidnight)
                        ?? checkMidnight
                } else {
                    // Overnight range wraps into next calendar day.
                    let nextMidnight = checkMidnight.addingTimeInterval(24 * 3600)
                    endDate = cal.date(bySettingHour: endHour, minute: endMin, second: 0, of: nextMidnight)
                        ?? nextMidnight
                }

                // JS: if (now >= start && now < end) return 0   [currently active]
                if now >= startDate && now < endDate { return 0 }
                // JS: if (start > now) return (start - now) / 3600000  [future]
                if startDate > now {
                    return startDate.timeIntervalSince(now) / 3600.0
                }
                // start <= now (past window) — try next time range.
            }
        }
        return 168
    }

    // MARK: - Private: time label formatting

    /// Formats hours-from-now into a "Today 9:30 AM" / "Tomorrow 7:00 AM" / "Thursday 9:30 AM" label.
    /// Port of getNextRestrictionTimeLabel(hours) at index.html:5429.
    ///
    /// Output format: uses en-US locale with hour:numeric, minute:2-digit, hour12:true in ET.
    /// This produces "9:30 AM", "7:00 AM", "7:00 PM" — uppercase, space before AM/PM, always shows
    /// minutes. This matches the JS toLocaleTimeString en-US output exactly.
    ///
    /// "Today" vs "Tomorrow" detection: JS compares calendar dates (etDate, targetDate),
    /// not time intervals. We replicate this using Calendar.easternTime date components.
    func nextRestrictionTimeLabel(hours: Double, now: Date = .nowET) -> String {
        guard hours < 168 else { return "No upcoming restrictions" }

        let target = now.addingTimeInterval(hours * 3600)

        let etComps     = Calendar.easternTime.dateComponents([.day, .weekday, .month, .year], from: now)
        let targetComps = Calendar.easternTime.dateComponents([.day, .weekday, .month, .year], from: target)

        let etDate     = etComps.day ?? 0
        let targetDate = targetComps.day ?? 0
        let etDay      = (etComps.weekday ?? 1) - 1      // 0=Sun
        let targetDay  = (targetComps.weekday ?? 1) - 1  // 0=Sun

        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        let dayLabel: String
        // "Today" if same calendar date AND same weekday (same as JS).
        if etDate == targetDate && etDay == targetDay {
            dayLabel = "Today"
        } else if targetDate == etDate + 1
                    || (etDate > targetDate && (etDay + 1) % 7 == targetDay) {
            // "Tomorrow" handles normal +1 day AND month-end rollover (etDate > targetDate
            // when the month changes, e.g., Jan 31 → Feb 1).
            dayLabel = "Tomorrow"
        } else {
            dayLabel = dayNames[targetDay]
        }

        // Format the time string — must match JS toLocaleTimeString en-US output exactly.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = .easternTime
        // "h:mm a" produces "9:30 AM" — hour (no leading zero), 2-digit minute, uppercase AM/PM.
        // This matches JS { hour: 'numeric', minute: '2-digit', hour12: true } in en-US.
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: target)

        return "\(dayLabel) \(timeStr)"
    }

    // MARK: - Private: metered time format

    /// Formats a minute-of-day value as "7am", "9:30am", "7pm".
    /// Port of the inline `fmt(m)` function in meteredStatusLabel() at index.html:5384-5388.
    ///
    /// This format is DIFFERENT from nextRestrictionTimeLabel — lowercase am/pm, no space,
    /// and omits ":00" for on-the-hour times.
    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let ampm = h >= 12 ? "pm" : "am"
        let h12 = ((h + 11) % 12) + 1
        if m > 0 {
            return "\(h12):\(String(format: "%02d", m))\(ampm)"
        } else {
            return "\(h12)\(ampm)"
        }
    }

    // MARK: - Private: metered label unwrapper

    /// Strips the "Metered (" prefix and ")" suffix from meteredStatus output.
    /// Replicates the JS: lbl.replace(/^Metered \(|\)$/g, '')
    /// e.g., "Metered (paid until 7pm)" → "paid until 7pm"
    ///       "Metered (free until 9am)" → "free until 9am"
    ///       "Metered (free)"           → "free"
    private func stripMeteredWrapper(_ lbl: String) -> String {
        var s = lbl
        if s.hasPrefix("Metered (") {
            s = String(s.dropFirst("Metered (".count))
        }
        if s.hasSuffix(")") {
            s = String(s.dropLast(1))
        }
        return s
    }

    // MARK: - W7.5: Park Until X interval query

    /// Returns true if the segment has no active parking restriction during [from, until].
    ///
    /// "Active" means: the rule's schedule fires AND (for ASP) the date is not suspended.
    /// Metered billing hours count as a restriction — a metered block with paid hours inside
    /// the window returns false (matches PWA checkParkUntilSafety at index.html:4285).
    ///
    /// Precondition: until >= from. Returns true for zero-length windows with no instant
    /// restriction (consistent with a half-open interval interpretation).
    /// Practical cap: callers should enforce until - from <= 24 * 3600.
    ///
    /// All date math uses Calendar.easternTime — zero Calendar.current references.
    ///
    /// Port of checkParkUntilSafety at index.html:4285.
    func isFree(segment: Segment, from: Date = .nowET, until: Date) -> Bool {
        let rules = segment.rules
        // Empty rules → always free.
        guard !rules.isEmpty else { return true }

        let cal = Calendar.easternTime

        // Build the set of calendar dates spanned by [from, until].
        // We walk day by day from the ET date of `from` up to the ET date of `until`.
        let fromMidnight = from.startOfDayET()
        let untilMidnight = until.startOfDayET()

        // Number of full calendar days to walk (0 = same day, 1 = crosses one midnight, etc.)
        let dayCount: Int = {
            let comps = cal.dateComponents([.day], from: fromMidnight, to: untilMidnight)
            return max(0, comps.day ?? 0)
        }()

        for rule in rules {
            let cat = rule.category

            // Fast path: anytime restriction → always conflicts.
            if rule.anytime {
                return false
            }

            // Walk each calendar date in the window.
            for dayOffset in 0...dayCount {
                guard let dayMidnight = cal.date(byAdding: .day, value: dayOffset, to: fromMidnight) else {
                    continue
                }

                // Determine the sub-window of [from, until] that falls on this calendar date.
                let nextMidnight = dayMidnight.addingTimeInterval(24 * 3600)
                let windowStart = dayOffset == 0 ? from : dayMidnight
                let windowEnd   = dayOffset == dayCount ? until : nextMidnight

                let dayOfWeek = dayMidnight.dayOfWeekET

                if cat.isASP {
                    // Must be an ASP day for this category.
                    guard cat.isASPDay(dayOfWeek) else { continue }
                    // Rule.days may further restrict which days this rule applies.
                    if !rule.days.isEmpty && !rule.days.contains(dayOfWeek) { continue }
                    // Skip suspended dates — a suspended ASP day has no restriction.
                    if aspService.isSuspended(dayMidnight) { continue }

                    // No time ranges: rule is active all day on this ASP day.
                    if rule.timeRanges.isEmpty {
                        // The rule covers the entire calendar day. Any overlap with
                        // [windowStart, windowEnd] is a conflict.
                        // windowEnd > windowStart is always true for a non-degenerate window;
                        // if they are equal (zero-length at midnight boundary) we still
                        // treat it as no conflict (half-open semantics for zero-length).
                        if windowEnd > windowStart {
                            return false
                        }
                        continue
                    }

                    // Check each time range for overlap with the day's window.
                    for tr in rule.timeRanges {
                        if timeRangeOverlaps(tr: tr, dayMidnight: dayMidnight,
                                             windowStart: windowStart, windowEnd: windowEnd,
                                             cal: cal) {
                            return false
                        }
                    }

                } else if cat == .noParking || cat == .truckLoading || cat == .noStanding || cat == .special {
                    // Must be a matching day.
                    if !rule.days.isEmpty && !rule.days.contains(dayOfWeek) { continue }

                    // No time ranges: rule is active all day on matching days.
                    if rule.timeRanges.isEmpty {
                        if !rule.days.isEmpty {
                            // The rule is active all day on this day — overlap exists.
                            if windowEnd > windowStart { return false }
                        }
                        continue
                    }

                    for tr in rule.timeRanges {
                        if timeRangeOverlaps(tr: tr, dayMidnight: dayMidnight,
                                             windowStart: windowStart, windowEnd: windowEnd,
                                             cal: cal) {
                            return false
                        }
                    }

                } else if cat == .metered {
                    // Metered billing hours count as a restriction in Park Until mode.
                    if !rule.days.isEmpty && !rule.days.contains(dayOfWeek) { continue }

                    if rule.timeRanges.isEmpty { continue }   // No time ranges → no metered conflict.

                    for tr in rule.timeRanges {
                        if timeRangeOverlaps(tr: tr, dayMidnight: dayMidnight,
                                             windowStart: windowStart, windowEnd: windowEnd,
                                             cal: cal) {
                            return false
                        }
                    }
                }
                // .free, .unknown: never a restriction.
            }
        }

        return true
    }

    /// Returns true if the given TimeRange (expressed in minutes-of-day) overlaps with
    /// the absolute [windowStart, windowEnd] interval on the given calendar day.
    ///
    /// Handles overnight time ranges (tr.start > tr.end) by splitting into two sub-ranges:
    ///   [tr.start, midnight) and [midnight, tr.end) on the next day.
    ///
    /// Overlap semantics: half-open intervals ([start, end)). A window whose `until`
    /// exactly equals the restriction start is treated as NO overlap (the user leaves
    /// exactly as the restriction begins — consistent with the PWA's behavior at
    /// index.html:4347 which uses strict `<` for the end comparison).
    private func timeRangeOverlaps(
        tr: TimeRange,
        dayMidnight: Date,
        windowStart: Date,
        windowEnd: Date,
        cal: Calendar
    ) -> Bool {
        if tr.start < tr.end {
            // Normal (non-overnight) range.
            let startHour = tr.start / 60
            let startMin  = tr.start % 60
            let endHour   = tr.end / 60
            let endMin    = tr.end % 60
            guard let rStart = cal.date(bySettingHour: startHour, minute: startMin, second: 0, of: dayMidnight),
                  let rEnd   = cal.date(bySettingHour: endHour,   minute: endMin,   second: 0, of: dayMidnight)
            else { return false }
            // Half-open interval: [rStart, rEnd) overlaps [windowStart, windowEnd)?
            return rStart < windowEnd && rEnd > windowStart
        } else {
            // Overnight range: wraps midnight. Split into two sub-ranges.
            // Sub-range 1: [tr.start, midnight) on dayMidnight's day.
            let startHour  = tr.start / 60
            let startMin   = tr.start % 60
            let nextMidnight = dayMidnight.addingTimeInterval(24 * 3600)
            guard let rStart = cal.date(bySettingHour: startHour, minute: startMin, second: 0, of: dayMidnight)
            else { return false }
            if rStart < windowEnd && nextMidnight > windowStart { return true }

            // Sub-range 2: [midnight, tr.end) on the next calendar day.
            let endHour = tr.end / 60
            let endMin  = tr.end % 60
            guard let rEnd = cal.date(bySettingHour: endHour, minute: endMin, second: 0, of: nextMidnight)
            else { return false }
            return nextMidnight < windowEnd && rEnd > windowStart
        }
    }
}

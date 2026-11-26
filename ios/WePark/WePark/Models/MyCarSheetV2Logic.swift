//
//  MyCarSheetV2Logic.swift
//  WePark
//
//  Pure, testable helpers behind the redesigned "My Car" sheet (`Views/MyCarSheetV2View.swift`,
//  dark-shipped behind `AppConstants.myCarSheetV2Enabled`). No SwiftUI, no engine instance:
//  everything here takes plain values so the wording is unit-testable.
//
//  Wording rules (plain English, once):
//    - street cleaning:  "street cleaning Mon & Thu 9-10:30 AM"   (days, then time)
//    - everything else:  "no parking 8 AM-6 PM weekdays"          (time, then days)
//    - meter in effect:  "meter until 7 PM"
//

import Foundation

nonisolated enum MyCarSheetVariant: Equatable {
    case legacy
    case v2
    /// Stoop Phase 4 (B7): the round-2 My Car screen. Needs BOTH `designSystemV2Enabled` and
    /// `myCarSheetV2Enabled`; with only the second on, today's `.v2` sheet is unchanged.
    case stoop

    /// Which My Car sheet the app shows. The flags default to the real ones; tests pass them.
    static func resolve(
        v2Enabled: Bool = AppConstants.myCarSheetV2Enabled,
        designSystemEnabled: Bool = AppConstants.designSystemV2Enabled
    ) -> MyCarSheetVariant {
        guard v2Enabled else { return .legacy }
        return designSystemEnabled ? .stoop : .v2
    }
}

nonisolated enum MyCarSheetV2Logic {

    // MARK: - Time / day phrases

    private static let dayAbbrev = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// "8 AM", "10:30 AM", "12 PM" from minutes since midnight.
    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let hour24 = m / 60
        let minute = m % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "AM" : "PM"
        if minute == 0 { return "\(hour12) \(suffix)" }
        let paddedMinute = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(hour12):\(paddedMinute) \(suffix)"
    }

    /// Like `clock`, but minute 0 / 1440 reads "midnight" (a bare "12" or "12 AM" next to a
    /// shared meridiem reads like noon: "12\u{2013}3 AM").
    static func clockOrMidnight(_ minutes: Int) -> String {
        ((minutes % 1440) + 1440) % 1440 == 0 ? "midnight" : clock(minutes)
    }

    /// "9\u{2013}10:30 AM" when both ends share a meridiem, "8 AM\u{2013}6 PM" otherwise.
    /// A midnight end or start is spelled out: "9 AM\u{2013}midnight", "midnight\u{2013}3 AM".
    static func timeRange(_ range: TimeRange) -> String {
        if range.start % 1440 == 0 || range.end % 1440 == 0 {
            return "\(clockOrMidnight(range.start))\u{2013}\(clockOrMidnight(range.end))"
        }
        let start = clock(range.start)
        let end = clock(range.end)
        let startParts = start.split(separator: " ")
        let endParts = end.split(separator: " ")
        if let startSuffix = startParts.last, let endSuffix = endParts.last,
           startSuffix == endSuffix, let startNumber = startParts.first {
            return "\(startNumber)\u{2013}\(end)"
        }
        return "\(start)\u{2013}\(end)"
    }

    static func timePhrase(_ ranges: [TimeRange]) -> String {
        ranges.map { timeRange($0) }.joined(separator: " & ")
    }

    /// "Mon & Thu", "weekdays", "Mon\u{2013}Sat", "daily", "Mon, Wed & Fri".
    static func dayPhrase(_ days: [Int]) -> String {
        let sorted = Set(days.filter { (0...6).contains($0) }).sorted()
        if sorted.isEmpty || sorted.count == 7 { return "daily" }
        if sorted == [1, 2, 3, 4, 5] { return "weekdays" }
        if sorted == [0, 6] { return "weekends" }
        if sorted.count >= 3, let first = sorted.first, let last = sorted.last, last - first == sorted.count - 1 {
            return "\(dayAbbrev[first])\u{2013}\(dayAbbrev[last])"
        }
        let names = sorted.map { dayAbbrev[$0] }
        if names.count == 1 { return names[0] }
        return names.dropLast().joined(separator: ", ") + " & " + (names.last ?? "")
    }

    // MARK: - Rule summaries

    /// Days a rule applies on. ASP rules with no explicit days fall back to the category's days.
    private static func effectiveDays(_ rule: ParkingRule) -> [Int] {
        if !rule.days.isEmpty { return rule.days }
        if rule.category.isASP { return (0...6).filter { rule.category.isASPDay($0) } }
        return []
    }

    private static func categoryNoun(_ category: WePark.Category) -> String {
        switch category {
        case .aspMonThu, .aspTueFri, .aspOvernightMWF, .aspOvernightTTHS, .aspDaily: return "street cleaning"
        case .metered: return "meter"
        case .truckLoading: return "truck loading"
        case .noParking: return "no parking"
        case .noStanding: return "no standing"
        case .special: return "special rule"
        case .free: return "free parking"
        case .unknown: return "unclear sign"
        }
    }

    /// Plain-English one-liner for a rule, no prefix and no trailing period.
    static func plainRule(_ rule: ParkingRule) -> String {
        let noun = categoryNoun(rule.category)
        let times = rule.anytime ? "" : timePhrase(rule.timeRanges)
        let days = dayPhrase(effectiveDays(rule))
        if rule.category.isASP {
            return [noun, days, times].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if rule.anytime {
            return days == "daily" ? "\(noun) at all times" : "\(noun) all day \(days)"
        }
        return [noun, times, days].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "meter until 7 PM" when a metered rule is in effect at (`dayOfWeek`, `minuteOfDay`); `nil` otherwise.
    static func meterUntil(rules: [ParkingRule], dayOfWeek: Int, minuteOfDay: Int) -> String? {
        for rule in rules where rule.category == .metered {
            guard rule.anytime || rule.days.isEmpty || rule.days.contains(dayOfWeek) else { continue }
            for range in rule.timeRanges {
                // Same midnight-aware check the engine uses, so hero and this line agree.
                if rule.rangeActive(range, dayOfWeek: dayOfWeek, minuteOfDay: minuteOfDay, emptyDaysMeansEveryDay: true) {
                    return "meter until \(clockOrMidnight(range.end))"
                }
            }
        }
        return nil
    }

    /// The "Next: ..." line under the hero status. `restriction` is `engine.nextRestriction(...)`
    /// (which skips meters on purpose); `rules` is the segment's full list so a meter can still be
    /// summarized when nothing else will force a move. `nil` means nothing to say.
    static func nextMoveLine(
        restriction: NextRestriction,
        rules: [ParkingRule],
        dayOfWeek: Int,
        minuteOfDay: Int,
        now: Date? = nil
    ) -> String? {
        if let rule = restriction.rule, !restriction.isUnrestricted {
            if restriction.isActiveNow {
                if rule.category == .unknown { return "Now: unclear sign, check the posted sign" }
                return "Now: \(plainRule(rule))"
            }
            // The engine already skipped suspended street-cleaning dates when it computed
            // `hours`, so name only the weekday it actually landed on ("Mon", not "Mon & Thu"
            // when Thursday is a holiday).
            if let now, rule.category.isASP, !rule.anytime {
                let target = now.addingTimeInterval(restriction.hours * 3600)
                let day = dayPhrase([target.dayOfWeekET])
                let times = timePhrase(rule.timeRanges)
                let text = ["street cleaning", day, times].filter { !$0.isEmpty }.joined(separator: " ")
                return "Next: \(text)"
            }
            return "Next: \(plainRule(rule))"
        }
        if let meter = meterUntil(rules: rules, dayOfWeek: dayOfWeek, minuteOfDay: minuteOfDay) {
            return "Now: \(meter)"
        }
        return nil
    }

    // MARK: - Leaving

    /// The server keeps a leaving-soon pin alive for the chosen minutes PLUS this grace period
    /// (`derive_pin_expiry`: `now() + (leaving_minutes + 3) minutes`).
    static let leavingSoonServerGraceMinutes = 3

    /// Minutes to show in "Neighbors have been told \u{2014} N min left": the countdown the user
    /// chose, not the server's padded expiry. Picks of 10 read "10", not "12"/"13".
    static func leavingSoonMinutesLeft(expiresAt: Date, now: Date, leavingMinutes: Int?) -> Int {
        let seconds = expiresAt.timeIntervalSince(now)
        guard let leavingMinutes else { return max(0, Int((seconds / 60).rounded(.up))) }
        let unpadded = seconds - Double(leavingSoonServerGraceMinutes * 60)
        let minutes = Int((unpadded / 60).rounded(.up))
        return min(leavingMinutes, max(0, minutes))
    }

    /// The "I'm leaving" button opens the hand-off sheet only when it has something besides "Just
    /// clear my car" to offer (crew pin via community, or Spot Pass); otherwise it clears directly,
    /// matching what the old single button did.
    static func leaveButtonOpensSheet(communityEnabled: Bool, spotPassAvailable: Bool) -> Bool {
        communityEnabled || spotPassAvailable
    }

    // MARK: - Sign dedupe

    /// Collapses repeated signs (same category, same wording ignoring case/whitespace, same schedule),
    /// preserving first-seen order and ignoring arrow direction.
    static func dedupedRules(_ rules: [ParkingRule]) -> [ParkingRule] {
        var seen = Set<String>()
        var result: [ParkingRule] = []
        for rule in rules {
            let words = rule.description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            let dayKey = rule.days.sorted().map { String($0) }.joined(separator: ",")
            let timeKey = rule.timeRanges.map { "\($0.start)-\($0.end)" }.joined(separator: ",")
            let key = [rule.category.rawValue, words, dayKey, timeKey, rule.anytime ? "1" : "0"].joined(separator: "|")
            if seen.insert(key).inserted { result.append(rule) }
        }
        return result
    }

    /// Full sign text for the disclosure: the raw description, or a generated line when it is blank.
    static func signText(_ rule: ParkingRule) -> String {
        let trimmed = rule.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let plain = plainRule(rule)
        return plain.prefix(1).uppercased() + plain.dropFirst()
    }

    // MARK: - Reminder summary

    /// Selected lead-time labels in ascending order (night-before is separate).
    static func selectedLeadLabels(_ offsets: ReminderOffsets) -> [String] {
        var labels: [String] = []
        if offsets.remind15Min { labels.append("15 min") }
        if offsets.remind30Min { labels.append("30 min") }
        if offsets.remind1Hour { labels.append("1 hr") }
        if offsets.remind2Hours { labels.append("2 hr") }
        return labels
    }

    /// The single row value: "15 min before + night before", "15 & 30 min before", "Night before",
    /// "Reminders off". `showDetail == false` (community flag off: no per-time options in the UI)
    /// collapses the on state to "On".
    static func reminderSummary(remindMe: Bool, offsets: ReminderOffsets, showDetail: Bool = true) -> String {
        guard remindMe else { return "Reminders off" }
        guard showDetail else { return "On" }
        let leads = selectedLeadLabels(offsets)
        var parts: [String] = []
        if !leads.isEmpty {
            let units = Set(leads.compactMap { $0.split(separator: " ").last.map { String($0) } })
            if units.count == 1, let unit = units.first {
                let numbers = leads.compactMap { $0.split(separator: " ").first.map { String($0) } }
                parts.append(numbers.joined(separator: " & ") + " \(unit) before")
            } else {
                parts.append(leads.joined(separator: " & ") + " before")
            }
        }
        if offsets.remindNightBefore { parts.append(leads.isEmpty ? "Night before" : "night before") }
        if parts.isEmpty { return "Pick a time" }
        return parts.joined(separator: " + ")
    }

    // MARK: - Header lines

    /// "1st\u{2013}2nd Ave" when both cross streets share a suffix, else "Hester St \u{2013} Grand St".
    static func crossStreetRange(from: String, to: String) -> String {
        let fromWords = from.split(separator: " ")
        let toWords = to.split(separator: " ")
        if fromWords.count >= 2, toWords.count >= 2,
           let fromSuffix = fromWords.last, let toSuffix = toWords.last, fromSuffix == toSuffix {
            let fromHead = fromWords.dropLast().joined(separator: " ")
            let toHead = toWords.dropLast().joined(separator: " ")
            return "\(fromHead)\u{2013}\(toHead) \(fromSuffix)"
        }
        return "\(from) \u{2013} \(to)"
    }

    /// Title: the address when there is one, else "E 1st St, North side", else "My Car".
    static func title(addressLine: String?, street: String?, side: String?) -> String {
        if let addressLine, !addressLine.isEmpty { return addressLine }
        if let street, let side { return "\(street), \(side)" }
        if let street { return street }
        return "My Car"
    }

    /// One secondary line: "North side \u{00B7} 1st\u{2013}2nd Ave \u{00B7} parked 8h ago". The side is
    /// omitted when the title already carries it (`sideInTitle`).
    static func secondaryLine(side: String?, sideInTitle: Bool, crossStreets: String?, parkedAgo: String, hasData: Bool) -> String {
        var parts: [String] = []
        if let side, !sideInTitle { parts.append(side) }
        if let crossStreets, !crossStreets.isEmpty { parts.append(crossStreets) }
        if !hasData { parts.append("No parking data here") }
        parts.append("parked \(parkedAgo)")
        return parts.joined(separator: " \u{00B7} ")
    }
}

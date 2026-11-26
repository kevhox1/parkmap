//
//  WPCurbSheetLogic.swift
//  WePark
//
//  Phase 2b (design system v0.1: curb detail, search, parking). Pure, unit-testable logic behind
//  the flag-on curb sheet (B4), the destination card (B3) and the drag-to-park feedback (B6).
//  Nothing here reads UI state. Every time comes from `ParkingRulesEngine`; every green gate is
//  `WPCurbVerdict.isParkable`.
//
//  Product rules enforced here (Kevin's, non-negotiable; DECISIONS.md accuracy adjustments):
//    - Never show a spot that isn't a spot. Unknown, unclear and no-data are never `park` and
//      never offer "Park here" as the primary action.
//    - Never claim a restriction a sign doesn't state: an unclear sign is "Unclear sign: check the
//      posted sign", never "street cleaning".
//    - No sub-curb precision: arrow / corner signs read "Arrow sign. Applies near the corner.
//      Check the sign on the street." Never "first 20 ft" or "your car is past it".
//    - A neighbor report never makes a curb greener. The sign verdict stands.
//    - "Open spot" pins draw only on curbs that are green for the window.
//    - Counts are computed on device from loaded segments for the selected window, or hidden.
//    - Midnight is written "midnight", never "12 AM".
//

import CoreLocation
import Foundation
import MapKit

// MARK: - Variant

/// Which curb-sheet verdict to show: the seven design kinds plus `unclear` (an UNKNOWN sign, #196).
enum WPCurbVariant: Equatable, CaseIterable {
    case park, soon, dont, meter, nodata, unclear, planpark, plandont

    /// The block drawing for this variant. `unclear` borrows the "don't" look (unsure is drawn as
    /// don't, rule 3).
    nonisolated var blockKind: WPVerdictKind {
        switch self {
        case .park: return .park
        case .soon: return .soon
        case .dont, .unclear: return .dont
        case .meter: return .meter
        case .nodata: return .nodata
        case .planpark: return .planpark
        case .plandont: return .plandont
        }
    }

    nonisolated var isPlan: Bool { self == .planpark || self == .plandont }

    /// Only a curb that is legal to park on right now offers the yellow raised "Park here".
    /// Unclear, no-data, don't, metered and every plan variant never do.
    nonisolated var offersPrimaryPark: Bool { self == .park || self == .soon }

    /// How green the verdict is (higher = greener). A neighbor report may only lower this.
    nonisolated var greenRank: Int {
        switch self {
        case .park, .planpark: return 3
        case .soon: return 2
        case .meter: return 1
        case .dont, .unclear, .nodata, .plandont: return 0
        }
    }
}

// MARK: - Model

struct WPCurbSheetModel: Equatable {
    var variant: WPCurbVariant
    /// "E 1st St · North side".
    var title: String
    /// "Between 1st Ave and 2nd Ave".
    var cross: String?
    var over: String
    var big: String
    var sub: String?
    /// Park only: 0...1 portion of the look-ahead left (the white part of the bar).
    var fractionLeft: Double?
    /// Distinct posted signs on this curb (what "See the N signs" opens).
    var signCount: Int
    /// The restriction that ends the free stretch, when the engine found one (for the park flow).
    var nextChange: Date?
    /// False when `big` is a plain statement, not a clock time ("Meter on this curb"). Every
    /// surface that writes "until \(big)" must go through `freeLine` (or check this) instead.
    var bigIsTime: Bool = true

    /// True when the free stretch has no end inside the 7 day look-ahead ("7+ days").
    nonisolated var isOpenEnded: Bool { variant == .park && big == WPCurbCopy.openEndedBig }

    /// "Free until Mon 9:00 AM" / "Free for 7+ days". One wording for every surface (drag bubble,
    /// car callout): "until 7+ days" is not a time.
    nonisolated var freeLine: String {
        if !bigIsTime { return "\(big). Check the meter." }
        return isOpenEnded ? "Free for \(big)" : "Free until \(big)"
    }

    nonisolated var ctaTitle: String { variant.offersPrimaryPark ? "Park here" : "Park here anyway" }
    nonisolated var offersPrimaryPark: Bool { variant.offersPrimaryPark }
}

// MARK: - Builder

enum WPCurbSheetBuilder {

    /// Look-ahead the engine uses for "no restriction found" (`nextRestriction` sentinel is 168 h).
    nonisolated static let lookAheadHours: Double = 168

    /// Builds the sheet model for one curb.
    /// - Parameters:
    ///   - windowEnd: end of the selected goal window (nil when no goal is active).
    ///   - trip: non-nil while a trip plan is active: the plan variants replace the live ones.
    nonisolated static func make(
        segment: Segment,
        engine: ParkingRulesEngine,
        now: Date,
        windowEnd: Date?,
        trip: TripPlan? = nil
    ) -> WPCurbSheetModel {
        let title = WPCurbCopy.title(for: segment)
        let cross = WPCurbCopy.cross(for: segment)
        let signCount = WPSignList.lines(for: segment, engine: engine, now: now).count

        func model(
            _ variant: WPCurbVariant, over: String, big: String, sub: String? = nil,
            fraction: Double? = nil, nextChange: Date? = nil, bigIsTime: Bool = true
        ) -> WPCurbSheetModel {
            WPCurbSheetModel(
                variant: variant, title: title, cross: cross, over: over, big: big, sub: sub,
                fractionLeft: fraction, signCount: signCount, nextChange: nextChange,
                bigIsTime: bigIsTime
            )
        }

        // Plan a Trip: not live. Unreadable signs are never "free for your trip".
        if let trip {
            if WPCurbVerdict.hasUnreadableSigns(segment) {
                let none = segment.hasNoSignData
                return model(
                    .plandont,
                    over: none ? NoSignData.overline : "Not free for your trip",
                    big: none ? NoSignData.headline : UnclearSign.headline,
                    sub: "We can't confirm this curb for your trip. Read the posted signs when you arrive."
                )
            }
            switch TripPlanning.verdict(segment: segment, plan: trip, engine: engine) {
            case .free:
                return model(
                    .planpark,
                    over: WPCurbCopy.tripRange(trip),
                    big: "Free for your whole trip",
                    sub: "Rules can change. Check again when you arrive."
                )
            case .notFree(let reason):
                return model(
                    .plandont,
                    over: "Not free for your trip",
                    big: WPCurbCopy.capitalized(reason),
                    sub: "You would have to move the car."
                )
            }
        }

        // No sign data: never green, never "No parking" (that would read as a posted sign).
        if segment.hasNoSignData {
            return model(
                .nodata, over: NoSignData.overline, big: NoSignData.headline,
                sub: [NoSignData.subline, segment.noSignDataReason].compactMap { $0 }.joined(separator: " ")
            )
        }

        let state = engine.currentState(for: segment, at: now)
        let next = engine.nextRestriction(for: segment, at: now)
        let hasUnclear = segment.rules.contains { $0.category == .unknown }

        // An UNKNOWN sign that is the reason (or could be): "check the posted sign", never a
        // specific restriction. A KNOWN active restriction still wins (named plainly below).
        if hasUnclear, !(state == .restrictedNow && next.category != .unknown) {
            return model(
                .unclear, over: UnclearSign.upcomingLabel, big: "Check the posted sign",
                sub: "We couldn't read one of the signs on this curb. Read it on the street before you park."
            )
        }

        switch state {
        case .unknown:
            return model(
                .nodata, over: NoSignData.overline, big: NoSignData.headline, sub: NoSignData.subline
            )

        case .restrictedNow:
            let name = WPCurbCopy.restrictionName(next.category)
            let freeAt = WPCurbCopy.nextFreeMoment(segment: segment, engine: engine, from: now)
            let headline = WPCurbCopy.restrictionHeadline(next.category)
            var sub: String
            if let freeAt {
                sub = "\(WPCurbCopy.capitalized(name)) until \(WPCurbCopy.when(freeAt, now: now))."
                let after = engine.nextRestriction(for: segment, at: freeAt)
                if after.hours < lookAheadHours {
                    let again = freeAt.addingTimeInterval(after.hours * 3600)
                    sub += " Free after that until \(WPCurbCopy.when(again, now: now))."
                } else {
                    sub += " Free after that."
                }
            } else {
                // Never frees up inside the 7 day look-ahead (e.g. no standing, anytime).
                sub = headline.lowercased() == name
                    ? "No end in the next 7 days."
                    : "\(WPCurbCopy.capitalized(name)). No end in the next 7 days."
            }
            return model(
                .dont, over: "Right now", big: WPCurbCopy.restrictionHeadline(next.category), sub: sub,
                nextChange: freeAt
            )

        case .meteredActive:
            let label = engine.safetyLabel(for: segment, at: now).text
            let until = WPCurbCopy.meterUntil(from: label)
            return model(
                .meter, over: "Pay the meter until", big: until,
                sub: "Check the signs on this curb for the time limit."
            )

        case .freeButRestrictionSoon, .freeComfortably:
            let otherAt = next.hours < lookAheadHours
                ? now.addingTimeInterval(next.hours * 3600) : nil
            // The engine's `nextRestriction` skips meters ("not a move-your-car restriction"), so a
            // meter that starts later is found separately. A curb with a meter is never green
            // unless the whole selected window is meter-free (the map's strict `isParkable`).
            let hasMeter = WPCurbVerdict.hasMeterRule(segment)
            let meterAt = hasMeter ? WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: now) : nil
            let restrictionAt = [otherAt, meterAt].compactMap { $0 }.min()
            let meterIsFirst: Bool = {
                guard let meterAt else { return false }
                guard let otherAt else { return true }
                return meterAt < otherAt
            }()
            let name = meterIsFirst ? "the meter" : WPCurbCopy.restrictionName(next.category)
            // Legal now but not green: a restriction is soon, a restriction lands inside the
            // selected window, or (no window) the curb has a meter at all.
            let legalButNotGreen: Bool = {
                // With a selected window the map's own gate decides (a restriction that starts at
                // or after the window end is still green); without one, a restriction inside 6 h
                // is "soon".
                if windowEnd == nil, state == .freeButRestrictionSoon { return true }
                if let windowEnd {
                    return !WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: windowEnd)
                }
                return hasMeter
            }()
            if legalButNotGreen {
                guard let restrictionAt else {
                    return model(
                        .soon, over: "Free now", big: "Meter on this curb",
                        sub: "Check the signs for the meter hours before you park.",
                        bigIsTime: false
                    )
                }
                var sub = "\(WPCurbCopy.duration(until: restrictionAt, from: now)) left, then \(name)."
                if let windowEnd, restrictionAt < windowEnd {
                    sub += " That is before your window ends at \(WPGoalCopy.clock(windowEnd))."
                }
                return model(
                    .soon, over: "Free until", big: WPCurbCopy.when(restrictionAt, now: now), sub: sub,
                    nextChange: restrictionAt
                )
            }
            if let restrictionAt {
                return model(
                    .park, over: "Free to stay until", big: WPCurbCopy.when(restrictionAt, now: now),
                    sub: "\(WPCurbCopy.duration(until: restrictionAt, from: now)) left, then \(name).",
                    fraction: min(1, max(0, restrictionAt.timeIntervalSince(now) / 3600 / lookAheadHours)),
                    nextChange: restrictionAt
                )
            }
            return model(
                .park, over: "Free to stay for", big: WPCurbCopy.openEndedBig,
                sub: "No restriction on the signs for the next 7 days.", fraction: 1
            )
        }
    }
}

// MARK: - Copy

enum WPCurbCopy {

    /// The "big" text of a park verdict with no restriction inside the look-ahead.
    nonisolated static let openEndedBig = "7+ days"

    /// First moment after `from` (inside the 7 day look-ahead) when a metered rule comes into
    /// force. Found from the rules' own start boundaries (every meter range start on each of the
    /// next 9 Eastern calendar days), so a window of any length is found, never stepped over.
    /// A boundary counts only when the rule is actually in force at that instant (right day).
    nonisolated static func nextMeterStart(segment: Segment, engine: ParkingRulesEngine, from: Date) -> Date? {
        let limit = from.addingTimeInterval(WPCurbSheetBuilder.lookAheadHours * 3600)
        let cal = Calendar.easternTime
        let today = cal.startOfDay(for: from)
        let meterRules = segment.rules.filter { $0.category == .metered && !$0.timeRanges.isEmpty }
        var best: Date?
        for rule in meterRules {
            for dayOffset in 0...8 {
                guard let day = cal.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                for tr in rule.timeRanges {
                    // Wall-clock, not elapsed minutes: on DST days the day is 23 or 25 hours long, so
                    // `day + N minutes` lands an hour off (or skips a day's meter entirely).
                    guard let start = cal.date(bySettingHour: tr.start / 60, minute: tr.start % 60, second: 0, of: day),
                          start > from, start < limit else { continue }
                    if let current = best, start >= current { continue }
                    if rule.rangeActive(
                        tr, dayOfWeek: start.dayOfWeekET, minuteOfDay: start.minuteOfDayET,
                        emptyDaysMeansEveryDay: true
                    ) { best = start }
                }
            }
        }
        return best
    }

    /// "E 1st St · North side".
    nonisolated static func title(for segment: Segment) -> String {
        "\(StreetNameFormatter.displayCanonical(segment.street)) \u{00B7} \(sideLabel(segment.side))"
    }

    /// "Between 1st Ave and 2nd Ave".
    nonisolated static func cross(for segment: Segment) -> String? {
        let from = StreetNameFormatter.displayCanonical(segment.fromStreet)
        let to = StreetNameFormatter.displayCanonical(segment.to)
        guard !from.isEmpty, !to.isEmpty else { return nil }
        return "Between \(from) and \(to)"
    }

    nonisolated static func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default: return "\(code) side"
        }
    }

    nonisolated static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Plain words for the restriction that ends (or blocks) the free stretch. `unknown` never
    /// names a specific restriction.
    nonisolated static func restrictionName(_ category: Category?) -> String {
        guard let category else { return "a restriction" }
        if category.isASP { return "street cleaning" }
        switch category {
        case .noParking: return "no parking"
        case .noStanding: return "no standing"
        case .truckLoading: return "truck loading"
        case .special: return "a special restriction"
        case .metered: return "the meter"
        case .unknown: return "an unclear sign"
        default: return "a restriction"
        }
    }

    /// The big word on a "don't" block.
    nonisolated static func restrictionHeadline(_ category: Category?) -> String {
        guard let category else { return "No parking" }
        if category.isASP { return "No parking" }
        switch category {
        case .noStanding: return "No standing"
        case .truckLoading: return "Truck loading"
        case .special: return "Restricted"
        default: return "No parking"
        }
    }

    /// "Mon 11/30 9:00 AM", "Tomorrow 7:00 AM", "Today midnight". Day wording and clock text come
    /// from the engine's label; midnight is rewritten from "12:00 AM" and the meridiem never wraps.
    nonisolated static func when(_ date: Date, now: Date) -> String {
        let hours = date.timeIntervalSince(now) / 3600
        let raw = ParkingRulesEngine().nextRestrictionTimeLabel(hours: max(0, hours), now: now)
        return midnightized(ParkingGoals.nonBreakingMeridiem(raw))
    }

    /// "12:00 AM" (and the non-breaking form) read "midnight".
    nonisolated static func midnightized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "12:00\u{00A0}AM", with: "midnight")
            .replacingOccurrences(of: "12:00 AM", with: "midnight")
            .replacingOccurrences(of: "12\u{00A0}AM", with: "midnight")
    }

    /// "4 days 11 h", "7 h 49 min", "45 min".
    nonisolated static func duration(until date: Date, from now: Date) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded()))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 {
            let dayWord = days == 1 ? "1 day" : "\(days) days"
            return hours > 0 ? "\(dayWord) \(hours) h" : dayWord
        }
        if hours > 0 { return mins > 0 ? "\(hours) h \(mins) min" : "\(hours) h" }
        return "\(mins) min"
    }

    /// "paid until 7pm" (engine metered label) -> "7 PM".
    nonisolated static func meterUntil(from label: String) -> String {
        let lower = label.lowercased()
        guard let range = lower.range(of: "paid until ") else { return label }
        let tail = String(label[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        var out = tail.uppercased()
        if out.hasSuffix("AM") || out.hasSuffix("PM") {
            let suffix = String(out.suffix(2))
            out = String(out.dropLast(2)) + "\u{00A0}" + suffix
        }
        return midnightized(out)
    }

    /// "Sat 10 AM to Sun 6 PM".
    nonisolated static func tripRange(_ plan: TripPlan) -> String {
        let fmt = DateFormatter()
        fmt.timeZone = .easternTime
        fmt.locale = Locale(identifier: "en_US")
        fmt.dateFormat = "EEE h:mm a"
        let a = ParkingGoals.nonBreakingMeridiem(fmt.string(from: plan.arrival))
        let d = ParkingGoals.nonBreakingMeridiem(fmt.string(from: plan.departure))
        return midnightized("\(a) to \(d)")
    }

    /// First moment at or after `from` when nothing restricts the curb (5 minute steps over the
    /// 7 day look-ahead, then refined to the minute). Engine-only: `currentState` decides.
    nonisolated static func nextFreeMoment(segment: Segment, engine: ParkingRulesEngine, from: Date) -> Date? {
        let step: TimeInterval = 300
        var t = from
        let limit = from.addingTimeInterval(WPCurbSheetBuilder.lookAheadHours * 3600)
        while t < limit {
            t = t.addingTimeInterval(step)
            if engine.currentState(for: segment, at: t) != .restrictedNow {
                // Refine inside the last step.
                var lo = t.addingTimeInterval(-step)
                while lo < t {
                    lo = lo.addingTimeInterval(60)
                    if engine.currentState(for: segment, at: lo) != .restrictedNow { return lo }
                }
                return t
            }
        }
        return nil
    }
}

// MARK: - Sign list (B4.11)

/// One distinct posted sign: the city's own wording and a plain line under it.
struct WPSignLine: Equatable, Identifiable {
    var id: String { "\(category)|\(text)" }
    let category: String
    /// Full posted text, untouched.
    let text: String
    /// Plain-words line under the sign.
    let plain: String
}

enum WPSignList {

    nonisolated static let arrowLine = "Arrow sign. Applies near the corner. Check the sign on the street."

    /// Distinct signs (duplicates merged), most restrictive first, each with a plain line.
    /// Never claims a distance ("first 20 ft") or whether a car is "past" a sign.
    nonisolated static func lines(for segment: Segment, engine: ParkingRulesEngine, now: Date) -> [WPSignLine] {
        guard !segment.hasNoSignData else { return [] }
        let rules = BlockDetailView.dedupedForDisplay(
            segment.rules.sorted { ($0.category.priority) < ($1.category.priority) }
        )
        return rules.map { rule in
            WPSignLine(
                category: rule.category.rawValue,
                text: rule.description.trimmingCharacters(in: .whitespaces).isEmpty
                    ? rule.category.label : rule.description,
                plain: plainLine(for: rule, segment: segment, engine: engine, now: now)
            )
        }
    }

    nonisolated static func isArrowLimited(_ rule: ParkingRule) -> Bool {
        guard let arrow = rule.arrow?.lowercased() else { return false }
        return arrow == "towards" || arrow == "away"
    }

    nonisolated static func plainLine(for rule: ParkingRule, segment: Segment, engine: ParkingRulesEngine, now: Date) -> String {
        if isArrowLimited(rule) { return arrowLine }
        if rule.category == .unknown { return "\(UnclearSign.headline)." }
        let single = Segment(
            id: segment.id, street: segment.street, fromStreet: segment.fromStreet, to: segment.to,
            side: segment.side, line: segment.line, rules: [rule], dominantCategory: rule.category
        )
        let next = engine.nextRestriction(for: single, at: now)
        let name = WPCurbCopy.capitalized(WPCurbCopy.restrictionName(rule.category))
        if rule.category == .metered { return "Paid parking. Check the meter for the limit." }
        if next.isActiveNow { return "\(name). In effect now." }
        if next.hours < WPCurbSheetBuilder.lookAheadHours {
            let at = now.addingTimeInterval(next.hours * 3600)
            return "\(name). Next: \(WPCurbCopy.when(at, now: now))."
        }
        return "\(name)."
    }
}

// MARK: - Neighbor reports (B4.8, B4.9)

/// What neighbors reported on this curb, already reduced to what changes the sheet.
struct WPNeighborReports: Equatable {
    /// An active block-scoped restriction (filming / construction), if any.
    var restrictionLabel: String?
    var restrictionIsActive: Bool = false
}

enum WPNeighborVerdict {

    /// Reduces the active block-scoped neighbor report (filming / construction) on a curb to what
    /// changes a verdict. Plan a Trip never uses live reports.
    nonisolated static func reports(for restriction: CommunityPin?, now: Date, trip: TripPlan?) -> WPNeighborReports {
        guard trip == nil, let restriction else { return WPNeighborReports() }
        return WPNeighborReports(
            restrictionLabel: label(for: restriction.pinType),
            restrictionIsActive: !restriction.isUpcoming(now: now)
        )
    }

    /// THE verdict for one curb: sign verdict (`WPCurbSheetBuilder`) then neighbor reports
    /// (`apply`). The curb sheet, the drag bubble and the parked-car callout all call this, so a
    /// curb with an active filming report reads "don't" on every surface.
    nonisolated static func resolve(
        segment: Segment,
        engine: ParkingRulesEngine,
        now: Date,
        windowEnd: Date?,
        trip: TripPlan?,
        reports: WPNeighborReports
    ) -> WPCurbSheetModel {
        apply(reports, to: WPCurbSheetBuilder.make(
            segment: segment, engine: engine, now: now, windowEnd: windowEnd, trip: trip
        ))
    }

    /// The parked-car callout verdict. The saved car is judged live and on its own: there is no
    /// search window (that window belongs to the spot being searched, not the parked car), so
    /// "Free until X" always names the FIRST restriction on the curb, meter included.
    nonisolated static func carCallout(
        segment: Segment, engine: ParkingRulesEngine, now: Date, reports: WPNeighborReports
    ) -> String? {
        calloutText(for: resolve(
            segment: segment, engine: engine, now: now, windowEnd: nil, trip: nil, reports: reports
        ))
    }

    /// The parked-car callout line for a resolved verdict (nil for plan variants).
    nonisolated static func calloutText(for model: WPCurbSheetModel) -> String? {
        switch model.variant {
        case .park, .soon: return model.freeLine
        case .meter: return "Metered until \(model.big)"
        case .dont: return model.big
        case .nodata: return NoSignData.headline
        case .unclear: return UnclearSign.upcomingLabel
        case .planpark, .plandont: return nil
        }
    }

    /// "Blocked for filming" / "Construction on this curb".
    nonisolated static func label(for type: PinType) -> String {
        type == .construction ? "Construction on this curb" : "Blocked for filming"
    }

    /// Applies neighbor reports to a sign verdict. A report can only make the verdict stricter:
    /// an active reported restriction turns a legal-looking curb into a "don't" ("unsure is
    /// don't"); a swept badge, confirmations and everything else add information only. The result
    /// is never greener than the input.
    nonisolated static func apply(_ reports: WPNeighborReports, to model: WPCurbSheetModel) -> WPCurbSheetModel {
        guard !model.variant.isPlan,
              let label = reports.restrictionLabel, reports.restrictionIsActive else { return model }
        // Already as strict as a report can make it: the sign verdict stands untouched.
        guard model.variant.greenRank > 0 else { return model }
        var out = model
        out.variant = .dont
        out.over = "Neighbors say"
        out.big = label
        let signLine: String
        switch model.variant {
        case .meter:
            signLine = "By the signs this curb is metered until \(model.big)."
        case .soon where !model.bigIsTime:
            signLine = "By the signs this curb is free now, but it has a meter. Check the meter hours."
        case .park where model.isOpenEnded:
            signLine = "By the signs this curb is free for the next 7 days."
        default:
            signLine = "By the signs this curb is free until \(model.big)."
        }
        out.sub = signLine
        out.fractionLeft = nil
        return out
    }
}

// MARK: - "Open spot" pins (B4.10, DECISIONS accuracy 2)

enum WPOpenSpotGate {

    /// Drops every "open spot" pin whose curb is not green for the window. Other pin types pass
    /// through untouched. An open-spot pin with no segment (or an unloaded one) is dropped too:
    /// "never show a spot that isn't a spot".
    nonisolated static func filter(
        _ pins: [CommunityPin],
        segmentsByID: [String: Segment],
        engine: ParkingRulesEngine,
        from: Date,
        until: Date
    ) -> [CommunityPin] {
        pins.filter { pin in
            guard pin.pinType == .openSpot else { return true }
            guard let id = pin.segmentId, let segment = segmentsByID[id] else { return false }
            return WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: until)
        }
    }

    /// List wording for an open-spot report on a curb that is not green.
    nonisolated static let listLine = "Reported open. Check the signs."
}

// MARK: - Free-curb count (B3.3, DECISIONS accuracy 5)

struct WPFreeCurbCount: Equatable {
    let count: Int
    /// Distance in meters to the nearest free curb, only when `count == 0` and one is loaded.
    let nearestMeters: Double?
}

/// Which tiles exist and which are loaded, so a count over an area can tell "no free curbs here"
/// from "the tiles for this area have not loaded yet".
struct WPTileCoverage: Equatable {
    let gridRows: Int
    let gridCols: Int
    let latMin: Double
    let lngMin: Double
    let rowSize: Double
    let colSize: Double
    /// "row_col" keys of every tile that exists (the tile set is sparse).
    let existingTiles: Set<String>
    /// "row_col" keys currently loaded into the segment list.
    let loadedTiles: Set<String>

    /// True only when at least one tile covers the circle of `radiusMeters` around `center` and
    /// EVERY tile that exists under that circle's bounding box is loaded. An area with no tiles at
    /// all is not "covered": there is nothing to count.
    nonisolated func covers(_ center: CLLocationCoordinate2D, radiusMeters: Double) -> Bool {
        let dLat = radiusMeters / 111_320
        let dLng = radiusMeters / (111_320 * max(0.2, cos(center.latitude * .pi / 180)))
        let region = MKCoordinateRegion(
            center: center, span: MKCoordinateSpan(latitudeDelta: dLat * 2, longitudeDelta: dLng * 2)
        )
        let needed = TileLoader.tileKeys(
            forRegion: region, gridRows: gridRows, gridCols: gridCols, latMin: latMin, lngMin: lngMin,
            rowSize: rowSize, colSize: colSize, tileSet: existingTiles, buffer: 0
        )
        guard !needed.isEmpty else { return false }
        return needed.allSatisfy { loadedTiles.contains($0) }
    }
}

enum WPFreeCurbCounter {

    /// "Within 2 blocks": two short (north-south) Manhattan blocks, about 80 m each.
    nonisolated static let radiusMeters: Double = 160

    /// The "nearest free curb" line looks this far. It is only shown when the tiles for the whole
    /// distance are loaded (a nearer curb in an unloaded tile would make it wrong).
    nonisolated static let coverageProbeMeters: Double = 400

    /// Counts curbs within `radiusMeters` of `destination` that are green (`isParkable`) for
    /// `[from, until]`. Returns nil (count hidden, never estimated) unless every tile covering the
    /// counting radius is loaded: a partly loaded area could otherwise read "No free curbs".
    nonisolated static func count(
        near destination: CLLocationCoordinate2D,
        segments: [Segment],
        coverage: WPTileCoverage?,
        engine: ParkingRulesEngine,
        from: Date,
        until: Date
    ) -> WPFreeCurbCount? {
        guard let coverage, coverage.covers(destination, radiusMeters: radiusMeters) else { return nil }
        let nearestCovered = coverage.covers(destination, radiusMeters: coverageProbeMeters)
        var count = 0
        var nearest: Double?
        for segment in segments {
            // Cheap bounding-box reject (~1.3 km) before the precise distance.
            if let first = segment.line.first, first.count >= 2,
               abs(first[0] - destination.latitude) > 0.012 || abs(first[1] - destination.longitude) > 0.016 {
                continue
            }
            let d = distance(from: destination, to: segment)
            guard d <= coverageProbeMeters else { continue }
            guard WPCurbVerdict.isParkable(segment: segment, engine: engine, from: from, until: until) else { continue }
            if d <= radiusMeters { count += 1 }
            if nearest == nil || d < nearest! { nearest = d }
        }
        return WPFreeCurbCount(
            count: count, nearestMeters: (count == 0 && nearestCovered) ? nearest : nil
        )
    }

    /// Shortest distance from `point` to any vertex or edge midpoint of the segment's line (the
    /// lines are short block faces, so vertex sampling is within a few meters).
    nonisolated static func distance(from point: CLLocationCoordinate2D, to segment: Segment) -> Double {
        let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var best = Double.infinity
        var previous: CLLocationCoordinate2D?
        for c in segment.coordinates {
            best = min(best, here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)))
            if let p = previous {
                let mid = CLLocation(latitude: (p.latitude + c.latitude) / 2, longitude: (p.longitude + c.longitude) / 2)
                best = min(best, here.distance(from: mid))
            }
            previous = c
        }
        return best
    }

    /// "6 free curbs within 2 blocks" (singular for 1).
    nonisolated static func headline(_ result: WPFreeCurbCount) -> String {
        switch result.count {
        case 0: return "No free curbs within 2 blocks"
        case 1: return "free curb within 2 blocks"
        default: return "free curbs within 2 blocks"
        }
    }

    /// "from now until 7 AM tomorrow".
    nonisolated static func windowLine(goal: ParkingGoal, end: Date, now: Date) -> String {
        "from now until " + WPCurbCopy.midnightized(ParkingGoals.nonBreakingMeridiem(
            ParkingGoals.windowEndLabel(for: goal, end: end, from: now)
        ))
    }

    /// "The nearest is 0.2 mi away." (real distance, not blocks.)
    nonisolated static func nearestLine(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 1000 { return "The nearest is \(Int((feet / 10).rounded()) * 10) ft away." }
        return "The nearest is " + String(format: "%.1f", meters / 1609.344) + " mi away."
    }
}

// MARK: - Drag feedback (B6.2, B6.3)

/// What the label on the dragged token says about the curb under it.
struct WPDragBubble: Equatable {
    enum Tone: Equatable { case park, soon, dont }
    let tone: Tone
    /// "Park" / "No parking" / "Free until" ...
    let headline: String
    /// "Free until Mon 9:00 AM" / "Street cleaning at 7 AM tomorrow".
    let detail: String
    /// Bottom-sheet line: "Let go to place your car" / "You can't park here overnight".
    let hint: String

    nonisolated static func make(from model: WPCurbSheetModel, windowName: String?) -> WPDragBubble {
        switch model.variant {
        case .park, .planpark:
            return WPDragBubble(
                tone: .park, headline: "Park", detail: model.freeLine, hint: "Let go to place your car"
            )
        case .soon where !model.bigIsTime:
            return WPDragBubble(
                tone: .soon, headline: model.big, detail: "Check the meter hours",
                hint: "Let go to place your car"
            )
        case .soon:
            return WPDragBubble(
                tone: .soon, headline: "Free until \(model.big)", detail: "Then you'd have to move",
                hint: "Let go to place your car"
            )
        case .meter:
            return WPDragBubble(
                tone: .dont, headline: "Metered", detail: "Pay until \(model.big)", hint: "Keep dragging, or let go to mark it anyway."
            )
        case .nodata:
            return WPDragBubble(
                tone: .dont, headline: NoSignData.headline, detail: "Read the posted signs",
                hint: "Keep dragging, or let go to mark it anyway."
            )
        case .unclear:
            return WPDragBubble(
                tone: .dont, headline: "Unclear sign", detail: "Check the posted sign",
                hint: "Keep dragging, or let go to mark it anyway."
            )
        case .dont, .plandont:
            return WPDragBubble(
                tone: .dont, headline: model.big, detail: model.sub ?? "",
                hint: "Keep dragging, or let go to mark it anyway."
            )
        }
    }
}

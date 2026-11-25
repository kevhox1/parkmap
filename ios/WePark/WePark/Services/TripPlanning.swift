//
//  TripPlanning.swift
//  WePark
//
//  Plan a Trip (docs/specs/goals-rework.md section 3): a future what-if window
//  [arrival, departure] evaluated with the SAME one free rule as every live goal
//  (`ParkingRulesEngine.isFree(..., ignoringMeteredPayment: false)`), plus validation,
//  quick picks, banner copy and the per-curb verdict ("Free for your whole trip" or the
//  first reason it is not).
//
//  Pure Foundation. No SwiftUI. Calendar.easternTime only.
//
//  ASP calendar coverage: the bundled suspension calendar covers one calendar year. Dates
//  outside it have no suspensions, so `isFree` already treats street cleaning as in effect
//  (the safe side, red); `calendarCovers` only drives the user-facing notice.
//

import Foundation

// MARK: - TripPlan

/// A planned visit. Never read by the drive card, voice, or Start Driving: it lives only in
/// `ContentView.tripPlan` and the trip overlay branch of `rebuildOverlays`.
nonisolated struct TripPlan: Equatable {
    let arrival: Date
    let departure: Date
}

// MARK: - Validation

nonisolated enum TripPlanValidation: Equatable {
    case valid
    case arrivalInPast
    case departureNotAfterArrival
    case tooLong

    /// Inline message for the planner sheet; `nil` when valid.
    var message: String? {
        switch self {
        case .valid: return nil
        case .arrivalInPast: return "Arrival can't be in the past. Use Now for a live search."
        case .departureNotAfterArrival: return "Departure must be after arrival."
        case .tooLong: return "Trips can be up to 7 days."
        }
    }
}

// MARK: - Quick picks

nonisolated enum TripQuickPick: CaseIterable {
    case todayEvening
    case tomorrow
    case thisWeekend

    var title: String {
        switch self {
        case .todayEvening: return "Today 5 PM → 10 PM"
        case .tomorrow: return "Tomorrow"
        case .thisWeekend: return "This weekend"
        }
    }

    var subtitle: String {
        switch self {
        case .todayEvening: return "An evening out"
        case .tomorrow: return "9 AM → 6 PM"
        case .thisWeekend: return "Sat 10 AM → Sun 6 PM"
        }
    }
}

// MARK: - Verdict

nonisolated enum TripVerdict: Equatable {
    case free
    /// `reason` reads as "street cleaning Sat 11/28 11:00 AM–12:30 PM".
    case notFree(reason: String)

    var isFree: Bool {
        if case .free = self { return true }
        return false
    }

    /// Curb-tap headline.
    var headline: String {
        switch self {
        case .free: return "Free for your whole trip"
        case .notFree(let reason): return "Not free: \(reason)"
        }
    }
}

// MARK: - TripPlanning

nonisolated enum TripPlanning {

    /// Spec section 3: cap at 7 days.
    static let maxDuration: TimeInterval = 7 * 24 * 3600

    /// Allowed arrival slop so a picker set to "now" a few seconds ago still validates.
    static let arrivalGrace: TimeInterval = 120

    static let caveat = "Rules can change (film shoots, construction, holidays). Check the signs when you arrive."

    static let calendarUnavailableNotice =
        "Street-cleaning calendar not available for these dates yet. Treating street cleaning as in effect."

    static let plannerPrompt = "Coming into the city? See where you can park for your visit."

    // MARK: Validation

    static func validate(arrival: Date, departure: Date, now: Date = .nowET) -> TripPlanValidation {
        if arrival < now.addingTimeInterval(-arrivalGrace) { return .arrivalInPast }
        if departure <= arrival { return .departureNotAfterArrival }
        if departure.timeIntervalSince(arrival) > maxDuration { return .tooLong }
        return .valid
    }

    // MARK: Quick picks

    /// Resolves a quick pick relative to `now` (ET). `nil` when the pick has already passed
    /// (e.g. "Today 5 PM -> 10 PM" at 11 PM).
    static func quickPick(_ pick: TripQuickPick, now: Date = .nowET) -> TripPlan? {
        switch pick {
        case .todayEvening:
            guard let five = time(hour: 17, dayOffset: 0, from: now),
                  let ten = time(hour: 22, dayOffset: 0, from: now), ten > now else { return nil }
            return TripPlan(arrival: max(five, now), departure: ten)
        case .tomorrow:
            guard let nine = time(hour: 9, dayOffset: 1, from: now),
                  let six = time(hour: 18, dayOffset: 1, from: now) else { return nil }
            return TripPlan(arrival: nine, departure: six)
        case .thisWeekend:
            let dow = now.dayOfWeekET  // 0 = Sunday ... 6 = Saturday
            // Saturday offsets to try, nearest first. On Sunday, "this weekend's" Saturday was yesterday.
            let firstSaturday = dow == 0 ? -1 : 6 - dow
            for offset in [firstSaturday, firstSaturday + 7] {
                guard let sat = time(hour: 10, dayOffset: offset, from: now),
                      let sun = time(hour: 18, dayOffset: offset + 1, from: now), sun > now else { continue }
                return TripPlan(arrival: max(sat, now), departure: sun)
            }
            return nil
        }
    }

    private static func time(hour: Int, dayOffset: Int, from: Date) -> Date? {
        let day = from.startOfDayET(offsetDays: dayOffset)
        return Calendar.easternTime.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    // MARK: Copy

    /// "Sat 11/28 10:00 AM → Sun 11/29 6:00 PM"
    static func windowLabel(for plan: TripPlan) -> String {
        "\(stamp(plan.arrival)) → \(stamp(plan.departure))"
    }

    /// Banner line: "TRIP PLAN" is the banner's own title; this is the rest.
    static func bannerLine(for plan: TripPlan) -> String {
        "\(displayWindowLabel(for: plan)) · not live"
    }

    /// `windowLabel` with non-breaking spaces inside each stamp, and between the arrow and the
    /// departure, so a narrow (AX5) line can only wrap before the arrow, never mid-time.
    static func displayWindowLabel(for plan: TripPlan) -> String {
        "\(nonBreaking(stamp(plan.arrival))) →\u{00A0}\(nonBreaking(stamp(plan.departure)))"
    }

    static func nonBreaking(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// "Sat 11/28 10:00 AM"
    static func stamp(_ date: Date) -> String {
        "\(ParkingGoals.weekdayDateLabel(for: date)) \(ParkingGoals.clockTimeLabel(for: date))"
    }

    // MARK: ASP calendar coverage

    /// Whether the bundled street-cleaning suspension calendar covers every day of the trip.
    static func calendarCovers(_ plan: TripPlan, service: ASPSuspensionService) -> Bool {
        service.calendarCovers(plan.arrival) && service.calendarCovers(plan.departure)
    }

    // MARK: Evaluation

    /// The one free rule for the whole trip window. Same call every live goal makes.
    static func isFree(segment: Segment, plan: TripPlan, engine: ParkingRulesEngine) -> Bool {
        engine.isFree(
            segment: segment, from: plan.arrival, until: plan.departure, ignoringMeteredPayment: false
        )
    }

    /// Verdict for one curb. Agrees with `isFree` by construction (free iff `isFree`), and names
    /// the EARLIEST single rule that breaks the trip when it is not.
    static func verdict(segment: Segment, plan: TripPlan, engine: ParkingRulesEngine) -> TripVerdict {
        if isFree(segment: segment, plan: plan, engine: engine) { return .free }

        var earliest: (start: Date, text: String)?
        for rule in segment.rules {
            let single = Segment(
                id: segment.id, street: segment.street, fromStreet: segment.fromStreet,
                to: segment.to, side: segment.side, line: segment.line,
                rules: [rule], dominantCategory: rule.category
            )
            guard !isFree(segment: single, plan: plan, engine: engine),
                  let span = firstConflict(of: single, plan: plan, engine: engine) else { continue }
            let text = reasonText(rule: rule, span: span, plan: plan)
            if earliest == nil || span.start < earliest!.start {
                earliest = (span.start, text)
            }
        }
        return .notFree(reason: earliest?.text ?? "a rule applies during your trip")
    }

    // MARK: Conflict search

    /// Slice boundaries: arrival, every clock quarter-hour in between, departure.
    private static func boundaries(for plan: TripPlan) -> [Date] {
        var result: [Date] = [plan.arrival]
        let quarter: TimeInterval = 15 * 60
        var tick = (plan.arrival.timeIntervalSinceReferenceDate / quarter).rounded(.down) * quarter + quarter
        while tick < plan.departure.timeIntervalSinceReferenceDate {
            result.append(Date(timeIntervalSinceReferenceDate: tick))
            tick += quarter
        }
        result.append(plan.departure)
        return result
    }

    /// First contiguous run of conflicting slices (15-minute resolution, aligned to the clock
    /// so typical sweep boundaries like 11:00 / 12:30 are exact).
    private static func firstConflict(
        of segment: Segment, plan: TripPlan, engine: ParkingRulesEngine
    ) -> (start: Date, end: Date)? {
        let points = boundaries(for: plan)
        var start: Date?
        for index in 0..<(points.count - 1) {
            let free = engine.isFree(
                segment: segment, from: points[index], until: points[index + 1],
                ignoringMeteredPayment: false
            )
            if !free, start == nil { start = points[index] }
            if free, let begun = start { return (begun, points[index]) }
        }
        if let begun = start { return (begun, plan.departure) }
        return nil
    }

    private static func reasonText(rule: ParkingRule, span: (start: Date, end: Date), plan: TripPlan) -> String {
        let name: String
        switch rule.category {
        case .aspMonThu, .aspTueFri, .aspOvernightMWF, .aspOvernightTTHS, .aspDaily:
            name = "street cleaning"
        case .noParking: name = "no parking"
        case .noStanding: name = "no standing"
        case .truckLoading: name = "truck loading zone"
        case .special: name = "special restriction"
        case .metered: name = "meter running"
        case .free, .unknown: name = "a restriction"
        }
        // Whole trip covered (e.g. anytime rules): no time range to quote.
        if span.start <= plan.arrival && span.end >= plan.departure {
            return "\(name) the whole trip"
        }
        let startLabel = stamp(span.start)
        let endLabel: String
        if Calendar.easternTime.isDate(span.start, inSameDayAs: span.end)
            || span.end == Calendar.easternTime.startOfDay(for: span.end) {
            endLabel = ParkingGoals.clockTimeLabel(for: span.end)
        } else {
            endLabel = stamp(span.end)
        }
        return "\(name) \(startLabel)–\(endLabel)"
    }
}

// MARK: - TripModeGating

/// Pure rules for what the live UI shows while a trip plan is active. A trip plan is a what-if,
/// so live actions (Park here, Report, long-press park) and the live ASP banner are hidden;
/// exiting the plan restores them.
enum TripModeGating {
    nonisolated static func showsLiveActions(tripActive: Bool) -> Bool { !tripActive }
    /// Live-only block-sheet content: sweeper badge, temporary restrictions, live pins, chatter.
    nonisolated static func showsLiveBlockContent(tripActive: Bool) -> Bool { !tripActive }
    nonisolated static func showsLiveASPBanner(tripActive: Bool) -> Bool { !tripActive }
    /// Spot Pass (asking a neighbor for their live spot, or an armed hand-off) is a live-parking
    /// flow, so its More rows are hidden during a trip plan.
    nonisolated static func showsSpotPass(tripActive: Bool) -> Bool { !tripActive }
    /// The floating Report pill (and its tap handler) is a live action.
    nonisolated static func showsReportPill(tripActive: Bool) -> Bool { !tripActive }
    /// Live wins: a Spot Pass seeker push the user opened, or the parked-car reminder deep link,
    /// concerns the real present, so the trip plan is closed (with this toast) before either shows.
    nonisolated static let planClosedToast = "Trip plan closed"
}

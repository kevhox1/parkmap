//
//  WPMyCarLogic.swift
//  WePark
//
//  Stoop Phase 4 (B7 My Car). Pure, unit-testable logic behind `Views/WPMyCarV2View.swift`, shown
//  only while `AppConstants.designSystemV2Enabled && AppConstants.myCarSheetV2Enabled`.
//
//  The one question this screen answers is "am I OK, and until when?". Rules in force
//  (DECISIONS.md accuracy adjustments, Kevin's overriding rule: never a false parking statement):
//    - The verdict is `WPNeighborVerdict.resolve` with NO search window, the same call the
//      parked-car callout on the map uses, so the two always agree. A neighbor report can only
//      make it stricter. Every time comes from `ParkingRulesEngine`; midnight is "midnight".
//    - Unclear, no-data and unknown curbs are never "Legal". They say "Check the posted sign" /
//      "No sign data".
//    - No sub-curb precision: sign lines come from `WPSignList` (arrow signs read "applies near
//      the corner"). Nothing here says "first 20 ft" or "your car is past it".
//    - Reminder options are the one shared set (DECISIONS #8): 15 min, 30 min, 1 hr, 2 hr and
//      "the night before", wired to the existing `ReminderOffsets` and `NotificationScheduler`.
//      The previews here mirror the scheduler's arithmetic exactly (restriction start minus the
//      lead; 8 PM ET the evening before), and only count reminders that are still in the future.
//    - The scheduler reminds about the next NON-METER restriction (`engine.nextRestriction`). The
//      reminder UI offers exactly that and nothing else: no "free again" or "meter limit" promise.
//

import Foundation
import UserNotifications

// MARK: - Verdict

/// What the My Car screen says about the curb under the parked car.
struct WPMyCarVerdict: Equatable {
    var variant: WPCurbVariant
    /// Over-line ("Legal until", "Move by", "Move your car now", "We don't know", ...).
    var over: String
    /// The answer: a clock time ("Mon 11/30 9:00 AM") or a short statement ("No parking").
    var big: String
    var sub: String?
    /// Legal only: 0...1 portion of the 7 day look-ahead still left (the bar).
    var fractionLeft: Double?
    /// Start of the next non-meter restriction (the reminders' anchor); nil when none is coming
    /// inside the look-ahead, or one is in force now.
    var restrictionStart: Date?
    /// Plain name of that restriction ("street cleaning").
    var restrictionName: String?

    /// Only a legal verdict (green or amber) may ever read "Legal". Everything else is a don't,
    /// a meter, or "we don't know".
    var isLegalNow: Bool { variant == .park || variant == .soon }

    /// Reminders apply only to a curb with a future non-meter restriction we can actually read.
    var offersReminders: Bool {
        guard restrictionStart != nil else { return false }
        switch variant {
        case .park, .soon, .meter: return true
        case .dont, .nodata, .unclear, .planpark, .plandont: return false
        }
    }

    /// "I left" normally; "I moved it" when the car is in a don't right now.
    var primaryTitle: String { variant == .dont ? "I moved it" : "I left" }
}

enum WPMyCarLogic {

    // MARK: Verdict

    /// - Parameter segment: the curb under the car; nil when the car has no matched curb.
    nonisolated static func verdict(
        segment: Segment?,
        engine: ParkingRulesEngine,
        now: Date,
        reports: WPNeighborReports = WPNeighborReports()
    ) -> WPMyCarVerdict {
        guard let segment else {
            return WPMyCarVerdict(
                variant: .nodata, over: NoSignData.overline, big: NoSignData.headline,
                sub: "We have no parking data at this spot. " + NoSignData.subline
            )
        }
        let model = WPNeighborVerdict.resolve(
            segment: segment, engine: engine, now: now, windowEnd: nil, trip: nil, reports: reports
        )
        let next = engine.nextRestriction(for: segment, at: now)
        let hasFutureRestriction = !next.isUnrestricted && !next.isActiveNow && next.hours < WPCurbSheetBuilder.lookAheadHours
        let start = hasFutureRestriction ? now.addingTimeInterval(next.hours * 3600) : nil
        let name = hasFutureRestriction ? WPCurbCopy.restrictionName(next.category) : nil

        var out = WPMyCarVerdict(
            variant: model.variant, over: model.over, big: model.big, sub: model.sub,
            fractionLeft: nil, restrictionStart: start, restrictionName: name
        )

        switch model.variant {
        case .park:
            if model.isOpenEnded {
                out.over = "Legal for"
            } else {
                out.over = "Legal until"
                out.big = short(model.big)
            }
            out.fractionLeft = model.fractionLeft
        case .soon:
            if model.bigIsTime {
                // A meter that starts first is "pay from", not "move by": the car is legal, it
                // just starts costing money.
                let meterAt = WPCurbVerdict.hasMeterRule(segment)
                    ? WPCurbCopy.nextMeterStart(segment: segment, engine: engine, from: now) : nil
                let meterFirst: Bool = {
                    guard let meterAt else { return false }
                    guard let start else { return true }
                    return meterAt < start
                }()
                if meterFirst, let meterAt {
                    out.over = "Meter starts"
                    out.big = short(WPCurbCopy.when(meterAt, now: now))
                } else {
                    out.over = "Move by"
                    out.big = short(model.big)
                }
            } else {
                out.over = "Legal now"
                out.big = "Meter on this curb"
                out.sub = "Check the signs for the meter hours."
            }
        case .dont:
            // A neighbor report already wrote its own over-line ("Neighbors say").
            if model.over == "Right now" { out.over = "Move your car now" }
            // "until Today 10:30 AM" reads wrong on the car screen: "until 10:30 AM".
            out.sub = model.sub?.replacingOccurrences(of: " until Today ", with: " until ")
        case .meter:
            out.over = "Pay the meter until"
            out.big = short(model.big)
        case .nodata, .unclear, .planpark, .plandont:
            break
        }
        return out
    }

    /// "Today 9:00 AM" -> "9:00 AM", "Today midnight" -> "midnight". Other days keep their label
    /// ("Tomorrow 7:00 AM", "Mon 11/30 9:00 AM").
    nonisolated static func short(_ whenText: String) -> String {
        whenText.hasPrefix("Today ") ? String(whenText.dropFirst("Today ".count)) : whenText
    }

    // MARK: Header lines

    /// "In front of 50 E 1st St" when there is an address; else "On E 1st St" (street known) or
    /// "My car". An approximate address stays "Near ..." (`ParkingAddressCopy.line`).
    nonisolated static func title(addressLine: String?, street: String?) -> String {
        if let addressLine, !addressLine.isEmpty { return addressLine }
        if let street, !street.isEmpty { return "On \(street)" }
        return "My car"
    }

    /// "Parked just now" / "Parked 12 min ago" / "Parked 3 h ago" / "Parked 2 days ago".
    nonisolated static func parkedLine(parkedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(parkedAt))
        if seconds < 60 { return "Parked just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Parked \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Parked \(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "Parked 1 day ago" : "Parked \(days) days ago"
    }

    // MARK: Leaving soon

    /// The "Leaving soon?" card (Tell neighbors / Spot Pass) shows whenever the leave flow offers a
    /// sheet, for EVERY verdict. `.dont` included: a driver who must move now is exactly the person
    /// leaving a spot (the V2 sheet always showed it). Deliberately takes no verdict: the card is
    /// not a function of the verdict.
    nonisolated static func showsLeavingSoonCard(leaveOpensSheet: Bool) -> Bool {
        leaveOpensSheet
    }

    // MARK: Street cleaning suspension

    /// A suspended-street-cleaning note, only when it truly applies to this curb: the segment has a
    /// street-cleaning rule that would have run on the suspended day. Nil otherwise.
    ///
    /// Kevin's rule (never a contradictory parking statement): the affirmative "You don't have to
    /// move the car" is said only when the verdict backs it, that is when the car is legal with
    /// nothing else to move for (`.park`) or just a meter (`.meter`). With any other verdict
    /// ("Move your car now", "Move by", unclear, no data) the note is neutral and makes no claim
    /// about moving.
    nonisolated static func suspensionNote(
        segment: Segment?, state: SuspensionBannerState, now: Date, variant: WPCurbVariant
    ) -> String? {
        let backsNoMove = variant == .park || variant == .meter
        guard let segment else { return nil }
        let asp = segment.rules.filter { $0.category.isASP }
        guard !asp.isEmpty else { return nil }
        func runs(on weekday: Int) -> Bool {
            asp.contains { rule in
                rule.days.isEmpty ? rule.category.isASPDay(weekday) : rule.days.contains(weekday)
            }
        }
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch state {
        case .aspInEffect:
            return nil
        case .todaySuspended(let reason):
            guard runs(on: now.dayOfWeekET) else { return nil }
            return backsNoMove
                ? "Street cleaning is suspended today for \(reason). You don't have to move the car."
                : "Street cleaning is suspended today for \(reason)."
        case .tomorrowSuspended(let reason):
            let weekday = (now.dayOfWeekET + 1) % 7
            guard runs(on: weekday) else { return nil }
            return backsNoMove
                ? "Street cleaning is suspended tomorrow for \(reason). You don't have to move the car \(days[weekday])."
                : "Street cleaning is suspended tomorrow for \(reason)."
        }
    }

    // MARK: Reminders

    /// Whether a scheduled reminder can actually reach the driver. The scheduler silently returns
    /// when the in-app mute is on (`AppConstants.notificationsMutedKey`) and iOS drops anything when
    /// permission is denied, so the screen must not promise reminders in those cases.
    enum NotificationAvailability: Equatable {
        case on
        case mutedInApp
        case deniedInSystem
        /// The system permission has not been read yet. Promises nothing until the real status
        /// arrives (a frame or two), so a denied phone never flashes "You'll get N reminders".
        case unknown

        /// `status` nil means "not read yet": do NOT assume on.
        nonisolated static func resolve(muted: Bool, status: UNAuthorizationStatus?) -> NotificationAvailability {
            if muted { return .mutedInApp }
            guard let status else { return .unknown }
            if status == .denied { return .deniedInSystem }
            return .on
        }

        /// The honest line for the off cases; nil when notifications are on.
        nonisolated var offLine: String? {
            switch self {
            case .on: return nil
            case .mutedInApp: return "Notifications are muted in WePark, so no reminders will be sent."
            case .deniedInSystem: return "Notifications are off for WePark in Settings, so no reminders will be sent."
            case .unknown: return "Checking whether notifications are on."
            }
        }
    }

    enum ReminderKind: Equatable {
        case minutes15, minutes30, hour1, hours2, nightBefore
    }

    struct ReminderPreview: Equatable {
        let kind: ReminderKind
        let fireDate: Date
    }

    /// The reminders the scheduler WOULD enqueue for `restrictionStart` with these options, soonest
    /// first. Same arithmetic as `NotificationScheduler.enqueuePresets`: start minus the lead, and
    /// 8 PM ET (`AppConstants.nightBeforeHourET`) the calendar evening before. A reminder whose
    /// time has already passed is skipped (the scheduler skips it too).
    nonisolated static func reminderPreviews(
        offsets: ReminderOffsets, restrictionStart: Date, now: Date
    ) -> [ReminderPreview] {
        var all: [ReminderPreview] = []
        if offsets.remind15Min { all.append(.init(kind: .minutes15, fireDate: restrictionStart.addingTimeInterval(-900))) }
        if offsets.remind30Min { all.append(.init(kind: .minutes30, fireDate: restrictionStart.addingTimeInterval(-1800))) }
        if offsets.remind1Hour { all.append(.init(kind: .hour1, fireDate: restrictionStart.addingTimeInterval(-3600))) }
        if offsets.remind2Hours { all.append(.init(kind: .hours2, fireDate: restrictionStart.addingTimeInterval(-7200))) }
        if offsets.remindNightBefore, let night = nightBeforeDate(relativeTo: restrictionStart) {
            all.append(.init(kind: .nightBefore, fireDate: night))
        }
        return all.filter { $0.fireDate > now }.sorted { $0.fireDate < $1.fireDate }
    }

    /// 8 PM ET on the calendar evening before the restriction day (wall clock, DST-safe).
    nonisolated static func nightBeforeDate(relativeTo restrictionStart: Date) -> Date? {
        let cal = Calendar.easternTime
        guard let prior = cal.date(byAdding: .day, value: -1, to: restrictionStart) else { return nil }
        return cal.date(bySettingHour: AppConstants.nightBeforeHourET, minute: 0, second: 0, of: prior)
    }

    /// "Next one: 6:30 AM" / "Next one: Sun 11/29 8:00 PM", or nil when nothing is left to fire.
    nonisolated static func nextReminderLine(previews: [ReminderPreview], now: Date) -> String? {
        guard let first = previews.first else { return nil }
        return "Next one: \(short(WPCurbCopy.when(first.fireDate, now: now)))"
    }

    /// "You'll get 2 reminders: Sun 8:00 PM and Mon 8:00 AM." / "You'll get 1 reminder: ...".
    /// Honest when nothing is left: no reminder is promised that cannot fire.
    nonisolated static func reminderSummary(
        previews: [ReminderPreview], now: Date, availability: NotificationAvailability = .on
    ) -> String {
        if let off = availability.offLine { return off }
        guard !previews.isEmpty else {
            return "No reminder is left before this changes. Pick a different time or leave it off."
        }
        let times = previews.map { short(WPCurbCopy.when($0.fireDate, now: now)) }
        let list: String
        switch times.count {
        case 1: list = times[0]
        case 2: list = "\(times[0]) and \(times[1])"
        default: list = times.dropLast().joined(separator: ", ") + ", and " + (times.last ?? "")
        }
        return "You'll get \(times.count) reminder\(times.count == 1 ? "" : "s"): \(list)."
    }

    /// The row's second line: the next reminder time, or "Off".
    nonisolated static func reminderRowSub(
        remindMe: Bool, previews: [ReminderPreview], now: Date, availability: NotificationAvailability = .on
    ) -> String {
        guard remindMe else { return "Off" }
        if availability == .unknown { return "Checking notifications" }
        if availability != .on { return "Notifications are off" }
        return nextReminderLine(previews: previews, now: now) ?? "No reminder time left before it changes"
    }

    /// "Street cleaning starts Mon 11/30 9:00 AM." for the reminders sheet.
    nonisolated static func startsLine(name: String?, start: Date, now: Date) -> String {
        let what = WPCurbCopy.capitalized(name ?? "A restriction")
        return "\(what) starts \(short(WPCurbCopy.when(start, now: now)))."
    }
}

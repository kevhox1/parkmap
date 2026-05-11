//
//  Date+ET.swift
//  WePark
//
//  All parking rules logic must run in America/New_York time regardless of
//  where the user's device is currently located. A user in LA checking NYC
//  parking still wants NYC-time answers.
//
//  PWA equivalents:
//    nowET()        → index.html:1668
//    toETDateStr(d) → index.html:1671
//
//  Spec note (R4 in docs/ios-mvp-spec.md §7): notifications are scheduled
//  using absolute Unix time computed via the ET calendar so they fire at the
//  correct NYC moment regardless of device time zone.
//

import Foundation

// MARK: - TimeZone convenience

extension TimeZone {
    /// America/New_York. Force-unwrapped because the identifier is a compile-time
    /// constant and will never be nil.
    static let easternTime = TimeZone(identifier: "America/New_York")!
}

// MARK: - Calendar convenience

extension Calendar {
    /// Gregorian calendar configured for Eastern Time.
    /// Use this for all day-of-week / hour-of-day / minute-of-day computations
    /// in the parking rules engine.
    static let easternTime: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.easternTime
        return cal
    }()
}

// MARK: - Date helpers

extension Date {
    /// Returns the current date and time as a `Date`.
    /// The `Date` itself is TZ-neutral (it represents an absolute UTC instant).
    /// All computations derived from it must use `Calendar.easternTime` so that
    /// day-of-week, hour, and minute values reflect New York local time.
    ///
    /// PWA equivalent: nowET() at index.html:1668
    /// Note: the PWA constructs a NEW Date from the ET locale string so that
    /// `.getDay()`, `.getHours()`, etc. return ET values on the JS object.
    /// In Swift we don't need that trick — the Date is TZ-neutral; we use
    /// Calendar.easternTime.component(...) instead.
    static var nowET: Date { Date() }

    /// Returns "yyyy-MM-dd" representation in America/New_York time.
    /// PWA equivalent: toETDateStr(d) at index.html:1671
    func toETDateString() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = .easternTime
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }

    /// Minute of day in Eastern Time (0 = midnight, 1439 = 11:59pm).
    /// Used by the rules engine for time-range comparisons.
    var minuteOfDayET: Int {
        let comps = Calendar.easternTime.dateComponents([.hour, .minute], from: self)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Day of week in Eastern Time (0 = Sunday … 6 = Saturday).
    /// Matches the JS Date.getDay() convention used throughout the PWA.
    var dayOfWeekET: Int {
        // Calendar weekday: 1=Sunday … 7=Saturday → subtract 1 to get 0-based
        let comps = Calendar.easternTime.dateComponents([.weekday], from: self)
        return (comps.weekday ?? 1) - 1
    }

    /// Returns midnight (00:00:00 ET) of the date that is `offsetDays` from
    /// the ET midnight of this Date. Used by computeHoursUntilASP to construct
    /// check dates for the 14-day walker.
    func startOfDayET(offsetDays: Int = 0) -> Date {
        let cal = Calendar.easternTime
        let startOfToday = cal.startOfDay(for: self)
        if offsetDays == 0 { return startOfToday }
        return cal.date(byAdding: .day, value: offsetDays, to: startOfToday) ?? startOfToday
    }
}

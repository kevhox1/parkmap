//
//  SpotPassCountdown.swift
//  Models/SpotPass
//
//  Spot Pass C1: the seeker's two clocks (spec §3, §9 item 2; design §9.3, F4).
//    - The UNCLAIMED pass TTL (20 min) is shown as mm:ss. It is the seeker's own pass.
//    - AFTER a neighbor arms the pass the seeker sees ONLY a coarse band ("about 30 min"), never a
//      clock time and never mm:ss to the driver's departure (safety: the seeker must not learn when
//      the person is actually at the car).
//

import Foundation

nonisolated enum SpotPassBand: Equatable, Sendable {
    case aboutAnHour
    /// Whole minutes, already rounded for display (10...50).
    case about(minutes: Int)
    case anyMinuteNow
    /// After `leave_at`, inside the grace window. Deliberately NOT "late"/"delayed" (no pressure signal).
    case shouldBeHeadingOut
    case ended

    /// Design §9.3 line 2.
    var line: String {
        switch self {
        case .aboutAnHour: return "Leaving in about an hour."
        case .about(let minutes): return "Leaving in about \(minutes) min."
        case .anyMinuteNow: return "Leaving any minute now."
        case .shouldBeHeadingOut: return "Should be heading out soon."
        case .ended: return "Pass ended."
        }
    }

    /// Spoken form for VoiceOver announcements (no abbreviations).
    var spokenLine: String {
        switch self {
        case .aboutAnHour: return "Leaving in about an hour."
        case .about(let minutes): return "Leaving in about \(minutes) minutes."
        case .anyMinuteNow: return "Leaving any minute now."
        case .shouldBeHeadingOut: return "Should be heading out soon."
        case .ended: return "Pass ended."
        }
    }
}

nonisolated enum SpotPassCountdown {

    /// `HANDOFF_GRACE_MIN` (spec §3): `expires_at = leave_at + 15 min`.
    static let graceMinutes: Double = 15

    /// An armed pass ends at the server's `expires_at` when known, else `leave_at + grace`.
    static func endDate(leaveAt: Date, expiresAt: Date?) -> Date {
        expiresAt ?? leaveAt.addingTimeInterval(graceMinutes * 60)
    }

    /// Design §9.3 table.
    ///   more than 55 min     -> about an hour
    ///   45...55 min          -> about 50 min
    ///   above 10 min         -> nearest 5 min (so 12 -> 10, 13 -> 15, 44 -> 45)
    ///   above 5, up to 10    -> about 10 min
    ///   5 min or less        -> any minute now
    ///   after leave_at       -> should be heading out soon, until the end date, then ended
    static func band(leaveAt: Date, expiresAt: Date?, now: Date) -> SpotPassBand {
        if now >= endDate(leaveAt: leaveAt, expiresAt: expiresAt) { return .ended }
        let minutes = leaveAt.timeIntervalSince(now) / 60
        if minutes <= 0 { return .shouldBeHeadingOut }
        if minutes <= 5 { return .anyMinuteNow }
        if minutes <= 10 { return .about(minutes: 10) }
        if minutes < 45 {
            let rounded = Int((minutes / 5).rounded()) * 5
            return .about(minutes: max(10, rounded))
        }
        if minutes <= 55 { return .about(minutes: 50) }
        return .aboutAnHour
    }

    // MARK: - Unclaimed TTL (seeker's own pass)

    static func remaining(until expiresAt: Date, now: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    /// "19:42". Floors, never shows a negative.
    static func clockString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Design §2.9: "Good for 19 minutes 42 seconds."
    static func spokenString(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        let minuteWord = minutes == 1 ? "minute" : "minutes"
        let secondWord = secs == 1 ? "second" : "seconds"
        if minutes == 0 { return "\(secs) \(secondWord)" }
        return "\(minutes) \(minuteWord) \(secs) \(secondWord)"
    }

    /// Design §2.5: under 2 minutes the sub line becomes "Ends in 1:12".
    static func isEnding(_ seconds: TimeInterval) -> Bool { seconds < 120 }

    /// A `ClosedRange<Date>` that cannot trap (`lower > upper` is a fatal error for ranges).
    static func safeRange(from start: Date, to end: Date) -> ClosedRange<Date> {
        start...max(start, end)
    }
}

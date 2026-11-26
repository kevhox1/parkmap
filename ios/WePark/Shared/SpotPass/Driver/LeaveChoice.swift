//
//  LeaveChoice.swift
//  Shared/SpotPass/Driver
//
//  The driver's "When are you leaving?" chips and the `leave_at` they produce
//  (spec section 3 "Leaving time", design section 3.3). Pure.
//
//  Server rules this must satisfy (`public.handoff_claim`): `leave_at` within [now - 10 min,
//  now + 240 min 30 s] or the call fails with `invalid_leave_at`; the server rounds to the nearest
//  5 minutes and clamps to `floor5(now + 240 min)`. The client therefore rounds presets to the
//  nearest 5 minutes and caps everything at `latest(from:)`: a FLOOR to 5 minutes with a 60 s
//  guard, so a clock running a few seconds ahead of the server's can never exceed the horizon.
//

import Foundation

nonisolated enum LeaveChoice: Equatable, Sendable {
    case now
    case minutes(Int)       // 10, 30, 60
    case custom(Date)       // "Pick a time"

    /// The preset chips, in display order. "Pick a time" is the fifth chip.
    static let presets: [LeaveChoice] = [.now, .minutes(10), .minutes(30), .minutes(60)]

    /// "~10 min" is preselected (spec section 6.1 beat 1).
    static let `default`: LeaveChoice = .minutes(10)

    /// Spec section 0 decision 4: `HANDOFF_MAX_HORIZON_MIN`.
    static let maxHorizonMinutes = 240

    static let roundingSeconds: TimeInterval = 300

    var isNow: Bool {
        if case .now = self { return true }
        return false
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The latest leave time the client will ever send for a request made at `now`.
    static func latest(from now: Date) -> Date {
        floorToFiveMinutes(now.addingTimeInterval(Double(maxHorizonMinutes) * 60 - 60))
    }

    /// The `leave_at` to send at `now`. Always within `[now, latest(from: now)]`.
    func leaveAt(from now: Date) -> Date {
        let ceiling = Self.latest(from: now)
        switch self {
        case .now:
            return now
        case .minutes(let minutes):
            let target = now.addingTimeInterval(Double(max(0, minutes)) * 60)
            return min(max(Self.roundToFiveMinutes(target), now), ceiling)
        case .custom(let picked):
            let low = max(picked, now)
            // Rounding to the NEAREST 5 min can land up to 2.5 min before `now`: never send a past time.
            return min(max(Self.roundToFiveMinutes(low), now), ceiling)
        }
    }

    static func roundToFiveMinutes(_ date: Date) -> Date {
        let t = (date.timeIntervalSince1970 / roundingSeconds).rounded() * roundingSeconds
        return Date(timeIntervalSince1970: t)
    }

    static func floorToFiveMinutes(_ date: Date) -> Date {
        let t = (date.timeIntervalSince1970 / roundingSeconds).rounded(.down) * roundingSeconds
        return Date(timeIntervalSince1970: t)
    }

    /// The range the "Pick a time" wheel offers: now ... now + 4 h (design section 3.3).
    static func pickableRange(from now: Date) -> ClosedRange<Date> {
        now...now.addingTimeInterval(Double(maxHorizonMinutes) * 60)
    }
}

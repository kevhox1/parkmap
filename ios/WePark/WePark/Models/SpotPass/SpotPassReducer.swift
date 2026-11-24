//
//  SpotPassReducer.swift
//  Models/SpotPass
//
//  Spot Pass C1: the pure seeker state machine (spec §3, design §2.5 / §9). One function maps
//  (current phase, latest server snapshot, now) to the next phase, so the same rules serve a poll
//  result, a push-triggered refresh, a restore after relaunch, and a local clock tick.
//
//  Rules:
//    - Only live phases (open / armed / departed) move. settled / ended / idle are terminal here.
//    - Monotonic: a stale poll can never move departed back to armed, or armed back to open.
//    - Driver cancel and expiry are indistinguishable by design: both read `.ended(.expired)`.
//    - The clock can end a pass before the next poll arrives (unclaimed TTL, armed end date,
//      30-minute departed decision window).
//

import Foundation

nonisolated enum SpotPassReducer {

    /// Design §9.4: "Auto-ends after 30 minutes if no choice is made."
    static let departedDecisionWindow: TimeInterval = 30 * 60

    static func next(
        from current: SpotPassPhase,
        snapshot: SpotPassSnapshot,
        now: Date
    ) -> SpotPassPhase {
        guard current.isLive else { return current }

        // Confirmed elsewhere (another device / a duplicate confirm): show the receipt.
        if let outcome = snapshot.outcome {
            return .settled(outcome, karmaDelta: nil)
        }

        switch snapshot.status {
        case .suspended:
            return .ended(.suspended)

        case .expired, .cancelled:
            return .ended(.expired)

        case .created:
            // A `created` snapshot after we already saw armed/departed is stale: ignore it.
            guard current == .open else { return current }
            if let expiresAt = snapshot.expiresAt, now >= expiresAt { return .ended(.expired) }
            return .open

        case .armed:
            if current == .departed { return current }
            if let leaveAt = snapshot.leaveAt {
                if now >= SpotPassCountdown.endDate(leaveAt: leaveAt, expiresAt: snapshot.expiresAt) {
                    return .ended(.expired)
                }
            } else if let expiresAt = snapshot.expiresAt, now >= expiresAt {
                return .ended(.expired)
            }
            return .armed

        case .departed:
            if let departedAt = snapshot.departedAt,
               now.timeIntervalSince(departedAt) > departedDecisionWindow {
                return .ended(.expired)
            }
            return .departed
        }
    }
}

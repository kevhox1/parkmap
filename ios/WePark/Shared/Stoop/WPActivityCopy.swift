//
//  WPActivityCopy.swift
//  Shared/Stoop
//
//  Stoop Phase 5b (round-2 B12 Live Activity / Dynamic Island). The words the mocks changed, pure
//  so tests pin them. Used only behind `StoopFlag.designSystemV2Enabled`.
//

import Foundation

nonisolated enum WPActivityCopy {
    static func isWaiting(name: String) -> String { "\(name) is waiting" }
    static func leavingAround(_ clock: String) -> String { "Leaving around \(clock)" }
    static let leavingNow = "Leaving now"
    static let stillLeaving = "Still leaving?"
    static let fiveMore = "5 more min"
    static let notLeaving = "Not leaving"
    static let headsUpSent = "Heads-up sent"
    static func knowsPullingOut(name: String) -> String { "\(name) knows you're pulling out" }
    static let passedTitle = "You passed a spot."
    static let karmaLands = "+5 karma lands when they say thanks"
    static let thanksTitle = "Thanks, neighbor."
    static func from(name: String) -> String { "From \(name)" }
    static let karmaChip = "+5"
    static let endedTitle = "Pass ended"
    static func stoppedWaiting(name: String) -> String { "\(name) stopped waiting. Nothing to do." }
    static let cancelledTitle = "Pass cancelled."
    static let cancelledSub = "Nobody was told."

    /// Which layout a state renders. `isStale` is the OS telling us `staleDate` (= leave_at) passed.
    enum Layout: Equatable {
        case counting, timeToGo, sent, passed, thanks, cancelled, ended
    }

    static func layout(phase: SpotPassActivityAttributes.Phase, isStale: Bool) -> Layout {
        switch phase {
        case .counting: return isStale ? .timeToGo : .counting
        case .timeToGo: return .timeToGo
        case .sent: return .sent
        case .passed: return .passed
        case .thanks: return .thanks
        case .cancelled: return .cancelled
        case .ended: return .ended
        }
    }
}

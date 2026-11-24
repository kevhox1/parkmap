//
//  ClipDeepAction.swift
//  Shared/SpotPass
//
//  What a Live Activity link or a reminder action asks the clip to do on open (design 5.2, spec 7.3).
//

import Foundation

nonisolated enum ClipDeepAction: Equatable, Hashable, Sendable {
    /// Open the "I'm pulling out" screen only (never sends).
    case openPullingOut
    /// Perform the departure now (explicit "Leaving now" button), reporting this source.
    case leavingNow(HandoffDepartSource)
    /// "5 more min": extend and confirm with a toast.
    case extend
    /// Open the pulling-out screen with the cancel confirmation pre-opened (opening alone must not cancel).
    case confirmCancel
    /// "Not leaving" notification action: cancel silently, no second tap.
    case cancelNow

    init?(urlCode: String) {
        switch urlCode {
        case "pull": self = .openPullingOut
        case "now": self = .leavingNow(.liveActivity)
        case "more": self = .extend
        case "cancel": self = .confirmCancel
        default: return nil
        }
    }

    /// The https URL a Live Activity `Link` opens (an App Clip invocation on the registered prefix).
    var url: URL {
        let code: String
        switch self {
        case .openPullingOut: code = "pull"
        case .leavingNow: code = "now"
        case .extend: code = "more"
        case .confirmCancel, .cancelNow: code = "cancel"
        }
        let string = "https://\(SpotPassShared.universalLinkHost)\(SpotPassShared.landingPath)?a=\(code)"
        return URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}

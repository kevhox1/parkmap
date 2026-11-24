//
//  ClipMessageContent.swift
//  Shared/SpotPass/Driver
//
//  Copy + symbol for each calm terminal / error phase (design 3.8, 5.1c). Pure, so tests can pin
//  it; rendered by the clip's `ClipMessageView`.
//

import Foundation

nonisolated struct ClipMessageContent: Equatable, Sendable {
    let symbol: String
    let title: String
    let body: String
    var retry = false
    var showsWhatsWePark = false

    static func content(for phase: ClipPhase) -> ClipMessageContent {
        switch phase {
        case .unavailable:
            return .init(symbol: "clock.badge.xmark", title: ClipCopy.unavailableTitle, body: ClipCopy.unavailableBody, showsWhatsWePark: true)
        case .offline:
            return .init(symbol: "wifi.slash", title: ClipCopy.offlineTitle, body: ClipCopy.offlineBody, retry: true)
        case .busy:
            return .init(symbol: "hourglass", title: ClipCopy.busyTitle, body: ClipCopy.busyBody, retry: true)
        case .disabled:
            return .init(symbol: "clock", title: ClipCopy.disabledTitle, body: ClipCopy.disabledBody)
        case .openApp:
            return .init(symbol: "arrow.down.app", title: ClipCopy.openAppTitle, body: ClipCopy.openAppBody, showsWhatsWePark: true)
        case .saveFailed:
            return .init(symbol: "exclamationmark.lock", title: ClipCopy.saveFailedTitle, body: ClipCopy.saveFailedBody, showsWhatsWePark: true)
        case .dismissed:
            return .init(symbol: "hand.wave", title: ClipCopy.dismissedLine, body: "", showsWhatsWePark: true)
        case .cancelled:
            return .init(symbol: "xmark.circle", title: ClipCopy.cancelledLine, body: "", showsWhatsWePark: true)
        case .ended:
            return .init(symbol: "clock.badge.checkmark", title: ClipCopy.passEnded, body: "", showsWhatsWePark: true)
        default:
            return .init(symbol: "parkingsign.circle", title: ClipCopy.landingTitle, body: ClipCopy.landingBody)
        }
    }
}

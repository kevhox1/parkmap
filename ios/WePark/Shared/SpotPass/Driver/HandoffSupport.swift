//
//  HandoffSupport.swift
//  Shared/SpotPass/Driver
//
//  Small collaborators of the driver flow, each behind a protocol so tests inject fakes.
//    - `HandoffFeedback`: haptics (design 1.4) and VoiceOver announcements.
//    - `HandoffPushTokenProviding`: the clip's ephemeral APNs device token (for the thank-you push).
//

import Foundation
import UIKit

// MARK: - Feedback

@MainActor
protocol HandoffFeedback: AnyObject {
    func selection()
    func armImpact()
    func success()
    func lightImpact()
    func announce(_ message: String)
}

@MainActor
final class SystemHandoffFeedback: HandoffFeedback {
    func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    func armImpact() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    func lightImpact() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - Push token

@MainActor
protocol HandoffPushTokenProviding: AnyObject {
    /// The hex APNs token for the clip's topic, or nil (no ephemeral permission, simulator, timeout).
    func deviceToken() async -> String?
}

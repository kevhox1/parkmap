//
//  HandoffReminders.swift
//  Shared/SpotPass/Driver
//
//  The driver's local reminder (spec 7.3, design section 6): "Time to go?" at `leave_at` and a
//  "Still leaving?" last call at `leave_at + 10 min`. In the clip these are EPHEMERAL
//  notifications (up to 8 h after launch, no permission prompt): check `.ephemeral`, never prompt.
//  All three actions use `.foreground` because a clip cannot run background activity (spec 5.1):
//  the action opens the clip, which performs it immediately (no second tap).
//

import Foundation
import UserNotifications

// MARK: - Plan (pure)

nonisolated struct PlannedReminder: Equatable, Sendable {
    let identifier: String
    let fireDate: Date
    let title: String
    let body: String
    let hiddenPreviewBody: String
}

nonisolated enum HandoffReminderPlan {

    static let categoryID = "SPOT_PASS_LEAVING"
    static let actionLeavingNow = "SPOT_PASS_ACTION_LEAVING_NOW"
    static let actionExtend = "SPOT_PASS_ACTION_EXTEND"
    static let actionCancel = "SPOT_PASS_ACTION_CANCEL"
    /// Last call fires this long after `leave_at` (the pass expires 15 min after it).
    static let lastCallDelay: TimeInterval = 10 * 60

    static func threadID(passID: UUID) -> String { "spotpass-\(passID.uuidString.lowercased())" }
    static func leaveIdentifier(passID: UUID) -> String { "spotpass.leave.\(passID.uuidString.lowercased())" }
    static func lastCallIdentifier(passID: UUID) -> String { "spotpass.last.\(passID.uuidString.lowercased())" }

    /// Reminders worth scheduling at `now`. Fire dates at or before `now + 1 s` are dropped (a
    /// "Now" pass opens straight on the Time-to-go screen, so an immediate reminder is noise), and
    /// nothing is scheduled at or after the pass expiry.
    static func make(passID: UUID, name: String, leaveAt: Date, expiresAt: Date, now: Date) -> [PlannedReminder] {
        let candidates = [
            PlannedReminder(
                identifier: leaveIdentifier(passID: passID), fireDate: leaveAt,
                title: ClipCopy.timeToGo, body: ClipCopy.reminderBody(name: name),
                hiddenPreviewBody: ClipCopy.reminderHiddenBody
            ),
            PlannedReminder(
                identifier: lastCallIdentifier(passID: passID), fireDate: leaveAt.addingTimeInterval(lastCallDelay),
                title: ClipCopy.lastCallTitle, body: ClipCopy.lastCallBody(name: name),
                hiddenPreviewBody: ClipCopy.reminderHiddenBody
            )
        ]
        return candidates.filter { $0.fireDate > now.addingTimeInterval(1) && $0.fireDate < expiresAt }
    }

    /// Notification response action -> clip action. The default tap (body) opens the pulling-out screen.
    static func deepAction(forActionIdentifier identifier: String) -> ClipDeepAction? {
        switch identifier {
        case actionLeavingNow: return .leavingNow(.notification)
        case actionExtend: return .extend
        case actionCancel: return .cancelNow
        case UNNotificationDefaultActionIdentifier: return .openPullingOut
        default: return nil
        }
    }

    /// Category with the three actions. Not destructive (design acceptance check 8); all open the clip.
    static func category() -> UNNotificationCategory {
        let actions = [
            UNNotificationAction(identifier: actionLeavingNow, title: ClipCopy.actionLeavingNow, options: [.foreground]),
            UNNotificationAction(identifier: actionExtend, title: ClipCopy.actionFiveMore, options: [.foreground]),
            UNNotificationAction(identifier: actionCancel, title: ClipCopy.actionNotLeaving, options: [.foreground])
        ]
        return UNNotificationCategory(
            identifier: categoryID, actions: actions, intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: ClipCopy.reminderHiddenBody, options: []
        )
    }
}

// MARK: - Availability

nonisolated enum HandoffReminderAvailability: Equatable, Sendable {
    case on
    case off

    /// `.ephemeral` is the clip's expected status; `.notDetermined`/`.denied` mean the user
    /// switched it off on the card (design 3.4 "reminders are off").
    init(status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .on
        default: self = .off
        }
    }
}

// MARK: - Scheduler

@MainActor
protocol HandoffReminderScheduling: AnyObject {
    func availability() async -> HandoffReminderAvailability
    func schedule(_ reminders: [PlannedReminder], passID: UUID) async
    func cancelAll(passID: UUID)
}

@MainActor
final class UNHandoffReminderScheduler: HandoffReminderScheduling {

    /// `target-content-id` must match a registered experience (the advanced experience prefix).
    nonisolated static let targetContentID = "https://\(SpotPassShared.universalLinkHost)\(SpotPassShared.landingPath)"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func availability() async -> HandoffReminderAvailability {
        HandoffReminderAvailability(status: await center.notificationSettings().authorizationStatus)
    }

    func schedule(_ reminders: [PlannedReminder], passID: UUID) async {
        center.setNotificationCategories([HandoffReminderPlan.category()])
        cancelAll(passID: passID)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.categoryIdentifier = HandoffReminderPlan.categoryID
            content.threadIdentifier = HandoffReminderPlan.threadID(passID: passID)
            content.interruptionLevel = .active
            content.targetContentIdentifier = Self.targetContentID
            content.userInfo = ["kind": "reminder"]
            let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }

    func cancelAll(passID: UUID) {
        let ids = [HandoffReminderPlan.leaveIdentifier(passID: passID), HandoffReminderPlan.lastCallIdentifier(passID: passID)]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

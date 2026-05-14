//
//  Constants.swift
//  WePark
//

import Foundation

enum AppConstants {
    /// Manhattan center, used as the default map center on first launch.
    /// Matches the PWA's `[40.7831, -73.9712]` (see `index.html`).
    static let manhattanCenter = (latitude: 40.7831, longitude: -73.9712)

    /// In-app notification rationale shown before `UNUserNotificationCenter.requestAuthorization`.
    /// Verbatim from `docs/ios-mvp-spec.md` §3.6 — do not change without updating the spec.
    static let notificationRationale = "Get a reminder before alternate-side parking starts so you never get ticketed. Notifications are scheduled on-device only."

    // MARK: - W6 Notification keys

    /// UserDefaults key: set to true after the rationale sheet has been presented once per install.
    /// Guards `firstPinDropped` → rationale sheet presentation in ContentView.
    static let notificationRationaleShownKey = "wepark_notification_rationale_shown"

    /// UserDefaults key: W7 integration point — mute toggle.
    /// W6 stubs this as always absent (= false). W7 fills it in via the settings sheet.
    /// Do NOT read or write this key from W6 code; reserved for W7.
    static let notificationsMutedKey = "wepark_notifications_muted"

    /// Lead time (seconds) before the next restriction at which the notification fires.
    /// 1 hour — per `docs/ios-mvp-spec.md` §2.1 baseline and OQ-W6-1 answer.
    /// Change only this constant to adjust the lead time globally.
    static let notificationLeadTimeSeconds: TimeInterval = 1 * 3600
}

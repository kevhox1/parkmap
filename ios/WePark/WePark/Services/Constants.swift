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
}

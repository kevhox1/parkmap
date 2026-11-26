//
//  WPParkReminderCopy.swift
//  WePark
//
//  Stoop Phase 5b (round-2 B13): the park-reminder notification in round-2 wording. "The title is
//  the deadline or the fact. The body is the reason and the place." Used only when
//  `AppConstants.designSystemV2Enabled`; flag off keeps `NotificationScheduler`'s shipping copy
//  byte for byte. Scheduling (when it fires, which presets) is untouched.
//
//    Title  "Move your car by 9:00 AM" / "Move your car by 9:00 AM tomorrow"
//    Body   "Street cleaning on E 1st St, north side. 2 hours left."
//    Action "Walk there" -> Apple Maps walking directions to the car (DECISIONS: Apple Maps).
//
//  Not matched: "Remind me at 8 AM" (a new scheduled notification: a scheduling-semantics change).
//

import Foundation
import UserNotifications

nonisolated enum WPParkReminderCopy {

    static let categoryID = "wepark_park_reminder_v2"
    static let actionWalkThere = "wepark_action_walk_there"
    static let walkThereTitle = "Walk there"
    static let hiddenPreviewPlaceholder = "Parking reminder"

    static func title(moveBy: String, nightBefore: Bool) -> String {
        nightBefore ? "Move your car by \(moveBy) tomorrow" : "Move your car by \(moveBy)"
    }

    /// "ASP ..." labels read "Street cleaning"; every other label is already plain words.
    static func reasonLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "Parking restriction" }
        return label.hasPrefix("ASP") ? "Street cleaning" : label
    }

    static func sideWord(_ side: String) -> String {
        switch side.uppercased() {
        case "N": return "north side"
        case "S": return "south side"
        case "E": return "east side"
        case "W": return "west side"
        default: return side.isEmpty ? "" : "\(side) side"
        }
    }

    static func leftPhrase(_ lead: NotificationScheduler.LeadKind) -> String? {
        switch lead {
        case .minutes15: return "15 minutes left."
        case .minutes30: return "30 minutes left."
        case .hour1: return "1 hour left."
        case .hours2: return "2 hours left."
        case .nightBefore: return nil
        }
    }

    static func body(
        label: String?, street: String, side: String, lead: NotificationScheduler.LeadKind
    ) -> String {
        let place = [street, sideWord(side)].filter { !$0.isEmpty }.joined(separator: ", ")
        let base = "\(reasonLabel(label)) on \(place)."
        guard let left = leftPhrase(lead) else { return base }
        return base + " " + left
    }

    static func category() -> UNNotificationCategory {
        let walk = UNNotificationAction(
            identifier: actionWalkThere, title: walkThereTitle, options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "figure.walk")
        )
        return UNNotificationCategory(
            identifier: categoryID, actions: [walk], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: hiddenPreviewPlaceholder, options: []
        )
    }

    /// The car's coordinate rides in `userInfo` so the action works from a cold launch.
    static func userInfo(latitude: Double, longitude: Double) -> [String: Any] {
        ["wepark_lat": latitude, "wepark_lon": longitude]
    }

    static func coordinate(from userInfo: [AnyHashable: Any]) -> (latitude: Double, longitude: Double)? {
        guard let lat = userInfo["wepark_lat"] as? Double, let lon = userInfo["wepark_lon"] as? Double,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    /// Apple Maps walking directions URL (maps.apple.com), no in-app routing.
    static func walkURL(latitude: Double, longitude: Double) -> URL? {
        URL(string: "https://maps.apple.com/?daddr=\(latitude),\(longitude)&dirflg=w")
    }
}

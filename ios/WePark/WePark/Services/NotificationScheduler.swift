//
//  NotificationScheduler.swift
//  WePark
//
//  W6: All UNUserNotificationCenter scheduling and cancellation logic.
//
//  No import SwiftUI — this is a pure service (QA invariant).
//  No Calendar.current — all time math uses Calendar.easternTime (W3 invariant).
//
//  Architecture:
//    - Singleton: NotificationScheduler.shared
//    - Scheduling: schedule(for:loadedSegments:engine:now:) — takes a ParkedCar,
//      resolves the segment, computes the next restriction, builds a
//      UNNotificationRequest, and adds it to UNUserNotificationCenter.
//    - Cancellation: cancelAll(for:) — cancels all pending requests whose identifier
//      starts with "wepark.pin.<car.id.uuidString>". Also removes delivered notifications.
//    - cancelAllThenSchedule(for:...) — convenience that cancels the previous pin's
//      notifications (by oldCarID) then schedules for the new pin.
//
//  Identifier scheme: wepark.pin.<car.id.uuidString>.r0
//    r0 = the single lead-time notification. r1 reserved for future two-notification
//    design (OQ-W6-2 forward-compatibility).
//
//  Notification content (§3.4):
//    Title:   "Move your car — <street> (<side>)"
//    Body:    "<restriction label> starts <time label>. Move by <time>."
//    Sound:   default
//    Badge:   1
//    userInfo: { "wepark_car_id": carID, "wepark_action": "show_car_detail" }
//
//  Trigger: UNCalendarNotificationTrigger (DST-safe wall-clock fire).
//    DateComponents built from fireDate via Calendar.easternTime.
//
//  W7 mute integration point (§4.1):
//    guard !UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey)
//    This guard is a no-op in W6 (key absent = false). W7 activates by writing the key.
//
//  W7.5 "Park Until X" integration point (§4.3):
//    schedule(for:loadedSegments:engine:now:parkUntil:) — parkUntil: Date? parameter.
//    If non-nil and fireDate > parkUntil, skip scheduling.
//    W6 ships with parkUntil: nil always.
//

import Foundation
import UserNotifications

// MARK: - NotificationScheduler

final class NotificationScheduler {

    // MARK: - Singleton

    static let shared = NotificationScheduler()

    private init() {}

    // MARK: - Internal testable initialiser

    /// Internal init used by tests to inject a mock notification center.
    internal init(center: UNUserNotificationCenterProtocol) {
        self.center = center
    }

    // MARK: - Dependencies

    /// The notification center used for all requests.
    /// Defaults to the real UNUserNotificationCenter; tests inject a mock.
    private var center: UNUserNotificationCenterProtocol = UNUserNotificationCenter.current()

    // MARK: - Public API

    /// Schedule a local notification for the given parked car's next upcoming restriction.
    ///
    /// Steps:
    ///  1. Guard: W7 mute check (no-op in W6).
    ///  2. Resolve segment from detectedSegmentID.
    ///  3. Call engine.nextRestriction(for:at:).
    ///  4. Guard: unrestricted (hours >= 168) → skip.
    ///  5. Guard: active now (hours == 0) → skip.
    ///  6. Compute fireDate = now + hours*3600 - leadTime. Guard: fireDate <= now → skip.
    ///  7. Build UNMutableNotificationContent (§3.4).
    ///  8. Build UNCalendarNotificationTrigger from Calendar.easternTime components.
    ///  9. Add request to notification center.
    ///
    /// - Parameters:
    ///   - car: The parked car to schedule a reminder for.
    ///   - loadedSegments: All currently loaded segments (from TileLoader).
    ///   - engine: The rules engine used to compute the next restriction.
    ///   - now: The reference date (default: Date.nowET). Overridden by tests.
    ///   - parkUntil: W7.5 integration point — if non-nil and fireDate > parkUntil, skip.
    func schedule(
        for car: ParkedCar,
        loadedSegments: [Segment],
        engine: ParkingRulesEngine,
        now: Date = .nowET,
        parkUntil: Date? = nil
    ) {
        // W7 integration point: mute check.
        // W6 stubs this as always false; W7 fills it in.
        guard !UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey) else { return }

        // W7: Per-pin opt-in check.
        guard car.notifyOnRestriction else { return }

        // Step 1: Resolve segment. Nil detectedSegmentID → no notification.
        guard let segmentID = car.detectedSegmentID,
              let segment = loadedSegments.first(where: { $0.id == segmentID }) else {
            return
        }

        // Step 2: Compute next restriction.
        let restriction = engine.nextRestriction(for: segment, at: now)

        // Step 3: Guard unrestricted.
        guard !restriction.isUnrestricted else { return }

        // Step 4: Guard active now.
        guard !restriction.isActiveNow else { return }

        // Step 5: Compute fire date. leadTime = 1h (AppConstants.notificationLeadTimeSeconds).
        let fireDate = now.addingTimeInterval(restriction.hours * 3600 - AppConstants.notificationLeadTimeSeconds)

        // Guard: fire date must be in the future.
        guard fireDate > now else { return }

        // Step 6: W7.5 park-until guard (no-op in W6; parameter always nil).
        if let parkUntil = parkUntil, fireDate > parkUntil { return }

        // Step 7: Guard notification permission before scheduling.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            self.scheduleRequest(for: car, restriction: restriction, engine: engine, segment: segment, fireDate: fireDate, now: now)
        }
    }

    /// Internal entry point that bypasses the UNNotificationSettings check.
    /// Used in unit tests where the real center always returns `.notDetermined`
    /// (the test target has no notification entitlements), so the settings guard
    /// would always bail out. In production this path is never called directly.
    ///
    /// Performs the same edge-case guards as `schedule(for:)` minus the settings check.
    internal func scheduleForTest(
        for car: ParkedCar,
        loadedSegments: [Segment],
        engine: ParkingRulesEngine,
        now: Date
    ) {
        // W7 mute check (tests can verify this too).
        guard !UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey) else { return }

        // W7: Per-pin opt-in check.
        guard car.notifyOnRestriction else { return }

        guard let segmentID = car.detectedSegmentID,
              let segment = loadedSegments.first(where: { $0.id == segmentID }) else {
            return
        }

        let restriction = engine.nextRestriction(for: segment, at: now)
        guard !restriction.isUnrestricted else { return }
        guard !restriction.isActiveNow else { return }

        let fireDate = now.addingTimeInterval(restriction.hours * 3600 - AppConstants.notificationLeadTimeSeconds)
        guard fireDate > now else { return }

        scheduleRequest(for: car, restriction: restriction, engine: engine, segment: segment, fireDate: fireDate, now: now)
    }

    /// Cancel all pending notification requests for the given car.
    /// Also removes any delivered notifications for the same identifiers from
    /// Notification Center (keeps NC clean after the user taps "I left").
    func cancelAll(for car: ParkedCar) {
        let prefix = notificationIDPrefix(for: car)
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map { $0.identifier }
                .filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: ids)
                self.center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// Cancel all pending notifications for the old car ID, then schedule for the new car.
    /// This is the pin-replace path: old car notifications are removed, new ones scheduled.
    ///
    /// - Parameters:
    ///   - car: The new car (just saved by ParkPinService).
    ///   - oldCarID: The UUID of the previous car, captured before ParkPinService.save()
    ///               overwrote parkedCar. Nil on a fresh first pin drop.
    ///   - loadedSegments: All currently loaded segments (from TileLoader).
    ///   - engine: The rules engine.
    ///   - now: Reference date (default: Date.nowET).
    func cancelAllThenSchedule(
        for car: ParkedCar,
        oldCarID: UUID?,
        loadedSegments: [Segment],
        engine: ParkingRulesEngine,
        now: Date = .nowET
    ) {
        // Cancel old car's notifications first.
        if let oldID = oldCarID {
            let oldPrefix = notificationIDPrefix(forUUID: oldID)
            center.getPendingNotificationRequests { requests in
                let ids = requests
                    .map { $0.identifier }
                    .filter { $0.hasPrefix(oldPrefix) }
                if !ids.isEmpty {
                    self.center.removePendingNotificationRequests(withIdentifiers: ids)
                    self.center.removeDeliveredNotifications(withIdentifiers: ids)
                }
                // Schedule new notifications after cancellation completes.
                self.schedule(for: car, loadedSegments: loadedSegments, engine: engine, now: now)
            }
        } else {
            // No old car — schedule immediately.
            schedule(for: car, loadedSegments: loadedSegments, engine: engine, now: now)
        }
    }

    // MARK: - Request building (shared by schedule and scheduleForTest)

    /// Builds and enqueues a `UNNotificationRequest` for the given car and restriction.
    /// Called from both the production path (after settings check) and the test path.
    private func scheduleRequest(
        for car: ParkedCar,
        restriction: NextRestriction,
        engine: ParkingRulesEngine,
        segment: Segment,
        fireDate: Date,
        now: Date
    ) {
        let content = buildContent(for: car, restriction: restriction, engine: engine, segment: segment, now: now)

        let components = Calendar.easternTime.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let identifier = Self.notificationID(for: car, ruleIndex: 0)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        center.add(request) { error in
            if let error = error {
                assertionFailure("NotificationScheduler: failed to schedule notification: \(error)")
            }
        }
    }

    // MARK: - Identifier helpers

    /// Builds the notification identifier for a specific rule index.
    /// Format: "wepark.pin.<car.id.uuidString>.r<ruleIndex>"
    static func notificationID(for car: ParkedCar, ruleIndex: Int) -> String {
        "wepark.pin.\(car.id.uuidString).r\(ruleIndex)"
    }

    /// Prefix for all notifications belonging to a car. Used for prefix-based cancellation.
    func notificationIDPrefix(for car: ParkedCar) -> String {
        "wepark.pin.\(car.id.uuidString)"
    }

    /// Prefix variant that takes a UUID directly — for cancelling a car that's no longer
    /// reachable via parkedCar (i.e., the old car before save() overwrites it).
    func notificationIDPrefix(forUUID uuid: UUID) -> String {
        "wepark.pin.\(uuid.uuidString)"
    }

    // MARK: - Content builder

    /// Builds the notification content per spec §3.4.
    private func buildContent(
        for car: ParkedCar,
        restriction: NextRestriction,
        engine: ParkingRulesEngine,
        segment: Segment,
        now: Date
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        // Title: "Move your car — <street> (<side>)"
        let streetDisplay = car.street.map { StreetNameNormalizer.canonical($0) }
            ?? StreetNameNormalizer.canonical(segment.street)
        let sideDisplay = car.detectedSide ?? segment.side
        content.title = "Move your car \u{2014} \(streetDisplay) (\(sideDisplay))"

        // Body: "<restriction label> starts <time label>. Move by <time>."
        let label = restriction.label ?? "Parking restriction"
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)

        // Extract just the time portion (e.g., "7:00 AM" from "Today 7:00 AM")
        // for the "Move by <time>" suffix — keep it concise.
        let moveByTime = extractTimeString(from: timeLabel)
        content.body = "\(label) starts \(timeLabel). Move by \(moveByTime)."

        content.sound = .default
        content.badge = 1

        // userInfo for deep-link tap handling (§3.7 OQ-W6-3).
        content.userInfo = [
            "wepark_car_id": car.id.uuidString,
            "wepark_action": "show_car_detail"
        ]

        return content
    }

    /// Extracts the time portion from a `nextRestrictionTimeLabel` string.
    /// Input examples: "Today 7:00 AM", "Tomorrow 9:30 AM", "Thursday 7:00 PM"
    /// Output examples: "7:00 AM", "9:30 AM", "7:00 PM"
    ///
    /// The time component is everything after the first space, which is always
    /// the day-label prefix. If parsing fails, returns the full string.
    private func extractTimeString(from timeLabel: String) -> String {
        let parts = timeLabel.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return timeLabel }
        return String(parts[1])
    }
}

// MARK: - UNUserNotificationCenterProtocol

/// Protocol that mirrors the subset of UNUserNotificationCenter used by NotificationScheduler.
/// This allows test injection of a mock without requiring real notification permissions.
protocol UNUserNotificationCenterProtocol: AnyObject {
    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void)
    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

// MARK: - UNUserNotificationCenter conformance

extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

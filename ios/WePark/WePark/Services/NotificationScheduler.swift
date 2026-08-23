//
//  NotificationScheduler.swift
//  WePark
//
//  W6: All UNUserNotificationCenter scheduling and cancellation logic.
//  FT-6: Extended to support multi-preset reminders via ReminderOffsets.
//
//  No import SwiftUI — this is a pure service (QA invariant).
//  No Calendar.current — all time math uses Calendar.easternTime (W3 invariant).
//
//  Architecture:
//    - Singleton: NotificationScheduler.shared
//    - Scheduling: schedule(for:loadedSegments:engine:now:parkUntil:) — takes a ParkedCar,
//      resolves the segment, computes the next restriction, iterates active ReminderOffsets
//      presets, and adds one UNNotificationRequest per preset to UNUserNotificationCenter.
//    - Cancellation: cancelAll(for:) — cancels all pending requests whose identifier
//      starts with "wepark.pin.<car.id.uuidString>". Also removes delivered notifications.
//    - cancelAllThenSchedule(for:...) — convenience that cancels the previous pin's
//      notifications (by oldCarID) then schedules for the new pin.
//
//  Preset-to-ruleIndex mapping (STABLE — never reorder, see spec §4.2):
//    r0 = 15 min before  (leadSeconds: 900)
//    r1 = 30 min before  (leadSeconds: 1800)
//    r2 = 1 hour before  (leadSeconds: 3600)
//    r3 = 2 hours before (leadSeconds: 7200)
//    r4 = Night before   (20:00 ET prior calendar evening — DST-safe)
//
//  Identifier scheme: wepark.pin.<car.id.uuidString>.rN
//    where N is the ruleIndex above (0–4). Stable mapping ensures prefix-based
//    cancellation removes all five slots without needing to know which were active.
//
//  Notification content (per spec §5.6):
//    Title:   "Move your car — <street> (<side>)" (unchanged)
//    Body:    Per-preset lead phrase — see buildBody(for:restriction:engine:now:leadKind:)
//    Sound:   default
//    Badge:   1
//    userInfo: { "wepark_car_id": carID, "wepark_action": "show_car_detail" }
//
//  Trigger: UNCalendarNotificationTrigger (DST-safe wall-clock fire).
//    DateComponents built from fireDate via Calendar.easternTime.
//
//  iOS pending-notification cap: 64 per app. With 5 presets and 1 active pin this feature
//  enqueues at most 5 requests — well within budget. No pruning logic needed.
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

    /// Schedule local notifications for the given parked car's next upcoming restriction.
    ///
    /// For each active preset in ReminderOffsets (loaded from UserDefaults), computes a
    /// fireDate and enqueues one UNNotificationRequest. Per-preset past-guard and
    /// W7.5 parkUntil-guard are applied independently per reminder.
    ///
    /// - Parameters:
    ///   - car: The parked car to schedule reminders for.
    ///   - loadedSegments: All currently loaded segments (from TileLoader).
    ///   - engine: The rules engine used to compute the next restriction.
    ///   - now: The reference date (default: Date.nowET). Overridden by tests.
    ///   - parkUntil: W7.5 integration point — if non-nil and fireDate > parkUntil, skip
    ///                that individual reminder (but still schedule others).
    func schedule(
        for car: ParkedCar,
        loadedSegments: [Segment],
        engine: ParkingRulesEngine,
        now: Date = .nowET,
        parkUntil: Date? = nil
    ) {
        // W7 integration point: mute check.
        guard !UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey) else { return }

        // W7: Per-pin opt-in check.
        guard car.notifyOnRestriction else { return }

        // Resolve segment. Nil detectedSegmentID → no notification.
        guard let segmentID = car.detectedSegmentID,
              let segment = loadedSegments.first(where: { $0.id == segmentID }) else {
            return
        }

        // Compute next restriction.
        let restriction = engine.nextRestriction(for: segment, at: now)

        // Guard unrestricted.
        guard !restriction.isUnrestricted else { return }

        // Guard active now.
        guard !restriction.isActiveNow else { return }

        // Load reminder offsets from UserDefaults.
        let offsets = ReminderOffsets.load(from: .standard)

        // Compute the anchor: absolute date of the restriction start.
        let restrictionStart = now.addingTimeInterval(restriction.hours * 3600)

        // Guard notification permission before scheduling any requests.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            self.enqueuePresets(
                offsets: offsets,
                car: car,
                restriction: restriction,
                engine: engine,
                segment: segment,
                restrictionStart: restrictionStart,
                now: now,
                parkUntil: parkUntil
            )
        }
    }

    /// Internal entry point that bypasses the UNNotificationSettings check.
    /// Used in unit tests where the real center always returns `.notDetermined`
    /// (the test target has no notification entitlements), so the settings guard
    /// would always bail out. In production this path is never called directly.
    ///
    /// - Parameters:
    ///   - offsets: Optional ReminderOffsets to use. When nil, reads from UserDefaults.standard.
    ///              Inject a specific value in tests to avoid polluting global state.
    internal func scheduleForTest(
        for car: ParkedCar,
        loadedSegments: [Segment],
        engine: ParkingRulesEngine,
        now: Date,
        offsets: ReminderOffsets? = nil,
        parkUntil: Date? = nil
    ) {
        // W7 mute check.
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

        // Use provided offsets or load from UserDefaults.standard.
        let resolvedOffsets = offsets ?? ReminderOffsets.load(from: .standard)

        // Compute the anchor: absolute date of the restriction start.
        let restrictionStart = now.addingTimeInterval(restriction.hours * 3600)

        enqueuePresets(
            offsets: resolvedOffsets,
            car: car,
            restriction: restriction,
            engine: engine,
            segment: segment,
            restrictionStart: restrictionStart,
            now: now,
            parkUntil: parkUntil
        )
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

    // MARK: - Multi-preset loop

    /// Iterates the active presets in `offsets` and enqueues one UNNotificationRequest per
    /// preset that passes the per-preset guards (past-guard + parkUntil-guard).
    ///
    /// Called from both the production path (inside getNotificationSettings callback) and
    /// the test path (scheduleForTest, which bypasses the settings check).
    private func enqueuePresets(
        offsets: ReminderOffsets,
        car: ParkedCar,
        restriction: NextRestriction,
        engine: ParkingRulesEngine,
        segment: Segment,
        restrictionStart: Date,
        now: Date,
        parkUntil: Date?
    ) {
        // iOS pending-notification cap: 64 per app. With 5 presets and 1 pin this enqueues
        // at most 5 requests — well within budget.

        // r0 — 15 min before
        if offsets.remind15Min {
            let fireDate = restrictionStart.addingTimeInterval(-900)
            if fireDate > now {
                if let pu = parkUntil, fireDate > pu { /* skip */ } else {
                    scheduleRequest(for: car, restriction: restriction, engine: engine,
                                    segment: segment, fireDate: fireDate, ruleIndex: 0,
                                    leadKind: .minutes15, now: now)
                }
            }
        }

        // r1 — 30 min before
        if offsets.remind30Min {
            let fireDate = restrictionStart.addingTimeInterval(-1800)
            if fireDate > now {
                if let pu = parkUntil, fireDate > pu { /* skip */ } else {
                    scheduleRequest(for: car, restriction: restriction, engine: engine,
                                    segment: segment, fireDate: fireDate, ruleIndex: 1,
                                    leadKind: .minutes30, now: now)
                }
            }
        }

        // r2 — 1 hour before
        if offsets.remind1Hour {
            let fireDate = restrictionStart.addingTimeInterval(-3600)
            if fireDate > now {
                if let pu = parkUntil, fireDate > pu { /* skip */ } else {
                    scheduleRequest(for: car, restriction: restriction, engine: engine,
                                    segment: segment, fireDate: fireDate, ruleIndex: 2,
                                    leadKind: .hour1, now: now)
                }
            }
        }

        // r3 — 2 hours before
        if offsets.remind2Hours {
            let fireDate = restrictionStart.addingTimeInterval(-7200)
            if fireDate > now {
                if let pu = parkUntil, fireDate > pu { /* skip */ } else {
                    scheduleRequest(for: car, restriction: restriction, engine: engine,
                                    segment: segment, fireDate: fireDate, ruleIndex: 3,
                                    leadKind: .hours2, now: now)
                }
            }
        }

        // r4 — Night before (20:00 ET on the prior calendar evening — DST-safe)
        if offsets.remindNightBefore {
            if let nightBeforeDate = computeNightBeforeDate(relativeTo: restrictionStart) {
                if nightBeforeDate > now {
                    if let pu = parkUntil, nightBeforeDate > pu { /* skip */ } else {
                        scheduleRequest(for: car, restriction: restriction, engine: engine,
                                        segment: segment, fireDate: nightBeforeDate, ruleIndex: 4,
                                        leadKind: .nightBefore, now: now)
                    }
                }
            }
        }
    }

    // MARK: - Night-before date computation (DST-safe, Calendar.easternTime only)

    /// Computes 20:00 ET on the calendar evening prior to the restriction day.
    ///
    /// Algorithm (spec §5.4):
    ///  1. Get ET calendar day of restrictionStart.
    ///  2. Subtract 1 calendar day.
    ///  3. Build 20:00 ET on that prior day via Calendar.easternTime.date(from:) with
    ///     fireComponents.timeZone = .easternTime — the same DST-safe pattern used throughout.
    ///
    /// Returns nil if the date components cannot be assembled (defensive; in practice always
    /// succeeds for valid restrictionStart dates).
    private func computeNightBeforeDate(relativeTo restrictionStart: Date) -> Date? {
        // Step 2: subtract 1 calendar day from restrictionStart.
        guard let priorDay = Calendar.easternTime.date(byAdding: .day, value: -1, to: restrictionStart) else {
            return nil
        }

        // Step 3: extract prior day's Y/M/D components in ET.
        let priorComponents = Calendar.easternTime.dateComponents([.year, .month, .day], from: priorDay)

        // Step 4: build 20:00 ET on that prior day.
        var fireComponents = DateComponents()
        fireComponents.year   = priorComponents.year
        fireComponents.month  = priorComponents.month
        fireComponents.day    = priorComponents.day
        fireComponents.hour   = AppConstants.nightBeforeHourET  // 20
        fireComponents.minute = 0
        fireComponents.second = 0
        fireComponents.timeZone = .easternTime

        return Calendar.easternTime.date(from: fireComponents)
    }

    // MARK: - Request building

    /// Builds and enqueues a `UNNotificationRequest` for one preset.
    ///
    /// - Parameters:
    ///   - ruleIndex: The stable slot index (0–4) per spec §4.2.
    ///   - leadKind: The preset enum value used to select the body copy.
    private func scheduleRequest(
        for car: ParkedCar,
        restriction: NextRestriction,
        engine: ParkingRulesEngine,
        segment: Segment,
        fireDate: Date,
        ruleIndex: Int,
        leadKind: LeadKind,
        now: Date
    ) {
        let content = buildContent(for: car, restriction: restriction, engine: engine,
                                   segment: segment, leadKind: leadKind, now: now)

        let components = Calendar.easternTime.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let identifier = Self.notificationID(for: car, ruleIndex: ruleIndex)
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
    /// Cancelling by prefix removes r0–r4 (all five slots) without needing to know which
    /// presets were active at scheduling time.
    func notificationIDPrefix(for car: ParkedCar) -> String {
        "wepark.pin.\(car.id.uuidString)"
    }

    /// Prefix variant that takes a UUID directly — for cancelling a car that's no longer
    /// reachable via parkedCar (i.e., the old car before save() overwrites it).
    func notificationIDPrefix(forUUID uuid: UUID) -> String {
        "wepark.pin.\(uuid.uuidString)"
    }

    // MARK: - Content builder

    /// Per-preset body copy variant. Used by buildContent.
    enum LeadKind {
        case minutes15
        case minutes30
        case hour1
        case hours2
        case nightBefore
    }

    /// Builds the notification content per spec §5.6.
    ///
    /// Title is unchanged from W6. Body varies by leadKind with a per-preset lead phrase.
    private func buildContent(
        for car: ParkedCar,
        restriction: NextRestriction,
        engine: ParkingRulesEngine,
        segment: Segment,
        leadKind: LeadKind,
        now: Date
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        // Title: "Move your car — <street> (<side>)" (unchanged from W6)
        let streetDisplay = car.street.map { StreetNameNormalizer.canonical($0) }
            ?? StreetNameNormalizer.canonical(segment.street)
        let sideDisplay = car.detectedSide ?? segment.side
        content.title = "Move your car \u{2014} \(streetDisplay) (\(sideDisplay))"

        // Per-preset body copy (spec §5.6).
        let label = restriction.label ?? "Parking restriction"
        let timeLabel = engine.nextRestrictionTimeLabel(hours: restriction.hours, now: now)
        let moveByTime = extractTimeString(from: timeLabel)

        switch leadKind {
        case .minutes15:
            content.body = "\(label) starts in 15 minutes. Move by \(moveByTime)."
        case .minutes30:
            content.body = "\(label) starts in 30 minutes. Move by \(moveByTime)."
        case .hour1:
            content.body = "\(label) starts in 1 hour. Move by \(moveByTime)."
        case .hours2:
            content.body = "\(label) starts in 2 hours. Move by \(moveByTime)."
        case .nightBefore:
            content.body = "\(label) starts tomorrow at \(moveByTime). Move your car by then."
        }

        content.sound = .default
        content.badge = 1

        // userInfo for deep-link tap handling (§3.7 OQ-W6-3).
        content.userInfo = [
            "wepark_car_id": car.id.uuidString,
            "wepark_action": "show_car_detail"
        ]

        return content
    }

    // MARK: - Badge clearing (fix: badge never cleared)

    /// Clears the app icon badge.
    ///
    /// `content.badge = 1` is set on every scheduled ASP reminder (see `buildContent` above).
    /// The badge means "a reminder is waiting" — once the user opens the app, they've seen
    /// whatever fired, so the badge should clear. Nothing previously called this: the badge
    /// belongs to the install (not the build), so the FIRST reminder that ever fired stamped
    /// a permanent "1" on the icon that survived every subsequent app launch and TestFlight
    /// build. Call site: `ContentView.handleScenePhaseChange` on `.active` (foreground).
    ///
    /// `setBadgeCount(_:withCompletionHandler:)` is the modern (iOS 16+) badge API; this
    /// project targets 17.0. Routed through `center` (the same injectable seam used by every
    /// other method here) so it's unit-testable via `MockNotificationCenter` without touching
    /// real notification permissions. A failure here is cosmetic (the badge just doesn't
    /// clear) — logged, not thrown or asserted, so it can never crash the app.
    func clearBadge() {
        center.setBadgeCount(0, withCompletionHandler: { error in
            if let error {
                print("[NotificationScheduler] clearBadge failed: \(error)")
            }
        })
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
    /// Badge fix: mirrors `UNUserNotificationCenter.setBadgeCount(_:withCompletionHandler:)`
    /// (iOS 16+) so `NotificationScheduler.clearBadge()` is testable via a mock.
    func setBadgeCount(_ newBadgeCount: Int, withCompletionHandler completionHandler: ((Error?) -> Void)?)
}

// MARK: - UNUserNotificationCenter conformance

extension UNUserNotificationCenter: UNUserNotificationCenterProtocol {}

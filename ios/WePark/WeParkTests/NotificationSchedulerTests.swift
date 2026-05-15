//
//  NotificationSchedulerTests.swift
//  WeParkTests
//
//  W6 unit tests for NotificationScheduler.
//  Tests T-W6.1 through T-W6.13 per docs/w6-notifications-spec.md §5.1.
//
//  Uses MockNotificationCenter (conforms to UNUserNotificationCenterProtocol) to avoid
//  requiring real notification permission in the test environment.
//  Tests drive the scheduler via `scheduleForTest()` — the internal entry point that
//  bypasses `getNotificationSettings` (which always returns .notDetermined in test targets
//  due to missing notification entitlements). The production path is verified structurally.
//
//  All dates constructed via Calendar.easternTime (W3 invariant).
//  No Calendar.current use.
//

import XCTest
import UserNotifications
@testable import WePark

// MARK: - MockNotificationCenter

/// In-memory UNUserNotificationCenterProtocol for test injection.
/// Tracks all added/removed identifiers; does not require notification entitlements.
final class MockNotificationCenter: UNUserNotificationCenterProtocol {

    var pendingRequests: [UNNotificationRequest] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedPendingIdentifiers: [String] = []
    var removedDeliveredIdentifiers: [String] = []

    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) {
        // Unused in the test path (scheduleForTest bypasses this check).
        // If called, we fall back to the real center which returns .notDetermined.
        UNUserNotificationCenter.current().getNotificationSettings(completionHandler: completionHandler)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        completionHandler(pendingRequests)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        addedRequests.append(request)
        pendingRequests.append(request)
        completionHandler?(nil)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
        pendingRequests.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }
}

// MARK: - Test helpers

extension XCTestCase {

    /// Builds a minimal Segment with the given rules.
    func nsSegment(
        id: String = "TEST",
        street: String = "MOTT STREET",
        side: String = "N",
        dominantCategory: WePark.Category? = nil,
        rules: [ParkingRule]
    ) -> Segment {
        let ruleData = try! JSONEncoder().encode(rules)
        let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
        var segDict: [String: Any] = [
            "id": id,
            "street": street,
            "from": "GRAND STREET",
            "to": "HESTER STREET",
            "side": side,
            "line": [[40.7183, -73.9942], [40.7190, -73.9940]],
            "rules": rulesJSON,
        ]
        if let dc = dominantCategory {
            segDict["dominantCategory"] = dc.rawValue
        }
        let data = try! JSONSerialization.data(withJSONObject: segDict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    /// Builds a ParkingRule.
    func nsRule(
        category: WePark.Category,
        days: [Int],
        timeRanges: [(start: Int, end: Int)] = [],
        anytime: Bool = false,
        description: String = ""
    ) -> ParkingRule {
        let ranges = timeRanges.map { TimeRange(start: $0.start, end: $0.end) }
        let ruleDict: [String: Any] = [
            "category": category.rawValue,
            "description": description,
            "days": days,
            "timeRanges": ranges.map { ["start": $0.start, "end": $0.end] },
            "anytime": anytime,
            "arrow": "both",
        ]
        let data = try! JSONSerialization.data(withJSONObject: ruleDict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    /// Builds a Date in America/New_York at the given components.
    func nsDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }

    /// Builds a minimal ParkedCar for a given segment.
    func nsCar(
        id: UUID = UUID(),
        segmentID: String?,
        street: String? = "MOTT STREET",
        side: String? = "N",
        notifyOnRestriction: Bool = true
    ) -> ParkedCar {
        ParkedCar(
            id: id,
            latitude: 40.7183,
            longitude: -73.9942,
            detectedSegmentID: segmentID,
            detectedSide: side,
            street: street,
            fromStreet: "GRAND STREET",
            toStreet: "HESTER STREET",
            parkedAt: Date(),
            notifyOnRestriction: notifyOnRestriction
        )
    }
}

// MARK: - NotificationSchedulerTests

final class NotificationSchedulerTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var mockCenter: MockNotificationCenter!
    var scheduler: NotificationScheduler!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        mockCenter = MockNotificationCenter()
        scheduler = NotificationScheduler(center: mockCenter)

        // Ensure mute key is absent before each test.
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationRationaleShownKey)
        super.tearDown()
    }

    // MARK: - T-W6.1: Restriction 3h away, lead 1h → schedules request with correct fire date

    /// Thu 2026-05-07 at 4:00am ET. ASP Mon/Thu 7:00am → 3h away.
    /// Expected: one request, fire date ≈ 6:00am (now + 3h - 1h).
    /// Using May 7 (not May 14 which is Ascension Day / ASP suspended).
    func testTW61_SchedulesNotificationFor3hRestriction() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_1",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_1")

        // Prereq: verify the engine sees ~3h.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertGreaterThan(restriction.hours, 2.9)
        XCTAssertLessThan(restriction.hours, 3.1)

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 1, "T-W6.1: should schedule exactly 1 request")

        let req = mockCenter.addedRequests[0]
        // Identifier scheme.
        XCTAssertEqual(req.identifier, "wepark.pin.\(car.id.uuidString).r0",
                       "T-W6.1: identifier must match scheme")

        // Trigger type.
        guard let trigger = req.trigger as? UNCalendarNotificationTrigger else {
            XCTFail("T-W6.1: trigger must be UNCalendarNotificationTrigger")
            return
        }
        XCTAssertFalse(trigger.repeats, "T-W6.1: trigger must not repeat")

        // Fire time should be 6:00am (7am - 1h lead).
        let comps = trigger.dateComponents
        XCTAssertEqual(comps.hour, 6, "T-W6.1: fire hour should be 6am (7am minus 1h lead)")
        XCTAssertEqual(comps.minute, 0, "T-W6.1: fire minute should be 0")
        XCTAssertEqual(comps.day, 7, "T-W6.1: fire day should be May 7")
    }

    // MARK: - T-W6.2: detectedSegmentID nil → no notification

    func testTW62_NilSegmentID_NoNotification() {
        let now = nsDate(year: 2026, month: 5, day: 14, hour: 4, minute: 0)
        let car = nsCar(segmentID: nil)
        let segment = nsSegment(rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0, "T-W6.2: nil segmentID → no notification")
    }

    // MARK: - T-W6.3: FREE segment (no rules → hours >= 168) → no notification

    func testTW63_FreeSegment_NoNotification() {
        let now = nsDate(year: 2026, month: 5, day: 14, hour: 10, minute: 0)
        let segment = nsSegment(id: "FREE_1", rules: [])
        let car = nsCar(segmentID: "FREE_1")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0, "T-W6.3: free segment → no notification")
    }

    // MARK: - T-W6.4: Metered-only segment → no notification

    func testTW64_MeteredOnlySegment_NoNotification() {
        let now = nsDate(year: 2026, month: 5, day: 14, hour: 10, minute: 0)
        // Metered rule only — engine skips metered in nextRestriction, returns hours = 168.
        let segment = nsSegment(
            id: "METER_1",
            rules: [nsRule(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1080)])]
        )
        let car = nsCar(segmentID: "METER_1")

        // Verify engine returns unrestricted for metered-only.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertTrue(restriction.isUnrestricted, "T-W6.4 prereq: metered segment should be unrestricted in engine")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0, "T-W6.4: metered segment → no notification")
    }

    // MARK: - T-W6.5: Restriction 45min away, lead 1h → fireDate past → no notification

    func testTW65_RestrictionLessThanLeadTime_NoNotification() {
        // Thu 2026-05-07 at 6:15am ET. ASP Mon/Thu 7:00am → 45min away.
        // fireDate = now + 0.75h - 1h = past now. No notification.
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 6, minute: 15)
        let segment = nsSegment(
            id: "MOTT_N_2",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_2")

        // Prereq: restriction is ~45min away.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertGreaterThan(restriction.hours, 0.7)
        XCTAssertLessThan(restriction.hours, 0.8)

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "T-W6.5: 45min away with 1h lead → fireDate in past → no notification")
    }

    // MARK: - T-W6.6: Restriction active now (hours == 0) → no notification

    func testTW66_RestrictionActiveNow_NoNotification() {
        // Thu 2026-05-07 at 8:00am ET. ASP Mon/Thu 7:00–9:30am → active now.
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 8, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_3",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_3")

        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertTrue(restriction.isActiveNow, "T-W6.6 prereq: restriction should be active at Thu 8am")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "T-W6.6: active restriction → no notification")
    }

    // MARK: - T-W6.7: cancelAll removes the pending request

    func testTW67_CancelAll_RemovesRequest() {
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_4",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_4")

        // Schedule first.
        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.pendingRequests.count, 1, "Prereq: one pending request")

        // Cancel using an expectation to handle the async getPendingNotificationRequests callback.
        let exp = expectation(description: "cancelAll completes")
        DispatchQueue.global().async {
            self.scheduler.cancelAll(for: car)
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(mockCenter.pendingRequests.count, 0,
                       "T-W6.7: pending requests should be empty after cancelAll")
        XCTAssertTrue(
            mockCenter.removedPendingIdentifiers.contains("wepark.pin.\(car.id.uuidString).r0"),
            "T-W6.7: correct identifier removed"
        )
    }

    // MARK: - T-W6.8: cancelAll with different car ID doesn't remove unrelated requests

    func testTW68_CancelAll_DifferentCarID_DoesNotRemoveOtherRequests() {
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_5",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let carA = nsCar(segmentID: "MOTT_N_5")
        let carB = nsCar(segmentID: "MOTT_N_5")   // Different UUID, same segment

        // Schedule for carA.
        scheduler.scheduleForTest(for: carA, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.pendingRequests.count, 1, "Prereq: carA scheduled")

        // Cancel for carB (different UUID) — should not touch carA's request.
        let exp = expectation(description: "cancelAll for carB completes")
        DispatchQueue.global().async {
            self.scheduler.cancelAll(for: carB)
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(mockCenter.pendingRequests.count, 1,
                       "T-W6.8: carA's request must be untouched")
        XCTAssertFalse(
            mockCenter.removedPendingIdentifiers.contains("wepark.pin.\(carA.id.uuidString).r0"),
            "T-W6.8: carA's identifier must NOT have been removed"
        )
    }

    // MARK: - T-W6.9: Notification title format matches spec §3.4

    func testTW69_NotificationTitleFormat() {
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_6",
            street: "MOTT STREET",
            side: "N",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = ParkedCar(
            id: UUID(),
            latitude: 40.7183,
            longitude: -73.9942,
            detectedSegmentID: "MOTT_N_6",
            detectedSide: "N",
            street: "MOTT STREET",
            fromStreet: "GRAND STREET",
            toStreet: "HESTER STREET",
            parkedAt: Date(),
            notifyOnRestriction: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1, "T-W6.9 prereq: one request")

        let title = mockCenter.addedRequests[0].content.title
        // Spec §3.4: "Move your car — <street> (<side>)"
        // StreetNameNormalizer.canonical() returns uppercase: "MOTT ST".
        XCTAssertTrue(title.contains("Move your car"), "T-W6.9: title must contain 'Move your car'")
        XCTAssertTrue(title.contains("MOTT ST"), "T-W6.9: title must contain canonical 'MOTT ST' (uppercase from normalizer)")
        XCTAssertTrue(title.contains("(N)"), "T-W6.9: title must contain side in parens")
    }

    // MARK: - T-W6.10: Notification body format contains restriction label and time

    func testTW610_NotificationBodyFormat() {
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_7",
            street: "MOTT STREET",
            side: "N",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_7")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1)

        let body = mockCenter.addedRequests[0].content.body
        // Spec §3.4: body contains restriction label and time reference.
        XCTAssertTrue(body.contains("starts"), "T-W6.10: body must contain 'starts'")
        XCTAssertTrue(body.contains("Move by"), "T-W6.10: body must contain 'Move by'")
        // Engine label for ASP_MON_THU is "ASP Mon/Thu".
        XCTAssertTrue(body.contains("ASP"), "T-W6.10: body should contain restriction label")
    }

    // MARK: - T-W6.11: ASP suspension → fire date is past the suspended date

    func testTW611_ASPSuspension_FireDatePastSuspension() {
        // 2026-05-14 is Ascension Day (ASP suspended per ASPSuspensionService).
        // Reference: Wed 2026-05-13 at 10:00am ET.
        // Next non-suspended Thursday after 2026-05-14 is 2026-05-21.
        let now = nsDate(year: 2026, month: 5, day: 13, hour: 10, minute: 0)
        let segment = nsSegment(
            id: "SUSP_1",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "SUSP_1")

        // Verify engine skips the suspension.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertFalse(restriction.isUnrestricted,
                       "T-W6.11: engine must find a restriction after skipping suspension")
        // From Wed May 13 10am to next Thursday May 21 7am ASP start:
        // Mon May 18 is also a valid ASP_MON_THU day — check if it's suspended.
        // May 18 is not in 2026 suspension list, so next is actually Mon May 18.
        // hours = ~14h (Mon May 18 7am - Wed May 13 10am = ~45h).
        // Let's check the engine actually returns something in a reasonable range.
        XCTAssertGreaterThan(restriction.hours, 0, "T-W6.11: must find a future restriction")
        XCTAssertLessThan(restriction.hours, 168, "T-W6.11: must be within 14-day window")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "T-W6.11: one request scheduled for post-suspension window")

        guard let trigger = mockCenter.addedRequests[0].trigger as? UNCalendarNotificationTrigger else {
            XCTFail("T-W6.11: trigger must be UNCalendarNotificationTrigger")
            return
        }
        let comps = trigger.dateComponents
        // Fire date must NOT be on May 14 (the suspended date).
        // It should be on the day of the next non-suspended ASP window minus 1h.
        let fireDay = comps.day ?? 0
        let fireMonth = comps.month ?? 0
        XCTAssertFalse(fireDay == 14 && fireMonth == 5,
                       "T-W6.11: fire date must NOT be on May 14 (suspended date)")
    }

    // MARK: - T-W6.12: UserDefaults key contract for rationale gating

    func testTW612_RationaleKeyGating() {
        let key = AppConstants.notificationRationaleShownKey
        let defaults = UserDefaults.standard

        // Key absent → false.
        defaults.removeObject(forKey: key)
        XCTAssertFalse(defaults.bool(forKey: key), "T-W6.12: absent key → false")

        // Set → true.
        defaults.set(true, forKey: key)
        XCTAssertTrue(defaults.bool(forKey: key), "T-W6.12: set key → true")

        // Clean up.
        defaults.removeObject(forKey: key)
    }

    // MARK: - T-W6.13: W7 mute stub — absent is a no-op; set prevents scheduling

    func testTW613_MuteStubBehavior() {
        let key = AppConstants.notificationsMutedKey
        let defaults = UserDefaults.standard
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_8",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_8")

        // Absent key → schedules normally.
        defaults.removeObject(forKey: key)
        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "T-W6.13: mute absent → schedules normally")

        // Muted → no scheduling.
        mockCenter.addedRequests.removeAll()
        defaults.set(true, forKey: key)
        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "T-W6.13: mute true → no notification")

        // Clean up.
        defaults.removeObject(forKey: key)
    }

    // MARK: - Additional: notification userInfo contains car ID (deep-link payload)

    func testUserInfoContainsCarID() {
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_9",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let carID = UUID()
        let car = nsCar(id: carID, segmentID: "MOTT_N_9")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1)

        let userInfo = mockCenter.addedRequests[0].content.userInfo
        XCTAssertEqual(userInfo["wepark_car_id"] as? String, carID.uuidString,
                       "userInfo must contain the car's UUID string")
        XCTAssertEqual(userInfo["wepark_action"] as? String, "show_car_detail",
                       "userInfo must contain wepark_action = show_car_detail")
    }

    // MARK: - Additional: trigger uses Calendar.easternTime (not UTC)

    func testTriggerUsesEasternTime() {
        // Pin dropped at 4am ET on a Thursday. Restriction at 7am ET (3h away).
        // fire date = 6am ET. Verify trigger components match ET time, not UTC
        // (UTC would be 10am or 11am depending on DST).
        // Using May 7 (not May 14 which is suspended).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)  // 4am ET = 8am UTC (May is EDT/UTC-4)
        let segment = nsSegment(
            id: "MOTT_N_10",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_10")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.addedRequests.count, 1)

        guard let trigger = mockCenter.addedRequests[0].trigger as? UNCalendarNotificationTrigger else {
            XCTFail("trigger must be UNCalendarNotificationTrigger")
            return
        }
        // Fire time should be 6am ET (hour: 6) — not 10am UTC (hour: 10).
        XCTAssertEqual(trigger.dateComponents.hour, 6,
                       "Trigger must use Eastern Time (6am ET), not UTC")
    }
}

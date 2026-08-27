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
    /// Badge fix: records every `setBadgeCount` call for assertion.
    var badgeCountCalls: [Int] = []

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

    func setBadgeCount(_ newBadgeCount: Int, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        badgeCountCalls.append(newBadgeCount)
        completionHandler?(nil)
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
        // FT-6: Ensure reminder offsets key is absent so ReminderOffsets.default is used.
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationRationaleShownKey)
        // FT-6: Remove reminder offsets key so FT-6 tests don't bleed into pre-existing tests.
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
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
        // Identifier scheme. FT-6: 1h preset maps to ruleIndex 2 (r2) per spec §4.2.
        XCTAssertEqual(req.identifier, "wepark.pin.\(car.id.uuidString).r2",
                       "T-W6.1: identifier must match scheme (r2 = 1h preset after FT-6)")

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
        // FT-6: 1h preset maps to ruleIndex 2 (r2). The prefix-based cancellation
        // removes all r0–r4 slots; specifically the 1h-scheduled r2 should be present.
        XCTAssertTrue(
            mockCenter.removedPendingIdentifiers.contains("wepark.pin.\(car.id.uuidString).r2"),
            "T-W6.7: correct identifier removed (r2 = 1h preset after FT-6)"
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
        // FT-6: 1h preset maps to ruleIndex 2 (r2). carA's r2 must NOT have been removed.
        XCTAssertFalse(
            mockCenter.removedPendingIdentifiers.contains("wepark.pin.\(carA.id.uuidString).r2"),
            "T-W6.8: carA's identifier must NOT have been removed"
        )
    }

    // MARK: - Build 19: cancelAll(forUUID:) — UUID-only variant used by the remote-clear path

    /// Mirrors T-W6.7 but exercises the UUID-keyed variant added for Build 19's
    /// `ContentView.handleRemoteCarChanged` — used when `parkPinService.parkedCar` is already
    /// nil (a remote clear) by the time cancellation needs to run, so a `ParkedCar` value
    /// isn't available to derive the prefix from.
    func testCancelAllForUUID_RemovesRequest() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_6",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "MOTT_N_6")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.pendingRequests.count, 1, "Prereq: one pending request")

        let exp = expectation(description: "cancelAll(forUUID:) completes")
        DispatchQueue.global().async {
            self.scheduler.cancelAll(forUUID: car.id)
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(mockCenter.pendingRequests.count, 0,
                       "cancelAll(forUUID:) should remove the car's pending requests by UUID alone")
        XCTAssertTrue(
            mockCenter.removedPendingIdentifiers.contains("wepark.pin.\(car.id.uuidString).r2"),
            "correct identifier removed (r2 = 1h preset after FT-6)"
        )
    }

    func testCancelAllForUUID_DifferentUUID_DoesNotRemoveOtherRequests() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "MOTT_N_7",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let carA = nsCar(segmentID: "MOTT_N_7")
        let unrelatedUUID = UUID()

        scheduler.scheduleForTest(for: carA, loadedSegments: [segment], engine: engine, now: now)
        XCTAssertEqual(mockCenter.pendingRequests.count, 1, "Prereq: carA scheduled")

        let exp = expectation(description: "cancelAll(forUUID:) for unrelated UUID completes")
        DispatchQueue.global().async {
            self.scheduler.cancelAll(forUUID: unrelatedUUID)
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(mockCenter.pendingRequests.count, 1, "carA's request must be untouched")
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

// MARK: - FT6ReminderTests

/// FT-6 acceptance-criteria tests.
///
/// Uses MockNotificationCenter, scheduleForTest(for:...offsets:), and nsDate/nsCar/nsSegment
/// helpers from the XCTestCase extension above. Tests are named AC-FT6.x per the spec.
///
/// Each test calls tearDown via XCTest infrastructure. The tearDown method below also cleans
/// up the wepark_reminder_offsets key so tests do not leak global state.
final class FT6ReminderTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var mockCenter: MockNotificationCenter!
    var scheduler: NotificationScheduler!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        mockCenter = MockNotificationCenter()
        scheduler = NotificationScheduler(center: mockCenter)
        // Ensure known-clean state before each test.
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
        super.tearDown()
    }

    // MARK: - AC-FT6.1 — Default serialization and round-trip

    func testFT6_AC1_DefaultSerializationRoundTrip() {
        let original = ReminderOffsets.default
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(ReminderOffsets.self, from: data)

        XCTAssertEqual(decoded, ReminderOffsets.default, "AC-FT6.1: round-trip must equal .default")
        XCTAssertTrue(decoded.remind1Hour, "AC-FT6.1: remind1Hour must be true")
        XCTAssertFalse(decoded.remind15Min, "AC-FT6.1: remind15Min must be false")
        XCTAssertFalse(decoded.remind30Min, "AC-FT6.1: remind30Min must be false")
        XCTAssertFalse(decoded.remind2Hours, "AC-FT6.1: remind2Hours must be false")
        XCTAssertFalse(decoded.remindNightBefore, "AC-FT6.1: remindNightBefore must be false")
    }

    // MARK: - AC-FT6.2 — Missing UserDefaults key returns default

    func testFT6_AC2_MissingKeyReturnsDefault() {
        // Use an ephemeral suite with no key set.
        let suiteName = "ft6-test-suite-\(UUID().uuidString)"
        let ephemeral = UserDefaults(suiteName: suiteName)!
        // Ensure key is absent.
        ephemeral.removeObject(forKey: AppConstants.reminderOffsetsKey)

        let result = ReminderOffsets.load(from: ephemeral)

        XCTAssertEqual(result, ReminderOffsets.default,
                       "AC-FT6.2: missing key must return ReminderOffsets.default")

        // Clean up the ephemeral suite.
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    // MARK: - AC-FT6.3 — Multi-preset scheduling: N requests for N active presets

    func testFT6_AC3_MultiPreset_NRequestsForNActivePresets() {
        // Thu 2026-05-07 at 4:00 ET, ASP Mon/Thu 7:00am → restriction ~3h away.
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC3_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC3_SEG")
        let offsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: false,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: false
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 3,
                       "AC-FT6.3: 3 active presets → 3 requests")

        let ids = Set(mockCenter.addedRequests.map { $0.identifier })
        let expectedIDs: Set<String> = [
            "wepark.pin.\(car.id.uuidString).r0",
            "wepark.pin.\(car.id.uuidString).r2",
            "wepark.pin.\(car.id.uuidString).r3"
        ]
        XCTAssertEqual(ids, expectedIDs,
                       "AC-FT6.3: identifiers must be exactly r0, r2, r3 (set-equal, any order)")
    }

    // MARK: - AC-FT6.4 — Correct fire times for relative presets

    func testFT6_AC4_CorrectFireTimesForRelativePresets() {
        // Thu 2026-05-07 at 4:00 ET, ASP Mon/Thu 7:00am.
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC4_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC4_SEG")
        let offsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: false,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: false
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 3, "AC-FT6.4 prereq")

        // Extract trigger components per identifier.
        func triggerComps(_ ruleIndex: Int) -> DateComponents? {
            let id = "wepark.pin.\(car.id.uuidString).r\(ruleIndex)"
            guard let req = mockCenter.addedRequests.first(where: { $0.identifier == id }),
                  let trigger = req.trigger as? UNCalendarNotificationTrigger else { return nil }
            return trigger.dateComponents
        }

        // r0 (15min): fire 06:45 (7:00 − 15min)
        let r0 = triggerComps(0)
        XCTAssertEqual(r0?.hour, 6, "AC-FT6.4: r0 hour must be 6")
        XCTAssertEqual(r0?.minute, 45, "AC-FT6.4: r0 minute must be 45")
        XCTAssertEqual(r0?.day, 7, "AC-FT6.4: r0 day must be 7 (May 7)")
        XCTAssertEqual(r0?.month, 5, "AC-FT6.4: r0 month must be 5 (May)")

        // r2 (1h): fire 06:00 (7:00 − 1h)
        let r2 = triggerComps(2)
        XCTAssertEqual(r2?.hour, 6, "AC-FT6.4: r2 hour must be 6")
        XCTAssertEqual(r2?.minute, 0, "AC-FT6.4: r2 minute must be 0")
        XCTAssertEqual(r2?.day, 7, "AC-FT6.4: r2 day must be 7 (May 7)")
        XCTAssertEqual(r2?.month, 5, "AC-FT6.4: r2 month must be 5 (May)")

        // r3 (2h): fire 05:00 (7:00 − 2h)
        let r3 = triggerComps(3)
        XCTAssertEqual(r3?.hour, 5, "AC-FT6.4: r3 hour must be 5")
        XCTAssertEqual(r3?.minute, 0, "AC-FT6.4: r3 minute must be 0")
        XCTAssertEqual(r3?.day, 7, "AC-FT6.4: r3 day must be 7 (May 7)")
        XCTAssertEqual(r3?.month, 5, "AC-FT6.4: r3 month must be 5 (May)")
    }

    // MARK: - AC-FT6.5 — Per-reminder past-guard skipping

    func testFT6_AC5_PerReminderPastGuard_AllPast() {
        // now = Thu 2026-05-07 06:50 ET (10 min before 7:00 AM ASP).
        // All 5 fire times are in the past at 6:50.
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 6, minute: 50)
        let segment = nsSegment(
            id: "FT6_AC5A_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC5A_SEG")
        let allOffsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: true,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: allOffsets)

        // 15min fires at 06:45 (past), 30min at 06:30 (past), 1h at 06:00 (past),
        // 2h at 05:00 (past), night-before = yesterday 20:00 (past) → 0 requests.
        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "AC-FT6.5a: all fire times past 6:50 AM → 0 requests")
    }

    func testFT6_AC5_PerReminderPastGuard_SomeActive() {
        // now = Thu 2026-05-07 06:50 ET with restriction at 7:30 AM (40min away).
        // 15min fires 07:15 (future), 30min fires 07:00 (future), 1h fires 06:30 (past),
        // 2h fires 05:30 (past), night-before past → 2 requests (r0, r1).
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 6, minute: 50)
        // ASP Mon/Thu with timeRange start=7:30am = minute 450
        let segment = nsSegment(
            id: "FT6_AC5B_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(450, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC5B_SEG")
        let allOffsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: true,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: true
        )

        // Prereq: restriction ~40min away.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertGreaterThan(restriction.hours, 0.6, "AC-FT6.5b prereq: restriction must be ~40min away")
        XCTAssertLessThan(restriction.hours, 0.7, "AC-FT6.5b prereq: restriction must be ~40min away")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: allOffsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 2,
                       "AC-FT6.5b: 15min + 30min future → 2 requests")
        let ids = Set(mockCenter.addedRequests.map { $0.identifier })
        XCTAssertTrue(ids.contains("wepark.pin.\(car.id.uuidString).r0"),
                      "AC-FT6.5b: r0 (15min) must be scheduled")
        XCTAssertTrue(ids.contains("wepark.pin.\(car.id.uuidString).r1"),
                      "AC-FT6.5b: r1 (30min) must be scheduled")
    }

    // MARK: - AC-FT6.6 — Night-before fires at 20:00 ET the prior evening

    func testFT6_AC6_NightBefore_FiresAt2000ET() {
        // Restriction on Mon 2026-05-11 at 07:00 ET. now = Fri 2026-05-08 12:00 ET.
        // Night-before fire: Sun 2026-05-10 20:00 ET.
        let now = nsDate(year: 2026, month: 5, day: 8, hour: 12, minute: 0)
        // Mon/Thu ASP segment — next restriction is Mon May 11 7:00 AM.
        let segment = nsSegment(
            id: "FT6_AC6_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC6_SEG")
        let offsets = ReminderOffsets(
            remind15Min: false,
            remind30Min: false,
            remind1Hour: false,
            remind2Hours: false,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 1, "AC-FT6.6: 1 night-before request")

        guard let trigger = mockCenter.addedRequests[0].trigger as? UNCalendarNotificationTrigger else {
            XCTFail("AC-FT6.6: trigger must be UNCalendarNotificationTrigger")
            return
        }
        let comps = trigger.dateComponents
        // Night-before = Sun May 10 20:00 ET.
        XCTAssertEqual(comps.day,   10, "AC-FT6.6: fire day must be 10 (Sun May 10)")
        XCTAssertEqual(comps.month,  5, "AC-FT6.6: fire month must be 5 (May)")
        XCTAssertEqual(comps.hour,  20, "AC-FT6.6: fire hour must be 20 (8 PM ET)")
        XCTAssertEqual(comps.minute, 0, "AC-FT6.6: fire minute must be 0")

        let id = mockCenter.addedRequests[0].identifier
        XCTAssertEqual(id, "wepark.pin.\(car.id.uuidString).r4",
                       "AC-FT6.6: identifier must be r4 (night-before ruleIndex)")
    }

    // MARK: - AC-FT6.7 — Night-before skip-if-past

    func testFT6_AC7_NightBefore_SkipIfPast() {
        // Restriction Mon 2026-05-11 at 07:00 ET.
        // now = Sun 2026-05-10 21:00 ET (1h AFTER night-before fire time of 20:00).
        let now = nsDate(year: 2026, month: 5, day: 10, hour: 21, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC7_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC7_SEG")
        let offsets = ReminderOffsets(
            remind15Min: false,
            remind30Min: false,
            remind1Hour: false,
            remind2Hours: false,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "AC-FT6.7: night-before fire time 20:00 is past at 21:00 → 0 requests")
    }

    // MARK: - AC-FT6.8 — Night-before same-day skip

    func testFT6_AC8_NightBefore_SameDaySkip() {
        // now = Mon 2026-05-11 06:00 ET, restriction at 07:00 ET same day.
        // Night-before fire would be Sun 2026-05-10 20:00 ET — in the past.
        let now = nsDate(year: 2026, month: 5, day: 11, hour: 6, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC8_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC8_SEG")
        let offsets = ReminderOffsets(
            remind15Min: false,
            remind30Min: false,
            remind1Hour: false,
            remind2Hours: false,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "AC-FT6.8: night-before fire (Sun 20:00) is past on Mon 06:00 → 0 requests")
    }

    // MARK: - AC-FT6.9 — Night-before DST boundary (spring forward)

    func testFT6_AC9_NightBefore_DSTSpringForward() {
        // Restriction on Sun 2026-03-08 at 07:00 ET (DST springs forward that morning:
        // clocks jump 2:00 → 3:00 AM, so after the spring-forward it's EDT = UTC-4).
        // now = Sat 2026-03-07 10:00 ET (still EST = UTC-5).
        //
        // Expected night-before fire: 2026-03-07 20:00 ET (still in EST = UTC-5,
        // i.e., 01:00 UTC on 2026-03-08, BEFORE the spring-forward at 07:00).
        //
        // We use a noParking rule with days: [0] (Sunday) since no ASP category covers Sunday.
        // This exercises computeHoursUntilActive, which correctly finds the Sun 7:00 AM window.
        let now = nsDate(year: 2026, month: 3, day: 7, hour: 10, minute: 0)

        // days: [0] = Sunday. timeRange 420–570 = 7:00 AM – 9:30 AM.
        let segment = nsSegment(
            id: "FT6_AC9_SEG",
            rules: [nsRule(category: .noParking, days: [0], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC9_SEG")
        let offsets = ReminderOffsets(
            remind15Min: false,
            remind30Min: false,
            remind1Hour: false,
            remind2Hours: false,
            remindNightBefore: true
        )

        // Prereq: the engine reports ~21 WALL-CLOCK hours from Sat 10:00 to Sun 7:00
        // (day/minute arithmetic, the W3 engine behavior). Note the true elapsed UTC
        // interval is only 20h because clocks spring forward (the 2 AM hour is skipped) —
        // but the engine counts wall-clock hours, so ~21 is the correct expectation here.
        // The night-before fire date is computed independently from the restriction's
        // calendar day (Sun) minus one day at 20:00 ET, so the DST hour-count quirk does
        // not affect the assertions below.
        let restriction = engine.nextRestriction(for: segment, at: now)
        XCTAssertFalse(restriction.isUnrestricted, "AC-FT6.9 prereq: must find a restriction")
        XCTAssertGreaterThan(restriction.hours, 20.9, "AC-FT6.9 prereq: restriction ~21 wall-clock h away")
        XCTAssertLessThan(restriction.hours, 21.1, "AC-FT6.9 prereq: restriction ~21 wall-clock h away")

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "AC-FT6.9: 1 night-before request")

        guard let trigger = mockCenter.addedRequests[0].trigger as? UNCalendarNotificationTrigger else {
            XCTFail("AC-FT6.9: trigger must be UNCalendarNotificationTrigger")
            return
        }
        let comps = trigger.dateComponents
        // Night-before = Sat 2026-03-07 20:00 ET (EST, UTC-5 → 01:00 UTC on Mar 8).
        // DST correctness: Calendar.easternTime.date(from:) with .easternTime timeZone produces
        // the correct absolute UTC instant for 20:00 ET on Mar 7 (EST), not 20:00 EDT.
        XCTAssertEqual(comps.day,    7, "AC-FT6.9: fire day must be 7 (Sat Mar 7)")
        XCTAssertEqual(comps.month,  3, "AC-FT6.9: fire month must be 3 (March)")
        XCTAssertEqual(comps.hour,  20, "AC-FT6.9: fire hour must be 20 (8 PM ET)")
        XCTAssertEqual(comps.minute, 0, "AC-FT6.9: fire minute must be 0")
    }

    // MARK: - AC-FT6.10 — Single-preset default matches prior behavior

    func testFT6_AC10_DefaultOffsets_SingleRequest_PriorBehaviorParity() {
        // Restriction 3h away on Thu 2026-05-07. Default offsets = {remind1Hour: true only}.
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC10_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC10_SEG")
        let offsets = ReminderOffsets.default  // remind1Hour=true only

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: offsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "AC-FT6.10: default offsets (1h only) → exactly 1 request")

        let id = mockCenter.addedRequests[0].identifier
        XCTAssertEqual(id, "wepark.pin.\(car.id.uuidString).r2",
                       "AC-FT6.10: default 1h preset uses ruleIndex 2 (r2)")

        guard let trigger = mockCenter.addedRequests[0].trigger as? UNCalendarNotificationTrigger else {
            XCTFail("AC-FT6.10: trigger must be UNCalendarNotificationTrigger")
            return
        }
        let comps = trigger.dateComponents
        XCTAssertEqual(comps.hour, 6,
                       "AC-FT6.10: fire hour = 6 (7:00 AM - 1h = 6:00 AM)")
        XCTAssertEqual(comps.minute, 0,
                       "AC-FT6.10: fire minute = 0")
    }

    // MARK: - AC-FT6.11 — notifyOnRestriction = false blocks all presets

    func testFT6_AC11_NotifyOnRestrictionFalse_BlocksAllPresets() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC11_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        // Car with notifyOnRestriction = false.
        let car = nsCar(segmentID: "FT6_AC11_SEG", notifyOnRestriction: false)
        let allOffsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: true,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: allOffsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "AC-FT6.11: notifyOnRestriction=false → 0 requests regardless of offsets")
    }

    // MARK: - AC-FT6.12 — Global mute blocks all presets

    func testFT6_AC12_GlobalMute_BlocksAllPresets() {
        UserDefaults.standard.set(true, forKey: AppConstants.notificationsMutedKey)
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC12_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC12_SEG", notifyOnRestriction: true)
        let allOffsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: true,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: true
        )

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: allOffsets)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "AC-FT6.12: global mute true → 0 requests regardless of offsets")
    }

    // MARK: - AC-FT6.13 — Cancellation removes all ruleIndexes by prefix

    func testFT6_AC13_Cancellation_RemovesAllRuleIndexesByPrefix() {
        // now = Fri 2026-05-08 12:00 ET, restriction Mon 2026-05-11 07:00 AM (Mon/Thu ASP).
        // All 5 fire times are in the future at Fri noon, so all 5 slots r0–r4 schedule —
        // this exercises the night-before slot (r4), which the prior setup (04:00 Thu) skipped.
        let now = nsDate(year: 2026, month: 5, day: 8, hour: 12, minute: 0)
        let segment = nsSegment(
            id: "FT6_AC13_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC13_SEG")
        let allOffsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: true,
            remind1Hour: true,
            remind2Hours: true,
            remindNightBefore: true  // Sun 05-10 20:00 ET is future at Fri noon → schedules r4
        )

        // Schedule with all 5 presets active (all fire times future from Fri noon).
        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now, offsets: allOffsets)
        XCTAssertEqual(mockCenter.addedRequests.count, 5,
                       "AC-FT6.13 prereq: 5 requests for r0, r1, r2, r3, r4")

        // Populate pendingRequests from added requests (MockNotificationCenter tracks both).
        XCTAssertEqual(mockCenter.pendingRequests.count, 5, "AC-FT6.13 prereq: 5 pending requests")

        // Cancel using prefix.
        let exp = expectation(description: "AC-FT6.13: cancelAll completes")
        DispatchQueue.global().async {
            self.scheduler.cancelAll(for: car)
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(mockCenter.pendingRequests.count, 0,
                       "AC-FT6.13: all pending requests removed by prefix cancellation")

        // Verify all 5 scheduled identifiers were removed — including the night-before slot r4.
        let removed = Set(mockCenter.removedPendingIdentifiers)
        for ruleIndex in [0, 1, 2, 3, 4] {
            let expectedID = "wepark.pin.\(car.id.uuidString).r\(ruleIndex)"
            XCTAssertTrue(removed.contains(expectedID),
                          "AC-FT6.13: r\(ruleIndex) identifier must be in removedPendingIdentifiers")
        }
    }

    // MARK: - AC-FT6.14 — parkUntil guard is per-reminder

    func testFT6_AC14_ParkUntilGuard_IsPerReminder() {
        // now = Thu 2026-05-07 04:00 ET, restriction at 07:00 AM (3h away).
        // parkUntil = 06:30 AM ET (90 min from now).
        // Active: 1h before (fires 06:00 — before parkUntil 06:30 → schedules r2)
        //         15min before (fires 06:45 — after parkUntil 06:30 → skipped r0)
        let now     = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let parkUntil = nsDate(year: 2026, month: 5, day: 7, hour: 6, minute: 30)
        let segment = nsSegment(
            id: "FT6_AC14_SEG",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "FT6_AC14_SEG")
        let offsets = ReminderOffsets(
            remind15Min: true,
            remind30Min: false,
            remind1Hour: true,
            remind2Hours: false,
            remindNightBefore: false
        )

        scheduler.scheduleForTest(
            for: car,
            loadedSegments: [segment],
            engine: engine,
            now: now,
            offsets: offsets,
            parkUntil: parkUntil
        )

        // 1h fires 06:00 (before parkUntil 06:30) → schedules.
        // 15min fires 06:45 (after parkUntil 06:30) → skipped.
        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "AC-FT6.14: only 1h reminder passes parkUntil guard → 1 request")

        let id = mockCenter.addedRequests[0].identifier
        XCTAssertEqual(id, "wepark.pin.\(car.id.uuidString).r2",
                       "AC-FT6.14: the scheduled request must be r2 (1h)")
    }

    // MARK: - AC-FT6.15 — ReminderOffsets.load + save round-trip via injected defaults

    func testFT6_AC15_LoadSaveRoundTrip_InjectedDefaults() {
        let suiteName = "ft6-roundtrip-suite-\(UUID().uuidString)"
        let injected = UserDefaults(suiteName: suiteName)!

        let original = ReminderOffsets(
            remind15Min: true,
            remind30Min: false,
            remind1Hour: false,
            remind2Hours: true,
            remindNightBefore: true
        )

        ReminderOffsets.save(original, to: injected)
        let loaded = ReminderOffsets.load(from: injected)

        XCTAssertEqual(loaded.remind15Min,    original.remind15Min,    "AC-FT6.15: remind15Min must match")
        XCTAssertEqual(loaded.remind30Min,    original.remind30Min,    "AC-FT6.15: remind30Min must match")
        XCTAssertEqual(loaded.remind1Hour,    original.remind1Hour,    "AC-FT6.15: remind1Hour must match")
        XCTAssertEqual(loaded.remind2Hours,   original.remind2Hours,   "AC-FT6.15: remind2Hours must match")
        XCTAssertEqual(loaded.remindNightBefore, original.remindNightBefore, "AC-FT6.15: remindNightBefore must match")
        XCTAssertEqual(loaded, original, "AC-FT6.15: full equality must hold after round-trip")

        // Clean up.
        UserDefaults.standard.removeSuite(named: suiteName)
    }

    // MARK: - Badge fix: clearBadge()

    /// Regression test for "the app icon badge never clears": `clearBadge()` must route
    /// through the injectable `center` to `setBadgeCount(0, ...)`, exactly once per call,
    /// so `ContentView.handleScenePhaseChange` clearing on foreground is verifiable without
    /// a real device/simulator.
    func testBadgeFix_ClearBadge_CallsSetBadgeCountZero() {
        scheduler.clearBadge()

        XCTAssertEqual(mockCenter.badgeCountCalls, [0],
                        "clearBadge() must call setBadgeCount(0, ...) exactly once")
    }
}

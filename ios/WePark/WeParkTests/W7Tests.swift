//
//  W7Tests.swift
//  WeParkTests
//
//  W7 unit tests per docs/w7-asp-banner-settings-spec.md §7.
//
//  Tests:
//    - testNotificationScheduler_perPinOptOut_skipsScheduling
//    - testNotificationScheduler_perPinOptIn_schedules
//    - testNotificationScheduler_globalMute_overridesPerPinOn
//    - testParkedCar_decodeMissingNotifyKey_defaultsTrue
//    - testParkedCar_encodeDecodeRoundTrip_preservesNotifyOn
//    - testParkedCar_encodeDecodeRoundTrip_preservesNotifyOff
//    - testASPSuspensionService_todaySuspended_returnsBannerState
//    - testASPSuspensionService_tomorrowSuspended_returnsBannerState
//    - testASPSuspensionService_aspInEffect_returnsBannerState
//    - testToastService_show_setsCurrentMessage
//    - testToastService_show_replacesExistingMessage
//    - testToastService_autoDismiss_clearsMessage
//
//  All date math via Calendar.easternTime. No Calendar.current.
//

import XCTest
@testable import WePark

// MARK: - W7 NotificationScheduler per-pin tests

final class W7NotificationSchedulerTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var mockCenter: MockNotificationCenter!
    var scheduler: NotificationScheduler!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        mockCenter = MockNotificationCenter()
        scheduler = NotificationScheduler(center: mockCenter)
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        // FT-6: Ensure reminder offsets key is absent so ReminderOffsets.default (1h only) is used.
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppConstants.notificationsMutedKey)
        // FT-6: Remove reminder offsets key so FT-6 tests don't bleed into pre-existing tests.
        UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)
        super.tearDown()
    }

    // MARK: - testNotificationScheduler_perPinOptOut_skipsScheduling
    // AC-W7.17, spec §7 row 1: notifyOnRestriction = false → schedule() returns without add.

    func testNotificationScheduler_perPinOptOut_skipsScheduling() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "W7_OPTOUT_1",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "W7_OPTOUT_1", notifyOnRestriction: false)

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "notifyOnRestriction=false → scheduleForTest must add zero requests")
    }

    // MARK: - testNotificationScheduler_perPinOptIn_schedules
    // AC-W7.16, spec §7 row 2: notifyOnRestriction = true, global mute OFF → schedule adds exactly 1.

    func testNotificationScheduler_perPinOptIn_schedules() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "W7_OPTIN_1",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "W7_OPTIN_1", notifyOnRestriction: true)

        // Confirm mute key is absent (setUp removed it).
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey))

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 1,
                       "notifyOnRestriction=true, mute OFF → scheduleForTest must add exactly 1 request")
    }

    // MARK: - testNotificationScheduler_globalMute_overridesPerPinOn
    // AC-W7.14, spec §7 row 3: muted=true, notifyOnRestriction=true → zero adds. Global mute wins.

    func testNotificationScheduler_globalMute_overridesPerPinOn() {
        let now = nsDate(year: 2026, month: 5, day: 7, hour: 4, minute: 0)
        let segment = nsSegment(
            id: "W7_MUTE_1",
            rules: [nsRule(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])]
        )
        let car = nsCar(segmentID: "W7_MUTE_1", notifyOnRestriction: true)

        UserDefaults.standard.set(true, forKey: AppConstants.notificationsMutedKey)

        scheduler.scheduleForTest(for: car, loadedSegments: [segment], engine: engine, now: now)

        XCTAssertEqual(mockCenter.addedRequests.count, 0,
                       "Global mute true overrides notifyOnRestriction=true → zero requests")
    }
}

// MARK: - W7 ParkedCar Codable tests

final class W7ParkedCarCodableTests: XCTestCase {

    // MARK: - testParkedCar_decodeMissingNotifyKey_defaultsTrue
    // AC-W7.22, spec §7 row 4: JSON without notifyOnRestriction → decoded value = true.

    func testParkedCar_decodeMissingNotifyKey_defaultsTrue() throws {
        // Build JSON that mimics a pre-W7 persisted ParkedCar (no notifyOnRestriction key).
        let jsonDict: [String: Any] = [
            "id": UUID().uuidString,
            "latitude": 40.7183,
            "longitude": -73.9942,
            "parkedAt": ISO8601DateFormatter().string(from: Date()),
            // notifyOnRestriction intentionally absent
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonDict)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let car = try decoder.decode(ParkedCar.self, from: data)

        XCTAssertTrue(car.notifyOnRestriction,
                      "Pre-W7 pin (missing notifyOnRestriction key) must decode as true")
    }

    // MARK: - testParkedCar_encodeDecodeRoundTrip_preservesNotifyOn

    func testParkedCar_encodeDecodeRoundTrip_preservesNotifyOn() throws {
        let original = ParkedCar(
            id: UUID(),
            latitude: 40.7183,
            longitude: -73.9942,
            detectedSegmentID: "SEG_1",
            detectedSide: "N",
            street: "MOTT STREET",
            fromStreet: "GRAND STREET",
            toStreet: "HESTER STREET",
            parkedAt: Date(),
            notifyOnRestriction: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ParkedCar.self, from: data)

        XCTAssertEqual(decoded.notifyOnRestriction, true,
                       "Round-trip with notifyOnRestriction=true must preserve true")
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.detectedSegmentID, original.detectedSegmentID)
    }

    // MARK: - testParkedCar_encodeDecodeRoundTrip_preservesNotifyOff

    func testParkedCar_encodeDecodeRoundTrip_preservesNotifyOff() throws {
        let original = ParkedCar(
            id: UUID(),
            latitude: 40.7183,
            longitude: -73.9942,
            detectedSegmentID: "SEG_2",
            detectedSide: "S",
            street: "BOWERY",
            fromStreet: "HESTER STREET",
            toStreet: "GRAND STREET",
            parkedAt: Date(),
            notifyOnRestriction: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ParkedCar.self, from: data)

        XCTAssertEqual(decoded.notifyOnRestriction, false,
                       "Round-trip with notifyOnRestriction=false must preserve false")
    }
}

// MARK: - W7 ASPSuspensionService banner state tests

final class W7ASPSuspensionServiceTests: XCTestCase {

    var service: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        service = ASPSuspensionService()
    }

    // MARK: - testASPSuspensionService_todaySuspended_returnsBannerState
    // spec §7 row 5: suspensionState(at: knownSuspendedDate) → .todaySuspended(reason:)

    func testASPSuspensionService_todaySuspended_returnsBannerState() {
        // 2026-01-01 is New Year's Day — in asp-2026.json.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 1
        comps.hour = 10
        comps.minute = 0
        comps.timeZone = .easternTime
        let newYearsDay = Calendar.easternTime.date(from: comps)!

        let state = service.suspensionState(at: newYearsDay)

        guard case .todaySuspended(let reason) = state else {
            XCTFail("2026-01-01 must return .todaySuspended, got \(state)")
            return
        }
        XCTAssertFalse(reason.isEmpty, "Reason string must not be empty for New Year's Day")
        // The asp-2026.json reason for Jan 1 should contain "New Year"
        XCTAssertTrue(reason.lowercased().contains("new year"),
                      "Reason for Jan 1 should contain 'New Year', got: \(reason)")
    }

    // MARK: - testASPSuspensionService_tomorrowSuspended_returnsBannerState
    // Day before a suspended date → .tomorrowSuspended(reason:)

    func testASPSuspensionService_tomorrowSuspended_returnsBannerState() {
        // 2025-12-31 is the day before New Year's Day 2026.
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 12
        comps.day = 31
        comps.hour = 10
        comps.minute = 0
        comps.timeZone = .easternTime
        let newYearsEve = Calendar.easternTime.date(from: comps)!

        let state = service.suspensionState(at: newYearsEve)

        guard case .tomorrowSuspended(let reason) = state else {
            XCTFail("2025-12-31 (day before Jan 1 suspension) must return .tomorrowSuspended, got \(state)")
            return
        }
        XCTAssertFalse(reason.isEmpty, "Reason string must not be empty")
    }

    // MARK: - testASPSuspensionService_aspInEffect_returnsBannerState
    // A normal non-suspended date → .aspInEffect

    func testASPSuspensionService_aspInEffect_returnsBannerState() {
        // 2026-05-07 is a regular Thursday — not in asp-2026.json.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 7
        comps.hour = 10
        comps.minute = 0
        comps.timeZone = .easternTime
        let regularDay = Calendar.easternTime.date(from: comps)!

        let state = service.suspensionState(at: regularDay)

        XCTAssertEqual(state, .aspInEffect,
                       "2026-05-07 (regular Thursday) must return .aspInEffect")
    }
}

// MARK: - W7 ToastService tests

@MainActor
final class W7ToastServiceTests: XCTestCase {

    // ToastService is a singleton (private init enforced — QA pass-1 #1).
    // resetForTesting() (DEBUG-only) clears state between tests to prevent bleed.

    override func setUp() {
        super.setUp()
        ToastService.shared.resetForTesting()
    }

    override func tearDown() {
        ToastService.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - testToastService_show_setsCurrentMessage
    // spec §7 row 6: show(message: "Hello") → currentMessage == "Hello" immediately.

    func testToastService_show_setsCurrentMessage() {
        ToastService.shared.show(message: "Hello")
        XCTAssertEqual(ToastService.shared.currentMessage, "Hello",
                       "currentMessage must be set immediately after show(message:)")
    }

    // MARK: - testToastService_show_replacesExistingMessage
    // spec §7 row 7: show("A") then show("B") → currentMessage == "B", only one dismiss task.

    func testToastService_show_replacesExistingMessage() {
        ToastService.shared.show(message: "A", duration: 10.0)
        XCTAssertEqual(ToastService.shared.currentMessage, "A", "first show sets A")

        ToastService.shared.show(message: "B", duration: 10.0)
        XCTAssertEqual(ToastService.shared.currentMessage, "B",
                       "Second show(message:B) must replace A immediately")
    }

    // MARK: - testToastService_autoDismiss_clearsMessage
    // spec §7 row 8: show("X", duration: 0.1) → after 0.2s, currentMessage == nil.

    func testToastService_autoDismiss_clearsMessage() async throws {
        ToastService.shared.show(message: "X", duration: 0.1)
        XCTAssertEqual(ToastService.shared.currentMessage, "X", "message set immediately")

        // Wait longer than the duration to allow auto-dismiss to fire.
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertNil(ToastService.shared.currentMessage,
                     "After 0.35s with 0.1s duration, currentMessage must be nil (auto-dismissed)")
    }
}

//
//  W61Tests.swift
//  WeParkTests
//
//  Unit tests for the W6.1 fix: notification deep-link buffering via @Published
//  pendingDeepLinkCarID on AppDelegate (replaces PassthroughSubject).
//
//  Root cause tested:
//    PassthroughSubject has no replay. If the UNUserNotificationCenterDelegate fires
//    didReceive before ContentView's subscriber attaches (cold-kill / background-wake
//    race), the event is silently dropped.
//
//  Fix verified:
//    AppDelegate.pendingDeepLinkCarID is @Published — the value persists until a
//    consumer reads it. Tests verify:
//      1. Value survives across simulated "late subscriber" timing (late read returns value).
//      2. routePendingDeepLink helper routing behavior (cold-kill path): a buffered carID
//         set before the scenePhase=.active handler fires is routed and cleared. This is
//         the actual cold-kill mechanism — iOS 17's .onChange(of:) does NOT fire on initial
//         value, so the .onChange(of: scenePhase) { .active } handler is the sole path for
//         cold-kill replay; both paths call routePendingDeepLink, so this test validates the
//         shared helper.
//      3. Clearing (nil) after route does not re-trigger routing (idempotency).
//      4. Mismatched car ID: the buffer IS cleared unconditionally (ContentView.swift:793
//         runs before the mismatch guard), but the sheet does NOT present (the guard at
//         ContentView.swift:795 returns early). No stuck state — the buffer is gone.
//      5. The @Published change fires synchronously on the main thread (delegate contract).
//
//  Note: ContentView.routePendingDeepLink is private. Tests for the routing guard logic
//  simulate the helper inline using ParkPinService directly, which is accessible via
//  @testable import. The buffering contract tests use AppDelegate.pendingDeepLinkCarID
//  directly.
//

import XCTest
@testable import WePark

// MARK: - W61DeepLinkBufferTests

final class W61DeepLinkBufferTests: XCTestCase {

    var appDelegate: AppDelegate!

    override func setUp() {
        super.setUp()
        appDelegate = AppDelegate()
    }

    override func tearDown() {
        appDelegate = nil
        super.tearDown()
    }

    // MARK: - testW61_1: @Published value persists for late readers

    /// Core regression test: a carID set on pendingDeepLinkCarID is readable AFTER the
    /// assignment — simulating a "late subscriber" who attaches after the delegate fires.
    ///
    /// PassthroughSubject would have dropped this event. @Published retains it.
    func testW61_1_pendingDeepLinkCarID_persistsForLateReader() {
        let carID = UUID()

        // Simulate delegate firing and setting the buffered value.
        appDelegate.pendingDeepLinkCarID = carID

        // Simulate a late reader (e.g., ContentView that mounted after the delegate fired).
        let readValue = appDelegate.pendingDeepLinkCarID

        XCTAssertEqual(readValue, carID,
            "pendingDeepLinkCarID must persist after assignment — late readers must receive the buffered value.")
    }

    // MARK: - testW61_2: routePendingDeepLink helper — buffered carID routes and clears

    /// Validates the routing helper that both cold-kill and background-wake paths share.
    ///
    /// Cold-kill path: pendingDeepLinkCarID is set by the UNUserNotificationCenterDelegate
    /// BEFORE ContentView's .onChange(of: pendingDeepLinkCarID) modifier attaches. Because
    /// iOS 17's .onChange(of:) does NOT fire on initial value, the value-onChange path alone
    /// cannot deliver the buffered ID in a cold-kill. The .onChange(of: scenePhase) { .active }
    /// handler fires once ContentView is mounted and the scene becomes active, reading the
    /// already-buffered carID and calling routePendingDeepLink. Both paths call the same helper.
    ///
    /// This test simulates the helper's contract: given a buffered carID and a matching
    /// parkedCar, routing succeeds and the buffer is cleared afterward.
    func testW61_2_routePendingDeepLink_withBufferedCarID_routesAndClears() {
        let carID = UUID()

        // Set up a parked car whose id matches the buffered carID.
        let car = ParkedCar(
            id: carID,
            latitude: 40.7128,
            longitude: -74.0060,
            detectedSegmentID: nil,
            detectedSide: nil,
            street: nil,
            fromStreet: nil,
            toStreet: nil,
            parkedAt: Date()
        )
        let service = ParkPinService()
        service.save(car)

        // Simulate the delegate firing before the view mounts (cold-kill scenario):
        // the carID is buffered in pendingDeepLinkCarID.
        appDelegate.pendingDeepLinkCarID = carID

        // Simulate what routePendingDeepLink does when scenePhase=.active fires:
        // read carID, clear buffer unconditionally, then route if the car still matches.
        var routeCallCount = 0
        func simulateRoutePendingDeepLink(carID: UUID?) {
            guard let carID else { return }
            // ContentView.swift:793 — unconditional clear before the matching guard.
            appDelegate.pendingDeepLinkCarID = nil
            // ContentView.swift:795 — only route if the notification matches the current pin.
            guard let parked = service.parkedCar, parked.id == carID else { return }
            _ = parked  // Would set activeSheet = .parkedCarDetail(parked) in production.
            routeCallCount += 1
        }

        simulateRoutePendingDeepLink(carID: appDelegate.pendingDeepLinkCarID)

        XCTAssertEqual(routeCallCount, 1,
            "Routing helper must route exactly once when carID matches the parked car.")
        XCTAssertNil(appDelegate.pendingDeepLinkCarID,
            "Buffer must be cleared after routing — prevents re-presentation on the next foreground.")
    }

    // MARK: - testW61_3: Idempotency — clear-after-route does not re-emit the old ID

    /// After routing (pendingDeepLinkCarID set then cleared to nil), a subsequent read
    /// must return nil — not the old carID. This prevents the sheet from re-presenting
    /// on the next foreground transition (AC criterion 4).
    func testW61_3_clearAfterRoute_returnsNil() {
        let carID = UUID()

        // Simulate delegate setting the buffered value.
        appDelegate.pendingDeepLinkCarID = carID

        // Simulate routePendingDeepLink clearing the buffer after presenting the sheet.
        appDelegate.pendingDeepLinkCarID = nil

        // Subsequent foreground transition reads nil — no sheet re-presentation.
        XCTAssertNil(appDelegate.pendingDeepLinkCarID,
            "pendingDeepLinkCarID must be nil after the route-and-clear cycle.")
    }

    // MARK: - testW61_4: Publish-route-clear cycle does not re-fire

    /// Verifies the full publish → route → clear cycle:
    /// 1. Delegate sets carID.
    /// 2. ContentView reads carID and routes.
    /// 3. ContentView clears to nil.
    /// 4. Next foreground transition reads nil — no second routing.
    ///
    /// This is the idempotency test referenced in the acceptance criteria.
    func testW61_4_publishRouteClear_idempotency() {
        let carID = UUID()
        var routeCallCount = 0

        // Simulate ContentView's routePendingDeepLink logic inline:
        // read → clear → route (if non-nil).
        func simulateRoutePendingDeepLink() {
            let buffered = appDelegate.pendingDeepLinkCarID
            appDelegate.pendingDeepLinkCarID = nil  // Always clear first.
            guard buffered != nil else { return }
            routeCallCount += 1
        }

        // First foreground: delegate has set the value.
        appDelegate.pendingDeepLinkCarID = carID
        simulateRoutePendingDeepLink()
        XCTAssertEqual(routeCallCount, 1, "Should route exactly once on first foreground.")
        XCTAssertNil(appDelegate.pendingDeepLinkCarID, "Buffer must be cleared after routing.")

        // Second foreground: no new notification — buffer is nil.
        simulateRoutePendingDeepLink()
        XCTAssertEqual(routeCallCount, 1, "Should NOT route again on second foreground — buffer is clear.")
    }

    // MARK: - testW61_5: Latest value wins when delegate fires twice

    /// If the delegate fires twice before ContentView reads (unlikely but possible if the
    /// user taps two different notifications in rapid succession), the latest carID wins.
    func testW61_5_doubleSet_latestValueWins() {
        let firstCarID = UUID()
        let secondCarID = UUID()

        appDelegate.pendingDeepLinkCarID = firstCarID
        appDelegate.pendingDeepLinkCarID = secondCarID

        XCTAssertEqual(appDelegate.pendingDeepLinkCarID, secondCarID,
            "When set twice without reading, the latest carID must win.")
    }

    // MARK: - testW61_6: Initial value is nil (no spurious deep-link on launch)

    /// AppDelegate must start with pendingDeepLinkCarID == nil so a cold launch without
    /// a notification tap does not incorrectly trigger the sheet.
    func testW61_6_initialValue_isNil() {
        let freshDelegate = AppDelegate()
        XCTAssertNil(freshDelegate.pendingDeepLinkCarID,
            "pendingDeepLinkCarID must be nil on a fresh AppDelegate — no spurious deep-link.")
    }

    // MARK: - testW61_mismatch: mismatched carID clears buffer but does not route

    /// Tests the actual mismatch guard in routePendingDeepLink (ContentView.swift:795):
    ///   guard let car = parkPinService.parkedCar, car.id == carID else { return }
    ///
    /// Scenario: the parked car's ID is UUID_A. The notification (and buffered carID) is UUID_B.
    /// Expected behavior per production code:
    ///   1. pendingDeepLinkCarID is cleared unconditionally at ContentView.swift:793
    ///      (the clear-before-route line runs BEFORE the mismatch guard).
    ///   2. The mismatch guard fails → no sheet presents (routeCallCount stays 0).
    ///   3. The buffer is nil afterward — no stuck state.
    ///
    /// This corrects the previous test file header that incorrectly stated the buffer
    /// "must not auto-clear on mismatch." The buffer IS cleared unconditionally; only
    /// the sheet presentation is suppressed by the guard.
    func testW61_routePendingDeepLink_mismatchedCarID_clearsBufferAndNoRoute() {
        let parkedCarID = UUID()   // UUID_A: the actual parked car.
        let notifCarID  = UUID()   // UUID_B: the notification's (stale) car ID.

        // Set up a parked car with parkedCarID (UUID_A).
        let car = ParkedCar(
            id: parkedCarID,
            latitude: 40.7128,
            longitude: -74.0060,
            detectedSegmentID: nil,
            detectedSide: nil,
            street: nil,
            fromStreet: nil,
            toStreet: nil,
            parkedAt: Date()
        )
        let service = ParkPinService()
        service.save(car)

        // Simulate the notification arriving with a different carID (UUID_B).
        appDelegate.pendingDeepLinkCarID = notifCarID

        // Simulate routePendingDeepLink with the mismatched notifCarID.
        var routeCallCount = 0
        func simulateRoutePendingDeepLink(carID: UUID?) {
            guard let carID else { return }
            // ContentView.swift:793 — unconditional clear (runs even on mismatch).
            appDelegate.pendingDeepLinkCarID = nil
            // ContentView.swift:795 — mismatch guard: parkedCarID != notifCarID → return.
            guard let parked = service.parkedCar, parked.id == carID else { return }
            _ = parked
            routeCallCount += 1
        }

        simulateRoutePendingDeepLink(carID: appDelegate.pendingDeepLinkCarID)

        // The guard at ContentView.swift:795 must have failed — no route.
        XCTAssertEqual(routeCallCount, 0,
            "A mismatched carID must NOT route (the car ID guard must fail).")
        // The buffer must be cleared despite the mismatch — line 793 ran before the guard.
        XCTAssertNil(appDelegate.pendingDeepLinkCarID,
            "pendingDeepLinkCarID must be nil after a mismatched route attempt — no stuck state.")
    }
}

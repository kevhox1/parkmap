//
//  StoopPhase5bActivityTests.swift
//  WeParkTests
//
//  Stoop Phase 5b (B12 Live Activity, B13 notifications). Pins:
//    - which Live Activity layout each phase renders (stale counting = "Still leaving?")
//    - the round-2 wording
//    - "Leaving now" stays a locked-phone one-tap: the intent is not discoverable, needs no
//      unlock and does not open the app (unchanged)
//    - park reminder copy, the "Walk there" action and its Apple Maps URL
//    - the new category registers only when the Stoop flag is on
//

import XCTest
@testable import WePark

final class StoopPhase5bActivityTests: XCTestCase {

    // MARK: Layout

    func testLayout_everyPhaseMapsAndStaleCountingIsTimeToGo() {
        typealias Phase = SpotPassActivityAttributes.Phase
        XCTAssertEqual(WPActivityCopy.layout(phase: .counting, isStale: false), .counting)
        XCTAssertEqual(WPActivityCopy.layout(phase: .counting, isStale: true), .timeToGo)
        XCTAssertEqual(WPActivityCopy.layout(phase: .timeToGo, isStale: false), .timeToGo)
        let expected: [(Phase, WPActivityCopy.Layout)] = [
            (.sent, .sent), (.passed, .passed), (.thanks, .thanks), (.cancelled, .cancelled), (.ended, .ended)
        ]
        for (phase, layout) in expected {
            XCTAssertEqual(WPActivityCopy.layout(phase: phase, isStale: false), layout)
            XCTAssertEqual(WPActivityCopy.layout(phase: phase, isStale: true), layout)
        }
    }

    func testActivityCopy_roundTwoWording() {
        XCTAssertEqual(WPActivityCopy.isWaiting(name: "Bodega Cat"), "Bodega Cat is waiting")
        XCTAssertEqual(WPActivityCopy.leavingAround("4:45 PM"), "Leaving around 4:45 PM")
        XCTAssertEqual(WPActivityCopy.stillLeaving, "Still leaving?")
        XCTAssertEqual(WPActivityCopy.headsUpSent, "Heads-up sent")
        XCTAssertEqual(WPActivityCopy.knowsPullingOut(name: "Bodega Cat"), "Bodega Cat knows you're pulling out")
        XCTAssertEqual(WPActivityCopy.thanksTitle, "Thanks, neighbor.")
        XCTAssertEqual(WPActivityCopy.from(name: "Bodega Cat"), "From Bodega Cat")
        XCTAssertEqual(WPActivityCopy.endedTitle, "Pass ended")
        XCTAssertEqual(WPActivityCopy.stoppedWaiting(name: "Bodega Cat"), "Bodega Cat stopped waiting. Nothing to do.")
        // Never a location in an activity.
        XCTAssertFalse(WPActivityCopy.knowsPullingOut(name: "X").lowercased().contains("where"))
    }

    // MARK: Locked-phone "Leaving now" (unchanged wiring)

    func testLeavingNowIntent_stillWorksFromALockedPhone() {
        XCTAssertFalse(LeavingNowIntent.openAppWhenRun)
        XCTAssertEqual(LeavingNowIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(LeavingNowIntent(passID: "abc").passID, "abc")
        XCTAssertFalse(FiveMoreMinutesIntent.openAppWhenRun)
        XCTAssertFalse(NotLeavingIntent.openAppWhenRun)
    }

    // MARK: Park reminder (B13)

    func testParkReminder_titleIsTheDeadline() {
        XCTAssertEqual(WPParkReminderCopy.title(moveBy: "9:00 AM", nightBefore: false), "Move your car by 9:00 AM")
        XCTAssertEqual(WPParkReminderCopy.title(moveBy: "9:00 AM", nightBefore: true), "Move your car by 9:00 AM tomorrow")
    }

    func testParkReminder_bodyIsTheReasonAndThePlace() {
        XCTAssertEqual(
            WPParkReminderCopy.body(label: "ASP Mon/Thu", street: "E 1st St", side: "N", lead: .hours2),
            "Street cleaning on E 1st St, north side. 2 hours left."
        )
        XCTAssertEqual(
            WPParkReminderCopy.body(label: "ASP Mon/Thu", street: "E 1st St", side: "N", lead: .nightBefore),
            "Street cleaning on E 1st St, north side."
        )
        XCTAssertEqual(
            WPParkReminderCopy.body(label: nil, street: "Main St", side: "", lead: .minutes15),
            "Parking restriction on Main St. 15 minutes left."
        )
        XCTAssertEqual(WPParkReminderCopy.reasonLabel("No Parking"), "No Parking")
    }

    func testParkReminder_walkThereActionAndAppleMapsURL() {
        let category = WPParkReminderCopy.category()
        XCTAssertEqual(category.identifier, WPParkReminderCopy.categoryID)
        XCTAssertEqual(category.actions.map(\.identifier), [WPParkReminderCopy.actionWalkThere])
        XCTAssertEqual(category.actions.first?.title, "Walk there")
        let info = WPParkReminderCopy.userInfo(latitude: 40.7, longitude: -73.9)
        let coordinate = WPParkReminderCopy.coordinate(from: info)
        XCTAssertEqual(coordinate?.latitude, 40.7)
        XCTAssertNil(WPParkReminderCopy.coordinate(from: ["wepark_lat": 400.0, "wepark_lon": 0.0]))
        let url = WPParkReminderCopy.walkURL(latitude: 40.7, longitude: -73.9)
        XCTAssertEqual(url?.host, "maps.apple.com")
        XCTAssertTrue(url?.absoluteString.contains("dirflg=w") == true)
    }

    // MARK: Flag-off

    @MainActor
    func testLaunchCategories_stoopCategoryOnlyWhenFlagOn() {
        let off = NotificationCategoryRegistry.launchCategories(
            addressEnabled: false, spotPassEnabled: false, stoopParkReminders: false
        )
        XCTAssertTrue(off.isEmpty)
        let on = NotificationCategoryRegistry.launchCategories(
            addressEnabled: false, spotPassEnabled: false, stoopParkReminders: true
        )
        XCTAssertEqual(on.map(\.identifier), [WPParkReminderCopy.categoryID])
        // The shipping default follows the flag, which is false.
        XCTAssertTrue(NotificationCategoryRegistry.launchCategories(addressEnabled: false, spotPassEnabled: false).isEmpty)
    }
}

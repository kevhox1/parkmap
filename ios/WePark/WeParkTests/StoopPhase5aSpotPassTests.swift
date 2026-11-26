//
//  StoopPhase5aSpotPassTests.swift
//  WeParkTests
//
//  Stoop Phase 5a: the pure logic and wording behind the Stoop skin of the in-app Spot Pass screens
//  (`WPPassLogic`, `WPPassCopy`). Views are covered by the DEBUG showcase screenshots.
//

import XCTest
@testable import WePark

final class StoopPhase5aSpotPassTests: XCTestCase {

    private func p5aDate(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 25; c.hour = h; c.minute = m; c.second = s
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    // MARK: Wording

    func testChipTitles_useAboutWording() {
        XCTAssertEqual(WPPassCopy.chipTitle(.now), "Now")
        XCTAssertEqual(WPPassCopy.chipTitle(.minutes(10)), "About 10 min")
        XCTAssertEqual(WPPassCopy.chipTitle(.minutes(30)), "About 30 min")
        XCTAssertEqual(WPPassCopy.chipTitle(.minutes(60)), "About 1 hour")
        XCTAssertEqual(WPPassCopy.chipTitle(.custom(Date())), "Pick a time")
        XCTAssertEqual(WPPassCopy.chipTitle(.custom(Date()), clock: "4:45 PM"), "4:45 PM")
    }

    func testChipTitles_neverUseTilde() {
        for choice in LeaveChoice.presets {
            XCTAssertFalse(WPPassCopy.chipTitle(choice).contains("~"))
            XCTAssertFalse(WPPassCopy.chipAccessibilityLabel(choice).contains("~"))
        }
        XCTAssertEqual(WPPassCopy.chipAccessibilityLabel(.minutes(10)), "Leaving in about 10 minutes")
        XCTAssertEqual(WPPassCopy.chipAccessibilityLabel(.minutes(60)), "Leaving in about 1 hour")
    }

    func testPrivacyCopy_isIntact() {
        XCTAssertEqual(WPPassCopy.privacyTitle, "They won't see who you are or where you are.")
        XCTAssertEqual(WPPassCopy.driverSub, "When are you leaving? They won't see who you are.")
        XCTAssertTrue(WPPassCopy.driverTitle(name: nil).hasPrefix("A neighbor"))
    }

    func testDefaultChoiceIsAboutTenMinutes() {
        XCTAssertEqual(LeaveChoice.default, .minutes(10))
        XCTAssertEqual(WPPassCopy.chipTitle(LeaveChoice.default), "About 10 min")
    }

    // MARK: Pick-a-time slots

    func testLeaveSlots_startAtNextQuarterHourAndStepFifteenMinutes() {
        let now = p5aDate(16, 2)
        let slots = WPPassLogic.leaveSlots(from: now)
        XCTAssertEqual(slots.first, p5aDate(16, 15))
        for (a, b) in zip(slots, slots.dropFirst()) {
            XCTAssertEqual(b.timeIntervalSince(a), 900)
        }
    }

    func testLeaveSlots_onAQuarterHourStartsAFullQuarterLater() {
        let now = p5aDate(16, 15)
        XCTAssertEqual(WPPassLogic.leaveSlots(from: now).first, p5aDate(16, 30))
    }

    func testLeaveSlots_neverPastWhatTheServerAccepts() {
        for now in [p5aDate(16, 2), p5aDate(16, 14, 59), p5aDate(16, 15), p5aDate(23, 50)] {
            let slots = WPPassLogic.leaveSlots(from: now)
            XCTAssertLessThanOrEqual(slots.count, 16)
            XCTAssertFalse(slots.isEmpty)
            let latest = LeaveChoice.latest(from: now)
            for slot in slots {
                XCTAssertGreaterThan(slot, now)
                XCTAssertLessThanOrEqual(slot, latest)
                XCTAssertLessThanOrEqual(slot.timeIntervalSince(now), 240 * 60)
            }
        }
    }

    /// The time on the chip is the time that is sent: no slot gets silently clamped or re-rounded.
    func testLeaveSlots_timeShownIsTimeSent() {
        let now = p5aDate(16, 2)
        for slot in WPPassLogic.leaveSlots(from: now) {
            XCTAssertEqual(LeaveChoice.custom(slot).leaveAt(from: now), slot)
        }
    }

    // MARK: Auto heads-up switch

    func testAutoSwitch_offByDefaultForEveryOfferToEnable() {
        for offer in [AutoDetectOffer.canEnable, .needsSavedCar, .locationDenied] {
            let state = WPPassLogic.autoSwitch(offer: offer, name: "Bodega Cat")
            XCTAssertTrue(state.isVisible, "\(offer)")
            XCTAssertFalse(state.isOn, "\(offer)")
        }
    }

    func testAutoSwitch_onOnlyWhenTheDriverOptedIn() {
        XCTAssertTrue(WPPassLogic.autoSwitch(offer: .on, name: "Sam").isOn)
        XCTAssertTrue(WPPassLogic.autoSwitch(offer: .waiting, name: "Sam").isOn)
        XCTAssertTrue(WPPassLogic.autoSwitch(offer: .on, name: "Sam").subtitle.contains("Sam"))
    }

    func testAutoSwitch_hiddenWhenNotOffered() {
        XCTAssertFalse(WPPassLogic.autoSwitch(offer: .hidden, name: "Sam").isVisible)
    }

    /// Turning ON never enables by itself: it goes through the purpose screen (second opt-in).
    func testSwitchAction_onGoesThroughPurposeOffIsImmediate() {
        XCTAssertEqual(WPPassLogic.switchAction(currentlyOn: false, newValue: true), .openPurpose)
        XCTAssertEqual(WPPassLogic.switchAction(currentlyOn: true, newValue: false), .turnOff)
        XCTAssertEqual(WPPassLogic.switchAction(currentlyOn: false, newValue: false), .none)
        XCTAssertEqual(WPPassLogic.switchAction(currentlyOn: true, newValue: true), .none)
    }

    // MARK: A chosen time that has passed

    func testResolvedChoice_passedCustomTimeBecomesNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(WPPassLogic.resolvedChoice(.custom(now.addingTimeInterval(-1)), now: now), .now)
        XCTAssertEqual(WPPassLogic.resolvedChoice(.custom(now), now: now), .now)
    }

    func testResolvedChoice_futureCustomTimeAndPresetsAreUnchanged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = LeaveChoice.custom(now.addingTimeInterval(60))
        XCTAssertEqual(WPPassLogic.resolvedChoice(future, now: now), future)
        XCTAssertEqual(WPPassLogic.resolvedChoice(.minutes(10), now: now), .minutes(10))
        XCTAssertEqual(WPPassLogic.resolvedChoice(.now, now: now), .now)
    }

    func testStillOffered_slotThatJustPassedIsNotSelectable() {
        let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - 1_800_000_000 % 900 + 890))
        let slots = WPPassLogic.leaveSlots(from: now)
        let first = slots[0]
        XCTAssertEqual(WPPassLogic.stillOffered(first, in: slots), first)
        let later = first.addingTimeInterval(1)
        XCTAssertNil(WPPassLogic.stillOffered(first, in: WPPassLogic.leaveSlots(from: later)))
    }
}

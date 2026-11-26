//
//  StoopPhase6bTests.swift
//  WeParkTests
//
//  Stoop Phase 6b: Plan a Trip copy and gating (B14), the blocking / limit state copy (B18) and the
//  Parking 101 section list (B16). Pure logic; the views draw what these return.
//

import XCTest
@testable import WePark

final class StoopPhase6bTests: XCTestCase {

    private func et(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        Calendar.easternTime.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// The labels use a non-breaking space before AM/PM; tests compare with plain spaces.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }

    // MARK: Trip labels

    func testTagDates_matchesTheMock() {
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18))
        XCTAssertEqual(plain(WPTripCopy.tagDates(plan, now: et(2026, 11, 26, 9))), "Sat 11/28 10 AM to Sun 11/29 6 PM")
    }

    func testTagDates_nextYearCarriesTwoDigitYear() {
        let plan = TripPlan(arrival: et(2027, 1, 2, 10), departure: et(2027, 1, 3, 18))
        XCTAssertEqual(plain(WPTripCopy.tagDates(plan, now: et(2026, 11, 26, 9))), "Sat 1/2/27 10 AM to Sun 1/3/27 6 PM")
    }

    func testUntilAndFromLabels() {
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18))
        XCTAssertEqual(plain(WPTripCopy.untilLabel(plan)), "Sun 6 PM")
        XCTAssertEqual(plain(WPTripCopy.fromLabel(plan)), "From Sat 10 AM \u{00B7} 32 hours")
    }

    func testMidnightIsWrittenAsMidnight() {
        // Mon Nov 30 00:00 ET.
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 30, 0))
        XCTAssertEqual(WPTripCopy.untilLabel(plan), "Mon midnight")
    }

    func testDurationLabel() {
        let a = et(2026, 11, 28, 10)
        XCTAssertEqual(WPTripCopy.durationLabel(TripPlan(arrival: a, departure: a.addingTimeInterval(3600))), "1 hour")
        XCTAssertEqual(WPTripCopy.durationLabel(TripPlan(arrival: a, departure: a.addingTimeInterval(5 * 3600))), "5 hours")
        XCTAssertEqual(WPTripCopy.durationLabel(TripPlan(arrival: a, departure: a.addingTimeInterval(72 * 3600))), "3 days")
        XCTAssertEqual(WPTripCopy.durationLabel(TripPlan(arrival: a, departure: a.addingTimeInterval(76 * 3600))), "3 days 4 h")
    }

    func testRangeLabel_sameDayShareMeridiemOnce() {
        let now = et(2026, 11, 26, 9)
        XCTAssertEqual(plain(WPTripCopy.rangeLabel(TripPlan(arrival: et(2026, 11, 26, 17), departure: et(2026, 11, 26, 22)), now: now)), "5 to 10 PM")
        XCTAssertEqual(plain(WPTripCopy.rangeLabel(TripPlan(arrival: et(2026, 11, 27, 9), departure: et(2026, 11, 27, 18)), now: now)), "9 AM to 6 PM")
        XCTAssertEqual(plain(WPTripCopy.rangeLabel(TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18)), now: now)), "Sat 10 AM to Sun 6 PM")
    }

    func testRowStamp() {
        XCTAssertEqual(plain(WPTripCopy.rowStamp(et(2026, 11, 28, 10))), "Sat, Nov 28 \u{00B7} 10:00 AM")
        XCTAssertEqual(plain(WPTripCopy.rowStamp(et(2026, 11, 29, 18, 30))), "Sun, Nov 29 \u{00B7} 6:30 PM")
    }

    func testQuickPickRange_passedPickSaysSo() {
        XCTAssertEqual(WPTripCopy.quickPickRange(.todayEvening, plan: nil, now: et(2026, 11, 26, 23)), "Already passed")
    }

    // MARK: Validation words

    func testProblems_nameTheRowAndSaySomethingConcrete() {
        XCTAssertNil(WPTripCopy.problem(for: .valid))
        let leave = WPTripCopy.problem(for: .departureNotAfterArrival)
        XCTAssertEqual(leave?.title, "Leave has to be after Arrive")
        XCTAssertEqual(leave?.field, .leave)
        XCTAssertEqual(WPTripCopy.problem(for: .tooLong)?.field, .leave)
        XCTAssertEqual(WPTripCopy.problem(for: .arrivalInPast)?.field, .arrive)
        for v in [TripPlanValidation.arrivalInPast, .departureNotAfterArrival, .tooLong] {
            XCTAssertFalse(WPTripCopy.problem(for: v)?.detail.isEmpty ?? true, "\(v)")
        }
    }

    // MARK: Calendar notice

    func testCalendarNotice_namesTheYearAndOnlyShowsWhenNotCovered() {
        let plan = TripPlan(arrival: et(2027, 1, 2, 10), departure: et(2027, 1, 3, 18))
        XCTAssertNil(WPTripCopy.calendarNotice(plan, arrivalCovered: true, departureCovered: true))
        XCTAssertEqual(WPTripCopy.calendarNotice(plan, arrivalCovered: false, departureCovered: false)?.title,
                       "Holiday changes for 2027 aren't out yet")
        XCTAssertNotNil(WPTripCopy.calendarNotice(plan, arrivalCovered: true, departureCovered: false))
    }

    // MARK: Live vs not live

    func testTripGating_liveControlsHiddenWhilePlanning() {
        XCTAssertFalse(WPTripChrome.showsLiveControls(tripActive: true))
        XCTAssertTrue(WPTripChrome.showsLiveControls(tripActive: false))
        XCTAssertFalse(TripModeGating.showsReportPill(tripActive: true))
        XCTAssertFalse(TripModeGating.showsSpotPass(tripActive: true))
        XCTAssertFalse(TripModeGating.showsLiveActions(tripActive: true))
    }

    func testPlanFrame_onlyForAPlanInStoop() {
        XCTAssertTrue(WPTripChrome.showsPlanFrame(tripActive: true, stoop: true))
        XCTAssertFalse(WPTripChrome.showsPlanFrame(tripActive: true, stoop: false))
        XCTAssertFalse(WPTripChrome.showsPlanFrame(tripActive: false, stoop: true))
    }

    func testCaveatIsTheExistingOne() {
        XCTAssertEqual(WPTripCopy.caveat, TripPlanning.caveat)
        XCTAssertTrue(WPTripCopy.planNote.contains("not the live map"))
    }

    // MARK: State copy (B18)

    func testStateScreens_everyBlockingStateHasAWayOut() {
        let screens = [WPStateCopy.noLocation, WPStateCopy.outsideCoverage(place: nil, canSuggest: true),
                       WPStateCopy.serverDown, WPStateCopy.account]
        for s in screens {
            XCTAssertFalse(s.title.isEmpty)
            XCTAssertNotNil(s.secondary, s.title)
        }
        XCTAssertEqual(WPStateCopy.noCar.primary, "Find parking")
    }

    func testOutsideCoverage_suggestionAndPlaceAreOptional() {
        let s = WPStateCopy.outsideCoverage(place: nil, canSuggest: false)
        XCTAssertNil(s.over)
        XCTAssertNil(s.primary)
        XCTAssertEqual(WPStateCopy.outsideCoverage(place: "Astoria, Queens", canSuggest: true).over, "You're in Astoria, Queens")
    }

    func testNoCurbs_neverReadsAsFree() {
        XCTAssertTrue(WPStateCopy.noCurbsBody.contains("Read the signs"))
        XCTAssertFalse(WPStateCopy.noCurbsBody.lowercased().contains("free"))
    }

    func testLimitRows() {
        XCTAssertEqual(WPStateCopy.offline(asOf: "10:02 PM").message, "You're offline. This is what we knew at 10:02 PM.")
        XCTAssertEqual(WPStateCopy.notificationsOff.fix, "Turn on")
        XCTAssertEqual(WPStateCopy.whileUsingOnly.fix, "Settings")
    }

    // MARK: Parking 101

    func testGuideSections_stoopDropsTheFiveColorLegendOnly() {
        XCTAssertEqual(ParkingGuideSection.visible(stoop: false), ParkingGuideSection.allCases)
        XCTAssertEqual(ParkingGuideSection.visible(stoop: true), [.pitch, .signSchool, .rookieMistakes])
    }
}

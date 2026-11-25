//
//  TripPlanningTests.swift
//  WeParkTests
//
//  Plan a Trip (docs/specs/goals-rework.md section 3): validation, quick picks, banner copy,
//  the per-curb verdict (agrees with the one free rule), ASP calendar coverage, and the
//  dark-ship / More-sheet gating.
//

import XCTest
@testable import WePark

final class TripPlanningTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
    }

    // MARK: - Helpers (private to this class)

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    private func tripSegment(rules: [ParkingRule]) -> Segment {
        Segment(
            id: "TRIP_TEST", street: "MOTT STREET", fromStreet: "GRAND STREET", to: "HESTER STREET",
            side: "N", line: [[40.7183, -73.9942], [40.7190, -73.9940]],
            rules: rules, dominantCategory: rules.first?.category
        )
    }

    private func tripRule(
        category: WePark.Category, days: [Int], ranges: [(Int, Int)] = [], anytime: Bool = false
    ) -> ParkingRule {
        let dict: [String: Any] = [
            "category": category.rawValue,
            "description": "",
            "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime,
            "arrow": "both",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        // A decode failure is a test-authoring bug; surface it as a hard failure.
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    // MARK: - Flag + menu gating

    func testPlanTripFlag_darkShips() {
        XCTAssertFalse(AppConstants.planTripEnabled, "planTripEnabled ships false until Kevin smokes it")
    }

    func testMoreMenu_planTripRow_hiddenByDefault_shownWhenEnabled_beforeSettings() {
        let off = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false, hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertFalse(off.contains(.planTrip))
        let on = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false, hasParkedCar: false,
            fullPaletteMode: false, planTripEnabled: true
        )
        XCTAssertEqual(on.last, .settings)
        XCTAssertEqual(on.dropLast().last, .planTrip)
        XCTAssertEqual(MoreMenuRow.planTrip.title, "Plan a trip")
        XCTAssertEqual(MoreMenuRow.planTrip.subtitle, "Coming into the city? See where you can park for your visit.")
    }

    // MARK: - Validation

    func testValidate_validPlan() {
        let now = et(2026, 11, 24, 12)
        XCTAssertEqual(TripPlanning.validate(arrival: now, departure: now.addingTimeInterval(3600), now: now), .valid)
        XCTAssertEqual(TripPlanning.validate(arrival: now.addingTimeInterval(86_400), departure: now.addingTimeInterval(2 * 86_400), now: now), .valid)
    }

    func testValidate_arrivalInPast() {
        let now = et(2026, 11, 24, 12)
        XCTAssertEqual(
            TripPlanning.validate(arrival: now.addingTimeInterval(-3600), departure: now.addingTimeInterval(3600), now: now),
            .arrivalInPast
        )
    }

    func testValidate_departureMustBeAfterArrival() {
        let now = et(2026, 11, 24, 12)
        let arrival = now.addingTimeInterval(3600)
        XCTAssertEqual(TripPlanning.validate(arrival: arrival, departure: arrival, now: now), .departureNotAfterArrival)
        XCTAssertEqual(TripPlanning.validate(arrival: arrival, departure: arrival.addingTimeInterval(-60), now: now), .departureNotAfterArrival)
    }

    func testValidate_cappedAtSevenDays() {
        let now = et(2026, 11, 24, 12)
        XCTAssertEqual(TripPlanning.validate(arrival: now, departure: now.addingTimeInterval(7 * 86_400), now: now), .valid)
        XCTAssertEqual(TripPlanning.validate(arrival: now, departure: now.addingTimeInterval(7 * 86_400 + 60), now: now), .tooLong)
    }

    // MARK: - Quick picks

    func testQuickPick_todayEvening() {
        let plan = TripPlanning.quickPick(.todayEvening, now: et(2026, 11, 24, 13))
        XCTAssertEqual(plan, TripPlan(arrival: et(2026, 11, 24, 17), departure: et(2026, 11, 24, 22)))
    }

    func testQuickPick_todayEvening_alreadyStarted_arrivesNow() {
        let now = et(2026, 11, 24, 19)
        XCTAssertEqual(TripPlanning.quickPick(.todayEvening, now: now), TripPlan(arrival: now, departure: et(2026, 11, 24, 22)))
    }

    func testQuickPick_todayEvening_afterTenPM_isNil() {
        XCTAssertNil(TripPlanning.quickPick(.todayEvening, now: et(2026, 11, 24, 23)))
    }

    func testQuickPick_tomorrow() {
        XCTAssertEqual(
            TripPlanning.quickPick(.tomorrow, now: et(2026, 11, 24, 13)),
            TripPlan(arrival: et(2026, 11, 25, 9), departure: et(2026, 11, 25, 18))
        )
    }

    func testQuickPick_thisWeekend_fromTuesday() {
        XCTAssertEqual(
            TripPlanning.quickPick(.thisWeekend, now: et(2026, 11, 24, 13)),
            TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18))
        )
    }

    func testQuickPick_thisWeekend_midSaturday_arrivesNow() {
        let now = et(2026, 11, 28, 12)
        XCTAssertEqual(
            TripPlanning.quickPick(.thisWeekend, now: now),
            TripPlan(arrival: now, departure: et(2026, 11, 29, 18))
        )
    }

    func testQuickPick_thisWeekend_sundayMorning_arrivesNow_sundayEvening_rollsToNextWeekend() {
        let sundayMorning = et(2026, 11, 29, 10)
        XCTAssertEqual(
            TripPlanning.quickPick(.thisWeekend, now: sundayMorning),
            TripPlan(arrival: sundayMorning, departure: et(2026, 11, 29, 18))
        )
        XCTAssertEqual(
            TripPlanning.quickPick(.thisWeekend, now: et(2026, 11, 29, 20)),
            TripPlan(arrival: et(2026, 12, 5, 10), departure: et(2026, 12, 6, 18))
        )
    }

    func testQuickPicks_alwaysValidWhenPresent() {
        for day in 22...30 {
            for hour in [0, 9, 13, 17, 21, 23] {
                let now = et(2026, 11, day, hour)
                for pick in TripQuickPick.allCases {
                    guard let plan = TripPlanning.quickPick(pick, now: now) else { continue }
                    XCTAssertEqual(
                        TripPlanning.validate(arrival: plan.arrival, departure: plan.departure, now: now), .valid,
                        "\(pick) at \(now)"
                    )
                }
            }
        }
    }

    // MARK: - Copy

    func testBannerLine_notLiveAndExplicitWindow() {
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18))
        XCTAssertEqual(TripPlanning.bannerLine(for: plan), "Sat 11/28 10:00 AM → Sun 11/29 6:00 PM · not live")
    }

    func testCaveatCopy() {
        XCTAssertEqual(
            TripPlanning.caveat,
            "Rules can change (film shoots, construction, holidays). Check the signs when you arrive."
        )
    }

    // MARK: - Verdict (one free rule)

    func testVerdict_free_whenNothingConflicts() {
        // ASP Tue/Fri 11:00-12:30; trip is Sat-Sun.
        let segment = tripSegment(rules: [tripRule(category: .aspTueFri, days: [2, 5], ranges: [(660, 750)])])
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 29, 18))
        let verdict = TripPlanning.verdict(segment: segment, plan: plan, engine: engine)
        XCTAssertEqual(verdict, .free)
        XCTAssertEqual(verdict.headline, "Free for your whole trip")
        XCTAssertTrue(TripPlanning.isFree(segment: segment, plan: plan, engine: engine))
    }

    func testVerdict_streetCleaningNamesTheSweepWindow() {
        let segment = tripSegment(rules: [tripRule(category: .aspTueFri, days: [2, 5], ranges: [(660, 750)])])
        let plan = TripPlan(arrival: et(2026, 11, 27, 9), departure: et(2026, 11, 28, 18))  // Fri 9 AM -> Sat
        let verdict = TripPlanning.verdict(segment: segment, plan: plan, engine: engine)
        XCTAssertEqual(verdict, .notFree(reason: "street cleaning Fri 11/27 11:00 AM–12:30 PM"))
        XCTAssertEqual(verdict.headline, "Not free: street cleaning Fri 11/27 11:00 AM–12:30 PM")
        XCTAssertFalse(TripPlanning.isFree(segment: segment, plan: plan, engine: engine))
    }

    func testVerdict_runningMeterIsNotFree() {
        let segment = tripSegment(rules: [tripRule(category: .metered, days: [1, 2, 3, 4, 5], ranges: [(480, 1320)])])
        let plan = TripPlan(arrival: et(2026, 11, 24, 13), departure: et(2026, 11, 24, 15))
        let verdict = TripPlanning.verdict(segment: segment, plan: plan, engine: engine)
        XCTAssertFalse(verdict.isFree)
        XCTAssertEqual(verdict, .notFree(reason: "meter running the whole trip"))
    }

    func testVerdict_anytimeNoStanding_wholeTrip() {
        let segment = tripSegment(rules: [tripRule(category: .noStanding, days: [], anytime: true)])
        let plan = TripPlan(arrival: et(2026, 11, 28, 10), departure: et(2026, 11, 28, 14))
        XCTAssertEqual(TripPlanning.verdict(segment: segment, plan: plan, engine: engine),
                       .notFree(reason: "no standing the whole trip"))
    }

    func testVerdict_picksEarliestConflictingRule() {
        let segment = tripSegment(rules: [
            tripRule(category: .noParking, days: [6], ranges: [(900, 960)]),   // Sat 3-4 PM
            tripRule(category: .truckLoading, days: [6], ranges: [(660, 720)]) // Sat 11-12
        ])
        let plan = TripPlan(arrival: et(2026, 11, 28, 9), departure: et(2026, 11, 28, 18))
        XCTAssertEqual(TripPlanning.verdict(segment: segment, plan: plan, engine: engine),
                       .notFree(reason: "truck loading zone Sat 11/28 11:00 AM–12:00 PM"))
    }

    func testVerdict_suspendedAspDay_isFree() {
        // Thu 11/26/2026 (Thanksgiving) is in the suspension calendar; ASP Mon/Thu 7-9:30 AM is a non-event.
        let segment = tripSegment(rules: [tripRule(category: .aspMonThu, days: [1, 4], ranges: [(420, 570)])])
        let plan = TripPlan(arrival: et(2026, 11, 26, 6), departure: et(2026, 11, 26, 18))
        XCTAssertEqual(TripPlanning.verdict(segment: segment, plan: plan, engine: engine), .free)
    }

    func testVerdict_agreesWithOvernightGoalForTheSameWindow() {
        // One free rule: a trip window equal to a live goal's window gives the goal's answer.
        let now = et(2026, 11, 24, 21)
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let plan = TripPlan(arrival: now, departure: end)
        let fixtures: [Segment] = [
            tripSegment(rules: [tripRule(category: .metered, days: [1, 2, 3, 4, 5], ranges: [(480, 1320)])]),
            tripSegment(rules: [tripRule(category: .aspTueFri, days: [2, 5], ranges: [(510, 600)])]),
            tripSegment(rules: [tripRule(category: .noParking, days: [3], ranges: [(0, 1439)])]),
            tripSegment(rules: []),
        ]
        for segment in fixtures {
            XCTAssertEqual(
                TripPlanning.verdict(segment: segment, plan: plan, engine: engine).isFree,
                ParkingGoals.match(segment: segment, goal: .freeOvernight, from: now, engine: engine).matches
            )
        }
    }

    // MARK: - ASP calendar coverage

    func testCalendarCovers_2026YesAnd2027No() {
        let in2026 = TripPlan(arrival: et(2026, 12, 20, 10), departure: et(2026, 12, 22, 10))
        let into2027 = TripPlan(arrival: et(2026, 12, 30, 10), departure: et(2027, 1, 2, 10))
        let all2027 = TripPlan(arrival: et(2027, 1, 5, 7), departure: et(2027, 1, 5, 12))
        XCTAssertTrue(TripPlanning.calendarCovers(in2026, service: aspService))
        XCTAssertFalse(TripPlanning.calendarCovers(into2027, service: aspService))
        XCTAssertFalse(TripPlanning.calendarCovers(all2027, service: aspService))
    }

    func testBeyondCalendar_streetCleaningTreatedAsInEffect() {
        // 2027 has no suspension data: ASP Tue/Fri 8-10 AM must read as in effect (red), the safe side.
        let segment = tripSegment(rules: [tripRule(category: .aspTueFri, days: [2, 5], ranges: [(480, 600)])])
        let plan = TripPlan(arrival: et(2027, 1, 5, 7), departure: et(2027, 1, 5, 12))  // Tue
        XCTAssertFalse(TripPlanning.isFree(segment: segment, plan: plan, engine: engine))
        XCTAssertTrue(TripPlanning.verdict(segment: segment, plan: plan, engine: engine) != .free)
    }

    // MARK: - Trip-mode gating (not live)

    func testTripModeGating_hidesLiveActionsAndLiveASPBannerOnlyWhileTripActive() {
        XCTAssertFalse(TripModeGating.showsLiveActions(tripActive: true))
        XCTAssertFalse(TripModeGating.showsLiveASPBanner(tripActive: true))
        XCTAssertTrue(TripModeGating.showsLiveActions(tripActive: false))
        XCTAssertTrue(TripModeGating.showsLiveASPBanner(tripActive: false))
    }

    func testMoreMenu_reportRowHiddenWhileTripActive_restoredOnExit() {
        func rows(tripActive: Bool) -> [MoreMenuRow] {
            moreMenuVisibleRows(
                communityEnabled: true,
                onboardingReplayAvailable: false,
                hasParkedCar: false,
                fullPaletteMode: false,
                planTripEnabled: true,
                tripActive: tripActive
            )
        }
        XCTAssertFalse(rows(tripActive: true).contains(.report))
        XCTAssertTrue(rows(tripActive: false).contains(.report))
        XCTAssertTrue(rows(tripActive: true).contains(.planTrip))
    }
}

//
//  UnknownIsRestrictionTests.swift
//  WeParkTests
//
//  Product rule: never show a spot that isn't a spot. An UNKNOWN sign (carshare, Open Streets,
//  microhub, bus-stop panel, taxi plate, "Description Not Available") is a restriction during
//  its stated days/times, and all the time when it states none. These tests pin that across the
//  goals, the map classification, the drive card, voice and copy, and check the engine against
//  the Node port's state (iv) green count over every bundled tile.
//
//  Reference week: Sun 2026-12-06 (no DST change inside the 8-day goal horizon).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixtures (file-private, uniquely named)

private func uirET(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 12; c.day = day; c.hour = hour; c.minute = minute; c.second = 0
    c.timeZone = .easternTime
    return Calendar.easternTime.date(from: c) ?? Date()
}

private func uirRule(
    _ category: WePark.Category,
    description: String = "TEST SIGN",
    days: [Int] = [],
    timeRanges: [TimeRange] = []
) -> ParkingRule {
    ParkingRule(category: category, description: description, days: days,
                timeRanges: timeRanges, anytime: false, arrow: nil)
}

private func uirSegment(
    side: String = "N",
    rules: [ParkingRule],
    id: String = UUID().uuidString
) -> Segment {
    Segment(
        id: id, street: "E 2 ST", fromStreet: "AVE B", to: "AVE A", side: side,
        line: [[40.7260, -73.9840], [40.7261, -73.9840]],
        rules: rules, dominantCategory: rules.first?.category
    )
}

final class UnknownIsRestrictionTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private let tue10AM = uirET(8, 10)
    private let tue8PM = uirET(8, 20)
    private let wed10AM = uirET(9, 10)
    private let sat2PM = uirET(12, 14)
    private let sun10AM = uirET(13, 10)
    private var probeTimes: [(String, Date)] {
        [("Tue 10 AM", tue10AM), ("Tue 8 PM", tue8PM), ("Sat 2 PM", sat2PM), ("Sun 10 AM", sun10AM)]
    }
    private let allGoals: [ParkingGoal] = [.freeFewHours, .freeOvernight, .parkAndForget]

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func matches(_ seg: Segment, _ goal: ParkingGoal, _ from: Date) -> Bool {
        ParkingGoals.match(segment: seg, goal: goal, from: from, engine: engine).matches
    }

    // MARK: - UNKNOWN-only is never free

    func testUnknownOnlyNoSchedule_neverFreeInAnyGoal() {
        let seg = uirSegment(rules: [uirRule(.unknown, description: "CARSHARE SIGN (INFORMATION)")])
        for (name, from) in probeTimes {
            for goal in allGoals {
                XCTAssertFalse(matches(seg, goal, from), "UNKNOWN-only must never be free: \(goal) at \(name)")
            }
        }
    }

    func testUnknownOnlyNoSchedule_notFreeInShortWindows() {
        let seg = uirSegment(rules: [uirRule(.unknown)])
        XCTAssertFalse(engine.isFree(segment: seg, from: tue10AM, until: tue10AM.addingTimeInterval(600)))
        XCTAssertFalse(engine.isFree(segment: seg, from: tue10AM, until: tue10AM.addingTimeInterval(600),
                                     ignoringMeteredPayment: true))
    }

    func testUnknownDaysOnlyNoTimes_restrictsThoseDaysAllDay() {
        // Tuesday only, no times: the whole Tuesday.
        let seg = uirSegment(rules: [uirRule(.unknown, days: [2])])
        XCTAssertFalse(engine.isFree(segment: seg, from: tue10AM, until: tue10AM.addingTimeInterval(3600)))
        XCTAssertTrue(engine.isFree(segment: seg, from: wed10AM, until: wed10AM.addingTimeInterval(3600)))
    }

    // MARK: - Mixed segment: restricted in the UNKNOWN window only

    func testMixedSegment_notFreeInsideUnknownWindow_unaffectedOutside() {
        // Mon-Fri 9AM-5PM unclear sign, plus a Saturday NO PARKING.
        let unknownRule = uirRule(.unknown, days: [1, 2, 3, 4, 5], timeRanges: [TimeRange(start: 540, end: 1020)])
        let satNoParking = uirRule(.noParking, days: [6], timeRanges: [TimeRange(start: 480, end: 1080)])
        let mixed = uirSegment(rules: [satNoParking, unknownRule])
        let knownOnly = uirSegment(rules: [satNoParking])

        // Inside the UNKNOWN window (Tue 10 AM, 3 h): not free, though the known rule alone is.
        XCTAssertTrue(matches(knownOnly, .freeFewHours, tue10AM))
        XCTAssertFalse(matches(mixed, .freeFewHours, tue10AM))

        // Outside it (Tue 8 PM, Sun 10 AM): identical to the known-only segment.
        for from in [tue8PM, sun10AM] {
            XCTAssertEqual(matches(mixed, .freeFewHours, from), matches(knownOnly, .freeFewHours, from))
        }
        XCTAssertTrue(matches(mixed, .freeFewHours, tue8PM))
        // A window that runs into the UNKNOWN window is blocked; one that ends as it starts is fine.
        XCTAssertFalse(engine.isFree(segment: mixed, from: uirET(8, 7), until: uirET(8, 9, 30)))
        XCTAssertTrue(engine.isFree(segment: mixed, from: uirET(8, 7), until: uirET(8, 9)))
    }

    func testUnknownTimesWithoutDays_appliesEveryDay() {
        let seg = uirSegment(rules: [uirRule(.unknown, timeRanges: [TimeRange(start: 420, end: 1080)])])
        XCTAssertFalse(engine.isFree(segment: seg, from: sun10AM, until: sun10AM.addingTimeInterval(3600)))
        XCTAssertTrue(engine.isFree(segment: seg, from: tue8PM, until: tue8PM.addingTimeInterval(3600)))
    }

    // MARK: - Map classification, drive card, labels all agree

    func testMapAndDriveCardAgree_unknownOnly() {
        let seg = uirSegment(rules: [uirRule(.unknown, description: "BUS STOP SIGN (GENERIC PANEL)")])
        let target = ParkingGoals.target(for: .freeFewHours, from: tue10AM)

        // Map: binary overlay (goal) and current-state overlay are both red.
        XCTAssertFalse(engine.isFree(segment: seg, from: tue10AM, until: target))
        XCTAssertEqual(engine.currentState(for: seg, at: tue10AM), .restrictedNow)

        // Drive card chip: red, text never claims a specific restriction.
        let chip = DrivingContextService.goalAwareChip(
            sideSegments: [seg], parkUntilMode: true, target: target,
            ignoringMeteredPayment: false, from: tue10AM, engine: engine
        )
        XCTAssertEqual(chip?.severity, .restricted)
        let agg = DrivingContextService.aggregateSideDetail(
            segments: [seg], side: "N", engine: engine, date: tue10AM
        )
        XCTAssertEqual(agg.opportunity, .restricted)
        XCTAssertTrue(agg.unclearSign)
        let label = SafetyLabel(for: agg)
        XCTAssertEqual(label.text, UnclearSign.headline)
        XCTAssertEqual(label.severity, .restricted)
    }

    func testMapAndDriveCardAgree_unclearCurbBesideFreeCurb() {
        // A free curb next to an unclear-sign curb on the same side: green, as before.
        let unclear = uirSegment(rules: [uirRule(.unknown)])
        let freeSeg = uirSegment(rules: [uirRule(.free, description: "FREE")])
        let target = ParkingGoals.target(for: .freeFewHours, from: tue10AM)
        let chip = DrivingContextService.goalAwareChip(
            sideSegments: [unclear, freeSeg], parkUntilMode: true, target: target,
            ignoringMeteredPayment: false, from: tue10AM, engine: engine
        )
        XCTAssertEqual(chip?.severity, .free)
        XCTAssertTrue(engine.isFree(segment: freeSeg, from: tue10AM, until: target))
        XCTAssertFalse(engine.isFree(segment: unclear, from: tue10AM, until: target))
    }

    func testSpecificRestrictionWinsOverUnknownInCopy() {
        let both = uirSegment(rules: [
            uirRule(.unknown),
            uirRule(.noStanding, days: [0, 1, 2, 3, 4, 5, 6], timeRanges: [TimeRange(start: 0, end: 1440)]),
        ])
        XCTAssertEqual(engine.safetyLabel(for: both, at: tue10AM).text, "No standing")
    }

    func testSafetyLabelAndNextRestriction_unknown() {
        let always = uirSegment(rules: [uirRule(.unknown)])
        let label = engine.safetyLabel(for: always, at: tue10AM)
        XCTAssertEqual(label.text, "Unclear sign: check the posted sign")
        XCTAssertEqual(label.severity, .restricted)
        XCTAssertFalse(label.text.localizedCaseInsensitiveContains("no parking"))
        let next = engine.nextRestriction(for: always, at: tue10AM)
        XCTAssertTrue(next.isActiveNow)
        XCTAssertEqual(next.category, .unknown)
        XCTAssertEqual(next.label, UnclearSign.headline)

        // Upcoming window: free now, "Free until", state turns orange within 6 h.
        let windowed = uirSegment(rules: [uirRule(.unknown, days: [2], timeRanges: [TimeRange(start: 720, end: 900)])])
        let upcoming = engine.safetyLabel(for: windowed, at: tue10AM)
        XCTAssertEqual(upcoming.severity, .free)
        XCTAssertTrue(upcoming.text.hasPrefix("Free until"))
        XCTAssertEqual(engine.currentState(for: windowed, at: tue10AM), .freeButRestrictionSoon)
        XCTAssertEqual(engine.nextRestriction(for: windowed, at: tue10AM).hours, 2.0, accuracy: 0.01)
        // Inside the window: red.
        XCTAssertEqual(engine.currentState(for: windowed, at: uirET(8, 13)), .restrictedNow)
    }

    func testMyCarLine_unknownDoesNotClaimSpecificRestriction() {
        let seg = uirSegment(rules: [uirRule(.unknown)])
        let line = MyCarSheetV2Logic.nextMoveLine(
            restriction: engine.nextRestriction(for: seg, at: tue10AM),
            rules: seg.rules, dayOfWeek: tue10AM.dayOfWeekET, minuteOfDay: tue10AM.minuteOfDayET
        )
        XCTAssertEqual(line, "Now: unclear sign, check the posted sign")
    }

    func testTripPlan_unknownReason() {
        let seg = uirSegment(rules: [uirRule(.unknown)])
        let plan = TripPlan(arrival: tue10AM, departure: tue10AM.addingTimeInterval(7200))
        XCTAssertEqual(TripPlanning.verdict(segment: seg, plan: plan, engine: engine),
                       .notFree(reason: UnclearSign.headline))
    }

    func testVoice_bothSidesUnclear_neverSaysNoParking() {
        let voice = MockDrivingVoice()
        let service = DrivingContextService(voice: voice)
        let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)
        let segs = [
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST", side: "N", category: .unknown, lat: 40.750, lng: -73.980),
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST", side: "S", category: .unknown, lat: 40.750, lng: -73.980),
        ]
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: tue10AM)
        let spoken = voice.spokenTexts.first ?? ""
        XCTAssertTrue(spoken.contains(UnclearSign.spoken), "Got: \(spoken)")
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("no parking"))
    }

    // MARK: - Parity with the Node port (state iv)

    /// Green count at Tue 10 AM for A Few Hours over every bundled tile, versus
    /// `node scripts/diff-tiles-days.js --green-table` state (iv): 10,598.
    ///
    /// The Node port applies no ASP suspensions, and Tue 2026-12-08 is a suspension day (Feast of
    /// the Immaculate Conception) in the Swift engine, which would make every ASP curb green. So
    /// the probe uses the same weekday and clock time one week later, Tue 2026-12-15 10 AM.
    func testParity_aFewHoursTue10AM_matchesNodeStateIV() throws {
        let tilesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WePark/Resources/tiles")
        let files = try FileManager.default.contentsOfDirectory(at: tilesDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tile_") && $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 900, "bundled tiles missing")

        let decoder = JSONDecoder()
        var seen = Set<String>()
        var total = 0
        var green = 0
        let probe = uirET(15, 10)
        let target = ParkingGoals.target(for: .freeFewHours, from: probe)
        for file in files {
            let segments = try decoder.decode([Segment].self, from: Data(contentsOf: file))
            for seg in segments where seen.insert(seg.id).inserted {
                total += 1
                if engine.isFree(segment: seg, from: probe, until: target, ignoringMeteredPayment: false) {
                    green += 1
                }
            }
        }
        print("UNKNOWN-PARITY segments=\(total) green(A Few Hours, Tue 10 AM)=\(green) node(iv)=10598")
        XCTAssertEqual(green, 10_598, accuracy: 0, "total=\(total) green=\(green)")
    }
}

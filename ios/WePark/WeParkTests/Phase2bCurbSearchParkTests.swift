//
//  Phase2bCurbSearchParkTests.swift
//  WeParkTests
//
//  Design system Phase 2b (curb sheet, search, parking). Pins Kevin's accuracy rules:
//    - the free-curb count equals the number of curbs `WPCurbVerdict.isParkable` accepts, and is
//      hidden (nil) when the destination's tiles are not loaded
//    - unclear and no-data curbs never offer a primary "Park here"
//    - a neighbor report never makes a verdict greener
//    - "open spot" pins are suppressed on curbs that are not green for the window
//    - copy: midnight, arrow-sign wording, no sub-curb precision
//

import CoreLocation
import XCTest
@testable import WePark

final class Phase2bCurbSearchParkTests: XCTestCase {

    private var engine: ParkingRulesEngine!

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine(aspService: ASPSuspensionService())
    }

    // MARK: Fixtures

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps) ?? Date.distantPast
    }

    /// Wed 11/25/2026 10:11 PM ET (the design mocks' clock).
    private var now: Date { et(2026, 11, 25, 22, 11) }

    private func ruleJSON(
        _ category: WePark.Category, days: [Int] = [], ranges: [(Int, Int)] = [],
        anytime: Bool = false, description: String = "", arrow: String = "both"
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": description, "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": arrow,
        ]
    }

    private func makeSegment(
        _ rules: [[String: Any]], id: String = "P2B", lat: Double = 40.7600, lng: Double = -73.9776
    ) -> Segment {
        let dict: [String: Any] = [
            "id": id, "street": "WEST 53RD STREET", "from": "5TH AVENUE", "to": "6TH AVENUE",
            "side": "N", "line": [[lat, lng], [lat + 0.0002, lng + 0.0003]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private var clearRules: [[String: Any]] { [ruleJSON(.noParking, days: [1], ranges: [(480, 540)])] }
    private var noDataRules: [[String: Any]] { [ruleJSON(.noParking, anytime: true, description: "NO DATA: SUPERSEDED SIGN")] }
    private var unclearRules: [[String: Any]] { [ruleJSON(.unknown, description: "CARSHARE")] }
    private var restrictedRules: [[String: Any]] { [ruleJSON(.noStanding, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)] }
    private var meteredRules: [[String: Any]] {
        [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(0, 1439)])]
    }

    private func pin(type: String, segmentId: String?) -> CommunityPin {
        let segmentJSON = segmentId.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": "\(UUID().uuidString)", "pin_type": "\(type)", "source": "crowd", "lifespan": "ephemeral",
         "lat": 40.76, "lng": -73.9776, "segment_id": \(segmentJSON), "author_id": null,
         "author_username": null, "created_at": "2026-11-25T22:00:00Z", "updated_at": "2026-11-25T22:00:00Z",
         "expires_at": null, "resolved_at": null, "confirm_count": 0, "dispute_count": 0,
         "meta": null, "notes": null}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(CommunityPin.self, from: json)
    }

    private func model(_ rules: [[String: Any]], at date: Date? = nil, window: Date? = nil) -> WPCurbSheetModel {
        WPCurbSheetBuilder.make(
            segment: makeSegment(rules), engine: engine, now: date ?? now, windowEnd: window
        )
    }

    // MARK: Free-curb count == isParkable

    func testCount_matchesIsParkable_forTheSelectedWindow() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        var segments: [Segment] = []
        // 4 clear curbs, 3 restricted, 2 metered, 1 no-data, 1 unclear, all within 2 blocks.
        for i in 0..<4 { segments.append(makeSegment(clearRules, id: "C\(i)", lat: 40.7600 + Double(i) * 0.0002)) }
        for i in 0..<3 { segments.append(makeSegment(restrictedRules, id: "R\(i)", lat: 40.7602 + Double(i) * 0.0001)) }
        for i in 0..<2 { segments.append(makeSegment(meteredRules, id: "M\(i)", lat: 40.7598 - Double(i) * 0.0001)) }
        segments.append(makeSegment(noDataRules, id: "N0"))
        segments.append(makeSegment(unclearRules, id: "U0"))
        // A clear curb far away (outside 2 blocks) is not counted.
        segments.append(makeSegment(clearRules, id: "FAR", lat: 40.7700))

        for goal in ParkingGoal.allCases {
            let end = ParkingGoals.target(for: goal, from: now)
            let expected = segments.filter {
                WPFreeCurbCounter.distance(from: destination, to: $0) <= WPFreeCurbCounter.radiusMeters
                    && WPCurbVerdict.isParkable(segment: $0, engine: engine, from: now, until: end)
            }.count
            let result = WPFreeCurbCounter.count(near: destination, segments: segments, engine: engine, from: now, until: end)
            XCTAssertEqual(result?.count, expected, "goal \(goal)")
        }
        let overnight = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertEqual(
            WPFreeCurbCounter.count(near: destination, segments: segments, engine: engine, from: now, until: overnight)?.count,
            4
        )
    }

    func testCount_isHidden_whenTilesNotLoadedNearDestination() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        let farAway = [makeSegment(clearRules, id: "FAR", lat: 40.8000, lng: -73.9500)]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: farAway, engine: engine, from: now, until: end))
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: [], engine: engine, from: now, until: end))
    }

    func testCount_zero_reportsNearestRealDistance_notAnEstimate() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        // Loaded and covered, but the only clear curb is ~300 m away (inside the probe, outside 2 blocks).
        let segments = [
            makeSegment(restrictedRules, id: "R0"),
            makeSegment(clearRules, id: "NEAR", lat: 40.7627),
        ]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let result = WPFreeCurbCounter.count(near: destination, segments: segments, engine: engine, from: now, until: end)
        XCTAssertEqual(result?.count, 0)
        XCTAssertNotNil(result?.nearestMeters)
        XCTAssertEqual(WPFreeCurbCounter.headline(WPFreeCurbCount(count: 0, nearestMeters: 300)), "No free curbs within 2 blocks")
    }

    // MARK: Unclear and no-data never offer a primary "Park here"

    func testUnclear_neverOffersPrimaryPark() {
        let m = model(unclearRules)
        XCTAssertEqual(m.variant, .unclear)
        XCTAssertFalse(m.offersPrimaryPark)
        XCTAssertEqual(m.ctaTitle, "Park here anyway")
        XCTAssertFalse(m.big.lowercased().contains("street cleaning"), "never names a restriction the sign does not state")
    }

    func testNoData_neverOffersPrimaryPark() {
        for rules in [noDataRules, [[String: Any]]()] {
            let m = model(rules)
            XCTAssertEqual(m.variant, .nodata)
            XCTAssertFalse(m.offersPrimaryPark)
            XCTAssertEqual(m.ctaTitle, "Park here anyway")
            XCTAssertEqual(m.over, "We don't know")
            XCTAssertEqual(m.big, "No sign data")
        }
    }

    func testUnclearAndNoData_neverParkOrSoon_atAnyHourOfTheWeek() {
        for hour in stride(from: 0, to: 24 * 8, by: 3) {
            let date = now.addingTimeInterval(Double(hour) * 3600)
            for rules in [unclearRules, noDataRules, [ruleJSON(.unknown), ruleJSON(.noParking, days: [1], ranges: [(480, 540)])]] {
                let m = model(rules, at: date, window: date.addingTimeInterval(8 * 3600))
                XCTAssertFalse(m.offersPrimaryPark, "hour +\(hour)")
                XCTAssertNotEqual(m.variant, .park)
                XCTAssertNotEqual(m.variant, .soon)
            }
        }
    }

    func testOnlyParkAndSoonOfferThePrimaryButton() {
        for variant in WPCurbVariant.allCases {
            XCTAssertEqual(variant.offersPrimaryPark, variant == .park || variant == .soon, "\(variant)")
        }
    }

    func testPlanVariants_neverOfferPark_andUnreadableIsNeverFreeForTheTrip() {
        let plan = TripPlan(arrival: now.addingTimeInterval(86_400), departure: now.addingTimeInterval(2 * 86_400))
        for rules in [unclearRules, noDataRules] {
            let m = WPCurbSheetBuilder.make(segment: makeSegment(rules), engine: engine, now: now, windowEnd: nil, trip: plan)
            XCTAssertEqual(m.variant, .plandont)
        }
        let free = WPCurbSheetBuilder.make(segment: makeSegment(clearRules), engine: engine, now: now, windowEnd: nil, trip: plan)
        XCTAssertFalse(free.offersPrimaryPark)
    }

    func testDragBubble_forUnclearAndNoData_isNeverPark() {
        for rules in [unclearRules, noDataRules] {
            XCTAssertNotEqual(WPDragBubble.make(from: model(rules), windowName: nil).tone, .park)
        }
    }

    // MARK: Neighbor reports never upgrade the verdict

    func testNeighborReport_neverMakesVerdictGreener() {
        let reports = WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: true)
        let bases = [clearRules, restrictedRules, meteredRules, noDataRules, unclearRules]
        for hour in stride(from: 0, to: 24 * 7, by: 5) {
            let date = now.addingTimeInterval(Double(hour) * 3600)
            for rules in bases {
                let base = model(rules, at: date)
                let after = WPNeighborVerdict.apply(reports, to: base)
                XCTAssertLessThanOrEqual(after.variant.greenRank, base.variant.greenRank)
                XCTAssertNotEqual(after.variant, .park, "a report can never produce a park verdict")
                if base.variant.greenRank == 0 { XCTAssertEqual(after, base, "already strictest: the sign verdict stands") }
            }
        }
    }

    func testNeighborReport_thatIsNotActive_orEmpty_changesNothing() {
        let base = model(clearRules)
        XCTAssertEqual(WPNeighborVerdict.apply(WPNeighborReports(), to: base), base)
        XCTAssertEqual(
            WPNeighborVerdict.apply(WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: false), to: base),
            base
        )
    }

    func testNeighborReport_onParkCurb_turnsToDont_andKeepsTheSignLine() {
        let base = model(clearRules)
        XCTAssertEqual(base.variant, .park)
        let after = WPNeighborVerdict.apply(
            WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: true), to: base
        )
        XCTAssertEqual(after.variant, .dont)
        XCTAssertEqual(after.over, "Neighbors say")
        XCTAssertTrue(after.sub?.hasPrefix("By the signs") ?? false)
        XCTAssertFalse(after.offersPrimaryPark)
    }

    // MARK: "Open spot" pins only on green curbs

    func testOpenSpotPins_suppressedOnNonGreenCurbs_keptOnGreen() {
        let green = makeSegment(clearRules, id: "G")
        let others = [
            makeSegment(restrictedRules, id: "R"), makeSegment(noDataRules, id: "N"),
            makeSegment(unclearRules, id: "U"), makeSegment(meteredRules, id: "M"),
        ]
        let byID = Dictionary(uniqueKeysWithValues: ([green] + others).map { ($0.id, $0) })
        let end = ParkingGoals.target(for: .freeOvernight, from: now)

        let greenPin = pin(type: "open_spot", segmentId: "G")
        let kept = WPOpenSpotGate.filter([greenPin], segmentsByID: byID, engine: engine, from: now, until: end)
        XCTAssertEqual(kept.map(\.id), [greenPin.id])

        for id in ["R", "N", "U", "M", "MISSING"] {
            let p = pin(type: "open_spot", segmentId: id)
            XCTAssertTrue(
                WPOpenSpotGate.filter([p], segmentsByID: byID, engine: engine, from: now, until: end).isEmpty,
                "open spot on \(id) must not draw"
            )
        }
        let noSegment = pin(type: "open_spot", segmentId: nil)
        XCTAssertTrue(WPOpenSpotGate.filter([noSegment], segmentsByID: byID, engine: engine, from: now, until: end).isEmpty)
    }

    func testOtherPinTypes_passThroughTheOpenSpotGate() {
        let byID: [String: Segment] = [:]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let pins = [pin(type: "leaving_soon", segmentId: "R"), pin(type: "enforcement_active", segmentId: "R")]
        XCTAssertEqual(
            WPOpenSpotGate.filter(pins, segmentsByID: byID, engine: engine, from: now, until: end).count, 2
        )
    }

    // MARK: Copy

    func testMidnight_isWrittenMidnight_neverTwelveAM() {
        XCTAssertEqual(WPCurbCopy.midnightized("Tomorrow 12:00\u{00A0}AM"), "Tomorrow midnight")
        XCTAssertEqual(WPCurbCopy.midnightized("Today 12:00 AM"), "Today midnight")
        XCTAssertFalse(WPCurbCopy.midnightized("Mon 11/30 12:00 AM").contains("12"))
    }

    func testArrowSigns_readTheCornerLine_andNeverClaimDistances() {
        let segment = makeSegment([
            ruleJSON(.noStanding, anytime: true, description: "NO STANDING ANYTIME (ARROW)", arrow: "towards"),
            ruleJSON(.noParking, days: [1], ranges: [(540, 630)], description: "NO PARKING 9AM-10:30AM", arrow: "both"),
        ])
        let lines = WPSignList.lines(for: segment, engine: engine, now: now)
        XCTAssertEqual(lines.count, 2)
        let arrow = lines.first { $0.category == WePark.Category.noStanding.rawValue }
        XCTAssertEqual(arrow?.plain, "Arrow sign. Applies near the corner. Check the sign on the street.")
        for line in lines {
            XCTAssertFalse(line.plain.lowercased().contains("20 ft"))
            XCTAssertFalse(line.plain.lowercased().contains("past"))
            XCTAssertFalse(line.text.isEmpty, "the real sign text is always reachable")
        }
    }

    func testSignList_hiddenForNoData_andKeepsFullPostedText() {
        XCTAssertTrue(WPSignList.lines(for: makeSegment(noDataRules), engine: engine, now: now).isEmpty)
        let text = "NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9AM-10:30AM"
        let lines = WPSignList.lines(
            for: makeSegment([ruleJSON(.aspMonThu, days: [1, 4], ranges: [(540, 630)], description: text)]),
            engine: engine, now: now
        )
        XCTAssertEqual(lines.first?.text, text)
    }

    func testDragBubble_parkAndDont() {
        let park = WPDragBubble.make(from: model(clearRules), windowName: nil)
        XCTAssertEqual(park.tone, .park)
        XCTAssertEqual(park.headline, "Park")
        let dont = WPDragBubble.make(from: model(restrictedRules), windowName: nil)
        XCTAssertEqual(dont.tone, .dont)
    }

    func testParkWarning_neverNamesARestrictionForUnclearOrNoData() {
        XCTAssertFalse(WPParkCopy.warning(for: .unclear).lowercased().contains("cleaning"))
        XCTAssertFalse(WPParkCopy.warning(for: .nodata).lowercased().contains("cleaning"))
    }

    func testReminderLead_usesTheUsersRealOffsets() {
        XCTAssertEqual(WPParkCopy.reminderLead(.default), "We'll remind you 1 hour before.")
    }
}

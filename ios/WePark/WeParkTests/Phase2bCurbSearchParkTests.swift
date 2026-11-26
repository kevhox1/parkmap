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

    /// A synthetic tile grid (same geometry as tiles/index.json) with every tile existing in a
    /// 40 x 40 block around Midtown; `loaded` picks which of them are loaded.
    private func coverage(loaded: (Int, Int) -> Bool) -> WPTileCoverage {
        let latMin = 40.70, lngMin = -74.02, rowSize = 0.00227, colSize = 0.00226
        var existing = Set<String>(), loadedKeys = Set<String>()
        let baseRow = Int(((40.7600 - latMin) / rowSize).rounded(.down)) - 20
        let baseCol = Int(((-73.9776 - lngMin) / colSize).rounded(.down)) - 20
        for r in baseRow..<(baseRow + 40) {
            for c in baseCol..<(baseCol + 40) {
                existing.insert("\(r)_\(c)")
                if loaded(r, c) { loadedKeys.insert("\(r)_\(c)") }
            }
        }
        return WPTileCoverage(
            gridRows: 80, gridCols: 50, latMin: latMin, lngMin: lngMin, rowSize: rowSize, colSize: colSize,
            existingTiles: existing, loadedTiles: loadedKeys
        )
    }

    private var allLoaded: WPTileCoverage { coverage { _, _ in true } }

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
            let result = WPFreeCurbCounter.count(near: destination, segments: segments, coverage: allLoaded, engine: engine, from: now, until: end)
            XCTAssertEqual(result?.count, expected, "goal \(goal)")
        }
        let overnight = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertEqual(
            WPFreeCurbCounter.count(near: destination, segments: segments, coverage: allLoaded, engine: engine, from: now, until: overnight)?.count,
            4
        )
    }

    func testCount_isHidden_whenTilesNotLoadedNearDestination() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        let farAway = [makeSegment(clearRules, id: "FAR", lat: 40.8000, lng: -73.9500)]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: farAway, coverage: nil, engine: engine, from: now, until: end))
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: [], coverage: coverage { _, _ in false }, engine: engine, from: now, until: end))
    }

    /// One of the tiles under the 160 m radius is not loaded: the count must be hidden, never a low
    /// number or "No free curbs" (a false statement).
    func testCount_isHidden_whenAnyTileUnderTheCountingRadiusIsMissing() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        let segments = [makeSegment(clearRules, id: "NEAR"), makeSegment(restrictedRules, id: "R0")]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let destRow = Int(((40.7600 - 40.70) / 0.00227).rounded(.down))
        let destCol = Int(((-73.9776 + 74.02) / 0.00226).rounded(.down))
        // The destination's own tile loaded, but its north neighbor (inside 160 m) is not.
        let partial = coverage { r, c in !(r == destRow + 1 && c == destCol) }
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: segments, coverage: partial, engine: engine, from: now, until: end))
        // Same segments, everything loaded: shown.
        XCTAssertEqual(
            WPFreeCurbCounter.count(near: destination, segments: segments, coverage: allLoaded, engine: engine, from: now, until: end)?.count, 1
        )
        // Only a far-away tile missing (outside the radius): still shown.
        let farMissing = coverage { r, _ in r < destRow + 15 }
        XCTAssertNotNil(WPFreeCurbCounter.count(near: destination, segments: segments, coverage: farMissing, engine: engine, from: now, until: end))
    }

    func testCount_hasNoTilesAtAll_isHidden() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let empty = WPTileCoverage(
            gridRows: 80, gridCols: 50, latMin: 40.70, lngMin: -74.02, rowSize: 0.00227, colSize: 0.00226,
            existingTiles: [], loadedTiles: []
        )
        XCTAssertNil(WPFreeCurbCounter.count(near: destination, segments: [], coverage: empty, engine: engine, from: now, until: end))
    }

    /// Radius is covered but the wider "nearest" probe is not: "No free curbs" stands, the
    /// "nearest is" line is dropped (a nearer curb could sit in an unloaded tile).
    func testCount_zero_dropsNearestLine_whenProbeAreaNotFullyLoaded() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        let segments = [makeSegment(restrictedRules, id: "R0"), makeSegment(clearRules, id: "NEAR", lat: 40.7627)]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let destRow = Int(((40.7600 - 40.70) / 0.00227).rounded(.down))
        // Rows 3+ tiles north (> 160 m) are missing; rows within +-1 are loaded.
        let cov = coverage { r, _ in r <= destRow + 1 }
        let result = WPFreeCurbCounter.count(near: destination, segments: segments, coverage: cov, engine: engine, from: now, until: end)
        XCTAssertEqual(result?.count, 0)
        XCTAssertNil(result?.nearestMeters)
    }

    func testCount_zero_reportsNearestRealDistance_notAnEstimate() {
        let destination = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)
        // Loaded and covered, but the only clear curb is ~300 m away (inside the probe, outside 2 blocks).
        let segments = [
            makeSegment(restrictedRules, id: "R0"),
            makeSegment(clearRules, id: "NEAR", lat: 40.7627),
        ]
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let result = WPFreeCurbCounter.count(near: destination, segments: segments, coverage: allLoaded, engine: engine, from: now, until: end)
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

    // MARK: QA follow-ups (PR #199)

    func testOpenEnded_isWorded_FreeFor_notFreeUntil() {
        // A sign that never applies in the next 7 days (no days): an open-ended free stretch.
        let m = model([ruleJSON(.noParking, days: [], ranges: [(480, 540)])])
        XCTAssertEqual(m.variant, .park)
        XCTAssertTrue(m.isOpenEnded)
        XCTAssertEqual(m.big, "7+ days")
        XCTAssertEqual(m.freeLine, "Free for 7+ days")
        XCTAssertEqual(WPDragBubble.make(from: m, windowName: nil).detail, "Free for 7+ days")
        XCTAssertEqual(WPNeighborVerdict.calloutText(for: m), "Free for 7+ days")
        // A real end time keeps "until".
        let timed = model([ruleJSON(.noParking, days: [4], ranges: [(480, 540)])], at: et(2026, 11, 26, 7, 0).addingTimeInterval(-3600 * 10))
        XCTAssertFalse(timed.isOpenEnded)
        XCTAssertTrue(timed.freeLine.hasPrefix("Free until "))
        XCTAssertFalse(timed.freeLine.contains("7+"))
    }

    func testThreeSurfaces_agree_onAnActiveFilmingReport() {
        let segment = makeSegment(clearRules)
        let end = ParkingGoals.target(for: .freeOvernight, from: now)
        let reports = WPNeighborReports(restrictionLabel: "Blocked for filming", restrictionIsActive: true)
        let resolved = WPNeighborVerdict.resolve(
            segment: segment, engine: engine, now: now, windowEnd: end, trip: nil, reports: reports
        )
        XCTAssertEqual(resolved.variant, .dont)
        XCTAssertEqual(WPDragBubble.make(from: resolved, windowName: nil).tone, .dont)
        XCTAssertEqual(WPNeighborVerdict.calloutText(for: resolved), "Blocked for filming")
        // Without a report all three read park.
        let quiet = WPNeighborVerdict.resolve(
            segment: segment, engine: engine, now: now, windowEnd: end, trip: nil, reports: WPNeighborReports()
        )
        XCTAssertEqual(quiet.variant, .park)
        XCTAssertEqual(WPDragBubble.make(from: quiet, windowName: nil).tone, .park)
        // Plan a Trip ignores live reports.
        let plan = TripPlan(arrival: now.addingTimeInterval(86_400), departure: now.addingTimeInterval(2 * 86_400))
        XCTAssertTrue(WPNeighborVerdict.reports(for: pin(type: "filming", segmentId: "P2B"), now: now, trip: plan).restrictionLabel == nil)
    }

    func testMeteredCurb_offMeterHours_isNeverGreen_withOrWithoutAWindow() {
        // Meter 8 AM-7 PM every day; now is 10:11 PM, so the meter is off but starts at 8 AM.
        let rules = [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(480, 1140)])]
        let segment = makeSegment(rules)
        XCTAssertEqual(engine.currentState(for: segment, at: now), .freeComfortably, "fixture: meter off now")
        // No goal window: never park. Amber, truthful about the meter.
        let noWindow = model(rules)
        XCTAssertNotEqual(noWindow.variant, .park)
        XCTAssertEqual(noWindow.variant, .soon)
        XCTAssertTrue(noWindow.sub?.contains("the meter") ?? false)
        XCTAssertEqual(WPCurbVerdict.currentState(segment: segment, engine: engine, at: now), .freeButRestrictionSoon)
        // Window that runs into the meter (8 AM next day or later): not parkable, so never park.
        let long = et(2026, 11, 26, 10)
        let m = model(rules, window: long)
        XCTAssertFalse(WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: long))
        XCTAssertEqual(m.variant, .soon)
        // Overnight window that ends before the meter starts: same as the map (green).
        let overnight = et(2026, 11, 26, 7)
        XCTAssertTrue(WPCurbVerdict.isParkable(segment: segment, engine: engine, from: now, until: overnight))
        XCTAssertEqual(model(rules, window: overnight).variant, .park)
    }

    func testSheetPark_alwaysImpliesMapGreen_forEveryWindow() {
        // Property: whenever a window is set, `.park` requires `isParkable` (the map's green gate).
        let fixtures = [
            clearRules, meteredRules, restrictedRules, unclearRules, noDataRules,
            [ruleJSON(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(480, 1140)])],
            [ruleJSON(.metered, days: [1, 2, 3, 4, 5], ranges: [(480, 1140)]), ruleJSON(.noParking, days: [1], ranges: [(480, 540)])],
        ]
        for rules in fixtures {
            let segment = makeSegment(rules)
            for hour in stride(from: 0, to: 24 * 7, by: 7) {
                let date = now.addingTimeInterval(Double(hour) * 3600)
                for hours in [2.0, 9.0, 30.0, 96.0] {
                    let end = date.addingTimeInterval(hours * 3600)
                    let m = WPCurbSheetBuilder.make(segment: segment, engine: engine, now: date, windowEnd: end)
                    if m.variant == .park {
                        XCTAssertTrue(WPCurbVerdict.isParkable(segment: segment, engine: engine, from: date, until: end), "+\(hour)h window \(hours)h")
                    }
                }
            }
        }
    }
}

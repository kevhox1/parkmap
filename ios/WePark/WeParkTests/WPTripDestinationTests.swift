//
//  WPTripDestinationTests.swift
//  WeParkTests
//
//  R35 F-1 (Plan a Trip with a destination address). Pins:
//    - `TripPlan(arrival:departure:)` still compiles and equality includes the destination
//    - the summary line counts only curbs `TripPlanning.isFree` accepts for the whole trip, is nil
//      (never a number) while tiles are missing, and promises nothing outside Manhattan
//    - the picker's content states, the default destination, and the resolver's pure parts
//

import CoreLocation
import XCTest
@testable import WePark

final class WPTripDestinationTests: XCTestCase {

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

    /// Thu 11/26/2026 10 AM to 6 PM ET.
    private var plan: TripPlan {
        TripPlan(arrival: et(2026, 11, 26, 10), departure: et(2026, 11, 26, 18))
    }

    private let midtown = CLLocationCoordinate2D(latitude: 40.7600, longitude: -73.9776)

    private var midtownDestination: TripDestination {
        TripDestination(name: "Near 350 5th Ave", address: nil, latitude: 40.7600, longitude: -73.9776)
    }

    private func ruleJSON(
        _ category: WePark.Category, days: [Int] = [], ranges: [(Int, Int)] = [], anytime: Bool = false
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": "", "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": "both",
        ]
    }

    private func makeSegment(_ rules: [[String: Any]], id: String, lat: Double = 40.7600) -> Segment {
        let dict: [String: Any] = [
            "id": id, "street": "WEST 53RD STREET", "from": "5TH AVENUE", "to": "6TH AVENUE",
            "side": "N", "line": [[lat, -73.9776], [lat + 0.0002, -73.9773]], "rules": rules,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    /// Monday 8 to 9 AM no parking only: free on a Thursday.
    private var clearRules: [[String: Any]] { [ruleJSON(.noParking, days: [1], ranges: [(480, 540)])] }
    private var restrictedRules: [[String: Any]] { [ruleJSON(.noStanding, days: [0, 1, 2, 3, 4, 5, 6], anytime: true)] }

    /// A tile grid with every tile existing in a 40 x 40 block around Midtown; `loaded` picks the
    /// loaded ones.
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

    private func outcome(
        destination: TripDestination? = nil, segments: [Segment], coverage: WPTileCoverage?
    ) -> WPTripDestinationSummary.Outcome? {
        WPTripDestinationSummary.outcome(
            destination: destination ?? midtownDestination, plan: plan, segments: segments,
            coverage: coverage, engine: engine,
            isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }, strictSigns: true
        )
    }

    // MARK: TripPlan

    func testTripPlan_twoArgumentInit_stillWorks_andHasNoDestination() {
        let two = TripPlan(arrival: et(2026, 11, 26, 10), departure: et(2026, 11, 26, 18))
        XCTAssertNil(two.destination)
    }

    func testTripPlan_equalityIncludesDestination() {
        let a = plan
        var b = plan
        XCTAssertEqual(a, b)
        b.destination = midtownDestination
        XCTAssertNotEqual(a, b)
        var c = plan
        c.destination = midtownDestination
        XCTAssertEqual(b, c)
        c.destination = TripDestination(name: "Near 350 5th Ave", address: nil, latitude: 40.7601, longitude: -73.9776)
        XCTAssertNotEqual(b, c)
    }

    func testTripDestination_coordinateRoundTrips() {
        let coordinate = midtownDestination.coordinate
        XCTAssertEqual(coordinate.latitude, 40.7600, accuracy: 1e-9)
        XCTAssertEqual(coordinate.longitude, -73.9776, accuracy: 1e-9)
    }

    // MARK: Summary

    func testSummary_countsOnlyCurbsFreeForTheWholeTrip() {
        var segments: [Segment] = []
        for i in 0..<4 { segments.append(makeSegment(clearRules, id: "C\(i)", lat: 40.7600 + Double(i) * 0.0002)) }
        for i in 0..<3 { segments.append(makeSegment(restrictedRules, id: "R\(i)", lat: 40.7602 + Double(i) * 0.0001)) }
        segments.append(makeSegment(clearRules, id: "FAR", lat: 40.7700))
        guard case .counted(let free, let nearest)? = outcome(segments: segments, coverage: allLoaded) else {
            return XCTFail("expected a count")
        }
        XCTAssertEqual(free, 4)
        XCTAssertNotNil(nearest)
    }

    func testSummary_agreesWithTripPlanningIsFree_onAFixture() {
        let segments = [
            makeSegment(clearRules, id: "A"), makeSegment(restrictedRules, id: "B"),
            makeSegment(clearRules, id: "C", lat: 40.7603),
        ]
        let expected = segments.filter {
            WPFreeCurbCounter.distance(from: midtown, to: $0) <= WPFreeCurbCounter.radiusMeters
                && TripPlanning.isFree(segment: $0, plan: plan, engine: engine, strictSigns: true)
        }.count
        guard case .counted(let free, _)? = outcome(segments: segments, coverage: allLoaded) else {
            return XCTFail("expected a count")
        }
        XCTAssertEqual(free, expected)
        XCTAssertEqual(free, 2)
    }

    func testSummary_isNil_whileTilesUnderTheRadiusAreMissing() {
        let segments = [makeSegment(clearRules, id: "A")]
        let destRow = Int(((40.7600 - 40.70) / 0.00227).rounded(.down))
        let destCol = Int(((-73.9776 + 74.02) / 0.00226).rounded(.down))
        let partial = coverage { r, c in !(r == destRow + 1 && c == destCol) }
        XCTAssertNil(outcome(segments: segments, coverage: partial))
        XCTAssertNil(outcome(segments: segments, coverage: nil))
    }

    func testSummary_outsideManhattan_countsNothing() {
        let newark = TripDestination(name: "Newark Penn Station", address: nil, latitude: 40.7347, longitude: -74.1644)
        let result = outcome(destination: newark, segments: [makeSegment(clearRules, id: "A")], coverage: allLoaded)
        XCTAssertEqual(result, .outsideCoverage)
        let line = WPTripDestinationSummary.line(for: .outsideCoverage, destination: newark)
        XCTAssertEqual(line, "Newark Penn Station is outside Manhattan. WePark can't show free curbs there yet.")
    }

    func testSummaryLine_plural() {
        let line = WPTripDestinationSummary.line(
            for: .counted(free: 12, nearestMeters: 122), destination: midtownDestination
        )
        XCTAssertEqual(line, "Near 350 5th Ave: 12 curbs free for your whole trip. The nearest is 400 ft away.")
    }

    func testSummaryLine_singular() {
        let line = WPTripDestinationSummary.line(
            for: .counted(free: 1, nearestMeters: nil), destination: midtownDestination
        )
        XCTAssertEqual(line, "Near 350 5th Ave: 1 curb is free for your whole trip.")
    }

    func testSummaryLine_zeroWithNearest() {
        let line = WPTripDestinationSummary.line(
            for: .counted(free: 0, nearestMeters: 322), destination: midtownDestination
        )
        XCTAssertEqual(
            line, "Near 350 5th Ave: no free curbs within 2 blocks for your whole trip. The nearest is 0.2 mi away."
        )
    }

    func testSummaryLine_zeroWithoutNearest() {
        let line = WPTripDestinationSummary.line(
            for: .counted(free: 0, nearestMeters: nil), destination: midtownDestination
        )
        XCTAssertEqual(line, "Near 350 5th Ave: no free curbs within 2 blocks for your whole trip.")
    }

    func testSummaryLine_placeNameGetsNear_andUnnamedPointSaysAroundHere() {
        let penn = TripDestination(name: "Penn Station", address: "New York, NY", latitude: 40.7506, longitude: -73.9935)
        XCTAssertEqual(WPTripDestinationSummary.nearPrefix(penn), "Near Penn Station")
        let unnamed = WPTripDestinationPickerLogic.defaultDestination(center: midtown, label: nil)
        XCTAssertEqual(WPTripDestinationSummary.nearPrefix(unnamed), "Around here")
        XCTAssertEqual(WPTripDestinationSummary.checkingLine(destination: midtownDestination), "Checking curbs near 350 5th Ave.")
    }

    func testSummaryKey_changesWithTheLoadedTileSet() {
        let a = WPTripSummaryKey(destination: midtownDestination, plan: plan, segments: 10, loadedTiles: ["1_1", "1_2"])
        let b = WPTripSummaryKey(destination: midtownDestination, plan: plan, segments: 10, loadedTiles: ["1_1", "1_3"])
        XCTAssertNotEqual(a, b)
    }

    // MARK: Picker and defaults

    func testPicker_emptyQuery_showsRecents() {
        XCTAssertEqual(
            WPTripDestinationPickerLogic.content(query: "", completionCount: 0, settled: false), .recents
        )
        XCTAssertEqual(
            WPTripDestinationPickerLogic.content(query: "   ", completionCount: 3, settled: true), .recents
        )
    }

    func testPicker_noCompletions_showsEmptyStateOnceSettled() {
        XCTAssertEqual(
            WPTripDestinationPickerLogic.content(query: "qzxv", completionCount: 0, settled: true),
            .empty(message: "No places found for 'qzxv'. Try a street address.")
        )
        XCTAssertEqual(
            WPTripDestinationPickerLogic.content(query: "qzxv", completionCount: 0, settled: false), .searching
        )
    }

    func testPicker_completions_showSuggestions() {
        XCTAssertEqual(
            WPTripDestinationPickerLogic.content(query: "350 5th", completionCount: 4, settled: false), .suggestions
        )
    }

    func testDefaultDestination_usesMapCentre_andFallsBackToUnnamedPoint() {
        let named = WPTripDestinationPickerLogic.defaultDestination(center: midtown, label: "Near 350 5th Ave")
        XCTAssertEqual(named.name, "Near 350 5th Ave")
        XCTAssertEqual(named.latitude, midtown.latitude)
        XCTAssertEqual(named.longitude, midtown.longitude)
        let unnamed = WPTripDestinationPickerLogic.defaultDestination(center: midtown, label: nil)
        XCTAssertEqual(unnamed.name, "This part of the map")
    }

    func testIsMapCentreDefault_isFalseOncePlaceHasAnAddressOrMoved() {
        let base = WPTripDestinationPickerLogic.defaultDestination(center: midtown, label: nil)
        XCTAssertTrue(WPTripDestinationPickerLogic.isMapCentreDefault(base, center: midtown))
        XCTAssertFalse(WPTripDestinationPickerLogic.isMapCentreDefault(nil, center: midtown))
        let picked = TripDestination(name: "Penn Station", address: "New York", latitude: 40.7506, longitude: -73.9935)
        XCTAssertFalse(WPTripDestinationPickerLogic.isMapCentreDefault(picked, center: midtown))
    }

    // MARK: Resolver (pure parts)

    func testResolver_nearLabel_fromNumberAndStreet() {
        XCTAssertEqual(WPPlaceResolver.nearLabel(houseNumber: "350", street: "5th Ave"), "Near 350 5th Ave")
        XCTAssertEqual(WPPlaceResolver.nearLabel(houseNumber: nil, street: "5th Ave"), "Near 5th Ave")
        XCTAssertNil(WPPlaceResolver.nearLabel(houseNumber: "350", street: nil))
        XCTAssertNil(WPPlaceResolver.nearLabel(houseNumber: nil, street: "  "))
    }

    func testResolver_errorMessagesMatchTheSearchSheet() {
        XCTAssertEqual(WPPlaceResolver.message(for: WPPlaceTimeoutError()), "Search timed out. Try again.")
        XCTAssertEqual(
            WPPlaceResolver.message(for: URLError(.notConnectedToInternet)),
            "Couldn't find that place. Check your connection and try again."
        )
    }

    func testResolver_withTimeout_throwsWhenOperationIsSlow() async {
        do {
            _ = try await WPPlaceResolver.withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is WPPlaceTimeoutError)
        }
    }

    func testResolver_withTimeout_returnsFastResult() async throws {
        let value = try await WPPlaceResolver.withTimeout(seconds: 5) { 7 }
        XCTAssertEqual(value, 7)
    }
}

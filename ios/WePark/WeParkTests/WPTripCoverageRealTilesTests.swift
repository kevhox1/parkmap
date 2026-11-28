//
//  WPTripCoverageRealTilesTests.swift
//  WeParkTests
//
//  R35-12 follow-up: which trip destinations are "outside coverage" and which are "inside Manhattan
//  but no curbs right at the spot" is decided from the REAL tile index, not the bounding box.
//  Central Park, Bryant Park, Battery Park, Little Island and DUMBO are checked against the bundled
//  `tiles/index.json`.
//

import CoreLocation
import XCTest
@testable import WePark

final class WPTripCoverageRealTilesTests: XCTestCase {

    private struct Index: Decodable {
        struct Entry: Decodable { let row: Int; let col: Int }
        let gridSize: Grid
        let latMin: Double, lngMin: Double, rowSize: Double, colSize: Double
        let tiles: [Entry]
        struct Grid: Decodable { let rows: Int; let cols: Int }
    }

    /// Every tile in the real index, all marked loaded.
    private func realCoverage() throws -> (WPTileCoverage, Index) {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "json"))
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
        let keys = Set(index.tiles.map { "\($0.row)_\($0.col)" })
        let coverage = WPTileCoverage(
            gridRows: index.gridSize.rows, gridCols: index.gridSize.cols,
            latMin: index.latMin, lngMin: index.lngMin, rowSize: index.rowSize, colSize: index.colSize,
            existingTiles: keys, loadedTiles: keys
        )
        return (coverage, index)
    }

    private func classify(_ lat: Double, _ lng: Double) throws -> WPTripDestinationSummary.CoverageClass {
        let (coverage, _) = try realCoverage()
        return WPTripDestinationSummary.coverageClass(
            of: CLLocationCoordinate2D(latitude: lat, longitude: lng), coverage: coverage,
            isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }
        )
    }

    // MARK: Classification over real tiles

    func testCentralPark_isInsideManhattanButHasNoCurbsHere() throws {
        XCTAssertEqual(try classify(40.7829, -73.9654), .noCurbsHere)
    }

    func testBryantPark_isCovered() throws {
        XCTAssertEqual(try classify(40.7536, -73.9832), .covered)
    }

    func testBatteryPark_isCovered() throws {
        XCTAssertEqual(try classify(40.7033, -74.0170), .covered)
    }

    func testLittleIsland_isCovered() throws {
        XCTAssertEqual(try classify(40.7421, -74.0100), .covered)
    }

    func testDUMBO_isOutsideCoverage() throws {
        XCTAssertEqual(try classify(40.7033, -73.9890), .outside)
    }

    func testBrooklynBridgePark_randallsAndSouthpoint_areOutsideCoverage() throws {
        XCTAssertEqual(try classify(40.7015, -73.9965), .outside)
        XCTAssertEqual(try classify(40.7930, -73.9210), .outside)
        XCTAssertEqual(try classify(40.7115, -73.9505), .outside)
    }

    func testNoTileIndexYet_isUnknown_insideTheBox_andOutsideOutsideIt() {
        let inside = CLLocationCoordinate2D(latitude: 40.7829, longitude: -73.9654)
        let newark = CLLocationCoordinate2D(latitude: 40.7347, longitude: -74.1644)
        XCTAssertEqual(
            WPTripDestinationSummary.coverageClass(of: inside, coverage: nil, isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }),
            .unknown
        )
        XCTAssertEqual(
            WPTripDestinationSummary.coverageClass(of: newark, coverage: nil, isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }),
            .outside
        )
    }

    // MARK: Outcome over real segments

    func testCentralPark_outcome_isNoCurbsHere_withHonestNearestCurb() throws {
        let (coverage, index) = try realCoverage()
        let park = TripDestination(name: "Central Park", address: nil, latitude: 40.7829, longitude: -73.9654)
        // Only the tiles around the park (the segment list the app would have loaded).
        let row = Int(((park.latitude - index.latMin) / index.rowSize).rounded(.down))
        let col = Int(((park.longitude - index.lngMin) / index.colSize).rounded(.down))
        var segments: [Segment] = []
        for tile in index.tiles where abs(tile.row - row) <= 4 && abs(tile.col - col) <= 4 {
            guard let url = Bundle.main.url(forResource: "tile_\(tile.row)_\(tile.col)", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Segment].self, from: data) else { continue }
            segments.append(contentsOf: decoded)
        }
        XCTAssertFalse(segments.isEmpty)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 11; comps.day = 26; comps.hour = 10; comps.timeZone = .easternTime
        let arrival = try XCTUnwrap(Calendar.easternTime.date(from: comps))
        let plan = TripPlan(arrival: arrival, departure: arrival.addingTimeInterval(8 * 3600))
        let engine = ParkingRulesEngine(aspService: ASPSuspensionService())
        let outcome = try XCTUnwrap(WPTripDestinationSummary.outcome(
            destination: park, plan: plan, segments: segments, coverage: coverage, engine: engine,
            isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }, strictSigns: true
        ))
        guard case .noCurbsHere(let nearest, let street) = outcome else {
            return XCTFail("expected noCurbsHere, got \(outcome)")
        }
        if let nearest {
            XCTAssertGreaterThan(nearest, WPFreeCurbCounter.radiusMeters)
            XCTAssertLessThanOrEqual(nearest, WPFreeCurbCounter.coverageProbeMeters)
            XCTAssertNotNil(street)
        } else {
            XCTAssertNil(street)
        }
        let line = WPTripDestinationSummary.line(for: outcome, destination: park)
        XCTAssertTrue(line.hasPrefix("No street parking right at Central Park."))
        XCTAssertFalse(line.contains("Not covered"))
    }

    func testNoCurbsHere_isNil_whileTheTilesAroundItAreNotLoaded() throws {
        let (full, index) = try realCoverage()
        let none = WPTileCoverage(
            gridRows: full.gridRows, gridCols: full.gridCols, latMin: index.latMin, lngMin: index.lngMin,
            rowSize: index.rowSize, colSize: index.colSize, existingTiles: full.existingTiles, loadedTiles: []
        )
        let park = TripDestination(name: "Central Park", address: nil, latitude: 40.7829, longitude: -73.9654)
        let engine = ParkingRulesEngine(aspService: ASPSuspensionService())
        let plan = TripPlan(arrival: Date(), departure: Date().addingTimeInterval(3600))
        XCTAssertNil(WPTripDestinationSummary.outcome(
            destination: park, plan: plan, segments: [], coverage: none, engine: engine,
            isInsideCoverage: { AppConstants.isInManhattanCoverage($0) }, strictSigns: true
        ))
    }

    // MARK: Wording

    func testNoCurbsHereLine_withNearestStreet() {
        let park = TripDestination(name: "Central Park", address: nil, latitude: 40.7829, longitude: -73.9654)
        let line = WPTripDestinationSummary.line(
            for: .noCurbsHere(nearestMeters: 183, street: "Central Park W"), destination: park
        )
        XCTAssertEqual(
            line,
            "No street parking right at Central Park. The nearest free curbs for your whole trip are on Central Park W, 600 ft away."
        )
    }

    func testNoCurbsHereLine_withoutAFreeCurbNearby() {
        let park = TripDestination(name: "Central Park", address: nil, latitude: 40.7829, longitude: -73.9654)
        let line = WPTripDestinationSummary.line(for: .noCurbsHere(nearestMeters: nil, street: nil), destination: park)
        XCTAssertEqual(
            line, "No street parking right at Central Park. No curbs free for your whole trip within a quarter mile."
        )
    }

    func testOutsideCoverageLine_isStillNotCoveredYet() {
        let dumbo = TripDestination(name: "DUMBO", address: nil, latitude: 40.7033, longitude: -73.9890)
        XCTAssertTrue(WPTripDestinationSummary.line(for: .outsideCoverage, destination: dumbo).hasPrefix("Not covered yet."))
    }
}

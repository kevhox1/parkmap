//
//  ViewportPolishTests.swift
//  WeParkTests
//
//  Unit tests for the Viewport-Polish feature:
//    - Part A: polylineHideSpanThreshold constant change (0.1 → 0.04). Verified by AC-A1.
//      The constant itself is private to ContentView, so it is verified via simulator smoke
//      (AC-A2 through AC-A5). The threshold value does not have a testable public API;
//      the QA verifier covers that via the simulator scenario in viewport-polish-spec.md §7.
//
//    - Part B: isInManhattanCoverage(_:) bounding-box function.
//      All tests here validate the public AppConstants API.
//      Priority logic lives in ContentView.task{} — it is launch-sequencing with @State side
//      effects and cannot be unit-tested without UITest infrastructure. The pattern matches W6.1:
//      routePendingDeepLink is also private and tested via inline simulation. For consistency,
//      the launch-priority logic is covered by simulator smoke (AC-B1 through AC-B6 in the spec)
//      and the observable outcome (isInManhattanCoverage) is covered here.
//
//  Test count added by this file: 12
//  Pre-PR total: 79 (7 W61 + 12 W7 + 15 NotificationScheduler + 45 ParkingRulesEngineParity)
//  Post-PR total: 91
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - isInManhattanCoverage: points inside the tile grid

final class IsInManhattanCoverageInsideTests: XCTestCase {

    // MARK: - testCoverage_downtown_isInside
    // Financial District / Lower Manhattan — well within bounds.
    func testCoverage_downtown_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.7075, longitude: -74.0113)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Lower Manhattan (40.7075, -74.0113) must be inside coverage")
    }

    // MARK: - testCoverage_midtown_isInside
    // Midtown Manhattan — central.
    func testCoverage_midtown_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Midtown Manhattan (40.7580, -73.9855) must be inside coverage")
    }

    // MARK: - testCoverage_upperWestSide_isInside
    // Upper West Side — north of Central Park, still within latMax 40.882.
    func testCoverage_upperWestSide_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.7990, longitude: -73.9690)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Upper West Side (40.7990, -73.9690) must be inside coverage")
    }

    // MARK: - testCoverage_harlem_isInside
    // Harlem — near lat 40.810, well inside.
    func testCoverage_harlem_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.8110, longitude: -73.9465)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Harlem (40.8110, -73.9465) must be inside coverage")
    }

    // MARK: - testCoverage_rooseveltIsland_isInside
    // Roosevelt Island (lat ~40.762, lon ~-73.953) — spec notes this falls inside the box.
    func testCoverage_rooseveltIsland_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.7620, longitude: -73.9530)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Roosevelt Island (40.7620, -73.9530) must be inside coverage (spec §5)")
    }

    // MARK: - testCoverage_manhattanCenter_isInside
    // The default launch center (AppConstants.manhattanCenter) must be inside its own tile grid.
    func testCoverage_manhattanCenter_isInside() {
        let coord = CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        )
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "AppConstants.manhattanCenter must be inside coverage bounds")
    }

    // MARK: - testCoverage_exactBoundaryLatMin_isInside
    // Coordinate exactly on the southern boundary (latMin 40.700) — should be inclusive.
    func testCoverage_exactBoundaryLatMin_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.700, longitude: -73.970)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Coordinate on exact latMin boundary (40.700) must be included (>=)")
    }

    // MARK: - testCoverage_exactBoundaryLatMax_isInside
    // Coordinate exactly on the northern boundary (latMax 40.882) — should be inclusive.
    func testCoverage_exactBoundaryLatMax_isInside() {
        let coord = CLLocationCoordinate2D(latitude: 40.882, longitude: -73.940)
        XCTAssertTrue(AppConstants.isInManhattanCoverage(coord),
                      "Coordinate on exact latMax boundary (40.882) must be included (<=)")
    }
}

// MARK: - isInManhattanCoverage: points outside the tile grid

final class IsInManhattanCoverageOutsideTests: XCTestCase {

    // MARK: - testCoverage_hoboken_isOutside
    // Hoboken NJ (lon -74.0324) — west of lngMin -74.020. The key AC-B5 case.
    func testCoverage_hoboken_isOutside() {
        let coord = CLLocationCoordinate2D(latitude: 40.7440, longitude: -74.0324)
        XCTAssertFalse(AppConstants.isInManhattanCoverage(coord),
                       "Hoboken NJ (40.7440, -74.0324) must be outside coverage (lon < lngMin -74.020)")
    }

    // MARK: - testCoverage_yonkers_isOutside
    // Yonkers (lat 40.9312) — north of latMax 40.882. The other AC-B5 case.
    func testCoverage_yonkers_isOutside() {
        let coord = CLLocationCoordinate2D(latitude: 40.9312, longitude: -73.8988)
        XCTAssertFalse(AppConstants.isInManhattanCoverage(coord),
                       "Yonkers (40.9312, -73.8988) must be outside coverage (lat > latMax 40.882)")
    }

    // MARK: - testCoverage_jfk_isOutside
    // JFK Airport (lat ~40.641) — south of latMin 40.700.
    func testCoverage_jfk_isOutside() {
        let coord = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
        XCTAssertFalse(AppConstants.isInManhattanCoverage(coord),
                       "JFK Airport (40.6413, -73.7781) must be outside coverage (lat < latMin 40.700)")
    }

    // MARK: - testCoverage_atlanticCity_isOutside
    // Atlantic City NJ — far south-west, well outside on both lat and lon.
    func testCoverage_atlanticCity_isOutside() {
        let coord = CLLocationCoordinate2D(latitude: 39.3643, longitude: -74.4229)
        XCTAssertFalse(AppConstants.isInManhattanCoverage(coord),
                       "Atlantic City NJ (39.3643, -74.4229) must be outside coverage")
    }

    // MARK: - testCoverage_exactBoundaryOneLessThanLatMin_isOutside
    // One epsilon below latMin — must be excluded.
    func testCoverage_justBelowLatMin_isOutside() {
        // 40.699999... just south of 40.700.
        let coord = CLLocationCoordinate2D(latitude: 40.700 - 0.000001, longitude: -73.970)
        XCTAssertFalse(AppConstants.isInManhattanCoverage(coord),
                       "A latitude infinitesimally below latMin 40.700 must be outside coverage")
    }
}

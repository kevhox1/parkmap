//
//  WPZoomOutFollowUpTests.swift
//  WeParkTests
//
//  R35 PR2b: the zoom-out follow-ups (loading pill after a far pan, zoomed-out dock lead).
//

import CoreLocation
import XCTest
@testable import WePark

final class WPZoomOutFollowUpTests: XCTestCase {

    private func coverage(loaded: Set<String>) -> WPTileCoverage {
        WPTileCoverage(
            gridRows: 10, gridCols: 10, latMin: 40.0, lngMin: -74.0, rowSize: 0.01, colSize: 0.01,
            existingTiles: ["2_3", "2_4"], loadedTiles: loaded
        )
    }

    // Row 2, col 3.
    private let overTile = CLLocationCoordinate2D(latitude: 40.025, longitude: -73.965)

    func testPendingWhenTheTileUnderTheViewIsNotLoaded() {
        XCTAssertTrue(coverage(loaded: []).hasPendingTile(atCenter: overTile))
        XCTAssertTrue(coverage(loaded: ["2_4"]).hasPendingTile(atCenter: overTile))
    }

    func testNotPendingOnceItLands() {
        XCTAssertFalse(coverage(loaded: ["2_3"]).hasPendingTile(atCenter: overTile))
    }

    func testNotPendingOverNoTilesAtAll() {
        // Row 8, col 8 has no tile in the sparse set; nothing to wait for.
        let nowhere = CLLocationCoordinate2D(latitude: 40.085, longitude: -73.915)
        XCTAssertFalse(coverage(loaded: []).hasPendingTile(atCenter: nowhere))
    }

    func testBadCentreNeverCrashesOrPends() {
        let bad = CLLocationCoordinate2D(latitude: .nan, longitude: .infinity)
        XCTAssertFalse(coverage(loaded: []).hasPendingTile(atCenter: bad))
    }

    func testZoomedOutDockLeadDoesNotClaimWhatTheGreenMeans() {
        func input(zoomedOut: Bool) -> WPGoalSheetInput {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            return WPGoalSheetInput(
                selectedGoal: .freeOvernight, now: now,
                fewHoursEnd: now.addingTimeInterval(3 * 3600),
                overnightEnd: now.addingTimeInterval(8 * 3600),
                forDaysEnd: now.addingTimeInterval(7 * 86_400),
                detailMode: false, loading: false, guardKind: nil, note: nil,
                morningHour: ParkingGoals.defaultOvernightMorningHour,
                zoomedOut: zoomedOut
            )
        }
        XCTAssertEqual(input(zoomedOut: false).lead, "Green curbs are free from now until")
        XCTAssertEqual(input(zoomedOut: true).lead, "Zoom in to see which curbs are free until")
    }
}

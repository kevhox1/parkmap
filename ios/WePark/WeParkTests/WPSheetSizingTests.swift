//
//  WPSheetSizingTests.swift
//  WeParkTests
//
//  R35 PR4: the pure rules behind content-sized sheets (`WPSheetSizing`). The live layout (no gap
//  above "Drive here", AX5 scrolling) is verified with simulator screenshots in the PR.
//

import XCTest
@testable import WePark

final class WPSheetSizingTests: XCTestCase {

    func testClamp_belowMinimum_usesMinimum() {
        let height = WPSheetSizing.clamp(measured: 120, screenHeight: 900)
        XCTAssertEqual(height, 260)
    }

    func testClamp_inRange_roundsToWholePoint() {
        let height = WPSheetSizing.clamp(measured: 411.6, screenHeight: 900)
        XCTAssertEqual(height, 412)
    }

    func testClamp_aboveCeiling_capsAtEightyFivePercentOfScreen() {
        let height = WPSheetSizing.clamp(measured: 2000, screenHeight: 900)
        XCTAssertEqual(height, 765)
    }

    func testClamp_customMinimum() {
        let height = WPSheetSizing.clamp(measured: 100, screenHeight: 900, minimum: 300)
        XCTAssertEqual(height, 300)
    }

    func testClamp_nanAndInfinity_fallBackToMinimum() {
        let nan = WPSheetSizing.clamp(measured: .nan, screenHeight: 900)
        let infinite = WPSheetSizing.clamp(measured: .infinity, screenHeight: 900)
        let zero = WPSheetSizing.clamp(measured: 0, screenHeight: 900)
        let negative = WPSheetSizing.clamp(measured: -40, screenHeight: 900)
        XCTAssertEqual(nan, 260)
        XCTAssertEqual(infinite, 260)
        XCTAssertEqual(zero, 260)
        XCTAssertEqual(negative, 260)
    }

    func testClamp_unusableScreenHeight_keepsMeasured() {
        let noScreen = WPSheetSizing.clamp(measured: 400, screenHeight: 0)
        let nanScreen = WPSheetSizing.clamp(measured: 400, screenHeight: .nan)
        XCTAssertEqual(noScreen, 400)
        XCTAssertEqual(nanScreen, 400)
    }

    func testClamp_tinyScreen_neverBelowMinimum() {
        // Landscape on a small phone: 85% of 300 is 255, under the 260 floor. The floor wins.
        let height = WPSheetSizing.clamp(measured: 500, screenHeight: 300)
        XCTAssertEqual(height, 260)
    }

    func testShouldUpdate_ignoresChangesUnderTwoPoints() {
        XCTAssertFalse(WPSheetSizing.shouldUpdate(current: 400, new: 401))
        XCTAssertFalse(WPSheetSizing.shouldUpdate(current: 400, new: 400))
        XCTAssertTrue(WPSheetSizing.shouldUpdate(current: 400, new: 402))
        XCTAssertTrue(WPSheetSizing.shouldUpdate(current: 400, new: 380))
    }

    func testShouldUpdate_rejectsNonFinite() {
        XCTAssertFalse(WPSheetSizing.shouldUpdate(current: 400, new: .nan))
        XCTAssertFalse(WPSheetSizing.shouldUpdate(current: 400, new: .infinity))
        XCTAssertFalse(WPSheetSizing.shouldUpdate(current: 400, new: -5))
    }
}

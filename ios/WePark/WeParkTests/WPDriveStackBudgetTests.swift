//
//  WPDriveStackBudgetTests.swift
//  WeParkTests
//
//  DT35-6b: the Stoop drive stack gives way at accessibility sizes so the Apple Maps logo and
//  Legal link keep a clear strip (see `MapBottomInsetPolicy`).
//

import XCTest
@testable import WePark

final class WPDriveStackBudgetTests: XCTestCase {

    func testStandardSizesKeepTheOriginalVerdictBudget() {
        XCTAssertEqual(WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: false), 0.55)
    }

    func testAccessibilitySizesCapTheVerdictsLower() {
        let ax = WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: true)
        XCTAssertLessThan(ax, WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize: false))
        // Verdicts plus roughly 0.25 of the screen for pill and actions stay inside the inset clamp.
        XCTAssertLessThanOrEqual(ax + 0.25, MapBottomInsetPolicy.maxHeightFraction)
    }
}

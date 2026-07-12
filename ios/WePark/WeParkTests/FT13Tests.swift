//
//  FT13Tests.swift
//  WeParkTests
//
//  FT-13 — Parking 101 "?" toolbar button (docs/field-testing-log.md).
//  Light, targeted tests mirroring the paddingForBannerState / recenterPillBottomPadding
//  precedent (W85cPolishTests.swift): the visibility rule is extracted as a pure function
//  so it's covered without instantiating a full ContentView — no ViewInspector/snapshot
//  library exists in this repo, so the button's actual on-screen anatomy is covered by
//  the mandatory engineer live-UI smoke instead.
//

import XCTest
@testable import WePark

// MARK: - parkingGuideButtonVisible(driveModeActive:) Tests

final class ParkingGuideButtonVisibilityTests: XCTestCase {

    func testParkingGuideButton_visibleWhenNotDriving() {
        XCTAssertTrue(
            parkingGuideButtonVisible(driveModeActive: false),
            "The Parking 101 guide button should be visible whenever Drive Mode is inactive"
        )
    }

    func testParkingGuideButton_hiddenWhileDriving() {
        XCTAssertFalse(
            parkingGuideButtonVisible(driveModeActive: true),
            "The Parking 101 guide button should be hidden during Drive Mode — the drive " +
            "overlay layer (End Drive / Report / Park Here pill row) owns the same top-left " +
            "corner it shares with the gear button"
        )
    }
}

// MARK: - ActiveSheet.parkingGuide wiring (toolbar trigger)

/// Confirms the FT-12 `ActiveSheet.parkingGuide` case (already covered by
/// `ParkingGuideActiveSheetTests` in FT12Tests.swift) remains the stable trigger the new
/// toolbar button assigns to `activeSheet` — a regression guard specific to the FT-13
/// wiring, distinct from FT-12's own coverage of the sheet identity itself.
final class FT13ToolbarWiringTests: XCTestCase {

    func testParkingGuideSheetCase_stillHasStableID() {
        XCTAssertEqual(
            ActiveSheet.parkingGuide.id, "parkingGuide",
            "FT-13's toolbar button sets activeSheet = .parkingGuide — the case's stable " +
            "id must not drift, or SwiftUI's .sheet(item:) identity breaks"
        )
    }
}

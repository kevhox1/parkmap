//
//  FT18Tests.swift
//  WeParkTests
//
//  FT-18 — Drive Mode layout redesign (docs/design/ft18-drive-mode-layout.md).
//  Light, targeted tests mirroring the parkingGuideButtonVisible / paddingForBannerState /
//  recenterPillBottomPadding precedent (FT13Tests.swift / W85cPolishTests.swift): visibility
//  rules are extracted as pure functions so they're covered without instantiating a full
//  ContentView — no ViewInspector/snapshot library exists in this repo, so the actual
//  on-screen composition (Bottom Dock ordering across all 7 states, End control isolation,
//  no duplicate mute toggle) is covered by the mandatory engineer live-UI smoke instead
//  (see the PR description's smoke checklist).
//

import XCTest
@testable import WePark

// MARK: - gearButtonVisible(driveModeActive:) Tests

final class GearButtonVisibilityTests: XCTestCase {

    func testGearButton_visibleWhenNotDriving() {
        XCTAssertTrue(
            gearButtonVisible(driveModeActive: false),
            "The gear (Settings) button should be visible whenever Drive Mode is inactive"
        )
    }

    func testGearButton_hiddenWhileDriving() {
        XCTAssertFalse(
            gearButtonVisible(driveModeActive: true),
            "FT-18 ruling #3: the gear button should be fully hidden during Drive Mode " +
            "(not dimmed-but-tappable) — not needed mid-drive, and voice control stays " +
            "reachable via the always-visible mute button in DriveModeBottomCard"
        )
    }

    /// FT-18 ruling #3 explicitly settled "hide fully" over "dim to ~40% and keep tappable" —
    /// this asserts the gating function follows the same all-or-nothing rule as
    /// `parkingGuideButtonVisible`, not an opacity gradient.
    func testGearButton_matchesParkingGuideButtonVisibilityRule() {
        for active in [true, false] {
            XCTAssertEqual(
                gearButtonVisible(driveModeActive: active),
                parkingGuideButtonVisible(driveModeActive: active),
                "gearButtonVisible and parkingGuideButtonVisible should agree for " +
                "driveModeActive == \(active) — both buttons share the same top-leading " +
                "corner and the same Drive Mode gating rule"
            )
        }
    }
}

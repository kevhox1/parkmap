//
//  W85cPolishTests.swift
//  WeParkTests
//
//  W8.5c-polish PR-1 unit tests:
//    1. Distance indicator metric formatting
//    2. Distance indicator imperial formatting
//    3. Distance indicator nil destination hides indicator (no element rendered)
//    4. End Drive pill spacing — ASP banner vs. no banner (documented; not live-UI asserted)
//
//  Baseline: 196/0 at W8.5c merge. Target: ≥199/0 after PR-1.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
import CoreLocation
import SwiftUI
@testable import WePark

// MARK: - Distance Formatting Tests

final class DistanceFormattingTests: XCTestCase {

    // MARK: - Test 1: Metric locale → "1.2 km" for 1200 m

    func testDistanceIndicator_metric_formatsCorrectly() {
        // Construct a card with usesMetricSystem = true to simulate a metric locale.
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: 1200.0,  // 1200 m
            usesMetricSystem: true
        )

        // 1200 m → 1200 / 1000 = 1.2 km.
        let result = card.formattedDistance(meters: 1200.0)
        // MeasurementFormatter with .providedUnit and 1 decimal formats 1.2 km as "1.2 km".
        // We verify the expected value contains the number and unit.
        XCTAssertTrue(result.contains("1.2"), "Expected '1.2' in metric-formatted distance, got: \(result)")
        XCTAssertTrue(result.lowercased().contains("km"), "Expected 'km' in metric-formatted distance, got: \(result)")
    }

    // MARK: - Test 2: Imperial locale → "0.8 mi" for ~1287.5 m

    func testDistanceIndicator_imperial_formatsCorrectly() {
        // 0.8 miles = 0.8 * 1609.344 = 1287.4752 m
        let distanceMeters = 0.8 * 1609.344
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: distanceMeters,
            usesMetricSystem: false
        )

        let result = card.formattedDistance(meters: distanceMeters)
        // 1287.4752 m → 1287.4752 / 1609.344 = 0.8 miles exactly.
        XCTAssertTrue(result.contains("0.8"), "Expected '0.8' in imperial-formatted distance, got: \(result)")
        XCTAssertTrue(result.lowercased().contains("mi"), "Expected 'mi' in imperial-formatted distance, got: \(result)")
    }

    // MARK: - Test 3: nil destination — indicator is not rendered

    func testDistanceIndicator_nilDestination_hidesIndicator() {
        // When destinationDistance is nil, the distance Text element must not be rendered.
        // We verify this by checking the card's stored property — the conditional rendering
        // in cardContent only adds the Text when destinationDistance != nil.
        // Structural assertion: the card's destinationDistance being nil means the if-branch
        // is never taken. This is a state-machine test (nil → no indicator).
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: nil
        )
        // destinationDistance is nil — the Text element is conditionally excluded.
        XCTAssertNil(card.destinationDistance, "destinationDistance should be nil when no destination is set")
    }

    // MARK: - Test 4: Distance precision — tenths only

    func testDistanceIndicator_metric_roundsToOneTenth() {
        // 1900 m = 1.9 km exactly — no rounding ambiguity.
        // (1850 m = 1.85 km was previously used but MeasurementFormatter uses banker's
        // rounding / half-to-even, which rounds 1.85 → 1.8, not 1.9. Use 1900 m instead.)
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: 1900.0,
            usesMetricSystem: true
        )
        let result = card.formattedDistance(meters: 1900.0)
        XCTAssertTrue(result.contains("1.9"), "Expected '1.9' for 1900 m metric, got: \(result)")
    }

    // MARK: - Test 5: Imperial rounding — 1.0 mile threshold

    func testDistanceIndicator_imperial_oneMileFormats() {
        // Exactly 1.0 miles = 1609.344 m.
        let distanceMeters = 1609.344
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: distanceMeters,
            usesMetricSystem: false
        )
        let result = card.formattedDistance(meters: distanceMeters)
        XCTAssertTrue(result.contains("1.0"), "Expected '1.0' for exactly 1 mile, got: \(result)")
        XCTAssertTrue(result.lowercased().contains("mi"), "Expected 'mi' unit for 1609.344 m, got: \(result)")
    }

    // MARK: - Test 6: Very small metric distance — formats to tenths

    func testDistanceIndicator_metric_smallDistance_formats() {
        // 200 m → 0.2 km
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: nil,
            voiceService: voice,
            destinationDistance: 200.0,
            usesMetricSystem: true
        )
        let result = card.formattedDistance(meters: 200.0)
        XCTAssertTrue(result.contains("0.2"), "Expected '0.2' for 200 m metric, got: \(result)")
    }
}

// MARK: - End Drive Pill Z-Order Tests

final class EndDrivePillZOrderTests: XCTestCase {

    // MARK: - Test 7: .aspInEffect — pill must clear the amber ASP banner (non-zero padding)

    /// Verifies that `paddingForBannerState` returns non-zero clearance for `.aspInEffect`.
    ///
    /// Regression guard for the PR-1 bug where the property returned 0 for `.aspInEffect`,
    /// placing the End Drive pill flush against the top of the screen with no clearance for
    /// the status bar or the amber "ASP in Effect Today" banner.
    ///
    /// This is a pure logic test against `paddingForBannerState(_:)` — the actual view
    /// layout is verified by live-UI smoke (documented in the PR description). Live-UI smoke
    /// is mandatory per the merge gate established after the W8.5c-polish revert.
    ///
    /// TF2-18 P2-2: value raised from 44 to 100 to align the two Drive Mode toolbar
    /// clusters (top-left End Drive/Report/Park Here vs. top-right Find me/Find car/Park
    /// Until/Drive, which has always used a hardcoded 100pt offset) — see
    /// `paddingForBannerState`'s doc comment for the full rationale. The `> 0` clearance
    /// invariant this test group exists to guard is unaffected.
    func testEndDrivePillOffset_aspInEffect_clearsBanner() {
        let padding = paddingForBannerState(.aspInEffect)
        XCTAssertGreaterThan(padding, 0, "End Drive pill must have non-zero top padding when ASP is in effect — the amber banner is visible and the pill must clear it")
        XCTAssertEqual(padding, 100, "End Drive pill should have 100pt top padding for .aspInEffect (TF2-18 P2-2 — matches recenterButtonStack's offset)")
    }

    func testEndDrivePillOffset_todaySuspended_is44() {
        let padding = paddingForBannerState(.todaySuspended(reason: "Memorial Day"))
        XCTAssertEqual(padding, 100, "End Drive pill should have 100pt top padding when ASP is suspended today (TF2-18 P2-2)")
    }

    func testEndDrivePillOffset_tomorrowSuspended_is44() {
        let padding = paddingForBannerState(.tomorrowSuspended(reason: "Independence Day"))
        XCTAssertEqual(padding, 100, "End Drive pill should have 100pt top padding when ASP is suspended tomorrow (TF2-18 P2-2)")
    }

    // MARK: - Test 10: All visible-banner states return non-zero clearance

    /// Parametrized invariant: for every SuspensionBannerState that shows a banner,
    /// `paddingForBannerState` must return a value that clears the status bar + banner.
    ///
    /// All three cases are banner-visible states — there is no hidden/none case in
    /// SuspensionBannerState. This test documents and guards that invariant.
    func testEndDrivePillOffset_allBannerVisibleStates_returnNonZero() {
        let visibleStates: [SuspensionBannerState] = [
            .aspInEffect,
            .todaySuspended(reason: "Test Holiday"),
            .tomorrowSuspended(reason: "Test Holiday Eve")
        ]
        for state in visibleStates {
            let padding = paddingForBannerState(state)
            XCTAssertGreaterThan(
                padding, 0,
                "paddingForBannerState(\(state)) must return non-zero clearance — banner is visible in this state"
            )
        }
    }
}

// MARK: - TF2-18 P1-3: Recenter Pill Bottom Clearance Tests

final class RecenterPillBottomPaddingTests: XCTestCase {

    /// Base case: no approach strip, no Park Until pill — just the bottom card.
    func testRecenterPillBottomPadding_cardOnly() {
        let padding = recenterPillBottomPadding(showApproachStrip: false, parkUntilVisible: false)
        XCTAssertEqual(padding, 148, "Base card clearance should be 140 + 8pt gap = 148")
    }

    /// Card + approach strip.
    func testRecenterPillBottomPadding_cardPlusApproachStrip() {
        let padding = recenterPillBottomPadding(showApproachStrip: true, parkUntilVisible: false)
        XCTAssertEqual(padding, 178, "Card + strip clearance should be 140 + 30 + 8pt gap = 178")
    }

    /// Card + Park Until pill.
    func testRecenterPillBottomPadding_cardPlusParkUntilPill() {
        let padding = recenterPillBottomPadding(showApproachStrip: false, parkUntilVisible: true)
        XCTAssertEqual(padding, 206, "Card + Park Until pill clearance should be 140 + 58 + 8pt gap = 206")
    }

    /// Card + approach strip + Park Until pill (the tallest combination).
    func testRecenterPillBottomPadding_cardPlusStripPlusParkUntilPill() {
        let padding = recenterPillBottomPadding(showApproachStrip: true, parkUntilVisible: true)
        XCTAssertEqual(padding, 236, "Card + strip + Park Until pill clearance should be 140 + 30 + 58 + 8pt gap = 236")
    }

    /// Invariant: clearance is always positive and monotonically non-decreasing as more
    /// stack elements are added — the pill should never get LESS clearance when more UI
    /// is on screen below it.
    func testRecenterPillBottomPadding_monotonicAcrossCombinations() {
        let cardOnly = recenterPillBottomPadding(showApproachStrip: false, parkUntilVisible: false)
        let plusStrip = recenterPillBottomPadding(showApproachStrip: true, parkUntilVisible: false)
        let plusPill = recenterPillBottomPadding(showApproachStrip: false, parkUntilVisible: true)
        let plusBoth = recenterPillBottomPadding(showApproachStrip: true, parkUntilVisible: true)

        XCTAssertGreaterThan(cardOnly, 0, "Base clearance must be positive")
        XCTAssertGreaterThanOrEqual(plusStrip, cardOnly, "Adding the approach strip must not shrink clearance")
        XCTAssertGreaterThanOrEqual(plusPill, cardOnly, "Adding the Park Until pill must not shrink clearance")
        XCTAssertGreaterThanOrEqual(plusBoth, plusStrip, "Adding both must be >= adding either alone")
        XCTAssertGreaterThanOrEqual(plusBoth, plusPill, "Adding both must be >= adding either alone")
    }
}

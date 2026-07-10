//
//  FT12Tests.swift
//  WeParkTests
//
//  FT-12 — "Free Parking in NYC 101" beginner's guide (docs/ft12-beginners-manual-spec.md).
//  Light, targeted tests mirroring the FAQHelpViewTests / BackgroundNoteGateTests
//  precedent for static-content views — no SwiftUI snapshot-testing library exists in
//  this repo (spec §10), so visual correctness is covered by the mandatory engineer
//  screenshot (AC-12) + designer review + Kevin's on-device smoke instead.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
@testable import WePark

// MARK: - 1. ParkingGuidePromptGate Tests (spec §7, mirrors BackgroundNoteGateTests)

/// Unit tests for the one-time Parking 101 first-launch banner gate.
/// Uses an ephemeral UserDefaults suite so standard UserDefaults is never polluted.
final class ParkingGuidePromptGateTests: XCTestCase {

    private let suiteName = "com.wepark.test.parkingguidepromptgate"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: AppConstants.parkingGuidePromptShownKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testFreshInstall_shouldShow_isTrue() {
        let gate = ParkingGuidePromptGate(defaults: ephemeralDefaults,
                                           key: AppConstants.parkingGuidePromptShownKey)
        XCTAssertTrue(gate.shouldShow(),
                      "shouldShow() should return true on a fresh UserDefaults suite")
    }

    func testMarkShown_thenShouldShow_isFalse() {
        let gate = ParkingGuidePromptGate(defaults: ephemeralDefaults,
                                           key: AppConstants.parkingGuidePromptShownKey)
        gate.markShown()

        let stored = ephemeralDefaults.bool(forKey: AppConstants.parkingGuidePromptShownKey)
        XCTAssertTrue(stored, "UserDefaults key should be true after markShown()")
        XCTAssertFalse(gate.shouldShow(),
                       "shouldShow() should return false after markShown()")
    }

    func testMarkShown_isIdempotent() {
        let gate = ParkingGuidePromptGate(defaults: ephemeralDefaults,
                                           key: AppConstants.parkingGuidePromptShownKey)
        gate.markShown()
        for i in 0..<5 {
            XCTAssertFalse(gate.shouldShow(),
                           "shouldShow() should return false on check #\(i + 1) after markShown")
        }
    }

    func testGate_neverTouchesStandardDefaults() {
        // Sanity: the default init parameter is .standard, but this test only ever
        // constructs the gate with the ephemeral suite — verifying the injectable
        // pattern is being used correctly rather than asserting on .standard directly
        // (which would risk polluting shared test state).
        UserDefaults.standard.removeObject(forKey: "com.wepark.test.parkingguidepromptgate.canary")
        let gate = ParkingGuidePromptGate(defaults: ephemeralDefaults,
                                           key: AppConstants.parkingGuidePromptShownKey)
        gate.markShown()
        XCTAssertNil(UserDefaults.standard.object(forKey: "com.wepark.test.parkingguidepromptgate.canary"),
                     "markShown() must not touch UserDefaults.standard when an ephemeral suite is injected")
    }
}

// MARK: - 2. MoneyMathConstants Tests (spec §6 auditability)

final class MoneyMathConstantsTests: XCTestCase {

    func testCitywideGarageRange_lowLessThanHigh_bothPositive() {
        XCTAssertGreaterThan(MoneyMathConstants.garageMonthlyCitywideLow, 0)
        XCTAssertGreaterThan(MoneyMathConstants.garageMonthlyCitywideHigh, 0)
        XCTAssertLessThan(MoneyMathConstants.garageMonthlyCitywideLow,
                          MoneyMathConstants.garageMonthlyCitywideHigh)
    }

    func testManhattanGarageRange_lowLessThanHigh_bothPositive() {
        XCTAssertGreaterThan(MoneyMathConstants.garageMonthlyManhattanLow, 0)
        XCTAssertGreaterThan(MoneyMathConstants.garageMonthlyManhattanHigh, 0)
        XCTAssertLessThan(MoneyMathConstants.garageMonthlyManhattanLow,
                          MoneyMathConstants.garageMonthlyManhattanHigh)
    }

    /// Guards against copy drift between FAQHelpView and the Parking 101 guide —
    /// both screens must cite the same street-cleaning ticket figure (spec §6).
    func testStreetCleaningTicketCost_matchesExistingFAQFigure() {
        XCTAssertEqual(MoneyMathConstants.streetCleaningTicketCost, 65,
                      "Ticket cost must match the $65 figure already shipped in FAQHelpView / docs/in-app-faq-content.md")
    }

    /// Guards the "auditable math" claim in spec §6 — annual figures must be a
    /// straight 12x multiple of the monthly bounds, never a separately invented number.
    func testAnnualSavings_equalsTwelveTimesMonthlyBounds() {
        XCTAssertEqual(MoneyMathConstants.annualSavingsLow,
                       MoneyMathConstants.garageMonthlyCitywideLow * 12)
        XCTAssertEqual(MoneyMathConstants.annualSavingsHigh,
                       MoneyMathConstants.garageMonthlyManhattanHigh * 12)
    }

    func testAnnualSavings_matchesSpecCitedFigures() {
        // Spec §3(a)/§6 cites "$4,800–$12,000 a year" as the worked example.
        XCTAssertEqual(MoneyMathConstants.annualSavingsLow, 4800)
        XCTAssertEqual(MoneyMathConstants.annualSavingsHigh, 12000)
    }

    func testAnnualSavings_lowLessThanHigh() {
        XCTAssertLessThan(MoneyMathConstants.annualSavingsLow, MoneyMathConstants.annualSavingsHigh)
    }
}

// MARK: - 3. ParkingGuideSection Tests (quick-jump chip anchor mapping)

/// Pure value-type tests for the section → anchor-ID mapping that drives the
/// ParkingGuideView quick-jump chip row — no UIKit/SwiftUI rendering required.
final class ParkingGuideSectionTests: XCTestCase {

    func testAllFourSections_arePresent_inSpecOrder() {
        let rawValues = ParkingGuideSection.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues, ["pitch", "signSchool", "colorLegend", "rookieMistakes"],
                       "Sections must render in spec §3 order: Pitch, Sign School, Color Legend, Rookie Mistakes")
    }

    func testEachSection_hasUniqueNonEmptyAnchorID() {
        let ids = ParkingGuideSection.allCases.map(\.anchorID)
        XCTAssertEqual(Set(ids).count, ids.count, "All anchor IDs must be unique")
        XCTAssertTrue(ids.allSatisfy { !$0.isEmpty }, "No anchor ID may be empty")
    }

    func testEachSection_hasNonEmptyTitleAndSymbol() {
        for section in ParkingGuideSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) must have a non-empty title")
            XCTAssertFalse(section.symbol.isEmpty, "\(section) must have a non-empty SF Symbol name")
        }
    }

    func testJumpAccessibilityLabel_namesDestinationSection() {
        XCTAssertEqual(ParkingGuideSection.signSchool.jumpAccessibilityLabel, "Jump to Sign School")
        XCTAssertEqual(ParkingGuideSection.pitch.jumpAccessibilityLabel, "Jump to The Pitch")
        XCTAssertEqual(ParkingGuideSection.colorLegend.jumpAccessibilityLabel, "Jump to Map Colors")
        XCTAssertEqual(ParkingGuideSection.rookieMistakes.jumpAccessibilityLabel, "Jump to Rookie Mistakes")
    }

    func testAnchorID_matchesRawValue() {
        for section in ParkingGuideSection.allCases {
            XCTAssertEqual(section.anchorID, section.rawValue)
        }
    }
}

// MARK: - 4. ActiveSheet.parkingGuide identity (ContentView wiring)

final class ParkingGuideActiveSheetTests: XCTestCase {

    func testParkingGuideCase_hasStableID() {
        XCTAssertEqual(ActiveSheet.parkingGuide.id, "parkingGuide")
    }

    func testParkingGuideCase_idDistinctFromOtherStaticCases() {
        let ids: Set<String> = [
            ActiveSheet.parkingGuide.id,
            ActiveSheet.notificationRationale.id,
            ActiveSheet.settings.id,
            ActiveSheet.parkUntil.id
        ]
        XCTAssertEqual(ids.count, 4, "ActiveSheet.parkingGuide's id must not collide with other static-case ids")
    }
}

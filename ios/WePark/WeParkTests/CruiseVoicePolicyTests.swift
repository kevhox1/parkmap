//
//  CruiseVoicePolicyTests.swift
//  WeParkTests
//
//  CM-1: Unit tests for CruiseVoicePolicy pure functions.
//
//  Coverage (10 tests):
//
//  shouldAnnounce — decision table:
//    1. testShouldAnnounce_freeBothSides_returnsTrue
//    2. testShouldAnnounce_freeLeft_restrictedRight_returnsTrue
//    3. testShouldAnnounce_freeRight_unknownLeft_returnsTrue
//    4. testShouldAnnounce_meteredLeft_restrictedRight_returnsTrue
//    5. testShouldAnnounce_restrictedBothSides_returnsFalse
//    6. testShouldAnnounce_unknownBothSides_returnsFalse
//    7. testShouldAnnounce_restrictedLeft_unknownRight_returnsFalse
//
//  utteranceText phrasing:
//    8. testUtteranceText_freeOnLeft_saysFreeParkingOnLeft
//    9. testUtteranceText_freeBothSides_saysFreeParkingBothSides
//   10. testUtteranceText_meteredOnlyNeitherFree_saysMetered
//
//  No Calendar.current.
//  No import SwiftUI (pure service tests).
//  No framework dependencies — CruiseVoicePolicy has none.
//

import XCTest
@testable import WePark

final class CruiseVoicePolicyTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Builds a minimal `DrivingContext` for policy testing.
    /// The street/from/to values are not evaluated by `shouldAnnounce` or `utteranceText`'s
    /// announce gate — only severity matters for the decision, and street name for phrasing.
    private func makeContext(
        street: String = "W 34 ST",
        leftSeverity: SafetyLabel.Severity,
        rightSeverity: SafetyLabel.Severity
    ) -> DrivingContext {
        DrivingContext(
            street: street,
            from: "7 AVE",
            to: "8 AVE",
            leftLabel: SafetyLabel(text: labelText(for: leftSeverity), severity: leftSeverity),
            rightLabel: SafetyLabel(text: labelText(for: rightSeverity), severity: rightSeverity)
        )
    }

    private func labelText(for severity: SafetyLabel.Severity) -> String {
        switch severity {
        case .free:       return "Free until 9 AM"
        case .metered:    return "Metered"
        case .restricted: return "No parking"
        case .unknown:    return "No data"
        }
    }

    // MARK: - shouldAnnounce — decision table

    // Test 1: Both sides free → true.
    func testShouldAnnounce_freeBothSides_returnsTrue() {
        let ctx = makeContext(leftSeverity: .free, rightSeverity: .free)
        XCTAssertTrue(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Both sides free should return true"
        )
    }

    // Test 2: Left free, right restricted → true (at least one side is free).
    func testShouldAnnounce_freeLeft_restrictedRight_returnsTrue() {
        let ctx = makeContext(leftSeverity: .free, rightSeverity: .restricted)
        XCTAssertTrue(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Left free, right restricted should return true"
        )
    }

    // Test 3: Left unknown, right free → true.
    func testShouldAnnounce_freeRight_unknownLeft_returnsTrue() {
        let ctx = makeContext(leftSeverity: .unknown, rightSeverity: .free)
        XCTAssertTrue(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Left unknown, right free should return true"
        )
    }

    // Test 4: Left metered, right restricted → true (metered is an opportunity).
    func testShouldAnnounce_meteredLeft_restrictedRight_returnsTrue() {
        let ctx = makeContext(leftSeverity: .metered, rightSeverity: .restricted)
        XCTAssertTrue(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Left metered, right restricted should return true"
        )
    }

    // Test 5: Both restricted → false (no parking opportunity on either side).
    func testShouldAnnounce_restrictedBothSides_returnsFalse() {
        let ctx = makeContext(leftSeverity: .restricted, rightSeverity: .restricted)
        XCTAssertFalse(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Both restricted should return false"
        )
    }

    // Test 6: Both unknown → false (no data = no opportunity to announce).
    func testShouldAnnounce_unknownBothSides_returnsFalse() {
        let ctx = makeContext(leftSeverity: .unknown, rightSeverity: .unknown)
        XCTAssertFalse(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Both unknown should return false"
        )
    }

    // Test 7: Left restricted, right unknown → false.
    func testShouldAnnounce_restrictedLeft_unknownRight_returnsFalse() {
        let ctx = makeContext(leftSeverity: .restricted, rightSeverity: .unknown)
        XCTAssertFalse(
            CruiseVoicePolicy.shouldAnnounce(context: ctx),
            "Left restricted, right unknown should return false"
        )
    }

    // MARK: - utteranceText phrasing

    // Test 8: Only left side free → "Free parking on the left."
    func testUtteranceText_freeOnLeft_saysFreeParkingOnLeft() {
        let ctx = makeContext(street: "SPRING ST", leftSeverity: .free, rightSeverity: .restricted)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("Free parking on the left."),
            "Expected 'Free parking on the left.' in: \(text)"
        )
        // Must NOT use destination-mode phrasing "Left side, free until..."
        XCTAssertFalse(
            text.contains("Left side,"),
            "Cruise Mode phrasing should NOT use 'Left side,' format. Got: \(text)"
        )
        // Street name should be Title Case with abbreviation expansion.
        XCTAssertTrue(
            text.contains("Spring Street."),
            "Street abbreviation 'St' should expand to 'Street'. Got: \(text)"
        )
    }

    // Test 9: Both sides free → "Free parking on both sides."
    func testUtteranceText_freeBothSides_saysFreeParkingBothSides() {
        let ctx = makeContext(street: "W 34 ST", leftSeverity: .free, rightSeverity: .free)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("Free parking on both sides."),
            "Expected 'Free parking on both sides.' in: \(text)"
        )
    }

    // Test 10: Left metered, right metered, neither free → "Metered on both sides."
    func testUtteranceText_meteredOnlyNeitherFree_saysMetered() {
        let ctx = makeContext(leftSeverity: .metered, rightSeverity: .metered)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("Metered on both sides."),
            "Expected 'Metered on both sides.' in: \(text)"
        )
        XCTAssertFalse(
            text.contains("Free parking"),
            "Metered-only context should NOT mention 'Free parking'. Got: \(text)"
        )
    }

    // MARK: - minimumGapSeconds constant

    // Bonus: minimumGapSeconds matches FinalApproachService.baselineVoiceGapSeconds.
    func testMinimumGapSeconds_matchesBaseline() {
        XCTAssertEqual(
            CruiseVoicePolicy.minimumGapSeconds,
            FinalApproachService.baselineVoiceGapSeconds,
            "Cruise Mode minimum gap should match baseline voice gap seconds"
        )
    }
}

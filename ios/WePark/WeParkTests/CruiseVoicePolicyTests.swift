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

    // MARK: - utteranceText phrasing (TF2-7: updated to "sections" + "check signs" copy)

    // Test 8 (renamed): Only left side free → contains "sections on the left" + "check signs".
    // Pre-TF2-7 this said "Free parking on the left." — now the "sections" qualifier is mandated.
    func testUtteranceText_freeOnLeft_containsSectionsAndCheckSigns() {
        let ctx = makeContext(street: "SPRING ST", leftSeverity: .free, rightSeverity: .restricted)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("sections on the left"),
            "Expected 'sections on the left' in TF2-7 phrasing: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Expected 'check signs' in TF2-7 phrasing: \(text)"
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

    // Test 9 (renamed): Both sides free → contains "both sides" + "check signs".
    // Pre-TF2-7 this said "Free parking on both sides." — now "sections" + "check signs" required.
    func testUtteranceText_freeBothSides_containsSectionsAndCheckSigns() {
        let ctx = makeContext(street: "W 34 ST", leftSeverity: .free, rightSeverity: .free)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("both sides"),
            "Expected 'both sides' in: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Expected 'check signs' in both-sides free phrasing: \(text)"
        )
    }

    // Test 10: Left metered, right metered, neither free → "Metered on both sides."
    // Metered phrasing is unchanged by TF2-7 — no "sections", no "check signs".
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
        XCTAssertFalse(
            text.contains("sections"),
            "Metered-only phrasing should NOT contain 'sections'. Got: \(text)"
        )
        XCTAssertFalse(
            text.contains("check signs"),
            "Metered-only phrasing should NOT contain 'check signs'. Got: \(text)"
        )
    }

    // MARK: - TF2-7 additional phrasing tests

    // Test 11 (new): Right free only → contains "sections on the right" + "check signs"
    func testUtteranceText_freeRight_containsSectionsAndCheckSigns() {
        let ctx = makeContext(leftSeverity: .restricted, rightSeverity: .free)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("sections on the right"),
            "Right-free phrasing should contain 'sections on the right'. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Right-free phrasing should contain 'check signs'. Got: \(text)"
        )
    }

    // Test 12 (new): Left free + right metered → "sections on the left" (free side leads, spec §4.1)
    func testUtteranceText_freeLeftMeteredRight_usesFreeLead() {
        let ctx = makeContext(leftSeverity: .free, rightSeverity: .metered)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("sections on the left"),
            "Left-free + right-metered should lead with left-free phrasing. Got: \(text)"
        )
        XCTAssertTrue(
            text.contains("check signs"),
            "Left-free lead should include 'check signs'. Got: \(text)"
        )
        // The metered side is visible on the card chip; voice is the action cue only.
        XCTAssertFalse(
            text.contains("Metered"),
            "Left-free + right-metered phrasing should NOT mention 'Metered' in voice. Got: \(text)"
        )
    }

    // Test 13 (new): Left metered only (right restricted) → "Metered on the left."
    func testUtteranceText_meteredLeft_restricted_saysMeteredOnLeft() {
        let ctx = makeContext(leftSeverity: .metered, rightSeverity: .restricted)
        let text = CruiseVoicePolicy.utteranceText(for: ctx)
        XCTAssertTrue(
            text.contains("Metered on the left."),
            "Left-metered phrasing should say 'Metered on the left.' Got: \(text)"
        )
        XCTAssertFalse(
            text.contains("sections"),
            "Metered phrasing should NOT contain 'sections'. Got: \(text)"
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

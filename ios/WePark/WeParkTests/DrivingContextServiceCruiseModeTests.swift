//
//  DrivingContextServiceCruiseModeTests.swift
//  WeParkTests
//
//  CM-2: Unit tests for DrivingContextService cruise-mode extension.
//
//  Coverage (5 tests):
//    1. testCruiseMode_restrictedBlock_doesNotSpeak
//    2. testCruiseMode_freeBlock_speaks
//    3. testCruiseMode_freeBlock_usesCruisePhrasing
//    4. testDestinationMode_restrictedBlock_stillSpeaks
//    5. testCruiseMode_blockChange_respectsMinGap
//
//  All tests pass without a real device (pure unit — no live GPS, no AVFoundation).
//  MockDrivingVoice is defined in W85cTests.swift and accessible via @testable import.
//  Uses the same fixture helpers (w85cMakeSeg) defined in W85cTests.swift.
//
//  No Calendar.current.
//  No import SwiftUI (service tests must not import SwiftUI per QA invariant).
//

import XCTest
import CoreLocation
@testable import WePark

final class DrivingContextServiceCruiseModeTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var mockVoice: MockDrivingVoice!
    var service: DrivingContextService!

    // Fixed test date: Wednesday 8 AM ET — outside typical restrictions.
    // Avoids Calendar.current (QA invariant).
    private var testDate: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 7
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }

    // GPS anchor inside the segment fixture's line.
    private let anchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        mockVoice = MockDrivingVoice()
        service = DrivingContextService(voice: mockVoice)
    }

    override func tearDown() {
        service = nil
        mockVoice = nil
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Single-side N segment (restricted).
    private func makeRestrictedBlock() -> [Segment] {
        [w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST",
                     side: "N", category: .noParking,
                     lat: 40.750, lng: -73.980)]
    }

    /// Single-side N segment (free) + S segment (restricted).
    private func makeFreeLeftBlock() -> [Segment] {
        [
            w85cMakeSeg(street: "W 34 ST", from: "7 AVE", to: "8 AVE",
                        side: "N", category: .free,
                        lat: 40.750, lng: -73.980),
            w85cMakeSeg(street: "W 34 ST", from: "7 AVE", to: "8 AVE",
                        side: "S", category: .noParking,
                        lat: 40.750, lng: -73.980)
        ]
    }

    // MARK: - Test 1: Cruise Mode + restricted block → no speak.

    func testCruiseMode_restrictedBlock_doesNotSpeak() {
        service.setCruiseMode(true)
        let segs = makeRestrictedBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)
        XCTAssertEqual(
            mockVoice.speakCallCount, 0,
            "Cruise Mode should NOT speak on a restricted-only block"
        )
    }

    // MARK: - Test 2: Cruise Mode + free block → speaks.

    func testCruiseMode_freeBlock_speaks() {
        service.setCruiseMode(true)
        let segs = makeFreeLeftBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)
        XCTAssertGreaterThan(
            mockVoice.speakCallCount, 0,
            "Cruise Mode should speak when at least one side is free"
        )
    }

    // MARK: - Test 3: Cruise Mode + free block → uses "sections...check signs" phrasing (not "Left side,").
    // TF2-7: updated assertion from "Free parking" → "sections" + "check signs" (new mandated copy).

    func testCruiseMode_freeBlock_usesCruisePhrasing() {
        service.setCruiseMode(true)
        let segs = makeFreeLeftBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)

        let spokenText = mockVoice.spokenTexts.first ?? ""
        XCTAssertTrue(
            spokenText.contains("sections"),
            "TF2-7 Cruise Mode phrasing should contain 'sections'. Got: \(spokenText)"
        )
        XCTAssertTrue(
            spokenText.contains("check signs"),
            "TF2-7 Cruise Mode phrasing should contain 'check signs'. Got: \(spokenText)"
        )
        XCTAssertFalse(
            spokenText.contains("Left side,"),
            "Cruise Mode should NOT use destination-mode 'Left side,' format. Got: \(spokenText)"
        )
    }

    // MARK: - Test 4: Destination Mode + one-restricted-one-unknown → silent (TF2-7 spec §4.3).
    // Pre-TF2-7 this asserted speakCallCount == 1 (destination mode announced every block).
    // TF2-7 spec §4.3: "If only one side is restricted (the other is unknown): no voice
    // (same as Cruise Mode)." The makeRestrictedBlock() fixture has N=restricted, right=unknown.
    // Updated to assert silence for this case; see testDestinationMode_bothRestricted_speaks()
    // for the both-restricted case that DOES announce.

    func testDestinationMode_restrictedBlock_stillSpeaks() {
        // Default is destination mode (isCruiseMode = false).
        // One side restricted (N), other side unknown (no data).
        // TF2-7 §4.3: one restricted + one unknown → no voice.
        let segs = makeRestrictedBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)
        XCTAssertEqual(
            mockVoice.speakCallCount, 0,
            "TF2-7: Destination Mode should NOT speak when only one side restricted and other is unknown (spec §4.3)"
        )
    }

    // MARK: - Test 4b: Destination Mode + both restricted → speaks "No parking on either side."
    //
    // Heading 90 (east) is used so N maps unambiguously to left (dLeft=0, dRight=180)
    // and S maps to right (dRight=0, dLeft=180). With heading 0 (north), both N and S
    // produce dLeft==dRight==90, so both map to "left" — rightCardinalSide stays nil,
    // buildUtteranceText sees restricted+unknown and returns "" (silent). Heading 90
    // separates the sides correctly and triggers the both-restricted path.

    func testDestinationMode_bothRestricted_speaks() {
        // Two-sided restricted block, heading east so N=left, S=right.
        let segs = [
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST",
                        side: "N", category: .noParking, lat: 40.750, lng: -73.980),
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST",
                        side: "S", category: .noParking, lat: 40.750, lng: -73.980)
        ]
        // heading: 90 (east) → N is on the left (90° CCW from east), S is on the right.
        service.update(coordinate: anchor, heading: 90, segments: segs, engine: engine, date: testDate)
        XCTAssertGreaterThan(
            mockVoice.speakCallCount, 0,
            "TF2-7: Destination Mode should speak when both sides are restricted (spec §4.3)"
        )
        let spokenText = mockVoice.spokenTexts.first ?? ""
        XCTAssertTrue(
            spokenText.contains("No parking on either side."),
            "TF2-7: Both-restricted destination phrasing should be 'No parking on either side.' Got: \(spokenText)"
        )
    }

    // MARK: - Test 4c: TF2-7 QA Finding #1 — heading-0 tie-break assigns BOTH sides.

    /// Regression lock for the due-north tie-break: at heading 0 with N/S-labeled sides,
    /// dLeft == dRight for both sides; the old `<=` tie-break sent BOTH to "left", leaving
    /// the right side unassigned ("—"). The signed-angle tiebreaker must assign the two
    /// opposite sides to OPPOSITE relative sides, so both-restricted still speaks
    /// "No parking on either side." (it was silent before the fix — right side .unknown).
    func testDestinationMode_headingZeroTieBreak_bothSidesAssigned() {
        let segs = [
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST",
                        side: "N", category: .noParking, lat: 40.750, lng: -73.980),
            w85cMakeSeg(street: "5 AVE", from: "34 ST", to: "35 ST",
                        side: "S", category: .noParking, lat: 40.750, lng: -73.980)
        ]
        // heading: 0 (due north) — the exact-tie case. Both sides must be assigned
        // (one left, one right), so the both-restricted utterance fires.
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)
        XCTAssertGreaterThan(
            mockVoice.speakCallCount, 0,
            "TF2-7 QA #1: heading-0 must assign both sides (was: right side stuck at unknown → silent)"
        )
        XCTAssertTrue(
            (mockVoice.spokenTexts.first ?? "").contains("No parking on either side."),
            "TF2-7 QA #1: both-restricted phrasing must fire at heading 0"
        )
    }

    // MARK: - Test 5: Cruise Mode + two rapid block changes → second is gated by min gap.

    func testCruiseMode_blockChange_respectsMinGap() {
        // The service's voiceMinGapSeconds = 12s (FinalApproachService.baselineVoiceGapSeconds).
        // Two block changes at time 0 and "immediately after": the second must not produce
        // a second voice cue within the same test run (which takes << 12s).
        service.setCruiseMode(true)

        let segsA = makeFreeLeftBlock()
        let segsB = [
            w85cMakeSeg(street: "BROADWAY", from: "34 ST", to: "35 ST",
                        side: "N", category: .free, lat: 40.752, lng: -73.982)
        ]

        // First block — should speak (both voiceMinGapSeconds and policy pass).
        service.update(coordinate: anchor, heading: 0, segments: segsA, engine: engine, date: testDate)
        let countAfterFirst = mockVoice.speakCallCount

        // Second block immediately — voiceMinGapSeconds (12s) has not elapsed.
        // The block key changed (street changed), so policy is re-evaluated.
        // The min-gap guard should suppress the second announcement.
        let coordB = CLLocationCoordinate2D(latitude: 40.752, longitude: -73.982)
        service.update(coordinate: coordB, heading: 0, segments: segsB, engine: engine, date: testDate)

        // After the second call we should have at most 1 speak — the same as after the first.
        // (The first call may or may not have triggered speak depending on timing; what matters
        // is the second did NOT add another one in the same test run.)
        XCTAssertEqual(
            mockVoice.speakCallCount, countAfterFirst,
            "Second block change within 12s should be suppressed by voiceMinGapSeconds"
        )
    }
}

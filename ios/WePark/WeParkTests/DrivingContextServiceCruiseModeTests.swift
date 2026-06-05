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

    // MARK: - Test 3: Cruise Mode + free block → uses "Free parking" phrasing (not "Left side,").

    func testCruiseMode_freeBlock_usesCruisePhrasing() {
        service.setCruiseMode(true)
        let segs = makeFreeLeftBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)

        let spokenText = mockVoice.spokenTexts.first ?? ""
        XCTAssertTrue(
            spokenText.contains("Free parking"),
            "Cruise Mode phrasing should lead with 'Free parking'. Got: \(spokenText)"
        )
        XCTAssertFalse(
            spokenText.contains("Left side,"),
            "Cruise Mode should NOT use destination-mode 'Left side,' format. Got: \(spokenText)"
        )
    }

    // MARK: - Test 4: Destination Mode + restricted block → still speaks (regression guard).

    func testDestinationMode_restrictedBlock_stillSpeaks() {
        // Default is destination mode (isCruiseMode = false).
        // setCruiseMode is NOT called here — verifying the pre-CM-2 behavior is preserved.
        let segs = makeRestrictedBlock()
        service.update(coordinate: anchor, heading: 0, segments: segs, engine: engine, date: testDate)
        XCTAssertEqual(
            mockVoice.speakCallCount, 1,
            "Destination Mode should speak on every block change, including restricted blocks"
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

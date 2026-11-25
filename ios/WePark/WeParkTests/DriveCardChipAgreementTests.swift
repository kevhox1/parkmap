//
//  DriveCardChipAgreementTests.swift
//  WeParkTests
//
//  Build 27 smoke finding 12 (owner, East 2nd / East 1st St, Overnight goal): both drive-card
//  chips went RED while their text read "Free until Monday/Friday ..." and the map's curb
//  lines were green. Root cause: `goalAwareChipSeverity` made EVERY segment on the side vote,
//  but the tile data carries clipped NO STANDING anytime stubs (hydrants, crosswalks, bus
//  stops) on almost every block side. Those stubs fail any window, yet the chip's text
//  (`aggregateSideDetail`) is about the free, car-length-or-longer stretch. The color now
//  judges that same subject set.
//
//  These tests pin chip color to the overlay's own decision (`engine.isFree`, the same call
//  `ContentView.rebuildOverlays` makes) for the segment the chip text describes.
//
//  Reference week: Wed 2026-01-07 08:00 ET; Overnight window = [now, Fri 2026-01-09 00:00).
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - Fixtures (file-private, uniquely named)

private func dcaSegment(
    side: String,
    rules: [ParkingRule],
    lengthLatDelta: Double = 0.0001,   // ~11 m: above the 6 m subject threshold
    id: String = UUID().uuidString
) -> Segment {
    Segment(
        id: id,
        street: "E 2 ST",
        fromStreet: "AVE B",
        to: "AVE A",
        side: side,
        line: [[40.7260, -73.9840], [40.7260 + lengthLatDelta, -73.9840]],
        rules: rules,
        dominantCategory: rules.first?.category
    )
}

private func dcaRule(
    _ category: WePark.Category,
    days: [Int] = [],
    timeRanges: [TimeRange] = [],
    anytime: Bool = false
) -> ParkingRule {
    ParkingRule(category: category, description: "", days: days, timeRanges: timeRanges, anytime: anytime, arrow: nil)
}

private func dcaWedMorning() -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 7
    comps.hour = 8; comps.minute = 0; comps.second = 0
    comps.timeZone = TimeZone(identifier: "America/New_York")
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

final class DriveCardChipAgreementTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private let now = dcaWedMorning()
    private var overnightTarget: Date { now.startOfDayET(offsetDays: 2) }

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func chip(_ segments: [Segment]) -> SafetyLabel.Severity? {
        DrivingContextService.goalAwareChipSeverity(
            sideSegments: segments,
            parkUntilMode: true,
            target: overnightTarget,
            ignoringMeteredPayment: true,
            from: now,
            engine: engine
        )
    }

    /// The overlay's own decision for one segment, collapsed to the same two buckets.
    private func overlayColor(_ segment: Segment) -> SafetyLabel.Severity {
        engine.isFree(segment: segment, from: now, until: overnightTarget, ignoringMeteredPayment: true)
            ? .free : .restricted
    }

    // The bug: a long free stretch plus a NO STANDING anytime stub. Text is about the free
    // stretch; the chip must be green exactly like the map's line for that stretch.
    func testNoStandingStubDoesNotVetoFreeStretch() {
        // Tue/Fri sweeps fall outside Wed 8am to Fri 0:00, so this stretch clears the window.
        let freeOutside = dcaSegment(side: "N", rules: [dcaRule(.aspTueFri, days: [2, 5])])
        let stub = dcaSegment(side: "N", rules: [dcaRule(.noStanding, anytime: true)])
        XCTAssertEqual(overlayColor(freeOutside), .free)
        XCTAssertEqual(overlayColor(stub), .restricted, "the stub itself is red on the map")
        XCTAssertEqual(chip([stub, freeOutside]), overlayColor(freeOutside),
                       "chip color must equal the overlay color of the curb the text describes")
        XCTAssertEqual(chip([stub, freeOutside]), .free)
    }

    // A genuinely failing free-now stretch still turns the chip red, and agrees with the map.
    func testFailingFreeStretchStillRed_agreesWithOverlay() {
        let failing = dcaSegment(side: "N", rules: [dcaRule(.aspMonThu, days: [1, 4])])
        let stub = dcaSegment(side: "N", rules: [dcaRule(.noStanding, anytime: true)])
        XCTAssertEqual(overlayColor(failing), .restricted)
        XCTAssertEqual(chip([failing, stub]), .restricted)
    }

    // Order of segments must not matter.
    func testChipIndependentOfSegmentOrder() {
        let ok = dcaSegment(side: "S", rules: [dcaRule(.aspTueFri, days: [2, 5])])
        let stub = dcaSegment(side: "S", rules: [dcaRule(.noStanding, anytime: true)])
        XCTAssertEqual(chip([ok, stub]), chip([stub, ok]))
    }

    // A side with only restricted-now segments has no free subject: falls back to the long
    // segments, which fail, so red (nothing to describe as free).
    func testOnlyRestrictedSegments_red() {
        let a = dcaSegment(side: "N", rules: [dcaRule(.noStanding, anytime: true)])
        XCTAssertEqual(chip([a]), .restricted)
    }

    // Segments under 6 m never decide the color when a longer segment exists.
    func testShortSegmentIgnoredWhenLongExists() {
        // Amended (no-sign-data fix): empty rules are unknown/not-free; use a FREE-category rule.
        let long = dcaSegment(side: "N", rules: [dcaRule(.free)])
        let tiny = dcaSegment(side: "N", rules: [dcaRule(.aspMonThu, days: [1, 4])], lengthLatDelta: 0.00001)
        XCTAssertLessThan(DrivingContextService.segmentLengthMeters(tiny), 6.0)
        XCTAssertEqual(chip([long, tiny]), .free)
    }

    // End to end through update(): both sides carry a stub, text says free, chips green.
    func testUpdate_stubOnBothSides_chipsGreenLikeTheMap() {
        let segments = [
            dcaSegment(side: "N", rules: [dcaRule(.aspTueFri, days: [2, 5])]),
            dcaSegment(side: "N", rules: [dcaRule(.noStanding, anytime: true)]),
            dcaSegment(side: "S", rules: [dcaRule(.aspTueFri, days: [2, 5])]),
            dcaSegment(side: "S", rules: [dcaRule(.noStanding, anytime: true)])
        ]
        let service = DrivingContextService(voice: MockDrivingVoice())
        service.update(
            coordinate: CLLocationCoordinate2D(latitude: 40.72605, longitude: -73.9840),
            heading: 90.0,
            segments: segments,
            engine: engine,
            date: now,
            parkUntilMode: true,
            parkUntilTarget: overnightTarget,
            parkUntilIgnoresMeteredPayment: true
        )
        let ctx = service.currentContext
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.leftLabel.severity, .free)
        XCTAssertEqual(ctx?.rightLabel.severity, .free)
        XCTAssertEqual(ctx?.leftChipColorOverride, .free)
        XCTAssertEqual(ctx?.rightChipColorOverride, .free)
    }
}

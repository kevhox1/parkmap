//
//  DriveSidesAndIdleHeadingTests.swift
//  WeParkTests
//
//  1. Drive-card LEFT/RIGHT follow the driver's travel direction (build-27 finding 8):
//     `DriveSideAssignment`, `DriveSideTravel`, and the `DrivingContextService` wiring.
//  2. Idle heading hold (build-27 finding 10): `DriveHeadingHold` and its wiring through
//     `LocationService.stabilizedHeading` with synthetic fix sequences.
//
//  Helper names are prefixed `sidesTest` (file-private) to avoid cross-file shadowing.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers

private let sidesTestAnchor = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980)

/// Segment whose polyline runs from the anchor to `(dLat, dLng)` away, ~25 m long.
private func sidesTestSeg(
    side: String,
    category: WePark.Category = .free,
    dLat: Double,
    dLng: Double,
    oneway: Bool? = nil,
    onewayToward: String? = nil,
    street: String = "SIDES TEST ST",
    fromStreet: String = "A",
    to: String = "B"
) -> Segment {
    let rule = ParkingRule(
        category: category, description: "t", days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: [], anytime: true, arrow: nil
    )
    return Segment(
        id: UUID().uuidString, street: street, fromStreet: fromStreet, to: to, side: side,
        line: [[sidesTestAnchor.latitude, sidesTestAnchor.longitude],
               [sidesTestAnchor.latitude + dLat, sidesTestAnchor.longitude + dLng]],
        rules: [rule], dominantCategory: category,
        oneway: oneway, onewayToward: onewayToward
    )
}

/// East-west street (polyline runs due east).
private func sidesTestEastWest(side: String, oneway: Bool? = nil, onewayToward: String? = nil) -> Segment {
    sidesTestSeg(side: side, dLat: 0, dLng: 0.0003, oneway: oneway, onewayToward: onewayToward)
}

/// North-south street (polyline runs due north).
private func sidesTestNorthSouth(side: String) -> Segment {
    sidesTestSeg(side: side, dLat: 0.00022, dLng: 0)
}

// MARK: - 1a. Pure assignment

final class DriveSideAssignmentTests: XCTestCase {

    private func assign(_ sides: [String], _ bearing: Double) -> (left: String?, right: String?) {
        DriveSideAssignment.assign(sides: sides, travelBearing: bearing)
    }

    func testEastWestStreet_eastbound_northIsLeft_southIsRight() {
        let r = assign(["N", "S"], 90)
        XCTAssertEqual(r.left, "N")
        XCTAssertEqual(r.right, "S")
    }

    func testEastWestStreet_westbound_northIsRight_southIsLeft() {
        // The reported bug: westbound, "LEFT" used to be the N curb (driver's right).
        let r = assign(["N", "S"], 270)
        XCTAssertEqual(r.left, "S")
        XCTAssertEqual(r.right, "N")
    }

    func testNorthSouthStreet_northbound_westIsLeft_eastIsRight() {
        let r = assign(["E", "W"], 0)
        XCTAssertEqual(r.left, "W")
        XCTAssertEqual(r.right, "E")
    }

    func testNorthSouthStreet_southbound_eastIsLeft_westIsRight() {
        let r = assign(["E", "W"], 180)
        XCTAssertEqual(r.left, "E")
        XCTAssertEqual(r.right, "W")
    }

    func testDiagonalBroadwayStyle_northeastBound() {
        // Broadway-style: runs ~NNE/SSW. Curbs labelled E/W.
        let up = assign(["E", "W"], 30)
        XCTAssertEqual(up.left, "W")
        XCTAssertEqual(up.right, "E")
        let down = assign(["E", "W"], 210)
        XCTAssertEqual(down.left, "E")
        XCTAssertEqual(down.right, "W")
    }

    func testDiagonalStreetLabelledNorthSouth() {
        let ne = assign(["N", "S"], 45)
        XCTAssertEqual(ne.left, "N")
        XCTAssertEqual(ne.right, "S")
        let sw = assign(["N", "S"], 225)
        XCTAssertEqual(sw.left, "S")
        XCTAssertEqual(sw.right, "N")
    }

    func testMixedCardinalSidesStillFillBothSlots() {
        // Old first-match loop could leave a slot "—" here; both must be filled and distinct.
        let r = assign(["N", "E"], 45)
        XCTAssertNotNil(r.left)
        XCTAssertNotNil(r.right)
        XCTAssertNotEqual(r.left, r.right)
    }

    func testTwoOppositeSidesAlwaysFillBothSlots_allHeadings() {
        for pair in [["N", "S"], ["E", "W"]] {
            for h in stride(from: 0.0, to: 360.0, by: 5.0) {
                let r = assign(pair, h)
                XCTAssertNotNil(r.left, "left blank for \(pair) at \(h)")
                XCTAssertNotNil(r.right, "right blank for \(pair) at \(h)")
                XCTAssertNotEqual(r.left, r.right)
            }
        }
    }

    func testSingleSide_assignedBySign_otherSlotNil() {
        let r = assign(["N"], 90)  // eastbound: N is left
        XCTAssertEqual(r.left, "N")
        XCTAssertNil(r.right)
        let w = assign(["N"], 270)
        XCTAssertNil(w.left)
        XCTAssertEqual(w.right, "N")
    }

    func testCardinalFallback_isNWLeft_SERight() {
        let r = DriveSideAssignment.cardinalFallback(sides: ["S", "N"])
        XCTAssertEqual(r.left, "N")
        XCTAssertEqual(r.right, "S")
    }
}

// MARK: - 1b. Travel resolution (polyline direction, one-way, preserve-last)

final class DriveSideTravelTests: XCTestCase {

    func testTwoWay_headingPicksPolylineDirection() {
        var travel = DriveSideTravel()
        let seg = sidesTestEastWest(side: "N")
        let east = travel.resolve(heading: 80, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(east ?? -1, 90, accuracy: 1.0)
        let west = travel.resolve(heading: 280, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(west ?? -1, 270, accuracy: 1.0)
    }

    /// Both curbs of an east-west street tagged one-way eastbound ("to").
    private func trueOneWayEast() -> [Segment] {
        [sidesTestEastWest(side: "N", oneway: true, onewayToward: "to"),
         sidesTestEastWest(side: "S", oneway: true, onewayToward: "to")]
    }

    func testTrueOneWay_headingNoiseWithin90_usesLegalDirection() {
        var travel = DriveSideTravel()
        let sibs = trueOneWayEast()
        // Reliable heading 80 deg off-street-axis noise: legal east wins.
        let a = travel.resolve(heading: 10, segment: sibs[0], siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(a ?? -1, 90, accuracy: 1.0)
        let b = travel.resolve(heading: 170, segment: sibs[0], siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(b ?? -1, 90, accuracy: 1.0)
        let unknown = travel.resolve(heading: nil, segment: sibs[0], siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(unknown ?? -1, 90, accuracy: 1.0)
    }

    func testTrueOneWay_wrongWay_followsHeading() {
        var travel = DriveSideTravel()
        let sibs = trueOneWayEast()
        let r = travel.resolve(heading: 270, segment: sibs[0], siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(r ?? -1, 270, accuracy: 1.0, "wrong-way travel must swap the chips")
        let swapped = DriveSideAssignment.assign(sides: ["N", "S"], travelBearing: r ?? 0)
        XCTAssertEqual(swapped.left, "S")
        XCTAssertEqual(swapped.right, "N")
    }

    /// Bowery-style: N-S two-way street whose W curb is tagged southbound and E curb northbound.
    private func perCurbOneWayNorthSouth() -> [Segment] {
        [sidesTestSeg(side: "W", dLat: 0.00022, dLng: 0, oneway: true, onewayToward: "from"),
         sidesTestSeg(side: "E", dLat: 0.00022, dLng: 0, oneway: true, onewayToward: "to")]
    }

    func testPerCurbOneWayTags_followHeading_bothDirectionsBothCurbs() {
        let sibs = perCurbOneWayNorthSouth()
        for matched in sibs {
            var north = DriveSideTravel()
            let n = north.resolve(heading: 5, segment: matched, siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
            XCTAssertEqual(n ?? -1, 0, accuracy: 1.0, "northbound near \(matched.side) curb")
            let nSides = DriveSideAssignment.assign(sides: ["W", "E"], travelBearing: n ?? 0)
            XCTAssertEqual(nSides.left, "W")
            XCTAssertEqual(nSides.right, "E")

            var south = DriveSideTravel()
            let sBearing = south.resolve(heading: 185, segment: matched, siblings: sibs, blockKey: "k", coordinate: sidesTestAnchor)
            XCTAssertEqual(sBearing ?? -1, 180, accuracy: 1.0, "southbound near \(matched.side) curb")
            let sSides = DriveSideAssignment.assign(sides: ["W", "E"], travelBearing: sBearing ?? 0)
            XCTAssertEqual(sSides.left, "E")
            XCTAssertEqual(sSides.right, "W")
        }
    }

    func testSingleCurbOneWayTag_isNotTrustedAsWholeStreet() {
        var travel = DriveSideTravel()
        let only = sidesTestEastWest(side: "N", oneway: true, onewayToward: "to")
        let r = travel.resolve(heading: 270, segment: only, siblings: [only], blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(r ?? -1, 270, accuracy: 1.0)
    }

    func testCanonicalBlockKey_isOrderIndependent() {
        XCTAssertEqual(
            DriveSideAssignment.canonicalBlockKey(street: "E 14TH ST", from: "2ND AVE", to: "3RD AVE"),
            DriveSideAssignment.canonicalBlockKey(street: "E 14TH ST", from: "3RD AVE", to: "2ND AVE")
        )
        XCTAssertNotEqual(
            DriveSideAssignment.canonicalBlockKey(street: "E 14TH ST", from: "2ND AVE", to: "3RD AVE"),
            DriveSideAssignment.canonicalBlockKey(street: "E 14TH ST", from: "2ND AVE", to: "4TH AVE")
        )
    }

    func testUnknownHeading_keepsLastKnownDirection() {
        var travel = DriveSideTravel()
        let seg = sidesTestEastWest(side: "N")
        _ = travel.resolve(heading: 270, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        let held = travel.resolve(heading: nil, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(held ?? -1, 270, accuracy: 1.0, "nil heading must keep westbound, not flip or blank")
    }

    func testUnknownHeading_carriesAcrossBlocks() {
        var travel = DriveSideTravel()
        let seg = sidesTestEastWest(side: "N")
        _ = travel.resolve(heading: 270, segment: seg, siblings: [seg], blockKey: "k1", coordinate: sidesTestAnchor)
        let next = travel.resolve(heading: nil, segment: seg, siblings: [seg], blockKey: "k2", coordinate: sidesTestAnchor)
        XCTAssertEqual(next ?? -1, 270, accuracy: 1.0)
    }

    func testNeverAnyHeading_returnsNil_soCallerUsesCardinalFallback() {
        var travel = DriveSideTravel()
        let seg = sidesTestEastWest(side: "N")
        XCTAssertNil(travel.resolve(heading: nil, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor))
    }

    func testPerpendicularHeadingMidTurn_keepsPreviousDirectionOnSameBlock() {
        var travel = DriveSideTravel()
        let seg = sidesTestEastWest(side: "N")
        _ = travel.resolve(heading: 270, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        let mid = travel.resolve(heading: 0, segment: seg, siblings: [seg], blockKey: "k", coordinate: sidesTestAnchor)
        XCTAssertEqual(mid ?? -1, 270, accuracy: 1.0, "sides must not flip while heading is crossing the street")
    }
}

// MARK: - 1c. DrivingContextService wiring

final class DriveSidesServiceTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private var service: DrivingContextService!

    private var testDate: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 7
        comps.hour = 8
        comps.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        service = DrivingContextService(voice: MockDrivingVoice())
    }

    override func tearDown() {
        service = nil
        engine = nil
        super.tearDown()
    }

    /// North curb free, south curb no parking, on an east-west street.
    private var eastWestBlock: [Segment] {
        [
            sidesTestSeg(side: "N", category: .free, dLat: 0, dLng: 0.0003),
            sidesTestSeg(side: "S", category: .noParking, dLat: 0, dLng: 0.0003),
        ]
    }

    private func update(heading: Double?, segments: [Segment]) {
        service.update(
            coordinate: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.9799),
            heading: heading, segments: segments, engine: engine, date: testDate
        )
    }

    func testEastbound_leftIsNorth_free() {
        update(heading: 90, segments: eastWestBlock)
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .free)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .restricted)
    }

    func testWestbound_leftIsSouth_restricted() {
        update(heading: 270, segments: eastWestBlock)
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .restricted)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .free)
    }

    func testVoicePhraseUsesSameMapping() {
        update(heading: 270, segments: eastWestBlock)
        guard let ctx = service.currentContext else { return XCTFail("no context") }
        // Westbound: free N curb is on the driver's RIGHT.
        XCTAssertTrue(service.buildUtteranceText(ctx).contains("on the right"))
        update(heading: 90, segments: eastWestBlock)
        guard let ctx2 = service.currentContext else { return XCTFail("no context") }
        XCTAssertTrue(service.buildUtteranceText(ctx2).contains("on the left"))
    }

    func testStationaryUnknownHeading_preservesLastAssignment() {
        update(heading: 270, segments: eastWestBlock)
        let before = service.currentContext
        update(heading: nil, segments: eastWestBlock)  // stationary / unreliable heading
        XCTAssertEqual(service.currentContext?.leftLabel.severity, before?.leftLabel.severity)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, before?.rightLabel.severity)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .free)
    }

    func testNorthSouthStreet_northbound_eastCurbIsRight() {
        let segs = [
            sidesTestSeg(side: "E", category: .free, dLat: 0.00022, dLng: 0),
            sidesTestSeg(side: "W", category: .noParking, dLat: 0.00022, dLng: 0),
        ]
        service.update(
            coordinate: CLLocationCoordinate2D(latitude: 40.7501, longitude: -73.980),
            heading: 0, segments: segs, engine: engine, date: testDate
        )
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .free)
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .restricted)
    }
}

// MARK: - 1d. Reversed from/to labels across the two curbs (finding 8 blank side)

final class DriveSidesReversedLabelTests: XCTestCase {

    private var engine: ParkingRulesEngine!
    private var service: DrivingContextService!

    private var testDate: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 7
        comps.hour = 8
        comps.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }

    override func setUp() {
        super.setUp()
        engine = ParkingRulesEngine()
        service = DrivingContextService(voice: MockDrivingVoice())
    }

    override func tearDown() {
        service = nil
        engine = nil
        super.tearDown()
    }

    func testReversedLabelCurbs_bothSidesPresent() {
        let segs = [
            sidesTestSeg(side: "N", category: .free, dLat: 0, dLng: 0.0003, fromStreet: "2ND AVE", to: "3RD AVE"),
            sidesTestSeg(side: "S", category: .noParking, dLat: 0, dLng: 0.0003, fromStreet: "3RD AVE", to: "2ND AVE"),
        ]
        service.update(
            coordinate: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.9799),
            heading: 90, segments: segs, engine: engine, date: testDate
        )
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .free)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .restricted)
    }

    /// Real tile block: BROADWAY between WEST 101ST STREET and WEST 102ND STREET
    /// (tiles/, ids BROADWAY_WEST_101ST_STREET_WEST_102ND_STREET_E_0 and
    /// BROADWAY_WEST_102ND_STREET_WEST_101ST_STREET_W_0). The E curb lists 101ST to 102ND,
    /// the W curb 102ND to 101ST. The E curb is tagged one-way "from" and the W curb "to",
    /// which point OPPOSITE ways geographically (a per-curb tag on a two-way street).
    private func realBroadway() -> [Segment] {
        let rule = { (c: WePark.Category) in
            ParkingRule(category: c, description: "t", days: [0, 1, 2, 3, 4, 5, 6],
                        timeRanges: [], anytime: true, arrow: nil)
        }
        let east = Segment(
            id: "BROADWAY_WEST_101ST_STREET_WEST_102ND_STREET_E_0", street: "BROADWAY",
            fromStreet: "WEST 101ST STREET", to: "WEST 102ND STREET", side: "E",
            line: [[40.798397, -73.969057], [40.798225, -73.96918]],
            rules: [rule(.free)], dominantCategory: .free, oneway: true, onewayToward: "from"
        )
        let west = Segment(
            id: "BROADWAY_WEST_102ND_STREET_WEST_101ST_STREET_W_0", street: "BROADWAY",
            fromStreet: "WEST 102ND STREET", to: "WEST 101ST STREET", side: "W",
            line: [[40.798482, -73.969266], [40.798301, -73.969395]],
            rules: [rule(.noParking)], dominantCategory: .noParking, oneway: true, onewayToward: "to"
        )
        return [east, west]
    }

    func testRealBroadwayBlock_bothCurbsFoundAndSidesFollowHeading() {
        let segs = realBroadway()
        // Near the W curb, heading roughly SSW (street axis ~208 deg): W curb is on the right.
        let nearWest = CLLocationCoordinate2D(latitude: 40.79839, longitude: -73.96933)
        service.update(coordinate: nearWest, heading: 208, segments: segs, engine: engine, date: testDate)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .restricted)
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .free, "E curb must not be blank")
        // Heading NNE (28 deg) near the same curb: W curb is on the LEFT (per-curb tag ignored).
        service.update(coordinate: nearWest, heading: 28, segments: segs, engine: engine, date: testDate)
        XCTAssertEqual(service.currentContext?.leftLabel.severity, .restricted)
        XCTAssertEqual(service.currentContext?.rightLabel.severity, .free)
    }
}

// MARK: - 2a. Pure idle hold

final class DriveHeadingHoldTests: XCTestCase {

    private let stopped = 0.5

    private func coord(metersNorth: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 40.750 + metersNorth / 111_320.0, longitude: -73.980)
    }

    func testMovingFixes_neverHeld() {
        var hold = DriveHeadingHold()
        for i in 0..<5 {
            XCTAssertFalse(hold.shouldHold(speed: 8, coordinate: coord(metersNorth: Double(i) * 8), stoppedBelowSpeed: stopped))
        }
        XCTAssertFalse(hold.isHeld)
    }

    func testStopEngagesHold_andPhantomSpeedDoesNotRelease() {
        var hold = DriveHeadingHold()
        XCTAssertTrue(hold.shouldHold(speed: 0, coordinate: coord(metersNorth: 0), stoppedBelowSpeed: stopped))
        for _ in 0..<30 {
            // GPS phantom speed 0.6-1.4 m/s with a few meters of jitter.
            XCTAssertTrue(hold.shouldHold(speed: 1.4, coordinate: coord(metersNorth: 3), stoppedBelowSpeed: stopped))
        }
        XCTAssertTrue(hold.isHeld)
    }

    func testSingleSpeedSpikeDoesNotRelease_butTwoSustainedFixesDo() {
        var hold = DriveHeadingHold()
        _ = hold.shouldHold(speed: 0, coordinate: coord(metersNorth: 0), stoppedBelowSpeed: stopped)
        XCTAssertTrue(hold.shouldHold(speed: 5, coordinate: coord(metersNorth: 1), stoppedBelowSpeed: stopped))
        XCTAssertTrue(hold.shouldHold(speed: 0.8, coordinate: coord(metersNorth: 1), stoppedBelowSpeed: stopped),
                      "a slow fix resets the streak")
        XCTAssertTrue(hold.shouldHold(speed: 5, coordinate: coord(metersNorth: 2), stoppedBelowSpeed: stopped))
        XCTAssertFalse(hold.shouldHold(speed: 5, coordinate: coord(metersNorth: 3), stoppedBelowSpeed: stopped))
        XCTAssertFalse(hold.isHeld)
    }

    func testSlowCreepReleasesByDistance() {
        var hold = DriveHeadingHold()
        _ = hold.shouldHold(speed: 0, coordinate: coord(metersNorth: 0), stoppedBelowSpeed: stopped)
        XCTAssertTrue(hold.shouldHold(speed: 1.0, coordinate: coord(metersNorth: 9), stoppedBelowSpeed: stopped))
        XCTAssertFalse(hold.shouldHold(speed: 1.0, coordinate: coord(metersNorth: 10.5), stoppedBelowSpeed: stopped))
    }
}

// MARK: - 2b. Hold wired through LocationService.stabilizedHeading

final class IdleHeadingHoldIntegrationTests: XCTestCase {

    private func coord(metersNorth: Double, metersEast: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 40.750 + metersNorth / 111_320.0,
            longitude: -73.980 + metersEast / (111_320.0 * cos(40.75 * .pi / 180))
        )
    }

    /// Drives north at 10 m/s for 10 s; returns the service and the last position (meters north).
    private func driveNorth() -> (LocationService, Double) {
        let service = LocationService()
        var north = 0.0
        for _ in 0..<10 {
            north += 10
            _ = service.stabilizedHeading(rawHeading: 0, speed: 10, current: coord(metersNorth: north), courseAccuracy: 5)
        }
        return (service, north)
    }

    func testStopFor60Seconds_withNoisyCourseAndCompass_doesNotRotate() {
        let (service, north) = driveNorth()
        let good = service.driveHeading
        XCTAssertEqual(good ?? -1, 0, accuracy: 0.5)

        // 60 one-second fixes at a standstill: speed noise 0-1.4 m/s, wild course (including
        // nil), up to 3 m position jitter, and compass-path calls interleaved (speed < gate).
        for i in 0..<60 {
            let speed = [0.0, 0.0, 0.6, 1.4, 0.9, 0.0][i % 6]
            let course: Double? = (i % 5 == 0) ? nil : Double((i * 73) % 360)
            let jitter = Double((i * 7) % 4)  // 0...3 m
            _ = service.stabilizedHeading(
                rawHeading: course, speed: speed,
                current: coord(metersNorth: north + jitter, metersEast: jitter), courseAccuracy: 20
            )
            _ = service.stabilizedHeading(
                rawHeading: Double((i * 131) % 360), speed: 0,
                current: coord(metersNorth: north + jitter)
            )
            XCTAssertEqual(service.driveHeading ?? -1, 0, accuracy: 0.001, "rotated at idle fix \(i)")
        }
        XCTAssertTrue(service.driveHeadingHeld)
    }

    func testResumeAfterStop_recoversDirectionPromptly() {
        let (service, north) = driveNorth()
        for _ in 0..<30 {
            _ = service.stabilizedHeading(rawHeading: 200, speed: 0, current: coord(metersNorth: north))
        }
        XCTAssertTrue(service.driveHeadingHeld)

        // Pull away heading east (90 deg turn; below the flip threshold so it blends).
        var east = 0.0
        var last: Double?
        for _ in 0..<8 {
            east += 8
            last = service.stabilizedHeading(
                rawHeading: 90, speed: 8, current: coord(metersNorth: north, metersEast: east), courseAccuracy: 5
            )
        }
        XCTAssertFalse(service.driveHeadingHeld, "hold must release after sustained speed")
        XCTAssertEqual(last ?? -1, 90, accuracy: 15, "heading must converge on the new direction within ~8 fixes")
    }

    func testUTurnRightAfterResume_goesThroughExistingFlipGuard() {
        let (service, north) = driveNorth()
        for _ in 0..<10 {
            _ = service.stabilizedHeading(rawHeading: 0, speed: 0, current: coord(metersNorth: north))
        }
        // Resume heading the opposite way (south). Two fast fixes release the hold; the flip
        // guard then needs flipConfirmFixes (2) agreeing fixes to adopt 180.
        var south = north
        var last: Double?
        for _ in 0..<5 {
            south -= 8
            last = service.stabilizedHeading(rawHeading: 180, speed: 8, current: coord(metersNorth: south), courseAccuracy: 5)
        }
        XCTAssertEqual(last ?? -1, 180, accuracy: 1.0)
    }
}


// MARK: - 2c. Displayed heading frozen while held (PR #182 QA blocker)

final class DisplayedHeadingHoldTests: XCTestCase {

    func testDisplayedHeading_frozenWhileHeld_regardlessOfCandidateSource() {
        XCTAssertEqual(DriveHeadingHold.displayedHeading(held: true, candidate: 83.7, previousDisplayed: 119.4) ?? -1, 119.4, accuracy: 0.0001)
        XCTAssertEqual(DriveHeadingHold.displayedHeading(held: false, candidate: 83.7, previousDisplayed: 119.4) ?? -1, 83.7, accuracy: 0.0001)
        XCTAssertEqual(DriveHeadingHold.displayedHeading(held: true, candidate: 83.7, previousDisplayed: nil) ?? -1, 83.7, accuracy: 0.0001)
        XCTAssertNil(DriveHeadingHold.displayedHeading(held: true, candidate: nil, previousDisplayed: nil))
    }

    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    /// Mirrors QA's repro: arrive eastbound where the street-snapped bearing (119.4) differs
    /// from the raw course EMA (~84), then alternate two fixes ~4 m apart with sim-like speed 0
    /// and a stale course. The DISPLAYED bearing (what camera + puck use) must stay within 3.
    func testQAJitterScript_displayedHeadingStaysWithin3Degrees() {
        let service = LocationService()
        let snapped = 119.4
        let a = CLLocationCoordinate2D(latitude: 40.73257, longitude: -73.98515)
        let b = CLLocationCoordinate2D(latitude: 40.73260, longitude: -73.98512)
        var displayed: Double? = nil
        var minSeen = Double.infinity, maxSeen = -Double.infinity

        // Driving in: street-snap source shows the snapped bearing.
        var lng = -73.98700
        for _ in 0..<8 {
            lng += 0.00002
            _ = service.stabilizedHeading(rawHeading: 84, speed: 10,
                                          current: CLLocationCoordinate2D(latitude: 40.73250, longitude: lng),
                                          courseAccuracy: 5)
            displayed = DriveHeadingHold.displayedHeading(
                held: service.driveHeadingHeld, candidate: snapped, previousDisplayed: displayed)
        }
        XCTAssertEqual(displayed ?? -1, snapped, accuracy: 0.001)

        // Jitter 60 s, one fix per second alternating positions, some with a stale course.
        for i in 0..<60 {
            let pos = (i / 5) % 2 == 0 ? a : b
            _ = service.stabilizedHeading(rawHeading: i % 3 == 0 ? 84 : nil, speed: 0, current: pos, courseAccuracy: 5)
            // Hold-time source selection flips candidate between raw EMA and snapped.
            let candidate = i % 2 == 0 ? (service.driveHeading ?? snapped) : snapped
            displayed = DriveHeadingHold.displayedHeading(
                held: service.driveHeadingHeld, candidate: candidate, previousDisplayed: displayed)
            if let d = displayed { minSeen = min(minSeen, d); maxSeen = max(maxSeen, d) }
            XCTAssertLessThanOrEqual(angleDelta(displayed ?? 0, snapped), 3.0, "rotated at fix \(i)")
        }
        XCTAssertTrue(service.driveHeadingHeld)
        XCTAssertLessThanOrEqual(maxSeen - minSeen, 3.0)
    }
}

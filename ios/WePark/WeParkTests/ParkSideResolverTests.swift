//
//  ParkSideResolverTests.swift
//  WeParkTests
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1): the park-side resolver. Geometry is
//  authored in local metres (x = east, y = north) through `CurbSnapTestFixtures.coordinate`, so
//  "12 m apart" really is 12 m. A `rotationDegrees` parameter turns a whole fixture street (the
//  Manhattan angled grid) without changing what is right or left of the direction of travel.
//
//  Everything lives in uniquely named enums / this class: NO `extension XCTestCase` (compile
//  failure class 4), pure statics are `nonisolated` (class 5), `WePark.Category` is never needed
//  here (class 6).
//

import XCTest
import CoreLocation
@testable import WePark

/// Fixtures for the park-side tests.
enum ParkSideTestFixtures {

    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Rotates local (x, y) metres counter-clockwise by `degrees`.
    static func rotated(_ x: Double, _ y: Double, degrees: Double) -> (Double, Double) {
        let radians = degrees * Double.pi / 180
        return (x * cos(radians) - y * sin(radians), x * sin(radians) + y * cos(radians))
    }

    static func coordinate(x: Double, y: Double, rotation: Double = 0) -> CLLocationCoordinate2D {
        let p = rotated(x, y, degrees: rotation)
        return CurbSnapTestFixtures.coordinate(x: p.0, y: p.1)
    }

    /// A straight curb along the street axis at lateral offset `y`, x in [-100, 100].
    static func curb(
        id: String, side: String, y: Double, oneway: Bool?, rotation: Double = 0,
        street: String = "STANTON STREET"
    ) -> Segment {
        let points = [(-100.0, y), (100.0, y)].map { point -> [Double] in
            let c = coordinate(x: point.0, y: point.1, rotation: rotation)
            return [c.latitude, c.longitude]
        }
        return Segment(
            id: id, street: street, fromStreet: "ESSEX STREET", to: "NORFOLK STREET", side: side,
            line: points, rules: [], dominantCategory: nil, oneway: oneway
        )
    }

    /// Two curbs 12 m apart: south at y = 0, north at y = 12.
    static func pair(oneway: Bool?, rotation: Double = 0) -> [Segment] {
        [
            curb(id: "S", side: "S", y: 0, oneway: oneway, rotation: rotation),
            curb(id: "N", side: "N", y: 12, oneway: oneway, rotation: rotation),
        ]
    }

    /// A fix at local (x, y) with the given accuracy, `ageSeconds` before `now`.
    static func fix(
        x: Double, y: Double, rotation: Double = 0, accuracy: Double?, speed: Double = 0,
        course: Double? = nil, courseAccuracy: Double? = nil, ageSeconds: Double = 0
    ) -> ParkTrackFix {
        ParkTrackFix(
            coordinate: coordinate(x: x, y: y, rotation: rotation),
            course: course, courseAccuracy: courseAccuracy, speed: speed,
            horizontalAccuracy: accuracy,
            timestamp: now.addingTimeInterval(-ageSeconds)
        )
    }

    /// An approach along the street axis ending at x = 0: `count` fixes 6 m apart at 6 m/s, the last
    /// one `lastAge` seconds before `now`. `eastbound` flips the direction and the bearing. Returns
    /// fixes oldest first. `bearingOffset` skews the courses (turning / misaligned approach).
    static func approach(
        eastbound: Bool, y: Double, rotation: Double = 0, count: Int = 4, lastAge: Double = 1,
        bearingOffsets: [Double]? = nil
    ) -> [ParkTrackFix] {
        let baseBearing = (eastbound ? 90.0 : 270.0) - rotation
        return (0..<count).map { index in
            let stepsBack = count - index   // oldest first
            let x = eastbound ? -6.0 * Double(stepsBack) : 6.0 * Double(stepsBack)
            let offset = bearingOffsets.map { $0[index % $0.count] } ?? 0
            return fix(
                x: x, y: y, rotation: rotation, accuracy: 6, speed: 6,
                course: baseBearing + offset, courseAccuracy: 5,
                ageSeconds: lastAge + Double(stepsBack - 1)
            )
        }
    }
}

final class ParkSideResolverTests: XCTestCase {

    private typealias F = ParkSideTestFixtures

    private func decide(
        _ fix: ParkTrackFix, track: [ParkTrackFix] = [], segments: [Segment], now: Date = F.now
    ) -> ParkSideDecision {
        ParkSideResolver.decide(fix: fix, track: track, segments: segments, now: now)
    }

    // MARK: Stanton replay (the DT35-2 bug)

    func testStanton_biasedFix_asks_andNeverPicksNorth() {
        // Car on the south curb; the 12 m accurate fix is biased 5 m north, so nearest-GPS (the old
        // behaviour) would pick the north curb.
        let segments = F.pair(oneway: true)
        let decision = decide(F.fix(x: 0, y: 5, accuracy: 12), segments: segments)
        guard case .ask(let choice) = decision else {
            return XCTFail("expected .ask, got \(decision)")
        }
        XCTAssertEqual(Set([choice.first.segment.id, choice.second.segment.id]), ["S", "N"])
        XCTAssertEqual(choice.reason, .tooCloseToCall)
        if case .confident(let pick) = decision { XCTAssertNotEqual(pick.segment.id, "N") }
    }

    func testStanton_accurateFixOnSouthCurb_isConfidentGeometry() {
        let decision = decide(F.fix(x: 0, y: 0.5, accuracy: 4), segments: F.pair(oneway: true))
        guard case .confident(let pick) = decision else {
            return XCTFail("expected .confident, got \(decision)")
        }
        XCTAssertEqual(pick.segment.id, "S")
        XCTAssertEqual(pick.basis, .geometry)
    }

    func testTieIsNeverBrokenByNearestGPS() {
        // 0.5 m closer to the south curb with a 12 m fix: still a coin flip, so the answer is ask.
        for y in [5.0, 5.5, 6.0, 6.5, 7.0] {
            let decision = decide(F.fix(x: 0, y: y, accuracy: 12), segments: F.pair(oneway: true))
            guard case .ask = decision else { return XCTFail("y=\(y): expected .ask, got \(decision)") }
        }
    }

    // MARK: Two-way heading vote

    func testTwoWay_eastbound_midGap_picksSouthPulledRight() {
        for rotation in [0.0, 29.0] {
            let segments = F.pair(oneway: false, rotation: rotation)
            let track = F.approach(eastbound: true, y: 6, rotation: rotation)
            let stop = F.fix(x: 0, y: 6, rotation: rotation, accuracy: 6, speed: 0)
            guard case .confident(let pick) = decide(stop, track: track, segments: segments) else {
                return XCTFail("rotation \(rotation): expected .confident")
            }
            XCTAssertEqual(pick.segment.id, "S", "eastbound: right-hand curb is the south one (rotation \(rotation))")
            XCTAssertEqual(pick.basis, .pulledRight)
        }
    }

    func testTwoWay_westbound_midGap_picksNorth() {
        for rotation in [0.0, 29.0] {
            let segments = F.pair(oneway: false, rotation: rotation)
            let track = F.approach(eastbound: false, y: 6, rotation: rotation)
            let stop = F.fix(x: 0, y: 6, rotation: rotation, accuracy: 6, speed: 0)
            guard case .confident(let pick) = decide(stop, track: track, segments: segments) else {
                return XCTFail("rotation \(rotation): expected .confident")
            }
            XCTAssertEqual(pick.segment.id, "N", "westbound: right-hand curb is the north one (rotation \(rotation))")
            XCTAssertEqual(pick.basis, .pulledRight)
        }
    }

    func testTwoWay_geometryDecisiveForLeftCurb_headingSaysRight_asks() {
        // Eastbound: right is south. The accurate fix sits on the NORTH (left) curb.
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 11)
        let stop = F.fix(x: 0, y: 11.5, accuracy: 4, speed: 0)
        guard case .ask(let choice) = decide(stop, track: track, segments: segments) else {
            return XCTFail("expected .ask when the signals disagree")
        }
        XCTAssertEqual(choice.reason, .signalsDisagree)
    }

    func testTwoWay_geometryAndHeadingAgree_isGeometryAndHeading() {
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 1)
        let stop = F.fix(x: 0, y: 0.5, accuracy: 4, speed: 0)
        guard case .confident(let pick) = decide(stop, track: track, segments: segments) else {
            return XCTFail("expected .confident")
        }
        XCTAssertEqual(pick.segment.id, "S")
        XCTAssertEqual(pick.basis, .geometryAndHeading)
    }

    func testTurningApproach_castsNoHeadingVote() {
        // Courses swing 40 degrees: spread over 25, so no vote, so (mid-gap) ask.
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 6, bearingOffsets: [-40, 0, 40, 0])
        let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)
        guard case .ask = decide(stop, track: track, segments: segments) else {
            return XCTFail("a turning approach must not vote")
        }
    }

    func testApproachNotAlignedWithStreet_castsNoHeadingVote() {
        // Driving north into an east-west street: not within 30 degrees of the axis.
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 6, bearingOffsets: [-90])
        let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)
        guard case .ask = decide(stop, track: track, segments: segments) else {
            return XCTFail("a misaligned approach must not vote")
        }
    }

    func testOneWayAndUnknownDirection_castNoHeadingVote() {
        for oneway in [true, nil] as [Bool?] {
            let segments = F.pair(oneway: oneway)
            let track = F.approach(eastbound: true, y: 6)
            let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)
            guard case .ask = decide(stop, track: track, segments: segments) else {
                return XCTFail("oneway=\(String(describing: oneway)): expected .ask")
            }
        }
    }

    func testStaleApproach_isRejected() {
        let segments = F.pair(oneway: false)
        let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)

        // Too far away (all moving fixes 100 m+ from the stop).
        let far = (0..<4).map { index in
            F.fix(x: -150 - Double(index) * 6, y: 6, accuracy: 6, speed: 6, course: 90, courseAccuracy: 5,
                  ageSeconds: Double(4 - index))
        }
        guard case .ask = decide(stop, track: far, segments: segments) else {
            return XCTFail("an approach more than 60 m from the stop must not vote")
        }

        // Too old (200 s before the stop).
        let old = F.approach(eastbound: true, y: 6, lastAge: 200)
        guard case .ask = decide(stop, track: old, segments: segments) else {
            return XCTFail("an approach older than 120 s must not vote")
        }
    }

    func testPoorCourseAccuracy_castsNoHeadingVote() {
        let segments = F.pair(oneway: false)
        let track = F.approach(eastbound: true, y: 6).map { fix in
            ParkTrackFix(
                coordinate: fix.coordinate, course: fix.course, courseAccuracy: 60, speed: fix.speed,
                horizontalAccuracy: fix.horizontalAccuracy, timestamp: fix.timestamp
            )
        }
        let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)
        guard case .ask = decide(stop, track: track, segments: segments) else {
            return XCTFail("course accuracy over 30 degrees must not vote")
        }
    }

    // MARK: Weak fix, no curb, only curb

    func testWeakFix_accuracyAndAge() {
        let segments = F.pair(oneway: true)
        XCTAssertEqual(decide(F.fix(x: 0, y: 0, accuracy: 80), segments: segments), .weakFix)
        XCTAssertEqual(decide(F.fix(x: 0, y: 0, accuracy: nil), segments: segments), .weakFix)
        XCTAssertEqual(
            decide(F.fix(x: 0, y: 0, accuracy: 5, ageSeconds: 15), segments: segments), .weakFix
        )
        // Right at the bars is still usable.
        guard case .confident = decide(F.fix(x: 0, y: 0, accuracy: 5, ageSeconds: 9), segments: segments) else {
            return XCTFail("a 9 s old, 5 m fix is usable")
        }
    }

    func testNoCurb_whenNothingWithin35m() {
        XCTAssertEqual(decide(F.fix(x: 0, y: 200, accuracy: 5), segments: F.pair(oneway: true)), .noCurb)
    }

    func testOnlyCurb_whenNoOppositeSideInData() {
        let segments = [F.curb(id: "S", side: "S", y: 0, oneway: true)]
        guard case .onlyCurb(let pick) = decide(F.fix(x: 0, y: 1, accuracy: 5), segments: segments) else {
            return XCTFail("expected .onlyCurb")
        }
        XCTAssertEqual(pick.segment.id, "S")
        XCTAssertEqual(pick.basis, .onlyCurb)
    }

    // MARK: Stationary averaging

    func testStationaryAveraging_resolvesWhatOneFixCannot() {
        let segments = F.pair(oneway: true)
        // Six stopped fixes alternating 3 m either side of the south curb: mean on the curb, but the
        // latest fix alone (+3 m) is too close to call.
        let track = (0..<6).map { index in
            F.fix(x: 0, y: index % 2 == 0 ? -3 : 3, accuracy: 5, speed: 0, ageSeconds: Double(5 - index))
        }
        let latest = track[track.count - 1]
        guard case .confident(let pick) = decide(latest, track: track, segments: segments) else {
            return XCTFail("the averaged position sits on the south curb")
        }
        XCTAssertEqual(pick.segment.id, "S")
        guard case .ask = decide(latest, track: [], segments: segments) else {
            return XCTFail("the single +3 m fix alone is a coin flip")
        }
    }

    func testMovingLatestFix_isNotAveraged() {
        let (position, _) = ParkSideResolver.stoppedPosition(
            fix: F.fix(x: 10, y: 0, accuracy: 5, speed: 5),
            track: [F.fix(x: 0, y: 0, accuracy: 5, speed: 0, ageSeconds: 3)]
        )
        let expected = F.coordinate(x: 10, y: 0)
        XCTAssertEqual(position.longitude, expected.longitude, accuracy: 1e-9)
    }

    // MARK: Approach bearing / hand / switching

    func testApproachBearing_circularMeanAcrossNorth() {
        let stop = F.coordinate(x: 0, y: 0)
        let fixes = [350.0, 10.0].enumerated().map { index, course in
            F.fix(x: -6 * Double(2 - index), y: 0, accuracy: 5, speed: 5, course: course, courseAccuracy: 5,
                  ageSeconds: Double(2 - index))
        }
        let last = fixes[fixes.count - 1]
        guard let bearing = ParkSideResolver.approachBearing(fix: last, track: fixes, stop: stop) else {
            return XCTFail("expected a bearing")
        }
        let wrapped = min(bearing, 360 - bearing)
        XCTAssertEqual(wrapped, 0, accuracy: 1)
    }

    func testHand_isRelativeToTravelNotCompassLetters() {
        let segments = F.pair(oneway: true, rotation: 29)
        let position = F.coordinate(x: 0, y: 6, rotation: 29)
        guard let southSnap = CandidateSegmentSearch.nearestPointOnPolyline(from: position, polyline: segments[0].coordinates),
              let northSnap = CandidateSegmentSearch.nearestPointOnPolyline(from: position, polyline: segments[1].coordinates)
        else { return XCTFail("projection failed") }
        let south = ParkSideOption(segment: segments[0], coordinate: southSnap.coordinate, fraction: southSnap.fraction)
        let north = ParkSideOption(segment: segments[1], coordinate: northSnap.coordinate, fraction: northSnap.fraction)
        let eastish = 90.0 - 29.0
        XCTAssertEqual(ParkSideResolver.hand(of: south, versus: north, travelBearing: eastish), .right)
        XCTAssertEqual(ParkSideResolver.hand(of: north, versus: south, travelBearing: eastish), .left)
        XCTAssertEqual(ParkSideResolver.hand(of: south, versus: north, travelBearing: eastish + 180), .left)
    }

    func testSwitched_projectsOntoOppositeCurbAtSamePosition() {
        let segments = F.pair(oneway: true)
        guard let snap = CandidateSegmentSearch.nearestPointOnPolyline(
            from: F.coordinate(x: 40, y: 0), polyline: segments[0].coordinates
        ) else { return XCTFail("projection failed") }
        let south = ParkSideOption(segment: segments[0], coordinate: snap.coordinate, fraction: snap.fraction)
        guard let north = ParkSideResolver.switched(from: south, in: segments) else {
            return XCTFail("expected an opposite curb")
        }
        XCTAssertEqual(north.segment.id, "N")
        XCTAssertEqual(north.coordinate.longitude, south.coordinate.longitude, accuracy: 1e-7)
        XCTAssertGreaterThan(north.coordinate.latitude, south.coordinate.latitude)
        XCTAssertEqual(north.fraction, south.fraction, accuracy: 0.001)
        XCTAssertNil(ParkSideResolver.switched(from: south, in: [segments[0]]))
    }

    func testAsk_retainsApproachCourseForRightLeftWording() {
        let segments = F.pair(oneway: true)
        let track = F.approach(eastbound: true, y: 6)
        let stop = F.fix(x: 0, y: 6, accuracy: 6, speed: 0)
        guard case .ask(let choice) = decide(stop, track: track, segments: segments),
              let bearing = choice.travelBearing else {
            return XCTFail("expected an ask that kept the approach course")
        }
        XCTAssertEqual(bearing, 90, accuracy: 1)
    }
}

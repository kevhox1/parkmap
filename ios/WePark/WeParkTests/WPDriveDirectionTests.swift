//
//  WPDriveDirectionTests.swift
//  WeParkTests
//
//  DT35-5: direction-of-travel label ("Eastbound") and its speed gate.
//  Helper names are prefixed `dirTest` (file-private) to avoid cross-file shadowing.
//

import XCTest
import CoreLocation
@testable import WePark

private let dirTestAnchor = CLLocationCoordinate2D(latitude: 40.725, longitude: -73.985)

/// Segment whose polyline runs from the anchor along compass `bearing` (~30 m).
private func dirTestSeg(side: String, lineBearing: Double, street: String = "DIR TEST ST") -> Segment {
    let b = lineBearing * .pi / 180
    let k = 0.00027
    let dLat = cos(b) * k
    let dLng = sin(b) * k / cos(dirTestAnchor.latitude * .pi / 180)
    let rule = ParkingRule(
        category: .free, description: "t", days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: [], anytime: true, arrow: nil
    )
    return Segment(
        id: UUID().uuidString, street: street, fromStreet: "A", to: "B", side: side,
        line: [[dirTestAnchor.latitude, dirTestAnchor.longitude],
               [dirTestAnchor.latitude + dLat, dirTestAnchor.longitude + dLng]],
        rules: [rule], dominantCategory: .free
    )
}

private func dirTestLabel(
    _ seg: Segment?, heading: Double?, moving: Bool = true, held: Bool = false, accuracy: Double? = nil
) -> String? {
    WPDriveDirection.label(
        segment: seg, coordinate: dirTestAnchor, heading: heading,
        moving: moving, headingHeld: held, courseAccuracy: accuracy
    )
}

final class WPDriveDirectionTests: XCTestCase {

    // MARK: Axis derivation

    func testStantonSidesNS_eastAndWest() {
        let stanton = dirTestSeg(side: "N", lineBearing: 100)
        XCTAssertEqual(dirTestLabel(stanton, heading: 100), "Eastbound")
        XCTAssertEqual(dirTestLabel(stanton, heading: 280), "Westbound")
        let southCurb = dirTestSeg(side: "S", lineBearing: 280)   // line digitised the other way
        XCTAssertEqual(dirTestLabel(southCurb, heading: 100), "Eastbound")
        XCTAssertEqual(dirTestLabel(southCurb, heading: 280), "Westbound")
    }

    func testSecondAveSidesEW_northAndSouth_toleratesGridTilt() {
        let ave = dirTestSeg(side: "E", lineBearing: 29)
        XCTAssertEqual(dirTestLabel(ave, heading: 25), "Northbound")
        XCTAssertEqual(dirTestLabel(ave, heading: 205), "Southbound")
        XCTAssertEqual(dirTestLabel(ave, heading: 5), "Northbound")
        XCTAssertEqual(dirTestLabel(ave, heading: 55), "Northbound")
        XCTAssertEqual(dirTestLabel(ave, heading: 185), "Southbound")
        let reversed = dirTestSeg(side: "W", lineBearing: 209)
        XCTAssertEqual(dirTestLabel(reversed, heading: 25), "Northbound")
    }

    func testManhattanCrosstownAt119_readsEastWest() {
        let street = dirTestSeg(side: "N", lineBearing: 119)
        XCTAssertEqual(dirTestLabel(street, heading: 119), "Eastbound")
        XCTAssertEqual(dirTestLabel(street, heading: 299), "Westbound")
    }

    func testRotationSweepNeverContradictsSideAxis() {
        for lineBearing in stride(from: 0.0, to: 360.0, by: 5.0) {
            for side in ["N", "S", "E", "W"] {
                let seg = dirTestSeg(side: side, lineBearing: lineBearing)
                for heading in stride(from: 0.0, to: 360.0, by: 3.0) {
                    guard let text = dirTestLabel(seg, heading: heading) else { continue }
                    if side == "N" || side == "S" {
                        XCTAssertTrue(text == "Eastbound" || text == "Westbound",
                                      "side \(side) line \(lineBearing) heading \(heading): \(text)")
                    } else {
                        XCTAssertTrue(text == "Northbound" || text == "Southbound",
                                      "side \(side) line \(lineBearing) heading \(heading): \(text)")
                    }
                }
            }
        }
    }

    // MARK: Diagonals

    func testBroadwayDiagonalReturnsNil() {
        for side in ["N", "S", "E", "W"] {
            for line in [40.0, 45, 50, 130, 135, 140, 220, 315] {
                let broadway = dirTestSeg(side: side, lineBearing: line, street: "BROADWAY")
                XCTAssertNil(dirTestLabel(broadway, heading: line), "side \(side) line \(line)")
                XCTAssertNil(dirTestLabel(broadway, heading: line + 180), "side \(side) line \(line)")
            }
        }
    }

    func testSideLetterDisagreeingWithGeometryReturnsNil() {
        // N/S curb letters on a street that runs north-south (letters wrong for the geometry).
        XCTAssertNil(dirTestLabel(dirTestSeg(side: "N", lineBearing: 5), heading: 5))
        XCTAssertNil(dirTestLabel(dirTestSeg(side: "E", lineBearing: 95), heading: 95))
    }

    func testUnknownSideLetterReturnsNil() {
        XCTAssertNil(dirTestLabel(dirTestSeg(side: "X", lineBearing: 90), heading: 90))
    }

    // MARK: Gates in the label

    func testNotMovingHeldAndNoDataGiveNil() {
        let seg = dirTestSeg(side: "N", lineBearing: 100)
        XCTAssertNil(dirTestLabel(seg, heading: 100, moving: false))
        XCTAssertNil(dirTestLabel(seg, heading: 100, held: true))
        XCTAssertNil(dirTestLabel(seg, heading: nil))
        XCTAssertNil(dirTestLabel(nil, heading: 100))
        XCTAssertNil(dirTestLabel(seg, heading: 100, accuracy: 45))
        XCTAssertEqual(dirTestLabel(seg, heading: 100, accuracy: 30), "Eastbound")
    }

    func testSnappedHeadingEqualToStreetBearingWithHeldIsNil() {
        // The street-snapped heading is only used while the course is held or low-confidence;
        // feeding it with headingHeld == true must never produce a claim.
        let seg = dirTestSeg(side: "N", lineBearing: 100)
        XCTAssertNil(dirTestLabel(seg, heading: 100, held: true))
    }

    func testMidTurnReturnsNil() {
        let seg = dirTestSeg(side: "N", lineBearing: 100)
        XCTAssertNil(dirTestLabel(seg, heading: 100 + 80))   // 80 deg off the axis
        XCTAssertNil(dirTestLabel(seg, heading: 100 - 90))
        XCTAssertEqual(dirTestLabel(seg, heading: 100 + 55), "Eastbound")
    }

    func testWrongWayOneWayReportsActualMovement() {
        let seg = dirTestSeg(side: "N", lineBearing: 100)
        XCTAssertEqual(dirTestLabel(seg, heading: 280), "Westbound")
    }

    // MARK: Text

    func testPillAndAccessibilityText() {
        XCTAssertEqual(WPDriveDirection.pillText(street: "Stanton St", direction: "Eastbound"), "Stanton St \u{00B7} Eastbound")
        XCTAssertEqual(WPDriveDirection.pillText(street: "Stanton St", direction: nil), "Stanton St")
        XCTAssertEqual(WPDriveDirection.accessibilityText(street: "Stanton St", direction: "Eastbound"), "Street: Stanton St, eastbound")
        XCTAssertEqual(WPDriveDirection.accessibilityText(street: "Stanton St", direction: nil), "Street: Stanton St")
    }

    // MARK: Speed gate

    func testGateOpensOnlyAtTwoMetersPerSecond() {
        var gate = WPDriveDirectionGate()
        XCTAssertFalse(gate.update(speed: 1.9, now: 0))
        XCTAssertFalse(gate.update(speed: 1.5, now: 1))
        XCTAssertTrue(gate.update(speed: 2.0, now: 2))
    }

    func testGateClosesOnlyAfterThreeSecondsBelowOne() {
        var gate = WPDriveDirectionGate()
        gate.update(speed: 6, now: 0)
        XCTAssertTrue(gate.update(speed: 0.5, now: 10))
        XCTAssertTrue(gate.update(speed: 0.5, now: 12.9))
        XCTAssertFalse(gate.update(speed: 0.5, now: 13.0))
    }

    func testGateHysteresisBandHoldsAndResetsTheTimer() {
        var gate = WPDriveDirectionGate()
        gate.update(speed: 6, now: 0)
        gate.update(speed: 0.5, now: 10)
        XCTAssertTrue(gate.update(speed: 1.5, now: 11))   // band: unchanged, timer cleared
        XCTAssertNil(gate.slowSince)
        XCTAssertTrue(gate.update(speed: 0.5, now: 12))   // new slow spell starts at 12
        XCTAssertTrue(gate.update(speed: 0.5, now: 14.9))
        XCTAssertFalse(gate.update(speed: 0.5, now: 15.0))
    }

    func testGateNilSpeedCountsAsStoppedAndResetClears() {
        var gate = WPDriveDirectionGate()
        gate.update(speed: 6, now: 0)
        gate.update(speed: nil, now: 1)
        XCTAssertFalse(gate.update(speed: nil, now: 4))
        gate.update(speed: 6, now: 5)
        gate.reset()
        XCTAssertFalse(gate.isOpen)
        XCTAssertNil(gate.slowSince)
    }
}

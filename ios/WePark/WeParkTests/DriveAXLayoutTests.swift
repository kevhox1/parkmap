//
//  DriveAXLayoutTests.swift
//  WeParkTests
//
//  Stoop drive mode at accessibility sizes: the compact one-line verdict per side keeps the
//  verdict and the end time, drops secondary text, and never turns a non-green side into park.
//  Also pins the world-covering tint ring.
//

import CoreLocation
import SwiftUI
import XCTest
@testable import WePark

final class DriveAXLayoutTests: XCTestCase {

    private func side(_ kind: WPDriveKind, _ big: String, _ sub: String?) -> WPDriveSide {
        WPDriveSide(kind: kind, isLeft: true, big: big, sub: sub)
    }

    func testCompactLine_green_readsParkUntilTime() {
        let s = WPDriveVerdict.side(
            isLeft: true,
            label: SafetyLabel(text: "Free until Mon 9:00 AM", severity: .free),
            override: .free
        )
        XCTAssertEqual(s.kind, .park)
        XCTAssertTrue(WPDriveVerdict.compactLine(for: s).hasPrefix("Park until Mon 9:00"))
    }

    func testCompactLine_midnightStaysSpelledOut() {
        let s = WPDriveVerdict.side(
            isLeft: false,
            label: SafetyLabel(text: "Free until Tue 12:00 AM", severity: .free),
            override: .free
        )
        let line = WPDriveVerdict.compactLine(for: s)
        XCTAssertTrue(line.contains("midnight"), line)
        XCTAssertFalse(line.contains("12:00 AM"), line)
    }

    func testCompactLine_nonGreen_isTheVerdictWordOnly_neverPark() {
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.dont, "No parking", nil)), "No parking")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.nodata, "Unclear sign", "Check the posted sign")), "Unclear sign")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.meter, "Metered", "Pay the meter. Check the signs.")), "Metered")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.soon, "Free now", "Free until Mon 9:00 AM")), "Free now")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.checking, "Checking", "One moment")), "Checking")
    }

    func testCompactLine_greenWithoutTime_isJustPark() {
        let s = side(.park, "Park", "No meter running in your window")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: s), "Park \u{00B7} no meter")
        XCTAssertEqual(WPDriveVerdict.compactLine(for: side(.park, "Park", nil)), "Park")
    }

    func testCompactLine_neverContradictsTheSideKind() {
        // Every kind other than .park must never produce a line that starts with "Park".
        for kind in [WPDriveKind.dont, .soon, .meter, .nodata, .checking] {
            let line = WPDriveVerdict.compactLine(for: side(kind, "X", "Free until Mon 9:00 AM"))
            XCTAssertFalse(line.hasPrefix("Park"), "\(kind): \(line)")
        }
    }

    func testDriveTypeSizeCap_isAccessibilitySized_andLowerOnShortPhones() {
        let se = WPDriveVerdict.maxDriveTypeSize(screenHeight: 667)
        let pro = WPDriveVerdict.maxDriveTypeSize(screenHeight: 874)
        XCTAssertTrue(se.isAccessibilitySize)
        XCTAssertTrue(pro.isAccessibilitySize)
        XCTAssertLessThan(se, pro)
    }

    func testTintRing_coversWorld_andEdgesStayUnder180Degrees() {
        let ring = WPDriveTintPolygon.worldRing
        XCTAssertEqual(ring.map(\.latitude).min(), -85)
        XCTAssertEqual(ring.map(\.latitude).max(), 85)
        XCTAssertLessThan(ring.map(\.longitude).min() ?? 0, -179)
        XCTAssertGreaterThan(ring.map(\.longitude).max() ?? 0, 179)
        for i in ring.indices {
            let next = ring[(i + 1) % ring.count]
            XCTAssertLessThan(abs(ring[i].longitude - next.longitude), 180)
        }
        // NYC is inside the box.
        XCTAssertTrue(ring.contains { $0.latitude > 40.7 } && ring.contains { $0.latitude < 40.7 })
    }
}

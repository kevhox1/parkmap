//
//  CurbLineWidthTests.swift
//  WeParkTests
//
//  Open item #19 (2026-09-12, polish-19-17b-20 session) — curb lines too thin, first
//  externally-sourced UI feedback (via Kevin): "the lines are not thick enough… especially
//  in the drive mode." `CurbLineWidth.width(for:driveModeActive:)` (`Views/MapViewRepresentable
//  .swift`) is the pure, unit-testable decision the renderer's `mapView(_:rendererFor:)`
//  delegate call site wires `parent.driveModeActive` into — the actual `MKPolylineRenderer
//  .lineWidth` assignment itself is UIKit rendering, verified live/on-sim per the PR's test
//  plan, not here.
//
//  COMPILE-UNVERIFIED. Written on a Linux VPS with no Xcode/Swift toolchain — never
//  compiled or run. A Mac `xcodebuild test` pass is a required gate before merge.
//
//  No Calendar.current use.
//

import XCTest
@testable import WePark

final class CurbLineWidthTests: XCTestCase {

    // MARK: - Browse mode (driveModeActive == false)

    func testFreeComfortably_browse_returnsStandardBrowse() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .freeComfortably, driveModeActive: false),
            CurbLineWidth.standardBrowse
        )
    }

    func testFreeButRestrictionSoon_browse_returnsStandardBrowse() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .freeButRestrictionSoon, driveModeActive: false),
            CurbLineWidth.standardBrowse
        )
    }

    func testRestrictedNow_browse_returnsStandardBrowse() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .restrictedNow, driveModeActive: false),
            CurbLineWidth.standardBrowse
        )
    }

    func testUnknown_browse_returnsStandardBrowse() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .unknown, driveModeActive: false),
            CurbLineWidth.standardBrowse
        )
    }

    func testMeteredActive_browse_returnsMeteredBrowse() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .meteredActive, driveModeActive: false),
            CurbLineWidth.meteredBrowse
        )
    }

    // MARK: - Drive Mode (driveModeActive == true)

    func testFreeComfortably_drive_returnsStandardDrive() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .freeComfortably, driveModeActive: true),
            CurbLineWidth.standardDrive
        )
    }

    func testMeteredActive_drive_returnsMeteredDrive() {
        XCTAssertEqual(
            CurbLineWidth.width(for: .meteredActive, driveModeActive: true),
            CurbLineWidth.meteredDrive
        )
    }

    // MARK: - Relationship invariants (open item #19's own asks)

    /// (a): browse-mode widths must be strictly thicker than the pre-#19 baseline (3/4).
    func testBrowseWidths_areThickerThanPreItem19Baseline() {
        XCTAssertGreaterThan(CurbLineWidth.standardBrowse, 3)
        XCTAssertGreaterThan(CurbLineWidth.meteredBrowse, 4)
    }

    /// (a): the metered/standard RATIO from before #19 (4/3) is preserved after the bump,
    /// so metered doesn't lose its existing relative legibility emphasis.
    func testMeteredToStandardRatio_browse_matchesPreItem19Ratio() {
        let preItem19Ratio = 4.0 / 3.0
        let newRatio = CurbLineWidth.meteredBrowse / CurbLineWidth.standardBrowse
        XCTAssertEqual(newRatio, preItem19Ratio, accuracy: 0.01)
    }

    /// (b): Drive Mode widths must be strictly thicker than their browse-mode counterparts.
    func testDriveWidths_areThickerThanBrowseWidths() {
        XCTAssertGreaterThan(CurbLineWidth.standardDrive, CurbLineWidth.standardBrowse)
        XCTAssertGreaterThan(CurbLineWidth.meteredDrive, CurbLineWidth.meteredBrowse)
    }

    /// (b): Drive Mode multiplier over the browse width must land in the open item's
    /// requested ~1.5x-2x range.
    func testDriveMultiplier_isWithinRequestedRange() {
        let standardMultiplier = CurbLineWidth.standardDrive / CurbLineWidth.standardBrowse
        let meteredMultiplier = CurbLineWidth.meteredDrive / CurbLineWidth.meteredBrowse
        XCTAssertGreaterThanOrEqual(standardMultiplier, 1.5)
        XCTAssertLessThanOrEqual(standardMultiplier, 2.0)
        XCTAssertGreaterThanOrEqual(meteredMultiplier, 1.5)
        XCTAssertLessThanOrEqual(meteredMultiplier, 2.0)
    }
}

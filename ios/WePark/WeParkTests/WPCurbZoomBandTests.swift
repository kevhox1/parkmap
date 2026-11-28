//
//  WPCurbZoomBandTests.swift
//  WeParkTests
//
//  R35 PR2 (docs/specs/r35-map-polish-and-trip-destination.md): the Stoop zoom bands, widths,
//  hints and the green-only payload filter.
//

import CoreGraphics
import MapKit
import XCTest
@testable import WePark

final class WPCurbZoomBandTests: XCTestCase {

    // MARK: - Bands

    func testBandBoundaries() {
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.0036), .full)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.012), .full)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.0121), .greenOnly)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.020), .greenOnly)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.0201), .off)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.5), .off)
    }

    func testLaunchRegionAndLocateSpansAreInTheFullBand() {
        // The launch region is about 0.0036 deg; the Locate span (R35 PR3) is 0.008 deg.
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.0036), .full)
        XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: 0.008), .full)
        XCTAssertLessThanOrEqual(0.0036, WPCurbZoomConstants.fullMaxDelta)
    }

    func testBadInputFallsBackToFullBandAndDefaultWidth() {
        for bad in [Double.nan, 0, -1, -0.5, Double.infinity] {
            XCTAssertEqual(WPCurbZoomBand.band(latitudeDelta: bad), .full)
            XCTAssertEqual(WPCurbZoomBand.width(latitudeDelta: bad, band: .full), 4.5)
        }
    }

    // MARK: - Widths

    func testWidthAtTheKnots() {
        for knot in WPCurbZoomConstants.knots {
            // Raw interpolation (the green-only floor is checked separately).
            let width = WPCurbZoomBand.width(latitudeDelta: knot.delta, band: .full)
            XCTAssertEqual(width, knot.width, accuracy: 0.0001, "delta \(knot.delta)")
        }
    }

    func testWidthIsMonotoneNonIncreasingAboveThePeak() {
        var previous = CGFloat.greatestFiniteMagnitude
        var delta = 0.0035
        while delta <= 0.03 {
            let band = WPCurbZoomBand.band(latitudeDelta: delta)
            let width = WPCurbZoomBand.width(latitudeDelta: delta, band: band)
            XCTAssertLessThanOrEqual(width, previous, "delta \(delta)")
            previous = width
            delta += 0.0001
        }
    }

    func testWidthIsQuantizedAndClamped() {
        var delta = 0.0005
        while delta <= 0.04 {
            let band = WPCurbZoomBand.band(latitudeDelta: delta)
            let width = WPCurbZoomBand.width(latitudeDelta: delta, band: band)
            XCTAssertEqual((width / 0.25).rounded() * 0.25, width, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(width, 1.5)
            XCTAssertLessThanOrEqual(width, 4.5)
            delta += 0.00037
        }
    }

    func testGreenFloorInTheGreenOnlyBand() {
        // Raw interpolation reaches 1.5 pt at 0.020; the green-only band never goes below 2.0.
        let width = WPCurbZoomBand.width(latitudeDelta: 0.020, band: .greenOnly)
        XCTAssertEqual(width, 2.0)
        XCTAssertEqual(WPCurbZoomBand.width(latitudeDelta: 0.020, band: .full), 1.5)
        XCTAssertGreaterThanOrEqual(WPCurbZoomBand.width(latitudeDelta: 0.0121, band: .greenOnly), 2.0)
    }

    func testCloseInWidthIsBetweenThreeAndFourAndAHalf() {
        XCTAssertEqual(WPCurbZoomBand.width(latitudeDelta: 0.0003, band: .full), 3.0)
        XCTAssertEqual(WPCurbZoomBand.width(latitudeDelta: 0.0035, band: .full), 4.5)
        XCTAssertEqual(WPCurbZoomBand.width(latitudeDelta: 0.008, band: .full), 3.0)
    }

    func testRenderScaleIsWidthOverTheDesignWidth() {
        XCTAssertEqual(WPCurbZoomBand.renderScale(latitudeDelta: 0.0035), 4.5 / 6, accuracy: 0.0001)
        XCTAssertEqual(WPCurbZoomBand.renderScale(latitudeDelta: 0.020), 2.0 / 6, accuracy: 0.0001)
    }

    func testDashScaleFloor() {
        XCTAssertEqual(WPCurbZoomBand.dashScale(forRenderScale: 1.5 / 6), 0.5)
        XCTAssertEqual(WPCurbZoomBand.dashScale(forRenderScale: 0.75), 0.75)
        XCTAssertEqual(WPCurbZoomBand.dashScale(forRenderScale: 0.01), 0.5)
    }

    // MARK: - Hints

    func testHints() {
        XCTAssertNil(WPCurbZoomBand.hint(for: .full))
        XCTAssertEqual(WPCurbZoomBand.hint(for: .greenOnly), "Green curbs only. Zoom in to see the rest.")
        XCTAssertEqual(WPCurbZoomBand.hint(for: .off), "Zoom in to see parking")
    }

    // MARK: - Payload filter

    func testGreenOnlyKeepsExactlyTheFullGreenGroup() {
        let groups = WPCurbZoomBand.Groups(
            free: ["g1", "g2", "g3"], soon: ["s1"], metered: ["m1", "m2"],
            restricted: ["r1", "r2", "r3", "r4"], unknown: ["u1"]
        )
        let full = WPCurbZoomBand.filter(payloadGroups: groups, band: .full)
        XCTAssertEqual(full.free, groups.free)
        XCTAssertEqual(full.restricted, groups.restricted)
        let greenOnly = WPCurbZoomBand.filter(payloadGroups: groups, band: .greenOnly)
        XCTAssertEqual(greenOnly.free, full.free, "green is untouched")
        XCTAssertTrue(greenOnly.soon.isEmpty)
        XCTAssertTrue(greenOnly.metered.isEmpty)
        XCTAssertTrue(greenOnly.restricted.isEmpty)
        XCTAssertTrue(greenOnly.unknown.isEmpty)
        let off = WPCurbZoomBand.filter(payloadGroups: groups, band: .off)
        XCTAssertTrue(off.free.isEmpty)
    }

    func testFilterNeverAddsGreen() {
        let groups = WPCurbZoomBand.Groups(
            free: [Int](), soon: [1, 2], metered: [3], restricted: [4], unknown: [5]
        )
        for band in [WPCurbZoomBand.full, .greenOnly, .off] {
            XCTAssertTrue(WPCurbZoomBand.filter(payloadGroups: groups, band: band).free.isEmpty)
        }
    }

    // MARK: - Style application

    @MainActor
    func testDashedLinesGetTheInflationCompensationAndSolidDoNot() {
        let scale = WPCurbZoomBand.renderScale(latitudeDelta: 0.008)   // 3 pt
        let solid = CurbLineStyleV2.style(for: .park)
        let dashed = CurbLineStyleV2.style(for: .dont)
        let solidRenderer = MKPolylineRenderer(polyline: MKPolyline())
        let dashedRenderer = MKPolylineRenderer(polyline: MKPolyline())
        CurbLineStyleV2.applyZoomBand(solid, to: solidRenderer, scale: scale)
        CurbLineStyleV2.applyZoomBand(dashed, to: dashedRenderer, scale: scale)
        XCTAssertEqual(solidRenderer.lineWidth, 3.0, accuracy: 0.001)
        XCTAssertEqual(dashedRenderer.lineWidth, 3.0 / WPCurbZoomConstants.dashedRenderInflation, accuracy: 0.001)
        XCTAssertNil(solidRenderer.lineDashPattern)
        XCTAssertEqual(dashedRenderer.lineDashPattern?.first?.doubleValue ?? 0, 10 * 0.5, accuracy: 0.001)
    }

    @MainActor
    func testDriveStylePathIsUnchanged() {
        // The legacy apply (used in Drive Mode) is untouched: width = style width x zoomScale.
        let renderer = MKPolylineRenderer(polyline: MKPolyline())
        CurbLineStyleV2.apply(CurbLineStyleV2.style(for: .dont), to: renderer, scale: 1)
        XCTAssertEqual(renderer.lineWidth, WP.CurbLine.width, accuracy: 0.001)
        XCTAssertEqual(renderer.lineDashPattern?.count, WP.CurbLine.dontDash.count)
    }
}

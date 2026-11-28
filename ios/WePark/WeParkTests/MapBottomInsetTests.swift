//
//  MapBottomInsetTests.swift
//  WeParkTests
//
//  DT35-6: the drive-mode bottom map inset that lifts the Apple Maps legal link.
//

import XCTest
import MapKit
@testable import WePark

final class MapBottomInsetTests: XCTestCase {

    // MARK: Policy

    func testInsetIsMeasuredPlusGap() {
        XCTAssertEqual(
            MapBottomInsetPolicy.inset(measuredFromBottom: 200, mapHeight: 852, driving: true), 208
        )
    }

    func testInsetClampsToSixtyPercentOfMapHeight() {
        XCTAssertEqual(
            MapBottomInsetPolicy.inset(measuredFromBottom: 700, mapHeight: 852, driving: true),
            852 * 0.6, accuracy: 0.001
        )
    }

    func testInsetIsZeroWhenNotDrivingOrMeasurementInvalid() {
        XCTAssertEqual(MapBottomInsetPolicy.inset(measuredFromBottom: 200, mapHeight: 852, driving: false), 0)
        XCTAssertEqual(MapBottomInsetPolicy.inset(measuredFromBottom: 0, mapHeight: 852, driving: true), 0)
        XCTAssertEqual(MapBottomInsetPolicy.inset(measuredFromBottom: -5, mapHeight: 852, driving: true), 0)
        XCTAssertEqual(MapBottomInsetPolicy.inset(measuredFromBottom: .nan, mapHeight: 852, driving: true), 0)
        XCTAssertEqual(MapBottomInsetPolicy.inset(measuredFromBottom: 200, mapHeight: 0, driving: true), 0)
    }

    // MARK: Snapshot and restore

    @MainActor
    func testApplyThenClearRestoresOriginalMarginsExactly() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        map.layoutMargins = UIEdgeInsets(top: 3, left: 5, bottom: 7, right: 9)
        let flagBefore = map.insetsLayoutMarginsFromSafeArea
        map.insetsLayoutMarginsFromSafeArea = false
        let rawBefore = map.layoutMargins
        map.insetsLayoutMarginsFromSafeArea = flagBefore

        let controller = MapBottomInsetController()
        controller.apply(inset: 260, to: map)
        XCTAssertFalse(map.insetsLayoutMarginsFromSafeArea)
        XCTAssertEqual(map.layoutMargins.bottom, 260)

        controller.apply(inset: 0, to: map)
        XCTAssertEqual(map.insetsLayoutMarginsFromSafeArea, flagBefore)
        map.insetsLayoutMarginsFromSafeArea = false
        XCTAssertEqual(map.layoutMargins, rawBefore)
        XCTAssertNil(controller.snapshot)
    }

    @MainActor
    func testRepeatedInsetChangesKeepTheFirstSnapshot() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let controller = MapBottomInsetController()
        controller.apply(inset: 200, to: map)
        let first = controller.snapshot
        controller.apply(inset: 320, to: map)
        XCTAssertEqual(controller.snapshot, first)
        XCTAssertEqual(map.layoutMargins.bottom, 320)
        controller.restore(on: map)
        XCTAssertNil(controller.snapshot)
    }

    @MainActor
    func testRestoreWithoutApplyIsANoOp() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        map.layoutMargins = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
        let before = map.layoutMargins
        MapBottomInsetController().restore(on: map)
        XCTAssertEqual(map.layoutMargins, before)
    }

    @MainActor
    func testApplyNeverHidesTheMap() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        MapBottomInsetController().apply(inset: 240, to: map)
        XCTAssertFalse(map.isHidden)
        XCTAssertEqual(map.alpha, 1)
    }

    // MARK: Seam and the #31 rule

    func testCoordinatorActionsSeamIsCallable() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var received: CGFloat?
        actions.onSetBottomChromeInset = { received = $0 }
        actions.setBottomChromeInset(208)
        XCTAssertEqual(received, 208)
    }

    /// #31: `updateUIView` runs during SwiftUI's update cycle and must not write layout margins.
    func testUpdateUIViewDoesNotWriteMargins() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WePark/Views/MapViewRepresentable.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func updateUIView("))
        let end = try XCTUnwrap(source.range(of: "// MARK: - Coordinator", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("layoutMargins"))
        XCTAssertFalse(body.contains("bottomInsetController"))
        XCTAssertFalse(body.contains("setBottomChromeInset"))
    }
}

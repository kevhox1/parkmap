//
//  LocationServiceTests.swift
//  WeParkTests
//
//  TF2-16: `LocationService.driveCourseAccuracy` publishing tests.
//  Spec: docs/tf2-16-heading-snap-spec.md §8, items 14-16.
//
//  Note: no `LocationServiceTests.swift` file predated this spec (LocationService's
//  Drive Mode behavior was previously covered by `LocationServiceDriveModeTests` in
//  W85cTests.swift and `FT7HeadingSourceTests` in FT7Tests.swift, both of which drive
//  the service through `stabilizedHeading(...)` directly rather than the
//  `CLLocationManagerDelegate` callback). `driveCourseAccuracy` is only set inside
//  `locationManager(_:didUpdateLocations:)`, so these tests invoke that delegate
//  method directly — it's `internal` (protocol conformance in an extension), so it's
//  directly callable from `@testable import WePark` without a mock CLLocationManager.
//
//  The delegate method dispatches its state writes via `DispatchQueue.main.async`
//  (documented "Modifying state during view update" avoidance); tests use an
//  expectation fulfilled by a second `DispatchQueue.main.async` call to guarantee the
//  first block has drained before asserting (FIFO ordering on the same serial queue).
//

import XCTest
import CoreLocation
@testable import WePark

final class LocationServiceDriveCourseAccuracyTests: XCTestCase {

    var service: LocationService!

    override func setUp() {
        super.setUp()
        service = LocationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    /// Waits for the delegate method's `DispatchQueue.main.async` state-write block to drain
    /// by enqueueing a second block behind it on the same serial main queue (FIFO).
    private func waitForMainQueueDrain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
    }

    private func makeLocation(course: CLLocationDirection, courseAccuracy: CLLocationDirectionAccuracy, speed: CLLocationSpeed = 5.0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course,
            courseAccuracy: courseAccuracy,
            speed: speed,
            speedAccuracy: 1.0,
            timestamp: Date()
        )
    }

    // MARK: 14. driveCourseAccuracy publishes the raw value

    func testDriveCourseAccuracy_publishesRawValue() {
        service.startDriveMode()
        let location = makeLocation(course: 45.0, courseAccuracy: 12.5)
        service.locationManager(CLLocationManager(), didUpdateLocations: [location])
        waitForMainQueueDrain()

        XCTAssertEqual(service.driveCourseAccuracy ?? -1, 12.5, accuracy: 0.01,
            "driveCourseAccuracy should publish CLLocation.courseAccuracy from the same tick as driveSpeed")
        service.endDriveMode()
    }

    // MARK: 15. Negative (invalid) courseAccuracy publishes nil

    func testDriveCourseAccuracy_negativeValue_publishesNil() {
        service.startDriveMode()
        // CoreLocation's "invalid" sentinel for courseAccuracy is a negative value,
        // matching the existing `course >= 0 ? course : nil` pattern for courseHeading.
        let location = makeLocation(course: 45.0, courseAccuracy: -1.0)
        service.locationManager(CLLocationManager(), didUpdateLocations: [location])
        waitForMainQueueDrain()

        XCTAssertNil(service.driveCourseAccuracy,
            "Negative (invalid) courseAccuracy should publish nil")
        service.endDriveMode()
    }

    // MARK: 16. driveCourseAccuracy cleared on endDriveMode

    func testDriveCourseAccuracy_clearedOnEndDriveMode() {
        service.startDriveMode()
        let location = makeLocation(course: 45.0, courseAccuracy: 8.0)
        service.locationManager(CLLocationManager(), didUpdateLocations: [location])
        waitForMainQueueDrain()
        XCTAssertNotNil(service.driveCourseAccuracy, "Sanity check: value should be published before endDriveMode")

        service.endDriveMode()
        XCTAssertNil(service.driveCourseAccuracy,
            "driveCourseAccuracy should be cleared to nil in endDriveMode alongside other drive-session state")
    }
}

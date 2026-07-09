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
//  `CLLocationManagerDelegate` callback).
//
//  `driveCourseAccuracy` is only set inside `locationManager(_:didUpdateLocations:)`, so
//  these tests invoke that delegate method directly — it's `internal` (protocol
//  conformance in an extension), so it's directly callable from `@testable import WePark`
//  without a mock CLLocationManager.
//
//  These tests use `setDriveModeActiveForTesting(true)` (a DEBUG-only seam mirroring the
//  existing `setAuthorizationStatusForTesting`) instead of the real `startDriveMode()`.
//  `startDriveMode()` starts a REAL `CLLocationManager.startUpdatingLocation()` session,
//  which in the Simulator can race with OS-synthesized location fixes and clobber the
//  test's manually-injected `CLLocation` shortly after — this was the root cause of
//  nondeterministic failures observed while developing this file under a full-suite run.
//  The seam lets these tests exercise the real Drive Mode branch of
//  `locationManager(_:didUpdateLocations:)` (including the `driveCourseAccuracy` sentinel
//  parsing, AC-2) deterministically, with no live system location session in play.
//
//  The delegate method still dispatches its state writes via `DispatchQueue.main.async`
//  (documented "Modifying state during view update" avoidance), so tests poll with
//  `try? await Task.sleep(...)` — same established pattern as `CommunityPinServiceTests`
//  (debounced async publishes).
//

import XCTest
import CoreLocation
@testable import WePark

final class LocationServiceDriveCourseAccuracyTests: XCTestCase {

    var service: LocationService!

    /// A single shared throwaway `CLLocationManager` instance for the `manager:` delegate
    /// parameter, which the implementation under test never reads.
    private static let dummyManager = CLLocationManager()

    override func setUp() {
        super.setUp()
        service = LocationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    /// Polls `condition` with short async sleeps until it returns `true` or `timeout`
    /// elapses. Mirrors the debounce-polling pattern in `CommunityPinServiceTests`.
    private func waitUntil(timeout: TimeInterval = 3.0, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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

    func testDriveCourseAccuracy_publishesRawValue() async {
        service.setDriveModeActiveForTesting(true)
        let location = makeLocation(course: 45.0, courseAccuracy: 12.5)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location])
        await waitUntil { self.service.driveSpeed != nil }

        XCTAssertEqual(service.driveCourseAccuracy ?? -1, 12.5, accuracy: 0.01,
            "driveCourseAccuracy should publish CLLocation.courseAccuracy from the same tick as driveSpeed")
        service.setDriveModeActiveForTesting(false)
    }

    // MARK: 15. Negative (invalid) courseAccuracy publishes nil

    func testDriveCourseAccuracy_negativeValue_publishesNil() async {
        service.setDriveModeActiveForTesting(true)
        // CoreLocation's "invalid" sentinel for courseAccuracy is a negative value,
        // matching the existing `course >= 0 ? course : nil` pattern for courseHeading.
        let location = makeLocation(course: 45.0, courseAccuracy: -1.0)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location])
        await waitUntil { self.service.driveSpeed != nil }

        XCTAssertNil(service.driveCourseAccuracy,
            "Negative (invalid) courseAccuracy should publish nil")
        service.setDriveModeActiveForTesting(false)
    }

    // MARK: 16. driveCourseAccuracy cleared on endDriveMode

    func testDriveCourseAccuracy_clearedOnEndDriveMode() async {
        service.setDriveModeActiveForTesting(true)
        let location = makeLocation(course: 45.0, courseAccuracy: 8.0)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location])
        await waitUntil { self.service.driveCourseAccuracy != nil }
        XCTAssertNotNil(service.driveCourseAccuracy, "Sanity check: value should be published before endDriveMode")

        // Exercise the REAL endDriveMode() (not the testing seam) — this is the code path
        // AC-2 requires ("cleared in endDriveMode()"). driveModeActiveInternal was set via
        // the testing seam above (no live CLLocationManager session was ever started), so
        // endDriveMode()'s stop calls are harmless no-ops; its state-clearing behavior is real.
        service.endDriveMode()
        XCTAssertNil(service.driveCourseAccuracy,
            "driveCourseAccuracy should be cleared to nil in endDriveMode alongside other drive-session state")
    }
}

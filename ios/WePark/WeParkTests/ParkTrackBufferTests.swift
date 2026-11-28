//
//  ParkTrackBufferTests.swift
//  WeParkTests
//
//  DT35-2 (docs/specs/dt35-park-flow-and-drive-fixes.md, PR1 section 1A): the in-memory fix trail
//  behind "Park here". Pure buffer rules, plus the LocationService wiring (drive branch records
//  accuracy, cleared on `endDriveMode`). Same direct-delegate-call pattern as
//  `LocationServiceDriveCourseAccuracyTests`.
//

import XCTest
import CoreLocation
@testable import WePark

final class ParkTrackBufferTests: XCTestCase {

    private static let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func fix(at seconds: Double, speed: Double = 5) -> ParkTrackFix {
        ParkTrackFix(
            coordinate: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
            course: 90, courseAccuracy: 5, speed: speed, horizontalAccuracy: 6,
            timestamp: Self.base.addingTimeInterval(seconds)
        )
    }

    func testCapsAtFortyFixes_keepingTheNewest() {
        var buffer = ParkTrackBuffer()
        for index in 0..<60 { buffer.append(fix(at: Double(index))) }
        XCTAssertEqual(buffer.fixes.count, ParkTrackConstants.maxFixes)
        XCTAssertEqual(buffer.fixes.last?.timestamp, Self.base.addingTimeInterval(59))
        XCTAssertEqual(buffer.fixes.first?.timestamp, Self.base.addingTimeInterval(20))
    }

    func testFixesLessThanOneSecondApart_areDropped() {
        var buffer = ParkTrackBuffer()
        XCTAssertTrue(buffer.append(fix(at: 0)))
        XCTAssertFalse(buffer.append(fix(at: 0.4)))
        XCTAssertFalse(buffer.append(fix(at: 0.99)))
        XCTAssertTrue(buffer.append(fix(at: 1.0)))
        XCTAssertEqual(buffer.fixes.count, 2)
    }

    func testFixesOlderThan120Seconds_expire() {
        var buffer = ParkTrackBuffer()
        buffer.append(fix(at: 0))
        buffer.append(fix(at: 50))
        buffer.append(fix(at: 100))
        XCTAssertEqual(buffer.fixes.count, 3)
        buffer.append(fix(at: 125))   // the t = 0 fix is now 125 s old
        XCTAssertEqual(buffer.fixes.map(\.timestamp), [50, 100, 125].map { Self.base.addingTimeInterval($0) })
    }

    func testRemoveAll_empties() {
        var buffer = ParkTrackBuffer()
        buffer.append(fix(at: 0))
        buffer.removeAll()
        XCTAssertTrue(buffer.fixes.isEmpty)
    }

    func testFixFromLocation_mapsInvalidSentinelsToNil() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: 5,
            course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1, timestamp: Self.base
        )
        let mapped = ParkTrackFix(location: location)
        XCTAssertNil(mapped.course)
        XCTAssertNil(mapped.courseAccuracy)
        XCTAssertNil(mapped.horizontalAccuracy)
        XCTAssertLessThan(mapped.speed, 0)
    }
}

final class ParkTrackLocationServiceTests: XCTestCase {

    private var service: LocationService!
    private static let dummyManager = CLLocationManager()

    override func setUp() {
        super.setUp()
        service = LocationService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 3.0, condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func location(accuracy: CLLocationAccuracy, seconds: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
            course: 90, courseAccuracy: 8, speed: 4, speedAccuracy: 1,
            timestamp: Date(timeIntervalSinceReferenceDate: 750_000_000 + seconds)
        )
    }

    func testDriveBranch_recordsHorizontalAccuracyAndTheTrack() async {
        service.setDriveModeActiveForTesting(true)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location(accuracy: 7.5, seconds: 0)])
        await waitUntil { self.service.driveHorizontalAccuracy != nil }

        XCTAssertEqual(service.driveHorizontalAccuracy ?? -1, 7.5, accuracy: 0.01)
        XCTAssertEqual(service.latestParkFix?.horizontalAccuracy ?? -1, 7.5, accuracy: 0.01)
        XCTAssertEqual(service.latestParkFix?.course ?? -1, 90, accuracy: 0.01)
        XCTAssertEqual(service.recentTrack.count, 1)
        service.setDriveModeActiveForTesting(false)
    }

    func testDriveBranch_invalidAccuracy_isNil() async {
        service.setDriveModeActiveForTesting(true)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location(accuracy: -1, seconds: 0)])
        await waitUntil { self.service.latestParkFix != nil }

        XCTAssertNil(service.driveHorizontalAccuracy)
        XCTAssertNil(service.latestParkFix?.horizontalAccuracy)
        service.setDriveModeActiveForTesting(false)
    }

    func testSingleShotBranch_alsoRecordsTheFix() async {
        service.locationManager(Self.dummyManager, didUpdateLocations: [location(accuracy: 12, seconds: 0)])
        await waitUntil { self.service.latestParkFix != nil }

        XCTAssertEqual(service.latestParkFix?.horizontalAccuracy ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(service.recentTrack.count, 1)
    }

    func testTrackIsClearedOnEndDriveMode() async {
        service.setDriveModeActiveForTesting(true)
        service.locationManager(Self.dummyManager, didUpdateLocations: [location(accuracy: 6, seconds: 0)])
        service.locationManager(Self.dummyManager, didUpdateLocations: [location(accuracy: 6, seconds: 2)])
        await waitUntil { self.service.recentTrack.count == 2 }
        XCTAssertEqual(service.recentTrack.count, 2, "sanity: two fixes were recorded")

        service.endDriveMode()

        XCTAssertTrue(service.recentTrack.isEmpty)
        XCTAssertNil(service.latestParkFix)
        XCTAssertNil(service.driveHorizontalAccuracy)
    }
}

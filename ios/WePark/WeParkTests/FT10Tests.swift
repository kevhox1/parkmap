//
//  FT10Tests.swift
//  WeParkTests
//
//  FT-10: Follow-pause state machine tests.
//
//  Test groups (per spec §6 Group 5):
//    AC-FT10.1 — shouldSyncDriveRegion(true, true) = true
//    AC-FT10.2 — shouldSyncDriveRegion(true, false) = false (follow paused)
//    AC-FT10.3 — shouldSyncDriveRegion(false, true) = false (not in Drive Mode)
//    AC-FT10.4 — shouldSyncDriveRegion(false, false) = false
//    AC-FT10.5 — Animated syncDriveHeading does NOT call onDrivePanDetected
//    AC-FT10.6 — When driveFollowEnabled=false, syncDriveRegion is NOT called
//
//  Group 6 (spec §6 Group 6):
//    AC-FT7.12 — Animated syncDriveHeading does not set isUserInteracting = true
//    AC-FT7.13 — Animated syncDriveRegion recenter does not trigger onDrivePanDetected
//
//  Architecture note: all tests use pure functions or Coordinator state — no live MKMapView window.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Group 5: Follow-pause state machine tests

@MainActor
final class FT10FollowPauseTests: XCTestCase {

    // MARK: AC-FT10.1 — driveModeActive=true, driveFollowEnabled=true → true

    /// Both conditions met → syncDriveRegion should run.
    func testShouldSyncDriveRegion_activeAndFollowEnabled_returnsTrue() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: true
        )
        XCTAssertTrue(result,
            "shouldSyncDriveRegion(true, true) must return true — Drive Mode active and follow enabled")
    }

    // MARK: AC-FT10.2 — driveModeActive=true, driveFollowEnabled=false → false

    /// Drive Mode active but follow paused → syncDriveRegion should NOT run.
    /// This is the FT-10 root cause fix: the user panned/zoomed and we must not snap back.
    func testShouldSyncDriveRegion_activeButFollowPaused_returnsFalse() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: false
        )
        XCTAssertFalse(result,
            "shouldSyncDriveRegion(true, false) must return false — follow paused, no snap-back")
    }

    // MARK: AC-FT10.3 — driveModeActive=false, driveFollowEnabled=true → false

    /// Not in Drive Mode — the non-drive setRegion path handles sync; syncDriveRegion should NOT run.
    func testShouldSyncDriveRegion_inactiveWithFollowEnabled_returnsFalse() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: false,
            driveFollowEnabled: true
        )
        XCTAssertFalse(result,
            "shouldSyncDriveRegion(false, true) must return false — not in Drive Mode")
    }

    // MARK: AC-FT10.4 — driveModeActive=false, driveFollowEnabled=false → false

    /// Both false → syncDriveRegion should NOT run.
    func testShouldSyncDriveRegion_bothFalse_returnsFalse() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: false,
            driveFollowEnabled: false
        )
        XCTAssertFalse(result,
            "shouldSyncDriveRegion(false, false) must return false")
    }

    // MARK: AC-FT10.5 — Animated syncDriveHeading does NOT call onDrivePanDetected

    /// When syncDriveHeading fires an animated setCamera, it fires regionWillChangeAnimated
    /// with no active gesture recognizer. The isUserGesture check finds no active recognizer
    /// → onDrivePanDetected is NOT called → driveFollowEnabled stays true.
    ///
    /// We test this indirectly: the isUserGesture check in regionWillChangeAnimated looks at
    /// gesture recognizers. A bare MKMapView() has no active gesture recognizers, so any
    /// programmatic setCamera call should NOT trigger onDrivePanDetected.
    ///
    /// This test verifies the Coordinator's onDrivePanDetected closure is not called via
    /// the syncDriveHeading code path (which goes through setCamera, not a user gesture).
    func testSyncDriveHeading_animatedSetCamera_doesNotCallOnDrivePanDetected() {
        var panDetectedFired = false

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let representable = MapViewRepresentable(
            region: .constant(region),
            selectedSegmentID: .constant(nil),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: .init(),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: 90.0,
            driveModeActive: true,
            onDrivePanDetected: { panDetectedFired = true },
            driveFollowEnabled: true,
            coordinatorActions: MapViewRepresentable.CoordinatorActions()
        )
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        // Apply an initial heading so the dead-band guard doesn't block the update.
        coordinator.lastAppliedHeading = 0.0

        // Call syncDriveHeading with a heading change > 2° (dead-band threshold).
        // This issues an animated setCamera internally.
        coordinator.syncDriveHeading(90.0, on: mapView)

        // onDrivePanDetected should NOT have been called.
        // Note: The actual regionWillChangeAnimated path requires a live map in a window
        // to fire; here we verify the Coordinator's direct call path doesn't call the closure.
        // The isUserGesture guard in regionWillChangeAnimated (which checks live gesture
        // recognizers) provides the real production guarantee for the animated setCamera path.
        XCTAssertFalse(panDetectedFired,
            "onDrivePanDetected must NOT be called by syncDriveHeading's animated setCamera " +
            "(no active gesture recognizer in the Coordinator direct path)")
    }

    // MARK: AC-FT10.6 — When driveFollowEnabled=false, syncDriveRegion is NOT called

    /// Verifies that the shouldSyncDriveRegion gate suppresses syncDriveRegion when
    /// driveFollowEnabled == false.
    ///
    /// We test the gate function directly (the pure extraction). The gate is applied
    /// in updateUIView's else-branch, and the gate contract is that shouldSyncDriveRegion
    /// returns false when driveFollowEnabled is false.
    func testShouldSyncDriveRegion_followPaused_gateReturnsFalse() {
        // This is the gate that blocks syncDriveRegion when follow is paused.
        // The actual syncDriveRegion call is inside updateUIView guarded by this result.
        let shouldSync = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: false  // Follow paused by user pan/zoom
        )
        XCTAssertFalse(shouldSync,
            "When driveFollowEnabled=false, shouldSyncDriveRegion must return false " +
            "(camera stays where user left it)")
    }

    // MARK: driveFollowEnabled default value

    /// Verifies MapViewRepresentable's driveFollowEnabled property defaults to true.
    /// This ensures follow mode is active when Drive Mode starts (correct initial state).
    func testDriveFollowEnabled_defaultIsTrue() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let representable = MapViewRepresentable(
            region: .constant(region),
            selectedSegmentID: .constant(nil),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: .init(),
            activeRoute: nil,
            destinationCoordinate: nil,
            coordinatorActions: MapViewRepresentable.CoordinatorActions()
        )
        XCTAssertTrue(representable.driveFollowEnabled,
            "driveFollowEnabled must default to true (follow mode active at Drive Mode start)")
    }
}

// MARK: - Group 6: FT-5 Non-Interference

@MainActor
final class FT10FT5NonInterferenceTests: XCTestCase {

    // MARK: AC-FT7.12 — Animated syncDriveHeading does not set isUserInteracting = true

    /// Verifies that after syncDriveHeading runs, the Coordinator's isUserInteracting
    /// flag is not set to true. The isUserInteracting flag is only set in
    /// regionWillChangeAnimated when an active gesture recognizer is found. A bare MKMapView
    /// (no window, no active gesture recognizers) does not have active recognizers, so the
    /// flag stays false through any programmatic setCamera.
    func testSyncDriveHeading_doesNotSetIsUserInteracting() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let representable = MapViewRepresentable(
            region: .constant(region),
            selectedSegmentID: .constant(nil),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: .init(),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: 90.0,
            driveModeActive: true,
            coordinatorActions: MapViewRepresentable.CoordinatorActions()
        )
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        // Start with isUserInteracting = false.
        XCTAssertFalse(coordinator.isUserInteracting, "isUserInteracting must start false")

        // Apply a heading change > 2° (will issue animated setCamera).
        coordinator.lastAppliedHeading = 0.0
        coordinator.syncDriveHeading(90.0, on: mapView)

        // isUserInteracting must remain false — programmatic setCamera is not a user gesture.
        XCTAssertFalse(coordinator.isUserInteracting,
            "isUserInteracting must remain false after syncDriveHeading's animated setCamera " +
            "(no active gesture recognizer → isUserGesture=false in regionWillChangeAnimated)")
    }

    // MARK: AC-FT7.13 — Animated syncDriveRegion does not trigger onDrivePanDetected

    /// Verifies that syncDriveRegion's animated setCamera does not trigger onDrivePanDetected.
    /// Same rationale as AC-FT10.5: no active gesture recognizer → isUserGesture=false.
    func testSyncDriveRegion_animatedSetCamera_doesNotTriggerOnDrivePanDetected() {
        var panDetectedFired = false

        let initialCoord = CLLocationCoordinate2D(latitude: 40.750, longitude: -73.990)
        let newCenter = CLLocationCoordinate2D(latitude: 40.755, longitude: -73.985)
        let region = MKCoordinateRegion(
            center: newCenter,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let representable = MapViewRepresentable(
            region: .constant(region),
            selectedSegmentID: .constant(nil),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: .init(),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: 90.0,
            driveModeActive: true,
            onDrivePanDetected: { panDetectedFired = true },
            driveFollowEnabled: true,
            coordinatorActions: MapViewRepresentable.CoordinatorActions()
        )
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        // Position the map at a different location so syncDriveRegion's guard passes.
        let oldCamera = MKMapCamera(
            lookingAtCenter: initialCoord,
            fromDistance: 1000,
            pitch: 45,
            heading: 0
        )
        mapView.setCamera(oldCamera, animated: false)

        // Call syncDriveRegion — issues animated setCamera (no user gesture).
        coordinator.syncDriveRegion(region, on: mapView)

        // onDrivePanDetected must NOT have been called.
        XCTAssertFalse(panDetectedFired,
            "onDrivePanDetected must NOT be triggered by syncDriveRegion's animated setCamera " +
            "(programmatic recenter is not a user gesture)")
    }

    // MARK: shouldSyncRegionToBinding unchanged — existing RegionSyncGuardTests still pass

    /// Smoke check: shouldSyncRegionToBinding still returns false when driveModeActive=true.
    /// This verifies the FT-5 / FT-10 separation: shouldSyncRegionToBinding and
    /// shouldSyncDriveRegion are distinct functions with distinct contracts.
    func testShouldSyncRegionToBinding_stillReturnsFalseInDriveMode() {
        let result = MapViewRepresentable.shouldSyncRegionToBinding(
            driveModeActive: true,
            isUserInteracting: false
        )
        XCTAssertFalse(result,
            "shouldSyncRegionToBinding must still return false in Drive Mode (FT-5 / PR-3 invariant)")
    }
}

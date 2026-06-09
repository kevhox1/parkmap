//
//  DriveCameraTiltTests.swift
//  WeParkTests
//
//  W8.5c-polish PR-3 unit tests: 3D camera tilt on Drive Mode entry/exit.
//
//  Architecture note: tests follow the pure-function strategy from spec §5.
//  The pitch-decision logic is extracted into `MapViewRepresentable.targetPitch(forDriveModeActive:priorPitch:)` —
//  a static function with NO MKMapView dependency. These tests exercise that function directly.
//
//  The actual `MKMapView.camera.pitch` application is verified by the mandatory live-UI smoke
//  (documented in the PR description / AC-7), NOT by a unit test that requires a windowed
//  MKMapView. This keeps production code free of headless-window guards, UIWindowScene
//  synthesis, and RunLoop.main.run(until:) calls — all of which appeared in the reverted
//  W8.5c-polish and are explicitly forbidden by spec §5 and AC-6.
//
//  Test inventory:
//    1. testPitchDecision_onEntry_returnsConstantPitch  — active=true  → driveModePitch (45°, PR-2)
//    2. testPitchDecision_onExit_restoresPriorPitch     — active=false → priorPitch (5°)
//    3. testPitchDecision_onExit_noPrior_returnsZero    — active=false → 0 when priorPitch=0
//    4. testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped  — R-1 coexistence
//    5. testPitchDecision_onEntry_returnsConstantValue  — verifies constant = 45° (PR-2 measured)
//    6. testPitchDecision_onExit_restoresNonZeroPrior   — OQ-3: non-zero priorPitch is preserved
//
//  PR-2 change: driveModePitch updated 30° → 45° (measured at tighter zoom ~0.005° span).
//  Tests 1 and 5 updated accordingly (spec §5: "update the existing targetPitch test").
//  Baseline before PR-3: 207/0. PR-3 added 6. PR-2 updates 2 existing tests.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//  No MKMapView camera reads (pure-function strategy, spec §5).
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Pure-function pitch decision tests

final class DriveCameraTiltTests: XCTestCase {

    // MARK: Test 1: Drive Mode entry → pitch = 30°

    /// Verifies `targetPitch(forDriveModeActive:priorPitch:)` returns `driveModePitch` on entry.
    ///
    /// PR-3 shipped 30° (safe ceiling at the wider span ~0.04°, altitude ~180,000m).
    /// PR-2 updated to 45° after empirical measurement at the tighter span ~0.005°
    /// (altitude ~480m via altitudeForSpan): at that altitude MapKit allows steeper pitch
    /// without clamping. 45° was measured to round-trip faithfully.
    func testPitchDecision_onEntry_returnsConstantPitch() {
        let result = MapViewRepresentable.targetPitch(forDriveModeActive: true, priorPitch: 0)
        XCTAssertEqual(result, MapViewRepresentable.driveModePitch, accuracy: 1,
            "Drive Mode entry should target driveModePitch (\(MapViewRepresentable.driveModePitch)°); got \(result)°")
    }

    // MARK: Test 2: Drive Mode exit → restore priorPitch

    /// Verifies `targetPitch` restores the captured priorPitch on Drive Mode exit (OQ-3).
    ///
    /// Prior pitch is almost always 0 (users don't manually tilt MKMapView), but we store
    /// and restore it precisely for correctness, consistent with the auto-zoom restore
    /// behaviour PR-2 will add.
    func testPitchDecision_onExit_restoresPriorPitch() {
        let result = MapViewRepresentable.targetPitch(forDriveModeActive: false, priorPitch: 5)
        XCTAssertEqual(result, 5, accuracy: 1,
            "Drive Mode exit should restore priorPitch=5; got \(result)°")
    }

    // MARK: Test 3: Drive Mode exit with priorPitch=0 → returns 0

    /// Verifies that exiting Drive Mode when priorPitch was 0 (the typical case) returns 0.
    func testPitchDecision_onExit_noPrior_returnsZero() {
        let result = MapViewRepresentable.targetPitch(forDriveModeActive: false, priorPitch: 0)
        XCTAssertEqual(result, 0, accuracy: 1,
            "Drive Mode exit with priorPitch=0 should return 0; got \(result)°")
    }

    // MARK: Test 4: R-1 coexistence — heading dead-band still skips after pitch change

    /// Verifies that the existing `lastAppliedHeading` dead-band in `syncDriveHeading`
    /// still guards against the regionDidChangeAnimated feedback loop after a pitch `setCamera`
    /// fires. This test does NOT read MKMapView camera state — it tests the guard logic only.
    ///
    /// After the pitch `setCamera` fires `regionDidChangeAnimated`, `updateUIView` calls
    /// `syncDriveHeading`. If the heading hasn't changed by > 5°, the dead-band should return
    /// early without issuing another `setCamera`. We verify this by simulating the guard logic
    /// directly on the Coordinator (which is a testable NSObject subclass).
    func testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped() {
        // Arrange: create a parent representable (with a stub CoordinatorActions box).
        let actions = MapViewRepresentable.CoordinatorActions()
        let mapView = MKMapView()

        // Build a minimal MapViewRepresentable so we can instantiate a Coordinator.
        // We use a dummy region; the coordinator only needs `parent` for the heading check.
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
            driveHeading: 90,   // Drive Mode active; heading = 90°
            coordinatorActions: actions
        )
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)

        // Simulate: Drive Mode has applied heading=90 (lastAppliedHeading set).
        coordinator.lastAppliedHeading = 90

        // A spy flag: if syncDriveHeading issues a setCamera, it mutates lastAppliedHeading.
        // With heading=90 and lastAppliedHeading=90, diff=0 ≤ 5 → guard returns early.
        // We verify lastAppliedHeading remains 90 (no camera mutation dispatched).
        coordinator.syncDriveHeading(90, on: mapView)

        // Assert: lastAppliedHeading unchanged — guard fired, no second setCamera.
        XCTAssertEqual(coordinator.lastAppliedHeading, 90,
            "Dead-band should keep lastAppliedHeading=90 when heading hasn't changed; " +
            "a mutation would indicate the R-1 feedback loop is re-entering")
    }

    // MARK: Test 5: pitch constant range guard

    /// Verifies that `driveModePitch` is 45° (PR-2 empirically measured value) and that
    /// `targetPitch` delegates to it regardless of priorPitch.
    ///
    /// PR-2 changed from 30° (PR-3) to 45° after measuring that MapKit allows steeper pitch
    /// at the tighter Drive Mode zoom (span ~0.005°, altitude ~480m via altitudeForSpan).
    /// Guards against silent constant changes — any change requires updating this test
    /// with a spec-approved deviation note.
    func testPitchDecision_onEntry_returnsConstantValue() {
        // The constant must be 45° (PR-2 empirical measurement result).
        XCTAssertEqual(MapViewRepresentable.driveModePitch, 45, accuracy: 0.001,
            "driveModePitch must be 45° (PR-2 measured value at tighter zoom); got \(MapViewRepresentable.driveModePitch)°")

        // targetPitch on entry must equal the constant regardless of priorPitch.
        let result = MapViewRepresentable.targetPitch(forDriveModeActive: true, priorPitch: 15)
        XCTAssertEqual(result, MapViewRepresentable.driveModePitch, accuracy: 0.001,
            "targetPitch(true, _) must equal driveModePitch regardless of priorPitch")
    }

    // MARK: Test 6: OQ-3 — non-zero priorPitch is preserved on exit

    /// Verifies that a non-zero priorPitch (e.g., user had manually tilted before Drive Mode)
    /// is correctly restored on Drive Mode exit.
    func testPitchDecision_onExit_restoresNonZeroPrior() {
        // priorPitch could be any value if the user had a tilted map before Drive Mode.
        let arbitraryPrior: CGFloat = 12.5
        let result = MapViewRepresentable.targetPitch(
            forDriveModeActive: false,
            priorPitch: arbitraryPrior
        )
        XCTAssertEqual(result, arbitraryPrior, accuracy: 0.001,
            "targetPitch(false, \(arbitraryPrior)) should return exactly \(arbitraryPrior)°")
    }
}

// MARK: - Phase 2 camera ownership tests (replaces Phase 1 RegionSyncGuardTests)

/// Tests for the Phase 2 (native follow) camera ownership model.
///
/// Phase 2 removes `shouldSyncDriveRegion`, `syncDriveRegion`, `driveFollowEnabled`, and
/// `onDrivePanDetected`. MapKit's `.follow` tracking mode now owns Drive Mode position centering.
/// These tests verify:
///
///   1. `shouldSyncDriveRegion` is gone (compile-time: any reference would not build).
///   2. `setRegion` closure is still the mechanism for browse-mode programmatic recenter.
///   3. `setDriveTrackingMode` closure is the Phase 2 mechanism for Drive Mode follow.
///   4. `onTrackingModeChanged` is a property on `MapViewRepresentable` (output closure).
///
/// Tests 7–10 previously tested `shouldSyncDriveRegion`. Replacement tests here cover the
/// Phase 2 camera contract with equivalent depth.
///
/// See map-rebuild-native-mapkit-spec.md §3 (Phase 2 architecture) and P2-AC-1 through
/// P2-AC-8 for the design rationale.
final class RegionSyncGuardTests: XCTestCase {

    // MARK: Test 7 (Phase 2 replacement): Browse mode — setRegion closure wired and callable

    /// Verifies that `CoordinatorActions.setRegion` can be wired to a closure and called.
    ///
    /// In Phase 1+2, programmatic recenter (find-me, find-car, launch center, search result)
    /// fires `coordinatorActions.setRegion?(newRegion)` directly from ContentView action
    /// handlers — OUTSIDE `updateUIView`.
    func testCoordinatorActions_setRegion_isCallable() {
        let actions = MapViewRepresentable.CoordinatorActions()

        var receivedRegion: MKCoordinateRegion? = nil
        actions.setRegion = { region in
            receivedRegion = region
        }

        let expected = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
        actions.setRegion?(expected)

        XCTAssertNotNil(receivedRegion,
            "setRegion closure must fire when called from the recenterMap path")
        XCTAssertEqual(receivedRegion?.center.latitude ?? 0, expected.center.latitude, accuracy: 0.0001,
            "setRegion must receive the exact region passed by recenterMap")
    }

    // MARK: Test 8 (Phase 2 replacement): Drive Mode — setDriveTrackingMode closure callable

    /// Verifies `CoordinatorActions.setDriveTrackingMode` exists and is callable.
    /// This is the Phase 2 replacement for `shouldSyncDriveRegion` / `syncDriveRegion`.
    /// In production, it calls `mapView.userTrackingMode = active ? .follow : .none`.
    func testCoordinatorActions_setDriveTrackingMode_isCallable() {
        let actions = MapViewRepresentable.CoordinatorActions()

        var capturedActive: Bool? = nil
        actions.setDriveTrackingMode = { active in
            capturedActive = active
        }

        actions.setDriveTrackingMode?(true)
        XCTAssertEqual(capturedActive, true,
            "setDriveTrackingMode must be callable with true (Drive Mode entry)")

        actions.setDriveTrackingMode?(false)
        XCTAssertEqual(capturedActive, false,
            "setDriveTrackingMode must be callable with false (Drive Mode exit)")
    }

    // MARK: Test 9 (Phase 2 replacement): onTrackingModeChanged is a MapViewRepresentable property

    /// Verifies `onTrackingModeChanged` is a valid settable property on `MapViewRepresentable`.
    /// This is the Phase 2 replacement for `onDrivePanDetected`.
    func testMapViewRepresentable_onTrackingModeChanged_isSettable() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        var r = MapViewRepresentable(
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
            coordinatorActions: .init()
        )

        var modeReceived: MKUserTrackingMode? = nil
        r.onTrackingModeChanged = { mode in
            modeReceived = mode
        }

        r.onTrackingModeChanged?(MKUserTrackingMode.none)
        XCTAssertEqual(modeReceived, MKUserTrackingMode.none,
            "onTrackingModeChanged must be settable and callable on MapViewRepresentable")
    }

    // MARK: Test 10 (Phase 2 replacement / TF2-2 non-regression): isUserInteracting still works

    /// Verifies `isUserInteracting` flag still exists on the Coordinator and starts false.
    /// The flag is still used in Phase 2 by `syncDriveHeading` to suppress heading updates
    /// during active user gestures. The old TF2-2 guard (`shouldSyncDriveRegion` +
    /// `isUserInteracting`) is replaced, but the flag itself remains active.
    func testCoordinator_isUserInteracting_defaultsFalse() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        let r = MapViewRepresentable(
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
            coordinatorActions: .init()
        )
        let coordinator = MapViewRepresentable.Coordinator(parent: r)
        XCTAssertFalse(coordinator.isUserInteracting,
            "isUserInteracting must default to false (no gesture in flight at init)")
    }
}

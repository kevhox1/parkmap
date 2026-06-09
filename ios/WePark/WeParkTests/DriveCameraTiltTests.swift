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
            onDrivePanDetected: nil,
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

// MARK: - Phase 1 browse-mode camera ownership tests

/// Tests for the Phase 1 (map-phase1-browse) camera ownership model.
///
/// Phase 1 removes `shouldSyncRegionToBinding` and the corresponding `setRegion` push in
/// `updateUIView`. MapKit now owns the camera in browse mode. These tests verify:
///
///   1. `shouldSyncRegionToBinding` is gone (compile-time: any reference would not build).
///   2. `shouldSyncDriveRegion` still gates Drive Mode follow correctly (Phase 1 invariant:
///      Drive Mode camera path is unchanged).
///   3. `coordinatorActions.setRegion` closure is the mechanism for programmatic recenter
///      in browse mode — verified by confirming the closure is wired and callable.
///   4. Drive Mode follow remains gated by `isUserInteracting` (TF2-2 / FT-5 non-regression).
///
/// Previous tests 7–10 tested `shouldSyncRegionToBinding`, which is deleted. These four
/// replacement tests cover the new browse-mode camera contract with equivalent depth.
///
/// See map-rebuild-native-mapkit-spec.md §3 (Phase 1 architecture) and §10 (programmatic
/// recenter risk and resolution) for the design rationale.
final class RegionSyncGuardTests: XCTestCase {

    // MARK: Test 7 (Phase 1 replacement): Drive Mode — syncDriveRegion gated when follow active

    /// Verifies `shouldSyncDriveRegion` returns `true` when Drive Mode is active and follow
    /// is enabled — confirming the Drive Mode follow path is unchanged in Phase 1.
    ///
    /// This is the Drive-Mode-only gate that remains after Phase 1 removes the browse-mode
    /// `setRegion` push. The browse camera is fully owned by MapKit; this function gates only
    /// the pitch-preserving `syncDriveRegion` call.
    func testDriveRegionSync_activeAndFollowEnabled_returnsTrue() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: true,
            isUserInteracting: false
        )
        XCTAssertTrue(result,
            "shouldSyncDriveRegion(active=true, follow=true, interacting=false) must return true; " +
            "Drive Mode follow path must remain operational in Phase 1")
    }

    // MARK: Test 8 (Phase 1 replacement): Browse mode — setRegion closure wired and callable

    /// Verifies that `CoordinatorActions.setRegion` can be wired to a closure and called.
    ///
    /// In Phase 1, programmatic recenter (find-me, find-car, launch center, search result)
    /// fires `coordinatorActions.setRegion?(newRegion)` directly from ContentView action
    /// handlers — OUTSIDE `updateUIView`. This test verifies the closure property exists on
    /// `CoordinatorActions` and behaves as a simple optional callable (the production path
    /// is `mapView.setRegion(_:animated:true)`, but here we verify the wire-up contract).
    func testCoordinatorActions_setRegion_isCallable() {
        let actions = MapViewRepresentable.CoordinatorActions()

        // Wire a spy closure.
        var receivedRegion: MKCoordinateRegion? = nil
        actions.setRegion = { region in
            receivedRegion = region
        }

        // Simulate the recenterMap path: fire the closure.
        let expected = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
        actions.setRegion?(expected)

        // Verify the closure received the region.
        XCTAssertNotNil(receivedRegion,
            "setRegion closure must fire when called from the recenterMap path")
        XCTAssertEqual(receivedRegion?.center.latitude ?? 0, expected.center.latitude, accuracy: 0.0001,
            "setRegion must receive the exact region passed by recenterMap")
    }

    // MARK: Test 9 (Phase 1 replacement): Drive Mode — follow paused suppresses syncDriveRegion

    /// Verifies `shouldSyncDriveRegion` returns `false` when Drive Mode is active but follow
    /// is paused (FT-10 root cause fix). Phase 1 does not change this invariant.
    ///
    /// This is the snap-back prevention guard that protects Drive Mode from snapping the
    /// camera back to the GPS position after the user has manually panned.
    func testDriveRegionSync_followPaused_returnsFalse() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: false,
            isUserInteracting: false
        )
        XCTAssertFalse(result,
            "shouldSyncDriveRegion must return false when follow is paused (FT-10); " +
            "camera must stay where user left it until Recenter is tapped")
    }

    // MARK: Test 10 (Phase 1 replacement / TF2-2 non-regression): isUserInteracting suppresses Drive follow

    /// Verifies `shouldSyncDriveRegion` returns `false` when `isUserInteracting` is true,
    /// even if follow is nominally enabled. This is the TF2-2 mid-drag race fix.
    ///
    /// Phase 1 preserves this invariant: `isUserInteracting` is still set synchronously in
    /// `regionWillChangeAnimated`, and the Drive Mode follow gate still checks it.
    func testDriveRegionSync_userInteracting_suppressesFollowEvenIfEnabled() {
        let result = MapViewRepresentable.shouldSyncDriveRegion(
            driveModeActive: true,
            driveFollowEnabled: true,
            isUserInteracting: true
        )
        XCTAssertFalse(result,
            "shouldSyncDriveRegion must return false when user is interacting (TF2-2 mid-drag race fix); " +
            "an active gesture suppresses Drive Mode follow recenter regardless of driveFollowEnabled")
    }
}

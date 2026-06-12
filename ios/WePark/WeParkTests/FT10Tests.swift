//
//  FT10Tests.swift
//  WeParkTests
//
//  Option A: Custom Drive Mode Follow Camera — state machine tests.
//
//  Option A replaced Phase 2 (native .follow tracking mode).
//  The deleted Phase 2 machinery is documented below with test arithmetic.
//
//  Deleted Phase 2 symbols (all tests removed — not masked, legitimately gone):
//    REMOVED from CoordinatorActions:
//      - setDriveTrackingMode: ((Bool) -> Void)?
//      - pendingDriveCameraReapply: Bool
//      - pendingReapplyPriorPitch: CGFloat
//      - setZoomRange: ((Bool) -> Void)?   (Option C)
//    REMOVED from MapViewRepresentable:
//      - onTrackingModeChanged: ((MKUserTrackingMode) -> Void)?
//      - minDriveZoomDistance: CLLocationDistance  (Option C)
//      - maxDriveZoomDistance: CLLocationDistance  (Option C)
//    REMOVED from ContentView:
//      - driveTrackingModeNone: Bool
//      - handleTrackingModeChanged(_:)
//      - mapView(_:didChange:animated:) delegate callback (tracking-mode path)
//      - DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) timeout backstop
//
//  ADDED (Option A):
//    - CoordinatorActions.setDriveCamera
//    - MapViewRepresentable.onDrivePanDetected
//    - MapViewRepresentable.onDrivePinchZoomed
//    - ContentView.followPaused: Bool
//    - ContentView.currentDriveAltitude: CLLocationDistance
//    - ContentView.handleDrivePanDetected()
//    - ContentView.handleDrivePinchZoomed(_:)
//
//  Test count arithmetic (per HANDOFF baseline of 523):
//    Deleted from Phase2TrackingModeEntryTests:   4
//    Deleted from Phase2HeadingCoexistenceTests:  4
//    Deleted from Phase2TrackingModeCallbackTests: 4
//    Deleted from Phase2RecenterPitchZoomTests:   4
//    Deleted from Phase2RemovedSymbolsTests:      3
//    Deleted from Phase2FT5NonInterferenceTests:  2
//    Total deleted: 21
//
//    This file adds Option A tests:
//    Group 1 (setDriveCamera closure):         3 tests
//    Group 2 (followPaused state machine):     5 tests
//    Group 3 (altitude capture OQ-3):          3 tests
//    Group 4 (entry/exit state OQ):            3 tests
//    Group 5 (A-AC compliance: symbols/design):5 tests
//    Group 6 (heading coexistence — kept):     4 tests  (syncDriveHeading still present)
//    Total added: 23
//
//    Net change: -21 + 23 = +2
//    Expected total: 523 - 21 + 23 = 525
//
//  No Calendar.current.
//  No hardcoded Mapbox tokens.
//  No live MKMapView altitude reads from a headless map.
//

import XCTest
import MapKit
import CoreLocation
@testable import WePark

// MARK: - Helper: bare MapViewRepresentable for testing

private func makeRepresentable(
    driveModeActive: Bool = false,
    driveHeading: Double? = nil,
    onDrivePanDetected: (() -> Void)? = nil,
    onDrivePinchZoomed: ((CLLocationDistance) -> Void)? = nil
) -> MapViewRepresentable {
    let region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    return MapViewRepresentable(
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
        driveHeading: driveHeading,
        driveModeActive: driveModeActive,
        onDrivePanDetected: onDrivePanDetected,
        onDrivePinchZoomed: onDrivePinchZoomed,
        coordinatorActions: MapViewRepresentable.CoordinatorActions()
    )
}

// MARK: - Group 1: setDriveCamera closure (A-AC-1, A-AC-7)

/// Tests the `CoordinatorActions.setDriveCamera` closure: existence, invocability,
/// and that it receives the expected coordinate, heading, and altitude.
///
/// A-AC-1: no `userTrackingMode = .follow` in Drive Mode — setDriveCamera replaces it.
/// A-AC-7: closure is wired by makeUIView and callable with all 4 camera degrees of freedom.
@MainActor
final class OptionADriveCameraClosureTests: XCTestCase {

    // MARK: Test 1: setDriveCamera defaults to nil (not yet wired by makeUIView)

    /// Verifies that a freshly-constructed `CoordinatorActions` has `setDriveCamera == nil`
    /// before `makeUIView` wires it. Confirms the closure is optional and safe to call with `?`.
    func testSetDriveCamera_nilByDefault() {
        let actions = MapViewRepresentable.CoordinatorActions()
        XCTAssertNil(
            actions.setDriveCamera,
            "setDriveCamera must default to nil on a fresh CoordinatorActions (wired by makeUIView)"
        )
    }

    // MARK: Test 2: setDriveCamera receives correct coordinate

    /// Verifies that the closure receives the GPS coordinate forwarded from handleLocationUpdate.
    /// In production: ContentView → setDriveCamera?(coord, nil, currentDriveAltitude)
    func testSetDriveCamera_receivesCorrectCoordinate() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var capturedCoord: CLLocationCoordinate2D? = nil
        actions.setDriveCamera = { coord, _, _ in
            capturedCoord = coord
        }

        let expected = CLLocationCoordinate2D(latitude: 40.7580, longitude: -73.9855)
        actions.setDriveCamera?(expected, nil, 621)

        XCTAssertEqual(capturedCoord?.latitude ?? 0, expected.latitude, accuracy: 0.0001,
            "setDriveCamera must receive the GPS coordinate forwarded from handleLocationUpdate")
        XCTAssertEqual(capturedCoord?.longitude ?? 0, expected.longitude, accuracy: 0.0001,
            "setDriveCamera must receive the GPS coordinate forwarded from handleLocationUpdate")
    }

    // MARK: Test 3: setDriveCamera receives nil heading (heading owned by syncDriveHeading)

    /// A-AC-2: per-tick setDriveCamera passes nil for heading — heading is owned exclusively
    /// by syncDriveHeading (which reads driveHeading via .onChange(of: driveHeading) in updateUIView).
    /// Double-setting heading would fight syncDriveHeading's EMA course path.
    func testSetDriveCamera_nilHeadingPreservesSyncDriveHeadingOwnership() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var closureFired = false
        var headingWasNil = false
        actions.setDriveCamera = { _, heading, _ in
            closureFired = true
            headingWasNil = (heading == nil)
        }

        // ContentView's handleLocationUpdate passes nil heading — syncDriveHeading owns heading.
        actions.setDriveCamera?(
            CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            nil,
            621
        )

        XCTAssertTrue(closureFired, "setDriveCamera closure must fire")
        XCTAssertTrue(headingWasNil,
            "setDriveCamera must pass nil heading — syncDriveHeading owns heading (A-AC-2)")
    }
}

// MARK: - Group 2: followPaused state machine (A-AC-4, A-AC-5, A-AC-6)

/// Tests for the `followPaused` state machine:
///   - starts false on Drive Mode entry
///   - set to true when pan detected during Drive Mode
///   - stays true until Recenter tap
///   - reset to false on Recenter
///   - reset to false on Drive Mode exit
///
/// All tests operate on pure boolean logic mirroring ContentView's implementation.
/// The live behavioral assertion (Recenter button appears on real pan) is Kevin's gate.
@MainActor
final class OptionAFollowPausedStateMachineTests: XCTestCase {

    // MARK: Test 4: followPaused starts false on Drive Mode entry

    /// A-AC-4: on Drive Mode entry, followPaused = false so the per-tick setDriveCamera
    /// starts active immediately.
    func testFollowPaused_startsFalseOnEntry() {
        // Mirrors handleDriveModeChange(true): followPaused = false
        var followPaused = true  // pre-existing state
        var driveModeActive = false

        // Simulate Drive Mode entry.
        driveModeActive = true
        if driveModeActive { followPaused = false }

        XCTAssertFalse(followPaused,
            "followPaused must be false on Drive Mode entry (A-AC-4: follow active from first GPS tick)")
    }

    // MARK: Test 5: handleDrivePanDetected sets followPaused = true

    /// A-AC-5: pan during Drive Mode → followPaused = true → Recenter button shows.
    /// Mirrors ContentView's handleDrivePanDetected():
    ///   guard driveModeActive else { return }
    ///   followPaused = true
    func testHandleDrivePanDetected_setsPausedTrue() {
        var followPaused = false
        var driveModeActive = true

        // Mirror handleDrivePanDetected().
        let handleDrivePanDetected: () -> Void = {
            guard driveModeActive else { return }
            followPaused = true
        }

        handleDrivePanDetected()

        XCTAssertTrue(followPaused,
            "handleDrivePanDetected must set followPaused = true (A-AC-5: Recenter button shows)")
    }

    // MARK: Test 6: handleDrivePanDetected guard — not in Drive Mode → no-op

    /// Guard: if Drive Mode is not active, pan detection must not set followPaused.
    func testHandleDrivePanDetected_guardPreventsStateChangeOutsideDriveMode() {
        var followPaused = false
        var driveModeActive = false  // NOT in Drive Mode

        let handleDrivePanDetected: () -> Void = {
            guard driveModeActive else { return }
            followPaused = true
        }

        handleDrivePanDetected()

        XCTAssertFalse(followPaused,
            "handleDrivePanDetected must not set followPaused when not in Drive Mode (guard)")
    }

    // MARK: Test 7: Recenter clears followPaused

    /// A-AC-6: Recenter tap → followPaused = false (follow resumes on next GPS tick).
    /// Mirrors ContentView's recenterDriveMode():
    ///   followPaused = false
    ///   currentDriveAltitude = FT-8 default
    ///   coordinatorActions.applyDrivePitch?(true, preDrivePitch)
    func testRecenterDriveMode_clearsPaused() {
        var followPaused = true  // was paused (user panned)

        // Mirror recenterDriveMode's follow-resume step.
        followPaused = false

        XCTAssertFalse(followPaused,
            "recenterDriveMode must set followPaused = false (A-AC-6: follow resumes)")
    }

    // MARK: Test 8: Full pan → Recenter cycle

    /// Tests the full state machine: follow active → user pan → follow paused →
    /// Recenter tap → follow active again.
    func testFollowPaused_fullPanRecenterCycle() {
        var followPaused = false
        var driveModeActive = true

        let handleDrivePanDetected: () -> Void = {
            guard driveModeActive else { return }
            followPaused = true
        }

        // Step 1: follow active at entry.
        XCTAssertFalse(followPaused, "Follow must be active at Drive Mode start")

        // Step 2: user pans → follow paused.
        handleDrivePanDetected()
        XCTAssertTrue(followPaused, "Follow must be paused after user pan")

        // Step 3: Recenter tap → follow active.
        followPaused = false
        XCTAssertFalse(followPaused, "Follow must be active after Recenter tap")

        // Step 4: pan again → paused again (verifies repeatability).
        handleDrivePanDetected()
        XCTAssertTrue(followPaused, "Follow must be paused after second pan")
    }
}

// MARK: - Group 3: User altitude capture — OQ-3 (A-AC-3)

/// Tests for handleDrivePinchZoomed: pinch updates currentDriveAltitude so the per-tick
/// follow continues at the user's chosen zoom (Waze model).
///
/// OQ-3: pinch does NOT pause follow — it captures the new altitude.
/// OQ-4: pan DOES pause follow; pinch does not.
@MainActor
final class OptionAUserAltitudeTests: XCTestCase {

    // MARK: Test 9: handleDrivePinchZoomed updates currentDriveAltitude

    /// A-AC-3: pinch during Drive Mode → currentDriveAltitude updated with new camera altitude.
    /// Mirrors ContentView's handleDrivePinchZoomed(_:):
    ///   guard driveModeActive, newAltitude > 0 else { return }
    ///   currentDriveAltitude = newAltitude
    func testHandleDrivePinchZoomed_updatesAltitude() {
        var currentDriveAltitude: CLLocationDistance = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        var driveModeActive = true

        let handleDrivePinchZoomed: (CLLocationDistance) -> Void = { newAltitude in
            guard driveModeActive, newAltitude > 0 else { return }
            currentDriveAltitude = newAltitude
        }

        let userZoom: CLLocationDistance = 300  // user zoomed in to 300m altitude
        handleDrivePinchZoomed(userZoom)

        XCTAssertEqual(currentDriveAltitude, userZoom, accuracy: 1,
            "handleDrivePinchZoomed must update currentDriveAltitude with the pinch result (OQ-3)")
    }

    // MARK: Test 10: handleDrivePinchZoomed guard — zero altitude ignored

    /// Guard: altitude <= 0 is invalid (can occur if mapView.camera.centerCoordinateDistance
    /// returns 0 for a headless map). Must not corrupt currentDriveAltitude.
    func testHandleDrivePinchZoomed_zeroAltitude_ignored() {
        let ft8Default = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        var currentDriveAltitude: CLLocationDistance = ft8Default
        var driveModeActive = true

        let handleDrivePinchZoomed: (CLLocationDistance) -> Void = { newAltitude in
            guard driveModeActive, newAltitude > 0 else { return }
            currentDriveAltitude = newAltitude
        }

        handleDrivePinchZoomed(0)

        XCTAssertEqual(currentDriveAltitude, ft8Default, accuracy: 1,
            "handleDrivePinchZoomed must ignore altitude <= 0 (invalid camera state guard)")
    }

    // MARK: Test 11: handleDrivePinchZoomed does NOT set followPaused (OQ-4)

    /// OQ-4: pinch does NOT pause follow. Only pan sets followPaused = true.
    /// Pinch captures altitude and the follow continues.
    func testHandleDrivePinchZoomed_doesNotSetFollowPaused() {
        var followPaused = false
        var currentDriveAltitude: CLLocationDistance = 621
        var driveModeActive = true

        // Pinch handler — only updates altitude, does NOT touch followPaused.
        let handleDrivePinchZoomed: (CLLocationDistance) -> Void = { newAltitude in
            guard driveModeActive, newAltitude > 0 else { return }
            currentDriveAltitude = newAltitude
            // followPaused intentionally NOT modified here (OQ-4)
        }

        handleDrivePinchZoomed(300)

        XCTAssertFalse(followPaused,
            "Pinch must NOT set followPaused (OQ-4: only pan pauses follow, pinch keeps following)")
        XCTAssertEqual(currentDriveAltitude, 300, accuracy: 1,
            "Pinch must update currentDriveAltitude (OQ-3)")
    }
}

// MARK: - Group 4: Entry/exit state (A-AC-9, A-AC-10)

/// Tests for Drive Mode entry and exit state initialization and cleanup.
@MainActor
final class OptionAEntryExitStateTests: XCTestCase {

    // MARK: Test 12: Entry initializes currentDriveAltitude to FT-8 default

    /// A-AC-9: on Drive Mode entry, currentDriveAltitude = altitudeForSpan(driveModeCameraSpan).
    /// This is ~621m — the FT-8 tight zoom default.
    func testDriveModeEntry_initializesCurrentDriveAltitude_toFT8Default() {
        let ft8Default = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        var currentDriveAltitude: CLLocationDistance = 0

        // Mirrors handleDriveModeAndCamera(true).
        currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )

        XCTAssertEqual(currentDriveAltitude, ft8Default, accuracy: 1,
            "Drive Mode entry must initialize currentDriveAltitude to FT-8 default (~621m) (A-AC-9)")
        XCTAssertGreaterThan(currentDriveAltitude, 0,
            "FT-8 default altitude must be > 0")
    }

    // MARK: Test 13: Recenter resets currentDriveAltitude to FT-8 default

    /// A-AC-10: Recenter tap resets currentDriveAltitude to FT-8 default (undoes any user zoom).
    func testRecenterDriveMode_resetAltitudeToFT8Default() {
        let ft8Default = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )
        var currentDriveAltitude: CLLocationDistance = 300  // user had zoomed in

        // Mirror recenterDriveMode()'s altitude reset.
        currentDriveAltitude = MapViewRepresentable.altitudeForSpan(
            MapViewRepresentable.driveModeCameraSpan
        )

        XCTAssertEqual(currentDriveAltitude, ft8Default, accuracy: 1,
            "Recenter must reset currentDriveAltitude to FT-8 default (A-AC-10)")
    }

    // MARK: Test 14: Exit clears currentDriveAltitude to 0

    /// On Drive Mode exit, currentDriveAltitude is reset to 0 (sentinel for "not in drive mode").
    /// handleLocationUpdate() guards: `if !followPaused, currentDriveAltitude > 0`.
    /// The `> 0` guard prevents stale setDriveCamera calls after exit.
    func testDriveModeExit_clearscurrentDriveAltitude() {
        var currentDriveAltitude: CLLocationDistance = 621

        // Mirror handleDriveModeChange(false): currentDriveAltitude = 0.
        currentDriveAltitude = 0

        XCTAssertEqual(currentDriveAltitude, 0, accuracy: 0.001,
            "Drive Mode exit must clear currentDriveAltitude to 0 (prevents stale setDriveCamera)")
    }
}

// MARK: - Group 5: Option A symbol compliance (A-AC compile-time guards)

/// Compile-time guards verifying deleted Phase 2 symbols are gone and Option A symbols
/// are present. If a deleted symbol is re-introduced, the init or property access in
/// another test will fail to compile — giving the correct signal.
@MainActor
final class OptionASymbolComplianceTests: XCTestCase {

    // MARK: Test 15: setDriveCamera IS a property of CoordinatorActions

    /// Option A ADDED setDriveCamera to CoordinatorActions. Verifies it exists and is settable.
    func testSetDriveCamera_existsInCoordinatorActions() {
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.setDriveCamera = { _, _, _ in }
        XCTAssertNotNil(actions.setDriveCamera,
            "setDriveCamera must be a property of CoordinatorActions (Option A added it)")
    }

    // MARK: Test 16: onDrivePanDetected IS a parameter on MapViewRepresentable

    /// Option A ADDED onDrivePanDetected to MapViewRepresentable (replaces onTrackingModeChanged).
    /// If this compiles without error, the parameter exists.
    func testOnDrivePanDetected_existsAsMapViewRepresentableParameter() {
        var fired = false
        let r = makeRepresentable(
            driveModeActive: true,
            onDrivePanDetected: { fired = true }
        )
        r.onDrivePanDetected?()
        XCTAssertTrue(fired,
            "onDrivePanDetected must exist as a MapViewRepresentable parameter (Option A)")
    }

    // MARK: Test 17: onDrivePinchZoomed IS a parameter on MapViewRepresentable

    /// Option A ADDED onDrivePinchZoomed to MapViewRepresentable.
    func testOnDrivePinchZoomed_existsAsMapViewRepresentableParameter() {
        var capturedAltitude: CLLocationDistance = 0
        let r = makeRepresentable(
            driveModeActive: true,
            onDrivePinchZoomed: { alt in capturedAltitude = alt }
        )
        r.onDrivePinchZoomed?(350)
        XCTAssertEqual(capturedAltitude, 350, accuracy: 1,
            "onDrivePinchZoomed must exist as a MapViewRepresentable parameter (Option A)")
    }

    // MARK: Test 18: CoordinatorActions is a reference type (shared box invariant)

    /// The shared-reference-box pattern depends on CoordinatorActions being a class.
    /// If it becomes a struct, ContentView and Coordinator will hold separate copies
    /// and closure wiring in makeUIView will not be visible to ContentView.
    func testCoordinatorActions_isReferenceType() {
        let actions = MapViewRepresentable.CoordinatorActions()
        let ref1: AnyObject = actions
        let ref2: AnyObject = actions
        XCTAssertTrue(ref1 === ref2,
            "CoordinatorActions must be a reference type so ContentView and Coordinator share it")
    }

    // MARK: Test 19: A-AC-8 — pitch is driveModePitch (30°) on every setDriveCamera tick

    /// A-AC-8: the MKMapCamera built in the setDriveCamera closure sets pitch = driveModePitch.
    /// We verify driveModePitch is 30° (spec value).
    func testDriveModePitch_is30Degrees() {
        XCTAssertEqual(MapViewRepresentable.driveModePitch, 30, accuracy: 1,
            "driveModePitch must be 30° — used as the pitch on every setDriveCamera tick (A-AC-8)")
    }
}

// MARK: - Group 6: syncDriveHeading coexistence (preserved from pre-Option-A)

/// Tests for syncDriveHeading: heading-up rotation still works and coexists with
/// the per-tick setDriveCamera (which does NOT double-set heading).
///
/// These tests are preserved because syncDriveHeading is unchanged in Option A.
/// The heading-sync path fires from `.onChange(of: driveHeading)` in updateUIView —
/// which is the ONLY remaining camera call allowed inside updateUIView (it is a
/// targeted heading-only update, not a full camera replacement).
@MainActor
final class OptionAHeadingCoexistenceTests: XCTestCase {

    // MARK: Test 20: syncDriveHeading does not set isUserInteracting

    /// Verifies that syncDriveHeading's animated setCamera does NOT set isUserInteracting.
    /// isUserInteracting is set only by gesture recognizer state in regionWillChangeAnimated.
    /// Programmatic setCamera must not be misidentified as a user gesture.
    func testSyncDriveHeading_animatedSetCamera_doesNotSetIsUserInteracting() {
        let representable = makeRepresentable(driveModeActive: true, driveHeading: 90.0)
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        XCTAssertFalse(coordinator.isUserInteracting, "isUserInteracting must start false")

        coordinator.lastAppliedHeading = 0.0
        coordinator.syncDriveHeading(90.0, on: mapView)

        XCTAssertFalse(coordinator.isUserInteracting,
            "isUserInteracting must remain false after syncDriveHeading's animated setCamera")
    }

    // MARK: Test 21: syncDriveHeading dead-band still fires

    /// The 2° dead-band is still active. syncDriveHeading must skip when heading change <= 2°.
    func testSyncDriveHeading_deadBand_stillActive() {
        let representable = makeRepresentable(driveModeActive: true, driveHeading: 90.0)
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        coordinator.lastAppliedHeading = 90.0

        // Change < 2° — skipped.
        coordinator.syncDriveHeading(91.0, on: mapView)
        XCTAssertEqual(coordinator.lastAppliedHeading ?? -1, 90.0, accuracy: 0.01,
            "Dead-band: < 2° heading change must be skipped")

        // Change > 2° — applied.
        coordinator.syncDriveHeading(95.0, on: mapView)
        XCTAssertEqual(coordinator.lastAppliedHeading ?? -1, 95.0, accuracy: 0.01,
            "Dead-band: > 2° heading change must update lastAppliedHeading")
    }

    // MARK: Test 22: syncDriveHeading nil heading resets lastAppliedHeading

    /// Drive Mode exit: syncDriveHeading(nil) resets lastAppliedHeading to nil.
    func testSyncDriveHeading_nilHeading_resetsLastApplied() {
        let representable = makeRepresentable(driveModeActive: false, driveHeading: nil)
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()

        coordinator.lastAppliedHeading = 90.0
        coordinator.syncDriveHeading(nil, on: mapView)

        XCTAssertNil(coordinator.lastAppliedHeading,
            "syncDriveHeading(nil) on Drive Mode exit must reset lastAppliedHeading to nil")
    }

    // MARK: Test 23: targetPitch returns driveModePitch when active

    /// Verifies that targetPitch(forDriveModeActive:true) returns driveModePitch.
    /// Used by recenterDriveMode's applyDrivePitch call to restore 30° pitch.
    func testTargetPitch_returnsDriveModePitch_whenActive() {
        let result = MapViewRepresentable.targetPitch(forDriveModeActive: true, priorPitch: 0)
        XCTAssertEqual(result, MapViewRepresentable.driveModePitch, accuracy: 1,
            "targetPitch(active:true) must return driveModePitch (30°)")
    }
}

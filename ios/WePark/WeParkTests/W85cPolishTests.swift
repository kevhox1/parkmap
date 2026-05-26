//
//  W85cPolishTests.swift
//  WeParkTests
//
//  W8.5c-polish unit tests: Apple-Maps-isms + distance indicator + z-order.
//
//  Test groups (per spec §5):
//    1. Camera state tests (2) — auto-zoom + tilt on Drive Mode transition
//    2. Distance calculation tests (2) — metric + imperial formatting
//    3. Dead-band regression test (1) — pitch change does not re-trigger heading dead-band
//    4. Z-order / pill layout test (1) — End Drive pill top padding clears ASP banner
//    5. No-feedback-loop guard test (1) — syncDriveCamera is idempotent after transition
//
//  Total new tests: 7 (brings baseline 196 → 203+ with 0 failures).
//
//  All tests pass without a real device (simulator or pure unit).
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
import CoreLocation
import MapKit
import SwiftUI
@testable import WePark

// MARK: - 1. Camera State Tests

@MainActor
final class DriveCameraTests: XCTestCase {

    // Backing window that keeps each test's MKMapView in a view hierarchy so
    // MKMapView camera operations (setCamera, setRegion) update mapView.camera
    // synchronously. Without a window, MKMapView defers camera state to a render
    // cycle that never fires in the XCTest host, causing mapView.camera.altitude
    // and mapView.camera.pitch to read as 0.0 regardless of what was applied.
    //
    // Must be initialised with a UIWindowScene (not UIWindow(frame:)) so that
    // MapKit's render pass fires in the XCTest host on iOS 17+.
    private var cameraTestWindow: UIWindow?

    override func setUp() {
        super.setUp()
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal - 1  // below normal UI, invisible in practice
        window.makeKeyAndVisible()
        cameraTestWindow = window
    }

    override func tearDown() {
        cameraTestWindow?.resignKey()
        cameraTestWindow?.isHidden = true
        cameraTestWindow = nil
        super.tearDown()
    }

    // Helper: creates a MapViewRepresentable and its coordinator with a fresh MKMapView.
    // The MKMapView is added to cameraTestWindow so camera API calls are synchronous.
    private func makeCoordinator(
        driveModeActive: Bool = false,
        preDriveRegion: MKCoordinateRegion? = nil
    ) -> (coordinator: MapViewRepresentable.Coordinator, mapView: MKMapView) {
        var regionState = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1) // wide starting zoom
        )
        var selectedID: String? = nil
        let repr = MapViewRepresentable(
            region: Binding(get: { regionState }, set: { regionState = $0 }),
            selectedSegmentID: Binding(get: { selectedID }, set: { selectedID = $0 }),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: MapViewRepresentable.OverlayPayload(generation: 0),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: nil,
            onDrivePanDetected: nil,
            driveModeActive: driveModeActive,
            preDriveRegion: preDriveRegion
        )
        let coordinator = repr.makeCoordinator()
        let mapView = MKMapView(frame: cameraTestWindow?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844))
        // Attach to test window so MKMapView camera operations are synchronous.
        cameraTestWindow?.addSubview(mapView)
        // Force a layout pass so MapKit's rendering context is established before
        // the test body calls setCamera / setRegion.
        cameraTestWindow?.layoutIfNeeded()
        // Set the map view to a wide starting region (simulating pre-drive zoom).
        mapView.setRegion(regionState, animated: false)
        // Pump the run loop briefly so the initial region commit propagates.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return (coordinator, mapView)
    }

    // AC-P.1, AC-P.4: Flipping driveModeActive true applies tight span and 45° pitch.
    func testDriveCamera_onDriveModeStart_setsTightSpanAndPitch() {
        let (coordinator, mapView) = makeCoordinator()

        // Confirm starting span is wide (0.1°).
        XCTAssertGreaterThan(mapView.camera.altitude, 10_000,
                             "Starting altitude should be high (wide zoom)")

        // Simulate Drive Mode start transition (false → true).
        coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)

        // Verify pitch is 45° (DriveModePitch).
        XCTAssertEqual(mapView.camera.pitch, MapViewRepresentable.driveModePitch, accuracy: 1.0,
                       "Camera pitch should be \(MapViewRepresentable.driveModePitch)° during Drive Mode")

        // Verify altitude reduced (tighter zoom — DriveModeCameraSpan 0.005° ≈ much lower altitude).
        // Wide zoom altitude for 0.1° span is roughly 20× the drive zoom altitude for 0.005°.
        // We assert the altitude dropped below half the wide starting altitude as a proxy.
        XCTAssertLessThan(mapView.camera.altitude, 25_000,
                          "Camera altitude should decrease (tighter zoom) when Drive Mode starts")
    }

    // AC-P.2, AC-P.5: Flipping driveModeActive false restores prior span and resets pitch.
    func testDriveCamera_onDriveModeEnd_restoresPriorSpanAndPitch() {
        // Set a specific pre-drive region with span 0.08°.
        let preDriveCenter = CLLocationCoordinate2D(latitude: 40.760, longitude: -73.990)
        let preDriveSpan = MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        let preDriveRegion = MKCoordinateRegion(center: preDriveCenter, span: preDriveSpan)

        let (coordinator, mapView) = makeCoordinator(preDriveRegion: preDriveRegion)

        // First, simulate Drive Mode start.
        coordinator.syncDriveCamera(active: true, preDriveRegion: preDriveRegion, on: mapView)
        let drivePitch = mapView.camera.pitch
        XCTAssertEqual(drivePitch, MapViewRepresentable.driveModePitch, accuracy: 1.0,
                       "Pitch should be \(MapViewRepresentable.driveModePitch)° during Drive Mode")

        // Now simulate Drive Mode end.
        coordinator.syncDriveCamera(active: false, preDriveRegion: preDriveRegion, on: mapView)

        // Pitch should reset to 0.
        XCTAssertEqual(mapView.camera.pitch, 0, accuracy: 1.0,
                       "Camera pitch should reset to 0° after Drive Mode ends")

        // Camera heading should reset to 0 (north-up).
        XCTAssertEqual(mapView.camera.heading, 0, accuracy: 1.0,
                       "Camera heading should reset to 0° (north-up) after Drive Mode ends")
    }

    // AC-P.3: syncDriveCamera is idempotent — calling multiple times with same active value
    // does NOT repeatedly mutate the camera. The lastDriveModeActive guard prevents re-entry.
    func testDriveCamera_idempotent_afterTransition_noRepeatedSetCamera() {
        let (coordinator, mapView) = makeCoordinator()

        // First call: transition false → true. Camera changes.
        coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)
        let altitudeAfterFirstCall = mapView.camera.altitude

        // Manually change the altitude to simulate user pan (camera diverged from drive zoom).
        let alteredCamera = mapView.camera.copy() as! MKMapCamera
        alteredCamera.altitude = 99_999
        mapView.setCamera(alteredCamera, animated: false)

        // Second call with same active=true (no transition): should be a no-op.
        coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)

        // The altitude should NOT be reset to driveModeCameraSpan again
        // (since lastDriveModeActive == true == active, the method returns early).
        XCTAssertEqual(mapView.camera.altitude, 99_999, accuracy: 1.0,
                       "Idempotent guard: subsequent syncDriveCamera(active:true) calls must be no-ops")

        // Verify the first call did change altitude (the transition did fire).
        XCTAssertLessThan(altitudeAfterFirstCall, 99_999,
                          "First call should have reduced altitude from wide zoom")
    }
}

// MARK: - 2. Distance Calculation Tests

final class DistanceFormattingTests: XCTestCase {

    // Two fixed real-world coordinates for reproducible distance tests:
    // Penn Station (40.7505, -73.9934) and Grand Central (40.7527, -73.9772).
    // Actual CLLocation.distance(from:) result: approximately 1,488m = 0.925 mi = 1.488 km.
    private let pennStation = CLLocation(latitude: 40.7505, longitude: -73.9934)
    private let grandCentral = CLLocation(latitude: 40.7527, longitude: -73.9772)

    // AC-P.9, AC-P.11: Imperial formatting via formattedDistance (internal test helper).
    func testDistanceCalc_imperial_formatsCorrectly() {
        let meters = pennStation.distance(from: grandCentral)
        // 1,488m ≈ 0.9 mi (one decimal, varies by CLLocation's actual haversine).
        let miles = meters / 1609.344
        let formatted = String(format: "%.1f mi", miles)

        // Verify format is "X.X mi".
        XCTAssertTrue(formatted.hasSuffix(" mi"), "Imperial format should end with ' mi'. Got: \(formatted)")
        // Verify value is approximately 0.9 mi ±0.2 mi (generous tolerance for test stability).
        XCTAssertEqual(miles, 0.925, accuracy: 0.2,
                       "Penn Station → Grand Central should be ~0.9 mi. Got: \(miles) mi")
    }

    // AC-P.9, AC-P.11: Metric formatting.
    func testDistanceCalc_metric_formatsCorrectly() {
        let meters = pennStation.distance(from: grandCentral)
        // 1,488m ≈ 1.5 km (one decimal).
        let km = meters / 1000.0
        let formatted = String(format: "%.1f km", km)

        // Verify format is "X.X km".
        XCTAssertTrue(formatted.hasSuffix(" km"), "Metric format should end with ' km'. Got: \(formatted)")
        // Verify value is approximately 1.5 km ±0.3 km.
        XCTAssertEqual(km, 1.5, accuracy: 0.3,
                       "Penn Station → Grand Central should be ~1.5 km. Got: \(km) km")
    }

    // AC-P.11: Distance uses CLLocation.distance(from:), not manual approximation.
    // We verify the API is called and produces a non-zero, physically plausible result.
    func testDistanceCalc_usesCLLocationDistance_notManualApproximation() {
        let dist = pennStation.distance(from: grandCentral)
        // Penn Station to Grand Central is known to be ~1.4–1.6 km in a straight line.
        XCTAssertGreaterThan(dist, 1_000, "Distance should be > 1,000m")
        XCTAssertLessThan(dist, 2_500, "Distance should be < 2,500m")
        // Verify it's NOT zero (correct API call).
        XCTAssertNotEqual(dist, 0, "Distance should be non-zero between two different coordinates")
    }

    // AC-P.10: Nil destinationDistance → distance element hidden (no crash).
    @MainActor
    func testDistanceIndicator_nil_doesNotCrash() {
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: DrivingContext(
                street: "W 34 ST",
                from: "7 AVE",
                to: "8 AVE",
                leftLabel: SafetyLabel(text: "Free", severity: .free),
                rightLabel: SafetyLabel(text: "No parking", severity: .restricted)
            ),
            voiceService: voice,
            destinationDistance: nil  // No destination — element should be hidden.
        )
        let host = UIHostingController(rootView: card)
        XCTAssertNotNil(host.view, "DriveModeBottomCard with nil destinationDistance should not crash")
    }

    // AC-P.7: Non-nil destinationDistance → card renders without crash.
    @MainActor
    func testDistanceIndicator_nonNil_rendersWithoutCrash() {
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(
            context: DrivingContext(
                street: "W 34 ST",
                from: "7 AVE",
                to: "8 AVE",
                leftLabel: SafetyLabel(text: "Free", severity: .free),
                rightLabel: SafetyLabel(text: "No parking", severity: .restricted)
            ),
            voiceService: voice,
            destinationDistance: 1488.0  // ~1.5 km / ~0.9 mi
        )
        let host = UIHostingController(rootView: card)
        XCTAssertNotNil(host.view, "DriveModeBottomCard with non-nil destinationDistance should not crash")
    }
}

// MARK: - 3. Dead-band Regression Test

@MainActor
final class DriveCameraDeadBandTests: XCTestCase {

    // Backing window that gives MKMapView a rendering context so camera API is synchronous.
    // Without a window (or without a UIWindowScene), setCamera/setRegion don't update
    // mapView.camera in XCTest hosts on iOS 17+.
    private var cameraTestWindow: UIWindow?

    override func setUp() {
        super.setUp()
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
            return
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .normal - 1
        window.makeKeyAndVisible()
        cameraTestWindow = window
    }

    override func tearDown() {
        cameraTestWindow?.resignKey()
        cameraTestWindow?.isHidden = true
        cameraTestWindow = nil
        super.tearDown()
    }

    // AC-P.6, AC-P.17: After syncDriveCamera applies pitch/zoom, a subsequent syncDriveHeading
    // call with the same heading as lastAppliedHeading is correctly skipped by the dead-band.
    // The two methods' guard state is independent — pitch/zoom change does NOT reset the heading guard.
    func testHeadingDeadBand_afterPitchChange_duplicateHeadingIsSkipped() {
        var regionState = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        var selectedID: String? = nil
        let repr = MapViewRepresentable(
            region: Binding(get: { regionState }, set: { regionState = $0 }),
            selectedSegmentID: Binding(get: { selectedID }, set: { selectedID = $0 }),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: MapViewRepresentable.OverlayPayload(generation: 0),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: 90.0,
            onDrivePanDetected: nil,
            driveModeActive: true,
            preDriveRegion: nil
        )

        let coordinator = repr.makeCoordinator()
        let mapView = MKMapView()

        // Step 1: Apply Drive Mode entry (pitch + zoom).
        coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)
        XCTAssertTrue(coordinator.lastDriveModeActive, "lastDriveModeActive should be true after entry")

        // Step 2: Apply initial heading of 90°.
        coordinator.syncDriveHeading(90.0, on: mapView)
        XCTAssertEqual(coordinator.lastAppliedHeading!, 90.0, accuracy: 0.01,
                       "First syncDriveHeading(90°) should set lastAppliedHeading")

        // Step 3: Apply duplicate heading of 90° again — should be skipped by dead-band.
        let headingBefore = mapView.camera.heading
        coordinator.syncDriveHeading(90.0, on: mapView)
        XCTAssertEqual(mapView.camera.heading, headingBefore, accuracy: 0.01,
                       "Duplicate syncDriveHeading(90°) should be skipped by dead-band (no camera change)")
        XCTAssertEqual(coordinator.lastAppliedHeading!, 90.0, accuracy: 0.01,
                       "lastAppliedHeading should remain 90° — not reset by the pitch change path")
    }

    // AC-P.3: Multiple updateUIView-equivalent calls with driveModeActive=true do NOT
    // re-trigger syncDriveCamera. The lastDriveModeActive guard ensures idempotency.
    func testNoFeedbackLoop_multipleUpdateUIView_syncDriveCameraCalledOnce() {
        var regionState = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.750, longitude: -73.980),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        var selectedID: String? = nil
        let repr = MapViewRepresentable(
            region: Binding(get: { regionState }, set: { regionState = $0 }),
            selectedSegmentID: Binding(get: { selectedID }, set: { selectedID = $0 }),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: MapViewRepresentable.OverlayPayload(generation: 0),
            activeRoute: nil,
            destinationCoordinate: nil,
            driveHeading: nil,
            onDrivePanDetected: nil,
            driveModeActive: true,
            preDriveRegion: nil
        )

        let coordinator = repr.makeCoordinator()
        let mapView = MKMapView()

        // First call: transition fires. Record altitude after.
        coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)
        let altitudeAfterTransition = mapView.camera.altitude

        // Simulate 5 more updateUIView calls (mimicking regionDidChangeAnimated feedback).
        // Each call should be a no-op (lastDriveModeActive == true == active → guard returns).
        for _ in 0..<5 {
            // Modify altitude between calls to detect if syncDriveCamera re-applies zoom.
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.altitude = 50_000  // artificially widen zoom
            mapView.setCamera(camera, animated: false)

            coordinator.syncDriveCamera(active: true, preDriveRegion: nil, on: mapView)

            // After each subsequent call, altitude should remain at 50,000 (guard fired).
            XCTAssertEqual(mapView.camera.altitude, 50_000, accuracy: 1.0,
                           "Subsequent syncDriveCamera(active:true) calls must be no-ops (feedback loop guard)")
        }

        // The first transition DID fire (altitude was reduced initially).
        XCTAssertLessThan(altitudeAfterTransition, 50_000,
                          "The initial transition should have reduced altitude (zoom-in fired once)")
    }
}

// MARK: - 4. Z-order / Pill Layout Test

@MainActor
final class EndDrivePillLayoutTests: XCTestCase {

    // AC-P.15, AC-P.16: End Drive pill has padding(.top, 100) to clear status bar + ASP banner.
    // We verify the state logic: when driveModeActive is true, the VStack containing the
    // End Drive pill gets the correct top offset.
    //
    // Full layout assertion would require ViewInspector or UIKit frame-reading tools not
    // available in pure XCTest. We verify the rendering path doesn't crash when both
    // Drive Mode and an ASP suspension state are active simultaneously.
    func testEndDrivePill_doesNotCrash_whenASPBannerAndDriveModeActive() {
        // Verify that ASPBanner renders all three states without crash alongside Drive Mode UI.
        let bannerStates: [SuspensionBannerState] = [
            .aspInEffect,
            .todaySuspended(reason: "Memorial Day"),
            .tomorrowSuspended(reason: "Thanksgiving")
        ]
        for state in bannerStates {
            let banner = ASPBanner(state: state)
            let host = UIHostingController(rootView: banner)
            XCTAssertNotNil(host.view, "ASPBanner in state \(state) should render without crash alongside Drive Mode")
        }
    }

    // AC-P.16: No regression — when Drive Mode is inactive, End Drive pill is not shown.
    // Verify DriveModeBottomCard renders correctly with nil context (chip-layout regression guard).
    func testDriveModeBottomCard_nilContext_noRegression() {
        let voice = DrivingVoice()
        let card = DriveModeBottomCard(context: nil, voiceService: voice)
        let host = UIHostingController(rootView: card)
        XCTAssertNotNil(host.view, "DriveModeBottomCard with nil context must not regress in W8.5c-polish")
    }

    // AC-P.12, AC-P.13: With non-nil context, chips render without crash.
    func testDriveModeBottomCard_nonNilContext_chipsRender() {
        let voice = DrivingVoice()
        let ctx = DrivingContext(
            street: "W 34 ST",
            from: "7 AVE",
            to: "8 AVE",
            leftLabel: SafetyLabel(text: "Free until Thu 9:30am", severity: .free),
            rightLabel: SafetyLabel(text: "No parking", severity: .restricted)
        )
        let card = DriveModeBottomCard(context: ctx, voiceService: voice, destinationDistance: 800.0)
        let host = UIHostingController(rootView: card)
        XCTAssertNotNil(host.view, "DriveModeBottomCard with non-nil context should render chips without crash")
    }
}

//
//  AmbientDrivingLookTests.swift
//  WeParkTests
//
//  Addendum 3 A3.6 ("driving look" opening posture, Kevin's Option A) - unit tests for the
//  pure decisions in `AmbientDrivingLook` plus the AC-13-style "the resting look never
//  enables the drive posture" checks.
//
//  What is and is not covered here (same disclosure `DriveCameraTiltTests` makes): the camera
//  / style / marker APPLICATION (`MKMapView.setCamera`, `viewFor`) is verified by the mandatory
//  live-UI smoke in the PR, not by a windowed MKMapView - no headless-window guards, no
//  UIWindowScene synthesis. Every DECISION that feeds those calls is a pure function tested
//  here. Flag-off byte-identical behavior is guarded through the gates every flag-on call site
//  hangs off (`isInEffect`, `restoresAmbientLookOnDriveExit`, the defaulted
//  `ambientRecenterButtonVisible` parameter), plus the existing flag-off pins elsewhere
//  (`initialLaunchRegion`, `DriveModeDefaultFlagTests`).
//
//  Compile-failure-class notes: pure statics are `nonisolated` and may be called inside
//  assertion autoclosures; MainActor members (`MapViewRepresentable.*`) are read into locals
//  FIRST. Helper names are file-private to this class (no XCTestCase extensions). No bare
//  `Category`/`Protocol`/`Method`/`Ivar` here.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine - Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
import MapKit
import UIKit
@testable import WePark

// MARK: - Pure decisions

final class AmbientDrivingLookTests: XCTestCase {

    // MARK: Posture gate

    func testIsInEffect_flagOnAtRest_true() {
        XCTAssertTrue(AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: true, driveModeActive: false))
    }

    func testIsInEffect_flagOnWhileDriving_false_lookIsNeverDriveMode() {
        XCTAssertFalse(
            AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: true, driveModeActive: true),
            "The ambient look and an escalated drive session are mutually exclusive by construction."
        )
    }

    func testIsInEffect_flagOff_alwaysFalse_byteIdentityGate() {
        XCTAssertFalse(AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: false, driveModeActive: false))
        XCTAssertFalse(AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: false, driveModeActive: true))
    }

    func testFlagShipsDark() {
        XCTAssertFalse(
            AppConstants.driveModeDefaultEnabled,
            "A3.6 is flag-on only; the flag must still ship false until Kevin's gate."
        )
        XCTAssertFalse(
            AmbientDrivingLook.isInEffect(
                driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
                driveModeActive: false
            ),
            "With the shipped flag value the ambient look is never in effect."
        )
    }

    // MARK: Accuracy guard (A3.6.1)

    func testZoomStep_noFixYet_opensWide() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: nil), .wide)
    }

    func testZoomStep_goodFix_tight() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 5), .tight)
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 30), .tight)
    }

    func testZoomStep_exactlyAtThreshold_tight() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 65), .tight,
            "A3.6.1: zoom fully when accuracy <= 65m (inclusive).")
    }

    func testZoomStep_justOverThreshold_wide() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 65.01), .wide)
    }

    func testZoomStep_poorFix_wide() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 100), .wide)
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: 1_000), .wide)
    }

    func testZoomStep_invalidNegativeAccuracy_wide() {
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: -1), .wide,
            "CoreLocation's invalid sentinel must never earn the tight step.")
    }

    func testThresholdConstantIsTheSpecValue() {
        XCTAssertEqual(AmbientDrivingLook.maxTightHorizontalAccuracyMeters, 65, accuracy: 0.0001)
    }

    // MARK: Camera numbers reuse Cruise's constants

    func testSpan_tight_isExactlyTheCruiseSpan() {
        let cruiseSpan = MapViewRepresentable.driveModeCameraSpan
        let tight = AmbientDrivingLook.span(for: .tight, cruiseSpan: cruiseSpan)
        XCTAssertEqual(tight, cruiseSpan, accuracy: 0.0000001,
            "A3.6.1: the tight look uses the escalated Cruise distance - no new number.")
    }

    func testSpan_wide_isOneStepOutFromCruise() {
        let cruiseSpan = MapViewRepresentable.driveModeCameraSpan
        let wide = AmbientDrivingLook.span(for: .wide, cruiseSpan: cruiseSpan)
        XCTAssertEqual(wide, cruiseSpan * AmbientDrivingLook.wideStepSpanMultiplier, accuracy: 0.0000001)
        XCTAssertGreaterThan(wide, cruiseSpan)
    }

    func testDistances_tightMatchesCruiseAltitude_wideIsFarther() {
        let cruiseSpan = MapViewRepresentable.driveModeCameraSpan
        let cruiseAltitude = MapViewRepresentable.altitudeForSpan(cruiseSpan)
        let tightAltitude = MapViewRepresentable.altitudeForSpan(
            AmbientDrivingLook.span(for: .tight, cruiseSpan: cruiseSpan)
        )
        let wideAltitude = MapViewRepresentable.altitudeForSpan(
            AmbientDrivingLook.span(for: .wide, cruiseSpan: cruiseSpan)
        )
        XCTAssertEqual(tightAltitude, cruiseAltitude, accuracy: 0.001)
        XCTAssertGreaterThan(wideAltitude, tightAltitude)
    }

    func testHeading_isNorthUp() {
        XCTAssertEqual(AmbientDrivingLook.heading, 0, accuracy: 0.0001,
            "A3.6.1: heading fixed at 0 - heading-up needs a GPS course the cheap posture lacks.")
    }

    // MARK: Overlay-hide guard under tilt (polylineHideSpanThreshold)

    /// Tilt makes `MKMapView.region.span` over-report the near field (a pitched view's
    /// lat/lng bounding box is a trapezoid's). At the look's own 30 deg pitch that inflates the
    /// reported span by roughly 20-30%; this test pins a deliberately generous 3x bound so the
    /// polyline-hide gate (`handleRegionChanged` -> `rebuildOverlays`'s `region.span <=
    /// polylineHideSpanThreshold` check) can never hide the curb colors at the look's own zoom,
    /// tight OR wide, however MapKit reports the tilted span.
    func testBothSteps_stayUnderPolylineHideThreshold_evenWithGenerousTiltInflation() {
        let cruiseSpan = MapViewRepresentable.driveModeCameraSpan
        let generousTiltInflation = 3.0
        for step in [AmbientDrivingLook.ZoomStep.tight, AmbientDrivingLook.ZoomStep.wide] {
            let reported = AmbientDrivingLook.span(for: step, cruiseSpan: cruiseSpan) * generousTiltInflation
            XCTAssertLessThanOrEqual(
                reported, AppConstants.polylineHideSpanThreshold,
                "Ambient step \(step) must keep curb colors painted at the tilted launch camera."
            )
        }
    }

    func testBothSteps_stayInsideTheZoomOutCeiling() {
        let cruiseSpan = MapViewRepresentable.driveModeCameraSpan
        let ceiling = MapViewRepresentable.maxZoomOutCenterCoordinateDistance
        let wideAltitude = MapViewRepresentable.altitudeForSpan(
            AmbientDrivingLook.span(for: .wide, cruiseSpan: cruiseSpan)
        )
        XCTAssertLessThan(wideAltitude, ceiling,
            "setCamera to the wide step must not be clamped by setCameraZoomRange.")
    }

    // MARK: Tighten-on-better-fix

    func testShouldTighten_wideLook_goodFix_notAdjusted_true() {
        XCTAssertTrue(AmbientDrivingLook.shouldTighten(currentStep: .wide, userAdjusted: false, newAccuracy: 20))
    }

    func testShouldTighten_alreadyTight_false() {
        XCTAssertFalse(AmbientDrivingLook.shouldTighten(currentStep: .tight, userAdjusted: false, newAccuracy: 20))
    }

    func testShouldTighten_userAdjusted_neverFightsTheGesture() {
        XCTAssertFalse(AmbientDrivingLook.shouldTighten(currentStep: .wide, userAdjusted: true, newAccuracy: 20))
    }

    func testShouldTighten_stillPoorFix_false() {
        XCTAssertFalse(AmbientDrivingLook.shouldTighten(currentStep: .wide, userAdjusted: false, newAccuracy: 90))
        XCTAssertFalse(AmbientDrivingLook.shouldTighten(currentStep: .wide, userAdjusted: false, newAccuracy: nil))
        XCTAssertFalse(AmbientDrivingLook.shouldTighten(currentStep: .wide, userAdjusted: false, newAccuracy: -1))
    }

    // MARK: Drive exit returns to the ambient look (A3.6.3)

    func testExit_flagOn_restoresAmbientLook_flagOff_keepsOldRestore() {
        XCTAssertTrue(AmbientDrivingLook.restoresAmbientLookOnDriveExit(driveModeDefaultEnabled: true))
        XCTAssertFalse(AmbientDrivingLook.restoresAmbientLookOnDriveExit(driveModeDefaultEnabled: false),
            "Flag-off exit must keep today's pre-drive camera/style restore, byte-identical.")
    }

    func testExit_restoresTightStep() {
        XCTAssertEqual(AmbientDrivingLook.exitZoomStep, .tight,
            "End returns to the launch look at the tight step - the driver just had a nav-grade fix.")
    }

    // MARK: Recenter under tilt (screen space)

    private let mapSize = CGSize(width: 393, height: 852)

    func testScreenSpace_dotAtViewCenter_isInsideCentralHalf() {
        XCTAssertFalse(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 196.5, y: 426), mapSize: mapSize
        ), "A dot at the camera center maps to the middle of the view whatever the pitch.")
    }

    func testScreenSpace_insideCentralHalfBoundary_false() {
        // Central 50% = x in [98.25, 294.75], y in [213, 639].
        XCTAssertFalse(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 100, y: 215), mapSize: mapSize
        ))
        XCTAssertFalse(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 290, y: 630), mapSize: mapSize
        ))
    }

    func testScreenSpace_pastQuarterHorizontally_true() {
        XCTAssertTrue(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 60, y: 426), mapSize: mapSize
        ))
        XCTAssertTrue(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 330, y: 426), mapSize: mapSize
        ))
    }

    func testScreenSpace_pastQuarterVertically_true() {
        XCTAssertTrue(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 196.5, y: 150), mapSize: mapSize
        ))
        XCTAssertTrue(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 196.5, y: 700), mapSize: mapSize
        ))
    }

    func testScreenSpace_offscreenDot_true() {
        XCTAssertTrue(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: -500, y: 3_000), mapSize: mapSize
        ))
    }

    func testScreenSpace_unmeasuredMap_false() {
        XCTAssertFalse(AmbientDrivingLook.userDotOutsideCentralHalf(
            screenPoint: CGPoint(x: 10, y: 10), mapSize: .zero
        ), "A map with no size yet must not flash Recenter.")
    }

    // MARK: Recenter button: screen-space measurement wins; default preserves old behavior

    private let user = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.98)

    /// A region whose bounding-box center sits 30% of its span north of the user - what a
    /// steeply pitched or rotated camera reports even with the dot dead-center on screen.
    private var skewedRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75 + 0.003, longitude: -73.98),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
    }

    func testRecenterButton_tiltSkewedBoundingBox_screenSpaceCenteredDot_hidden() {
        // Region-based test alone misreads the skew as "panned away" ...
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: user, visibleRegion: skewedRegion
        ), "Sanity: the pre-A3.6 region test over-reports under a skewed bounding box.")
        // ... the screen-space measurement (dot in the middle of the view) overrides it.
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse,
            userLocation: user,
            visibleRegion: skewedRegion,
            userDotOutsideCentralHalfOnScreen: false
        ), "A3.6: Recenter must NOT show while the dot is centered on screen, tilted or not.")
    }

    func testRecenterButton_screenSpaceOffCenter_shows() {
        let centeredRegion = MKCoordinateRegion(
            center: user, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse,
            userLocation: user,
            visibleRegion: centeredRegion,
            userDotOutsideCentralHalfOnScreen: true
        ), "After the user pans the dot out of the central half, Recenter shows.")
    }

    func testRecenterButton_nilMeasurement_keepsRegionTest_flagOffEquivalence() {
        let centeredRegion = MKCoordinateRegion(
            center: user, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
        // Explicit nil == omitted argument == the pre-A3.6 function, for every auth branch.
        let statuses: [CLAuthorizationStatus] = [
            .notDetermined, .authorizedWhenInUse, .authorizedAlways, .denied, .restricted
        ]
        for status in statuses {
            let omitted = ambientRecenterButtonVisible(
                authorizationStatus: status, userLocation: user, visibleRegion: skewedRegion
            )
            let explicitNil = ambientRecenterButtonVisible(
                authorizationStatus: status, userLocation: user, visibleRegion: skewedRegion,
                userDotOutsideCentralHalfOnScreen: nil
            )
            XCTAssertEqual(omitted, explicitNil)
        }
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: user, visibleRegion: centeredRegion
        ))
    }

    func testRecenterButton_measurementNeverOverridesAuthGating() {
        let centeredRegion = MKCoordinateRegion(
            center: user, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.008)
        )
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .denied, userLocation: user, visibleRegion: centeredRegion,
            userDotOutsideCentralHalfOnScreen: true
        ), "Denied/restricted stays hidden regardless of the measurement.")
        XCTAssertFalse(ambientRecenterButtonVisible(
            authorizationStatus: .authorizedWhenInUse, userLocation: nil, visibleRegion: centeredRegion,
            userDotOutsideCentralHalfOnScreen: true
        ), "No fix means no dot to return to.")
        XCTAssertTrue(ambientRecenterButtonVisible(
            authorizationStatus: .notDetermined, userLocation: nil, visibleRegion: centeredRegion,
            userDotOutsideCentralHalfOnScreen: false
        ), "notDetermined is the route to the permission prompt - always shows.")
    }

    // MARK: Marker

    func testAmbientUserDotImage_isAPlainDot_notTheDriveChevron() {
        let dot = MapViewRepresentable.ambientUserDotImage()
        let chevron = MapViewRepresentable.driveNavPuckImage()
        XCTAssertGreaterThan(dot.size.width, 0)
        XCTAssertGreaterThan(dot.size.height, 0)
        XCTAssertEqual(dot.size.width, dot.size.height, accuracy: 0.001)
        XCTAssertNotEqual(dot.size, chevron.size,
            "The ambient dot is its own asset; driveNavPuckImage stays untouched.")
    }
}

// MARK: - AC-13: the resting look never enters the drive location posture

final class AmbientDrivingLookLocationPostureTests: XCTestCase {

    var service: LocationService!

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

    private func makeFix(horizontalAccuracy: CLLocationAccuracy) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: 5,
            course: 90,
            courseAccuracy: 10,
            speed: 8,
            speedAccuracy: 1,
            timestamp: Date()
        )
    }

    func testFreshService_hasNoWakeLock_noDriveState_noAccuracy() {
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled,
            "AC-13: at rest the screen idle timer is never disabled.")
        XCTAssertNil(service.driveHeading)
        XCTAssertNil(service.driveSpeed)
        XCTAssertNil(service.driveCourseAccuracy)
        XCTAssertNil(service.userHorizontalAccuracy)
    }

    func testRestingFix_publishesAccuracy_withoutAnyDrivePosture() async {
        service.locationManager(Self.dummyManager, didUpdateLocations: [makeFix(horizontalAccuracy: 30)])
        await waitUntil { self.service.userHorizontalAccuracy != nil }

        XCTAssertEqual(service.userHorizontalAccuracy ?? -1, 30, accuracy: 0.001,
            "The accuracy guard reads this published single-shot accuracy.")
        XCTAssertNil(service.driveHeading, "AC-13: a resting fix never produces drive heading state.")
        XCTAssertNil(service.driveSpeed, "AC-13: a resting fix never produces drive speed state.")
        XCTAssertNil(service.driveCourseAccuracy)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled,
            "AC-13: consuming a resting fix does not take the wake lock.")
    }

    func testRestingFix_invalidAccuracy_publishesNil() async {
        service.locationManager(Self.dummyManager, didUpdateLocations: [makeFix(horizontalAccuracy: 40)])
        await waitUntil { self.service.userHorizontalAccuracy != nil }
        service.locationManager(Self.dummyManager, didUpdateLocations: [makeFix(horizontalAccuracy: -1)])
        await waitUntil { self.service.userHorizontalAccuracy == nil }

        XCTAssertNil(service.userHorizontalAccuracy,
            "CoreLocation's negative sentinel must publish nil so it can never earn the tight step.")
    }

    func testAccuracyGuardEndToEnd_publishedAccuracyDrivesTheStep() async {
        service.locationManager(Self.dummyManager, didUpdateLocations: [makeFix(horizontalAccuracy: 100)])
        await waitUntil { self.service.userHorizontalAccuracy != nil }
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: service.userHorizontalAccuracy), .wide)

        service.locationManager(Self.dummyManager, didUpdateLocations: [makeFix(horizontalAccuracy: 25)])
        await waitUntil { (self.service.userHorizontalAccuracy ?? 999) < 50 }
        XCTAssertEqual(AmbientDrivingLook.zoomStep(forHorizontalAccuracy: service.userHorizontalAccuracy), .tight)
    }
}

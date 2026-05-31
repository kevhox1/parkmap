//
//  MapViewRepresentable.swift
//  WePark
//
//  Rendering architecture decision (2026-05-11):
//  SwiftUI MapPolyline inside @MapContentBuilder is disqualified at WePark's tile density.
//  40,664 segments × ~30 Metal resources each = 1.22M GPU resources, 25× over MapKit's
//  50,000-resource VectorKit limit. This file replaces that approach entirely.
//
//  Architecture: UIKit MKMapView via UIViewRepresentable.
//  6 MKMultiPolyline overlays (one per current parking state + 1 selected-block highlight).
//  6 overlays = 6 Metal resource groups. Under the 50,000 limit by a factor of 8,000.
//
//  Overlay groups:
//    1. freeComfortably          — green,   lineWidth: 3
//    2. freeButRestrictionSoon   — orange,  lineWidth: 3
//    3. meteredActive            — amber,   lineWidth: 4
//    4. restrictedNow            — red,     lineWidth: 3
//    5. unknown                  — gray/35%,lineWidth: 3
//    6. selectedBlock            — state color, lineWidth: 6 (single MKPolyline)
//
//  On the 60-second timer tick, `updateOverlays(segments:engine:now:)` is called from
//  ContentView. It partitions segments by current state via a single O(n) pass, instantiates
//  new MKMultiPolyline objects, swaps old overlays out via removeOverlay/addOverlay.
//  MKMultiPolyline is immutable — we never mutate, only replace.
//
//  Tap handling: UITapGestureRecognizer added to MKMapView in the Coordinator.
//  On tap: mapView.convert(_:toCoordinateFrom:) → CLLocationCoordinate2D.
//  The coordinate is passed to the `onTap` closure, which lives in ContentView and
//  runs the existing haversine point-to-segment search unchanged.
//
//  W5 additions:
//    - UILongPressGestureRecognizer (0.4s min duration) → onLongPress closure.
//    - CarPinAnnotation: MKPointAnnotation subclass for the parked-car pin.
//    - carPin: ParkedCar? input — drives annotation add/remove in updateUIView.
//    - onCarPinTapped: () -> Void — fired when the tap hits the car pin instead of map.
//    - Car pin tap disambiguation: if tap coordinate is within ~30pt of the car pin
//      annotation view center, fire onCarPinTapped instead of onTap.
//
//  State bridging to SwiftUI:
//    - `region` Binding<MKCoordinateRegion>: two-way camera state
//    - `selectedSegmentID` Binding<String?>: drives highlight overlay
//    - `onTap(CLLocationCoordinate2D)`: closure into ContentView tap handler
//    - `onLongPress(CLLocationCoordinate2D)`: closure into ContentView long-press handler (W5)
//    - `onRegionChanged(MKCoordinateRegion)`: closure for tile loading
//    - `onCarPinTapped()`: closure into ContentView car-pin tap handler (W5)
//    - `carPin: ParkedCar?`: drives car pin annotation state (W5)
//
//  API availability: MKMultiPolyline and MKMultiPolylineRenderer available since iOS 13.
//  All APIs used here are available on the iOS 17 deployment target.
//
//  See: docs/ios-rendering-architecture-decision.md §1, §3, §4, §5
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Overlay identity tags
// Used in mapView(_:rendererFor:) to distinguish which group an overlay belongs to.

/// Overlay identity tag enum.
/// Internal (not private) because `TaggedMultiPolyline` is internal (for Z-order testing)
/// and Swift requires a property's type to be at least as accessible as the property itself.
enum OverlayTag: Int {
    case freeComfortably         = 0
    case freeButRestrictionSoon  = 1
    case meteredActive           = 2
    case restrictedNow           = 3
    case unknown                 = 4
    case selectedBlock           = 5
    /// W8.5b: Drive Mode route polyline (blue, above parking state overlays).
    case routePolyline           = 6
}

// MARK: - Tagged MKMultiPolyline

/// MKMultiPolyline with an associated OverlayTag so the renderer delegate can
/// distinguish the 5 state groups without a fragile identity comparison.
///
/// Internal (not private) so the S-1 Z-order test in W85bTests can type-check
/// overlays in mapView.overlays. Not part of the public API surface.
final class TaggedMultiPolyline: MKMultiPolyline {
    var overlayTag: OverlayTag = .unknown
}

/// Single-segment selected-block overlay. Uses MKPolyline (not MKMultiPolyline)
/// so it can carry the segment's current-state color independently.
private final class SelectedPolyline: MKPolyline {
    var currentState: CurrentState = .unknown
}

/// W8.5b: Drive Mode route polyline overlay.
/// Rendered in .systemBlue above the parking-state overlays (OQ-8).
///
/// Internal (not private) so the S-1 Z-order test in W85bTests can type-check
/// overlays in mapView.overlays. Not part of the public API surface.
final class RoutePolyline: MKPolyline {}

// MARK: - CarPinAnnotation

/// MKPointAnnotation subclass for the user's parked car.
/// Identified by type in viewFor(annotation:) to render the custom pin.
final class CarPinAnnotation: MKPointAnnotation {
    // No extra state needed — identity is by type.
}

/// W8.5b: MKPointAnnotation subclass for the Drive Mode destination.
/// Rendered in red (OQ-6: `mappin.circle.fill` red, distinct from the blue car pin).
final class DestinationPinAnnotation: MKPointAnnotation {
    // No extra state needed — identity is by type.
}

// MARK: - MapViewRepresentable

struct MapViewRepresentable: UIViewRepresentable {

    // MARK: Bindings / inputs from ContentView

    /// Two-way camera region. Updated when the user pans/zooms; written by ContentView
    /// to programmatically change the visible region.
    @Binding var region: MKCoordinateRegion

    /// Currently selected segment ID — drives the highlight overlay.
    @Binding var selectedSegmentID: String?

    /// Called when the user taps the map (not the car pin). ContentView runs haversine search.
    let onTap: (CLLocationCoordinate2D) -> Void

    /// W5: Called when the user long-presses the map. ContentView runs segment detection.
    let onLongPress: (CLLocationCoordinate2D) -> Void

    /// Called when the visible region changes (user pan/zoom ended). ContentView
    /// forwards to TileLoader.
    let onRegionChanged: (MKCoordinateRegion) -> Void

    /// W5: Called when the user taps the car-pin annotation. ContentView presents
    /// ParkedCarDetailView.
    let onCarPinTapped: () -> Void

    /// W5: Current parked car from ParkPinService. Non-nil → annotation visible on map.
    /// Nil → annotation removed.
    let carPin: ParkedCar?

    // MARK: Overlay update API
    // Called from ContentView on every 60-second tick and on initial load.

    /// Holds the overlay state to apply in updateUIView.
    var overlayPayload: OverlayPayload

    // MARK: W8.5b: Drive Mode inputs

    /// Active Drive Mode route. Non-nil → blue route polyline rendered above parking overlays.
    /// Nil → route polyline removed.
    let activeRoute: DriveRoute?

    /// Drive Mode destination coordinate. Non-nil → red destination pin annotation on map.
    /// Nil → destination pin removed.
    let destinationCoordinate: CLLocationCoordinate2D?

    // MARK: W8.5c: Heading-up rotation

    /// Stabilized Drive Mode heading in degrees [0, 360). Non-nil → camera heading set.
    /// Nil → reset camera heading to north-up (0).
    /// Dead-band: only applied when heading changes by > 5 degrees (R-1 anti-loop guard).
    /// Default: nil (Drive Mode not active).
    var driveHeading: Double? = nil

    /// Whether Drive Mode is currently active.
    ///
    /// Used to gate the region-sync path in `updateUIView`: when Drive Mode is active,
    /// `setRegion(_:animated:)` is suppressed because it resets camera pitch to 0, clobbering
    /// the 30° tilt set by `applyDriveCameraPitch`. Follow-mode recentering during Drive Mode
    /// uses a pitch-preserving `setCamera` path instead (`syncDriveRegion`).
    ///
    /// On the simulator there is no magnetometer, so `driveHeading` is always nil during
    /// Drive Mode — the original guard `if driveHeading == nil` failed to suppress `setRegion`
    /// in the sim, flattening pitch on every location update. This property fixes that.
    var driveModeActive: Bool = false

    /// Callback when the user manually pans the map during Drive Mode (follow mode disabled).
    /// ContentView sets `driveFollowEnabled = false` to show the Recenter button.
    /// Default: nil (not in Drive Mode).
    var onDrivePanDetected: (() -> Void)? = nil

    // MARK: - W8.5c-polish PR-3 / PR-2: Drive Mode camera constants + pure-function decisions

    /// Camera pitch applied during Drive Mode.
    ///
    /// PR-2 value: 45° — empirically measured at the PR-2 tighter zoom (span ~0.005°,
    /// centerCoordinateDistance ~2,000m). At this altitude MapKit allows steeper pitch without
    /// clamping; 45° was verified to round-trip faithfully (camera.pitch ≈ 45° post-animation).
    ///
    /// PR-3 shipped 30° at the wider Drive Mode span (~0.04°, altitude ~180,000m) where MapKit
    /// clamps pitch at ~35°, making 30° the safe ceiling. At the PR-2 tighter altitude (~2,000m)
    /// the ceiling rises to at least 45°, possibly higher. 45° is the measured faithful value.
    ///
    /// W8.5d note: `applyDriveCameraState` is reusable for final-approach pitch escalation
    /// without structural change — call it with a different pitch value in the last 500m.
    static let driveModePitch: CGFloat = 45

    /// Target latitude span during Drive Mode (~0.005° ≈ 1–2 Manhattan blocks).
    ///
    /// PR-2: this is the tighter zoom that replaces the wider Drive Mode span from PR-3.
    /// At 0.005° the camera `centerCoordinateDistance` is approximately 2,000–2,300m
    /// (computed by `altitudeForSpan(_:)`). This span was chosen per the spec's
    /// "approximately 1–2 Manhattan blocks visible" UX target.
    static let driveModeCameraSpan: CLLocationDegrees = 0.005

    /// Pure pitch-decision function: no MKMapView dependency, directly unit-testable.
    ///
    /// Returns the target camera pitch given the Drive Mode state and the pitch that was
    /// in effect before Drive Mode started.
    ///
    /// - Parameters:
    ///   - active: Whether Drive Mode is being entered (true) or exited (false).
    ///   - priorPitch: The camera pitch captured at Drive Mode entry; restored on exit (OQ-3).
    /// - Returns: 45° when entering Drive Mode; `priorPitch` when exiting.
    static func targetPitch(forDriveModeActive active: Bool, priorPitch: CGFloat) -> CGFloat {
        active ? driveModePitch : priorPitch
    }

    /// Pure span-decision function: no MKMapView dependency, directly unit-testable.
    ///
    /// Returns the target latitude span given the Drive Mode state.
    ///
    /// - Parameters:
    ///   - active: Whether Drive Mode is being entered (true) or exited (false).
    ///   - priorSpan: The latitude span captured at Drive Mode entry; restored on exit.
    /// - Returns: `driveModeCameraSpan` (~0.005°) when entering; `priorSpan` when exiting.
    static func targetSpan(forDriveModeActive active: Bool, priorSpan: CLLocationDegrees) -> CLLocationDegrees {
        active ? driveModeCameraSpan : priorSpan
    }

    /// Converts a latitude span (in degrees) to a MapKit camera `centerCoordinateDistance`
    /// (altitude in meters).
    ///
    /// Formula: half of the N–S visible distance in meters divided by tan(half the vertical FOV).
    /// Assumes MapKit's default ~60° vertical FOV (tan of 30° ≈ 0.5774).
    ///
    /// Approximation accuracy: within ~5% at NYC latitudes (flat-Earth, valid for small spans).
    /// Acceptable for a Drive Mode UX heuristic (not navigation-critical).
    ///
    /// - Parameter latitudeDelta: Latitude span in degrees.
    /// - Returns: Estimated camera `centerCoordinateDistance` in meters.
    static func altitudeForSpan(_ latitudeDelta: CLLocationDegrees) -> CLLocationDistance {
        let metersPerDegree: CLLocationDistance = 111_000
        let halfHeightMeters = (latitudeDelta / 2.0) * metersPerDegree
        return halfHeightMeters / tan(30.0 * .pi / 180.0)
    }

    /// Pure map-configuration-decision function: no MKMapView dependency, directly unit-testable.
    ///
    /// Returns the target `MKMapConfiguration` given the Drive Mode state.
    ///
    /// - Parameters:
    ///   - active: Whether Drive Mode is being entered (true) or exited (false).
    ///   - priorConfiguration: The configuration captured at Drive Mode entry; restored on exit.
    /// - Returns: `MKStandardMapConfiguration(emphasisStyle: .muted)` when entering;
    ///   `priorConfiguration` (or a default standard config if nil) when exiting.
    static func targetMapConfiguration(
        forDriveModeActive active: Bool,
        priorConfiguration: MKMapConfiguration?
    ) -> MKMapConfiguration {
        if active {
            return MKStandardMapConfiguration(emphasisStyle: .muted)
        } else {
            return priorConfiguration ?? MKStandardMapConfiguration()
        }
    }

    // MARK: - W8.5c-polish PR-3: CoordinatorActions reference-type bridge

    /// Reference-type action box populated by `makeUIView` and held by ContentView.
    ///
    /// Mechanism: `makeUIView` creates the Coordinator, then wires the coordinator's
    /// `applyDriveCameraPitch` method into this box. ContentView holds a reference to the
    /// same box instance (passed as a property on the representable) and calls
    /// `applyDrivePitch` from its `.onChange(of: driveModeActive)` modifier — OUTSIDE
    /// `updateUIView` — so camera mutation never runs during SwiftUI's view-update cycle.
    ///
    /// This is the architectural fix for the #31 regression: the reverted code called
    /// `setCamera` synchronously inside `updateUIView`, racing SwiftUI's in-progress mount
    /// and silently dropping the entire `.safeAreaInset(...)` overlay chain (toolbar, ASP
    /// banner, Park Until pill). By moving the mutation to `.onChange`, we fire after
    /// SwiftUI's mount completes, eliminating the race.
    final class CoordinatorActions {
        /// Captures the current map camera pitch. Called by ContentView before Drive Mode entry
        /// to record `preDrivePitch`.
        var captureCurrentPitch: (() -> CGFloat)?

        /// Applies the Drive Mode camera pitch + zoom transition (single combined setCamera).
        /// `active` = true → animate to driveModePitch + driveModeCameraSpan altitude.
        /// `active` = false → animate back to `priorPitch` + `priorDistance`.
        var applyDrivePitch: ((Bool, CGFloat) -> Void)?

        // MARK: PR-2: Auto-zoom closures

        /// Captures the current camera `centerCoordinateDistance`. Called by ContentView
        /// before Drive Mode entry to record `preDriveDistance`.
        var captureCurrentDistance: (() -> CLLocationDistance)?

        /// Applies the Drive Mode zoom transition.
        /// NOTE: zoom is combined into `applyDrivePitch` (single setCamera call per §3.4).
        /// This closure is reserved for future extension and is not called directly today.
        var applyDriveZoom: ((Bool, CLLocationDistance) -> Void)?

        // MARK: PR-2: Map style closures

        /// Captures the current `preferredConfiguration`. Called by ContentView before Drive
        /// Mode entry to record `preDriveMapConfiguration`.
        var captureCurrentMapConfiguration: (() -> MKMapConfiguration?)?

        /// Applies or restores the Drive Mode map style (`.muted` on entry, prior on exit).
        var applyDriveMapStyle: ((Bool, MKMapConfiguration?) -> Void)?

        // MARK: PR-2: Directional puck refresh

        /// Refreshes the user-location annotation view so MapKit re-queries the delegate.
        /// Called on Drive Mode entry/exit to swap between the directional puck and the
        /// default blue dot. Implemented by briefly toggling `showsUserLocation`.
        var refreshUserLocationPuck: ((Bool) -> Void)?
    }

    /// Shared action box. Created by ContentView and passed in; populated by `makeUIView`.
    /// ContentView calls `coordinatorActions.applyDrivePitch(active, priorPitch)` from its
    /// `.onChange(of: driveModeActive)` handler (not from updateUIView).
    var coordinatorActions: CoordinatorActions

    // MARK: - OverlayPayload (value type carrying segment-group coordinates)

    struct OverlayPayload: Equatable {
        var freeComfortably:        [[CLLocationCoordinate2D]]
        var freeButRestrictionSoon: [[CLLocationCoordinate2D]]
        var meteredActive:          [[CLLocationCoordinate2D]]
        var restrictedNow:          [[CLLocationCoordinate2D]]
        var unknown:                [[CLLocationCoordinate2D]]
        var selectedCoords:         [CLLocationCoordinate2D]?
        var selectedState:          CurrentState
        /// Generation counter used for equality. ContentView increments this on every
        /// rebuild, so the UIView update fires exactly once per rebuild — not on every
        /// SwiftUI re-render. Comparing coordinate arrays would be expensive (O(n) over
        /// potentially thousands of coordinates).
        var generation:             Int

        /// Default empty payload (no overlays, generation 0).
        init(generation: Int = 0) {
            self.freeComfortably        = []
            self.freeButRestrictionSoon = []
            self.meteredActive          = []
            self.restrictedNow          = []
            self.unknown                = []
            self.selectedCoords         = nil
            self.selectedState          = .unknown
            self.generation             = generation
        }

        /// Full payload initializer used by ContentView.rebuildOverlays.
        init(
            freeComfortably:        [[CLLocationCoordinate2D]],
            freeButRestrictionSoon: [[CLLocationCoordinate2D]],
            meteredActive:          [[CLLocationCoordinate2D]],
            restrictedNow:          [[CLLocationCoordinate2D]],
            unknown:                [[CLLocationCoordinate2D]],
            selectedCoords:         [CLLocationCoordinate2D]?,
            selectedState:          CurrentState,
            generation:             Int
        ) {
            self.freeComfortably        = freeComfortably
            self.freeButRestrictionSoon = freeButRestrictionSoon
            self.meteredActive          = meteredActive
            self.restrictedNow          = restrictedNow
            self.unknown                = unknown
            self.selectedCoords         = selectedCoords
            self.selectedState          = selectedState
            self.generation             = generation
        }

        static func == (lhs: OverlayPayload, rhs: OverlayPayload) -> Bool {
            lhs.generation == rhs.generation
        }
    }

    // MARK: - UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Dead-band heading diff

    /// Circular heading difference in degrees (0–180). Used for dead-band guard.
    static func headingDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    // MARK: - W8.5c-polish PR-3: Region-sync guard pure function

    /// Returns whether `updateUIView` should sync the SwiftUI `region` binding to the map
    /// view via `setRegion(_:animated:)`.
    ///
    /// `setRegion` resets the camera to top-down (pitch = 0, heading = 0). During Drive Mode
    /// that would clobber the 30° tilt applied by `applyDriveCameraPitch`. Region sync is
    /// therefore suppressed while Drive Mode is active; follow-mode recentering uses
    /// `syncDriveRegion` (a pitch-preserving `setCamera` path) instead.
    ///
    /// On the simulator, `driveHeading` is always nil (no magnetometer), so the previous
    /// guard `if driveHeading == nil` never suppressed the sync during Drive Mode in the sim,
    /// flattening pitch back to 0 on every location update. This function fixes that by
    /// gating on the authoritative Drive Mode flag, not the derived heading value.
    ///
    /// - Parameter driveModeActive: Whether Drive Mode is currently active.
    /// - Returns: `true` when region sync should run; `false` to suppress it.
    static func shouldSyncRegionToBinding(driveModeActive: Bool) -> Bool {
        !driveModeActive
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true  // W5.1: show blue dot for recenter feature
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = true
        mapView.showsScale = true

        // Register the CarPinAnnotation view class.
        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.carPinReuseID
        )

        // W8.5b: Register the DestinationPinAnnotation view class.
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.destinationPinReuseID
        )

        // Set initial camera region.
        mapView.setRegion(region, animated: false)

        // UITapGestureRecognizer for block taps.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Allow simultaneous recognition with MKMapView's built-in gesture recognizers
        // (needed so map gestures like pan/pinch still work alongside our tap).
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

        // W5: UILongPressGestureRecognizer for pin-drop.
        // 0.4s minimum duration — slightly faster than iOS default (0.5s) for better
        // responsiveness on a small phone. Above the 0.3s accidental-tap-hold threshold.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.4
        longPress.delegate = context.coordinator
        mapView.addGestureRecognizer(longPress)

        context.coordinator.mapView = mapView

        // W8.5c-polish PR-3 / PR-2: Wire coordinator actions into the shared action box.
        // ContentView holds this same box instance and calls it from .onChange(of: driveModeActive),
        // OUTSIDE updateUIView, so setCamera never fires during SwiftUI's view-update cycle.
        // This is the architectural guard against the #31 regression.
        let coordinator = context.coordinator

        // PR-3 pitch closure (extended in PR-2 to also set centerCoordinateDistance).
        coordinatorActions.captureCurrentPitch = { [weak coordinator] in
            coordinator?.mapView?.camera.pitch ?? 0
        }
        coordinatorActions.applyDrivePitch = { [weak coordinator] active, priorPitch in
            guard let c = coordinator, let mapView = c.mapView else { return }
            // NOTE: priorDistance is captured separately; we need it here for the combined call.
            // The ContentView extension passes priorDistance via applyDriveZoom (reserved) but
            // the combined setCamera is driven by applyDriveCameraState called from the pitch closure
            // with both priorPitch and priorDistance. We call the combined method here.
            let priorDistance = c.lastCapturedPriorDistance
            c.applyDriveCameraState(
                active: active,
                priorPitch: priorPitch,
                priorDistance: priorDistance,
                on: mapView
            )
        }

        // PR-2: Distance capture closure.
        coordinatorActions.captureCurrentDistance = { [weak coordinator] in
            coordinator?.mapView?.camera.centerCoordinateDistance ?? 0
        }

        // PR-2: Zoom closure is merged into applyDrivePitch (single setCamera per §3.4).
        // applyDriveZoom is wired as a no-op reservation; the actual zoom fires via
        // applyDrivePitch → applyDriveCameraState.
        coordinatorActions.applyDriveZoom = { _, _ in
            // Intentionally empty: zoom is handled inside applyDrivePitch via
            // applyDriveCameraState which sets BOTH pitch and centerCoordinateDistance
            // in a single setCamera call (spec §3.4 single-call requirement).
        }

        // PR-2: Map style closures.
        coordinatorActions.captureCurrentMapConfiguration = { [weak coordinator] in
            coordinator?.mapView?.preferredConfiguration
        }
        coordinatorActions.applyDriveMapStyle = { [weak coordinator] active, priorConfig in
            guard let mapView = coordinator?.mapView else { return }
            mapView.preferredConfiguration = MapViewRepresentable.targetMapConfiguration(
                forDriveModeActive: active,
                priorConfiguration: priorConfig
            )
        }

        // PR-2: Puck refresh closure — toggles showsUserLocation to force re-query of
        // mapView(_:viewFor:) so the directional puck or default blue dot is applied.
        coordinatorActions.refreshUserLocationPuck = { [weak coordinator] _ in
            guard let mapView = coordinator?.mapView else { return }
            mapView.showsUserLocation = false
            mapView.showsUserLocation = true
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Apply overlay updates if the payload has changed (generation differs).
        if context.coordinator.lastAppliedGeneration != overlayPayload.generation {
            context.coordinator.applyOverlayPayload(overlayPayload, to: mapView)
            context.coordinator.lastAppliedGeneration = overlayPayload.generation
        }

        // W5: Sync car pin annotation state.
        context.coordinator.syncCarPin(carPin, on: mapView)

        // W8.5b: Sync route polyline and destination pin.
        context.coordinator.syncRoutePolyline(activeRoute, on: mapView)
        context.coordinator.syncDestinationPin(destinationCoordinate, on: mapView)

        // W8.5c: Heading-up rotation (AC-W85c.10, AC-W85c.11).
        // Port of setDrivingMapRotation (index.html:6584–6601) with R-1 dead-band guard.
        // Only update when heading changes > 5 degrees to prevent tight regionDidChange feedback loop.
        context.coordinator.syncDriveHeading(driveHeading, on: mapView)

        // Sync camera to the SwiftUI `region` binding when not in Drive Mode.
        //
        // `setRegion` resets the camera to top-down (pitch = 0, heading = 0), which would
        // clobber the 30° tilt applied by `applyDriveCameraPitch`. Guard uses
        // `shouldSyncRegionToBinding(driveModeActive:)` rather than `driveHeading == nil`
        // because the simulator has no magnetometer — driveHeading is always nil in the sim
        // even during Drive Mode, so the old guard never suppressed `setRegion` there,
        // flattening pitch back to 0 on every location update (W8.5c-polish PR-3 bug fix).
        //
        // During Drive Mode, follow-mode recentering is handled by `syncDriveRegion` below,
        // which copies the current camera (preserving pitch + heading) and updates only the
        // center coordinate — so pitch survives every location update.
        if MapViewRepresentable.shouldSyncRegionToBinding(driveModeActive: driveModeActive) {
            let mapRegion = mapView.region
            let latDiff = abs(mapRegion.center.latitude  - region.center.latitude)
            let lngDiff = abs(mapRegion.center.longitude - region.center.longitude)
            if latDiff > 0.0001 || lngDiff > 0.0001 {
                mapView.setRegion(region, animated: false)
            }
        } else {
            // Drive Mode: use pitch-preserving camera update so the 30° tilt survives
            // every follow-mode recenter. `setRegion` is banned here — it resets pitch.
            context.coordinator.syncDriveRegion(region, on: mapView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        var parent: MapViewRepresentable
        weak var mapView: MKMapView?

        /// Tracks which payload generation we last applied to avoid redundant overlay swaps.
        var lastAppliedGeneration: Int = -1

        // Current live overlays (strong refs so we can removeOverlay them later).
        private var multiPolylines: [OverlayTag: TaggedMultiPolyline] = [:]
        private var selectedPolyline: SelectedPolyline? = nil

        // W5: Car pin annotation state.
        static let carPinReuseID = "CarPinAnnotation"
        private var carPinAnnotation: CarPinAnnotation? = nil
        /// The UUID of the currently-rendered car pin (nil if none).
        /// Used to detect when the pin changes identity (new pin, clear, or replace).
        private var renderedCarPinID: UUID? = nil

        // W8.5b: Route polyline + destination pin state.
        static let destinationPinReuseID = "DestinationPinAnnotation"
        /// The currently-rendered route polyline overlay (nil if no active route).
        private var routePolylineOverlay: RoutePolyline? = nil
        /// The UUID of the route whose polyline is currently rendered.
        private var renderedRouteID: UUID? = nil
        /// The currently-rendered destination pin annotation.
        private var destinationPinAnnotation: DestinationPinAnnotation? = nil
        /// The coordinate of the currently-rendered destination pin (encoded as a tuple for equality).
        private var renderedDestinationCoord: (Double, Double)? = nil

        // W8.5c: Heading-up rotation state.
        /// Last heading value applied to the camera (R-1 dead-band guard).
        /// Nil before the first Drive Mode heading update.
        /// Port of drivingLastAppliedHeading (index.html:6583).
        var lastAppliedHeading: Double? = nil

        // MARK: - W8.5c-polish PR-2: Drive Mode prior-distance tracking

        /// The `centerCoordinateDistance` captured at Drive Mode entry.
        ///
        /// Written by `applyDriveCameraState(active: true, ...)` just before the transition
        /// so the `applyDrivePitch` closure (which receives priorPitch but not priorDistance)
        /// can still issue a correctly-combined single `setCamera` for both pitch and zoom.
        ///
        /// The combined approach avoids two sequential `setCamera` calls (which would fire
        /// `regionDidChangeAnimated` twice) per spec §3.4.
        var lastCapturedPriorDistance: CLLocationDistance = 0

        init(parent: MapViewRepresentable) {
            self.parent = parent
        }

        // MARK: - Overlay application

        func applyOverlayPayload(_ payload: OverlayPayload, to mapView: MKMapView) {
            // Build new TaggedMultiPolyline objects for each state group.
            // Only replace groups whose coordinate set is non-empty (or the old overlay
            // needs to be cleared because the set is now empty).

            let groups: [(OverlayTag, [[CLLocationCoordinate2D]])] = [
                (.freeComfortably,         payload.freeComfortably),
                (.freeButRestrictionSoon,  payload.freeButRestrictionSoon),
                (.meteredActive,           payload.meteredActive),
                (.restrictedNow,           payload.restrictedNow),
                (.unknown,                 payload.unknown),
            ]

            for (tag, coordArrays) in groups {
                // Remove old overlay for this group if present.
                if let old = multiPolylines[tag] {
                    mapView.removeOverlay(old)
                    multiPolylines[tag] = nil
                }
                // Only add if there are segments in this group.
                guard !coordArrays.isEmpty else { continue }

                // Build [MKPolyline] children from coord arrays.
                let children = coordArrays.compactMap { coords -> MKPolyline? in
                    guard coords.count >= 2 else { return nil }
                    var mutable = coords
                    return MKPolyline(coordinates: &mutable, count: mutable.count)
                }
                guard !children.isEmpty else { continue }

                let multi = TaggedMultiPolyline(children)
                multi.overlayTag = tag
                multiPolylines[tag] = multi
                mapView.addOverlay(multi, level: .aboveRoads)
            }

            // Selected-block highlight (group 6).
            if let old = selectedPolyline {
                mapView.removeOverlay(old)
                selectedPolyline = nil
            }
            if let coords = payload.selectedCoords, coords.count >= 2 {
                var mutable = coords
                let sel = SelectedPolyline(coordinates: &mutable, count: mutable.count)
                sel.currentState = payload.selectedState
                selectedPolyline = sel
                mapView.addOverlay(sel, level: .aboveRoads)
            }

            // S-1 fix (PR #29 QA pass-1 S-1): re-insert the RoutePolyline so it sits
            // above the parking-state overlays after this rebuild.
            //
            // applyOverlayPayload removes and re-adds all 5 TaggedMultiPolyline groups
            // and the SelectedPolyline — but leaves the RoutePolyline in place.
            // MKMapView renders overlays in insertion order at the same level, so the
            // parking overlays now sit above the pre-existing RoutePolyline in the stack.
            //
            // Fix approach A: if a RoutePolyline is currently rendered, remove it and
            // re-add it last so it ends up at the top of the .aboveRoads stack.
            // syncRoutePolyline is NOT called here because the route geometry hasn't
            // changed — only its position in the overlay stack needs refreshing.
            if let existing = routePolylineOverlay {
                mapView.removeOverlay(existing)
                mapView.addOverlay(existing, level: .aboveRoads)
            }
        }

        // MARK: - W5: Car pin annotation management

        /// Syncs the car-pin annotation to match the current ParkedCar state.
        /// Called from updateUIView on every SwiftUI render cycle.
        func syncCarPin(_ car: ParkedCar?, on mapView: MKMapView) {
            let newID = car?.id

            // Fast path: nothing changed.
            if renderedCarPinID == newID { return }

            // Remove old annotation if present.
            if let old = carPinAnnotation {
                mapView.removeAnnotation(old)
                carPinAnnotation = nil
            }

            // Add new annotation if a car pin is set.
            if let car = car {
                let annotation = CarPinAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(
                    latitude: car.latitude,
                    longitude: car.longitude
                )
                annotation.accessibilityLabel = "My parked car. Tap for parking details."
                carPinAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            renderedCarPinID = newID
        }

        // MARK: - W8.5b: Route polyline management

        /// Syncs the route polyline overlay to match the current `DriveRoute`.
        /// The route polyline renders above all parking-state overlays (OQ-4, OQ-8).
        func syncRoutePolyline(_ route: DriveRoute?, on mapView: MKMapView) {
            let newID = route?.id

            // Fast path: same route already rendered.
            if renderedRouteID == newID { return }

            // Remove old route polyline.
            if let old = routePolylineOverlay {
                mapView.removeOverlay(old)
                routePolylineOverlay = nil
            }

            // Add new route polyline if a route is present.
            if let route = route, !route.geometry.isEmpty {
                var coords = route.geometry
                let polyline = RoutePolyline(coordinates: &coords, count: coords.count)
                routePolylineOverlay = polyline
                // Insert above all parking-state overlays (.aboveRoads level).
                // MKMapView renders overlays in insertion order at the same level —
                // adding last ensures it renders on top of the 5 state groups + selected highlight.
                mapView.addOverlay(polyline, level: .aboveRoads)
            }

            renderedRouteID = newID
        }

        // MARK: - W8.5b: Destination pin management

        /// Syncs the destination pin annotation to match the current `destinationCoordinate`.
        func syncDestinationPin(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            let newCoord = coordinate.map { ($0.latitude, $0.longitude) }

            // Fast path: same coordinate already rendered.
            if let existing = renderedDestinationCoord, let new = newCoord,
               existing.0 == new.0, existing.1 == new.1 { return }
            if renderedDestinationCoord == nil && newCoord == nil { return }

            // Remove old annotation.
            if let old = destinationPinAnnotation {
                mapView.removeAnnotation(old)
                destinationPinAnnotation = nil
            }

            // Add new annotation if a destination is set.
            if let coordinate = coordinate {
                let annotation = DestinationPinAnnotation()
                annotation.coordinate = coordinate
                annotation.accessibilityLabel = "Drive Mode destination"
                destinationPinAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            renderedDestinationCoord = newCoord
        }

        // MARK: - W8.5c: Heading-up rotation

        /// Applies the stabilized Drive Mode heading to the map camera.
        ///
        /// Port of `setDrivingMapRotation` (index.html:6584–6601) with R-1 dead-band guard:
        ///   - If `heading` is nil (Drive Mode off), reset camera to north-up (heading = 0).
        ///   - If heading changed by <= 5 degrees, skip (avoids regionDidChangeAnimated feedback loop).
        ///   - If changed by > 5 degrees, create a new MKMapCamera and call setCamera(_:animated:false).
        ///
        /// Called from updateUIView on every SwiftUI render cycle that has a new driveHeading.
        func syncDriveHeading(_ heading: Double?, on mapView: MKMapView) {
            if let h = heading {
                // Check dead-band (R-1 anti-loop). Only update if changed > 5 degrees.
                if let last = lastAppliedHeading {
                    let diff = MapViewRepresentable.headingDiff(h, last)
                    guard diff > 5 else { return }
                }
                lastAppliedHeading = h
                let camera = mapView.camera.copy() as! MKMapCamera
                camera.heading = h
                mapView.setCamera(camera, animated: false)

                // PR-2: Rotate the directional puck to match the new heading.
                // `mapView.view(for:)` returns the annotation view if visible; nil if off-screen.
                // The rotation is applied directly to the view's transform — no new setCamera.
                let headingRad = CGFloat(h * .pi / 180.0)
                mapView.view(for: mapView.userLocation)?.transform =
                    CGAffineTransform(rotationAngle: headingRad)
            } else {
                // Drive Mode exited — reset to north-up and clear state.
                guard lastAppliedHeading != nil else { return }
                lastAppliedHeading = nil
                let camera = mapView.camera.copy() as! MKMapCamera
                camera.heading = 0
                mapView.setCamera(camera, animated: false)
            }
        }

        // MARK: - W8.5c-polish PR-3: Drive Mode camera pitch

        /// Applies or restores the Drive Mode camera pitch + zoom in a SINGLE `setCamera` call.
        ///
        /// Called from ContentView's `.onChange(of: driveModeActive)` handler via
        /// `CoordinatorActions.applyDrivePitch` — OUTSIDE `updateUIView`. This is the
        /// architectural fix for the #31 regression: the reverted W8.5c-polish called
        /// `setCamera` synchronously inside `updateUIView`, racing SwiftUI's in-progress
        /// view-update cycle and dropping the entire `.safeAreaInset(...)` overlay chain.
        ///
        /// PR-2 change: this method now sets BOTH pitch AND `centerCoordinateDistance`
        /// in a single `setCamera(animated: true)` call (spec §3.4 single-call requirement).
        /// Using a single call avoids two `regionDidChangeAnimated` events (one per `setCamera`),
        /// which would each trigger `updateUIView` → `syncDriveHeading`. The existing
        /// `lastAppliedHeading` dead-band would absorb both, but the single-call approach
        /// eliminates the double-fire risk entirely.
        ///
        /// On Drive Mode entry (`active` = true):
        ///   - Captures `priorDistance` from the current camera and stores it in
        ///     `lastCapturedPriorDistance` for use by the `applyDrivePitch` closure.
        ///   - Animates pitch to `driveModePitch` (45°) AND
        ///     `centerCoordinateDistance` to `altitudeForSpan(driveModeCameraSpan)` (~2,000m).
        ///   - Single `setCamera(animated: true)` call — smooth ~0.3s ease.
        ///
        /// On Drive Mode exit (`active` = false):
        ///   - Restores `priorPitch` and `priorDistance` captured at entry.
        ///   - Single `setCamera(animated: true)` call.
        ///
        /// R-1 coexistence: fired exactly once per transition via `.onChange`, not per `updateUIView`.
        /// The resulting `regionDidChangeAnimated` → `syncDriveHeading` dead-band absorbs it.
        ///
        /// W8.5d note: pass an explicit pitch value to support final-approach pitch escalation
        /// (e.g., 60° inside the last 500m) without restructuring this method.
        ///
        /// - Parameters:
        ///   - active: Drive Mode entering (true) or exiting (false).
        ///   - priorPitch: Pitch captured at Drive Mode entry; restored on exit.
        ///   - mapView: The live `MKMapView` instance.
        func applyDriveCameraState(
            active: Bool,
            priorPitch: CGFloat,
            priorDistance: CLLocationDistance,
            on mapView: MKMapView
        ) {
            // On entry: stash the current distance before overwriting it with the Drive Mode zoom.
            if active {
                lastCapturedPriorDistance = mapView.camera.centerCoordinateDistance
            }

            let targetPitch = MapViewRepresentable.targetPitch(
                forDriveModeActive: active,
                priorPitch: priorPitch
            )

            // Compute target centerCoordinateDistance.
            // On entry: altitudeForSpan(driveModeCameraSpan) ≈ 2,000m.
            // On exit: restore the distance captured at entry.
            let finalDistance: CLLocationDistance
            if active {
                finalDistance = MapViewRepresentable.altitudeForSpan(
                    MapViewRepresentable.driveModeCameraSpan
                )
            } else {
                // Use the explicitly-passed priorDistance when available (ContentView passes it);
                // fall back to lastCapturedPriorDistance if caller passed 0 (legacy path).
                finalDistance = priorDistance > 0 ? priorDistance : lastCapturedPriorDistance
            }

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.pitch = targetPitch
            camera.centerCoordinateDistance = finalDistance
            // Single combined setCamera for pitch + zoom (spec §3.4).
            // One setCamera → one regionDidChangeAnimated → one syncDriveHeading call.
            // The lastAppliedHeading dead-band absorbs it. No feedback loop possible.
            mapView.setCamera(camera, animated: true)
        }

        /// Entry point called by the `applyDrivePitch` CoordinatorActions closure.
        ///
        /// Forwards to `applyDriveCameraState` using the prior distance stored in
        /// `lastCapturedPriorDistance` (set by ContentView via `captureCurrentDistance`
        /// before calling this closure). This keeps the combined pitch+zoom single-call
        /// path intact while preserving backwards compatibility with the closure signature
        /// established in PR-3.
        func applyDriveCameraPitch(active: Bool, priorPitch: CGFloat, on mapView: MKMapView) {
            applyDriveCameraState(
                active: active,
                priorPitch: priorPitch,
                priorDistance: lastCapturedPriorDistance,
                on: mapView
            )
        }

        // MARK: - W8.5c-polish PR-3: Pitch-preserving Drive Mode region sync

        /// Recenters the map on the given region's center coordinate during Drive Mode,
        /// preserving the current camera pitch and heading.
        ///
        /// Called from `updateUIView` when `driveModeActive` is true and the map center has
        /// diverged from the SwiftUI `region` binding — i.e., a follow-mode recenter was
        /// requested by `recenterDriveMap` in ContentView. `setRegion(_:animated:)` is banned
        /// here because it resets camera pitch to 0, clobbering the 30° Drive Mode tilt.
        ///
        /// Implementation: copies the current `MKMapCamera` (preserving `pitch`, `heading`,
        /// and `centerCoordinateDistance`) and sets only `centerCoordinate` to the new center.
        /// Uses `animated: false` to match the non-Drive-Mode `setRegion(animated: false)` path
        /// and avoid fighting `syncDriveHeading`'s own `setCamera` calls.
        ///
        /// - Parameters:
        ///   - region: The SwiftUI `region` binding value — only `center` is used.
        ///   - mapView: The live `MKMapView` instance.
        func syncDriveRegion(_ region: MKCoordinateRegion, on mapView: MKMapView) {
            let mapRegion = mapView.region
            let latDiff = abs(mapRegion.center.latitude  - region.center.latitude)
            let lngDiff = abs(mapRegion.center.longitude - region.center.longitude)
            guard latDiff > 0.0001 || lngDiff > 0.0001 else { return }

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinate = region.center
            // pitch and heading are preserved from the copied camera — no pitch reset.
            mapView.setCamera(camera, animated: false)
        }

        // MARK: - MKMapViewDelegate: annotation view

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // MARK: PR-2: Directional user puck (mechanism b — spec §3.7).
            //
            // During Drive Mode, replace the system blue dot with a heading-aware arrow icon.
            // Mechanism (b): custom MKAnnotationView for MKUserLocation — NO userTrackingMode
            // change. `syncDriveHeading` continues to own camera rotation; this only rotates
            // the puck image. The two are orthogonal (no conflict with `syncDriveHeading`).
            //
            // The puck image is rotated to match `driveHeading`. `mapView(_:viewFor:)` fires
            // once when the annotation is first added; subsequent heading updates rotate the
            // view in `syncDriveHeading` via `mapView.view(for: mapView.userLocation)?.transform`.
            //
            // On Drive Mode exit, `refreshUserLocationPuck` toggles `showsUserLocation` which
            // causes MapKit to re-query this delegate — then `parent.driveModeActive` is false
            // so we return nil and MapKit renders the default blue dot.
            if annotation is MKUserLocation {
                guard parent.driveModeActive else { return nil }
                let reuseID = "driveUserPuck"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
                view.annotation = annotation

                // SF Symbol arrow pointing north. Tinted system blue to match the default puck.
                let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
                view.image = UIImage(systemName: "location.north.fill", withConfiguration: config)?
                    .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)

                // Apply current heading rotation. CGAffineTransform rotation is in radians,
                // clockwise from north. MKMapView coordinate system: 0° = north, clockwise.
                let headingRad = CGFloat((parent.driveHeading ?? 0) * .pi / 180.0)
                view.transform = CGAffineTransform(rotationAngle: headingRad)

                view.canShowCallout = false
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Your current location and heading"
                view.accessibilityTraits = .staticText
                return view
            }

            // Handle DestinationPinAnnotation (W8.5b) — red mappin.circle.fill (OQ-6).
            if annotation is DestinationPinAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.destinationPinReuseID,
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: Coordinator.destinationPinReuseID
                )
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "mappin")
                view.canShowCallout = false
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Drive Mode destination"
                view.accessibilityTraits = .staticText
                return view
            }

            // Only handle CarPinAnnotation — let the map handle user location etc.
            guard annotation is CarPinAnnotation else { return nil }

            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Coordinator.carPinReuseID,
                for: annotation
            )

            // W5 spec §5.1: mappin.circle.fill, 36pt, palette mode, white + systemBlue.
            let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .medium)
                .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
            let image = UIImage(systemName: "mappin.circle.fill", withConfiguration: config)
            view.image = image

            // Shift the annotation view so its bottom tip sits at the coordinate.
            // The symbol is 36pt tall; center is at 18pt from top → offset up by 18pt.
            view.centerOffset = CGPoint(x: 0, y: -18)

            // Drop shadow for visual separation from polylines.
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.3
            view.layer.shadowOffset = CGSize(width: 0, height: 2)
            view.layer.shadowRadius = 3

            // Accessibility: read as a distinct tap target.
            view.isAccessibilityElement = true
            view.accessibilityLabel = "My parked car. Tap for parking details."
            view.accessibilityTraits = .button

            // canShowCallout = false — we handle taps via gesture recognizer to
            // show ParkedCarDetailView (a full sheet) rather than a callout bubble.
            view.canShowCallout = false

            return view
        }

        // MARK: - MKMapViewDelegate: renderer

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? TaggedMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
                // .butt caps stop exactly at the polyline endpoint with no extension.
                // Combined with the 10m intersection setback in build/preprocess.js, this
                // produces visible gaps at intersections. .round caps would re-fill the gap
                // by ~lineWidth/2 on each end. lineJoin stays .round for smooth segment
                // bends within a block (mid-block curves on Manhattan avenues).
                renderer.lineCap = .butt
                renderer.lineJoin = .round
                switch multi.overlayTag {
                case .freeComfortably:
                    renderer.strokeColor = UIColor(ParkingColors.freeComfortably)
                    renderer.lineWidth = 3
                case .freeButRestrictionSoon:
                    renderer.strokeColor = UIColor(ParkingColors.restrictionComingSoon)
                    renderer.lineWidth = 3
                case .meteredActive:
                    renderer.strokeColor = UIColor(ParkingColors.meteredActive)
                    renderer.lineWidth = 4
                case .restrictedNow:
                    renderer.strokeColor = UIColor(ParkingColors.restricted)
                    renderer.lineWidth = 3
                case .unknown:
                    renderer.strokeColor = UIColor(ParkingColors.unknown)
                    renderer.lineWidth = 3
                case .selectedBlock:
                    // Should not be reached (selected overlay uses SelectedPolyline, not TaggedMultiPolyline).
                    renderer.strokeColor = UIColor.systemBlue
                    renderer.lineWidth = 6
                case .routePolyline:
                    // Should not be reached (route overlay uses RoutePolyline, not TaggedMultiPolyline).
                    renderer.strokeColor = UIColor.systemBlue
                    renderer.lineWidth = 5
                }
                return renderer
            }

            if let sel = overlay as? SelectedPolyline {
                let renderer = MKPolylineRenderer(polyline: sel)
                renderer.strokeColor = UIColor(sel.currentState.swiftUIColor)
                renderer.lineWidth = 6
                renderer.lineCap = .butt   // see TaggedMultiPolyline comment above
                renderer.lineJoin = .round
                return renderer
            }

            // W8.5b: Drive Mode route polyline (OQ-8: .systemBlue, lineWidth 5, round caps).
            if overlay is RoutePolyline, let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            // Fallback for any unexpected overlay type (e.g. user location annotation).
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: - MKMapViewDelegate: camera

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // W8.5c: Detect user-initiated pans during Drive Mode (follow mode detection).
            // We distinguish user gestures from programmatic updates by checking if any of
            // the map's gesture recognizers is in a state that indicates a user interaction.
            // `animated == false` doesn't reliably distinguish user vs programmatic on MKMapView.
            guard parent.driveHeading != nil else { return }
            let isUserGesture = mapView.gestureRecognizers?.contains(where: {
                $0.state == .began || $0.state == .changed || $0.state == .ended
            }) ?? false
            if isUserGesture {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onDrivePanDetected?()
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            // Defer the SwiftUI state write to the next run loop cycle.
            // regionDidChangeAnimated fires from a MapKit animation callback that can
            // overlap with SwiftUI's render pass — writing @State synchronously here
            // triggers "Modifying state during view update" warnings.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onRegionChanged(region)
            }
        }

        // MARK: - Tap handling

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = mapView,
                  recognizer.state == .ended else { return }
            let screenPoint = recognizer.location(in: mapView)

            // W5: Check if the tap is on the car-pin annotation view before
            // forwarding to the block-selection handler.
            if let pinAnnotation = carPinAnnotation,
               let pinView = mapView.view(for: pinAnnotation) {
                // Hit-test within a 30pt radius of the pin view center.
                let pinCenter = mapView.convert(pinAnnotation.coordinate, toPointTo: mapView)
                let dx = screenPoint.x - pinCenter.x
                let dy = screenPoint.y - pinCenter.y
                let distancePt = sqrt(dx * dx + dy * dy)
                if distancePt <= 30 {
                    // The tap is on the car pin — suppress map-tap and fire car-pin handler.
                    _ = pinView  // suppress unused-variable warning
                    // Defer SwiftUI state mutation out of the UIKit gesture callback.
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.onCarPinTapped()
                    }
                    return
                }
            }

            // W8.5b: Absorb taps on the destination pin annotation — no action in W8.5b.
            // W8.5d will add arrival prompt handling here.
            if let destAnnotation = destinationPinAnnotation {
                let destCenter = mapView.convert(destAnnotation.coordinate, toPointTo: mapView)
                let dx = screenPoint.x - destCenter.x
                let dy = screenPoint.y - destCenter.y
                if sqrt(dx * dx + dy * dy) <= 30 {
                    return  // Absorbed — no map-tap fired.
                }
            }

            let coordinate = mapView.convert(screenPoint, toCoordinateFrom: mapView)
            // Defer SwiftUI state mutation out of the UIKit gesture callback.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onTap(coordinate)
            }
        }

        // MARK: - W5: Long-press handling

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let mapView = mapView,
                  recognizer.state == .began else { return }
            let screenPoint = recognizer.location(in: mapView)
            let coordinate = mapView.convert(screenPoint, toCoordinateFrom: mapView)
            // Defer SwiftUI state mutation out of the UIKit gesture callback.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onLongPress(coordinate)
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        /// Allow all recognizers to fire simultaneously with MKMapView's built-in
        /// recognizers so that map gestures (pan, pinch, double-tap-to-zoom) continue
        /// to work alongside our block-tap and long-press logic.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }
}

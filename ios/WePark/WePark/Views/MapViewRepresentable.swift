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

    // MARK: Community 1.0 / Tier 1: Community pin annotations

    /// Community pins to render as map markers (filming + special_event only).
    /// Pushed from ContentView via `.onChange(of: pinService.visiblePins)` — NEVER inside
    /// `updateUIView` (invariant I-1, spec §5.1).
    ///
    /// Default: empty (no markers until the first visible-pins update).
    var communityPins: [CommunityPin] = []

    /// Fired from the Coordinator when the user taps a `CommunityPinAnnotation`.
    /// ContentView sets `activeSheet = .pinDetail(pin)` in response.
    /// Default: nil (no-op).
    var onCommunityPinTapped: ((CommunityPin) -> Void)? = nil

    /// FT-11: Currently-loaded tile segments, used to compute directional chevron bearings
    /// for enforcement_active and sweeper_passed community pins.
    ///
    /// Passed from ContentView's `tileLoader.segments`. Used only in
    /// `syncCommunityPinAnnotations` to look up a pin's segment by `segmentId` so the
    /// bearing can be computed at annotation-build time.
    ///
    /// Default: empty (no segments until tiles load; bearing defaults to nil = no chevron).
    var segments: [Segment] = []

    // MARK: W8.5c: Heading-up rotation

    /// Stabilized Drive Mode heading in degrees [0, 360). Non-nil → camera heading set.
    /// Nil → reset camera heading to north-up (0).
    /// Dead-band: only applied when heading changes by > 5 degrees (R-1 anti-loop guard).
    /// Default: nil (Drive Mode not active).
    var driveHeading: Double? = nil

    /// Whether Drive Mode is currently active.
    ///
    /// Used to gate the heading-sync path (`syncDriveHeading`) and the directional puck
    /// rendering in `mapView(_:viewFor:)`. Phase 2: Drive Mode position follow is owned
    /// natively by MapKit (`.follow` tracking mode set via `CoordinatorActions.setDriveTrackingMode`).
    ///
    /// On the simulator there is no magnetometer, so `driveHeading` is always nil during
    /// Drive Mode — the original guard `if driveHeading == nil` failed to suppress `setRegion`
    /// in the sim, flattening pitch on every location update. This property fixes that.
    var driveModeActive: Bool = false

    // MARK: - Phase 2: Tracking-mode change output callback

    /// Phase 2: Called when MapKit changes `userTrackingMode` — including when a user pan
    /// during Drive Mode causes MapKit to break `.follow` (setting mode to `.none`).
    ///
    /// This is an OUTPUT closure: Coordinator → ContentView. It follows the same pattern
    /// as `onRegionChanged` and replaces the deleted `onDrivePanDetected`.
    ///
    /// ContentView responds by updating `driveTrackingModeNone` @State to show/hide the
    /// Recenter button. When `mode == .none` during Drive Mode → show Recenter. When
    /// `mode != .none` → hide Recenter.
    ///
    /// Default: nil (no-op). Set from ContentView's `mapRepresentable` property.
    var onTrackingModeChanged: ((MKUserTrackingMode) -> Void)? = nil

    // MARK: - W8.5c-polish PR-3 / PR-2: Drive Mode camera constants + pure-function decisions

    /// Camera pitch applied during Drive Mode.
    ///
    /// TF2-6 (Issue 2b): Lowered 45° → 30° to match Apple/Waze navigation behaviour.
    /// At 30° the road ahead is clearly visible without the steep forward-lean that causes
    /// 3D buildings to occlude lane markings and parking lines (the reported issue).
    ///
    /// PR-2 shipped 45° — measured faithful (not clamped) at the tighter zoom ~0.003° span.
    /// 30° is also faithful at this altitude (~621m via altitudeForSpan); MapKit only clamps
    /// pitch at wide altitudes (~180,000m where ceiling ≈ 35°). At ~621m the ceiling is 60°+.
    ///
    /// Kevin: tune on-device. Try 35° if more depth is wanted; use 25° for a flatter view.
    ///
    /// W8.5d note: `applyDriveCameraState` is reusable for final-approach pitch escalation
    /// without structural change — call it with a different pitch value in the last 500m.
    static let driveModePitch: CGFloat = 30

    /// Target latitude span during Drive Mode.
    ///
    /// FT-8: Tightened from 0.005° (~1,036m altitude) to 0.003° (~621m altitude).
    /// At 0.003°, the camera focuses on roughly one Manhattan block, improving the
    /// "current block" UX intent without losing all cross-street context.
    ///
    /// Kevin: tune on-device — 0.0025° (~518m) if tighter, 0.004° if wider.
    /// Altitude computed via altitudeForSpan(_:): halfH = (span/2)*111,000 / tan(15°).
    ///   0.003° → halfH = 166.5m → altitude ≈ 621m.
    static let driveModeCameraSpan: CLLocationDegrees = 0.003

    /// Animation duration for Drive Mode camera + puck transitions (FT-7).
    ///
    /// 0.3s allows each GPS-fix animation to complete with 0.7s to spare at 1 Hz cadence.
    /// Mid-animation retargeting: setCamera(animated:true) while a previous one is in flight
    /// cancels the in-flight animation and starts fresh — no stacking.
    ///
    /// Kevin: tune on-device — try 0.5s if 0.3s feels abrupt on a real-device drive-test.
    static let driveAnimationDuration: TimeInterval = 0.3

    // MARK: - TF2-11 Option C: Drive Mode camera zoom range clamp constants

    /// Minimum `centerCoordinateDistance` (altitude in meters) enforced during Drive Mode.
    ///
    /// Prevents the user from zooming tighter than ~150m during Drive Mode navigation.
    /// Our target altitude (~621m via altitudeForSpan(driveModeCameraSpan)) is well above
    /// this floor, so the clamp does not affect our entry setCamera or Recenter transitions.
    ///
    /// Kevin: tune on-device — 100m if tighter is acceptable, 200m if 150m feels too tight.
    ///
    /// C-AC-3: minDriveZoomDistance ≤ altitudeForSpan(driveModeCameraSpan) ≈ 621m. ✓
    static let minDriveZoomDistance: CLLocationDistance = 150

    /// Maximum `centerCoordinateDistance` (altitude in meters) enforced during Drive Mode.
    ///
    /// TF2-11 clamp: prevents MapKit's `.follow` from re-asserting its wide default altitude
    /// on each GPS update. By capping at 900m (just above our ~621m target), `.follow`'s
    /// zoom-to-default is blocked at the ceiling — the camera stays near the FT-8 tight zoom.
    ///
    /// Per Apple docs: `setCameraZoomRange` constrains "both programmatic and user-initiated"
    /// zooming. Whether "programmatic" covers MapKit's own tracking-mode re-assert is the
    /// experiment question (§5 / §6.1). If it does, TF2-11 closes here. If it doesn't, fall
    /// through to Option A.
    ///
    /// OQ-2 resolution: Kevin approved the experiment with the spec-recommended 900m value.
    ///
    /// Kevin: tune on-device — lower this if you want a tighter ceiling; raise (e.g. 1500m)
    /// if you want more zoom freedom while driving. Note: reducing the gap between target
    /// (~621m) and ceiling narrows the buffer against .follow's re-assert.
    ///
    /// C-AC-3: altitudeForSpan(driveModeCameraSpan) ≈ 621m ≤ maxDriveZoomDistance = 900m. ✓
    static let maxDriveZoomDistance: CLLocationDistance = 900

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
        // Formula from the spec (§3.5) and the reverted PR's `altitudeForSpan`:
        //   altitude = halfHeightMeters / tan(halfFovAngle)
        // where halfFovAngle = 15° (half of MapKit's default ~30° vertical half-FOV,
        // giving a ~60° total vertical FOV for a standard iPhone viewport).
        // At 0.005° span: halfHeight = (0.005/2)*111,000 = 277.5m; altitude ≈ 1,035m.
        let metersPerDegree: CLLocationDistance = 111_000
        let halfHeightMeters = (latitudeDelta / 2.0) * metersPerDegree
        return halfHeightMeters / tan(15.0 * .pi / 180.0)
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

        // MARK: Phase 1: Programmatic browse-mode recenter

        /// Directly moves the camera to the given region (animated). Used by browse-mode
        /// recenter actions (find-me, find-car, search result, launch center) after the
        /// Phase 1 removal of the `setRegion` push in `updateUIView`.
        ///
        /// Wired in `makeUIView` to call `mapView.setRegion(_:animated:true)` directly —
        /// outside `updateUIView` (satisfying the #31 architectural invariant: no camera
        /// mutation inside `updateUIView`). ContentView calls this closure from its
        /// action handlers (themselves outside SwiftUI's view-update cycle).
        var setRegion: ((MKCoordinateRegion) -> Void)?

        // MARK: Phase 2: Native Drive Mode follow

        /// Engages or disengages native MapKit position-follow in Drive Mode.
        ///
        /// `true`  → `mapView.userTrackingMode = .follow` (smooth native position centering).
        /// `false` → `mapView.userTrackingMode = .none` (MapKit releases position follow).
        ///
        /// Called from ContentView's `.onChange(of: driveModeActive)` handler — OUTSIDE
        /// `updateUIView` — so the tracking-mode set never races SwiftUI's view-update cycle.
        ///
        /// Design note: `.follow` (not `.followWithHeading`) is used intentionally.
        ///   - `.follow` centers position natively; MapKit does NOT rotate the map heading.
        ///   - `syncDriveHeading` continues to set `camera.heading` from GPS course (FT-7).
        ///   - The two are orthogonal: `setCamera(heading:)` does NOT reset `userTrackingMode`.
        ///     MapKit's follow resumes centering on the next GPS fix without conflict.
        ///   - `.followWithHeading` would use the compass (magnetometer) for rotation — exactly
        ///     the FT-7 bug (askew when phone is mounted at an angle). Explicitly rejected.
        var setDriveTrackingMode: ((Bool) -> Void)?

        // MARK: TF2-6: 3D buildings toggle

        /// Shows or hides 3D building extrusions on the map.
        ///
        /// TF2-6 (Issue 2a): `MKStandardMapConfiguration` does not expose a `showsBuildings`
        /// property; the flag lives on `MKMapView` itself (`mapView.showsBuildings`).
        /// Toggling it here (via CoordinatorActions, called from ContentView's
        /// `.onChange(of: driveModeActive)` — OUTSIDE `updateUIView`) satisfies the #31
        /// architectural invariant (no UIKit state mutation inside `updateUIView`).
        ///
        /// `false` → hide 3D buildings during Drive Mode (flat nav map, matching Apple/Waze).
        /// `true`  → restore 3D buildings on Drive Mode exit.
        ///
        /// Kevin: change the `false` to `true` in ContentView's handleDriveCameraChange
        /// if you prefer buildings visible during Drive Mode navigation.
        var setShowsBuildings: ((Bool) -> Void)?

        // MARK: TF2-8: Post-follow drive-camera re-apply flag

        /// One-shot flag set on Drive Mode entry to trigger a camera re-apply after
        /// MapKit's `.follow` asynchronous zoom-to-default settles.
        ///
        /// Root cause (TF2-8, confirmed on-device): setting `.follow` causes MapKit to perform
        /// its own zoom-to-default ASYNCHRONOUSLY — after our synchronous `setCamera` in
        /// `handleDriveModeAndCamera`. The asynchronous follow animation clobbers the tight
        /// FT-8 zoom we set, leaving the camera at MapKit's default wide altitude.
        ///
        /// Fix: when the flag is set and `regionDidChangeAnimated` fires (after MapKit's
        /// animation completes), the Coordinator re-applies the drive camera pitch+zoom.
        /// The flag is then cleared (ONE-SHOT) so the re-apply's own `regionDidChangeAnimated`
        /// does not re-trigger another re-apply (idempotence).
        ///
        /// Additional idempotence guard (TF2-8 spec): the re-apply is skipped if the current
        /// altitude is already within 25% of the target — this avoids a visible double-animation
        /// when MapKit happened NOT to zoom out (e.g., user had already tight zoom before entry).
        ///
        /// Cleared on Drive Mode exit (`handleDriveModeAndCamera(false)`) so a quick entry/exit
        /// sequence cannot leave a stale flag.
        ///
        /// Must NOT fire on the Recenter path: `recenterDriveMode` calls `applyDrivePitch`
        /// directly (which already applies pitch+zoom) and does not set this flag.
        var pendingDriveCameraReapply: Bool = false

        /// The preDrivePitch value captured at Drive Mode entry, stored here so the
        /// Coordinator's `regionDidChangeAnimated` hook can pass the correct prior pitch
        /// to `applyDrivePitch` during the re-apply (without needing to round-trip through
        /// ContentView state, which would require a dispatch or a binding).
        var pendingReapplyPriorPitch: CGFloat = 0

        // MARK: TF2-11 Option C: Camera zoom range clamp

        /// Engages or removes the Drive Mode camera zoom range clamp.
        ///
        /// `true`  (entry) → applies `setCameraZoomRange(minCenterCoordinateDistance:
        ///                   minDriveZoomDistance, maxCenterCoordinateDistance:
        ///                   maxDriveZoomDistance)` to block MapKit's `.follow` re-assert.
        /// `false` (exit)  → restores the unrestricted range via `setCameraZoomRange(nil)`.
        ///
        /// Called from ContentView's `handleDriveModeAndCamera(_:)` — OUTSIDE `updateUIView`
        /// — so the range constraint never races SwiftUI's view-update cycle (#31 invariant).
        ///
        /// Placement in handleDriveModeAndCamera:
        ///   ENTRY: setZoomRange(true) BEFORE setDriveTrackingMode(true) so the clamp is in
        ///          place before `.follow` can re-assert.
        ///   EXIT:  setZoomRange(false) AFTER setDriveTrackingMode(false) so the clamp is
        ///          held until tracking is fully released.
        var setZoomRange: ((Bool) -> Void)?

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

    // MARK: - FT-7: Shortest-arc rotation delta pure helper

    /// Returns the shortest angular path from `from` to `to` in radians, in (-π, π].
    ///
    /// Without this helper, a puck rotating from 359° to 1° would animate the long way
    /// (spinning 358° counter-clockwise instead of 2° clockwise). This function ensures
    /// UIView.animate uses the correct arc direction for every heading update.
    ///
    /// - Parameters:
    ///   - from: Current rotation angle in radians (any value; will be normalized).
    ///   - to: Target rotation angle in radians (any value; will be normalized).
    /// - Returns: The signed delta in (-π, π] to add to `from` to reach `to` by the shortest arc.
    static func shortestArcDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = to - from
        // Normalize to (-π, π] so the rotation takes the short arc, never the long way.
        while delta >  .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true  // W5.1: show blue dot for recenter feature
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
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

        // Community 1.0 / Tier 1: Register community pin annotation view class.
        mapView.register(
            PinMarkerAnnotation.self,
            forAnnotationViewWithReuseIdentifier: PinMarkerAnnotation.reuseIdentifier
        )

        // Set initial camera region.
        mapView.setRegion(region, animated: false)

        // W5: UILongPressGestureRecognizer for pin-drop / report dialog.
        // 0.4s minimum duration — slightly faster than iOS default (0.5s) for better
        // responsiveness on a small phone. Above the 0.3s accidental-tap-hold threshold.
        //
        // IMPORTANT: longPress is declared BEFORE tap so tap.require(toFail: longPress)
        // can reference it. The gesture priority rule (Bug #3 fix): a long-press on any
        // surface — including over a street-segment polyline — must always win over the
        // segment-tap handler. Without require(toFail:), UIKit fires BOTH recognizers
        // concurrently (because shouldRecognizeSimultaneously returns true), so a 0.4s
        // hold on a segment would simultaneously open BlockDetailView AND the
        // confirmationDialog. require(toFail:) delays the tap until the 0.4s window
        // passes without a long-press — if the long-press fires, the tap is cancelled.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.4
        longPress.delegate = context.coordinator
        mapView.addGestureRecognizer(longPress)

        // UITapGestureRecognizer for block taps.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Bug #3 fix: require the long-press to fail before the tap fires.
        // This means: if the user holds for >= 0.4s (long-press threshold), the tap is
        // cancelled and only the long-press handler fires. A normal quick tap (< 0.4s)
        // lets the long-press fail naturally (it never reaches .began), so the tap fires
        // as expected. This ensures long-press ALWAYS wins over segment-tap regardless
        // of which surface is touched.
        tap.require(toFail: longPress)
        // Allow simultaneous recognition with MKMapView's built-in gesture recognizers
        // (needed so map gestures like pan/pinch still work alongside our tap).
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)

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

        // Phase 1: Browse-mode programmatic recenter closure.
        // After removing the `setRegion` push in `updateUIView`, browse-mode recenter
        // actions (find-me, find-car, search result, launch center) must call the camera
        // directly. This closure wraps `mapView.setRegion(_:animated:true)` and is called
        // from ContentView's action handlers — OUTSIDE `updateUIView` — satisfying the
        // #31 architectural invariant (no camera mutation inside `updateUIView`).
        coordinatorActions.setRegion = { [weak mapView] newRegion in
            mapView?.setRegion(newRegion, animated: true)
        }

        // Phase 2: Native Drive Mode follow tracking-mode closure.
        // Engaging/disengaging MapKit's native position-follow (.follow / .none).
        // MUST be called from ContentView's .onChange(of: driveModeActive) — OUTSIDE
        // updateUIView — to satisfy the #31 architectural invariant (no camera/tracking
        // mutation inside updateUIView).
        //
        // Design: .follow (not .followWithHeading) — see CoordinatorActions.setDriveTrackingMode
        // doc comment for the full analysis. syncDriveHeading drives heading rotation separately.
        coordinatorActions.setDriveTrackingMode = { [weak mapView] active in
            guard let mapView = mapView else { return }
            mapView.userTrackingMode = active ? .follow : .none
        }

        // TF2-6 (Issue 2a): 3D buildings toggle.
        // `mapView.showsBuildings` is NOT on MKStandardMapConfiguration — it lives on MKMapView.
        // Called from ContentView's .onChange(of: driveModeActive) OUTSIDE updateUIView per #31.
        coordinatorActions.setShowsBuildings = { [weak mapView] show in
            mapView?.showsBuildings = show
        }

        // TF2-11 Option C: Camera zoom range clamp.
        // Constrains `centerCoordinateDistance` during Drive Mode so MapKit's `.follow`
        // re-assert cannot zoom past maxDriveZoomDistance (900m). Our FT-8 target (~621m)
        // is within the 150–900m clamped range, so setCamera in applyDrivePitch is unaffected.
        //
        // MUST be called from ContentView's handleDriveModeAndCamera (via .onChange) — OUTSIDE
        // updateUIView — to satisfy the #31 invariant: no UIKit state mutation during SwiftUI's
        // view-update cycle.
        //
        // Per Apple docs: setCameraZoomRange constrains "both programmatic and user-initiated"
        // zooming. The experiment (§5, §6.1) determines whether MapKit's own .follow tracking-mode
        // re-asserts are treated as "programmatic" and therefore also constrained.
        coordinatorActions.setZoomRange = { [weak mapView] active in
            guard let mapView = mapView else { return }
            if active {
                mapView.setCameraZoomRange(
                    MKMapView.CameraZoomRange(
                        minCenterCoordinateDistance: MapViewRepresentable.minDriveZoomDistance,
                        maxCenterCoordinateDistance: MapViewRepresentable.maxDriveZoomDistance
                    ),
                    animated: false
                )
            } else {
                mapView.setCameraZoomRange(nil, animated: false)
            }
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

        // Community 1.0 / Tier 1: sync community pin annotations.
        //
        // Architectural contract (spec §5.2, invariant I-1):
        //   - The DECISION to push a new pin array is made in ContentView's
        //     .onChange(of: pinService.visiblePins) — OUTSIDE updateUIView.
        //   - updateUIView performs only the MECHANICAL SYNC: diff add/remove vs current
        //     MKMapView annotation state. No camera mutations, no setRegion, no setCamera.
        //
        // This call is safe inside updateUIView because it only calls mapView.addAnnotation /
        // mapView.removeAnnotation based on a diff — not setCamera, setRegion, or any other
        // UIKit state that races SwiftUI's mount cycle.
        // FT-11: pass segments so the bearing for enforcement/sweeper pins can be computed.
        context.coordinator.syncCommunityPinAnnotations(communityPins, segments: segments, on: mapView)

        // W8.5c: Heading-up rotation (AC-W85c.10, AC-W85c.11, P2-AC-5).
        // Port of setDrivingMapRotation (index.html:6584–6601) with R-1 dead-band guard.
        // Only update when heading changes > 2 degrees to prevent tight regionDidChange feedback loop.
        //
        // Phase 2 coexistence note (P2-AC-5): syncDriveHeading calls setCamera(animated:true)
        // with only the heading changed. This does NOT reset userTrackingMode to .none —
        // MapKit's .follow continues to center the position on the next GPS fix. The two are
        // orthogonal: tracking mode controls center; camera heading is a separate mutable property.
        // Apple Maps uses exactly this pattern internally (follow + manual heading).
        //
        // Phase 2 invariant: NO camera mutation (setCamera, setRegion, userTrackingMode =)
        // happens inside updateUIView. The Drive Mode follow recentering that was here before
        // (syncDriveRegion / shouldSyncDriveRegion) is removed in Phase 2 — native MapKit
        // .follow tracking mode owns position centering without code in updateUIView.
        context.coordinator.syncDriveHeading(driveHeading, on: mapView)

        // Phase 1+2: Browse-mode `setRegion` push REMOVED (Phase 1).
        // Drive Mode manual follow loop REMOVED (Phase 2).
        //
        // MapKit owns ALL camera centering:
        //   - Browse mode: MapKit native pan/zoom, no programmatic setRegion in updateUIView.
        //   - Drive Mode: MapKit .follow tracking mode, set via coordinatorActions.setDriveTrackingMode
        //     from ContentView's .onChange(of: driveModeActive) — OUTSIDE updateUIView.
        //
        // updateUIView is now a pure mechanical sync (overlays, annotations, heading).
        // No camera mutations here. Invariant: satisfies the #31 architectural constraint.
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

        // Community 1.0 / Tier 1: community pin annotation state.
        /// Map from pin UUID → CommunityPinAnnotation for currently-rendered community markers.
        /// Used to diff add/remove in syncCommunityPinAnnotations.
        private var communityPinAnnotations: [UUID: CommunityPinAnnotation] = [:]

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

        // MARK: - FT-5: User interaction tracking

        /// Whether a user pan/zoom gesture is currently in flight.
        ///
        /// Set to `true` in `regionWillChangeAnimated` when gesture recognizers are active,
        /// indicating a user-driven map motion. Cleared to `false` unconditionally in
        /// `regionDidChangeAnimated` once the gesture (including any deceleration animation)
        /// fully settles.
        ///
        /// Phase 1: `shouldSyncRegionToBinding` was deleted; this flag is no longer used to
        /// suppress browse-mode `setRegion` (that entire path is removed). The flag is still
        /// read by `shouldSyncDriveRegion` to suppress Drive Mode follow (`syncDriveRegion`)
        /// during an active mid-drag gesture (TF2-2 race fix).
        ///
        /// Lives on Coordinator (NSObject) only — no @State/@Binding/@Published, no
        /// ContentView changes.
        var isUserInteracting: Bool = false

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

        // MARK: - Community 1.0 / Tier 1: Community pin annotation sync

        /// Diffs the desired `pins` array against the currently-rendered `communityPinAnnotations`
        /// and calls `mapView.addAnnotation` / `mapView.removeAnnotation` as needed.
        ///
        /// Architectural contract (spec §5.2, invariant I-1):
        ///   - This method is called from `updateUIView` — it may ONLY add/remove annotations.
        ///   - NO setCamera, NO setRegion, NO UIKit state that races SwiftUI's mount cycle.
        ///   - The DECISION to call with a new pin array was made in ContentView's
        ///     `.onChange(of: pinService.visiblePins)` — OUTSIDE updateUIView.
        ///
        /// Diff algorithm: O(n+m) using UUID sets.
        ///   - Pins in `desired` but not in `current` → addAnnotation.
        ///   - Pins in `current` but not in `desired` → removeAnnotation.
        ///   - Pins in both → no-op (position/title don't change for open-data pins
        ///     within a single session; a future PATCH-event path can force-update if needed).
        /// FT-11 extension: segments parameter added so directional bearings can be computed
        /// for enforcement_active and sweeper_passed pins that carry a `heading_toward` value.
        func syncCommunityPinAnnotations(
            _ pins: [CommunityPin],
            segments: [Segment],
            on mapView: MKMapView
        ) {
            let desiredByID = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })
            let currentIDs = Set(communityPinAnnotations.keys)
            let desiredIDs = Set(desiredByID.keys)

            // Remove pins that are no longer in the desired set.
            let toRemove = currentIDs.subtracting(desiredIDs)
            for id in toRemove {
                if let annotation = communityPinAnnotations[id] {
                    mapView.removeAnnotation(annotation)
                    communityPinAnnotations.removeValue(forKey: id)
                }
            }

            // Add pins that are new to the desired set.
            let toAdd = desiredIDs.subtracting(currentIDs)
            guard !toAdd.isEmpty else { return }

            // Build a [id: Segment] dict once for O(1) lookup per new pin.
            // QA Minor #2: replaces the previous O(n) `first(where:)` scan in resolveBearing.
            // Cost: one O(n) pass over `segments` here, amortised across all new pins in `toAdd`.
            // At current pin volume (O(10–100) new pins per diff), this is a no-op in practice.
            let segmentByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })

            for id in toAdd {
                guard let pin = desiredByID[id] else { continue }
                // FT-11: compute bearing when the pin carries a heading_toward value.
                let bearing = Self.resolveBearing(for: pin, segmentByID: segmentByID)
                let annotation = CommunityPinAnnotation(pin: pin, bearing: bearing)
                communityPinAnnotations[id] = annotation
                mapView.addAnnotation(annotation)
            }
        }

        /// FT-11: Computes the compass bearing for a directional pin.
        ///
        /// Returns nil (no chevron) when:
        ///   - The pin type is not `enforcement_active` or `sweeper_passed`.
        ///   - The pin has no `heading_toward` in meta (legacy pin, OD-3).
        ///   - The pin has no `segmentId` or the segment is not in the loaded set (OD-1).
        ///
        /// Build-7 QA Minor #2: accepts a pre-built `[id: Segment]` dict instead of the raw
        /// array so callers can do an O(1) lookup rather than O(n) `first(where:)` per pin.
        /// The dict is built once in `syncCommunityPinAnnotations` and passed through.
        private static func resolveBearing(for pin: CommunityPin, segmentByID: [String: Segment]) -> Double? {
            // Only enforcement and sweeper pins get chevrons.
            guard pin.pinType == .enforcementActive || pin.pinType == .sweeperPassed else {
                return nil
            }

            // Extract the headingToward value from the typed meta.
            let headingToward: HeadingToward?
            switch pin.meta {
            case .enforcementActive(let m): headingToward = m.headingToward
            case .sweeperPassed(let m):     headingToward = m.headingToward
            default:                        return nil
            }

            guard let heading = headingToward else { return nil }
            guard let segmentId = pin.segmentId else { return nil }
            // O(1) dict lookup replacing the previous O(n) linear scan (QA Minor #2).
            guard let segment = segmentByID[segmentId] else { return nil }

            return SegmentBearing.bearing(segment: segment, toward: heading)
        }

        // MARK: - W8.5c: Heading-up rotation

        /// Applies the stabilized Drive Mode heading to the map camera.
        ///
        /// FT-7 changes from W8.5c baseline:
        ///   - Dead-band lowered from 5° to 2° (OQ-FT7-1 resolved). With animated transitions
        ///     the R-1 feedback-loop risk at a lower threshold is substantially reduced.
        ///     2° is above GPS course noise (~0.5–1° at highway speed).
        ///   - Camera rotation now animated (driveAnimationDuration = 0.3s). MapKit's animated
        ///     setCamera cancels any in-flight animation and starts fresh — no stacking at 1 Hz.
        ///   - Puck rotation animated via UIView.animate with shortestArcDelta so a 359°→1°
        ///     transition takes 2° clockwise, not 358° counter-clockwise.
        ///
        /// Build-7 TF2-3 #1 — Puck double-rotation fix:
        ///   Previously the puck was rotated by the ABSOLUTE heading `h` in screen space.
        ///   On a heading-up map (`camera.heading = h`) the map itself rotates so that the
        ///   travel direction faces screen-up. The puck asset (`location.north.fill`) points
        ///   north at rest. After the camera rotates heading-up, a north-pointing asset that
        ///   stays at 0 screen rotation points UP = travel direction — which is exactly correct.
        ///   Applying an additional absolute-heading rotation double-counted the rotation,
        ///   leaving the puck off by the map's heading (wrong everywhere except h ≈ north).
        ///
        ///   Fix: rotate the puck to IDENTITY (0 radians = screen-up) in drive mode.
        ///   The heading-up camera already handles the directional orientation; the puck
        ///   merely needs to point up the screen.
        ///
        ///   `shortestArcDelta` still ensures a smooth shortest-arc animation from the
        ///   puck's current screen angle back to identity (0). On exit, the puck resets
        ///   to identity immediately (same as before).
        ///
        /// Port of `setDrivingMapRotation` (index.html:6584–6601) with R-1 dead-band guard:
        ///   - If `heading` is nil (Drive Mode off), reset camera to north-up (heading = 0).
        ///   - If heading changed by <= 2 degrees, skip (avoids regionDidChangeAnimated feedback loop).
        ///   - If changed by > 2 degrees, animate camera heading; keep puck pointing screen-up.
        ///
        /// Called from updateUIView on every SwiftUI render cycle that has a new driveHeading.
        func syncDriveHeading(_ heading: Double?, on mapView: MKMapView) {
            if let h = heading {
                // FT-7: Dead-band lowered from 5° to 2° (OQ-FT7-1 resolved).
                // R-1 anti-loop: only update if heading changed > 2 degrees.
                if let last = lastAppliedHeading {
                    let diff = MapViewRepresentable.headingDiff(h, last)
                    guard diff > 2 else { return }
                }
                lastAppliedHeading = h
                let camera = mapView.camera.copy() as! MKMapCamera
                camera.heading = h
                // FT-7 B.2: Animate camera rotation (was animated: false).
                // Programmatic animated setCamera fires regionWillChangeAnimated with no active
                // gesture recognizer → isUserGesture = false → onDrivePanDetected NOT called
                // → driveFollowEnabled unaffected. Safe.
                mapView.setCamera(camera, animated: true)

                // Build-7 TF2-3 #1: Puck target is IDENTITY (0 = screen-up).
                //
                // On a heading-up map the camera rotates so travel direction = screen-up.
                // The puck asset (location.north.fill) points north at rest. After the camera
                // rotates, a zero-screen-rotation puck points up the screen = travel direction.
                // Rotating by the absolute heading too would double-count — off by `h` degrees.
                //
                // shortestArcDelta animates from the current puck angle to 0 via the shortest
                // arc. .beginFromCurrentState: if a previous animation is in-flight, continue
                // from wherever the view currently is rather than jumping to the stale target.
                //
                // Note: `setCamera(animated:true)` means `mapView.camera.heading` may lag by
                // one animation frame. Reading it here would give a stale value. We do NOT
                // read `mapView.camera.heading` — we use the desired target (0 = identity) which
                // is independent of the camera lag. This is why the relative-to-camera approach
                // (h - camera.heading) is less robust: the stale heading makes it non-zero
                // mid-animation and causes visible jitter. Static identity is the safe target.
                let targetRad: CGFloat = 0  // screen-up in heading-up mode
                if let puckView = mapView.view(for: mapView.userLocation) {
                    // Decompose current transform angle from the existing transform.
                    let currentAngle = atan2(puckView.transform.b, puckView.transform.a)
                    let delta = MapViewRepresentable.shortestArcDelta(from: currentAngle, to: targetRad)
                    UIView.animate(
                        withDuration: MapViewRepresentable.driveAnimationDuration,
                        delay: 0,
                        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
                    ) {
                        puckView.transform = puckView.transform.rotated(by: delta)
                    }
                }
            } else {
                // Drive Mode exited — reset to north-up and clear state.
                guard lastAppliedHeading != nil else { return }
                lastAppliedHeading = nil
                let camera = mapView.camera.copy() as! MKMapCamera
                camera.heading = 0
                // Exit path stays animated: false (immediate reset on Drive Mode exit is correct).
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

                // Build-7 TF2-3 #1: Puck initialised at IDENTITY (no rotation).
                //
                // In heading-up drive mode the map camera already rotates so travel direction
                // faces screen-up. `location.north.fill` points north at rest; after the
                // camera rotates, a zero-screen-rotation puck points up = travel direction.
                // Applying the absolute heading here would double-count the rotation.
                //
                // `syncDriveHeading` will animate any subsequent puck corrections via
                // shortestArcDelta → target 0. On initial dequeue this is already correct.
                view.transform = .identity

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

            // Community 1.0 / Tier 1: community pin marker (filming + special_event).
            // Spec §7.2 — PinMarkerAnnotation, circular SF Symbol marker.
            if let pinAnnotation = annotation as? CommunityPinAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PinMarkerAnnotation.reuseIdentifier,
                    for: pinAnnotation
                ) as? PinMarkerAnnotation ?? PinMarkerAnnotation(
                    annotation: pinAnnotation,
                    reuseIdentifier: PinMarkerAnnotation.reuseIdentifier
                )
                view.annotation = pinAnnotation
                // FT-11: pass the pre-computed bearing for the directional chevron.
                // `bearing` is nil for legacy pins (OD-3 backward-compat — no chevron).
                view.configure(for: pinAnnotation.pin, bearing: pinAnnotation.bearing)
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

        // MARK: - MKMapViewDelegate: annotation callout tap (Community 1.0 / Tier 1)

        /// Fires when the user taps the right-side disclosure button in a community pin callout.
        ///
        /// Spec §7.4: tapping a `CommunityPinAnnotation` sets `activeSheet = .pinDetail(pin)`.
        /// The `DispatchQueue.main.async` wrapper follows the W5.1 UIKit→SwiftUI callback
        /// pattern (prevents "Modifying state during view update" warnings when SwiftUI is
        /// in the middle of a render cycle).
        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            calloutAccessoryControlTapped control: UIControl
        ) {
            guard let pinAnnotation = view.annotation as? CommunityPinAnnotation else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.onCommunityPinTapped?(pinAnnotation.pin)
            }
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
            // FT-5: Detect user-initiated gestures regardless of Drive Mode state.
            // Check gesture recognizers FIRST, outside the Drive Mode guard, so that
            // free-browse pans also set the interaction flag.
            //
            // We distinguish user gestures from programmatic recenters by checking whether
            // any gesture recognizer is in an active state. Programmatic `setRegion` /
            // `setCamera` calls fire `regionWillChangeAnimated` with no active recognizer,
            // so `isUserInteracting` stays `false` for those (correct — programmatic camera
            // moves, including syncDriveHeading's setCamera, should not trigger pan detection).
            //
            // Phase 2 note: `isUserInteracting` is still used by `syncDriveHeading` to prevent
            // re-applying heading while a user gesture is in flight (prevents jitter). The
            // old `onDrivePanDetected` / `driveFollowEnabled` mechanism is removed in Phase 2.
            // User pan detection during Drive Mode is now handled by MapKit's tracking-mode
            // delegate callback `mapView(_:didChange:animated:)` — see below.
            let isUserGesture = mapView.gestureRecognizers?.contains(where: {
                $0.state == .began || $0.state == .changed || $0.state == .ended
            }) ?? false
            if isUserGesture {
                isUserInteracting = true
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            // FT-5: Clear the interaction flag synchronously and unconditionally, before
            // the async onRegionChanged dispatch. Clears on every call — whether the change
            // was user-driven or programmatic — to prevent the flag from getting stuck `true`
            // if a programmatic recenter fires while no gesture is active (AC-FT5.9).
            // MapKit fires this callback only after the deceleration animation completes,
            // so clearing here is the correct moment (map has fully settled).
            isUserInteracting = false

            // TF2-8: Post-follow drive-camera re-apply.
            //
            // When MapKit's `.follow` acquires the user location after Drive Mode entry, it
            // performs its own zoom-to-default ASYNCHRONOUSLY — after our synchronous
            // `setCamera` in `handleDriveModeAndCamera`. The async follow animation clobbers
            // the tight FT-8 zoom, leaving the camera at MapKit's default wide altitude.
            //
            // Why regionDidChangeAnimated is the correct hook (vs. handleTrackingModeChanged):
            //   - `handleTrackingModeChanged(.follow)` fires when .follow is SET, not when
            //     MapKit's own follow animation COMPLETES. The follow zoom may animate after
            //     that event, so re-applying from the tracking-mode callback may still race.
            //   - `regionDidChangeAnimated` fires when any MapKit animation fully completes
            //     and the map settles. Calling `setCamera` here cancels any in-flight follow
            //     animation and targets the correct altitude — no race possible.
            //
            // One-shot + idempotence:
            //   - `pendingDriveCameraReapply` is cleared BEFORE calling `applyDrivePitch` so
            //     the re-apply's own `regionDidChangeAnimated` does not re-enter this block.
            //   - We also skip if the current altitude is within 25% of the target — avoids a
            //     visible double-animation when MapKit happened not to zoom out.
            //
            // Drive Mode guard: `parent.driveModeActive` ensures the flag is a no-op if
            // Drive Mode was exited between entry and the first regionDidChangeAnimated.
            if parent.coordinatorActions.pendingDriveCameraReapply && parent.driveModeActive
                && !isUserInteracting {
                let targetAltitude = MapViewRepresentable.altitudeForSpan(
                    MapViewRepresentable.driveModeCameraSpan
                )
                let currentAltitude = mapView.camera.centerCoordinateDistance
                let deviationRatio = abs(currentAltitude - targetAltitude) / targetAltitude
                // TF2-8 QA Finding #1: only CONSUME the flag when an actual zoom-out is
                // detected (deviation > 25%). Altitude-neutral camera events — notably the
                // course-heading setCamera, which fires regionDidChangeAnimated WITHOUT
                // changing altitude — must NOT consume the flag, or MapKit's later async
                // follow-zoom would go uncaught (the exact on-device bounce being fixed).
                // The flag therefore stays ARMED until: a real zoom-out is corrected here,
                // the user takes over (tracking drops to .none → cleared in didChange),
                // Drive Mode exits, or the entry timeout fires (ContentView, 6s).
                if deviationRatio > 0.25 {
                    // Clear BEFORE re-applying so the re-apply's own
                    // regionDidChangeAnimated does not re-enter this block (one-shot).
                    parent.coordinatorActions.pendingDriveCameraReapply = false
                    let priorPitch = parent.coordinatorActions.pendingReapplyPriorPitch
                    parent.coordinatorActions.applyDrivePitch?(true, priorPitch)
                }
                // else: still at/near target — keep the flag armed and keep waiting.
            }

            // Defer the SwiftUI state write to the next run loop cycle.
            // regionDidChangeAnimated fires from a MapKit animation callback that can
            // overlap with SwiftUI's render pass — writing @State synchronously here
            // triggers "Modifying state during view update" warnings.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onRegionChanged(region)
            }
        }

        // MARK: - Phase 2: Tracking-mode change delegate (P2-AC-1, P2-AC-6, P2-AC-7)

        /// Fires when MapKit changes `userTrackingMode` — including when a user pan/gesture
        /// during Drive Mode causes MapKit to set it to `.none` (tracking break).
        ///
        /// Phase 2 Drive Mode pan detection replaces the old `regionWillChangeAnimated` +
        /// `onDrivePanDetected` mechanism. MapKit guarantees this callback fires on any
        /// tracking-mode change, including gesture-driven breaks — it is the standard signal
        /// Apple Maps uses for the same purpose.
        ///
        /// When `mode == .none` fires during Drive Mode → tell ContentView to show Recenter.
        /// When `mode != .none` fires (re-engage by Recenter tap) → tell ContentView to hide it.
        ///
        /// Safety: dispatched via `DispatchQueue.main.async` — this callback fires from MapKit's
        /// internal queue, not SwiftUI's render cycle, so it is safe to dispatch @State writes.
        ///
        /// P2-AC-5 coexistence: `syncDriveHeading` calls `setCamera(animated:true)` with only
        /// the heading changed. Per MapKit documentation and behavior, `setCamera` does NOT
        /// reset `userTrackingMode` — only user gestures and `setUserTrackingMode` do. This
        /// callback will NOT fire spuriously from `syncDriveHeading`'s camera updates.
        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // TF2-8 QA Finding #1/#3: if the user takes over (pan/pinch breaks .follow →
            // .none) while the entry re-apply flag is still armed, disarm it — a later
            // re-apply would yank the camera out of the user's hands.
            if mode == .none {
                parent.coordinatorActions.pendingDriveCameraReapply = false
            }
            DispatchQueue.main.async { [weak self] in
                self?.parent.onTrackingModeChanged?(mode)
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

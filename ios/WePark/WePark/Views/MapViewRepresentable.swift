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
//  FT-15 / TF2-15 Stream B2 additions (docs/ft15-tf215-temporary-block-restrictions-spec.md
//  §4.2, §9.1): `blockSelectKeys: Set<String>` input + `OverlayTag.blockSelectHighlight` +
//  `Coordinator.syncBlockSelectHighlight` — a 7th, additive `TaggedMultiPolyline` overlay
//  showing every currently tap-selected blockface during a block-scoped restriction report
//  (dashed .systemPurple, distinct from every severity color and from the existing
//  .systemBlue `selectedBlock`/route overlays). Mechanical `updateUIView` sync only — no
//  camera mutation (invariant I-1), same architectural discipline as
//  `syncCommunityPinAnnotations`. This is the ONE new overlay surface OQ-1's marker-only
//  render ruling still requires: the actual restriction render stays marker-only
//  (`PinMarkerAnnotation`, unchanged by this stream); this overlay exists only to show the
//  user which blockfaces they've picked WHILE picking them, and never persists past the
//  report sheet's dismissal (`ContentView` clears `selectedBlockKeys` on dismiss).
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
    /// FT-15/TF2-15 Stream B2: multi-segment highlight shown during block-scoped
    /// report tap-select mode (§4.2 step 3). Additive — does not replace or recolor
    /// `selectedBlock` (single-segment BlockDetailView highlight); this is a distinct
    /// overlay that can show N segments at once. See `Coordinator.syncBlockSelectHighlight`.
    case blockSelectHighlight    = 7
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

/// Community 2.0 Phase 2b (build 20 S7): MKPointAnnotation subclass for the "Spot open"
/// placement flow's draft pin — the tentative, not-yet-posted position shown while
/// `SpotPlacementConfirmCard` is up. Distinct from `CarPinAnnotation`/`DestinationPinAnnotation`
/// by type, same as those two.
final class DraftSpotPinAnnotation: MKPointAnnotation {
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

    // MARK: Community 2.0 Phase 2b (build 20 S7): Spot placement draft pin

    /// The "Spot open" placement flow's current draft position. Non-nil → a dashed-ring
    /// draft-pin annotation renders at this coordinate. Nil → removed. Driven straight from
    /// `ContentView`'s `@State spotPlacementDraft` — same "optional coordinate in, mechanical
    /// add/remove sync in `updateUIView`" contract as `destinationCoordinate` above.
    var draftSpotCoordinate: CLLocationCoordinate2D? = nil

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

    // MARK: FT-15 / TF2-15 Stream B2: Block-scoped report tap-select highlight

    /// The set of `Segment.blockfaceKey` values currently selected during block-scoped
    /// report tap-select mode (§4.2). Empty when block-select mode is inactive or no
    /// blockfaces have been tapped yet — in either case, no highlight is rendered.
    ///
    /// Pushed from `ContentView.selectedBlockKeys` on every SwiftUI re-render. The
    /// Coordinator diffs this against `lastAppliedBlockSelectKeys` in `updateUIView` and
    /// only rebuilds the overlay when the set actually changed (same cheap-equality-gate
    /// pattern as `OverlayPayload.generation`, sized down since `Set<String>` is natively
    /// `Equatable` — no synthetic generation counter needed).
    ///
    /// Mechanical sync only (add/remove one `TaggedMultiPolyline` overlay) — no camera
    /// mutation, matching every other `updateUIView`-driven sync in this file (invariant
    /// I-1: `communityPins`/`syncCommunityPinAnnotations` is the direct precedent).
    var blockSelectKeys: Set<String> = []

    // MARK: W8.5c: Heading-up rotation

    /// Stabilized Drive Mode heading in degrees [0, 360). Non-nil → camera heading set.
    /// Nil → reset camera heading to north-up (0).
    /// Dead-band: only applied when heading changes by > 5 degrees (R-1 anti-loop guard).
    /// Default: nil (Drive Mode not active).
    var driveHeading: Double? = nil

    /// Whether Drive Mode is currently active.
    ///
    /// Used to gate the heading-sync path (`syncDriveHeading`) and the directional puck
    /// rendering in `mapView(_:viewFor:)`. Option A: Drive Mode position follow is owned
    /// by a per-tick custom `setCamera` in ContentView's `handleLocationUpdate()` —
    /// called from `.onChange(of: locationService.locationUpdateCount)` OUTSIDE `updateUIView`.
    ///
    /// On the simulator there is no magnetometer, so `driveHeading` is always nil during
    /// Drive Mode — the original guard `if driveHeading == nil` failed to suppress `setRegion`
    /// in the sim, flattening pitch on every location update. This property fixes that.
    var driveModeActive: Bool = false

    // MARK: - Option A: Drive Mode gesture output callbacks

    /// Option A: Called when a user gesture is detected during Drive Mode.
    ///
    /// Fires from `regionWillChangeAnimated` when ANY active gesture recognizer (pan OR
    /// pinch) is detected and `driveModeActive` is true. ContentView responds by setting
    /// `followPaused = true` to pause the per-tick custom follow and show the Recenter button.
    ///
    /// FT-17 (2026-08-12) reversed the original OQ-4 resolution. OQ-4 originally shipped
    /// "pan pauses follow, pinch does not" (pinch instead updated `currentDriveAltitude`
    /// and kept following — see `onDrivePinchZoomed` below). On-device, real two-finger
    /// pinches almost always drift enough that MapKit's own `UIPanGestureRecognizer` also
    /// becomes active concurrently, which silently discarded the altitude capture (the
    /// `wasPan` guard in `regionDidChangeAnimated` skipped it) while leaving follow ACTIVE —
    /// so the very next GPS tick re-centered and re-zoomed the map out from under the user's
    /// pinch ("it zoomed back in"), and the Recenter pill never appeared because
    /// `followPaused` was never set for a pinch. Kevin's ask, matching the Waze/Apple pattern:
    /// ANY user gesture — pan or pinch — pauses follow and surfaces Recenter; free zoom/pan
    /// until an explicit Recenter tap. See `docs/field-testing-log.md` FT-17 and
    /// `docs/tf2-11-drive-camera-ownership-spec.md` OQ-4 (amended).
    ///
    /// FT-17a (2026-08-13) fixed a defect in HOW this fires: `regionWillChangeAnimated`
    /// originally detected "any active gesture" by scanning `mapView.gestureRecognizers`,
    /// which only ever contains our own `UILongPressGestureRecognizer` and
    /// `UITapGestureRecognizer` (added in `makeUIView`) — MapKit's native pan and pinch
    /// recognizers live on internal subviews and are never in that array. So this callback
    /// fired only when our tap/long-press happened to flicker into an active state during a
    /// real pan/pinch (sporadic, not reliable — Kevin: "the recenter pill is sporadic, it
    /// doesn't always appear"). The fix installs our own passive, observer-only
    /// `UIPanGestureRecognizer` + `UIPinchGestureRecognizer` directly on the map view
    /// (`Coordinator.panGesture` / `pinchGesture`) purely to read their `.state`; tap and
    /// long-press are deliberately excluded from this detection so they do NOT pause follow.
    /// See `docs/field-testing-log.md` FT-17a.
    ///
    /// Programmatic `setCamera` / `setRegion` calls fire `regionWillChangeAnimated` with no
    /// active gesture recognizer, so this callback does NOT fire for them (correct).
    ///
    /// Default: nil (no-op). Set from ContentView's `mapRepresentable` property.
    var onDrivePanDetected: (() -> Void)? = nil

    /// Option A: Called when the user pinch-zooms during Drive Mode.
    ///
    /// Fires from `regionDidChangeAnimated` when `driveModeActive` and the settled change
    /// was from a pure pinch (no `UIPanGestureRecognizer` active — detected via the
    /// preceding `regionWillChangeAnimated`). ContentView responds by updating
    /// `currentDriveAltitude` so a resumed follow would honour the user's zoom.
    ///
    /// FT-17 note: since ANY gesture (including pinch) now also fires `onDrivePanDetected`
    /// and sets `followPaused = true`, the per-tick `setDriveCamera` is skipped the moment
    /// this callback's altitude lands — and `recenterDriveMode()` unconditionally resets
    /// `currentDriveAltitude` to the FT-8 default on the explicit Recenter tap (left
    /// unchanged by FT-17; see PR discussion). So today this callback's captured value is
    /// effectively inert in practice: it lands, then gets overwritten by the very next
    /// Recenter tap before follow ever resumes with it. KEPT rather than removed because
    /// (a) it is harmless dead weight, not a correctness risk, and (b) it is the only piece
    /// of plumbing that would let a future "Recenter preserves the user's last zoom" change
    /// (an open question — see FT-17 PR body) ship without re-deriving this capture path.
    /// Per OQ-3 (original): user-adjusted altitude persists across GPS ticks (Waze model),
    /// still true for the un-paused window between a pinch starting and `followPaused`
    /// flipping true on the same gesture.
    ///
    /// Default: nil (no-op). Set from ContentView's `mapRepresentable` property.
    var onDrivePinchZoomed: ((CLLocationDistance) -> Void)? = nil

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

    /// Pure gesture-pause-decision function: no MKMapView dependency, directly unit-testable.
    ///
    /// FT-17 (2026-08-12): reverses the original OQ-4 resolution. ANY active user gesture —
    /// pan or pinch — pauses Drive Mode follow, not just pan. `isUserGesture` already
    /// collapses "any gesture recognizer on the map view is in an active state" (computed
    /// once in `regionWillChangeAnimated` for the pre-existing FT-5 `isUserInteracting`
    /// signal); this function adds no further type-of-gesture narrowing on top of it.
    ///
    /// - Parameters:
    ///   - driveModeActive: Whether Drive Mode is currently active.
    ///   - isUserGesture: Whether an active (non-`.possible`) gesture recognizer was
    ///     detected on the map view for this `regionWillChangeAnimated` event.
    /// - Returns: `true` when follow should pause and the Recenter pill should surface.
    static func shouldPauseFollow(driveModeActive: Bool, isUserGesture: Bool) -> Bool {
        driveModeActive && isUserGesture
    }

    /// Pure gesture-state-detection function: no MKMapView dependency (only bare
    /// `UIGestureRecognizer.State` values), directly unit-testable.
    ///
    /// FT-17a (2026-08-13): replaces the broken `mapView.gestureRecognizers?.contains { ... }`
    /// scan that used to compute `isUserGesture` in `regionWillChangeAnimated`. That scan only
    /// ever inspected our own tap and long-press recognizers (the only two ever added directly
    /// to the map view) — MapKit's native pan and pinch recognizers live on internal subviews
    /// and were never in that array, so real pans/pinches were detected only when our tap or
    /// long-press happened to flicker into an active state alongside them. That made the
    /// Recenter pill appear sporadically instead of reliably. See `docs/field-testing-log.md`
    /// FT-17a for the full root-cause trace.
    ///
    /// Fix: `regionWillChangeAnimated` now reads the `.state` of two dedicated,
    /// observer-only recognizers (`Coordinator.panGesture` / `pinchGesture`, added directly
    /// to the map view in `makeUIView` and never intercepting MapKit's own gesture handling —
    /// see `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`) and passes their states
    /// here. Tap and long-press are deliberately NOT passed in, so neither pauses follow —
    /// only pan and pinch do (see FT-17a's PR body for the explicit tap/long-press decision).
    ///
    /// - Parameters:
    ///   - panState: `.state` of the observer `UIPanGestureRecognizer`, or `nil` if it hasn't
    ///     been installed yet (e.g. `regionWillChangeAnimated` fires before `makeUIView`
    ///     finishes wiring it — treated as inactive).
    ///   - pinchState: `.state` of the observer `UIPinchGestureRecognizer`, same nil handling.
    /// - Returns: `true` if either recognizer is in `.began`, `.changed`, or `.ended` —
    ///   i.e. currently tracking touches or just completed a real touch-driven gesture.
    static func isUserGestureActive(
        panState: UIGestureRecognizer.State?,
        pinchState: UIGestureRecognizer.State?
    ) -> Bool {
        func isActive(_ state: UIGestureRecognizer.State?) -> Bool {
            guard let state else { return false }
            return state == .began || state == .changed || state == .ended
        }
        return isActive(panState) || isActive(pinchState)
    }

    /// Pure dedup-decision function: no MKMapView / Coordinator dependency, directly
    /// unit-testable.
    ///
    /// FT-17a Defect 2 (2026-08-13): `regionWillChangeAnimated` fires repeatedly throughout
    /// a single continuous pan/pinch gesture (MapKit calls it on every incremental region
    /// change, not once per gesture — confirmed on Kevin's PR #74 simulator smoke test).
    /// Before FT-17a's detection fix (`isUserGestureActive`, above), `onDrivePanDetected`
    /// almost never actually dispatched (the same broken-detection bug that made the
    /// Recenter pill sporadic), so this per-event repetition was invisible. Making detection
    /// reliable turned a rare dispatch into a per-region-change-event flood: each dispatch
    /// writes `followPaused = true` to a SwiftUI `@State` in ContentView (SwiftUI does not
    /// dedupe same-value `@State` writes), so every one of those was a full view
    /// invalidation/re-render of the Drive Mode overlay stack mid-gesture — felt as jank.
    ///
    /// - Parameters:
    ///   - shouldPause: The result of `shouldPauseFollow(driveModeActive:isUserGesture:)` for
    ///     this region-change event.
    ///   - alreadySignaledThisGesture: Whether `onDrivePanDetected` was already dispatched
    ///     for the gesture currently in progress (`Coordinator
    ///     .hasSignaledFollowPauseThisGesture`).
    /// - Returns: `true` only on the first region-change event within a gesture that should
    ///   pause follow — `false` for every subsequent event in the same gesture, even though
    ///   `shouldPause` remains `true` throughout the gesture's duration.
    static func shouldSignalFollowPause(
        shouldPause: Bool,
        alreadySignaledThisGesture: Bool
    ) -> Bool {
        shouldPause && !alreadySignaledThisGesture
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

        // MARK: Option A: Custom Drive Mode follow camera

        /// Option A per-tick follow camera: issues a single animated `setCamera` that
        /// positions the map at the given GPS coordinate with the current drive heading,
        /// drive pitch (30°), and the user-adjustable current drive altitude.
        ///
        /// Parameters:
        ///   - coordinate: User's GPS position — new camera center.
        ///   - heading:    Current drive heading in degrees [0, 360) from GPS EMA course.
        ///                 Nil if GPS course is not yet available (camera uses existing heading).
        ///   - altitude:   `currentDriveAltitude` — the user-adjusted or entry-default
        ///                 `centerCoordinateDistance` in meters (~621m FT-8 default).
        ///
        /// Called from ContentView's `handleLocationUpdate()` via
        /// `.onChange(of: locationService.locationUpdateCount)` — OUTSIDE `updateUIView`.
        ///
        /// Architecture invariant: no camera mutation (`setCamera`, `setRegion`,
        /// `userTrackingMode =`) happens inside `updateUIView`. All camera mutations are
        /// driven from `.onChange` handlers in ContentView or MapKit delegate callbacks.
        ///
        /// #31 safety: identical call path to `applyDrivePitch` (called from `.onChange`),
        /// which has been shipping safely since W8.5c-polish PR-3. No #31 risk.
        var setDriveCamera: ((CLLocationCoordinate2D, Double?, CLLocationDistance) -> Void)?

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

    // MARK: - FT-15 / TF2-15 Stream B2: Block-select highlight coordinate lookup

    /// Pure segment-filter function: no `MKMapView` dependency, directly unit-testable.
    ///
    /// Returns the coordinate arrays for every segment in `segments` whose `blockfaceKey`
    /// is present in `keys`, dropping any segment with fewer than 2 coordinates (same
    /// degenerate-segment guard used throughout this file, e.g. `applyOverlayPayload`).
    /// Empty `keys` → empty result (no highlight — block-select mode inactive or nothing
    /// tapped yet).
    static func blockSelectHighlightCoordinateGroups(
        keys: Set<String>,
        segments: [Segment]
    ) -> [[CLLocationCoordinate2D]] {
        guard !keys.isEmpty else { return [] }
        return segments
            .filter { keys.contains($0.blockfaceKey) }
            .map { $0.coordinates }
            .filter { $0.count >= 2 }
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

    // MARK: - Hard camera zoom-out limit (2026-08-23, tightened 2026-08-23, widened 2026-08-23)

    /// Maximum camera distance (meters) the user can zoom out to, applied via
    /// `setCameraZoomRange(_:animated:)` in `makeUIView`. No minimum is set (see below).
    ///
    /// Kevin's original call after seeing the fully-zoomed-out state on device: a small
    /// rotated map square floating in a grey void with a faint grid, no parking data, no
    /// city context — "cant we just lock it so that you cant zoom too far out?" That first
    /// pass locked at ~53,000m, framing all of NYC's basemap.
    ///
    /// Second pass ("zoom-out-limit-tighten") derived this constant FROM
    /// `AppConstants.polylineHideSpanThreshold` instead, locking the ceiling at the point
    /// where parking polylines themselves stop rendering (~7,457m) — the premise being that
    /// "locking where data ends" beats framing the whole city.
    ///
    /// **Third pass, current (PR #89 on-device follow-up) — that premise is now REVERSED.**
    /// Kevin, on device with the 7,457m ceiling: "i think we need to have farther zoom. All
    /// of manhattan is probably the right gate. So that you can zoom out to see all of
    /// manhattan. The spot we are right now is awkward and difficult to understand what your
    /// looking at unless you actually know manhattan really well." Locking to the
    /// data-availability edge produced a *tighter*, more disorienting zoom-out ceiling than
    /// the first-pass basemap-framing one — a user without an internal map of every block
    /// couldn't zoom out far enough to get their bearings. Orientation at wide zoom is worth
    /// more than guaranteeing polyline data is visible at every reachable zoom level.
    ///
    /// **Derivation, restructured (no longer coupled to `polylineHideSpanThreshold`):** this
    /// constant is now derived from the pre-built tile grid's own coverage extent —
    /// `AppConstants.manhattanCoverageBounds` — because that bounding box is what the new
    /// limit actually means: "you can zoom out to see the whole covered area, and no
    /// further." If the tile grid's coverage ever grows (`manhattanCoverageBounds` is the
    /// single source of truth `isInManhattanCoverage(_:)` already uses elsewhere), this
    /// constant recomputes automatically instead of silently falling out of sync.
    ///
    /// `manhattanCoverageZoomOutMarginFactor` (1.1, i.e. +10% headroom on the SPAN) exists so
    /// the ceiling frames slightly MORE than the exact coverage box — "a little breathing
    /// room" past the edge of Manhattan, rather than clipping the camera exactly at the
    /// coastline. Both quantities scale linearly with span in `altitudeForSpan`, so applying
    /// the margin to the span before conversion is equivalent to applying it to the
    /// resulting altitude.
    ///
    /// Worked numbers (computed by the code below at compile-time-equivalent load time —
    /// these are documentation of the arithmetic, not separately hardcoded values):
    ///   coverage lat span: `manhattanCoverageBounds.latMax - latMin` = 40.882 − 40.700 =
    ///     0.182° (80 tile rows × 0.002275°/row — matches the tile grid exactly)
    ///   exact-fit altitude: altitudeForSpan(0.182°) ≈ 37,700m (≈37.7 km)
    ///   margined target span: 0.182° × 1.1 = 0.2002°
    ///   final altitude: altitudeForSpan(0.2002°) ≈ 41,467m (≈41.5 km)
    ///
    /// At this limit: the camera frames roughly all of Manhattan with a little margin — the
    /// same "orient yourself against the whole island" view the first-pass 53,000m limit gave,
    /// but now derived honestly from the actual coverage box instead of an arbitrary
    /// city-framing guess. **Trade-off, explicit and accepted:** `AppConstants
    /// .polylineHideSpanThreshold` (0.04°, ~8,285m) is unchanged and NOT raised — parking
    /// polylines fade well before this ceiling (above ~8.3km), leaving a wide band
    /// (~8.3km→41.5km) where Apple's basemap continues to render street names and
    /// neighborhood labels but zero parking-state overlays. That is the accepted trade: Kevin
    /// has an open complaint about zoom/pan lag, and `polylineHideSpanThreshold` was lowered
    /// from 0.1° to 0.04° during viewport-polish specifically for performance (LRU tile-cache
    /// headroom) — raising it back to chase this wider ceiling would reopen that regression.
    /// Basemap-only orientation above 8.3km is the intended experience, not a bug.
    ///
    /// ⚠️ Known side effect, flagged rather than silently absorbed: `ContentView`'s cold-launch
    /// default `region` span (0.07°/0.05° lat/lng, ~14,499m altitude) is now WELL INSIDE this
    /// ceiling again (it was clamped down to ~7,457m by the previous, tighter pass) — see
    /// `MapZoomOutLimitTests.testInitialBrowseRegion_isNoLongerClampedAtLaunch`, which now
    /// documents the opposite of what the prior test name asserted.
    ///
    /// Relationship to `TileLoader.maxLoadSpanDegrees` / grid clamping (kept, unchanged, and
    /// still wider than this constant): see `AppConstants.polylineHideSpanThreshold`'s doc
    /// comment for the full three-layer statement (camera ceiling / polyline-hide gate /
    /// tile-load backstop). Short version: this is a UX-layer cap on the STEADY-STATE camera
    /// reachable via gesture or programmatic `setCamera`/`setRegion`. It is NOT a substitute
    /// for `TileLoader`'s safety net — MapKit can still report a transient, degenerate
    /// `region.span` mid-gesture (e.g. at extreme pitch) that is decoupled from this
    /// steady-state bound; that is the independent crash path `TileLoader.tileKeys`/
    /// `clampToInt` exists to guard regardless of how far the user can actually zoom.
    /// Keep both — deleting either "because they look redundant" reopens a different bug.
    static let manhattanCoverageZoomOutMarginFactor: Double = 1.1

    static let maxZoomOutCenterCoordinateDistance: CLLocationDistance =
        altitudeForSpan(
            (AppConstants.manhattanCoverageBounds.latMax
                - AppConstants.manhattanCoverageBounds.latMin)
                * manhattanCoverageZoomOutMarginFactor
        )

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true  // W5.1: show blue dot for recenter feature
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        // PR #89 on-device follow-up, Kevin: "should we have the compass in the top left or
        // in a spot so its clear which way you have tilted the map?" MapKit's built-in
        // `showsCompass` compass renders top-RIGHT, colliding with `recenterButtonStack`
        // (Find me / Find my car / Park Until) — visibly clipped on device. Disabled here;
        // a repositioned `MKCompassButton` is added as a plain subview below, top-LEADING,
        // which FT-20 vacated (the gear + Parking 101 "?" buttons that used to live there
        // were deleted — see `ContentView`'s `mapZStack` doc comments).
        mapView.showsCompass = false
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

        // Community 2.0 Phase 2b (build 20 S7): Register the DraftSpotPinAnnotation view class.
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.draftSpotPinReuseID
        )

        // Community 1.0 / Tier 1: Register community pin annotation view class.
        mapView.register(
            PinMarkerAnnotation.self,
            forAnnotationViewWithReuseIdentifier: PinMarkerAnnotation.reuseIdentifier
        )

        // Set initial camera region.
        mapView.setRegion(region, animated: false)

        // Hard zoom-out limit (Kevin, 2026-08-23, on-device): max only, no minimum —
        // Drive Mode and block-select both depend on tight zoom-in, so leaving
        // minCenterCoordinateDistance unset imposes no zoom-in floor. Applies to BOTH
        // user pinch gestures and programmatic setCamera/setRegion calls. See
        // `maxZoomOutCenterCoordinateDistance` above for the full derivation.
        mapView.setCameraZoomRange(
            MKMapView.CameraZoomRange(
                maxCenterCoordinateDistance: MapViewRepresentable.maxZoomOutCenterCoordinateDistance
            ),
            animated: false
        )

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

        // FT-17a: Observer-only UIPanGestureRecognizer + UIPinchGestureRecognizer.
        //
        // Root cause this fixes: MapKit's own pan/pinch recognizers live on MKMapView's
        // internal subviews and are NEVER present in `mapView.gestureRecognizers` — the
        // FT-17-era `regionWillChangeAnimated` detection scanned exactly that array, so it
        // could only ever see our tap/long-press recognizers, making Drive Mode follow-pause
        // (and the Recenter pill) fire sporadically instead of reliably. See
        // `docs/field-testing-log.md` FT-17a.
        //
        // These two recognizers exist SOLELY so `regionWillChangeAnimated` /
        // `regionDidChangeAnimated` can read a real `.state` for pan/pinch — they have no
        // target-action side effects of their own (`handlePanObserver`/`handlePinchObserver`
        // are no-ops) and must NEVER call `cancel`, mutate the camera, or otherwise act as
        // more than a passive state observer. `shouldRecognizeSimultaneouslyWith` (below)
        // unconditionally returns `true`, so they track alongside MapKit's native pan/pinch
        // without intercepting or altering it — pinch-zoom and pan continue to work exactly
        // as they do today (Kevin confirmed this feel is correct; do not regress it).
        //
        // Deliberate scope decision (FT-17a): tap and long-press are NOT part of this
        // detection — only pan and pinch pause Drive Mode follow. A block tap (select) and a
        // long-press (pin-drop) are momentary, non-camera-moving gestures; pausing follow for
        // them would surface the Recenter pill for actions that never actually moved the
        // camera off the driver's position, which is not what "recenter" means to the user.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePanObserver(_:))
        )
        pan.delegate = context.coordinator
        // FT-17a follow-up (orchestrator review): make these genuinely passive.
        // `shouldRecognizeSimultaneouslyWith` resolves recognizer-vs-recognizer conflict, but
        // touch DELIVERY is a separate axis: `cancelsTouchesInView` defaults to `true`, which
        // would cancel touches to the view once the observer recognizes, and
        // `delaysTouchesEnded` defaults to `true`, adding latency. Either can make MapKit's own
        // pan/pinch feel sticky or drop mid-gesture — the exact regression FT-17a must not cause
        // (Kevin confirmed the current pan/pinch feel is correct).
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        mapView.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinchObserver(_:))
        )
        pinch.delegate = context.coordinator
        // Same passivity settings as the pan observer above — see that comment.
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        mapView.addGestureRecognizer(pinch)
        context.coordinator.pinchGesture = pinch

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

        // Option A: Custom per-tick Drive Mode follow camera.
        // Issues a single animated setCamera combining center, heading, pitch, and altitude.
        // Called from ContentView's handleLocationUpdate() via .onChange(of:
        // locationService.locationUpdateCount) — OUTSIDE updateUIView.
        //
        // Architecture invariant: no camera mutation (setCamera, setRegion, userTrackingMode =)
        // happens inside updateUIView. All camera mutations are driven from .onChange handlers
        // in ContentView or from MapKit delegate callbacks.
        //
        // Per-tick design: at 1 Hz GPS and 0.3s animation, each animation completes with
        // 0.7s to spare. MapKit's animated setCamera retargets in-flight animations — no stacking.
        // heading is still also set by syncDriveHeading on heading-only updates (orthogonal paths).
        coordinatorActions.setDriveCamera = { [weak coordinator] coordinate, heading, altitude in
            guard let c = coordinator, let mapView = c.mapView else { return }
            let camera = mapView.camera.copy() as! MKMapCamera
            camera.centerCoordinate = coordinate
            if let h = heading {
                camera.heading = h
            }
            camera.pitch = MapViewRepresentable.driveModePitch
            camera.centerCoordinateDistance = altitude
            mapView.setCamera(camera, animated: true)
        }

        // TF2-6 (Issue 2a): 3D buildings toggle.
        // `mapView.showsBuildings` is NOT on MKStandardMapConfiguration — it lives on MKMapView.
        // Called from ContentView's .onChange(of: driveModeActive) OUTSIDE updateUIView per #31.
        coordinatorActions.setShowsBuildings = { [weak mapView] show in
            mapView?.showsBuildings = show
        }

        // PR #89 on-device follow-up: repositioned compass (see `showsCompass = false`
        // above for the full rationale). Added directly as a subview of `mapView` — Apple's
        // own recommended usage of `MKCompassButton` — rather than as a SwiftUI overlay in
        // `ContentView`, so the whole change stays inside this file (`ContentView.swift` and
        // this file are the two most regression-prone views in the project; a native-subview
        // add here is a one-time, static `makeUIView` setup call, not a per-render mutation,
        // so it does not touch `updateUIView`'s "no UIKit state mutation mid-SwiftUI-update"
        // invariant).
        //
        // `compassVisibility` defaults to `.adaptive` (iOS 16+, this target is iOS 17+):
        // MapKit shows the compass only when the map is rotated away from north and
        // auto-hides it at zero rotation — set explicitly below for documentation, not
        // because the default needs overriding. That auto-hide/auto-show behavior is exactly
        // the affordance Kevin asked to keep ("which way have I tilted the map"); it is
        // MapKit's own internal animation, untouched here.
        //
        // Positioned top-leading, top offset pinned to `mapView.safeAreaLayoutGuide.topAnchor`
        // (NOT the raw `mapView.topAnchor`) — on-device follow-up to the PR #89 comment this
        // replaced. That prior version pinned to `mapView.topAnchor` with the same `100pt`
        // constant `recenterButtonStack` uses and reasoned the two would land in the same
        // place because the constant matched. On device they didn't (Kevin: "can we pull the
        // compass down just a bit? Its overlapping on the banner"): `mapView.topAnchor` is the
        // map view's RAW top — it sits above the status bar AND above the always-visible ASP
        // banner (`SuspensionBannerState` has no "none" case; ASPBanner.swift's three states
        // all render a visible ~44pt banner, and `paddingForBannerState` in ContentView.swift
        // returns a non-zero value for all of them). `recenterButtonStack`'s `100pt` is a
        // SwiftUI `.padding(.top, 100)`, which — because `recenterButtonStack` is a sibling of
        // `mapRepresentable` in `ContentView`'s `mapZStack`, not a descendant of it — sits
        // relative to the device's plain safe-area top (status bar / Dynamic Island), NOT the
        // ASP banner (the banner's `.safeAreaInset` is attached directly to `mapRepresentable`
        // and only extends the safe area seen by mapRepresentable's own subtree). Matching
        // constants, different origins → the compass landed roughly a banner-height too high
        // and clipped the banner. See the `paddingForBannerState` doc comment
        // (`ContentView.swift`, TF2-18 P2-2) for the same "two unrelated toolbars instead of
        // one row" failure mode already on record for this pair of floating clusters.
        //
        // Fix: switch the compass's base anchor to `mapView.safeAreaLayoutGuide.topAnchor`.
        // Because the ASP banner's `.safeAreaInset(edge: .top)` IS attached to
        // `mapRepresentable` (this same UIViewRepresentable), SwiftUI extends the wrapped
        // `MKMapView`'s own safe area to include the banner's rendered height automatically —
        // so this anchor already accounts for status bar + banner without `MapViewRepresentable`
        // needing to take a `SuspensionBannerState` (or any other banner-shaped) input, and it
        // self-updates if the banner's height or the device's safe-area inset ever changes.
        // This is the "fix the mechanism, not the number" version: a live Auto Layout anchor
        // that reads the actual rendered safe area, not a second hand-copied magic number.
        //
        // Remaining top offset (56pt) was derived, not measured, from typical values for this
        // target (no simulator/Xcode in this environment):
        //   recenterButtonStack absolute top  ≈ deviceSafeAreaTop (~59pt, Dynamic Island) + 100
        //                                      ≈ 159pt
        //   safeAreaLayoutGuide.topAnchor     ≈ deviceSafeAreaTop (~59pt) + bannerHeight (~44pt)
        //                                      ≈ 103pt
        //   remaining constant                ≈ 159 - 103 ≈ 56pt
        // Kevin: please eyeball this against `recenterButtonStack`'s top edge on the next
        // device pass — these are typical-device estimates, not an on-device measurement, so
        // nudge the constant below if it's still off.
        //
        // No extra background chrome is added around the compass glyph itself (unlike the
        // `.regularMaterial` pill buttons in `recenterButtonStack`): MapKit's own compass
        // rendering already reads as a floating system control, and wrapping it in a
        // persistent backdrop would keep an empty pill visible at north-up, undermining the
        // auto-hide affordance Kevin explicitly asked to preserve. Flagged for Kevin's
        // on-device call — if the bare compass reads as a "foreign element" against the
        // toolbar's frosted-glass buttons once he sees it live, wrapping it in a
        // show/hide-synced `.regularMaterial` backdrop is a scoped follow-up.
        let compassButton = MKCompassButton(mapView: mapView)
        compassButton.compassVisibility = .adaptive
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        mapView.addSubview(compassButton)
        NSLayoutConstraint.activate([
            compassButton.topAnchor.constraint(
                equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 56),
            compassButton.leadingAnchor.constraint(equalTo: mapView.leadingAnchor, constant: 12),
        ])

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

        // Community 2.0 Phase 2b (build 20 S7): sync the "Spot open" draft-pin annotation.
        // Same mechanical add/remove-only contract as syncDestinationPin above — safe inside
        // updateUIView, no camera mutation.
        context.coordinator.syncDraftSpotPin(draftSpotCoordinate, on: mapView)

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

        // FT-15/TF2-15 Stream B2: Sync block-scoped report tap-select highlight.
        // Mechanical sync only (add/remove one overlay) — no camera mutation. Same
        // architectural contract as syncCommunityPinAnnotations above.
        context.coordinator.syncBlockSelectHighlight(blockSelectKeys, segments: segments, on: mapView)

        // W8.5c: Heading-up rotation (AC-W85c.10, AC-W85c.11).
        // Port of setDrivingMapRotation (index.html:6584–6601) with R-1 dead-band guard.
        // Only update when heading changes > 2 degrees to prevent tight regionDidChange feedback loop.
        //
        // Option A coexistence: syncDriveHeading calls setCamera(animated:true) for heading-only
        // updates (when position hasn't changed). The per-tick setDriveCamera in handleLocationUpdate
        // also includes heading — the two occasionally overlap at 1 Hz; MapKit's cancel-and-restart
        // animation behavior handles this correctly (same as the FT-7 design per spec §3 Option A).
        //
        // Architecture invariant: NO camera mutation (setCamera, setRegion, userTrackingMode =)
        // happens inside updateUIView. The per-tick custom follow camera fires from ContentView's
        // handleLocationUpdate() via .onChange(of: locationService.locationUpdateCount) — OUTSIDE
        // updateUIView. This is the architectural fix for the #31 regression.
        context.coordinator.syncDriveHeading(driveHeading, on: mapView)

        // Browse-mode setRegion push REMOVED (Phase 1).
        // Drive Mode .follow tracking-mode REMOVED (Option A — no userTrackingMode = .follow).
        // Drive Mode per-tick follow camera is owned by ContentView's handleLocationUpdate()
        // via .onChange(of: locationService.locationUpdateCount) — OUTSIDE updateUIView.
        //
        // updateUIView is now a pure mechanical sync (overlays, annotations, heading).
        // No camera mutations here. Invariant: satisfies the #31 architectural constraint.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        var parent: MapViewRepresentable
        weak var mapView: MKMapView?

        // MARK: - FT-17a: Observer-only pan/pinch gesture recognizers

        /// Passive, observer-only `UIPanGestureRecognizer` installed directly on the map
        /// view (in `makeUIView`) purely to read `.state` in `regionWillChangeAnimated`.
        ///
        /// FT-17a (2026-08-13): MapKit's own pan recognizer lives on an internal subview of
        /// `MKMapView` and is never present in `mapView.gestureRecognizers` — scanning that
        /// array (the FT-17-era approach) could not reliably detect a real pan. This
        /// recognizer is attached to the map view itself and participates in simultaneous
        /// recognition (`gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` returns
        /// `true` unconditionally) so it tracks alongside MapKit's native pan handling
        /// without ever intercepting or altering it — MapKit's own pan/zoom behavior is
        /// unchanged. `weak` because `mapView` already owns it via `addGestureRecognizer`.
        weak var panGesture: UIPanGestureRecognizer?

        /// Passive, observer-only `UIPinchGestureRecognizer` — see `panGesture` doc for the
        /// full rationale. Detects pinch the same way; MapKit's native pinch recognizer
        /// similarly lives on an internal subview.
        weak var pinchGesture: UIPinchGestureRecognizer?

        /// Tracks which payload generation we last applied to avoid redundant overlay swaps.
        var lastAppliedGeneration: Int = -1

        // Current live overlays (strong refs so we can removeOverlay them later).
        private var multiPolylines: [OverlayTag: TaggedMultiPolyline] = [:]
        private var selectedPolyline: SelectedPolyline? = nil

        // FT-15/TF2-15 Stream B2: block-select tap-select highlight overlay state.
        /// The currently-rendered highlight overlay (nil if block-select mode is inactive
        /// or nothing is selected yet).
        private var blockSelectOverlay: TaggedMultiPolyline? = nil
        /// The last `blockSelectKeys` set applied — cheap equality gate (Set<String> is
        /// natively Equatable) so `syncBlockSelectHighlight` only rebuilds when the
        /// selection actually changed.
        private var lastAppliedBlockSelectKeys: Set<String> = []

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

        // Community 2.0 Phase 2b (build 20 S7): Spot placement draft pin state.
        static let draftSpotPinReuseID = "DraftSpotPinAnnotation"
        /// The currently-rendered draft-spot-pin annotation.
        private var draftSpotPinAnnotation: DraftSpotPinAnnotation? = nil
        /// The coordinate of the currently-rendered draft-spot pin (tuple for equality) —
        /// same shape as `renderedDestinationCoord` above.
        private var renderedDraftSpotCoord: (Double, Double)? = nil

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

        /// FT-17a Defect 2: whether `onDrivePanDetected` has already been dispatched for the
        /// gesture currently in progress.
        ///
        /// `regionWillChangeAnimated` fires repeatedly throughout a single continuous
        /// pan/pinch gesture (MapKit calls it on every incremental region change, not once
        /// per gesture) — confirmed on-device by Kevin's PR #74 smoke test. Before FT-17a's
        /// detection fix, `onDrivePanDetected` almost never fired at all (the same
        /// `mapView.gestureRecognizers` bug that made the Recenter pill sporadic), so this
        /// storm was never visible. Making detection reliable turned that rare, sporadic
        /// dispatch into a per-region-change-event flood — each dispatch writes
        /// `followPaused = true` to a SwiftUI `@State` in ContentView, and SwiftUI does not
        /// dedupe same-value `@State` writes, so every one of those was a full view
        /// invalidation/re-render of the Drive Mode overlay stack mid-gesture (felt as jank:
        /// "pan and pinch work but not quite as smoothly as before").
        ///
        /// Set `true` synchronously the first time `onDrivePanDetected` is dispatched for a
        /// gesture; reset `false` once neither observer recognizer (`panGesture`/
        /// `pinchGesture`) is active any more (checked in `regionDidChangeAnimated`, not
        /// unconditionally — see that method's comment for why). This is a plain Bool on
        /// Coordinator (NSObject), not a SwiftUI `@State`/`@Binding`/`@Published` — reading
        /// or writing it repeatedly has no view-invalidation cost, unlike `followPaused`.
        var hasSignaledFollowPauseThisGesture: Bool = false

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

            // FT-15/TF2-15 Stream B2: same S-1-style re-insertion for the block-select
            // highlight — applyOverlayPayload fires on every 60s tick / selection change
            // while block-select mode may simultaneously be active, and would otherwise
            // leave the highlight buried under the freshly-rebuilt parking-state overlays.
            if let existing = blockSelectOverlay {
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

        // MARK: - Community 2.0 Phase 2b (build 20 S7): Spot placement draft pin management

        /// Syncs the draft-spot-pin annotation to match the current `draftSpotCoordinate`.
        /// Byte-for-byte the same add/remove-diff shape as `syncDestinationPin` above —
        /// mechanical sync only (no camera mutation), safe to call from `updateUIView`.
        func syncDraftSpotPin(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            let newCoord = coordinate.map { ($0.latitude, $0.longitude) }

            // Fast path: same coordinate already rendered.
            if let existing = renderedDraftSpotCoord, let new = newCoord,
               existing.0 == new.0, existing.1 == new.1 { return }
            if renderedDraftSpotCoord == nil && newCoord == nil { return }

            // Remove old annotation.
            if let old = draftSpotPinAnnotation {
                mapView.removeAnnotation(old)
                draftSpotPinAnnotation = nil
            }

            // Add new annotation if a draft position is set.
            if let coordinate = coordinate {
                let annotation = DraftSpotPinAnnotation()
                annotation.coordinate = coordinate
                annotation.accessibilityLabel = "Draft spot-open position, not yet posted"
                draftSpotPinAnnotation = annotation
                mapView.addAnnotation(annotation)
            }

            renderedDraftSpotCoord = newCoord
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

        // MARK: - FT-15 / TF2-15 Stream B2: Block-select tap-select highlight

        /// Syncs the multi-segment highlight overlay to match `keys` (§4.2 step 3 — the
        /// selection highlight required by OQ-1's marker-only ruling: "the user must see
        /// which blockfaces they've picked").
        ///
        /// Mechanical sync only — remove-then-add-if-non-empty, exactly like the 5
        /// parking-state `TaggedMultiPolyline` groups in `applyOverlayPayload`. Called from
        /// `updateUIView`; no camera mutation (invariant I-1).
        ///
        /// Cheap equality gate: `Set<String>` is natively `Equatable`, so this skips the
        /// rebuild entirely when the selection hasn't changed since the last call — no
        /// synthetic generation counter needed (unlike `OverlayPayload`, which carries
        /// non-Equatable `[CLLocationCoordinate2D]` arrays).
        func syncBlockSelectHighlight(_ keys: Set<String>, segments: [Segment], on mapView: MKMapView) {
            guard lastAppliedBlockSelectKeys != keys else { return }
            lastAppliedBlockSelectKeys = keys

            if let old = blockSelectOverlay {
                mapView.removeOverlay(old)
                blockSelectOverlay = nil
            }

            let coordArrays = MapViewRepresentable.blockSelectHighlightCoordinateGroups(
                keys: keys,
                segments: segments
            )
            guard !coordArrays.isEmpty else { return }

            let children = coordArrays.compactMap { coords -> MKPolyline? in
                var mutable = coords
                return MKPolyline(coordinates: &mutable, count: mutable.count)
            }
            guard !children.isEmpty else { return }

            let multi = TaggedMultiPolyline(children)
            multi.overlayTag = .blockSelectHighlight
            blockSelectOverlay = multi
            mapView.addOverlay(multi, level: .aboveRoads)
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

            // Handle DraftSpotPinAnnotation (Community 2.0 Phase 2b, build 20 S7) — blue
            // "tentative" pin for the Spot open placement flow. `mappin.and.ellipse` (a pin
            // over a dashed ellipse) is the closest native SF Symbol equivalent to the
            // prototype's dashed draft marker — restyled toward the native idiom rather than
            // a pixel port of a literal dashed circle (gap-inventory judgment call #4's same
            // "native over pixel-port" bias), reinforced with reduced alpha so it visually
            // reads as "not yet posted."
            if annotation is DraftSpotPinAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Coordinator.draftSpotPinReuseID,
                    for: annotation
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                    annotation: annotation,
                    reuseIdentifier: Coordinator.draftSpotPinReuseID
                )
                view.markerTintColor = .systemBlue
                view.glyphImage = UIImage(systemName: "mappin.and.ellipse")
                view.alpha = 0.85
                view.canShowCallout = false
                view.isAccessibilityElement = true
                view.accessibilityLabel = "Draft spot-open position, not yet posted"
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
                case .blockSelectHighlight:
                    // FT-15/TF2-15 Stream B2: distinct from every severity color (green/
                    // orange/amber/red/gray) AND from the existing .systemBlue used by
                    // both `selectedBlock` and the route polyline, so a block-select
                    // session is never confused with either. Dashed to read as "you are
                    // selecting" rather than "this is the current legal state" (OQ-1:
                    // marker-only for the actual restriction render — this overlay is
                    // ONLY the tap-select session highlight, never a persisted state).
                    renderer.strokeColor = UIColor.systemPurple
                    renderer.lineWidth = 7
                    renderer.lineDashPattern = [8, 6]
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
            // our observer pan/pinch recognizers are in an active state. Programmatic
            // `setRegion` / `setCamera` calls fire `regionWillChangeAnimated` with neither
            // recognizer active, so `isUserInteracting` stays `false` for those (correct —
            // programmatic camera moves, including syncDriveHeading's setCamera and the
            // per-tick setDriveCamera, should not trigger pan detection).
            //
            // FT-17a (2026-08-13): previously this scanned `mapView.gestureRecognizers`,
            // which only ever contains our OWN tap and long-press recognizers — MapKit's
            // native pan/pinch recognizers live on internal subviews and are never in that
            // array, so this used to detect a real pan/pinch only sporadically (when tap or
            // long-press happened to flicker into an active state alongside it). It now
            // reads `panGesture`/`pinchGesture` — dedicated, passive observer recognizers
            // installed directly on the map view in `makeUIView` for exactly this purpose.
            // Tap and long-press are deliberately excluded: neither pauses follow or sets
            // `isUserInteracting` (see FT-17a's PR body for that decision). See
            // `docs/field-testing-log.md` FT-17a and `isUserGestureActive`'s doc comment.
            let isUserGesture = MapViewRepresentable.isUserGestureActive(
                panState: panGesture?.state,
                pinchState: pinchGesture?.state
            )
            if isUserGesture {
                isUserInteracting = true
            }

            // Option A: Drive Mode gesture-pause detection.
            //
            // FT-17 (2026-08-12) reversed OQ-4: ANY active user gesture — pan OR pinch —
            // pauses follow and surfaces Recenter (see `shouldPauseFollow` doc and
            // `onDrivePanDetected`'s doc comment for the full root-cause trace). We no
            // longer distinguish gesture type here — `isUserGesture` (computed above from
            // the observer pan/pinch recognizers' `.state`) is sufficient.
            //
            // Programmatic animated setCamera fires regionWillChangeAnimated with NO active
            // gesture recognizer, so this block never fires for programmatic camera calls.
            let shouldPause = MapViewRepresentable.shouldPauseFollow(
                driveModeActive: parent.driveModeActive,
                isUserGesture: isUserGesture
            )
            guard shouldPause else { return }

            // FT-17a Defect 2: `regionWillChangeAnimated` fires repeatedly throughout a
            // single continuous gesture (confirmed on-device, PR #74 smoke test) — without
            // this dedup guard, every one of those calls would dispatch `onDrivePanDetected`,
            // each writing `followPaused = true` to a SwiftUI `@State` in ContentView and
            // forcing a full Drive Mode overlay re-render mid-gesture (felt as jank: "pan and
            // pinch work but not quite as smoothly as before"). See
            // `hasSignaledFollowPauseThisGesture`'s doc comment and `shouldSignalFollowPause`.
            guard MapViewRepresentable.shouldSignalFollowPause(
                shouldPause: shouldPause,
                alreadySignaledThisGesture: hasSignaledFollowPauseThisGesture
            ) else { return }
            // Set synchronously (plain Coordinator Bool, not SwiftUI state — no
            // "Modifying state during view update" risk) so a second `regionWillChangeAnimated`
            // call later in the SAME run loop tick (before the async dispatch below runs)
            // still sees the gate as already signaled.
            hasSignaledFollowPauseThisGesture = true

            // Dispatch async to avoid "Modifying state during view update" if SwiftUI is
            // mid-render (ContentView sets `followPaused = true` in response).
            DispatchQueue.main.async { [weak self] in
                self?.parent.onDrivePanDetected?()
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
            let wasUserInteracting = isUserInteracting
            isUserInteracting = false

            // FT-17a Defect 2: re-arm the follow-pause dedup gate for the NEXT gesture, but
            // only once the current one has genuinely ended — i.e. neither observer
            // recognizer is still active. `regionDidChangeAnimated` is documented above (see
            // the `isUserInteracting` clear, same call) as firing once the map has "fully
            // settled" — but that assumption is unverified for `regionDidChangeAnimated`
            // specifically (only `regionWillChangeAnimated`'s per-event repetition was
            // confirmed on-device for Defect 2). Gating the reset on actual recognizer state,
            // rather than resetting unconditionally on every call, means that even if
            // `regionDidChangeAnimated` turns out to also fire mid-gesture on some
            // device/iOS version, `hasSignaledFollowPauseThisGesture` cannot be prematurely
            // cleared and cause a second `onDrivePanDetected` dispatch (and re-render) within
            // the same still-in-progress gesture.
            if !MapViewRepresentable.isUserGestureActive(
                panState: panGesture?.state,
                pinchState: pinchGesture?.state
            ) {
                hasSignaledFollowPauseThisGesture = false
            }

            // Option A: Capture user-adjusted altitude during Drive Mode pinch zoom.
            //
            // OQ-3: user pinch-zooms → capture new altitude as currentDriveAltitude so a
            // resumed follow would honour the user's zoom (see `onDrivePinchZoomed`'s doc
            // comment: FT-17 made follow pause on pinch too, so this capture is currently
            // inert in practice — kept for a possible future "Recenter preserves zoom"
            // change, not removed). We check that:
            //   1. Drive Mode is active.
            //   2. The change was user-initiated (wasUserInteracting == true).
            //   3. No pan recognizer was active at regionWillChange (pure pinch — a pan,
            //      or a pinch that also triggered MapKit's pan recognizer, is handled by
            //      the `onDrivePanDetected` follow-pause path above and does not also need
            //      an altitude capture, since follow is paused either way post-FT-17).
            //
            // We re-check the observer `panGesture`: if it's in a settling state, this was
            // a pan (handled by onDrivePanDetected in regionWillChangeAnimated). We use the
            // ENDED/CHANGED state check here since this fires after the gesture settles.
            //
            // FT-17a (2026-08-13): previously scanned `mapView.gestureRecognizers` for a
            // `UIPanGestureRecognizer`, which never matched anything real (see
            // `isUserGestureActive`'s doc comment) — this guard was effectively always
            // `false` in practice pre-fix. It now reads `panGesture` directly.
            if parent.driveModeActive, wasUserInteracting {
                let wasPan = panGesture?.state == .ended || panGesture?.state == .changed
                if !wasPan {
                    // Pinch zoom settled: report the new altitude to ContentView.
                    let newAltitude = mapView.camera.centerCoordinateDistance
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.onDrivePinchZoomed?(newAltitude)
                    }
                }
            }

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

        // MARK: - FT-17a: Observer-only pan/pinch handlers

        /// No-op target-action for the observer `panGesture`.
        ///
        /// This recognizer exists solely so `regionWillChangeAnimated` /
        /// `regionDidChangeAnimated` can read its `.state`; UIKit requires a target-action
        /// pair for a gesture recognizer to track touches at all, but this handler itself
        /// does nothing — it must never mutate the camera or any state. Reading `.state` is
        /// done directly from `panGesture` where needed, not from this callback.
        @objc func handlePanObserver(_ recognizer: UIPanGestureRecognizer) {}

        /// No-op target-action for the observer `pinchGesture`. See `handlePanObserver` doc.
        @objc func handlePinchObserver(_ recognizer: UIPinchGestureRecognizer) {}

        // MARK: - UIGestureRecognizerDelegate

        /// Allow all recognizers to fire simultaneously with MKMapView's built-in
        /// recognizers so that map gestures (pan, pinch, double-tap-to-zoom) continue
        /// to work alongside our block-tap/long-press logic and the FT-17a observer
        /// `panGesture`/`pinchGesture` recognizers. Returning `true` unconditionally means
        /// these observers never block or steal MapKit's own gesture handling — they are
        /// purely passive.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }
}

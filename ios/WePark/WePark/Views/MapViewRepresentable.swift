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

        // Sync camera only if it diverged from the map's current region by more than
        // a threshold — avoids fighting the user's pan/zoom gestures.
        let mapRegion = mapView.region
        let latDiff = abs(mapRegion.center.latitude  - region.center.latitude)
        let lngDiff = abs(mapRegion.center.longitude - region.center.longitude)
        if latDiff > 0.0001 || lngDiff > 0.0001 {
            mapView.setRegion(region, animated: false)
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

        // MARK: - MKMapViewDelegate: annotation view

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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

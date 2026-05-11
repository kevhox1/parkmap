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
//  State bridging to SwiftUI:
//    - `region` Binding<MKCoordinateRegion>: two-way camera state
//    - `selectedSegmentID` Binding<String?>: drives highlight overlay
//    - `onTap(CLLocationCoordinate2D)`: closure into ContentView tap handler
//    - `onRegionChanged(MKCoordinateRegion)`: closure for tile loading
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

private enum OverlayTag: Int {
    case freeComfortably         = 0
    case freeButRestrictionSoon  = 1
    case meteredActive           = 2
    case restrictedNow           = 3
    case unknown                 = 4
    case selectedBlock           = 5
}

// MARK: - Tagged MKMultiPolyline

/// MKMultiPolyline with an associated OverlayTag so the renderer delegate can
/// distinguish the 5 state groups without a fragile identity comparison.
private final class TaggedMultiPolyline: MKMultiPolyline {
    var overlayTag: OverlayTag = .unknown
}

/// Single-segment selected-block overlay. Uses MKPolyline (not MKMultiPolyline)
/// so it can carry the segment's current-state color independently.
private final class SelectedPolyline: MKPolyline {
    var currentState: CurrentState = .unknown
}

// MARK: - MapViewRepresentable

struct MapViewRepresentable: UIViewRepresentable {

    // MARK: Bindings / inputs from ContentView

    /// Two-way camera region. Updated when the user pans/zooms; written by ContentView
    /// to programmatically change the visible region.
    @Binding var region: MKCoordinateRegion

    /// Currently selected segment ID — drives the highlight overlay.
    @Binding var selectedSegmentID: String?

    /// Called when the user taps the map. ContentView runs the haversine search.
    let onTap: (CLLocationCoordinate2D) -> Void

    /// Called when the visible region changes (user pan/zoom ended). ContentView
    /// forwards to TileLoader.
    let onRegionChanged: (MKCoordinateRegion) -> Void

    // MARK: Overlay update API
    // Called from ContentView on every 60-second tick and on initial load.

    /// Holds the overlay state to apply in updateUIView.
    /// ContentView calls updateOverlays(segments:engine:now:) → mutates this → triggers
    /// SwiftUI diff → updateUIView is called on the Coordinator.
    var overlayPayload: OverlayPayload

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
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = true
        mapView.showsScale = true

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
        }

        // MARK: - MKMapViewDelegate: renderer

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? TaggedMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multi)
                renderer.lineCap = .round
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
                }
                return renderer
            }

            if let sel = overlay as? SelectedPolyline {
                let renderer = MKPolylineRenderer(polyline: sel)
                renderer.strokeColor = UIColor(sel.currentState.swiftUIColor)
                renderer.lineWidth = 6
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
            // Notify ContentView so it can load tiles for the new viewport.
            parent.onRegionChanged(region)
        }

        // MARK: - Tap handling

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = mapView,
                  recognizer.state == .ended else { return }
            let screenPoint = recognizer.location(in: mapView)
            let coordinate = mapView.convert(screenPoint, toCoordinateFrom: mapView)
            parent.onTap(coordinate)
        }

        // MARK: - UIGestureRecognizerDelegate

        /// Allow the tap recognizer to fire simultaneously with MKMapView's built-in
        /// recognizers so that map gestures (pan, pinch, double-tap-to-zoom) continue
        /// to work alongside our block-tap logic.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherRecognizer: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }
}

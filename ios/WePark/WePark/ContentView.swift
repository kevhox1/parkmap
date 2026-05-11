//
//  ContentView.swift
//  WePark
//
//  W3: refactored to use ParkingRulesEngine.currentStateColor (Option B dynamic state).
//  Previously (W2) used segment.dominantCategory?.swiftUIColor — static interim, now removed.
//
//  W4: Added tap interaction via MapReader + onTapGesture coordinate conversion.
//  Tapping near a polyline opens the BlockDetailView sheet. Tapping empty space dismisses.
//
//  Tap mechanism: MapPolyline does not support .onTapGesture directly in iOS 17 MapKit.
//  Spike outcome (2026-05-11): MapPolyline in the @MapContentBuilder closure does not
//  adopt SwiftUI gesture modifiers — they are silently ignored by the map render layer.
//  The invisible 20pt-wide overlay approach from the spec §3.1 is also inapplicable for
//  the same reason (there is no gesture API on MapContent). Fallback from spec §3.1 used:
//  MapReader + onTapGesture on the Map container converts the tap CGPoint to a
//  CLLocationCoordinate2D, then findClosestSegment() uses haversine point-to-segment
//  distance to identify the tapped polyline. Hit threshold = 20m, matching ~20pt at
//  typical street-level zoom.
//
//  MapAnnotation midpoint fallback was NOT used — coordinate-based hit detection is more
//  accurate and avoids cluttering the map with 40k+ annotation buttons.
//
//  The engine is computed once per minute via a Timer (sufficient granularity for
//  parking-rule state changes, which are at minimum 30-minute windows). This avoids
//  the perf trap of recomputing on every animation frame.
//

import SwiftUI
import MapKit
import Combine

struct ContentView: View {

    // MARK: - State

    /// Camera position, persisted across re-renders.
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: AppConstants.manhattanCenter.latitude,
                longitude: AppConstants.manhattanCenter.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
        )
    )

    /// TileLoader uses the @Observable macro, so @State keeps it alive for the
    /// lifetime of ContentView without requiring @StateObject / ObservableObject.
    @State private var tileLoader = TileLoader()

    /// ParkingRulesEngine: stateless pure-logic module. @State keeps the instance alive;
    /// it is safe to share because all its methods are pure (no mutation).
    @State private var engine = ParkingRulesEngine()

    /// Current map region, updated on camera change and used for tile culling and
    /// tap-threshold calculation.
    @State private var visibleRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        ),
        span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
    )

    /// Flipped every 60 seconds by the timer. SwiftUI re-evaluates the body
    /// when this changes, which causes currentStateColor to be re-evaluated
    /// with the current time — without triggering recompute every animation frame.
    @State private var lastEvaluatedAt: Date = .now

    /// W4: The currently selected segment ID. Used for:
    ///  - highlight (lineWidth:6 on the polyline for this segment)
    ///  - controlling whether the sheet is presented (`isSheetPresented`)
    /// Cleared on every dismiss path (swipe-down, ✕ button, tap-outside).
    @State private var selectedSegmentID: String? = nil

    /// W4: Controls sheet presentation. Kept separate from selectedSegmentID so
    /// the sheet can animate out without immediately losing the segment reference
    /// (which would blank the sheet content during the dismiss animation).
    @State private var isSheetPresented: Bool = false

    // MARK: - Zoom threshold
    /// Hide all polylines when the user is zoomed out further than this span.
    /// Prevents rendering tens of thousands of lines at city-wide zoom.
    /// 0.1° latitude ≈ ~11 km — well above any useful street-level view.
    /// Mitigation #2 from §3.1 / §7 R1.
    private let polylineHideSpanThreshold: Double = 0.1

    /// W4: Hit threshold in meters for "tap near a polyline" detection.
    /// 20pt at typical zoom 14–15 corresponds to roughly 8–20m on the ground.
    /// Using 20m gives comfortable margin without false positives on adjacent blocks.
    private let tapHitThresholdMeters: Double = 20.0

    // MARK: - Derived: selected segment (stable across sheet dismiss animation)

    private var selectedSegment: Segment? {
        guard let id = selectedSegmentID else { return nil }
        return tileLoader.segments.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        MapReader { mapProxy in
            Map(position: $cameraPosition) {
                polylineContent
            }
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                tileLoader.loadTiles(forRegion: context.region)
            }
            .task {
                // Kick off the initial tile load for the default Manhattan view.
                tileLoader.loadTiles(forRegion: visibleRegion)
            }
            .onAppear {
                // Immediately stamp the evaluation time on appear.
                lastEvaluatedAt = .now
            }
            .onReceive(
                Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            ) { _ in
                // Tick once per minute so time-based color changes propagate.
                // This is the only timer-driven recompute — not every animation frame.
                lastEvaluatedAt = .now
            }
            // W4: Tap gesture on the map container. MapReader.convert converts the
            // screen-space CGPoint to a CLLocationCoordinate2D. We then run a
            // point-to-segment haversine search to find the tapped polyline.
            // If no segment is within tapHitThresholdMeters, dismiss any open sheet.
            .onTapGesture { screenPoint in
                guard let coordinate = mapProxy.convert(screenPoint, from: .local) else {
                    // Failed to convert — treat as empty tap, dismiss.
                    dismissSheet()
                    return
                }
                handleMapTap(at: coordinate)
            }
            // W4: sheet(isPresented:) driven by isSheetPresented.
            // The segment lookup uses selectedSegmentID, which is cleared by dismissSheet().
            // Sheet dismiss via swipe-down sets isSheetPresented = false automatically
            // (system behavior), and our onChange clears selectedSegmentID so highlight reverts.
            .sheet(isPresented: $isSheetPresented, onDismiss: {
                // Clear the selected segment ID when the sheet is dismissed by any means.
                // This reverts the highlight and ensures the state is clean.
                selectedSegmentID = nil
            }) {
                if let segment = selectedSegment {
                    BlockDetailView(
                        segment: segment,
                        engine: engine,
                        onDismiss: { dismissSheet() }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
                    .presentationCornerRadius(20)
                }
            }
        }
    }

    // MARK: - Dismiss helper

    private func dismissSheet() {
        isSheetPresented = false
        selectedSegmentID = nil
    }

    // MARK: - Map content builder

    @MapContentBuilder
    private var polylineContent: some MapContent {
        // Zoom-threshold gating: suppress polylines when zoomed out too far.
        // latitudeDelta > threshold means the visible area is larger than ~11 km
        // tall — individual block-face lines would be illegible and slow to render.
        if visibleRegion.span.latitudeDelta <= polylineHideSpanThreshold {
            // Visible colored polylines.
            ForEach(tileLoader.segments) { segment in
                let coords = segment.coordinates
                if coords.count >= 2 {
                    // Option B dynamic state color: color reflects CURRENT parking state,
                    // not static category. Recomputed on lastEvaluatedAt tick (once/min).
                    // W3 replaces the W2 static `segment.dominantCategory?.swiftUIColor`.
                    //
                    // Cache currentState() in a local so we call the engine once per segment
                    // per render — not twice (once for color, once for lineWidth). At 1,000+
                    // visible segments that halves engine invocations per frame.
                    let state = engine.currentState(for: segment, at: lastEvaluatedAt)

                    // W4: Selected segment renders at lineWidth:6 for visual highlight.
                    // Non-selected segments stay at their normal width.
                    // The SwiftUI diff only re-renders the segments whose lineWidth changes —
                    // typically just two (the old selected and the newly selected).
                    let isSelected = segment.id == selectedSegmentID
                    let lineWidth: CGFloat = isSelected ? 6 : (state == .meteredActive ? 4 : 3)

                    MapPolyline(coordinates: coords)
                        .stroke(
                            state.swiftUIColor,
                            style: StrokeStyle(
                                lineWidth: lineWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
            }

            // W4 accessibility: invisible Annotation at each segment midpoint.
            // Per spec §3.5 / palette §5.1: each tap target must have an accessibilityLabel
            // so VoiceOver users can navigate blocks by swipe without precise tapping.
            // The Annotation button is hidden to sighted users (opacity 0, zero frame)
            // but remains in the accessibility tree.
            // Note: MapPolyline does not accept .accessibilityLabel in @MapContentBuilder
            // (the modifier breaks the ForEach result-builder type inference in iOS 17 —
            // see W4 implementation note in ContentView header). Annotation is the solution.
            ForEach(tileLoader.segments) { segment in
                if let midpoint = segment.midpoint {
                    let a11yLabel = accessibilityLabel(for: segment)
                    Annotation("", coordinate: midpoint) {
                        Button {
                            selectedSegmentID = segment.id
                            isSheetPresented = true
                        } label: {
                            Color.clear
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(a11yLabel)
                        .accessibilityHint("Opens the block details sheet.")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
    }

    // MARK: - Tap handling

    /// Identifies the segment closest to the tapped coordinate and selects it,
    /// or clears selection if no segment is within the hit threshold.
    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        // Only search among currently loaded (visible) segments.
        guard !tileLoader.segments.isEmpty else {
            dismissSheet()
            return
        }

        var closestID: String? = nil
        var closestDistance: Double = .infinity

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: coordinate, polyline: coords)
            if dist < closestDistance {
                closestDistance = dist
                closestID = segment.id
            }
        }

        if closestDistance <= tapHitThresholdMeters, let id = closestID {
            selectedSegmentID = id
            isSheetPresented = true
        } else {
            // Tap landed on empty map — dismiss any open sheet.
            dismissSheet()
        }
    }

    /// Computes the minimum distance in meters from `point` to any edge of `polyline`.
    /// Uses haversine for accuracy over Manhattan distances (~11 km bounding box).
    private func pointToPolylineDistance(from point: CLLocationCoordinate2D,
                                          polyline: [CLLocationCoordinate2D]) -> Double {
        var minDist = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let d = pointToSegmentDistance(point: point, a: polyline[i], b: polyline[i + 1])
            if d < minDist { minDist = d }
        }
        return minDist
    }

    /// Minimum distance from `point` to the line segment AB, in meters.
    /// Projects point onto AB in a local Cartesian approximation (valid for short segments
    /// < 1 km), then uses haversine for the final distance measurement.
    private func pointToSegmentDistance(point: CLLocationCoordinate2D,
                                        a: CLLocationCoordinate2D,
                                        b: CLLocationCoordinate2D) -> Double {
        // Convert to approximate Cartesian (meters) centered at A.
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            // Degenerate segment (A == B) — distance to point A.
            return haversine(from: point, to: a)
        }

        // t: scalar projection of P onto AB, clamped to [0,1].
        let t = max(0, min(1, (px * bx + py * by) / abLenSq))

        // Closest point on AB (in local Cartesian).
        let closestX = t * bx
        let closestY = t * by

        // Convert back to coordinate.
        let closestLat = a.latitude  + closestY / metersPerDegLat
        let closestLng = a.longitude + closestX / metersPerDegLng
        let closest = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng)

        return haversine(from: point, to: closest)
    }

    /// Haversine distance between two coordinates, in meters.
    private func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0  // Earth radius in meters
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Accessibility label (for the invisible tap-target polyline)

    /// Generates the accessibility label for a segment's tap-target overlay.
    /// Format: "Parking on <street>, <side>. <safetyLabel>. Tap for details."
    private func accessibilityLabel(for segment: Segment) -> String {
        let street = StreetNameNormalizer.canonical(segment.street)
        let side = sideLabel(segment.side)
        let label = engine.safetyLabel(for: segment, at: lastEvaluatedAt).text
        return "Parking on \(street), \(side). \(label). Tap for details."
    }

    /// View-level side label helper (mirrors the one in BlockDetailView).
    private func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }
}

#Preview {
    ContentView()
}

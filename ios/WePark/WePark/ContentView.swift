//
//  ContentView.swift
//  WePark
//
//  W3: refactored to use ParkingRulesEngine.currentStateColor (Option B dynamic state).
//  Previously (W2) used segment.dominantCategory?.swiftUIColor — static interim, now removed.
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

    /// Current map region, updated on camera change and used for tile culling.
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

    // MARK: - Zoom threshold
    /// Hide all polylines when the user is zoomed out further than this span.
    /// Prevents rendering tens of thousands of lines at city-wide zoom.
    /// 0.1° latitude ≈ ~11 km — well above any useful street-level view.
    /// Mitigation #2 from §3.1 / §7 R1.
    private let polylineHideSpanThreshold: Double = 0.1

    // MARK: - Body

    var body: some View {
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
    }

    // MARK: - Map content builder

    @MapContentBuilder
    private var polylineContent: some MapContent {
        // Zoom-threshold gating: suppress polylines when zoomed out too far.
        // latitudeDelta > threshold means the visible area is larger than ~11 km
        // tall — individual block-face lines would be illegible and slow to render.
        if visibleRegion.span.latitudeDelta <= polylineHideSpanThreshold {
            ForEach(tileLoader.segments) { segment in
                let coords = segment.coordinates
                if coords.count >= 2 {
                    // Option B dynamic state color: color reflects CURRENT parking state,
                    // not static category. Recomputed on lastEvaluatedAt tick (once/min).
                    // W3 replaces the W2 static `segment.dominantCategory?.swiftUIColor`.
                    let now = lastEvaluatedAt
                    let color = engine.currentStateColor(for: segment, at: now)
                    // Metered segments use lineWidth: 4 for legibility against
                    // Apple Maps' tan basemap (palette doc §2.3).
                    let isMetered = engine.currentState(for: segment, at: now) == .meteredActive
                    MapPolyline(coordinates: coords)
                        .stroke(
                            color,
                            style: StrokeStyle(
                                lineWidth: isMetered ? 4 : 3,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

//
//  ContentView.swift
//  WePark
//

import SwiftUI
import MapKit

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

    /// Current map region, updated on camera change and used for tile culling.
    @State private var visibleRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        ),
        span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
    )

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
                    MapPolyline(coordinates: coords)
                        .stroke(
                            segment.dominantCategory?.swiftUIColor ?? Color.gray.opacity(0.4),
                            lineWidth: 3
                        )
                }
            }
        }
    }
}

#Preview {
    ContentView()
}

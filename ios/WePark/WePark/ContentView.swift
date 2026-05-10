//
//  ContentView.swift
//  WePark
//

import SwiftUI
import MapKit

struct ContentView: View {
    /// Initial camera position centered on Manhattan.
    /// Matches the PWA's `[40.7831, -73.9712]` initial view (see `index.html`).
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: AppConstants.manhattanCenter.latitude,
                longitude: AppConstants.manhattanCenter.longitude
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
        )
    )

    var body: some View {
        Map(position: $cameraPosition) {
            // Tile polylines and annotations will be added in W2.
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}

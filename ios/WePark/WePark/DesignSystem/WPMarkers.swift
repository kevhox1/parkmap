//
//  WPMarkers.swift
//  WePark
//
//  Design system v0.1 map markers (spec "Map markers"), as SwiftUI views. `WPMarkerRenderer`
//  turns any of them into a `UIImage` for `MKAnnotationView` use (the screens PR wires that).
//  Markers use fixed (non-adaptive) fills because they sit on the map, not on a surface.
//
//  you            22 ink dot with a 4 white ring
//  car token      56 taxi disc, 3 line, raise 4 (can be dragged, so it is raised)
//  parked car     40 taxi disc, 2.5 line, FLAT (once parked it is a fact, not a control)
//  neighbor report 44 rounded square (radius 14), white, 2.5 line
//  leaving soon   same square in taxi, raise 3
//
//  Icons are placeholder SF Symbols (Rounded, Semibold) until the icon mapping is decided.
//

import SwiftUI
import UIKit

/// "You": 22pt ink dot with a 4pt white ring.
struct WPYouDot: View {
    var body: some View {
        Circle()
            .fill(WP.ink)
            .frame(width: WP.Marker.youDot, height: WP.Marker.youDot)
            .padding(WP.Marker.youRing)
            .background(Circle().fill(Color.white))
            .accessibilityLabel("Your location")
    }
}

/// Car token: 56pt taxi disc, 3pt line, raised 4. `isLifted` shows the pressed/dragging state.
struct WPCarToken: View {
    var isLifted: Bool = false

    var body: some View {
        WPRaisedPiece(
            shape: Circle(),
            fill: WP.taxi,
            border: WP.Border.raised,
            borderColor: WP.ink,
            raise: WP.Raise.md,
            isPressed: isLifted
        ) {
            Image(systemName: "car.fill")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(WP.ink)
                .frame(width: WP.Marker.carToken, height: WP.Marker.carToken)
        }
        .accessibilityLabel("Car token")
    }
}

/// Parked car: 40pt taxi disc, 2.5pt line, flat.
struct WPParkedCarMarker: View {
    var body: some View {
        Image(systemName: "car.fill")
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(WP.ink)
            .frame(width: WP.Marker.parkedCar, height: WP.Marker.parkedCar)
            .background(Circle().fill(WP.taxi))
            .overlay(Circle().strokeBorder(WP.ink, lineWidth: WP.Border.control))
            .accessibilityLabel("Your parked car")
    }
}

/// Neighbor report: 44pt rounded square (radius 14), white, 2.5pt line, flat.
struct WPNeighborReportMarker: View {
    var systemImage: String = "megaphone.fill"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.marker, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(WP.ink)
            .frame(width: WP.Marker.report, height: WP.Marker.report)
            .background(shape.fill(Color.white))
            .overlay(shape.strokeBorder(WP.ink, lineWidth: WP.Border.control))
            .accessibilityLabel("Neighbor report")
    }
}

/// Leaving soon: the report square in taxi, raised 3 (a neighbor is giving the spot, so it is earned).
struct WPLeavingSoonMarker: View {
    var systemImage: String = "figure.walk"

    var body: some View {
        WPRaisedPiece(
            shape: RoundedRectangle(cornerRadius: WP.Radius.marker, style: .continuous),
            fill: WP.taxi,
            border: WP.Border.control,
            borderColor: WP.ink,
            raise: WP.Raise.sm,
            isPressed: false
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(WP.ink)
                .frame(width: WP.Marker.report, height: WP.Marker.report)
        }
        .accessibilityLabel("Leaving soon")
    }
}

/// Renders a marker view to a `UIImage` for annotation views.
@MainActor
enum WPMarkerRenderer {
    static func image<V: View>(_ view: V, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }
}

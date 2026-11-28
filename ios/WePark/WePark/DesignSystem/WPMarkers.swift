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
    /// DT35-3: a placement that is not saved yet gets a dashed outline ring.
    var isPending: Bool = false

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
        .overlay {
            if isPending {
                Circle()
                    .strokeBorder(WP.ink, style: StrokeStyle(lineWidth: WP.Border.control, dash: [6, 4]))
                    .padding(-6)
            }
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

    /// Phase 2b: the parked-car marker plus its flat label, as an image and the center offset
    /// that puts the marker disc (not the label) on the coordinate.
    static func parkedCarCallout(detail: String?) -> (image: UIImage, centerOffset: CGPoint)? {
        guard let image = image(WPParkedCarCallout(detail: detail)) else { return nil }
        return (image, CGPoint(x: 0, y: -(image.size.height / 2 - WP.Marker.parkedCar / 2)))
    }
}

// MARK: - Parked car with its flat label (Phase 2b, B6.7)

/// The parked-car marker (40pt, flat) under a flat label that always carries the end time
/// ("My car" / "Free until Mon 9 AM"). Fixed (non-adaptive) fills: it sits on the map.
struct WPParkedCarCallout: View {
    /// Second line of the label: the engine's end time (nil when unknown).
    let detail: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.chip, style: .continuous)
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                Text("My car")
                    .font(WP.Font.fredoka(13, .bold, relativeTo: .caption))
                if let detail {
                    Text(detail)
                        .font(WP.Font.fredoka(12, .medium, relativeTo: .caption))
                }
            }
            .foregroundStyle(WP.ink)
            .padding(.horizontal, WP.Space.s3)
            .padding(.vertical, 6)
            .background(shape.fill(Color.white))
            .overlay(shape.strokeBorder(WP.ink, lineWidth: WP.Border.fact))
            WPParkedCarMarker()
        }
        .fixedSize()
    }
}

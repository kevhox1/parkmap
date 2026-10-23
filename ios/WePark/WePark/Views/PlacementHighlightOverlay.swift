//
//  PlacementHighlightOverlay.swift
//  WePark
//
//  Stream A2 (curb-pin placement map layer): the snapped-blockface highlight.
//
//  Design review section 2 (docs/design/curb-pin-placement-design.md): ONE overlay drawn by ONE
//  custom renderer that strokes four layers in a single `draw`, so the layers cannot desync
//  and it costs one overlay instead of four:
//
//      layer 1  outer keyline   20 pt  black            edge on light / tan / white map features
//      layer 2  casing          16 pt  white            edge on the dark map and green / red lines
//      layer 3  inner keyline   11 pt  black            separates the core from the white casing
//      layer 4  core             8 pt  severity colour  OPAQUE; the DATA (chrome is monochrome)
//
//  The amendment's white-14 / core-9 pair was invisible on a light basemap; this replaces it.
//  Widths are screen points (divided by `zoomScale` inside `draw`), scaled 0.6x when the user
//  has zoomed out past 0.5 m/pt.
//
//  Why a custom `MKOverlay` instead of an `MKPolyline` subclass: the stroke is up to 20 pt
//  wide but `MKPolyline.boundingMapRect` hugs the vertices, so MapKit would clip the stroke
//  to the bbox on tile edges. The overlay here reports an INFLATED bounding rect.
//
//  Colour is resolved ONCE at creation (`CGColor`, against the map's trait collection):
//  MapKit calls `draw` on a background thread, where resolving a dynamic `UIColor` against
//  `UITraitCollection.current` is undefined.
//
//  The overlay is added at `.aboveRoads` (same level as the curb lines) so street-name labels
//  still draw above it. `CurbPlacementController` re-inserts it after every overlay-payload
//  rebuild (same S-1 pattern as the route / block-select overlays) so it stays on top.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import SwiftUI
import MapKit
import UIKit

// MARK: - Overlay

/// `@unchecked Sendable` + `nonisolated` members (PR #140 QA #5): MapKit reads `coordinate` /
/// `boundingMapRect` and calls the renderer's `draw` OFF the main thread, while this project's
/// default actor isolation is MainActor. Every stored property is an immutable `let`, so sharing
/// is safe; the annotations just keep the compiler from inferring MainActor for them.
nonisolated final class PlacementHighlightOverlay: NSObject, MKOverlay, @unchecked Sendable {

    /// Extra metres added on every side of the polyline's bbox so a wide stroke is not clipped
    /// (half the widest layer is 10 pt; at the 0.6 m/pt zoom-out ceiling that is 6 m).
    nonisolated static let boundingInflationMeters: Double = 12

    nonisolated let blockfaceKey: String
    nonisolated let points: [MKMapPoint]
    nonisolated let coreColor: CGColor
    nonisolated let coordinate: CLLocationCoordinate2D
    nonisolated let boundingMapRect: MKMapRect

    /// nil if the segment has fewer than two usable vertices (nothing to draw).
    init?(segment: Segment, coreColor: CGColor) {
        let coordinates = segment.coordinates
        guard coordinates.count >= 2 else { return nil }
        let mapPoints = coordinates.map { (vertex: CLLocationCoordinate2D) -> MKMapPoint in
            MKMapPoint(vertex)
        }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for point in mapPoints {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        let first = coordinates[0]
        let inflation = PlacementHighlightOverlay.boundingInflationMeters
            * MKMapPointsPerMeterAtLatitude(first.latitude)
        let rect = MKMapRect(
            x: minX - inflation,
            y: minY - inflation,
            width: (maxX - minX) + 2 * inflation,
            height: (maxY - minY) + 2 * inflation
        )

        self.blockfaceKey = segment.blockfaceKey
        self.points = mapPoints
        self.coreColor = coreColor
        self.coordinate = first
        self.boundingMapRect = rect
        super.init()
    }
}

// MARK: - Renderer

final class PlacementHighlightRenderer: MKOverlayRenderer {

    private nonisolated let highlight: PlacementHighlightOverlay

    init(highlight: PlacementHighlightOverlay) {
        self.highlight = highlight
        super.init(overlay: highlight)
    }

    override nonisolated func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let mapPoints = highlight.points
        guard mapPoints.count >= 2, zoomScale > 0 else { return }

        let path = CGMutablePath()
        for (index, mapPoint) in mapPoints.enumerated() {
            let p = point(for: mapPoint)
            if index == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }

        // Screen scale -> optional zoom-out shrink (design Polish 13).
        let metersPerPoint = CurbPlacementMapPolicy.metersPerScreenPoint(
            zoomScale: Double(zoomScale),
            mapPointsPerMeter: MKMapPointsPerMeterAtLatitude(highlight.coordinate.latitude)
        )
        let widths = CurbPlacementMapPolicy.highlightLayerWidths(metersPerPoint: metersPerPoint)
        let black = CGColor(gray: 0, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)
        let colors: [CGColor] = [black, white, black, highlight.coreColor]

        context.setLineCap(.round)
        context.setLineJoin(.round)
        for layer in 0..<min(widths.count, colors.count) {
            context.setStrokeColor(colors[layer])
            context.setLineWidth(widths[layer] / CGFloat(zoomScale))
            context.addPath(path)
            context.strokePath()
        }
    }
}

// MARK: - Core colour

/// The opaque severity colour for the highlight core. Colour is DATA here (the same
/// `CurrentState` -> `ParkingColors` mapping the map's curb lines use); everything else in the
/// placement chrome is monochrome. `.unknown` is the one exception to "same as the map": its
/// map colour is 35%-alpha grey, which would vanish as a core, so it is opaque #8E8E93.
enum PlacementHighlightStyle {
    static func coreColor(for state: CurrentState, traits: UITraitCollection) -> CGColor {
        switch state {
        case .unknown:
            let rgb = CurbPlacementMapPolicy.unknownCoreRGB
            return CGColor(
                red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1
            )
        case .restrictedNow, .freeButRestrictionSoon, .meteredActive, .freeComfortably:
            return UIColor(state.swiftUIColor).resolvedColor(with: traits).cgColor
        }
    }
}

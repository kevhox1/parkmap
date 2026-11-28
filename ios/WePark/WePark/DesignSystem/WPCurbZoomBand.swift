//
//  WPCurbZoomBand.swift
//  WePark
//
//  R35 PR2 (docs/specs/r35-map-polish-and-trip-destination.md): the Stoop zoomed-out map.
//
//  Three bands by visible latitude span:
//    full       red and green curbs.
//    greenOnly  green curbs only (red would paint over the whole street grid). A plain line says so.
//    off        no curbs at all; a plain line says "Zoom in to see parking".
//  Omitting red can never create a fake spot: every green line is still the strict-gate green, and
//  a curb with no line is not claimed free.
//
//  Line widths scale down with zoom-out so the paint on the ground stays about one sixth of a
//  street, instead of growing to the whole street. Drive Mode keeps its own widths.
//
//  Pure Foundation, `nonisolated` (the project defaults to MainActor isolation) so sync tests can
//  call it directly. Tunables live in `WPCurbZoomConstants`.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import os

nonisolated enum WPCurbZoomConstants {
    /// Up to about 1.3 km tall: red and green.
    static let fullMaxDelta: Double = 0.012
    /// Up to about 2.2 km tall: green only. Above this: nothing.
    static let greenOnlyMaxDelta: Double = 0.020
    /// (latitudeDelta, rendered width in pt). Linear between knots; clamped outside.
    static let knots: [(delta: Double, width: CGFloat)] = [
        (0.0007, 3.0), (0.0035, 4.5), (0.008, 3.0), (0.012, 2.25), (0.016, 1.75), (0.020, 1.5)
    ]
    static let minWidth: CGFloat = 1.5
    /// Green in the green-only band never turns into a hairline.
    static let greenOnlyMinWidth: CGFloat = 2.0
    /// Width used when the span is unusable (NaN, zero, negative).
    static let fallbackWidth: CGFloat = 4.5
    static let quantum: CGFloat = 0.25
    /// The width the dash patterns in `WP.CurbLine` were drawn for.
    static let referenceWidth: CGFloat = 6
    static let minDashScale: CGFloat = 0.5
    /// Step 0 measurement (R35 PR2, iPhone 17 Pro simulator, iOS 26.5, top-down camera): a SOLID
    /// MKOverlayPathRenderer line renders at its `lineWidth` (1 -> 1 pt, 3 -> 3 pt, 6 -> 5.7 pt), but
    /// the same line with a `lineDashPattern` renders about 2.35 times wider (1.5 -> 3.7 pt,
    /// 3 -> 7 pt, 6 -> 14.3 pt), regardless of the dash length. Dashed curbs are therefore given
    /// `lineWidth / dashedRenderInflation` so the width ON SCREEN is the intended one. Re-measure on
    /// a device; this is the one constant to retune.
    static let dashedRenderInflation: CGFloat = 2.35
}

nonisolated enum WPCurbZoomBand: Equatable {
    case full, greenOnly, off

    /// Band for a visible latitude span. Unusable input (NaN, zero, negative) is the full band.
    static func band(latitudeDelta: Double) -> WPCurbZoomBand {
        guard latitudeDelta.isFinite, latitudeDelta > 0 else { return .full }
        if latitudeDelta <= WPCurbZoomConstants.fullMaxDelta { return .full }
        if latitudeDelta <= WPCurbZoomConstants.greenOnlyMaxDelta { return .greenOnly }
        return .off
    }

    /// Intended on-screen curb width in points: knot interpolation, quantized, clamped.
    static func width(latitudeDelta: Double, band: WPCurbZoomBand) -> CGFloat {
        guard latitudeDelta.isFinite, latitudeDelta > 0 else { return WPCurbZoomConstants.fallbackWidth }
        let knots = WPCurbZoomConstants.knots
        var raw: CGFloat
        if let first = knots.first, latitudeDelta <= first.delta {
            raw = first.width
        } else if let last = knots.last, latitudeDelta >= last.delta {
            raw = last.width
        } else {
            raw = knots[0].width
            for index in 1..<knots.count where latitudeDelta <= knots[index].delta {
                let low = knots[index - 1]
                let high = knots[index]
                let t = CGFloat((latitudeDelta - low.delta) / (high.delta - low.delta))
                raw = low.width + t * (high.width - low.width)
                break
            }
        }
        let quantum = WPCurbZoomConstants.quantum
        var width = (raw / quantum).rounded() * quantum
        width = max(width, WPCurbZoomConstants.minWidth)
        if band == .greenOnly { width = max(width, WPCurbZoomConstants.greenOnlyMinWidth) }
        return width
    }

    /// Width relative to the 6 pt design width, so a style (or the selected-curb casing) scales as a
    /// whole. Dash and dot patterns scale by this, floored at `minDashScale`.
    static func renderScale(latitudeDelta: Double) -> CGFloat {
        let zoomBand = WPCurbZoomBand.band(latitudeDelta: latitudeDelta)
        return width(latitudeDelta: latitudeDelta, band: zoomBand) / WPCurbZoomConstants.referenceWidth
    }

    static func dashScale(forRenderScale scale: CGFloat) -> CGFloat {
        max(scale, WPCurbZoomConstants.minDashScale)
    }

    /// The pill line for a band, nil in the full band.
    static func hint(for band: WPCurbZoomBand) -> String? {
        switch band {
        case .full: return nil
        case .greenOnly: return "Green curbs only. Zoom in to see the rest."
        case .off: return "Zoom in to see parking"
        }
    }

    /// The five overlay groups in the order the map draws them.
    struct Groups<Line> {
        var free: [Line]
        var soon: [Line]
        var metered: [Line]
        var restricted: [Line]
        var unknown: [Line]
    }

    /// In the green-only band every non-green group is dropped; green is untouched (same decision,
    /// same instant, same end), so it still nests and nothing becomes green that was not. Off draws
    /// nothing; full is the identity.
    static func filter<Line>(payloadGroups groups: Groups<Line>, band: WPCurbZoomBand) -> Groups<Line> {
        switch band {
        case .full: return groups
        case .greenOnly: return Groups(free: groups.free, soon: [], metered: [], restricted: [], unknown: [])
        case .off: return Groups(free: [], soon: [], metered: [], restricted: [], unknown: [])
        }
    }
}

/// os_signpost intervals around the overlay rebuild and publish, so Instruments can show the cost.
nonisolated enum WPOverlayPerf {
    static let signposter = OSSignposter(subsystem: "com.kevinhoxha.wepark", category: "overlays")
}

extension WPTileCoverage {
    /// R35 PR2b: true when a tile EXISTS under `center` and is not loaded yet. After zoom out, pan far,
    /// zoom in, the loaded set is the old area, so the screen is blank until this tile lands; the map
    /// then says "loading" instead of showing nothing. A centre over no tiles at all (outside the
    /// data) is not pending: there is nothing to wait for.
    nonisolated func hasPendingTile(atCenter center: CLLocationCoordinate2D) -> Bool {
        guard center.latitude.isFinite, center.longitude.isFinite else { return false }
        let probe = MKCoordinateRegion(
            center: center, span: MKCoordinateSpan(latitudeDelta: 0.0002, longitudeDelta: 0.0002)
        )
        let needed = TileLoader.tileKeys(
            forRegion: probe, gridRows: gridRows, gridCols: gridCols, latMin: latMin, lngMin: lngMin,
            rowSize: rowSize, colSize: colSize, tileSet: existingTiles, buffer: 0
        )
        return !needed.isEmpty && !needed.allSatisfy { loadedTiles.contains($0) }
    }
}

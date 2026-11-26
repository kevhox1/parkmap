//
//  WPCurbLines.swift
//  WePark
//
//  Design system v0.1 curb-line styles for the MapKit overlay renderers. Used ONLY when
//  `AppConstants.designSystemV2Enabled` is true (MapViewRepresentable's renderer delegate
//  branches on the flag; flag off never reaches this file).
//
//  This file changes how an EXISTING parking decision is DRAWN. It never makes a decision:
//  the classification (`ParkingRulesEngine.currentState` / `isFree`, goal windows) is upstream
//  and untouched; each overlay group already arrives tagged with its decision.
//
//  Rule 3: line style carries the answer. Solid = park. Broken = don't. Unsure = don't.
//
//  Default (two states):
//      park  = solid #3CCF7A, 6pt
//      don't = dashed #E39A90 [10, 8], 6pt
//  "Show all sign details" (five states):
//      free    = solid green
//      soon    = long dash #F2A23A [24, 8]   (free now, changes soon)
//      metered = dotted #5B7CFA (round caps, dash [0.1, 11])
//      no parking / standing = dashed coral
//      no data = 2pt solid #A9A7B8
//
//  Mapping of the existing 5 classifier states (`OverlayTag` / `CurrentState`):
//      freeComfortably        -> park    (both modes)
//      freeButRestrictionSoon -> soon    (detail)  /  dont  (default: a restriction starts inside the
//                                window, and green must mean free for the WHOLE selected window;
//                                Phase 2a accuracy fix, was `park` "free right now")
//      meteredActive          -> metered (detail)  /  dont  (default: a running meter is not free)
//      restrictedNow          -> dont    (both modes)
//      unknown                -> noData  (detail)  /  dont  (default: unsure is drawn as don't)
//

import MapKit
import UIKit

/// What a curb line looks like. Pure value, directly unit-testable.
struct CurbLineStyle: Equatable {
    let colorHex: UInt32
    let width: CGFloat
    /// nil = solid.
    let dashPattern: [CGFloat]?
    /// Round caps (the dotted metered line); butt otherwise so intersection setbacks stay visible.
    let roundCaps: Bool
}

/// The visual vocabulary of v0.1 curb lines.
enum CurbLineKind: Equatable, CaseIterable {
    case park, dont, soon, metered, noData
}

enum CurbLineStyleV2 {

    // MARK: Styles

    nonisolated static func style(for kind: CurbLineKind) -> CurbLineStyle {
        switch kind {
        case .park:
            return CurbLineStyle(colorHex: WP.Hex.park, width: WP.CurbLine.width, dashPattern: nil, roundCaps: false)
        case .dont:
            return CurbLineStyle(colorHex: WP.Hex.noParkLine, width: WP.CurbLine.width, dashPattern: WP.CurbLine.dontDash, roundCaps: false)
        case .soon:
            return CurbLineStyle(colorHex: WP.Hex.detailSoon, width: WP.CurbLine.width, dashPattern: WP.CurbLine.soonDash, roundCaps: false)
        case .metered:
            return CurbLineStyle(colorHex: WP.Hex.detailMetered, width: WP.CurbLine.width, dashPattern: WP.CurbLine.meteredDash, roundCaps: true)
        case .noData:
            return CurbLineStyle(colorHex: WP.Hex.hairline, width: WP.CurbLine.noDataWidth, dashPattern: nil, roundCaps: false)
        }
    }

    // MARK: Mapping from the existing classifier

    nonisolated static func kind(for state: CurrentState, detailMode: Bool) -> CurbLineKind {
        switch state {
        case .freeComfortably:
            return .park
        case .freeButRestrictionSoon:
            return detailMode ? .soon : .dont
        case .meteredActive:
            return detailMode ? .metered : .dont
        case .restrictedNow:
            return .dont
        case .unknown:
            return detailMode ? .noData : .dont
        }
    }

    /// Nil for tags that are not parking-state curb lines (route, block-select, selected block):
    /// those keep their existing renderers.
    // NB: the calls below are qualified `CurrentState.x`; bare `.x` also type-checks against
    // `OverlayTag` and silently recursed forever (found by the Phase 2a live smoke).
    nonisolated static func kind(for tag: OverlayTag, detailMode: Bool) -> CurbLineKind? {
        switch tag {
        case .freeComfortably: return kind(for: CurrentState.freeComfortably, detailMode: detailMode)
        case .freeButRestrictionSoon: return kind(for: CurrentState.freeButRestrictionSoon, detailMode: detailMode)
        case .meteredActive: return kind(for: CurrentState.meteredActive, detailMode: detailMode)
        case .restrictedNow: return kind(for: CurrentState.restrictedNow, detailMode: detailMode)
        case .unknown: return kind(for: CurrentState.unknown, detailMode: detailMode)
        case .selectedBlock, .routePolyline, .blockSelectHighlight: return nil
        }
    }

    // MARK: Applying to a renderer

    /// Applies `style` to a polyline renderer (solid, dashed, or dotted).
    @MainActor
    static func apply(_ style: CurbLineStyle, to renderer: MKOverlayPathRenderer, scale: CGFloat = 1) {
        renderer.strokeColor = UIColor(wpHex: style.colorHex)
        renderer.lineWidth = style.width * scale
        renderer.lineCap = style.roundCaps ? .round : .butt
        renderer.lineJoin = .round
        renderer.lineDashPattern = style.dashPattern?.map { NSNumber(value: Double($0 * scale)) }
    }

    // MARK: Zoom scaling (Phase 2b, Phase 2a QA gap: "curb dashes read heavy at close zoom")

    /// The spec widths (6pt line, [10, 8] dash) are drawn at a typical street-level zoom, about
    /// a quarter-mile tall (`typicalLatitudeDelta`). Closer than that a 6pt line covers a large
    /// part of the sidewalk, so line width and dash scale down with the visible span, never below
    /// `minimumScale`, never above 1. Quantized so a pinch does not redraw every frame.
    nonisolated static let typicalLatitudeDelta: Double = 0.0035
    nonisolated static let closestLatitudeDelta: Double = 0.0007
    nonisolated static let minimumScale: CGFloat = 0.5

    nonisolated static func zoomScale(latitudeDelta: Double) -> CGFloat {
        guard latitudeDelta.isFinite, latitudeDelta > 0 else { return 1 }
        if latitudeDelta >= typicalLatitudeDelta { return 1 }
        if latitudeDelta <= closestLatitudeDelta { return minimumScale }
        let t = (latitudeDelta - closestLatitudeDelta) / (typicalLatitudeDelta - closestLatitudeDelta)
        let raw = minimumScale + CGFloat(t) * (1 - minimumScale)
        return (raw * 10).rounded() / 10
    }
}

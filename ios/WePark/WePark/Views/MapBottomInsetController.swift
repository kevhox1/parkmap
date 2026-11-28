//
//  MapBottomInsetController.swift
//  WePark
//
//  DT35-6: lifts the Apple Maps logo / Legal link above the Stoop drive card. The map runs
//  edge to edge under the bottom safe-area inset, so MapKit pins its attribution to the screen
//  bottom, beneath the Report / Park here / Voice row. MapKit positions the attribution from
//  `layoutMargins`, so we raise the bottom margin to the measured card height. The attribution
//  itself is never hidden, restyled or covered (Apple requires it).
//
//  Independent of `CurbPlacementController`'s margin handling: placement and drive are mutually
//  exclusive, and each owns its own snapshot so neither restores the other's.
//

import UIKit
import MapKit
import CoreLocation

/// Pure policy for the drive-mode bottom inset (mirrors `CurbPlacementMapPolicy.bottomMargin`).
enum MapBottomInsetPolicy {

    /// Clear space between the attribution and the top of the drive card.
    nonisolated static let gapPoints: CGFloat = 8
    /// The inset never exceeds this share of the map height, so a tall AX card cannot push the
    /// attribution to the middle of the screen.
    nonisolated static let maxHeightFraction: CGFloat = 0.70

    /// - Parameters:
    ///   - measuredFromBottom: distance from the screen bottom up to the card's top edge (the
    ///     card height PLUS the home-indicator safe area under it).
    ///   - mapHeight: the map view's height.
    ///   - driving: false (or a non-positive / non-finite measurement) means no inset, 0.
    nonisolated static func inset(measuredFromBottom: CGFloat, mapHeight: CGFloat, driving: Bool) -> CGFloat {
        guard driving, measuredFromBottom.isFinite, measuredFromBottom > 0,
              mapHeight.isFinite, mapHeight > 0 else { return 0 }
        return min(measuredFromBottom + gapPoints, mapHeight * maxHeightFraction)
    }
}

/// Margin state captured by the first non-zero inset (same raw-vs-effective reasoning as
/// `CurbPlacementController.setBottomInset`: with `insetsLayoutMarginsFromSafeArea == true` the
/// getter can include the safe area, so write-back of the effective value would double count).
struct MapMarginSnapshot: Equatable {
    let insetsFromSafeArea: Bool
    let rawMargins: UIEdgeInsets
    let effectiveMargins: UIEdgeInsets
}

/// Applies and restores the map's bottom layout margin for drive mode.
final class MapBottomInsetController {

    private(set) var snapshot: MapMarginSnapshot?

    /// How far (points, upwards) the bottom margin has moved the centre of the visible area, so
    /// MapKit now draws the camera centre that far above where it used to. 0 when no inset.
    private(set) var centreShift: CGFloat = 0

    /// Sets the bottom margin to `inset` points (the policy already added the gap); `inset <= 0`
    /// restores the pre-drive margins exactly. Main thread, outside any SwiftUI update.
    func apply(inset: CGFloat, to mapView: MKMapView) {
        guard inset > 0 else {
            restore(on: mapView)
            return
        }
        let snap: MapMarginSnapshot
        if let existing = snapshot {
            snap = existing
        } else {
            let effective = mapView.layoutMargins
            let originalFlag = mapView.insetsLayoutMarginsFromSafeArea
            mapView.insetsLayoutMarginsFromSafeArea = false
            let raw = mapView.layoutMargins
            mapView.insetsLayoutMarginsFromSafeArea = originalFlag
            snap = MapMarginSnapshot(insetsFromSafeArea: originalFlag, rawMargins: raw, effectiveMargins: effective)
            snapshot = snap
        }
        var applied = snap.effectiveMargins
        applied.bottom = max(snap.effectiveMargins.bottom, inset)
        // Bottom only. A mirrored top margin keeps the puck framed but makes MapKit drop the Apple
        // "Maps" logo once top + bottom approach the map height (QA, DT35-6). The camera centre
        // shift this causes is compensated in `compensatedCenter` instead.
        centreShift = (applied.bottom - snap.effectiveMargins.bottom) / 2
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.layoutMargins = applied
    }

    /// The camera centre that makes `puck` appear where it did before the inset (the follow
    /// camera otherwise rides `centreShift` points higher, showing less road ahead). Translates
    /// the puck by the ground vector between where MapKit now draws the centre and where it
    /// used to. Returns `puck` unchanged when no inset is applied.
    func compensatedCenter(for puck: CLLocationCoordinate2D, on mapView: MKMapView) -> CLLocationCoordinate2D {
        guard centreShift > 0 else { return puck }
        let drawn = CGPoint(x: mapView.bounds.midX, y: (mapView.layoutMargins.top + mapView.bounds.height - mapView.layoutMargins.bottom) / 2)
        let original = CGPoint(x: drawn.x, y: drawn.y + centreShift)
        let current = mapView.convert(drawn, toCoordinateFrom: mapView)
        let target = mapView.convert(original, toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(current), CLLocationCoordinate2DIsValid(target) else { return puck }
        return CLLocationCoordinate2D(
            latitude: puck.latitude + (current.latitude - target.latitude),
            longitude: puck.longitude + (current.longitude - target.longitude)
        )
    }

    func restore(on mapView: MKMapView) {
        guard let snap = snapshot else { return }
        mapView.insetsLayoutMarginsFromSafeArea = snap.insetsFromSafeArea
        mapView.layoutMargins = snap.rawMargins
        snapshot = nil
        centreShift = 0
    }
}

//
//  CurbPlacementMapPolicy.swift
//  WePark
//
//  Stream A2 of the fixed-center-pin amendment (docs/longpress-universal-plant-spec.md
//  "Amendment - fixed-center pin with live curb snap", section A.9) as amended by the Stream B
//  design review (docs/design/curb-pin-placement-design.md, AUTHORITATIVE over the amendment).
//
//  This file is ONLY the pure decisions behind the placement map layer, so each one is
//  directly unit-testable with no MKMapView (the project's `targetPitch` / `targetSpan` /
//  `AmbientDrivingLook` house style):
//    - where the pin tip sits on screen (40% of height, NOT bounds centre)  - `tipPoint`
//    - the entry camera (street-level span, distance clamp, seed-under-the-tip centre)
//    - the zoom-floor / zoom-out range applied while the mode is active   - `zoomRange`
//    - when the 30 fps display link resolves vs skips                      - `shouldResolve`
//    - when `onPlacementOutcome` fires (blockface / outcome-kind change)   - `shouldFireOutcome`
//    - the settle nudge (skip threshold, distance-scaled duration, RM)     - `settleNudge`
//    - the camera the mode exits to (cancel vs commit, ambient look)      - `exitCamera`
//    - the 4-layer highlight stroke widths and zoom-out scaling            - `highlightLayerWidths`
//
//  The camera / overlay / display-link MUTATION lives in `CurbPlacementController` (driven from
//  `MapViewRepresentable.CoordinatorActions`, called from ContentView `.onChange` handlers
//  OUTSIDE `updateUIView` - the #31 invariant). Nothing here touches MapKit.
//
//  Invariants:
//    - Pure Foundation / CoreGraphics / CoreLocation (+ UIKit only for `UIGestureRecognizer
//      .State`). No SwiftUI. No Calendar.current. No force-unwraps.
//    - `nonisolated` explicit on EVERY member and value type (project default actor isolation
//      is MainActor; same convention as `ParkingGoals` / `AmbientDrivingLook`). No `==` on a
//      project enum and no MainActor-constant read inside a `nonisolated` function (PR #138
//      QA caught exactly that): the ambient pitch / heading are passed IN by the caller.
//    - Placement is a RESTING-posture mode: nothing here reads or writes `driveModeActive`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import Foundation
import CoreGraphics
import CoreLocation
import UIKit

// MARK: - Value types

/// A camera pose the mode captures on entry and returns to on exit.
nonisolated struct PlacementCameraState {
    let center: CLLocationCoordinate2D
    let distance: CLLocationDistance
    let pitch: CGFloat
    let heading: CLLocationDirection
}

/// The camera-distance window applied while the mode is active.
nonisolated struct PlacementZoomRange {
    /// The zoom FLOOR: how close the user may pinch in (design Finding 1).
    let minDistance: CLLocationDistance
    /// How far the user may pinch out.
    let maxDistance: CLLocationDistance
}

/// A settle nudge: the animation to run, or an instant jump under Reduce Motion.
nonisolated struct PlacementNudge {
    let animated: Bool
    let duration: TimeInterval
}

// MARK: - Policy

nonisolated enum CurbPlacementMapPolicy {

    // MARK: Geometry (design section 0)

    /// The pin tip sits at this fraction of the map view's height, measured from the top
    /// (design section 0: 341 pt on an 852 pt screen, 267 on 667). Keeps >= 100 pt of clear map
    /// between the tip and the card even on SE-class phones, puts the pin above the thumb's
    /// resting zone, and keeps the needle head clear of the Cancel row.
    static let tipHeightFraction: CGFloat = 0.40

    /// The ONE definition of "where the pin is" - used by the reticle, the resolver, the settle
    /// nudge and the entry centring so they cannot disagree.
    static func tipPoint(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.minY + tipHeightFraction * bounds.height)
    }

    /// Where the screen point `ghost` must land so the ghost ends up under the pin tip: the
    /// map CENTRE (what `setCenter` moves) is shifted by the same delta that takes the tip to
    /// the ghost. Design section 0: `screenPoint(of: snapped) + (boundsCenter - tipPoint)`.
    static func nudgeTargetScreenPoint(ghost: CGPoint, tip: CGPoint, boundsCenter: CGPoint) -> CGPoint {
        CGPoint(x: ghost.x + (boundsCenter.x - tip.x), y: ghost.y + (boundsCenter.y - tip.y))
    }

    // MARK: Entry camera (spec A.3 "Entry")

    /// Entry pitch: flat. A tilted camera makes "ground point under the pin" ambiguous (A.3).
    static let entryPitch: CGFloat = 0

    /// Entry heading: north-up.
    static let entryHeading: CLLocationDirection = 0

    /// Visible map WIDTH at entry, metres (~0.28 m/pt on a 390 pt screen - chosen so the two
    /// curbs of a typical 15 m street sit ~55 pt apart; spec A.3).
    static let entryVisibleWidthMeters: Double = 110

    /// Used only if the map has no size yet (iPhone 15 Pro portrait).
    static let fallbackBoundsSize = CGSize(width: 390, height: 844)

    /// Metres per degree of latitude as `MapViewRepresentable.altitudeForSpan` uses it (kept
    /// private there). A test asserts the round trip so the two can never drift apart.
    static let metersPerDegreeForSpan: Double = 111_000

    /// Metres per degree of latitude for the small centre shift (same flat-earth constant
    /// `CurbSnapIndex` / `CandidateSegmentSearch` use).
    static let metersPerDegreeLatitude: Double = 111_320

    /// Visible map HEIGHT in metres that makes the visible WIDTH `entryVisibleWidthMeters`.
    static func entryVisibleHeightMeters(boundsSize: CGSize) -> Double {
        let size = (boundsSize.width > 0 && boundsSize.height > 0) ? boundsSize : fallbackBoundsSize
        return entryVisibleWidthMeters * Double(size.height) / Double(size.width)
    }

    /// Latitude span (degrees) for a visible height in metres - the input
    /// `MapViewRepresentable.altitudeForSpan` converts to a camera distance.
    static func latitudeSpan(forVisibleHeightMeters meters: Double) -> CLLocationDegrees {
        meters / metersPerDegreeForSpan
    }

    /// The entry camera distance when the map has no usable size yet: the distance
    /// `altitudeForSpan` gives for the 110 m target on a 390x844 phone (~444 m).
    static let defaultEntryDistanceMeters: CLLocationDistance = 444

    /// PINCH-OUT cap while the mode is active - a constant SEPARATE from the entry distance
    /// (orchestrator ruling on PR #140, superseding the spec's "~400 m", which the repo's own
    /// `altitudeForSpan` field-of-view convention makes unreachable: 110 m of width needs
    /// ~444 m). At 600 m a 390x844 view shows ~0.381 m/pt, so the 24 m acquire radius is still
    /// ~63 pt (>= the 40 pt target), and the entry (~444 m) has ~1.35x of pinch-out headroom.
    static let zoomOutCeilingMeters: CLLocationDistance = 600

    /// Design Finding 1: zoom floor = 0.55x the entry distance (~244 m = ~60 m visible width,
    /// >= 0.15 m/pt, so the ghost's max reach is ~155 pt and can never run under the card).
    static let zoomFloorFactor: Double = 0.55

    /// The entry camera distance: the one the 110 m target needs (NOT clamped to a 400 m cap
    /// any more), bounded only by the pinch-out ceiling as a safety net (a very tall/iPad view
    /// would otherwise start outside its own window). Invalid input falls back to the
    /// phone-default distance.
    static func entryDistance(requested: CLLocationDistance) -> CLLocationDistance {
        guard requested.isFinite, requested > 0 else { return defaultEntryDistanceMeters }
        return min(requested, zoomOutCeilingMeters)
    }

    /// The zoom window for a given entry distance: floor 0.55x entry, ceiling `zoomOutCeilingMeters`.
    static func zoomRange(entryDistance: CLLocationDistance) -> PlacementZoomRange {
        PlacementZoomRange(
            minDistance: entryDistance * zoomFloorFactor,
            maxDistance: zoomOutCeilingMeters
        )
    }

    // MARK: Bottom inset (design Finding 7 / QA #3)

    /// Breathing room between the card top and the Apple logo / Legal link.
    static let bottomInsetGapPoints: CGFloat = 8

    /// The bottom layout margin to apply while the card is `cardHeight` tall:
    /// `max(snapshotEffectiveBottom, cardHeight + gap)`, and exactly `snapshotEffectiveBottom`
    /// for a non-positive / non-finite height (the "inset cleared" call).
    static func bottomMargin(cardHeight: CGFloat, snapshotEffectiveBottom: CGFloat) -> CGFloat {
        guard cardHeight.isFinite, cardHeight > 0 else { return snapshotEffectiveBottom }
        return max(snapshotEffectiveBottom, cardHeight + bottomInsetGapPoints)
    }

    /// Visible height in metres after the distance clamp (visible extent is linear in
    /// distance, same assumption `altitudeForSpan` makes).
    static func clampedVisibleHeightMeters(
        requestedVisibleHeightMeters: Double,
        requestedDistance: CLLocationDistance,
        clampedDistance: CLLocationDistance
    ) -> Double {
        guard requestedDistance > 0 else { return requestedVisibleHeightMeters }
        return requestedVisibleHeightMeters * clampedDistance / requestedDistance
    }

    /// Camera CENTRE that puts `seed` under the pin tip at the entry camera (pitch 0, north-up):
    /// the tip is `(0.5 - tipHeightFraction)` of the view height ABOVE centre, so the centre is
    /// that many metres SOUTH of the seed.
    static func entryCenter(
        seed: CLLocationCoordinate2D,
        visibleHeightMeters: Double
    ) -> CLLocationCoordinate2D {
        let southMeters = (0.5 - Double(tipHeightFraction)) * visibleHeightMeters
        return CLLocationCoordinate2D(
            latitude: seed.latitude - southMeters / metersPerDegreeLatitude,
            longitude: seed.longitude
        )
    }

    /// Whether the entry camera has landed (a stale regionDidChange from an interrupted
    /// animation must not reveal the reticle early). Distance within 10%, pitch near flat.
    static func entryArrived(
        currentDistance: CLLocationDistance,
        targetDistance: CLLocationDistance,
        currentPitch: CGFloat
    ) -> Bool {
        guard targetDistance > 0 else { return true }
        let relative = abs(currentDistance - targetDistance) / targetDistance
        return relative <= 0.10 && abs(currentPitch) < 1.0
    }

    /// Safety net if MapKit never reports a region change for the entry `setCamera` (camera
    /// already there): the entry is completed anyway after this long.
    static let entrySafetySeconds: TimeInterval = 1.5

    // MARK: Display-link loop (spec A.6)

    static let displayLinkFramesPerSecond: Int = 30

    /// Spec A.6: skip the resolve if the pin ground point moved less than this since the last
    /// one (metres).
    static let resolveSkipMeters: Double = 0.15

    /// Resolve when there is no previous resolve, or the pin moved at least the threshold.
    static func shouldResolve(movedMeters: Double?) -> Bool {
        guard let movedMeters, movedMeters.isFinite else { return true }
        return movedMeters >= resolveSkipMeters
    }

    /// The link only needs to run while the map is moving and the entry flight is over.
    static func displayLinkShouldRun(placementActive: Bool, entryInProgress: Bool, mapMoving: Bool) -> Bool {
        placementActive && !entryInProgress && mapMoving
    }

    /// Flat-earth distance in metres between two nearby coordinates (the pin moves metres per
    /// frame at most; the repo's other geometry helpers use the same approximation).
    static func approxMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * metersPerDegreeLatitude
        let meanLat = (a.latitude + b.latitude) / 2 * Double.pi / 180
        let dLng = (b.longitude - a.longitude) * metersPerDegreeLatitude * cos(meanLat)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    /// Whether the observer pan / pinch recognizers report a finger actually down (began or
    /// changed). Unlike `MapViewRepresentable.isUserGestureActive` this EXCLUDES `.ended`, which
    /// is "the finger just lifted" - the moment the settle logic wants to start.
    static func isTouchDown(
        panState: UIGestureRecognizer.State?,
        pinchState: UIGestureRecognizer.State?
    ) -> Bool {
        func down(_ state: UIGestureRecognizer.State?) -> Bool {
            guard let state else { return false }
            switch state {
            case .began, .changed: return true
            default: return false
            }
        }
        return down(panState) || down(pinchState)
    }

    // MARK: Outcome callback gating (spec A.4 / A23)

    /// Stable identity of an outcome for change detection: the snapped blockface key, or a
    /// fixed tag for no-curb. `nearestMeters` and the foot point change every frame and are
    /// deliberately NOT part of it (gating on those writes SwiftUI state per frame).
    static func outcomeSignature(for outcome: CurbSnapOutcome) -> String {
        switch outcome {
        case .snapped(let result):
            return "snapped|" + result.blockfaceKey
        case .noCurbInRange:
            return "noCurb"
        }
    }

    /// `onPlacementOutcome` fires on a blockface / outcome-kind change, and on every settle.
    static func shouldFireOutcome(lastSignature: String?, newSignature: String, isSettle: Bool) -> Bool {
        if isSettle { return true }
        guard let lastSignature else { return true }
        return lastSignature != newSignature
    }

    /// Design section 1 haptics: a selection tick when the blockface changes DURING a user
    /// move, throttled, never for the first outcome or a programmatic nudge.
    static let selectionHapticMinIntervalSeconds: TimeInterval = 0.15

    static func shouldFireSelectionHaptic(
        isFirstOutcome: Bool,
        userMoveInFlight: Bool,
        secondsSinceLastHaptic: TimeInterval?
    ) -> Bool {
        guard !isFirstOutcome, userMoveInFlight else { return false }
        guard let secondsSinceLastHaptic else { return true }
        return secondsSinceLastHaptic >= selectionHapticMinIntervalSeconds
    }

    // MARK: Settle nudge (design section 1 "Settle nudge refinements")

    /// Skip the nudge if the snapped point is within this many screen points of the tip
    /// (nothing visible to settle).
    static let nudgeSkipPoints: Double = 2

    /// Wait this long after the map stops before nudging; a touch in the dwell abandons it.
    static let nudgeDwellSeconds: TimeInterval = 0.1

    static let nudgeBaseSeconds: TimeInterval = 0.12
    static let nudgeSecondsPerPoint: TimeInterval = 0.002
    static let nudgeMinSeconds: TimeInterval = 0.14
    static let nudgeMaxSeconds: TimeInterval = 0.30

    /// The nudge for a ghost that sits `ghostOffsetPoints` screen points from the tip, or nil
    /// to skip. Duration `0.12 + 0.002 x pt`, clamped 0.14-0.30 s (an 86 pt jump is ~0.29 s).
    /// Reduce Motion: an instant jump (no vestibular sweep), still performed.
    static func settleNudge(ghostOffsetPoints: Double, reduceMotion: Bool) -> PlacementNudge? {
        guard ghostOffsetPoints.isFinite, ghostOffsetPoints >= nudgeSkipPoints else { return nil }
        if reduceMotion {
            return PlacementNudge(animated: false, duration: 0)
        }
        let raw = nudgeBaseSeconds + nudgeSecondsPerPoint * ghostOffsetPoints
        let clamped = min(nudgeMaxSeconds, max(nudgeMinSeconds, raw))
        return PlacementNudge(animated: true, duration: clamped)
    }

    // MARK: Exit camera (spec A.3 "Exit", A14; A3.6 ambient look)

    /// The camera the mode exits to.
    ///
    ///  - `restoreSnapshot == true` (Cancel): the snapshot's centre and distance.
    ///  - `restoreSnapshot == false` (commit): keep the street-level zoom and centre on the
    ///    placed point (`pinCoordinate`, the ground point under the tip) so the car / pin is
    ///    what the user sees.
    ///  - Pitch and heading: flag-on (`ambientLookInEffect`) the ambient driving look - the
    ///    values the caller passes from `MapViewRepresentable.driveModePitch` /
    ///    `AmbientDrivingLook.heading`, so no camera number is duplicated here; otherwise the
    ///    snapshot's own pitch and heading (today's behaviour, flag-off).
    static func exitCamera(
        restoreSnapshot: Bool,
        snapshot: PlacementCameraState,
        pinCoordinate: CLLocationCoordinate2D,
        currentDistance: CLLocationDistance,
        ambientLookInEffect: Bool,
        ambientPitch: CGFloat,
        ambientHeading: CLLocationDirection
    ) -> PlacementCameraState {
        PlacementCameraState(
            center: restoreSnapshot ? snapshot.center : pinCoordinate,
            distance: restoreSnapshot ? snapshot.distance : currentDistance,
            pitch: ambientLookInEffect ? ambientPitch : snapshot.pitch,
            heading: ambientLookInEffect ? ambientHeading : snapshot.heading
        )
    }

    // MARK: Highlight stroke (design section 2)

    /// Four layers, bottom to top: outer keyline 20 black, casing 16 white, inner keyline 11
    /// black, core 8 in the blockface's opaque severity colour. Screen points.
    static let highlightLayerCount: Int = 4
    static let highlightBaseWidths: [CGFloat] = [20, 16, 11, 8]

    /// Design Polish 13: past this scale (user zoomed out) all four widths shrink so the band
    /// cannot swallow the neighbouring curb.
    static let highlightZoomOutMetersPerPoint: Double = 0.5
    static let highlightZoomOutScale: CGFloat = 0.6

    static func highlightWidthScale(metersPerPoint: Double) -> CGFloat {
        guard metersPerPoint.isFinite else { return 1 }
        return metersPerPoint > highlightZoomOutMetersPerPoint ? highlightZoomOutScale : 1
    }

    static func highlightLayerWidths(metersPerPoint: Double) -> [CGFloat] {
        let scale = highlightWidthScale(metersPerPoint: metersPerPoint)
        return highlightBaseWidths.map { (width: CGFloat) -> CGFloat in width * scale }
    }

    /// Screen metres-per-point from an `MKOverlayRenderer` zoom scale (screen points per map
    /// point) and `MKMapPointsPerMeterAtLatitude`.
    static func metersPerScreenPoint(zoomScale: Double, mapPointsPerMeter: Double) -> Double {
        let denominator = zoomScale * mapPointsPerMeter
        guard denominator.isFinite, denominator > 0 else { return 0 }
        return 1 / denominator
    }

    /// `.unknown`'s map colour is `Color.gray.opacity(0.35)`; as the highlight CORE that would
    /// vanish (design layer 4), so the core uses opaque #8E8E93.
    static let unknownCoreRGB: (red: Double, green: Double, blue: Double) =
        (red: 142.0 / 255.0, green: 142.0 / 255.0, blue: 147.0 / 255.0)
}

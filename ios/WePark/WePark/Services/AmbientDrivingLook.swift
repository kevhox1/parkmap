//
//  AmbientDrivingLook.swift
//  WePark
//
//  Addendum 3 A3.6 (`docs/design/goal-first-ambient-design.md`) + Kevin's Option A ruling
//  (`docs/drive-mode-default-spec.md` ruling 6): flag-on, the app OPENS with the "driving
//  look" - the escalated Cruise camera's tilt and distance, north-up, muted style, the
//  standard blue dot - while staying in the cheap, resting location posture
//  (`driveModeActive == false`, no continuous GPS, no wake lock, no voice).
//
//  This file is ONLY the pure decisions behind that look, so each one is directly
//  unit-testable with no MKMapView (the project's `targetPitch`/`targetSpan` house style):
//    - when the posture applies (`isInEffect`)
//    - which zoom step a GPS fix earns (`zoomStep(forHorizontalAccuracy:)`, the A3.6.1
//      accuracy guard)
//    - the camera span for a step (`span(for:cruiseSpan:)`)
//    - whether a newly arrived fix should tighten a wide look (`shouldTighten`)
//    - what End / drive-exit restores (`restoresAmbientLookOnDriveExit`, `exitZoomStep`)
//    - the screen-space "is the user's dot outside the central 50% of the map" test the
//      Recenter button uses (`userDotOutsideCentralHalf`) - correct under pitch, where the
//      lat/lng-bounding-box test is not (see that function's doc comment).
//
//  The camera MUTATION that applies the look lives in `MapViewRepresentable.makeUIView`
//  (`CoordinatorActions.setAmbientDrivingLook`) and is driven from ContentView callers that
//  run OUTSIDE `updateUIView` (the #31 invariant). Nothing here touches UIKit or MapKit.
//
//  The Cruise pitch / span constants are deliberately NOT referenced from this file: callers
//  pass `MapViewRepresentable.driveModePitch` / `driveModeCameraSpan` in, so this look can
//  never drift from the escalated camera (A3.6.1: "reuse them; do not invent new numbers")
//  and these `nonisolated` statics never read a MainActor-isolated constant.
//
//  Invariants:
//    - No SwiftUI / UIKit / MapKit import. No Calendar.current. No force-unwraps.
//    - `nonisolated` explicit on every member (project default actor isolation is MainActor;
//      same convention as `ParkingGoals` / `DriveHeadingSnapConstants`).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import Foundation
import CoreGraphics
import CoreLocation

enum AmbientDrivingLook {

    // MARK: - Types

    /// How zoomed in the ambient look is. `.tight` is exactly the Cruise camera distance;
    /// `.wide` is one step out from it (A3.6.1's accuracy guard).
    enum ZoomStep: Equatable {
        case tight
        case wide
    }

    // MARK: - Constants

    /// A3.6.1 (spec-defined value): zoom fully in only if the fix's `horizontalAccuracy` is at
    /// or better than this. At ~100m error a fully zoomed-in view would visibly put the dot on
    /// the wrong block, which for a parking app is a trust problem.
    nonisolated static let maxTightHorizontalAccuracyMeters: CLLocationAccuracy = 65

    /// "One step wider" (A3.6.1) as a multiple of the Cruise latitude span. The spec names the
    /// step but not its size - this is the ONE new tunable this feature adds (flagged in the
    /// PR). 2x doubles the visible span (0.003 deg -> 0.006 deg, ~1,240m camera distance): still
    /// street-level, still far inside `AppConstants.polylineHideSpanThreshold` (0.04 deg), and
    /// wide enough that a ~100m-error dot lands in the right neighborhood of the frame.
    nonisolated static let wideStepSpanMultiplier: Double = 2

    /// A3.6.1: heading fixed at 0 (north-up). Heading-up needs a GPS course, which the cheap
    /// single-shot posture does not give; rotating on a guessed heading turns the map the wrong
    /// way. North-up until motion.
    nonisolated static let heading: CLLocationDirection = 0

    /// A3.6.3 "End returns to this exact launch look": on Cruise exit the look is restored at
    /// the tight step. The driver was just on a navigation-grade fix, so the accuracy guard has
    /// nothing to protect; the post-End single-shot fix can only ever tighten, never widen.
    nonisolated static let exitZoomStep: ZoomStep = .tight

    /// The Recenter test's "central 50%": the dot is inside when it is within this fraction of
    /// the map's width/height of the center on each axis (a quarter either side = the middle
    /// half). Same threshold `ambientRecenterButtonVisible`'s region-based test has always used.
    nonisolated static let centralHalfFraction: CGFloat = 0.25

    // MARK: - Posture gate

    /// Whether the ambient driving look is the active resting posture right now: flag on AND
    /// not in an escalated drive session. Mutually exclusive with `driveModeActive` by
    /// construction - this look is NEVER drive mode (spec "single biggest risk" paragraph,
    /// AC-13) - and always false flag-off, which is what keeps every flag-off path
    /// byte-identical.
    nonisolated static func isInEffect(driveModeDefaultEnabled: Bool, driveModeActive: Bool) -> Bool {
        driveModeDefaultEnabled && !driveModeActive
    }

    // MARK: - Accuracy guard (A3.6.1)

    /// The zoom step a fix earns. `.tight` only for a valid fix at or better than
    /// `maxTightHorizontalAccuracyMeters`. `nil` (no fix yet - cold launch, denied) and
    /// negative (CoreLocation's "invalid" sentinel) both open `.wide`: the spec's direction is
    /// always "open wider, tighten when a better fix arrives", never tight-then-widen.
    nonisolated static func zoomStep(forHorizontalAccuracy accuracy: CLLocationAccuracy?) -> ZoomStep {
        guard let accuracy, accuracy >= 0, accuracy <= maxTightHorizontalAccuracyMeters else {
            return .wide
        }
        return .tight
    }

    /// Latitude span for a step, derived from the Cruise camera span the caller passes in
    /// (`MapViewRepresentable.driveModeCameraSpan`). The caller converts span -> camera
    /// distance with the existing `MapViewRepresentable.altitudeForSpan`.
    nonisolated static func span(for step: ZoomStep, cruiseSpan: CLLocationDegrees) -> CLLocationDegrees {
        switch step {
        case .tight: return cruiseSpan
        case .wide:  return cruiseSpan * wideStepSpanMultiplier
        }
    }

    /// Whether a newly arrived fix should tighten the current look. Only wide -> tight, only
    /// when the user has not touched the map since the look was last applied (never fight a
    /// pan/pinch the user just made), and only when the new fix actually earns `.tight`.
    nonisolated static func shouldTighten(
        currentStep: ZoomStep,
        userAdjusted: Bool,
        newAccuracy: CLLocationAccuracy?
    ) -> Bool {
        currentStep == .wide
            && !userAdjusted
            && zoomStep(forHorizontalAccuracy: newAccuracy) == .tight
    }

    // MARK: - Drive exit

    /// Whether leaving an escalated drive session should restore the ambient driving look
    /// (flag-on) instead of the pre-drive camera/style captured at entry (flag-off, today's
    /// behavior, untouched). Flag-on the "prior" state IS the driving look - A3.6.3.
    nonisolated static func restoresAmbientLookOnDriveExit(driveModeDefaultEnabled: Bool) -> Bool {
        driveModeDefaultEnabled
    }

    // MARK: - Recenter under tilt (A3.2 / QA note on PR #135)

    /// Whether the user's dot lies OUTSIDE the central 50% of the visible map, measured in
    /// SCREEN space (the point comes from `MKMapView.convert(_:toPointTo:)`).
    ///
    /// Why screen space, not the region bounding box: under pitch (and rotation)
    /// `MKMapView.region` is the lat/lng bounding box of a TRAPEZOID - its center is no longer
    /// the camera center (it sits toward the far edge) and its span over-reports the near
    /// field. The old test (`|user - region.center| <= 0.25 * region.span`) therefore reads a
    /// dot sitting dead-center on screen as off-center once the camera is tilted. `convert`
    /// accounts for pitch, heading and zoom, so a dot at the camera center maps to the middle
    /// of the view whatever the camera, and "central 50%" means what the user sees.
    nonisolated static func userDotOutsideCentralHalf(screenPoint: CGPoint, mapSize: CGSize) -> Bool {
        guard mapSize.width > 0, mapSize.height > 0 else { return false }
        let dx = abs(screenPoint.x - mapSize.width / 2)
        let dy = abs(screenPoint.y - mapSize.height / 2)
        return dx > mapSize.width * centralHalfFraction
            || dy > mapSize.height * centralHalfFraction
    }
}

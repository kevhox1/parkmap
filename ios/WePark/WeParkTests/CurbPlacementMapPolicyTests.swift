//
//  CurbPlacementMapPolicyTests.swift
//  WeParkTests
//
//  Stream A2 (curb-pin placement map layer) - unit tests for every PURE decision in
//  `CurbPlacementMapPolicy` plus the flag-off / no-session guards on `MapViewRepresentable`.
//  Spec: docs/longpress-universal-plant-spec.md "Amendment" A.3 / A.6 / A.9 / A.11 and the
//  AUTHORITATIVE design review docs/design/curb-pin-placement-design.md.
//
//  What is and is not covered here (same disclosure `DriveCameraTiltTests` /
//  `AmbientDrivingLookTests` make): the camera / overlay / display-link / CALayer APPLICATION
//  (`setCamera`, the 30 fps loop, the reticle drawing, the 4-layer renderer output) is verified
//  by the mandatory live-UI smoke in the PR, not by a windowed MKMapView - no headless-window
//  guards, no UIWindowScene synthesis. Every DECISION that feeds those calls is a pure function
//  tested here. Flag-off byte-identical behaviour is guarded by asserting that with no
//  placement session the representable defaults are nil, the Coordinator holds no controller,
//  and the delegate hooks add no overlay and no subview.
//
//  Compile-failure-class notes: pure statics are `nonisolated` and may be called inside
//  assertion autoclosures; MainActor members (`MapViewRepresentable.*`) are read into locals
//  FIRST. Helpers are file-private with a `cpm` prefix (no XCTestCase extensions). No bare
//  `Category`. No `==` on project enums (outcomes are inspected with `if case` / switch).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine - Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
import CoreGraphics
import MapKit
import UIKit
@testable import WePark

// MARK: - File-private helpers

private func cpmPoint(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
    CurbSnapTestFixtures.coordinate(x: x, y: y)
}

/// Two parallel east-west curbs 15 m apart (y = -7.5 "S", y = +7.5 "N"), x in [-100, 100].
private func cpmTwoCurbIndex() -> CurbSnapIndex {
    CurbSnapIndex(segments: [
        CurbSnapTestFixtures.eastWestCurb(id: "S1", side: "S", y: -7.5),
        CurbSnapTestFixtures.eastWestCurb(id: "N1", side: "N", y: 7.5),
    ])
}

private func cpmResolve(_ index: CurbSnapIndex, _ x: Double, _ y: Double) -> CurbSnapOutcome {
    index.resolve(cpmPoint(x, y), incumbent: nil, metersPerPoint: 0.28, config: CurbSnapConfig.standard)
}

private func cpmSnapped(_ outcome: CurbSnapOutcome) -> CurbSnapResult? {
    if case .snapped(let result) = outcome { return result }
    return nil
}

// MARK: - Geometry: pin tip (design section 0)

final class CurbPlacementTipGeometryTests: XCTestCase {

    func testTipFractionIsTheDesignValue() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.tipHeightFraction), 0.40, accuracy: 0.0000001,
            "Design section 0: the pin tip is at 40% of the view height, NOT bounds centre.")
    }

    func testTipPoint_393x852_is341() {
        let tip = CurbPlacementMapPolicy.tipPoint(in: CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertEqual(Double(tip.x), 196.5, accuracy: 0.001)
        XCTAssertEqual(Double(tip.y), 340.8, accuracy: 0.001, "Design: 341 pt on an 852 pt screen.")
    }

    func testTipPoint_SEClass_375x667_is267() {
        let tip = CurbPlacementMapPolicy.tipPoint(in: CGRect(x: 0, y: 0, width: 375, height: 667))
        XCTAssertEqual(Double(tip.y), 266.8, accuracy: 0.001, "Design: 267 pt on a 667 pt screen.")
    }

    func testTipPoint_respectsBoundsOrigin() {
        let tip = CurbPlacementMapPolicy.tipPoint(in: CGRect(x: 10, y: 50, width: 400, height: 1000))
        XCTAssertEqual(Double(tip.x), 210, accuracy: 0.001)
        XCTAssertEqual(Double(tip.y), 450, accuracy: 0.001)
    }

    func testTipIsAboveBoundsCentre() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let tip = CurbPlacementMapPolicy.tipPoint(in: bounds)
        XCTAssertLessThan(tip.y, bounds.midY)
    }

    func testNudgeTarget_shiftsCentreByTheTipToCentreDelta() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let tip = CurbPlacementMapPolicy.tipPoint(in: bounds)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let ghost = CGPoint(x: 100, y: 400)
        let target = CurbPlacementMapPolicy.nudgeTargetScreenPoint(ghost: ghost, tip: tip, boundsCenter: centre)
        // Moving the map centre to this point puts the ghost under the tip.
        XCTAssertEqual(Double(target.x), 100 + (196.5 - 196.5), accuracy: 0.001)
        XCTAssertEqual(Double(target.y), 400 + (426 - 340.8), accuracy: 0.001)
    }

    func testNudgeTarget_ghostAlreadyUnderTip_targetIsBoundsCentre() {
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let tip = CurbPlacementMapPolicy.tipPoint(in: bounds)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let target = CurbPlacementMapPolicy.nudgeTargetScreenPoint(ghost: tip, tip: tip, boundsCenter: centre)
        XCTAssertEqual(Double(target.x), Double(centre.x), accuracy: 0.001)
        XCTAssertEqual(Double(target.y), Double(centre.y), accuracy: 0.001)
    }

    func testReticleViewTipMatchesPolicy() {
        let reticle = PlacementReticleView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        reticle.setNeedsLayout()
        reticle.layoutIfNeeded()
        let expected = CurbPlacementMapPolicy.tipPoint(in: CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertEqual(Double(reticle.tipPoint.x), Double(expected.x), accuracy: 0.001)
        XCTAssertEqual(Double(reticle.tipPoint.y), Double(expected.y), accuracy: 0.001,
            "The reticle and the resolver must use the SAME tip.")
    }

    func testReticleViewIsNonInteractiveAndDecorative() {
        let reticle = PlacementReticleView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertFalse(reticle.isUserInteractionEnabled, "Must never intercept map gestures.")
        XCTAssertFalse(reticle.isAccessibilityElement, "Decorative; the VoiceOver face is the card's summary element.")
    }

    func testReticleViewLiftState() {
        let reticle = PlacementReticleView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertFalse(reticle.isLifted)
        reticle.setLifted(true, reduceMotion: true)
        XCTAssertTrue(reticle.isLifted)
        reticle.setLifted(false, reduceMotion: true)
        XCTAssertFalse(reticle.isLifted)
    }
}

// MARK: - Entry camera, zoom floor

final class CurbPlacementEntryCameraTests: XCTestCase {

    func testEntryCameraIsFlatAndNorthUp() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.entryPitch), 0, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryHeading, 0, accuracy: 0.0001)
    }

    func testEntryVisibleHeight_matches110mWidthOnAPhoneAspect() {
        let height = CurbPlacementMapPolicy.entryVisibleHeightMeters(boundsSize: CGSize(width: 390, height: 844))
        XCTAssertEqual(height, 110.0 * 844.0 / 390.0, accuracy: 0.0001)
    }

    func testEntryVisibleHeight_unsizedMap_usesTheFallbackNotZero() {
        let unsized = CurbPlacementMapPolicy.entryVisibleHeightMeters(boundsSize: CGSize.zero)
        let fallback = CurbPlacementMapPolicy.entryVisibleHeightMeters(
            boundsSize: CurbPlacementMapPolicy.fallbackBoundsSize
        )
        XCTAssertGreaterThan(unsized, 0)
        XCTAssertEqual(unsized, fallback, accuracy: 0.0001)
    }

    /// The span constant must mirror `MapViewRepresentable.altitudeForSpan`'s, or the entry
    /// zoom silently drifts. altitude = halfHeight / tan(15 deg), so 2 * altitude * tan(15 deg)
    /// must return the visible height we asked for.
    func testLatitudeSpan_roundTripsThroughAltitudeForSpan() {
        let wantedMeters = 238.0
        let span = CurbPlacementMapPolicy.latitudeSpan(forVisibleHeightMeters: wantedMeters)
        let altitude = MapViewRepresentable.altitudeForSpan(span)
        let recovered = 2 * altitude * tan(15.0 * Double.pi / 180.0)
        XCTAssertEqual(recovered, wantedMeters, accuracy: 0.01)
    }

    /// Metres per screen point on a 390x844 view at camera distance `d`, under the repo's own
    /// `altitudeForSpan` FOV convention (visible height = 2 d tan 15 deg).
    private func cpmMetersPerPoint(atDistance d: Double) -> Double {
        2 * d * tan(15.0 * Double.pi / 180.0) / 844.0
    }

    func testEntryDistance_isNotClampedTo400_andOnlyBoundedByThePinchOutCeiling() {
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: 444), 444, accuracy: 0.0001,
            "Orchestrator ruling: entry is the altitude for the 110 m target, no 400 m clamp.")
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: 300), 300, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: 600), 600, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: 900), 600, accuracy: 0.0001,
            "Safety net: a very tall view must not start outside its own window.")
    }

    func testEntryDistance_degenerateInputFallsBackToThePhoneDefault() {
        let fallback = CurbPlacementMapPolicy.defaultEntryDistanceMeters
        XCTAssertEqual(fallback, 444, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: 0), fallback, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: -5), fallback, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: Double.nan), fallback, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: Double.infinity), fallback, accuracy: 0.0001)
    }

    /// Replaces the old "spec inconsistency" tripwire: the relation is now CONSISTENT. The 110 m
    /// target resolves to ~444 m under the repo FOV, entry is that value (not clamped), and it
    /// sits inside the 600 m pinch-out ceiling with headroom.
    func testEntryFor110mTarget_isAbout444m_insideTheCeiling_unclamped() {
        let heightMeters = CurbPlacementMapPolicy.entryVisibleHeightMeters(boundsSize: CGSize(width: 390, height: 844))
        let requested = MapViewRepresentable.altitudeForSpan(
            CurbPlacementMapPolicy.latitudeSpan(forVisibleHeightMeters: heightMeters)
        )
        let ceiling = CurbPlacementMapPolicy.zoomOutCeilingMeters
        XCTAssertEqual(requested, 444.2, accuracy: 0.5)
        XCTAssertLessThan(requested, ceiling)
        XCTAssertEqual(CurbPlacementMapPolicy.entryDistance(requested: requested), requested, accuracy: 0.0001)
        XCTAssertEqual(cpmMetersPerPoint(atDistance: requested), 0.282, accuracy: 0.002,
            "Spec A.3's ~0.28 m/pt entry scale.")
    }

    func testZoomRange_floorIs055xEntryDistance_ceilingIs600() {
        let range = CurbPlacementMapPolicy.zoomRange(entryDistance: 444)
        XCTAssertEqual(range.minDistance, 244.2, accuracy: 0.0001, "Design Finding 1: floor ~0.55x entry distance.")
        XCTAssertEqual(range.maxDistance, 600, accuracy: 0.0001, "Orchestrator ruling: pinch-out cap 600 m.")
        XCTAssertLessThan(range.minDistance, range.maxDistance)
    }

    func testZoomFloor_keepsGhostReachUnder160pt_designFinding1() {
        let floor = CurbPlacementMapPolicy.zoomRange(entryDistance: 444.2).minDistance
        let mpp = cpmMetersPerPoint(atDistance: floor)
        XCTAssertGreaterThanOrEqual(mpp, 0.15)
        XCTAssertLessThanOrEqual(24.0 / mpp, 160)
    }

    func testPinchOutCeiling_keepsTheAcquireRadiusAtLeast40pt() {
        let mpp = cpmMetersPerPoint(atDistance: CurbPlacementMapPolicy.zoomOutCeilingMeters)
        XCTAssertEqual(mpp, 0.381, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(24.0 / mpp, 40, "Spec A.3 rationale for the cap.")
    }

    func testBottomMargin_isMaxOfSnapshotAndCardPlusGap() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.bottomMargin(cardHeight: 300, snapshotEffectiveBottom: 42)), 308, accuracy: 0.0001)
        XCTAssertEqual(Double(CurbPlacementMapPolicy.bottomMargin(cardHeight: 20, snapshotEffectiveBottom: 42)), 42, accuracy: 0.0001,
            "Never below what the user already sees.")
    }

    func testBottomMargin_clearedHeightReturnsTheSnapshot() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.bottomMargin(cardHeight: 0, snapshotEffectiveBottom: 42)), 42, accuracy: 0.0001)
        XCTAssertEqual(Double(CurbPlacementMapPolicy.bottomMargin(cardHeight: -3, snapshotEffectiveBottom: 42)), 42, accuracy: 0.0001)
        XCTAssertEqual(Double(CurbPlacementMapPolicy.bottomMargin(cardHeight: CGFloat.nan, snapshotEffectiveBottom: 42)), 42, accuracy: 0.0001)
    }

    func testZoomRange_scalesWithEntryDistance() {
        let range = CurbPlacementMapPolicy.zoomRange(entryDistance: 300)
        XCTAssertEqual(range.minDistance, 165, accuracy: 0.0001)
        XCTAssertLessThan(range.minDistance, range.maxDistance)
    }

    /// Entry is always inside its own window: floor < entry <= ceiling.
    func testEntryDistanceIsAlwaysInsideItsOwnZoomRange() {
        let requests: [Double] = [50, 150, 300, 400, 444, 900, 5_000]
        for requested in requests {
            let entry = CurbPlacementMapPolicy.entryDistance(requested: requested)
            let range = CurbPlacementMapPolicy.zoomRange(entryDistance: entry)
            XCTAssertGreaterThan(entry, range.minDistance, "requested \(requested)")
            XCTAssertLessThanOrEqual(entry, range.maxDistance, "requested \(requested)")
        }
    }

    func testClampedVisibleHeight_scalesLinearlyWithDistance() {
        let clamped = CurbPlacementMapPolicy.clampedVisibleHeightMeters(
            requestedVisibleHeightMeters: 240,
            requestedDistance: 480,
            clampedDistance: 400
        )
        XCTAssertEqual(clamped, 200, accuracy: 0.0001)
        let unchanged = CurbPlacementMapPolicy.clampedVisibleHeightMeters(
            requestedVisibleHeightMeters: 240, requestedDistance: 0, clampedDistance: 400
        )
        XCTAssertEqual(unchanged, 240, accuracy: 0.0001, "No divide-by-zero.")
    }

    func testEntryCenter_putsSeedUnderTheTipByShiftingSouth() {
        let seed = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900)
        let center = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: 200)
        // The tip is 10% of the height above centre => centre is 20 m south of the seed.
        let southMeters = (seed.latitude - center.latitude) * 111_320
        XCTAssertEqual(southMeters, 20, accuracy: 0.01)
        XCTAssertEqual(center.longitude, seed.longitude, accuracy: 0.0000001)
    }

    // MARK: Exact entry region (2026-10-26 "pin lands mid-building" fix)

    func testEntrySpanDegrees_isExactWithNoFieldOfViewApproximation() {
        let span = CurbPlacementMapPolicy.entrySpanDegrees(
            seedLatitude: 40.75, visibleHeightMeters: 238.05, visibleWidthMeters: 110
        )
        XCTAssertEqual(span.latitudeDelta, 238.05 / 111_320, accuracy: 0.0000001)
        let expectedLongitudeDelta = 110 / (111_320 * cos(40.75 * Double.pi / 180))
        XCTAssertEqual(span.longitudeDelta, expectedLongitudeDelta, accuracy: 0.0000001)
    }

    func testEntrySpanDegrees_degenerateLatitudeFallsBackToASquareSpan() {
        let span = CurbPlacementMapPolicy.entrySpanDegrees(
            seedLatitude: 90, visibleHeightMeters: 200, visibleWidthMeters: 500
        )
        XCTAssertEqual(span.longitudeDelta, span.latitudeDelta, accuracy: 0.0000001,
            "cos(90 deg) == 0: no non-finite / zero longitude delta.")
    }

    func testClampedVisibleWidthMeters_keepsTheBoundsAspectRatio() {
        let width = CurbPlacementMapPolicy.clampedVisibleWidthMeters(
            boundsSize: CGSize(width: 390, height: 844), clampedHeightMeters: 200
        )
        XCTAssertEqual(width, 200 * 390.0 / 844.0, accuracy: 0.0001)
    }

    func testClampedVisibleWidthMeters_unsizedMapUsesTheFallback() {
        let width = CurbPlacementMapPolicy.clampedVisibleWidthMeters(boundsSize: .zero, clampedHeightMeters: 200)
        let fallback = CurbPlacementMapPolicy.clampedVisibleWidthMeters(
            boundsSize: CurbPlacementMapPolicy.fallbackBoundsSize, clampedHeightMeters: 200
        )
        XCTAssertEqual(width, fallback, accuracy: 0.0001)
    }

    /// The actual requirement: given a seed, a screen size, the 40% tip fraction and a visible
    /// span, the resulting `entryCenter` + `entrySpanDegrees` region must put the seed EXACTLY at
    /// the tip - not approximately. This is the round trip that replaces the old
    /// `altitudeForSpan`-driven centring (never exact; needed a post-hoc nudge that the 2026-10-26
    /// report showed could be skipped entirely). Checked across several phone screen sizes; the
    /// entry camera is ALWAYS pitch 0 / heading 0 (`testEntryCameraIsFlatAndNorthUp`), so there is
    /// no rotated-entry case to also check - only straight north-up.
    func testEntryRegion_seedLandsExactlyAtTheTipFraction_acrossScreenSizes() {
        let seeds: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 40.7484, longitude: -73.9857), // Midtown
            CLLocationCoordinate2D(latitude: 40.8075, longitude: -73.9626), // Upper Manhattan
        ]
        let sizes: [CGSize] = [
            CGSize(width: 390, height: 844),  // iPhone 12/13/14
            CGSize(width: 375, height: 667),  // SE-class
            CGSize(width: 428, height: 926),  // Pro Max-class
            CGSize(width: 393, height: 852),  // iPhone 15
        ]
        for seed in seeds {
            for size in sizes {
                let heightMeters = CurbPlacementMapPolicy.entryVisibleHeightMeters(boundsSize: size)
                let center = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: heightMeters)
                let widthMeters = CurbPlacementMapPolicy.clampedVisibleWidthMeters(
                    boundsSize: size, clampedHeightMeters: heightMeters
                )
                let span = CurbPlacementMapPolicy.entrySpanDegrees(
                    seedLatitude: seed.latitude, visibleHeightMeters: heightMeters, visibleWidthMeters: widthMeters
                )
                let topLatitude = center.latitude + span.latitudeDelta / 2
                let fractionFromTop = (topLatitude - seed.latitude) / span.latitudeDelta
                XCTAssertEqual(
                    fractionFromTop, Double(CurbPlacementMapPolicy.tipHeightFraction), accuracy: 0.000001,
                    "seed \(seed), size \(size): must sit EXACTLY at the 40% tip fraction."
                )
                XCTAssertEqual(center.longitude, seed.longitude, accuracy: 0.0000001, "No horizontal offset.")
            }
        }
    }

    func testEntryArrived_withinToleranceAndFlat() {
        let target = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900)
        XCTAssertTrue(CurbPlacementMapPolicy.entryArrived(currentCenter: target, targetCenter: target, currentPitch: 0))
        let nearby = CLLocationCoordinate2D(latitude: 40.75001, longitude: -73.9900) // ~1.1 m
        XCTAssertTrue(CurbPlacementMapPolicy.entryArrived(currentCenter: nearby, targetCenter: target, currentPitch: 0.5))
    }

    func testEntryArrived_staleCallbackFromAnInterruptedAnimationIsRejected() {
        let target = CLLocationCoordinate2D(latitude: 40.7500, longitude: -73.9900)
        let farAway = CLLocationCoordinate2D(latitude: 40.7520, longitude: -73.9900) // ~223 m
        XCTAssertFalse(CurbPlacementMapPolicy.entryArrived(currentCenter: farAway, targetCenter: target, currentPitch: 30))
        XCTAssertFalse(CurbPlacementMapPolicy.entryArrived(currentCenter: target, targetCenter: target, currentPitch: 12),
            "Still tilted: not landed.")
        let justOutsideTolerance = CLLocationCoordinate2D(latitude: 40.75004, longitude: -73.9900) // ~4.5 m
        XCTAssertFalse(CurbPlacementMapPolicy.entryArrived(currentCenter: justOutsideTolerance, targetCenter: target, currentPitch: 0))
    }
}

// MARK: - Display link, resolve skip, touch state

final class CurbPlacementLoopDecisionTests: XCTestCase {

    func testDisplayLinkIs30fps() {
        XCTAssertEqual(CurbPlacementMapPolicy.displayLinkFramesPerSecond, 30)
    }

    func testShouldResolve_firstResolveAlwaysRuns() {
        XCTAssertTrue(CurbPlacementMapPolicy.shouldResolve(movedMeters: nil))
    }

    func testShouldResolve_skipsBelowThreshold() {
        XCTAssertFalse(CurbPlacementMapPolicy.shouldResolve(movedMeters: 0))
        XCTAssertFalse(CurbPlacementMapPolicy.shouldResolve(movedMeters: 0.149))
    }

    func testShouldResolve_runsAtAndAboveThreshold() {
        XCTAssertEqual(CurbPlacementMapPolicy.resolveSkipMeters, 0.15, accuracy: 0.0000001)
        XCTAssertTrue(CurbPlacementMapPolicy.shouldResolve(movedMeters: 0.15))
        XCTAssertTrue(CurbPlacementMapPolicy.shouldResolve(movedMeters: 3))
    }

    func testShouldResolve_nonFiniteDistanceFailsOpen() {
        XCTAssertTrue(CurbPlacementMapPolicy.shouldResolve(movedMeters: Double.nan))
    }

    func testDisplayLinkRunsOnlyWhileTheMapMovesAfterEntry() {
        XCTAssertTrue(CurbPlacementMapPolicy.displayLinkShouldRun(placementActive: true, entryInProgress: false, mapMoving: true))
        XCTAssertFalse(CurbPlacementMapPolicy.displayLinkShouldRun(placementActive: true, entryInProgress: false, mapMoving: false),
            "Idle: paused.")
        XCTAssertFalse(CurbPlacementMapPolicy.displayLinkShouldRun(placementActive: true, entryInProgress: true, mapMoving: true),
            "The entry flight must not stream card updates.")
        XCTAssertFalse(CurbPlacementMapPolicy.displayLinkShouldRun(placementActive: false, entryInProgress: false, mapMoving: true),
            "Ended: never runs.")
    }

    func testApproxMeters_latitudeDegree() {
        let a = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let b = CLLocationCoordinate2D(latitude: 40.751, longitude: -73.99)
        XCTAssertEqual(CurbPlacementMapPolicy.approxMeters(from: a, to: b), 111.32, accuracy: 0.01)
    }

    func testApproxMeters_longitudeShrinksWithLatitude() {
        let a = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.990)
        let b = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.989)
        let expected = 111.32 * cos(40.75 * Double.pi / 180)
        XCTAssertEqual(CurbPlacementMapPolicy.approxMeters(from: a, to: b), expected, accuracy: 0.01)
    }

    func testApproxMeters_agreesWithTheSnapEngineScale() {
        // 5 m east on the snap engine's own projection must read ~5 m here (0.15 m skip is only
        // meaningful if both use the same metres).
        let moved = CurbPlacementMapPolicy.approxMeters(from: cpmPoint(0, 0), to: cpmPoint(5, 0))
        XCTAssertEqual(moved, 5, accuracy: 0.05)
    }

    func testIsTouchDown_beganAndChangedOnly() {
        XCTAssertTrue(CurbPlacementMapPolicy.isTouchDown(panState: .began, pinchState: nil))
        XCTAssertTrue(CurbPlacementMapPolicy.isTouchDown(panState: .changed, pinchState: nil))
        XCTAssertTrue(CurbPlacementMapPolicy.isTouchDown(panState: nil, pinchState: .changed))
        XCTAssertTrue(CurbPlacementMapPolicy.isTouchDown(panState: .possible, pinchState: .began))
    }

    func testIsTouchDown_endedIsTheSettleMomentNotTouchDown() {
        XCTAssertFalse(CurbPlacementMapPolicy.isTouchDown(panState: .ended, pinchState: .ended))
        XCTAssertFalse(CurbPlacementMapPolicy.isTouchDown(panState: .cancelled, pinchState: .failed))
        XCTAssertFalse(CurbPlacementMapPolicy.isTouchDown(panState: .possible, pinchState: .possible))
        XCTAssertFalse(CurbPlacementMapPolicy.isTouchDown(panState: nil, pinchState: nil))
    }
}

// MARK: - Outcome gating (A23)

final class CurbPlacementOutcomeGatingTests: XCTestCase {

    func testSignature_sameBlockfaceDifferentFootPoint_isEqual() {
        let index = cpmTwoCurbIndex()
        let a = cpmSnapped(cpmResolve(index, -40, -6))
        let b = cpmSnapped(cpmResolve(index, 40, -6))
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        guard let a, let b else { return }
        // The foot point differs every frame of a pan...
        XCTAssertNotEqual(a.snappedCoordinate.longitude, b.snappedCoordinate.longitude)
        // ...but the signature the callback is gated on does not.
        XCTAssertEqual(
            CurbPlacementMapPolicy.outcomeSignature(for: .snapped(a)),
            CurbPlacementMapPolicy.outcomeSignature(for: .snapped(b))
        )
    }

    func testSignature_differentBlockface_differs() {
        let index = cpmTwoCurbIndex()
        let south = cpmSnapped(cpmResolve(index, 0, -6))
        let north = cpmSnapped(cpmResolve(index, 0, 6))
        guard let south, let north else {
            XCTFail("both fixture curbs must be acquirable")
            return
        }
        XCTAssertNotEqual(
            CurbPlacementMapPolicy.outcomeSignature(for: .snapped(south)),
            CurbPlacementMapPolicy.outcomeSignature(for: .snapped(north))
        )
    }

    func testSignature_noCurb_ignoresNearestMeters() {
        let a = CurbPlacementMapPolicy.outcomeSignature(for: .noCurbInRange(nearestMeters: 31))
        let b = CurbPlacementMapPolicy.outcomeSignature(for: .noCurbInRange(nearestMeters: 60))
        let c = CurbPlacementMapPolicy.outcomeSignature(for: .noCurbInRange(nearestMeters: nil))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func testSignature_snappedVersusNoCurb_differs() {
        let index = cpmTwoCurbIndex()
        guard let snapped = cpmSnapped(cpmResolve(index, 0, -6)) else {
            XCTFail("fixture curb must be acquirable")
            return
        }
        XCTAssertNotEqual(
            CurbPlacementMapPolicy.outcomeSignature(for: .snapped(snapped)),
            CurbPlacementMapPolicy.outcomeSignature(for: .noCurbInRange(nearestMeters: nil))
        )
    }

    func testShouldFire_firstOutcomeFires() {
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireOutcome(lastSignature: nil, newSignature: "noCurb", isSettle: false))
    }

    func testShouldFire_sameSignatureDoesNotFire_perFrameWritesAreImpossible() {
        for _ in 0..<100 {
            XCTAssertFalse(CurbPlacementMapPolicy.shouldFireOutcome(
                lastSignature: "snapped|X", newSignature: "snapped|X", isSettle: false))
        }
    }

    func testShouldFire_changedSignatureFires() {
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireOutcome(
            lastSignature: "snapped|X", newSignature: "snapped|Y", isSettle: false))
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireOutcome(
            lastSignature: "snapped|X", newSignature: "noCurb", isSettle: false))
    }

    func testShouldFire_settleAlwaysFires() {
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireOutcome(
            lastSignature: "snapped|X", newSignature: "snapped|X", isSettle: true))
    }

    /// A3 budget (A23): over a 3 s pan the callback count is bounded by blockface changes + 1.
    func testCallbackCountOverASimulatedPan_isBoundedByBlockfaceChangesPlusOneSettle() {
        let signatures: [String] = [
            "snapped|A", "snapped|A", "snapped|A", "snapped|B", "snapped|B", "noCurb",
            "noCurb", "snapped|B", "snapped|B", "snapped|B",
        ]
        var last: String?
        var fires = 0
        var changes = 0
        for signature in signatures {
            if last != nil, last != signature { changes += 1 }
            if CurbPlacementMapPolicy.shouldFireOutcome(lastSignature: last, newSignature: signature, isSettle: false) {
                fires += 1
                last = signature
            }
        }
        // First outcome + each change; then ONE settle.
        XCTAssertEqual(fires, 1 + changes)
        let withSettle = fires + 1
        XCTAssertLessThanOrEqual(withSettle, signatures.count)
        XCTAssertEqual(withSettle, 1 + changes + 1)
    }

    func testHaptic_neverOnFirstOutcomeOrProgrammaticMove() {
        XCTAssertFalse(CurbPlacementMapPolicy.shouldFireSelectionHaptic(
            isFirstOutcome: true, userMoveInFlight: true, secondsSinceLastHaptic: nil))
        XCTAssertFalse(CurbPlacementMapPolicy.shouldFireSelectionHaptic(
            isFirstOutcome: false, userMoveInFlight: false, secondsSinceLastHaptic: nil),
            "Design: never for programmatic nudges.")
    }

    func testHaptic_throttledTo150ms() {
        XCTAssertEqual(CurbPlacementMapPolicy.selectionHapticMinIntervalSeconds, 0.15, accuracy: 0.0000001)
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireSelectionHaptic(
            isFirstOutcome: false, userMoveInFlight: true, secondsSinceLastHaptic: nil))
        XCTAssertFalse(CurbPlacementMapPolicy.shouldFireSelectionHaptic(
            isFirstOutcome: false, userMoveInFlight: true, secondsSinceLastHaptic: 0.10))
        XCTAssertTrue(CurbPlacementMapPolicy.shouldFireSelectionHaptic(
            isFirstOutcome: false, userMoveInFlight: true, secondsSinceLastHaptic: 0.15))
    }
}

// MARK: - Settle nudge

final class CurbPlacementSettleNudgeTests: XCTestCase {

    func testNudge_skippedUnder2Points() {
        XCTAssertNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 0, reduceMotion: false))
        XCTAssertNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 1.99, reduceMotion: false))
    }

    func testNudge_performedAtAndAbove2Points() {
        XCTAssertNotNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 2, reduceMotion: false))
        XCTAssertNotNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 40, reduceMotion: false))
    }

    func testNudge_durationScalesWithDistance() {
        let near = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 20, reduceMotion: false)
        let far = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 80, reduceMotion: false)
        XCTAssertNotNil(near)
        XCTAssertNotNil(far)
        guard let near, let far else { return }
        XCTAssertEqual(near.duration, 0.16, accuracy: 0.0001, "0.12 + 0.002 x 20")
        XCTAssertEqual(far.duration, 0.28, accuracy: 0.0001, "0.12 + 0.002 x 80")
        XCTAssertGreaterThan(far.duration, near.duration)
        XCTAssertTrue(near.animated)
        XCTAssertTrue(far.animated)
    }

    func testNudge_86ptJumpIsAbout0_29s_notTheSpecsFixed180ms() {
        let nudge = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 86, reduceMotion: false)
        XCTAssertNotNil(nudge)
        XCTAssertEqual(nudge?.duration ?? 0, 0.292, accuracy: 0.0001)
    }

    func testNudge_durationIsClamped() {
        // 2 pt would be 0.124 s raw - floored at 0.14.
        let tiny = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 2, reduceMotion: false)
        XCTAssertEqual(tiny?.duration ?? 0, 0.14, accuracy: 0.0001)
        // 500 pt would be 1.12 s raw - capped at 0.30.
        let huge = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 500, reduceMotion: false)
        XCTAssertEqual(huge?.duration ?? 0, 0.30, accuracy: 0.0001)
    }

    func testNudge_reduceMotionIsInstantButStillPerformed() {
        let nudge = CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 60, reduceMotion: true)
        XCTAssertNotNil(nudge)
        XCTAssertEqual(nudge?.animated, false)
        XCTAssertEqual(nudge?.duration ?? -1, 0, accuracy: 0.0001)
    }

    func testNudge_reduceMotionStillSkipsNothingToSettle() {
        XCTAssertNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: 1, reduceMotion: true))
    }

    func testNudge_nonFiniteOffsetIsSkipped() {
        XCTAssertNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: Double.nan, reduceMotion: false))
        XCTAssertNil(CurbPlacementMapPolicy.settleNudge(ghostOffsetPoints: Double.infinity, reduceMotion: false))
    }

    func testNudgeDwellIs100ms() {
        XCTAssertEqual(CurbPlacementMapPolicy.nudgeDwellSeconds, 0.1, accuracy: 0.0000001)
    }
}

// MARK: - Exit camera (A14, A3.6 ambient look)

final class CurbPlacementExitCameraTests: XCTestCase {

    private func cpmSnapshot() -> PlacementCameraState {
        PlacementCameraState(
            center: CLLocationCoordinate2D(latitude: 40.70, longitude: -74.00),
            distance: 621,
            pitch: 30,
            heading: 0
        )
    }

    private let cpmPin = CLLocationCoordinate2D(latitude: 40.7512, longitude: -73.9921)

    func testCancel_flagOff_restoresTheExactSnapshot() {
        let snapshot = cpmSnapshot()
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: true, snapshot: snapshot, pinCoordinate: cpmPin, currentDistance: 220,
            ambientLookInEffect: false, ambientPitch: 30, ambientHeading: 0
        )
        XCTAssertEqual(exit.center.latitude, snapshot.center.latitude, accuracy: 0.0000001)
        XCTAssertEqual(exit.center.longitude, snapshot.center.longitude, accuracy: 0.0000001)
        XCTAssertEqual(exit.distance, 621, accuracy: 0.0001)
        XCTAssertEqual(Double(exit.pitch), 30, accuracy: 0.0001)
        XCTAssertEqual(exit.heading, 0, accuracy: 0.0001)
    }

    func testCommit_flagOff_keepsStreetZoomCentresOnThePin_restoresPitchAndHeading() {
        var snapshot = cpmSnapshot()
        snapshot = PlacementCameraState(center: snapshot.center, distance: 900, pitch: 12, heading: 45)
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: false, snapshot: snapshot, pinCoordinate: cpmPin, currentDistance: 260,
            ambientLookInEffect: false, ambientPitch: 30, ambientHeading: 0
        )
        XCTAssertEqual(exit.center.latitude, cpmPin.latitude, accuracy: 0.0000001)
        XCTAssertEqual(exit.center.longitude, cpmPin.longitude, accuracy: 0.0000001)
        XCTAssertEqual(exit.distance, 260, accuracy: 0.0001, "A.3: commit keeps the zoom.")
        XCTAssertEqual(Double(exit.pitch), 12, accuracy: 0.0001, "Flag-off: the prior pitch, not the ambient one.")
        XCTAssertEqual(exit.heading, 45, accuracy: 0.0001)
    }

    func testCancel_flagOn_returnsTheAmbientLook_notTheSnapshotsPitch() {
        let snapshot = PlacementCameraState(
            center: CLLocationCoordinate2D(latitude: 40.70, longitude: -74.00),
            distance: 621, pitch: 0, heading: 90
        )
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: true, snapshot: snapshot, pinCoordinate: cpmPin, currentDistance: 220,
            ambientLookInEffect: true, ambientPitch: 30, ambientHeading: 0
        )
        XCTAssertEqual(Double(exit.pitch), 30, accuracy: 0.0001)
        XCTAssertEqual(exit.heading, 0, accuracy: 0.0001)
        XCTAssertEqual(exit.distance, 621, accuracy: 0.0001)
    }

    func testCommit_flagOn_returnsTheAmbientLookAtStreetZoom() {
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: false, snapshot: cpmSnapshot(), pinCoordinate: cpmPin, currentDistance: 240,
            ambientLookInEffect: true, ambientPitch: 30, ambientHeading: 0
        )
        XCTAssertEqual(Double(exit.pitch), 30, accuracy: 0.0001)
        XCTAssertEqual(exit.heading, 0, accuracy: 0.0001)
        XCTAssertEqual(exit.distance, 240, accuracy: 0.0001)
        XCTAssertEqual(exit.center.latitude, cpmPin.latitude, accuracy: 0.0000001)
    }

    /// The ambient numbers are INPUTS, sourced from the merged A3.6 constants - this layer
    /// duplicates no camera number. Read the MainActor constants into locals first (class 5).
    func testAmbientNumbersComeFromTheMergedA36Constants() {
        let cruisePitch = MapViewRepresentable.driveModePitch
        let ambientHeading = AmbientDrivingLook.heading
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: true, snapshot: cpmSnapshot(), pinCoordinate: cpmPin, currentDistance: 220,
            ambientLookInEffect: true, ambientPitch: cruisePitch, ambientHeading: ambientHeading
        )
        XCTAssertEqual(Double(exit.pitch), Double(cruisePitch), accuracy: 0.0001)
        XCTAssertEqual(exit.heading, ambientHeading, accuracy: 0.0001)
    }

    /// Placement is a resting-posture mode: the ambient look applies exactly when its flag is
    /// on (it passes `driveModeActive: false`; it never reads the real one).
    func testAmbientPostureGate_atRest_followsTheFlag() {
        XCTAssertTrue(AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: true, driveModeActive: false))
        XCTAssertFalse(AmbientDrivingLook.isInEffect(driveModeDefaultEnabled: false, driveModeActive: false))
    }
}

// MARK: - Highlight stroke (design section 2)

final class CurbPlacementHighlightTests: XCTestCase {

    func testFourLayerWidths_20_16_11_8() {
        let widths = CurbPlacementMapPolicy.highlightLayerWidths(metersPerPoint: 0.28)
        XCTAssertEqual(widths.count, CurbPlacementMapPolicy.highlightLayerCount)
        XCTAssertEqual(widths.count, 4)
        XCTAssertEqual(Double(widths[0]), 20, accuracy: 0.0001, "outer keyline")
        XCTAssertEqual(Double(widths[1]), 16, accuracy: 0.0001, "white casing")
        XCTAssertEqual(Double(widths[2]), 11, accuracy: 0.0001, "inner keyline")
        XCTAssertEqual(Double(widths[3]), 8, accuracy: 0.0001, "severity core")
    }

    func testLayersAreStrictlyNested() {
        let widths = CurbPlacementMapPolicy.highlightLayerWidths(metersPerPoint: 0.28)
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
        XCTAssertGreaterThan(widths[2], widths[3])
    }

    func testZoomOutShrinksAllLayersTo60Percent() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.highlightWidthScale(metersPerPoint: 0.5)), 1, accuracy: 0.0001,
            "Exactly 0.5 m/pt is not past the threshold.")
        XCTAssertEqual(Double(CurbPlacementMapPolicy.highlightWidthScale(metersPerPoint: 0.51)), 0.6, accuracy: 0.0001)
        let widths = CurbPlacementMapPolicy.highlightLayerWidths(metersPerPoint: 0.8)
        XCTAssertEqual(Double(widths[0]), 12, accuracy: 0.0001)
        XCTAssertEqual(Double(widths[1]), 9.6, accuracy: 0.0001)
        XCTAssertEqual(Double(widths[2]), 6.6, accuracy: 0.0001)
        XCTAssertEqual(Double(widths[3]), 4.8, accuracy: 0.0001)
    }

    func testNonFiniteScaleDoesNotShrink() {
        XCTAssertEqual(Double(CurbPlacementMapPolicy.highlightWidthScale(metersPerPoint: Double.nan)), 1, accuracy: 0.0001)
    }

    func testMetersPerScreenPoint_isTheInverseOfZoomScaleTimesMapPointsPerMeter() {
        XCTAssertEqual(CurbPlacementMapPolicy.metersPerScreenPoint(zoomScale: 0.5, mapPointsPerMeter: 8), 0.25, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.metersPerScreenPoint(zoomScale: 0, mapPointsPerMeter: 8), 0)
        XCTAssertEqual(CurbPlacementMapPolicy.metersPerScreenPoint(zoomScale: 1, mapPointsPerMeter: 0), 0)
    }

    func testUnknownCoreIsOpaqueGrey8E8E93() {
        let rgb = CurbPlacementMapPolicy.unknownCoreRGB
        XCTAssertEqual(rgb.red * 255, 142, accuracy: 0.0001)
        XCTAssertEqual(rgb.green * 255, 142, accuracy: 0.0001)
        XCTAssertEqual(rgb.blue * 255, 147, accuracy: 0.0001)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let core = PlacementHighlightStyle.coreColor(for: .unknown, traits: traits)
        XCTAssertEqual(Double(core.alpha), 1, accuracy: 0.0001,
            "The map's unknown colour is 35% alpha and would vanish as a core (design layer 4).")
    }

    func testEveryCoreColourIsFullyOpaque() {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let states: [CurrentState] = [.restrictedNow, .freeButRestrictionSoon, .meteredActive, .freeComfortably, .unknown]
        for state in states {
            let core = PlacementHighlightStyle.coreColor(for: state, traits: traits)
            XCTAssertEqual(Double(core.alpha), 1, accuracy: 0.0001, "A.11 A25: no alpha < 1 on the highlight.")
        }
    }

    func testCoreColourIsDataItFollowsTheSeverityPalette() {
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let restricted = PlacementHighlightStyle.coreColor(for: .restrictedNow, traits: traits)
        let free = PlacementHighlightStyle.coreColor(for: .freeComfortably, traits: traits)
        XCTAssertNotEqual(restricted.components ?? [], free.components ?? [])
    }

    func testOverlayBuildsFromASegmentWithAnInflatedBoundingRect() {
        let segment = CurbSnapTestFixtures.eastWestCurb(id: "H1", side: "S", y: 0, x0: -50, x1: 50)
        let color = CGColor(gray: 0.5, alpha: 1)
        let overlay = PlacementHighlightOverlay(segment: segment, coreColor: color)
        XCTAssertNotNil(overlay)
        guard let overlay else { return }
        XCTAssertEqual(overlay.blockfaceKey, segment.blockfaceKey)
        XCTAssertEqual(overlay.points.count, 2)

        // The bbox must be wider than the 100 m polyline by the stroke inflation on each side.
        let metersWide = overlay.boundingMapRect.size.width / MKMapPointsPerMeterAtLatitude(overlay.coordinate.latitude)
        XCTAssertGreaterThan(metersWide, 100 + 2 * PlacementHighlightOverlay.boundingInflationMeters - 1)
        // And it has height even though the curb is perfectly east-west (the stroke has width).
        XCTAssertGreaterThan(overlay.boundingMapRect.size.height, 0)
    }

    func testOverlayRejectsASegmentWithNothingToDraw() {
        let segment = CurbSnapTestFixtures.segment(id: "H2", side: "S", points: [(0, 0)])
        XCTAssertNil(PlacementHighlightOverlay(segment: segment, coreColor: CGColor(gray: 0, alpha: 1)))
    }
}

// MARK: - Flag-off / no-session guards (byte-identical)

final class CurbPlacementFlagOffGuardTests: XCTestCase {

    private func cpmRepresentable(actions: MapViewRepresentable.CoordinatorActions) -> MapViewRepresentable {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        return MapViewRepresentable(
            region: .constant(region),
            selectedSegmentID: .constant(nil),
            onTap: { _ in },
            onLongPress: { _ in },
            onRegionChanged: { _ in },
            onCarPinTapped: {},
            carPin: nil,
            overlayPayload: .init(),
            activeRoute: nil,
            destinationCoordinate: nil,
            coordinatorActions: actions
        )
    }

    func testRepresentableDefaults_modeIsOff() {
        let representable = cpmRepresentable(actions: MapViewRepresentable.CoordinatorActions())
        XCTAssertNil(representable.placementIndex, "nil => mode off.")
        XCTAssertNil(representable.onPlacementOutcome)
        XCTAssertNil(representable.placementSeverity)
    }

    func testFreshCoordinator_hasNoPlacementSession() {
        let representable = cpmRepresentable(actions: MapViewRepresentable.CoordinatorActions())
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        XCTAssertNil(coordinator.placementController)
    }

    func testDelegateHooksWithNoSession_addNoOverlayAndNoSubview() {
        let representable = cpmRepresentable(actions: MapViewRepresentable.CoordinatorActions())
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()
        coordinator.mapView = mapView
        let subviewsBefore = mapView.subviews.count
        let overlaysBefore = mapView.overlays.count

        coordinator.mapView(mapView, regionWillChangeAnimated: false)
        coordinator.mapView(mapView, regionDidChangeAnimated: false)

        XCTAssertEqual(mapView.subviews.count, subviewsBefore, "No reticle without a session.")
        XCTAssertEqual(mapView.overlays.count, overlaysBefore, "No highlight overlay without a session.")
        XCTAssertNil(coordinator.placementController)
    }

    func testOverlayPayloadRebuildWithNoSession_addsNoPlacementOverlay() {
        let representable = cpmRepresentable(actions: MapViewRepresentable.CoordinatorActions())
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        let mapView = MKMapView()
        coordinator.mapView = mapView
        coordinator.applyOverlayPayload(.init(), to: mapView)
        var placementOverlays = 0
        for overlay in mapView.overlays where overlay is PlacementHighlightOverlay {
            placementOverlays += 1
        }
        XCTAssertEqual(placementOverlays, 0)
    }

    func testFreshCoordinatorActions_placementClosuresAreAllNil() {
        let actions = MapViewRepresentable.CoordinatorActions()
        XCTAssertNil(actions.onBeginPlacement)
        XCTAssertNil(actions.onEndPlacement)
        XCTAssertNil(actions.onRefreshPlacement)
        XCTAssertNil(actions.onCyclePlacementCurb)
        XCTAssertNil(actions.onSetPlacementBottomInset)
        XCTAssertNil(actions.onFocusPlacement)
        XCTAssertNil(actions.onQueryPlacementActive)
        XCTAssertNil(actions.onQueryPlacementPin)
        XCTAssertNil(actions.placementPinCoordinate())
    }

    func testIsPlacementActive_falseWhenNothingInstalled_andFollowsTheProvider() {
        let actions = MapViewRepresentable.CoordinatorActions()
        XCTAssertFalse(actions.isPlacementActive)
        var live = true
        actions.onQueryPlacementActive = { live }
        XCTAssertTrue(actions.isPlacementActive)
        live = false
        XCTAssertFalse(actions.isPlacementActive)
    }

    func testFocusPlacementSeamForwardsTheCoordinate_andIsInertWhenNotInstalled() {
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.focusPlacement(on: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99))
        var received: Double?
        actions.onFocusPlacement = { coordinate in received = coordinate.latitude }
        actions.focusPlacement(on: CLLocationCoordinate2D(latitude: 40.76, longitude: -73.99))
        XCTAssertEqual(received ?? 0, 40.76, accuracy: 0.0000001)
    }

    func testFreshCoordinator_isNotPlacementActive_viaTheInstalledProvider() {
        let actions = MapViewRepresentable.CoordinatorActions()
        let representable = cpmRepresentable(actions: actions)
        let coordinator = MapViewRepresentable.Coordinator(parent: representable)
        actions.onQueryPlacementActive = { [weak coordinator] in coordinator?.placementController != nil }
        XCTAssertFalse(actions.isPlacementActive)
    }

    func testPlacementActionsAreInertWhenNothingInstalledThem() {
        let actions = MapViewRepresentable.CoordinatorActions()
        // Flag off: ContentView never calls these, and if it did they must do nothing (the
        // closures are only installed by makeUIView and only create a session on begin).
        actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99))
        actions.endPlacement(restore: true)
        actions.refreshPlacement()
        actions.cyclePlacementCurb()
        actions.setPlacementBottomInset(300)
        XCTAssertNil(actions.onBeginPlacement)
    }

    /// The seam A3 calls: seed-only form compiles, and the optional parameters are defaulted.
    func testBeginPlacementSeamForms() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var received: [(Double, String?, Bool)] = []
        actions.onBeginPlacement = { seed, incumbent, animated in
            received.append((seed.latitude, incumbent, animated))
        }
        actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99))
        actions.beginPlacement(
            seed: CLLocationCoordinate2D(latitude: 40.76, longitude: -73.99),
            incumbentBlockfaceKey: "MAIN ST|A ST|B ST|S",
            animated: false
        )
        XCTAssertEqual(received.count, 2)
        XCTAssertNil(received[0].1)
        XCTAssertEqual(received[0].2, true, "Default: animated entry.")
        XCTAssertEqual(received[1].1, "MAIN ST|A ST|B ST|S")
        XCTAssertEqual(received[1].2, false)
    }

    func testEndPlacementSeamForwardsRestoreFlag() {
        let actions = MapViewRepresentable.CoordinatorActions()
        var flags: [Bool] = []
        actions.onEndPlacement = { restore in flags.append(restore) }
        actions.endPlacement(restore: true)
        actions.endPlacement(restore: false)
        XCTAssertEqual(flags, [true, false])
    }
}

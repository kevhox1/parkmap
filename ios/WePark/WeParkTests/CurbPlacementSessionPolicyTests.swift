//
//  CurbPlacementSessionPolicyTests.swift
//  WeParkTests
//
//  Stream A3 (curb-pin placement, ContentView mode) - the flag-off byte-identity guards and the
//  pure decisions behind ContentView's wiring (Services/CurbPlacementSession.swift):
//    - the dark-ship flag and its independence (spec A.6)
//    - entry routing per A.7 / the entry guard per A.3 / A22 mutual exclusion
//    - the chrome-visibility parameter threading (AC-A21): every existing pure chrome function
//      keeps its exact result with the new trailing parameter defaulted, and hides when it is set
//    - the generic `.sheet(onDismiss:)` catch-all clause (AC-A21)
//    - the recenter / ambient-look DEFERRAL plan (PR #140 QA #2, P2-1 (a)+(b))
//    - the ambient-look bookkeeping on exit (P2-1 (c): state only, never a camera move)
//    - teardown / heal decisions and the `isPlacementActive` seam contract (QA #4, (d))
//    - the Park and report handoffs' payloads (spec A.6 table, AC-A15/A16)
//    - the pin estimate, bearing and nearest-curb helpers, and the first-use hint gate
//
//  Flag-off claims that are pure SwiftUI wiring (the modifier chain, the overlay mount) cannot be
//  called from a test; those are covered by code inspection plus the live smoke in the PR body -
//  the same disclosure `DM2GoalSelectorTests` / `MinimalAmbientLayoutTests` make.
//
//  Compile-failure-class notes: pure statics are `nonisolated` and are called directly; MainActor
//  members (`AppConstants`, `ContentView.*`, `MapViewRepresentable.*`) are read into locals
//  FIRST. Helpers are file-private with a `cpsp` prefix (no XCTestCase extensions). No bare
//  `Category`. No `==` on project enums outside XCTAssertEqual of `Equatable` nonisolated enums;
//  `CurbSnapOutcome` is inspected with `if case`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine - Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers

private let cpspAllEntries: [CurbPlacementEntry] = [.longPress, .reportPill, .pathB]

private func cpspRoute(
    _ entry: CurbPlacementEntry,
    flag: Bool,
    drive: Bool = false,
    blockSelect: Bool = false,
    spot: Bool = false,
    placement: Bool = false
) -> CurbPlacementEntryRouting {
    CurbPlacementPolicy.routing(
        for: entry,
        flagEnabled: flag,
        driveModeActive: drive,
        blockSelectModeActive: blockSelect,
        spotPlacementActive: spot,
        placementActive: placement
    )
}

private func cpspSnappedOutcome(distance: Double = 3.0) -> CurbSnapOutcome {
    let segment = CurbSnapTestFixtures.segment(
        id: "CPSP_SEG",
        street: "STANTON STREET",
        from: "BOWERY",
        to: "CHRYSTIE STREET",
        side: "S",
        points: [(-10, 0), (10, 0)]
    )
    return .snapped(CurbSnapResult(
        segment: segment,
        positionFraction: 0.4,
        distanceMeters: distance,
        snappedCoordinate: CurbSnapTestFixtures.coordinate(x: 2, y: 0)
    ))
}

// MARK: - Flag

final class CurbPlacementFlagTests: XCTestCase {

    func testFlag_shipsDark() {
        let flag = AppConstants.curbPinPlacementEnabled
        XCTAssertFalse(flag, "curbPinPlacementEnabled must ship dark until Kevin's Mac gate + daylight check (spec A.6/A.5).")
    }

    func testHintKey_isTheDocumentedUserDefaultsKey() {
        let key = AppConstants.curbPlacementHintShownKey
        XCTAssertEqual(key, "wepark_curb_placement_hint_shown")
    }
}

// MARK: - Entry routing (A.7) and the entry guard (A.3, A22) - flag-off byte-identity lives here

final class CurbPlacementRoutingTests: XCTestCase {

    func testFlagOff_everyEntry_isLegacy_inEveryModeCombination() {
        // Exhaustive: 3 entries x 2^4 mode states. Flag off is ALWAYS the pre-A3 branch.
        for entry in cpspAllEntries {
            for drive in [true, false] {
                for blockSelect in [true, false] {
                    for spot in [true, false] {
                        for placement in [true, false] {
                            let routing = cpspRoute(entry, flag: false, drive: drive, blockSelect: blockSelect, spot: spot, placement: placement)
                            XCTAssertEqual(routing, .legacy, "flag off must take the existing branch: \(entry)")
                        }
                    }
                }
            }
        }
    }

    func testFlagOn_idleResting_routesEveryEntryToPlacement() {
        for entry in cpspAllEntries {
            XCTAssertEqual(cpspRoute(entry, flag: true), .placement)
        }
    }

    func testFlagOn_longPressWhileAnotherModeIsActive_isIgnored_A22() {
        XCTAssertEqual(cpspRoute(.longPress, flag: true, drive: true), .ignore)
        XCTAssertEqual(cpspRoute(.longPress, flag: true, blockSelect: true), .ignore)
        XCTAssertEqual(cpspRoute(.longPress, flag: true, spot: true), .ignore)
        XCTAssertEqual(cpspRoute(.longPress, flag: true, placement: true), .ignore)
    }

    func testFlagOn_pillAndPathB_fallBackToLegacyWhenBlocked() {
        for entry in [CurbPlacementEntry.reportPill, .pathB] {
            XCTAssertEqual(cpspRoute(entry, flag: true, drive: true), .legacy, "in-drive paths stay untouched (AC-A28)")
            XCTAssertEqual(cpspRoute(entry, flag: true, blockSelect: true), .legacy)
            XCTAssertEqual(cpspRoute(entry, flag: true, spot: true), .legacy)
            XCTAssertEqual(cpspRoute(entry, flag: true, placement: true), .legacy)
        }
    }

    func testEntryAllowed_truthTable() {
        for drive in [true, false] {
            for blockSelect in [true, false] {
                for spot in [true, false] {
                    for placement in [true, false] {
                        let allowed = CurbPlacementPolicy.entryAllowed(
                            driveModeActive: drive,
                            blockSelectModeActive: blockSelect,
                            spotPlacementActive: spot,
                            placementActive: placement
                        )
                        XCTAssertEqual(allowed, !drive && !blockSelect && !spot && !placement)
                    }
                }
            }
        }
    }

    func testEntryIntents_followTheA7Matrix() {
        XCTAssertEqual(CurbPlacementEntry.longPress.intent, .plant)
        XCTAssertEqual(CurbPlacementEntry.reportPill.intent, .report)
        XCTAssertEqual(CurbPlacementEntry.pathB.intent, .parkBlock)
    }

    func testPillEntryIsInstant_otherEntriesAnimate_A2Ruling() {
        XCTAssertFalse(CurbPlacementEntry.reportPill.animatesEntry)
        XCTAssertTrue(CurbPlacementEntry.longPress.animatesEntry)
        XCTAssertTrue(CurbPlacementEntry.pathB.animatesEntry)
    }

    func testCoordinateSourceTags() {
        XCTAssertEqual(CurbPlacementEntry.longPress.coordinateSource, "curb-snap placement (long-press)")
        XCTAssertEqual(CurbPlacementEntry.reportPill.coordinateSource, "curb-snap placement (report pill)")
        XCTAssertEqual(CurbPlacementEntry.pathB.coordinateSource, "curb-snap placement (block detail)")
    }

    func testNewSession_startsEmpty_andDerivesIntentFromEntry() {
        let seed = CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99)
        let session = CurbPlacementSession(entry: .pathB, seed: seed, incumbentBlockfaceKey: "K", showsHint: true)
        XCTAssertNil(session.outcome)
        XCTAssertNil(session.nearestCurb)
        XCTAssertFalse(session.oppositeSideLoaded)
        XCTAssertEqual(session.intent, .parkBlock)
        XCTAssertEqual(session.incumbentBlockfaceKey, "K")
        XCTAssertTrue(session.showsHint)
        XCTAssertTrue(session.animatedEntry)
        XCTAssertFalse(CurbPlacementSession(entry: .reportPill, seed: seed).animatedEntry)
    }
}

// MARK: - Chrome-visibility threading (AC-A21)

final class CurbPlacementChromeThreadingTests: XCTestCase {

    func testRecenterButtonStack_defaultParameterIsByteIdentical() {
        for drive in [true, false] {
            for blockSelect in [true, false] {
                let legacy = !drive && !blockSelect
                XCTAssertEqual(recenterButtonStackVisible(driveModeActive: drive, blockSelectModeActive: blockSelect), legacy)
                XCTAssertEqual(
                    recenterButtonStackVisible(driveModeActive: drive, blockSelectModeActive: blockSelect, curbPlacementActive: false),
                    legacy
                )
            }
        }
    }

    func testRecenterButtonStack_hidesDuringPlacement() {
        XCTAssertFalse(recenterButtonStackVisible(driveModeActive: false, blockSelectModeActive: false, curbPlacementActive: true))
    }

    func testCommunityMapChrome_defaultParameterIsByteIdentical_andHidesDuringPlacement() {
        for community in [true, false] {
            for drive in [true, false] {
                for blockSelect in [true, false] {
                    for spot in [true, false] {
                        for longPress in [true, false] {
                            let legacy = community && !drive && !blockSelect && !spot && !longPress
                            let defaulted = ContentView.communityMapChromeVisible(
                                communityEnabled: community,
                                driveModeActive: drive,
                                blockSelectModeActive: blockSelect,
                                spotPlacementActive: spot,
                                longPressParkConfirmActive: longPress
                            )
                            XCTAssertEqual(defaulted, legacy)
                            let placement = ContentView.communityMapChromeVisible(
                                communityEnabled: community,
                                driveModeActive: drive,
                                blockSelectModeActive: blockSelect,
                                spotPlacementActive: spot,
                                longPressParkConfirmActive: longPress,
                                curbPlacementActive: true
                            )
                            XCTAssertFalse(placement, "Report pill and '?' hide during placement.")
                        }
                    }
                }
            }
        }
    }

    func testGoalDock_defaultParameterIsByteIdentical_andHidesDuringPlacement() {
        for flag in [true, false] {
            for sheetNil in [true, false] {
                for drive in [true, false] {
                    for blockSelect in [true, false] {
                        for spot in [true, false] {
                            let legacy = flag && sheetNil && !drive && !blockSelect && !spot
                            XCTAssertEqual(
                                goalSelectorDockVisible(
                                    driveModeDefaultEnabled: flag, activeSheetIsNil: sheetNil,
                                    driveModeActive: drive, blockSelectModeActive: blockSelect,
                                    spotPlacementActive: spot
                                ),
                                legacy
                            )
                            XCTAssertFalse(
                                goalSelectorDockVisible(
                                    driveModeDefaultEnabled: flag, activeSheetIsNil: sheetNil,
                                    driveModeActive: drive, blockSelectModeActive: blockSelect,
                                    spotPlacementActive: spot, curbPlacementActive: true
                                ),
                                "The DM-2 goal dock hides during placement."
                            )
                        }
                    }
                }
            }
        }
    }

    func testGoalTileRow_defaultParameterIsByteIdentical_andHidesDuringPlacement() {
        for fullPalette in [true, false] {
            let legacy = !fullPalette
            XCTAssertEqual(
                goalTileRowVisible(
                    driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: fullPalette,
                    driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
                ),
                legacy
            )
            XCTAssertFalse(
                goalTileRowVisible(
                    driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: fullPalette,
                    driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false,
                    curbPlacementActive: true
                )
            )
        }
    }

    func testSheetDismissCatchAll_flagOffClause_isExactlyThePreA3Conjunction() {
        for browse in [true, false] {
            for sheetNil in [true, false] {
                for drive in [true, false] {
                    for blockSelect in [true, false] {
                        for spot in [true, false] {
                            let legacy = browse && sheetNil && !drive && !blockSelect && !spot
                            let actual = CurbPlacementPolicy.sheetDismissRestoresRestState(
                                browseSheetEnabled: browse,
                                activeSheetIsNil: sheetNil,
                                driveModeActive: drive,
                                blockSelectModeActive: blockSelect,
                                spotPlacementActive: spot,
                                placementActive: false
                            )
                            XCTAssertEqual(actual, legacy)
                        }
                    }
                }
            }
        }
    }

    func testSheetDismissCatchAll_neverRepresentsASheetMidMode() {
        let actual = CurbPlacementPolicy.sheetDismissRestoresRestState(
            browseSheetEnabled: true,
            activeSheetIsNil: true,
            driveModeActive: false,
            blockSelectModeActive: false,
            spotPlacementActive: false,
            placementActive: true
        )
        XCTAssertFalse(actual, "AC-A21: the onDismiss catch-all never re-presents a sheet mid-mode.")
    }

    func testSheetConflicts_onlyWhenBothAreTrue() {
        XCTAssertTrue(CurbPlacementPolicy.sheetConflicts(placementActive: true, activeSheetPresent: true))
        XCTAssertFalse(CurbPlacementPolicy.sheetConflicts(placementActive: true, activeSheetPresent: false))
        XCTAssertFalse(CurbPlacementPolicy.sheetConflicts(placementActive: false, activeSheetPresent: true))
        XCTAssertFalse(CurbPlacementPolicy.sheetConflicts(placementActive: false, activeSheetPresent: false))
    }
}

// MARK: - Camera-mover deferral (PR #140 QA #2, P2-1 (a)+(b)) and exit bookkeeping (P2-1 (c))

final class CurbPlacementDeferralTests: XCTestCase {

    func testNoSession_consumesExactlyWhatIsPending_andAllowsAmbientLook() {
        for requested in [true, false] {
            for atLaunch in [true, false] {
                let plan = CurbPlacementPolicy.recenterPlan(requestedPending: requested, atLaunchPending: atLaunch, placementActive: false)
                XCTAssertEqual(plan.consumeRequested, requested, "flag-off: byte-identical consumption")
                XCTAssertEqual(plan.consumeAtLaunch, atLaunch)
                XCTAssertTrue(plan.allowAmbientLook)
            }
        }
    }

    func testLiveSession_consumesNothing_soTheRecenterIsDeferredNotDropped() {
        for requested in [true, false] {
            for atLaunch in [true, false] {
                let plan = CurbPlacementPolicy.recenterPlan(requestedPending: requested, atLaunchPending: atLaunch, placementActive: true)
                XCTAssertFalse(plan.consumeRequested, "(b): the pending flag must stay set")
                XCTAssertFalse(plan.consumeAtLaunch, "(b): the pending flag must stay set")
                XCTAssertFalse(plan.allowAmbientLook, "(a): no ambient auto-tighten hijacking the placement camera")
            }
        }
    }

    func testDeferredFlagIsConsumedOnceTheSessionEnds() {
        // Simulates handleLocationUpdate's flag handling across a session: fix 1 mid-session,
        // fix 2 after exit. The flag must survive fix 1 and be consumed by fix 2.
        var requested = true
        let during = CurbPlacementPolicy.recenterPlan(requestedPending: requested, atLaunchPending: false, placementActive: true)
        if requested && during.consumeRequested { requested = false }
        XCTAssertTrue(requested, "still pending after a fix that arrived mid-session")

        let after = CurbPlacementPolicy.recenterPlan(requestedPending: requested, atLaunchPending: false, placementActive: false)
        if requested && after.consumeRequested { requested = false }
        XCTAssertFalse(requested, "consumed by the first fix after the session ended")
    }

    func testRequeueOnExit_onlyWhenSomethingWasDeferred() {
        XCTAssertTrue(CurbPlacementPolicy.shouldRequeueRecenterOnExit(requestedPending: true, atLaunchPending: false))
        XCTAssertTrue(CurbPlacementPolicy.shouldRequeueRecenterOnExit(requestedPending: false, atLaunchPending: true))
        XCTAssertFalse(CurbPlacementPolicy.shouldRequeueRecenterOnExit(requestedPending: false, atLaunchPending: false))
    }

    func testAmbientBookkeeping_cancelLeavesTheFlagUntouched() {
        for adjusted in [true, false] {
            for inEffect in [true, false] {
                XCTAssertEqual(
                    CurbPlacementPolicy.ambientUserAdjustedAfterExit(restored: true, ambientLookInEffect: inEffect, currentUserAdjusted: adjusted),
                    adjusted,
                    "Cancel restores the exact pre-session camera - nothing to reset."
                )
            }
        }
    }

    func testAmbientBookkeeping_commitMarksUserAdjusted_onlyWhenAmbientLookIsInEffect() {
        XCTAssertTrue(CurbPlacementPolicy.ambientUserAdjustedAfterExit(restored: false, ambientLookInEffect: true, currentUserAdjusted: false))
        XCTAssertTrue(CurbPlacementPolicy.ambientUserAdjustedAfterExit(restored: false, ambientLookInEffect: true, currentUserAdjusted: true))
        XCTAssertFalse(
            CurbPlacementPolicy.ambientUserAdjustedAfterExit(restored: false, ambientLookInEffect: false, currentUserAdjusted: false),
            "flag-off ambient look: bookkeeping untouched"
        )
    }
}

// MARK: - Teardown / heal (QA #4, (d)) and the isPlacementActive seam

final class CurbPlacementTeardownTests: XCTestCase {

    func testHealAction_tableCoversEveryCombination() {
        XCTAssertEqual(CurbPlacementPolicy.healAction(sessionPresent: false, mapLayerActive: false), .none)
        XCTAssertEqual(CurbPlacementPolicy.healAction(sessionPresent: true, mapLayerActive: true), .none)
        XCTAssertEqual(CurbPlacementPolicy.healAction(sessionPresent: false, mapLayerActive: true), .endMapLayer)
        XCTAssertEqual(CurbPlacementPolicy.healAction(sessionPresent: true, mapLayerActive: false), .dropSession)
    }

    func testFreshCoordinatorActions_reportInactive_andPlacementCallsAreInert() {
        let actions = MapViewRepresentable.CoordinatorActions()
        XCTAssertFalse(actions.isPlacementActive, "flag-off / pre-makeUIView: no session ever exists")
        actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99))
        actions.endPlacement(restore: true)
        actions.refreshPlacement()
        actions.cyclePlacementCurb()
        actions.setPlacementBottomInset(300)
        actions.focusPlacement(on: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99))
        XCTAssertFalse(actions.isPlacementActive)
    }

    func testEveryExitFunnelEndsTheMapLayer_viaTheSeamContract() {
        // The contract ContentView's single exit funnel (`endCurbPlacement`) relies on: after
        // `endPlacement`, `isPlacementActive` is false - for every exit reason (Cancel, commit,
        // report handoff, Drive entry, abort, conflicting sheet, heal). Modelled with fake seam
        // closures; the ContentView wiring itself is covered by the live smoke.
        for restore in [true, false] {
            var live = false
            let actions = MapViewRepresentable.CoordinatorActions()
            actions.onQueryPlacementActive = { live }
            actions.onBeginPlacement = { _, _, _ in live = true }
            actions.onEndPlacement = { _ in live = false }

            actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99))
            XCTAssertTrue(actions.isPlacementActive)
            actions.endPlacement(restore: restore)
            XCTAssertFalse(actions.isPlacementActive, "taps must work after every exit path")
        }
    }

    func testBeginWhileLive_isAReplacement_andOneEndStillClearsIt() {
        var live = false
        var beginCount = 0
        let actions = MapViewRepresentable.CoordinatorActions()
        actions.onQueryPlacementActive = { live }
        actions.onBeginPlacement = { _, _, _ in
            live = true
            beginCount += 1
        }
        actions.onEndPlacement = { _ in live = false }
        actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99))
        actions.beginPlacement(seed: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.98))
        XCTAssertEqual(beginCount, 2)
        actions.endPlacement(restore: true)
        XCTAssertFalse(actions.isPlacementActive)
    }
}

// MARK: - Handoffs (spec A.6 table; AC-A15/A16)

final class CurbPlacementHandoffTests: XCTestCase {

    private let fallback = CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0)

    func testParkTarget_snapped_usesTheSnappedCoordinateWinnerAndDistance() {
        let outcome = cpspSnappedOutcome(distance: 7.5)
        let target = CurbPlacementPolicy.parkTarget(outcome: outcome, fallbackPin: fallback)
        let expected = CurbSnapTestFixtures.coordinate(x: 2, y: 0)
        XCTAssertEqual(target.latitude, expected.latitude, accuracy: 1e-9)
        XCTAssertEqual(target.longitude, expected.longitude, accuracy: 1e-9)
        XCTAssertEqual(target.segment?.id, "CPSP_SEG")
        XCTAssertEqual(target.distanceMeters, 7.5)
    }

    func testParkTarget_noCurb_usesThePinWithNoSegment() {
        let target = CurbPlacementPolicy.parkTarget(outcome: .noCurbInRange(nearestMeters: 60), fallbackPin: fallback)
        XCTAssertEqual(target.latitude, 40.7)
        XCTAssertEqual(target.longitude, -74.0)
        XCTAssertNil(target.segment)
        XCTAssertNil(target.distanceMeters)
    }

    func testParkTarget_noOutcomeYet_fallsBackToThePin() {
        let target = CurbPlacementPolicy.parkTarget(outcome: nil, fallbackPin: fallback)
        XCTAssertEqual(target.latitude, 40.7)
        XCTAssertNil(target.segment)
    }

    func testReportTarget_snapped_fixesTheCoordinateAndSegmentBeforeTheSheetExists() {
        let target = CurbPlacementPolicy.reportTarget(outcome: cpspSnappedOutcome(), entry: .reportPill, fallbackPin: fallback)
        let expected = CurbSnapTestFixtures.coordinate(x: 2, y: 0)
        XCTAssertEqual(target.coordinate.latitude, expected.latitude, accuracy: 1e-9)
        XCTAssertEqual(target.segment?.id, "CPSP_SEG")
        XCTAssertEqual(target.coordinateSource, "curb-snap placement (report pill)")
    }

    func testReportTarget_noCurb_degradesToSegmentNil() {
        let target = CurbPlacementPolicy.reportTarget(outcome: .noCurbInRange(nearestMeters: nil), entry: .longPress, fallbackPin: fallback)
        XCTAssertNil(target.segment, "existing OD-1 graceful degradation")
        XCTAssertEqual(target.coordinate.latitude, 40.7)
        XCTAssertEqual(target.coordinateSource, "curb-snap placement (long-press)")
    }

    func testReportTarget_showsParkTile_onlyForThePillEntry() {
        XCTAssertTrue(CurbPlacementPolicy.reportTarget(outcome: nil, entry: .reportPill, fallbackPin: fallback).showsParkMyCarTile)
        XCTAssertFalse(CurbPlacementPolicy.reportTarget(outcome: nil, entry: .longPress, fallbackPin: fallback).showsParkMyCarTile)
        XCTAssertFalse(CurbPlacementPolicy.reportTarget(outcome: nil, entry: .pathB, fallbackPin: fallback).showsParkMyCarTile)
    }

    func testParkHandoff_buildsTheExistingPinDropIntentShape() {
        // The ContentView handoff builds exactly this (alternatives empty, reminders ON).
        let target = CurbPlacementPolicy.parkTarget(outcome: cpspSnappedOutcome(distance: 4), fallbackPin: fallback)
        let intent = PinDropIntent(
            pinLat: target.latitude,
            pinLng: target.longitude,
            detectedSegment: target.segment,
            detectedSegmentDistance: target.distanceMeters,
            alternativeCandidates: []
        )
        let result = PinConfirmResult(intent: intent, notifyOnRestriction: true)
        XCTAssertEqual(result.intent.detectedSegment?.id, "CPSP_SEG")
        XCTAssertEqual(result.intent.detectedSegmentDistance, 4)
        XCTAssertTrue(result.intent.alternativeCandidates.isEmpty)
        XCTAssertTrue(result.notifyOnRestriction)
    }
}

// MARK: - Pin estimate, bearing, nearest-curb helpers

final class CurbPlacementGeometryHelperTests: XCTestCase {

    func testEstimatedPin_isTenPercentOfTheVisibleHeightNorthOfCentre() {
        let center = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let pin = CurbPlacementPolicy.estimatedPinCoordinate(regionCenter: center, regionLatitudeDelta: 0.004, tipHeightFraction: 0.40)
        XCTAssertEqual(pin.latitude, 40.75 + 0.1 * 0.004, accuracy: 1e-9)
        XCTAssertEqual(pin.longitude, -73.99, accuracy: 1e-12)
    }

    func testEstimatedPin_invalidSpanFallsBackToTheCentre() {
        let center = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        for delta in [0.0, -1.0, Double.nan, Double.infinity] {
            let pin = CurbPlacementPolicy.estimatedPinCoordinate(regionCenter: center, regionLatitudeDelta: delta, tipHeightFraction: 0.40)
            XCTAssertEqual(pin.latitude, 40.75)
            XCTAssertEqual(pin.longitude, -73.99)
        }
    }

    func testBearing_cardinalDirections() {
        let origin = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let north = CLLocationCoordinate2D(latitude: 40.751, longitude: -73.99)
        let east = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.989)
        let south = CLLocationCoordinate2D(latitude: 40.749, longitude: -73.99)
        let west = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.991)
        XCTAssertEqual(CurbPlacementPolicy.bearingDegrees(from: origin, to: north), 0, accuracy: 0.5)
        XCTAssertEqual(CurbPlacementPolicy.bearingDegrees(from: origin, to: east), 90, accuracy: 0.5)
        XCTAssertEqual(CurbPlacementPolicy.bearingDegrees(from: origin, to: south), 180, accuracy: 0.5)
        XCTAssertEqual(CurbPlacementPolicy.bearingDegrees(from: origin, to: west), 270, accuracy: 0.5)
    }

    func testNearestCurb_fromWideProbe_snappedAndNone() {
        let pin = CurbSnapTestFixtures.coordinate(x: 0, y: 30)
        let index = CurbSnapIndex(segments: [
            CurbSnapTestFixtures.eastWestCurb(id: "CPSP_FAR", side: "S", y: 0),
        ])
        let probe = index.resolve(
            pin,
            incumbent: nil,
            metersPerPoint: 0.28,
            config: CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)
        )
        let hint = CurbPlacementPolicy.nearestCurb(from: pin, probe: probe)
        XCTAssertNotNil(hint)
        XCTAssertEqual(hint?.distanceMeters ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(hint?.bearingDegrees ?? -1, 180, accuracy: 1.0, "the curb is due south of the pin")

        XCTAssertNil(CurbPlacementPolicy.nearestCurb(from: pin, probe: .noCurbInRange(nearestMeters: nil)))
    }

    func testNearestCurb_nothingWithin100m_isNil() {
        let pin = CurbSnapTestFixtures.coordinate(x: 0, y: 200)
        let index = CurbSnapIndex(segments: [CurbSnapTestFixtures.eastWestCurb(id: "CPSP_VERYFAR", side: "S", y: 0)])
        let probe = index.resolve(
            pin,
            incumbent: nil,
            metersPerPoint: 0.28,
            config: CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)
        )
        XCTAssertNil(CurbPlacementPolicy.nearestCurb(from: pin, probe: probe))
    }
}

// MARK: - First-use hint gate (BackgroundNoteGate convention)

final class CurbPlacementHintGateTests: XCTestCase {

    private func ephemeralDefaults() -> UserDefaults {
        let name = "CurbPlacementHintGateTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? UserDefaults.standard
    }

    func testShowsUntilMarked_thenNever() {
        let defaults = ephemeralDefaults()
        let gate = CurbPlacementHintGate(defaults: defaults, key: "cpsp_test_hint")
        XCTAssertTrue(gate.shouldShow())
        gate.markShown()
        XCTAssertFalse(gate.shouldShow())
        XCTAssertFalse(CurbPlacementHintGate(defaults: defaults, key: "cpsp_test_hint").shouldShow(), "persists across instances")
    }
}

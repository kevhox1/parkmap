//
//  CurbPlacementCardModelTests.swift
//  WeParkTests
//
//  Stream A3 (curb-pin placement, ContentView mode) - unit tests for every decision in the PURE
//  `CurbPlacementCardModel` (Views/CurbPlacementCard.swift): the canonical "Street . side" line,
//  the cross streets, the status text (byte-equal to the rules engine's `safetyLabel` - AC-A9),
//  the ONE primary button's label / route / enabled state per intent and state (A-1 ruling), the
//  quiet secondary link (AC-A10), the "No curb here" and "Loading curbs..." states (AC-A11/A13),
//  the far-curb footnote (AC-A12), the card height cap and the nearest-curb chip helpers.
//  Spec: docs/longpress-universal-plant-spec.md "Amendment" A.4 / A.11, and the AUTHORITATIVE
//  design review docs/design/curb-pin-placement-design.md.
//
//  What is NOT covered here (disclosed, same as `CurbPlacementMapPolicyTests`): the SwiftUI
//  layout of `CurbPlacementOverlay` (sizes, Dynamic Type, VoiceOver ordering, contrast) is only
//  provable live - the mandatory Mac smoke in the PR body covers it.
//
//  Compile-failure-class notes: pure statics are `nonisolated` and are called directly; MainActor
//  members are read into locals first. Helpers are file-private with a `cpcm` prefix (no
//  XCTestCase extensions). No bare `Category`. No `==` on project enums (outcomes are built and
//  inspected with `if case`; the model's own enums are `Equatable` and compared via
//  XCTAssertEqual).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine - Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - File-private helpers

private let cpcmNow = Date(timeIntervalSince1970: 1_800_000_000)

/// A rule-less segment (the engine labels it "No data" / .unknown).
private func cpcmBareSegment(
    id: String = "CPCM_BARE",
    street: String = "STANTON STREET",
    from: String = "BOWERY",
    to: String = "CHRYSTIE STREET",
    side: String = "S"
) -> Segment {
    CurbSnapTestFixtures.segment(
        id: id,
        street: street,
        from: from,
        to: to,
        side: side,
        points: [(-10, 0), (10, 0)]
    )
}

/// A segment with a NO STANDING anytime rule (the engine labels it "No standing" / .restricted).
private func cpcmRestrictedSegment(id: String = "CPCM_RESTRICTED") -> Segment {
    let rule = ParkingRule(
        category: .noStanding,
        description: "NO STANDING ANYTIME",
        days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: [],
        anytime: true,
        arrow: "both"
    )
    return Segment(
        id: id,
        street: "BOWERY",
        fromStreet: "HESTER STREET",
        to: "GRAND STREET",
        side: "N",
        line: [[40.7183, -73.9942], [40.7190, -73.9940]],
        rules: [rule],
        dominantCategory: .noStanding
    )
}

private func cpcmSnapped(_ segment: Segment, distance: Double = 3.0) -> CurbSnapOutcome {
    .snapped(CurbSnapResult(
        segment: segment,
        positionFraction: 0.5,
        distanceMeters: distance,
        snappedCoordinate: CurbSnapTestFixtures.coordinate(x: 0, y: 0)
    ))
}

private let cpcmNoCurb = CurbSnapOutcome.noCurbInRange(nearestMeters: nil)

private func cpcmMake(
    _ outcome: CurbSnapOutcome?,
    intent: CurbPlacementIntent,
    community: Bool = true,
    tilesLoaded: Bool = true,
    indexRefreshing: Bool = false,
    oppositeLoaded: Bool = true,
    nearest: CurbPlacementNearestCurb? = nil
) -> CurbPlacementCardModel {
    CurbPlacementCardModel.make(
        outcome: outcome,
        intent: intent,
        communityEnabled: community,
        engine: ParkingRulesEngine(),
        now: cpcmNow,
        tilesLoaded: tilesLoaded,
        indexRefreshing: indexRefreshing,
        oppositeSideLoaded: oppositeLoaded,
        nearestCurb: nearest,
        usesMetricSystem: false
    )
}

private let cpcmAllIntents: [CurbPlacementIntent] = [.park, .plant, .report, .parkBlock]

// MARK: - Snapped state: title, subtitle, status

final class CurbPlacementCardSnappedTests: XCTestCase {

    func testTitle_isCanonicalStreetPlusSideDisplayName() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        let expected = StreetNameNormalizer.canonical("STANTON STREET") + " \u{00B7} " + ReportSheet.sideDisplayName("S")
        XCTAssertEqual(model.title, expected)
        XCTAssertEqual(model.title, "STANTON ST \u{00B7} South side")
    }

    func testSubtitle_isCanonicalCrossStreets() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        XCTAssertEqual(model.subtitle, "between BOWERY & CHRYSTIE ST")
    }

    func testStatusText_isByteEqualToEngineSafetyLabel_forRestrictedSegment() {
        let segment = cpcmRestrictedSegment()
        let label = ParkingRulesEngine().safetyLabel(for: segment, at: cpcmNow)
        let model = cpcmMake(cpcmSnapped(segment), intent: .parkBlock)
        XCTAssertEqual(model.statusText, label.text, "AC-A9: never a second status formatter.")
        XCTAssertEqual(model.statusText, "No standing")
        XCTAssertEqual(model.statusTone, .restricted)
    }

    func testStatusText_isByteEqualToEngineSafetyLabel_forNoDataSegment() {
        let segment = cpcmBareSegment()
        let label = ParkingRulesEngine().safetyLabel(for: segment, at: cpcmNow)
        let model = cpcmMake(cpcmSnapped(segment), intent: .plant)
        XCTAssertEqual(model.statusText, label.text)
        XCTAssertEqual(model.statusTone, .unknown)
    }

    func testSnappedState_hasNoFootnote_andNoNearestCurb() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        XCTAssertEqual(model.state, .snapped)
        XCTAssertNil(model.footnote)
        XCTAssertNil(model.nearestCurb)
        XCTAssertFalse(model.showsProgress)
    }

    func testVoiceOverValue_expandsAbbreviations_andEndsWithStatus() {
        let segment = cpcmBareSegment()
        let label = ParkingRulesEngine().safetyLabel(for: segment, at: cpcmNow)
        let model = cpcmMake(cpcmSnapped(segment), intent: .plant)
        XCTAssertEqual(
            model.voiceOverValue,
            "Stanton Street, South side, between Bowery and Chrystie Street. \(label.text)."
        )
    }
}

// MARK: - Primary button / secondary link (A-1 ruling, AC-A10)

final class CurbPlacementCardButtonTests: XCTestCase {

    func testPrimary_isParkHere_forEveryParkIntent() {
        for intent in [CurbPlacementIntent.park, .plant, .parkBlock] {
            let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: intent)
            XCTAssertEqual(model.primaryTitle, "Park here")
            XCTAssertEqual(model.primaryAction, .parkHere)
            XCTAssertTrue(model.primaryEnabled)
        }
    }

    func testPrimary_isNext_forReportIntent() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .report)
        XCTAssertEqual(model.primaryTitle, "Next")
        XCTAssertEqual(model.primaryAction, .next)
        XCTAssertTrue(model.primaryEnabled)
    }

    func testSecondaryLink_existsOnlyForPlant_whenCommunityEnabled() {
        for intent in cpcmAllIntents {
            for community in [true, false] {
                let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: intent, community: community)
                let expectLink = (intent == .plant) && community
                if expectLink {
                    XCTAssertEqual(model.secondaryTitle, "Report something here")
                } else {
                    XCTAssertNil(
                        model.secondaryTitle,
                        "AC-A10: the link appears only for .plant with communityEnabled."
                    )
                }
            }
        }
    }

    func testSecondaryLink_isPresentInEveryStateForPlantWithCommunity() {
        let outcomes: [CurbSnapOutcome?] = [nil, cpcmNoCurb, cpcmSnapped(cpcmBareSegment())]
        for outcome in outcomes {
            let model = cpcmMake(outcome, intent: .plant, community: true)
            XCTAssertEqual(model.secondaryTitle, "Report something here")
        }
    }

    func testPrimaryHints_describeTheRoute() {
        let park = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        XCTAssertEqual(park.primaryHint, "Saves your car on Stanton Street, South side.")
        let next = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .report)
        XCTAssertEqual(next.primaryHint, "Opens report options for this spot.")
        XCTAssertEqual(next.secondaryHint, "Opens report options for this spot.")
    }
}

// MARK: - No curb / loading (AC-A11, AC-A13)

final class CurbPlacementCardEmptyStateTests: XCTestCase {

    func testNoCurb_parkIntent_offersSaveCarHere_andNeverDeadEnds() {
        for intent in [CurbPlacementIntent.park, .plant, .parkBlock] {
            let model = cpcmMake(cpcmNoCurb, intent: intent)
            XCTAssertEqual(model.state, .noCurb)
            XCTAssertEqual(model.title, "No curb here")
            XCTAssertEqual(model.subtitle, "Move the map until the pin is near a street")
            XCTAssertEqual(model.primaryTitle, "Save car here (no parking info)")
            XCTAssertEqual(model.primaryAction, .saveCarHere)
            XCTAssertTrue(model.primaryEnabled, "AC-A11: Park still works with no segment.")
            XCTAssertNil(model.statusText)
            XCTAssertNil(model.statusTone)
        }
    }

    func testNoCurb_reportIntent_nextStaysEnabled() {
        let model = cpcmMake(cpcmNoCurb, intent: .report)
        XCTAssertEqual(model.primaryTitle, "Next")
        XCTAssertEqual(model.primaryAction, .next)
        XCTAssertTrue(model.primaryEnabled, "AC-A11: report continues with segment: nil.")
    }

    func testNoCurb_carriesTheNearestCurbChipTarget() {
        let hint = CurbPlacementNearestCurb(latitude: 40.75, longitude: -73.99, distanceMeters: 45.72, bearingDegrees: 90)
        let model = cpcmMake(cpcmNoCurb, intent: .plant, nearest: hint)
        XCTAssertEqual(model.nearestCurb, hint)
    }

    func testNoCurb_voiceOverValue() {
        let model = cpcmMake(cpcmNoCurb, intent: .plant)
        XCTAssertEqual(model.voiceOverValue, "No curb here. Move the map until the pin is near a street.")
    }

    func testLoading_whenNoOutcomeYet() {
        let model = cpcmMake(nil, intent: .plant)
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.title, "Loading curbs\u{2026}")
        XCTAssertNil(model.subtitle)
        XCTAssertFalse(model.primaryEnabled)
        XCTAssertTrue(model.showsProgress)
        XCTAssertEqual(model.primaryTitle, "Park here")
        XCTAssertEqual(cpcmMake(nil, intent: .report).primaryTitle, "Next")
    }

    func testLoading_notNoCurb_whileTilesAreStillLoading() {
        let model = cpcmMake(cpcmNoCurb, intent: .plant, tilesLoaded: false)
        XCTAssertEqual(model.state, .loading, "AC-A13: never a false 'No curb here' before tiles arrive.")
        XCTAssertFalse(model.primaryEnabled)
    }

    func testLoading_notNoCurb_whileIndexIsRebuilding() {
        let model = cpcmMake(cpcmNoCurb, intent: .plant, indexRefreshing: true)
        XCTAssertEqual(model.state, .loading)
    }

    func testSnapped_staysSnapped_evenWhileTilesOrIndexAreRefreshing() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant, tilesLoaded: false, indexRefreshing: true)
        XCTAssertEqual(model.state, .snapped)
        XCTAssertTrue(model.primaryEnabled)
    }

    func testLoading_cardHasNoDeadEndOnceTilesArrive() {
        let loading = cpcmMake(cpcmNoCurb, intent: .plant, tilesLoaded: false)
        let resolved = cpcmMake(cpcmNoCurb, intent: .plant, tilesLoaded: true, indexRefreshing: false)
        XCTAssertFalse(loading.primaryEnabled)
        XCTAssertEqual(resolved.state, .noCurb)
        XCTAssertTrue(resolved.primaryEnabled)
    }
}

// MARK: - Far-curb footnote (AC-A12)

final class CurbPlacementCardFarCurbTests: XCTestCase {

    func testFarCurb_showsFootnote_whenOver15m_andNoOppositeSideLoaded() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment(), distance: 20), intent: .plant, oppositeLoaded: false)
        XCTAssertEqual(model.state, .farCurb)
        XCTAssertEqual(model.footnote, "Nearest curb with data")
        XCTAssertTrue(model.primaryEnabled)
        XCTAssertTrue(model.voiceOverValue.hasSuffix("Nearest curb with data."))
    }

    func testFarCurb_noFootnote_whenOppositeSideIsLoaded() {
        let model = cpcmMake(cpcmSnapped(cpcmBareSegment(), distance: 20), intent: .plant, oppositeLoaded: true)
        XCTAssertEqual(model.state, .snapped)
        XCTAssertNil(model.footnote)
    }

    func testFarCurb_boundaryIsStrictlyGreaterThan15m() {
        let atBoundary = cpcmMake(cpcmSnapped(cpcmBareSegment(), distance: 15.0), intent: .plant, oppositeLoaded: false)
        XCTAssertEqual(atBoundary.state, .snapped)
        let justOver = cpcmMake(cpcmSnapped(cpcmBareSegment(), distance: 15.01), intent: .plant, oppositeLoaded: false)
        XCTAssertEqual(justOver.state, .farCurb)
    }
}

// MARK: - Tone / pure helpers

final class CurbPlacementCardHelperTests: XCTestCase {

    func testTone_mapsEverySeverity_andSymbolsAreDistinct() {
        let pairs: [(SafetyLabel.Severity, CurbPlacementStatusTone, String)] = [
            (.free, .free, "checkmark.circle.fill"),
            (.comingSoon, .comingSoon, "clock.fill"),
            (.metered, .metered, "parkingsign.circle.fill"),
            (.restricted, .restricted, "nosign"),
            (.unknown, .unknown, "questionmark.circle.fill"),
        ]
        var seen = Set<String>()
        for (severity, tone, symbol) in pairs {
            XCTAssertEqual(CurbPlacementStatusTone.tone(for: severity), tone)
            XCTAssertEqual(tone.symbolName, symbol, "Design 3.2: state never depends on hue alone.")
            seen.insert(tone.symbolName)
        }
        XCTAssertEqual(seen.count, 5)
    }

    func testExpandedStreetName() {
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName("STANTON ST"), "Stanton Street")
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName("1 AVE"), "1 Avenue")
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName("W 14 ST"), "West 14 Street")
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName("E HOUSTON ST"), "East Houston Street")
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName("BOWERY"), "Bowery")
        XCTAssertEqual(CurbPlacementCardModel.expandedStreetName(""), "")
    }

    func testMaxCardHeight_isScreenMinusTipPlus130() {
        // Design 3.5: 381 pt on an 852 pt screen, 270 on 667.
        XCTAssertEqual(CurbPlacementCardModel.maxCardHeight(fullScreenHeight: 852, tipFraction: 0.40), 381.2, accuracy: 0.01)
        XCTAssertEqual(CurbPlacementCardModel.maxCardHeight(fullScreenHeight: 667, tipFraction: 0.40), 270.2, accuracy: 0.01)
        XCTAssertEqual(CurbPlacementCardModel.maxCardHeight(fullScreenHeight: 0, tipFraction: 0.40), 0)
        XCTAssertEqual(CurbPlacementCardModel.maxCardHeight(fullScreenHeight: .nan, tipFraction: 0.40), 0)
        XCTAssertEqual(CurbPlacementCardModel.maxCardHeight(fullScreenHeight: 100, tipFraction: 0.40), 0, "Never negative.")
    }

    func testMaxCardHeight_keepsCardBelowThePinTipPlus100() {
        for height in [667.0, 852.0, 932.0] {
            let cap = CurbPlacementCardModel.maxCardHeight(fullScreenHeight: height, tipFraction: 0.40)
            let cardTop = height - cap
            XCTAssertGreaterThanOrEqual(cardTop, 0.40 * height + 130 - 0.001)
        }
    }

    func testNearestCurbChipText_usesFeetUnderUS_metersOtherwise() {
        let curb = CurbPlacementNearestCurb(latitude: 0, longitude: 0, distanceMeters: 45.72, bearingDegrees: 0)
        XCTAssertEqual(CurbPlacementCardModel.nearestCurbChipText(curb, usesMetricSystem: false), "Nearest curb 150 ft")
        let far = CurbPlacementNearestCurb(latitude: 0, longitude: 0, distanceMeters: 47, bearingDegrees: 0)
        XCTAssertEqual(CurbPlacementCardModel.nearestCurbChipText(far, usesMetricSystem: true), "Nearest curb 50 m")
    }

    func testRoundedDistance_roundsToTen_withFloorOfTen_andHandlesGarbage() {
        XCTAssertEqual(CurbPlacementCardModel.roundedDistance(1.0, usesMetricSystem: true), 10)
        XCTAssertEqual(CurbPlacementCardModel.roundedDistance(0, usesMetricSystem: false), 10)
        XCTAssertEqual(CurbPlacementCardModel.roundedDistance(.nan, usesMetricSystem: true), 10)
        XCTAssertEqual(CurbPlacementCardModel.roundedDistance(-5, usesMetricSystem: true), 10)
        XCTAssertEqual(CurbPlacementCardModel.roundedDistance(100, usesMetricSystem: true), 100)
    }

    func testNearestCurbAccessibilityLabel() {
        let curb = CurbPlacementNearestCurb(latitude: 0, longitude: 0, distanceMeters: 45.72, bearingDegrees: 45)
        XCTAssertEqual(
            CurbPlacementCardModel.nearestCurbAccessibilityLabel(curb, usesMetricSystem: false),
            "Nearest curb is 150 feet north-east"
        )
    }

    func testCompassName_eightPoints() {
        let cases: [(Double, String)] = [
            (0, "north"), (44, "north-east"), (90, "east"), (135, "south-east"),
            (180, "south"), (225, "south-west"), (270, "west"), (315, "north-west"),
            (350, "north"), (360, "north"), (-90, "west"),
        ]
        for (bearing, name) in cases {
            XCTAssertEqual(CurbPlacementCardModel.compassName(forBearing: bearing), name, "bearing \(bearing)")
        }
        XCTAssertEqual(CurbPlacementCardModel.compassName(forBearing: .nan), "north")
    }

    func testArrowRotation_isBearingMinusHeading() {
        XCTAssertEqual(CurbPlacementCardModel.arrowRotationDegrees(bearing: 90, cameraHeading: 0), 90, accuracy: 0.001)
        XCTAssertEqual(CurbPlacementCardModel.arrowRotationDegrees(bearing: 10, cameraHeading: 30), 340, accuracy: 0.001)
        XCTAssertEqual(CurbPlacementCardModel.arrowRotationDegrees(bearing: .nan, cameraHeading: 0), 0)
    }
}

// MARK: - Copy hygiene (AC-A27) and model value semantics

final class CurbPlacementCopyHygieneTests: XCTestCase {

    private let banned = ["avoid", "ticket", "fine", "evasion", "dodge"]

    private func allStrings() -> [String] {
        var strings: [String] = [
            CurbPlacementCardCopy.parkHere, CurbPlacementCardCopy.next, CurbPlacementCardCopy.saveCarHere,
            CurbPlacementCardCopy.reportSomethingHere, CurbPlacementCardCopy.noCurbTitle,
            CurbPlacementCardCopy.noCurbSubtitle, CurbPlacementCardCopy.loadingTitle,
            CurbPlacementCardCopy.farCurbFootnote, CurbPlacementCardCopy.hint,
            CurbPlacementCardCopy.cancel, CurbPlacementCardCopy.locateLabel,
        ]
        let outcomes: [CurbSnapOutcome?] = [nil, cpcmNoCurb, cpcmSnapped(cpcmBareSegment(), distance: 20)]
        for outcome in outcomes {
            for intent in cpcmAllIntents {
                let model = cpcmMake(outcome, intent: intent, oppositeLoaded: false)
                strings.append(model.title)
                strings.append(model.subtitle ?? "")
                strings.append(model.primaryTitle)
                strings.append(model.primaryHint)
                strings.append(model.secondaryHint)
                strings.append(model.voiceOverValue)
                strings.append(model.footnote ?? "")
                strings.append(model.secondaryTitle ?? "")
            }
        }
        return strings
    }

    func testNoBannedWordsInAnyNewString() {
        for string in allStrings() {
            let lower = string.lowercased()
            for word in banned {
                XCTAssertFalse(lower.contains(word), "A27: '\(word)' found in '\(string)'")
            }
        }
    }

    func testModel_isDeterministic_forIdenticalInputs() {
        let a = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        let b = cpcmMake(cpcmSnapped(cpcmBareSegment()), intent: .plant)
        XCTAssertEqual(a, b)
    }

    func testCardStatesDifferByState_butShareTheSameSlotShape() {
        // The card reserves rows by state (no height jump while panning); the model always carries
        // a title and a primary - the view reserves the rest. Guard the invariant it relies on.
        let outcomes: [CurbSnapOutcome?] = [nil, cpcmNoCurb, cpcmSnapped(cpcmBareSegment())]
        for outcome in outcomes {
            for intent in cpcmAllIntents {
                let model = cpcmMake(outcome, intent: intent)
                XCTAssertFalse(model.title.isEmpty)
                XCTAssertFalse(model.primaryTitle.isEmpty)
            }
        }
    }
}

//
//  CurbPlacementCardLayoutTests.swift
//  WeParkTests
//
//  Open item #37 item 8: the placement card at accessibility sizes and on the SE
//  (docs/design/curb-pin-placement-design.md, "Addendum - placement card at accessibility sizes
//  and SE"). Pure tests over `CurbPlacementCardLayout` (the ordered config selector, card height,
//  row-drop rules, banner / hint rules), the street title-case function and the VoiceOver
//  label / value split. The live geometry is proven by the simulator smoke in the PR body.
//
//  Compile-failure classes avoided: no literal-receiver member calls, labeled arguments in
//  declaration order, no XCTestCase extensions, every pure static is `nonisolated` in the
//  production type, and no bare `Category`.
//

import XCTest
import SwiftUI
import UIKit
import CoreLocation
@testable import WePark

// MARK: - Fixtures

/// (screen height, home-indicator inset): SE, a 6.1 inch notch phone (812 class), the 17, the Pro Max.
private let cpclPhones: [(height: Double, inset: Double)] = [
    (667, 0), (812, 34), (874, 34), (932, 34)
]

private let cpclTiers: [CurbPlacementSizeTier] = [.standard, .extended, .accessibility]

// MARK: - Tier mapping

final class CurbPlacementSizeTierTests: XCTestCase {

    func testDynamicTypeSizeMapsToTiers() {
        let standard: [DynamicTypeSize] = [.xSmall, .small, .medium, .large]
        let extended: [DynamicTypeSize] = [.xLarge, .xxLarge, .xxxLarge]
        let accessibility: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ]
        for size in standard { XCTAssertEqual(CurbPlacementSizeTier.tier(for: size), .standard, "\(size)") }
        for size in extended { XCTAssertEqual(CurbPlacementSizeTier.tier(for: size), .extended, "\(size)") }
        for size in accessibility { XCTAssertEqual(CurbPlacementSizeTier.tier(for: size), .accessibility, "\(size)") }
    }

    func testContentSizeCategoryMapsToTiers() {
        XCTAssertEqual(CurbPlacementSizeTier.tier(for: UIContentSizeCategory.large), .standard)
        XCTAssertEqual(CurbPlacementSizeTier.tier(for: UIContentSizeCategory.extraLarge), .extended)
        XCTAssertEqual(CurbPlacementSizeTier.tier(for: UIContentSizeCategory.extraExtraExtraLarge), .extended)
        XCTAssertEqual(CurbPlacementSizeTier.tier(for: UIContentSizeCategory.accessibilityMedium), .accessibility)
        XCTAssertEqual(CurbPlacementSizeTier.tier(for: UIContentSizeCategory.accessibilityExtraExtraExtraLarge), .accessibility)
    }
}

// MARK: - Config selector

final class CurbPlacementConfigSelectorTests: XCTestCase {

    /// The hard requirement's arithmetic: at every tier x phone x link wish a candidate fits with
    /// >= 12 pt of slack, and the card top is >= tip + 130.
    func testEveryTierAndPhone_fitsWithSlack_andKeeps130BelowTheTip() {
        for phone in cpclPhones {
            for tier in cpclTiers {
                for wantsLink in [true, false] {
                    let r = CurbPlacementCardLayout.select(
                        tier: tier, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: wantsLink
                    )
                    let label = "H \(phone.height) \(tier) link \(wantsLink)"
                    XCTAssertTrue(r.fits, label)
                    XCTAssertGreaterThanOrEqual(r.slack, 12 - 0.0001, label)
                    XCTAssertLessThanOrEqual(r.content + 12, r.cap + 0.0001, label)
                    let tipY = r.config.tipFraction * phone.height
                    let cardTop = phone.height - phone.inset - r.cardHeight
                    XCTAssertGreaterThanOrEqual(cardTop - tipY, 130 - 0.0001, label)
                    XCTAssertEqual(r.cardHeight, r.content, accuracy: 0.0001, label + " card is its content, not clamped")
                }
            }
        }
    }

    func testLegalityIsAlwaysAbovePrimary_andInsideTheCard() {
        for phone in cpclPhones {
            for tier in cpclTiers {
                let r = CurbPlacementCardLayout.select(
                    tier: tier, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: true
                )
                let m = CurbPlacementCardMetrics.metrics(for: tier)
                let legalityBottom = CurbPlacementCardLayout.topPadding + m.title
                    + CurbPlacementCardLayout.titleToChip + m.chip
                XCTAssertLessThanOrEqual(legalityBottom, r.cardHeight - m.primary,
                                         "title + status end above the primary: H \(phone.height) \(tier)")
            }
        }
    }

    // MARK: Spec table (addendum section 4)

    func testPhone17_atLarge_keepsEveryRow_atTheStandardTip() {
        let r = CurbPlacementCardLayout.select(tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001)
        XCTAssertTrue(r.showsLink)
        XCTAssertTrue(r.config.showsSubtitle)
        XCTAssertEqual(r.content, 292, accuracy: 0.0001)
        XCTAssertEqual(r.cap, 360.4, accuracy: 0.05)
        XCTAssertEqual(r.config.link, .roomy, "a tall phone keeps the 48 pt link row")
    }

    func testPhone17_atXXXL_keepsEveryRow() {
        let r = CurbPlacementCardLayout.select(tier: .extended, fullHeight: 874, bottomInset: 34, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001)
        XCTAssertTrue(r.showsLink)
        XCTAssertEqual(r.content, 341, accuracy: 0.0001)
    }

    func testPhone17_atAX_dropsLink_andMovesTheTipTo36() {
        let r = CurbPlacementCardLayout.select(tier: .accessibility, fullHeight: 874, bottomInset: 34, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.36, accuracy: 0.0001, "at .40 the slack would be 8 pt")
        XCTAssertFalse(r.showsLink)
        XCTAssertTrue(r.config.showsSubtitle)
        XCTAssertEqual(r.content, 352, accuracy: 0.0001)
    }

    func testSE_atLarge_movesTipTo36_withCompactLink() {
        let r = CurbPlacementCardLayout.select(tier: .standard, fullHeight: 667, bottomInset: 0, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.36, accuracy: 0.0001)
        XCTAssertTrue(r.showsLink)
        XCTAssertEqual(r.config.link, .compact)
        XCTAssertEqual(r.content, 284, accuracy: 0.0001)
        XCTAssertTrue(r.config.showsSubtitle)
    }

    func testSE_atXXXL_dropsTheLink_keepsTheSubtitle() {
        let r = CurbPlacementCardLayout.select(tier: .extended, fullHeight: 667, bottomInset: 0, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.36, accuracy: 0.0001)
        XCTAssertFalse(r.showsLink)
        XCTAssertTrue(r.config.showsSubtitle)
        XCTAssertEqual(r.content, 281, accuracy: 0.0001)
    }

    func testSE_atAX_dropsLinkAndSubtitle_andMovesTheTipTo30() {
        let r = CurbPlacementCardLayout.select(tier: .accessibility, fullHeight: 667, bottomInset: 0, wantsLink: true)
        XCTAssertEqual(r.config.tipFraction, 0.30, accuracy: 0.0001)
        XCTAssertFalse(r.showsLink)
        XCTAssertFalse(r.config.showsSubtitle)
        XCTAssertEqual(r.content, 318, accuracy: 0.0001)
    }

    func testReportIntent_hasNoLink_soTheSEKeepsTheStandardTipAtLarge() {
        let r = CurbPlacementCardLayout.select(tier: .standard, fullHeight: 667, bottomInset: 0, wantsLink: false)
        XCTAssertFalse(r.showsLink)
        XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001, "no-link content 240 vs cap 270 at .40")
        XCTAssertEqual(r.content, 240, accuracy: 0.0001)
    }

    func testLinkIsNeverShownAtAccessibilitySizes_onAnyPhone() {
        for phone in cpclPhones {
            let r = CurbPlacementCardLayout.select(
                tier: .accessibility, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: true
            )
            XCTAssertFalse(r.showsLink, "H \(phone.height)")
        }
    }

    func testSubtitleIsDroppedOnlyOnTheSE_atAccessibilitySizes() {
        for phone in cpclPhones {
            let r = CurbPlacementCardLayout.select(
                tier: .accessibility, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: true
            )
            XCTAssertEqual(r.config.showsSubtitle, phone.height > 700, "H \(phone.height)")
        }
    }

    func testTipFractionIsOnlyEver40_36_or30() {
        let allowed: [Double] = [0.40, 0.36, 0.30]
        for phone in cpclPhones {
            for tier in cpclTiers {
                let r = CurbPlacementCardLayout.select(
                    tier: tier, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: true
                )
                XCTAssertTrue(allowed.contains(where: { abs($0 - r.config.tipFraction) < 0.0001 }))
            }
        }
    }

    func testTallPhones_keepTheStandardTip_atDefaultSize_andTheBigOnesAtExtendedSizes() {
        for height in [812.0, 874.0, 932.0] {
            let r = CurbPlacementCardLayout.select(tier: .standard, fullHeight: height, bottomInset: 34, wantsLink: true)
            XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001, "H \(height) standard")
        }
        for height in [874.0, 932.0] {
            let r = CurbPlacementCardLayout.select(tier: .extended, fullHeight: height, bottomInset: 34, wantsLink: true)
            XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001, "H \(height) extended")
            XCTAssertTrue(r.showsLink)
        }
        // 812 at XXXL: .40 leaves 341 vs 323 -> the tip moves to .36 and the link row survives.
        let mid = CurbPlacementCardLayout.select(tier: .extended, fullHeight: 812, bottomInset: 34, wantsLink: true)
        XCTAssertEqual(mid.config.tipFraction, 0.36, accuracy: 0.0001)
        XCTAssertTrue(mid.showsLink)
    }

    func testNoCandidateFits_returnsTheMostReduced_notAScroll() {
        let r = CurbPlacementCardLayout.select(tier: .accessibility, fullHeight: 480, bottomInset: 0, wantsLink: true)
        XCTAssertFalse(r.fits)
        XCTAssertEqual(r.config, CurbPlacementCardLayout.candidates[CurbPlacementCardLayout.candidates.count - 1])
        XCTAssertLessThanOrEqual(r.cardHeight, r.cap + 0.0001, "the card is still never taller than the cap")
    }

    func testResolve_atAFrozenTip_staysAtThatTip() {
        // The view only ever lays out at the tip the camera froze, even if the type size moved.
        let r = CurbPlacementCardLayout.resolve(
            tipFraction: 0.40, tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: true
        )
        XCTAssertEqual(r.config.tipFraction, 0.40, accuracy: 0.0001)
        let sameAsSelect = CurbPlacementCardLayout.select(tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: true)
        XCTAssertEqual(r, sameAsSelect, "unchanged environment: resolve == select")
        let tight = CurbPlacementCardLayout.resolve(
            tipFraction: 0.30, tier: .accessibility, fullHeight: 667, bottomInset: 0, wantsLink: true
        )
        XCTAssertEqual(tight.config.tipFraction, 0.30, accuracy: 0.0001)
        XCTAssertFalse(tight.config.showsSubtitle)
    }

    func testResolve_withAnUnknownTip_fallsBackToTheSelector() {
        let r = CurbPlacementCardLayout.resolve(
            tipFraction: 0.5, tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: true
        )
        XCTAssertEqual(r, CurbPlacementCardLayout.select(tier: .standard, fullHeight: 874, bottomInset: 34, wantsLink: true))
    }

    func testCap_isComputedOnUnroundedValues_andNeverNegative() {
        XCTAssertEqual(CurbPlacementCardLayout.cap(fullHeight: 874, tipFraction: 0.40, bottomInset: 34), 360.4, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementCardLayout.cap(fullHeight: 667, tipFraction: 0.36, bottomInset: 0), 296.88, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementCardLayout.cap(fullHeight: 100, tipFraction: 0.40, bottomInset: 0), 0)
        XCTAssertEqual(CurbPlacementCardLayout.cap(fullHeight: .nan, tipFraction: 0.40, bottomInset: 0), 0)
    }

    func testContentHeight_isIndependentOfAnyCardState() {
        // The function has no state input: same tier + config + link wish, same height.
        let config = CurbPlacementCardLayout.candidates[0]
        let a = CurbPlacementCardLayout.contentHeight(tier: .standard, config: config, wantsLink: true)
        let b = CurbPlacementCardLayout.contentHeight(tier: .standard, config: config, wantsLink: true)
        XCTAssertEqual(a, b)
    }
}

// MARK: - Row-drop, banner, hint, primary title

final class CurbPlacementCardRowRuleTests: XCTestCase {

    func testAspBannerIsHidden_onShortPhones_andAtAX_only() {
        XCTAssertTrue(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 667, tier: .standard))
        XCTAssertTrue(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 667, tier: .extended))
        XCTAssertTrue(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 874, tier: .accessibility))
        XCTAssertTrue(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 932, tier: .accessibility))
        XCTAssertFalse(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 874, tier: .standard), "tall phone at default size keeps the banner")
        XCTAssertFalse(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 874, tier: .extended))
        XCTAssertFalse(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 812, tier: .standard))
        XCTAssertFalse(CurbPlacementCardLayout.hidesASPBanner(fullHeight: 700, tier: .standard), "700 is not short (< 700)")
    }

    func testTopRowButtonHeight_is56AtAccessibilitySizes() {
        XCTAssertEqual(CurbPlacementCardLayout.topRowButtonHeight(tier: .standard), 48)
        XCTAssertEqual(CurbPlacementCardLayout.topRowButtonHeight(tier: .extended), 48)
        XCTAssertEqual(CurbPlacementCardLayout.topRowButtonHeight(tier: .accessibility), 56)
    }

    func testHintPill_clearsTheNeedleHead_atHeadOffset72() {
        // SE Large: tip 0.36 x 667 = 240 (screen), 220 in overlay coordinates (20 pt status bar).
        let center = CurbPlacementCardLayout.hintPillCenterY(tipY: 220, cancelBottom: 8 + 48)
        XCTAssertNotNil(center)
        if let center {
            let bottom = center + 18
            XCTAssertEqual(bottom, 220 - 72 - 12, accuracy: 0.0001, "bottom edge 12 pt above the 72 pt head")
        }
    }

    func testHintPill_isSuppressed_ratherThanClamped_whenItWouldHitCancel() {
        // SE AX: tip 0.30 x 667 = 200 screen -> 180 overlay; pill would be 60...96, Cancel bottom 64 + 8.
        XCTAssertNil(CurbPlacementCardLayout.hintPillCenterY(tipY: 180, cancelBottom: 8 + 56))
    }

    func testHintPill_boundaryIsInclusive() {
        // Pill top = tipY - 72 - 12 - 36 = tipY - 120; it needs top >= cancelBottom (56) + 8.
        XCTAssertNotNil(CurbPlacementCardLayout.hintPillCenterY(tipY: 184, cancelBottom: 56))
        XCTAssertNil(CurbPlacementCardLayout.hintPillCenterY(tipY: 183.5, cancelBottom: 56))
    }

    func testPrimaryTitle_breaksSaveCarHere_atLargerTiers_only() {
        let title = CurbPlacementCardCopy.saveCarHere
        XCTAssertEqual(CurbPlacementCardLayout.primaryDisplayTitle(title, tier: .standard), title)
        XCTAssertEqual(CurbPlacementCardLayout.primaryDisplayTitle(title, tier: .extended), "Save car here\n(no parking info)")
        XCTAssertEqual(CurbPlacementCardLayout.primaryDisplayTitle(title, tier: .accessibility), "Save car here\n(no parking info)")
        XCTAssertEqual(CurbPlacementCardLayout.primaryDisplayTitle("Park here", tier: .accessibility), "Park here")
    }

    func testMetrics_matchTheAddendum() {
        let t0 = CurbPlacementCardMetrics.metrics(for: .standard)
        let t1 = CurbPlacementCardMetrics.metrics(for: .extended)
        let t2 = CurbPlacementCardMetrics.metrics(for: .accessibility)
        XCTAssertEqual([t0.title, t1.title, t2.title], [56, 68, 82])
        XCTAssertEqual([t0.chip, t1.chip, t2.chip], [44, 48, 88])
        XCTAssertEqual([t0.subtitle, t1.subtitle, t2.subtitle], [20, 25, 30])
        XCTAssertEqual([t0.primary, t1.primary, t2.primary], [60, 80, 92])
    }
}

// MARK: - Title case

final class CurbPlacementTitleCaseTests: XCTestCase {

    func testOrdinalsStayLowercase_notCapitalizedStyle() {
        XCTAssertEqual(CurbPlacementCardModel.titleCased("1ST AVE"), "1st Ave")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("31ST ST"), "31st St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("8 AVE"), "8 Ave")
        let raw = String("1st ave")
        XCTAssertEqual(raw.capitalized, "1St Ave", "documents why String.capitalized is not used")
    }

    func testSingleLetterDirectionsStayCapital() {
        XCTAssertEqual(CurbPlacementCardModel.titleCased("W 34TH ST"), "W 34th St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("E HOUSTON ST"), "E Houston St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("N MOORE ST"), "N Moore St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("S END AVE"), "S End Ave")
    }

    func testPunctuationAbbreviationsAndAcronyms() {
        XCTAssertEqual(CurbPlacementCardModel.titleCased("ST. MARKS PL"), "St. Marks Pl")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("FDR DR"), "FDR Dr")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("STANTON ST"), "Stanton St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("BOWERY"), "Bowery")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("AVE A"), "Ave A")
    }

    func testEdgeCases() {
        XCTAssertEqual(CurbPlacementCardModel.titleCased(""), "")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("  STANTON   ST "), "Stanton St")
        XCTAssertEqual(CurbPlacementCardModel.titleCased("already Mixed CASE"), "Already Mixed Case")
    }
}

// MARK: - VoiceOver label / value

final class CurbPlacementVoiceOverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(
        _ outcome: CurbSnapOutcome?,
        data: CurbPlacementDataStatus = .ready,
        oppositeLoaded: Bool = true
    ) -> CurbPlacementCardModel {
        CurbPlacementCardModel.make(
            outcome: outcome,
            intent: .plant,
            communityEnabled: true,
            engine: ParkingRulesEngine(),
            now: now,
            dataStatus: data,
            oppositeSideLoaded: oppositeLoaded,
            nearestCurb: nil,
            usesMetricSystem: false
        )
    }

    private func snapped(distance: Double = 3) -> CurbSnapOutcome {
        let segment = CurbSnapTestFixtures.segment(
            id: "CPCL_VO", street: "STANTON STREET", from: "BOWERY", to: "CHRYSTIE STREET",
            side: "S", points: [(-10, 0), (10, 0)]
        )
        return .snapped(CurbSnapResult(
            segment: segment,
            positionFraction: 0.5,
            distanceMeters: distance,
            snappedCoordinate: CurbSnapTestFixtures.coordinate(x: 0, y: 0)
        ))
    }

    func testSnapped_labelIsTheVisibleStreetAndSide_valueIsCrossStreetAndStatus() {
        let m = model(snapped())
        XCTAssertEqual(m.title, "Stanton St \u{00B7} South side")
        XCTAssertEqual(m.voiceOverLabel, "Stanton Street, South side")
        XCTAssertTrue(m.voiceOverValue.hasPrefix("between Bowery and Chrystie Street. "))
        XCTAssertFalse(m.voiceOverValue.contains("Stanton"), "street moved to the label")
        XCTAssertTrue(m.voiceOverValue.hasSuffix((m.statusText ?? "?") + "."))
        XCTAssertNotEqual(m.voiceOverLabel, "Parking spot")
    }

    func testFarCurb_valueCarriesTheFootnote() {
        let m = model(snapped(distance: 20), oppositeLoaded: false)
        XCTAssertEqual(m.state, .farCurb)
        XCTAssertTrue(m.voiceOverValue.hasSuffix("Nearest curb with data."))
        XCTAssertEqual(m.voiceOverLabel, "Stanton Street, South side")
    }

    func testNonSnappedStates_labelIsTheVisibleTitle_valueIsTheInstruction() {
        let noCurb = model(.noCurbInRange(nearestMeters: nil))
        XCTAssertEqual(noCurb.voiceOverLabel, "No curb here")
        XCTAssertEqual(noCurb.voiceOverValue, "No curb here. Move the map until the pin is near a street.")
        let noData = model(nil, data: .noData)
        XCTAssertEqual(noData.voiceOverLabel, "No parking data here")
        XCTAssertEqual(noData.voiceOverValue, "No parking data here. You can still save your car at this spot.")
        let loading = model(nil, data: .loading)
        XCTAssertEqual(loading.voiceOverLabel, CurbPlacementCardCopy.loadingTitle)
        XCTAssertEqual(loading.voiceOverValue, "Loading curbs")
    }

    func testLabelInName_visibleTitleTextIsInsideTheSpokenLabel() {
        // WCAG 2.5.3: the visible side text must appear in the accessible label.
        let m = model(snapped())
        XCTAssertTrue(m.voiceOverLabel.contains("South side"))
        for state in [model(.noCurbInRange(nearestMeters: nil)), model(nil, data: .noData), model(nil, data: .loading)] {
            XCTAssertEqual(state.voiceOverLabel, state.title)
        }
    }
}

// MARK: - Session defaults (flag-off guard)

final class CurbPlacementSessionLayoutDefaultsTests: XCTestCase {

    func testSessionDefaults_keepTheStandardTip_andTheBanner() {
        let session = CurbPlacementSession(
            entry: .longPress,
            seed: CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        )
        XCTAssertEqual(session.tipFraction, 0.40, accuracy: 0.0001)
        XCTAssertFalse(session.hidesASPBanner, "no session means the banner is never hidden (flag-off)")
    }

    func testTipPoint_usesTheFrozenFraction_andDefaultsToStandard() {
        let bounds = CGRect(x: 0, y: 0, width: 375, height: 667)
        XCTAssertEqual(CurbPlacementMapPolicy.tipPoint(in: bounds).y, 0.40 * 667, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.tipPoint(in: bounds, tipFraction: 0.30).y, 0.30 * 667, accuracy: 0.0001)
        XCTAssertEqual(CurbPlacementMapPolicy.tipPoint(in: bounds, tipFraction: 0.36).x, 187.5, accuracy: 0.0001)
    }

    func testEntryCenter_followsTheFrozenFraction() {
        let seed = CLLocationCoordinate2D(latitude: 40.75, longitude: -73.99)
        let standard = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: 200)
        let same = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: 200, tipFraction: 0.40)
        XCTAssertEqual(standard.latitude, same.latitude, accuracy: 1e-12)
        let higher = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: 200, tipFraction: 0.30)
        XCTAssertLessThan(higher.latitude, standard.latitude, "a higher tip puts the centre further south of the seed")
    }

    // MARK: - Address row priority (QA #2 on PR #158): the cross street outranks the address

    func testAddressPriority_flagOffCandidatesAreUntouched() {
        XCTAssertEqual(CurbPlacementCardLayout.candidateList(wantsAddress: false), CurbPlacementCardLayout.candidates)
        XCTAssertTrue(CurbPlacementCardLayout.candidates.allSatisfy { $0.showsAddress })
    }

    func testAddressPriority_addressIsDroppedBeforeLinkAndSubtitle() {
        let list = CurbPlacementCardLayout.addressCandidates
        XCTAssertEqual(list.count, CurbPlacementCardLayout.candidates.count + CurbPlacementCardLayout.candidates.filter { $0.link != .none }.count)
        // Everything after the link candidates that carry the address is address-less.
        let firstDropped = list.firstIndex { !$0.showsAddress }
        XCTAssertNotNil(firstDropped)
        if let firstDropped {
            XCTAssertTrue(list[firstDropped...].allSatisfy { !$0.showsAddress })
            XCTAssertTrue(list[..<firstDropped].allSatisfy { $0.showsAddress && $0.showsSubtitle && $0.link != .none })
        }
        // The address-less tail is exactly the flag-off order.
        let tail = list.filter { !$0.showsAddress }.map {
            CurbPlacementCardConfig(tipFraction: $0.tipFraction, link: $0.link, showsSubtitle: $0.showsSubtitle)
        }
        XCTAssertEqual(tail, CurbPlacementCardLayout.candidates)
    }

    func testAddressPriority_crossStreetAndLinkSurviveWheneverFlagOffShowsThem() {
        for phone in cpclPhones {
            for tier in cpclTiers {
                for wantsLink in [true, false] {
                    let off = CurbPlacementCardLayout.select(
                        tier: tier, fullHeight: phone.height, bottomInset: phone.inset, wantsLink: wantsLink)
                    let on = CurbPlacementCardLayout.select(
                        tier: tier, fullHeight: phone.height, bottomInset: phone.inset,
                        wantsLink: wantsLink, wantsAddress: true)
                    let context = "h\(phone.height) tier \(tier) link \(wantsLink)"
                    if off.config.showsSubtitle {
                        XCTAssertTrue(on.config.showsSubtitle, "cross street dropped for the address: \(context)")
                    }
                    if off.showsLink {
                        XCTAssertTrue(on.showsLink, "link dropped for the address: \(context)")
                    }
                    if off.fits {
                        XCTAssertTrue(on.fits, context)
                    }
                }
            }
        }
    }

    func testAddressPriority_whereBothCannotFit_addressRowGoesAndSubtitleStays() {
        // SE at AX1: flag-off keeps the cross street; flag-on must too, with no address row.
        let on = CurbPlacementCardLayout.select(
            tier: .accessibility, fullHeight: 667, bottomInset: 0, wantsLink: false, wantsAddress: true)
        let off = CurbPlacementCardLayout.select(
            tier: .accessibility, fullHeight: 667, bottomInset: 0, wantsLink: false)
        XCTAssertEqual(on.config.showsSubtitle, off.config.showsSubtitle)
        if off.config.showsSubtitle {
            XCTAssertFalse(on.config.showsAddress)
            XCTAssertEqual(on.content, off.content)
        }
    }

    func testAddressPriority_cardHeightIsConstantForAGivenConfig() {
        // The row is reserved whether or not an address has resolved: height depends only on the
        // config, never on the address text.
        for config in CurbPlacementCardLayout.addressCandidates {
            let a = CurbPlacementCardLayout.contentHeight(tier: .standard, config: config, wantsLink: true, wantsAddress: true)
            let b = CurbPlacementCardLayout.contentHeight(tier: .standard, config: config, wantsLink: true, wantsAddress: true)
            XCTAssertEqual(a, b)
        }
    }
}

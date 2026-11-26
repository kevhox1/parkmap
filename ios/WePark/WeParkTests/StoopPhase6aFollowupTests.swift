//
//  StoopPhase6aFollowupTests.swift
//  WeParkTests
//
//  Follow-ups to PR #212 (QA doc `docs/qa/pr212-stoop-phase6a-qa.md`): coach mark 3 copy follows
//  whether the car token is drawn, mark 2's ring never lands on a control, honest story copy,
//  Settings refresh / night-before visibility.
//

import XCTest
import SwiftUI
@testable import WePark

final class StoopPhase6aFollowupTests: XCTestCase {

    // MARK: Coach 3 copy follows token visibility

    func testCoach3_tokenDrawn_saysDrag() {
        let mark = OnboardingCoachMark.tapABlock
        XCTAssertEqual(mark.v2Title(accessibilityLayout: false, tokenVisible: true), "Drag the car to park")
        XCTAssertEqual(mark.v2Message(accessibilityLayout: false, tokenVisible: true),
                       "Hold the car and drag it to a green curb.")
    }

    func testCoach3_tokenHidden_fallsBackToTapAGreenCurb() {
        let mark = OnboardingCoachMark.tapABlock
        XCTAssertEqual(mark.v2Title(accessibilityLayout: false, tokenVisible: false), "Tap a green curb, then Park here")
        XCTAssertFalse(mark.v2Message(accessibilityLayout: false, tokenVisible: false).lowercased().contains("drag"))
    }

    func testCoach3_accessibilitySize_alwaysFallsBack_evenIfTokenFlagTrue() {
        let mark = OnboardingCoachMark.tapABlock
        XCTAssertEqual(mark.v2Title(accessibilityLayout: true, tokenVisible: true), "Tap a green curb, then Park here")
        XCTAssertEqual(mark.v2Title(accessibilityLayout: true, tokenVisible: false), "Tap a green curb, then Park here")
    }

    func testCoach1And2_copyIgnoresTokenVisibility() {
        for mark in [OnboardingCoachMark.goalTiles, .colorMeaning] {
            XCTAssertEqual(mark.v2Title(accessibilityLayout: false, tokenVisible: true),
                           mark.v2Title(accessibilityLayout: false, tokenVisible: false))
            XCTAssertEqual(mark.v2Message(accessibilityLayout: false, tokenVisible: true),
                           mark.v2Message(accessibilityLayout: false, tokenVisible: false))
        }
    }

    // MARK: Coach 2 anchor

    private let screen = CGSize(width: 402, height: 874)

    private func clear(_ p: CGPoint, token: CGPoint? = nil) -> Bool {
        WPCoachAnchorLogic.isClear(point: p, topChromeBottom: 120, goalDockTop: 507, screen: screen, tokenCenter: token)
    }

    func testAnchor_openMapPoint_isClear() {
        XCTAssertTrue(clear(CGPoint(x: 330, y: 200)))
    }

    func testAnchor_underTopChrome_rejected() {
        XCTAssertFalse(clear(CGPoint(x: 200, y: 130)))
    }

    func testAnchor_overSearchRow_rejected() {
        // The search row sits roughly y 447 to 495 (just above the sheet at 507).
        XCTAssertFalse(clear(CGPoint(x: 150, y: 470)))
    }

    func testAnchor_overSheet_rejected() {
        XCTAssertFalse(clear(CGPoint(x: 200, y: 600)))
    }

    func testAnchor_nearScreenEdge_rejected() {
        XCTAssertFalse(clear(CGPoint(x: 10, y: 200)))
        XCTAssertFalse(clear(CGPoint(x: 395, y: 200)))
    }

    func testAnchor_overToken_rejected() {
        XCTAssertFalse(clear(CGPoint(x: 205, y: 250), token: CGPoint(x: 201, y: 245)))
        XCTAssertTrue(clear(CGPoint(x: 330, y: 200), token: CGPoint(x: 201, y: 245)))
    }

    func testAnchor_cardWouldCoverSearchRow_rejected() {
        // Clear of every control itself, but a card hung below it (36 gap + 176) would reach the
        // search row, and there is no room above under the Skip link either.
        XCTAssertFalse(clear(CGPoint(x: 330, y: 300)))
    }

    func testAnchor_unmeasuredSheet_assumesBottomFortyPercent() {
        XCTAssertFalse(WPCoachAnchorLogic.isClear(
            point: CGPoint(x: 200, y: 500), topChromeBottom: 120, goalDockTop: 0, screen: screen, tokenCenter: nil))
    }

    func testAnchor_firstClear_skipsBlockedCandidatesKeepingOrder() {
        let blocked = CGPoint(x: 150, y: 470)
        let ok1 = CGPoint(x: 330, y: 200)
        let ok2 = CGPoint(x: 300, y: 190)
        XCTAssertEqual(
            WPCoachAnchorLogic.firstClear(among: [blocked, ok1, ok2], topChromeBottom: 120, goalDockTop: 507,
                                          screen: screen, tokenCenter: nil),
            ok1)
        XCTAssertNil(
            WPCoachAnchorLogic.firstClear(among: [blocked], topChromeBottom: 120, goalDockTop: 507,
                                          screen: screen, tokenCenter: nil))
    }

    // MARK: Story copy honesty

    func testStory_doesNotClaimEveryCurbOrCertainty() {
        for card in OnboardingStoryCard.allCases {
            let text = (card.v2Title + " " + card.v2Sub).lowercased()
            XCTAssertFalse(text.contains("every curb"), text)
            XCTAssertFalse(text.contains("which sign says"), text)
        }
        XCTAssertEqual(OnboardingStoryCard.problem.v2Sub,
                       "WePark reads NYC\u{2019}s posted parking signs, curb by curb, so you don\u{2019}t have to.")
        XCTAssertEqual(OnboardingStoryCard.ask.v2Sub,
                       "Tap a curb to see how long you can stay and the sign behind it.")
    }

    // MARK: Settings

    func testSettings_notificationStatusRefreshesOnlyWhenActive() {
        XCTAssertTrue(WPSettingsLogic.shouldRefreshNotificationStatus(scenePhase: .active))
        XCTAssertFalse(WPSettingsLogic.shouldRefreshNotificationStatus(scenePhase: .inactive))
        XCTAssertFalse(WPSettingsLogic.shouldRefreshNotificationStatus(scenePhase: .background))
    }

    func testSettings_nightBeforeTimeShownOnlyWhenToggleOn() {
        XCTAssertTrue(WPSettingsLogic.showsNightBeforeTime(nightBeforeOn: true))
        XCTAssertFalse(WPSettingsLogic.showsNightBeforeTime(nightBeforeOn: false))
    }
}

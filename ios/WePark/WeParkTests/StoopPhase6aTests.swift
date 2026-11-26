//
//  StoopPhase6aTests.swift
//  WeParkTests
//
//  Stoop Phase 6a (B1 onboarding + coach marks, B15 More / Settings): the pure copy and decision
//  logic in `DesignSystem/WPPhase6aLogic.swift`, plus guards that the flag-off sequencing, gates
//  and row visibility did not move.
//

import XCTest
import UserNotifications
@testable import WePark

final class StoopPhase6aTests: XCTestCase {

    // MARK: Story deck

    func testStory_threeCards_progressAndOrder() {
        XCTAssertEqual(OnboardingStoryCard.allCases.map(\.v2Progress), ["1 of 3", "2 of 3", "3 of 3"])
        XCTAssertEqual(OnboardingStoryCard.problem.v2Title, "See where you can park before you circle the block")
        XCTAssertEqual(OnboardingStoryCard.ask.v2Title, "Free always comes with an end time")
        XCTAssertEqual(OnboardingStoryCard.payoff.v2Title, "Say how long you\u{2019}re staying")
    }

    func testStory_lastCardKeepsLetsGo_andSequencingIsTheExistingModel() {
        XCTAssertEqual(OnboardingStoryCard.problem.v2PrimaryLabel, "Continue")
        XCTAssertEqual(OnboardingStoryCard.payoff.v2PrimaryLabel, "Let's go")
        XCTAssertTrue(onboardingStoryIsFinalCard(.payoff))
        XCTAssertEqual(onboardingStoryNextCard(after: .problem), .ask)
        XCTAssertNil(onboardingStoryNextCard(after: .payoff))
    }

    func testStory_onboardingTeachesOnlyTheBaseView() {
        let all = OnboardingStoryCard.allCases.flatMap { [$0.v2Title, $0.v2Sub] }
            + [WPStoryLines.parkSub, WPStoryLines.dontSub]
        for text in all {
            XCTAssertFalse(text.lowercased().contains("sign details"), text)
            XCTAssertFalse(text.lowercased().contains("metered"), text)
        }
    }

    func testStory_forDaysNeverClaimsAFixedWeek() {
        let subs = WPStoryExample.goalChips.map(\.sub)
        XCTAssertEqual(WPStoryExample.goalChips.map(\.title), ["A few hours", "Overnight", "For days"])
        XCTAssertFalse(subs.contains { $0.lowercased().contains("week") })
        XCTAssertEqual(WPStoryExample.goalChips[WPStoryExample.selectedChipIndex].title, "Overnight")
    }

    func testStory_exampleCardIsLabelledAsAnExample() {
        XCTAssertEqual(WPStoryExample.label, "Example")
    }

    // MARK: Location priming

    func testLocationPriming_copyMatchesMock() {
        XCTAssertEqual(WPLocationPrimingCopy.title, "Let WePark see where you are")
        XCTAssertEqual(WPLocationPrimingCopy.allow, "Allow location")
        XCTAssertEqual(WPLocationPrimingCopy.notNow, "Not now")
        XCTAssertEqual(WPLocationPrimingCopy.facts.count, 3)
    }

    // MARK: Coach marks

    func testCoach_sequenceIsUnchanged_threeMarks() {
        XCTAssertEqual(OnboardingCoachMark.allCases.count, 3)
        XCTAssertEqual(onboardingCoachFirstMark(), .goalTiles)
        XCTAssertEqual(onboardingCoachNextMark(after: .goalTiles), .colorMeaning)
        XCTAssertEqual(onboardingCoachNextMark(after: .colorMeaning), .tapABlock)
        XCTAssertNil(onboardingCoachNextMark(after: .tapABlock))
        XCTAssertEqual(OnboardingCoachMark.allCases.map(\.v2Progress), ["1 of 3", "2 of 3", "3 of 3"])
    }

    func testCoach_teachesWindowTwoStateMapAndDragToPark() {
        XCTAssertEqual(OnboardingCoachMark.goalTiles.v2Message(accessibilityLayout: false),
                       "Overnight means from now until the morning.")
        XCTAssertEqual(OnboardingCoachMark.colorMeaning.v2Title(accessibilityLayout: false),
                       "Solid green: park. Dashed coral: don\u{2019}t.")
        XCTAssertEqual(OnboardingCoachMark.tapABlock.v2Title(accessibilityLayout: false), "Drag the car to park")
    }

    func testCoach_accessibilityLayoutNamesWhatIsActuallyThere() {
        // The goal tiles collapse to one card and the resting car token is hidden at AX sizes.
        XCTAssertTrue(OnboardingCoachMark.goalTiles.v2Title(accessibilityLayout: true).contains("goal card"))
        XCTAssertFalse(OnboardingCoachMark.tapABlock.v2Title(accessibilityLayout: true).lowercased().contains("drag"))
        XCTAssertFalse(OnboardingCoachMark.tapABlock.v2Message(accessibilityLayout: true).lowercased().contains("drag"))
    }

    func testCoach_nextLabels() {
        XCTAssertEqual(OnboardingCoachMark.goalTiles.v2NextLabel, "Next")
        XCTAssertEqual(OnboardingCoachMark.colorMeaning.v2NextLabel, "Next")
        XCTAssertEqual(OnboardingCoachMark.tapABlock.v2NextLabel, "Got it")
    }

    func testCoach_realControlRules() {
        XCTAssertTrue(OnboardingCoachMark.goalTiles.v2DismissedByGoalTileTap)
        XCTAssertFalse(OnboardingCoachMark.colorMeaning.v2DismissedByGoalTileTap)
        XCTAssertFalse(OnboardingCoachMark.tapABlock.v2DismissedByGoalTileTap)
        XCTAssertTrue(OnboardingCoachMark.colorMeaning.v2DismissedByCurbTap)
        XCTAssertFalse(OnboardingCoachMark.goalTiles.v2DismissedByCurbTap)
        // Flag-off rule is untouched: marks 1 and 2 are both dismissed by a goal-tile tap.
        XCTAssertTrue(OnboardingCoachMark.colorMeaning.dismissedByGoalTileTap)
    }

    func testOnboardingGates_stillRequireBothFlagsAndTheOneShotGate() {
        XCTAssertFalse(onboardingStoryShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: false, gateShouldShow: true))
        XCTAssertFalse(onboardingStoryShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: true, gateShouldShow: false))
        XCTAssertTrue(onboardingStoryShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: true, gateShouldShow: true))
        XCTAssertFalse(onboardingCoachShouldShow(onboardingStoryEnabled: true, driveModeDefaultEnabled: true, gateShouldShow: false))
    }

    func testOnboardingGates_seenFlagsAreRespected() {
        let suite = UserDefaults(suiteName: "wp6a-gates-\(UUID().uuidString)")!
        XCTAssertTrue(OnboardingStoryGate(defaults: suite).shouldShow())
        OnboardingStoryGate(defaults: suite).markShown()
        XCTAssertFalse(OnboardingStoryGate(defaults: suite).shouldShow())
        XCTAssertTrue(OnboardingCoachGate(defaults: suite).shouldShow())
        OnboardingCoachGate(defaults: suite).markShown()
        XCTAssertFalse(OnboardingCoachGate(defaults: suite).shouldShow())
    }

    // MARK: Reminder option set (DECISIONS #8)

    func testReminderOptions_sameSetAsMyCar_inOrder() {
        XCTAssertEqual(WPSettingsLogic.LeadOption.allCases.map(\.chipTitle), ["15 min", "30 min", "1 hr", "2 hr"])
    }

    func testReminderOptions_toggleOnlyTheirOwnField() {
        let base = ReminderOffsets.default
        let a = WPSettingsLogic.LeadOption.min15.toggled(in: base)
        XCTAssertTrue(a.remind15Min)
        XCTAssertTrue(a.remind1Hour)
        XCTAssertFalse(a.remind30Min)
        XCTAssertFalse(a.remind2Hours)
        XCTAssertFalse(a.remindNightBefore)
        XCTAssertEqual(WPSettingsLogic.LeadOption.min15.toggled(in: a), base)
        XCTAssertFalse(WPSettingsLogic.LeadOption.hour1.toggled(in: base).remind1Hour)
        XCTAssertTrue(WPSettingsLogic.LeadOption.hours2.toggled(in: base).remind2Hours)
        XCTAssertTrue(WPSettingsLogic.LeadOption.min30.toggled(in: base).remind30Min)
    }

    func testReminderOptions_persistThroughTheExistingStorage() {
        let suite = UserDefaults(suiteName: "wp6a-offsets-\(UUID().uuidString)")!
        let toggled = WPSettingsLogic.LeadOption.hours2.toggled(in: .default)
        ReminderOffsets.save(toggled, to: suite)
        XCTAssertEqual(ReminderOffsets.load(from: suite), toggled)
    }

    func testReminderSummary_cases() {
        let none = ReminderOffsets(remind15Min: false, remind30Min: false, remind1Hour: false, remind2Hours: false, remindNightBefore: false)
        XCTAssertEqual(WPSettingsLogic.reminderSummary(offsets: .default, muted: false), "1 hour before")
        XCTAssertEqual(WPSettingsLogic.reminderSummary(offsets: .default, muted: true), "Off")
        XCTAssertEqual(WPSettingsLogic.reminderSummary(offsets: none, muted: false), "None picked")
        var night = none
        night.remindNightBefore = true
        XCTAssertEqual(WPSettingsLogic.reminderSummary(offsets: night, muted: false), "The night before")
        var many = ReminderOffsets.default
        many.remind15Min = true
        many.remindNightBefore = true
        XCTAssertEqual(WPSettingsLogic.reminderSummary(offsets: many, muted: false), "15 min, 1 hour before and the night before")
    }

    func testNightBeforeTimeLabel() {
        XCTAssertEqual(WPSettingsLogic.nightBeforeTimeLabel(hour: AppConstants.nightBeforeHourET), "8:00 PM")
        XCTAssertEqual(WPSettingsLogic.nightBeforeTimeLabel(hour: 0), "12:00 AM")
        XCTAssertEqual(WPSettingsLogic.nightBeforeTimeLabel(hour: 12), "12:00 PM")
        XCTAssertEqual(WPSettingsLogic.nightBeforeTimeLabel(hour: 9), "9:00 AM")
    }

    // MARK: Notifications row

    func testNotificationStatusLabel() {
        XCTAssertEqual(WPSettingsLogic.notificationStatusLabel(.authorized), "Allowed")
        XCTAssertEqual(WPSettingsLogic.notificationStatusLabel(.provisional), "Allowed")
        XCTAssertEqual(WPSettingsLogic.notificationStatusLabel(.denied), "Off in iOS Settings")
        XCTAssertEqual(WPSettingsLogic.notificationStatusLabel(.notDetermined), "Not asked yet")
        XCTAssertEqual(WPSettingsLogic.notificationStatusLabel(nil), "Checking\u{2026}")
    }

    // MARK: Settings rows and the dark-shipped flags

    func testSettingsSections_shippingFlagsOff_hideDeleteAndSuggest() {
        let sections = WPSettingsLogic.sections(
            suggestVisible: AppConstants.coverageSuggestionVisible(),
            deleteVisible: AppConstants.accountDeletionRowVisible(),
            regularsVisible: AppConstants.regularsSettingsRowVisible()
        )
        XCTAssertEqual(sections, [[.reminders, .voice, .notifications], [.help, .about]])
    }

    func testSettingsSections_flagsOn_renderPerMock() {
        let sections = WPSettingsLogic.sections(suggestVisible: true, deleteVisible: true, regularsVisible: false)
        XCTAssertEqual(sections, [
            [.reminders, .voice, .notifications],
            [.deleteAccount],
            [.suggestNeighborhood, .help, .about],
        ])
    }

    func testSettingsFlags_dark_shippedDefaultsStayOff() {
        XCTAssertFalse(AppConstants.accountDeletionEnabled)
        XCTAssertFalse(AppConstants.coverageRequestsEnabled)
        XCTAssertFalse(AppConstants.designSystemV2Enabled)
    }

    func testVersionLabel() {
        XCTAssertEqual(WPSettingsLogic.versionLabel(version: "1.0", build: "42"), "1.0 (42)")
    }

    // MARK: More list (DECISIONS #9, "Show all sign details" keeps working)

    func testMore_fullList_keepsOrder_andSignDetailsToggleRow() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: true, hasParkedCar: false,
            fullPaletteMode: false, spotPassEnabled: true, planTripEnabled: true
        )
        XCTAssertEqual(rows, [.report, .spotPass, .howWeParkWorks, .mapKey, .parking101, .showAllRules, .planTrip, .settings])
        XCTAssertEqual(MoreMenuRow.showAllRules.title, "Show all sign details")
        XCTAssertEqual(MoreMenuRow.mapKey.title, "What the colors mean")
    }

    func testMore_shippingFlagsOff_hidesSpotPassAndPlanTrip() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: false, hasParkedCar: false, fullPaletteMode: false
        )
        XCTAssertFalse(rows.contains(.spotPass))
        XCTAssertFalse(rows.contains(.planTrip))
        XCTAssertFalse(rows.contains(.howWeParkWorks))
        XCTAssertEqual(rows.last, .settings)
    }

    // MARK: Colors (B15.6) and Help (B15.7)

    func testColors_detailRowsMatchTheFiveStyles_andPinsAreOnlyWhatTheMapDraws() {
        XCTAssertEqual(WPColorsCopy.detailRows.map(\.label),
                       ["Free", "Changes soon", "Metered", "No parking", "No sign data"])
        XCTAssertEqual(WPColorsCopy.detailRows.map(\.kind), CurbLineKind.allCases)
        XCTAssertEqual(WPColorsCopy.pinLabels, ["Open spot", "Leaving soon", "Street swept", "Ticketing now"])
    }

    func testHelp_spotPassTopicsOnlyWhenSpotPassIsLive() {
        let off = WPHelpTopic.topics(spotPassEnabled: false).map(\.id)
        let on = WPHelpTopic.topics(spotPassEnabled: true).map(\.id)
        XCTAssertEqual(off, ["disagree", "source", "reminders"])
        XCTAssertEqual(on, ["disagree", "source", "reminders", "spotpass", "karma"])
        XCTAssertEqual(Set(on).count, on.count)
        XCTAssertTrue(WPHelpTopic.topics(spotPassEnabled: false)[0].answer.contains("sign"))
    }

    func testAbout_sourcesAreValidHTTPSLinks() {
        XCTAssertEqual(WPAboutSources.links.count, 3)
        for link in WPAboutSources.links {
            XCTAssertEqual(URL(string: link.url)?.scheme, "https", link.url)
        }
    }
}

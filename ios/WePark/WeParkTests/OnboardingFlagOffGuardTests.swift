//
//  OnboardingFlagOffGuardTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41) — dark-ship guard tests. `AppConstants
//  .onboardingStoryEnabled` ships `false`; these tests pin that EVERY onboarding call site
//  resolves to "nothing renders/nothing is scheduled" whenever either onboarding flag is
//  `false`, for every combination of the OTHER inputs — the same "4 dark-ship guard tests
//  transformed into launched-world assertions" playbook `DriveModeDefaultFlagTests`/
//  `RegularsFlagGuardTests` already use for this codebase's other flags.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class OnboardingFlagOffGuardTests: XCTestCase {

    /// Both flags ship `false` today.
    func testBothOnboardingFlags_defaultFalse() {
        XCTAssertFalse(AppConstants.onboardingStoryEnabled)
        XCTAssertFalse(AppConstants.driveModeDefaultEnabled)
    }

    /// With `onboardingStoryEnabled == false`, the story deck never shows — regardless of
    /// `driveModeDefaultEnabled` or the one-shot gate's own state.
    func testStoryNeverShows_whenOnboardingStoryEnabledFalse() {
        for driveFlag in [true, false] {
            for gate in [true, false] {
                XCTAssertFalse(
                    onboardingStoryShouldShow(
                        onboardingStoryEnabled: false,
                        driveModeDefaultEnabled: driveFlag,
                        gateShouldShow: gate
                    )
                )
            }
        }
    }

    /// With `driveModeDefaultEnabled == false`, the story deck never shows — regardless of
    /// `onboardingStoryEnabled` or the gate's own state (onboarding that explains a screen the
    /// user can't reach is meaningless, design doc §6).
    func testStoryNeverShows_whenDriveModeDefaultEnabledFalse() {
        for storyFlag in [true, false] {
            for gate in [true, false] {
                XCTAssertFalse(
                    onboardingStoryShouldShow(
                        onboardingStoryEnabled: storyFlag,
                        driveModeDefaultEnabled: false,
                        gateShouldShow: gate
                    )
                )
            }
        }
    }

    /// Same sweep, for the coach layer.
    func testCoachNeverShows_whenEitherOnboardingFlagFalse() {
        for storyFlag in [true, false] {
            for driveFlag in [true, false] {
                for gate in [true, false] {
                    guard !(storyFlag && driveFlag) else { continue }
                    XCTAssertFalse(
                        onboardingCoachShouldShow(
                            onboardingStoryEnabled: storyFlag,
                            driveModeDefaultEnabled: driveFlag,
                            gateShouldShow: gate
                        )
                    )
                }
            }
        }
    }

    /// The real, no-argument call (the one every actual call site in `ContentView` uses)
    /// resolves `false` today for both tiers, using the REAL shipped flags.
    func testRealFlags_resolveFalse_forBothTiers() {
        XCTAssertFalse(onboardingStoryShouldShow(
            onboardingStoryEnabled: AppConstants.onboardingStoryEnabled,
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            gateShouldShow: true
        ))
        XCTAssertFalse(onboardingCoachShouldShow(
            onboardingStoryEnabled: AppConstants.onboardingStoryEnabled,
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            gateShouldShow: true
        ))
    }

    /// The More sheet's "How WePark works" row never appears when the onboarding experience is
    /// disabled — regardless of every other row-visibility input.
    func testHowWeParkWorksRow_neverShows_whenOnboardingReplayUnavailable() {
        for communityEnabled in [true, false] {
            for hasParkedCar in [true, false] {
                for fullPaletteMode in [true, false] {
                    let rows = moreMenuVisibleRows(
                        communityEnabled: communityEnabled,
                        onboardingReplayAvailable: false,
                        hasParkedCar: hasParkedCar,
                        fullPaletteMode: fullPaletteMode
                    )
                    XCTAssertFalse(rows.contains(.howWeParkWorks))
                }
            }
        }
    }
}

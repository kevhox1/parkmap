//
//  OnboardingGatingTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §4) —
//  unit tests for `AppConstants.onboardingExperienceEnabled(...)` (the one pure gating
//  function every onboarding call site routes through), the three one-shot gates
//  (`OnboardingStoryGate`/`OnboardingCoachGate`), and `FirstLaunchSentinel` (the fresh-install
//  vs. upgrading-user detector, §4.2).
//
//  Test groups:
//    1. `AppConstants.onboardingExperienceEnabled(...)` — every combination (the master
//       both-flags AND gate task requires).
//    2. `OnboardingStoryGate` / `OnboardingCoachGate` persistence — mirrors
//       `LocationPrimingCardGateTests` exactly (ephemeral `UserDefaults` suite, injected).
//    3. `FirstLaunchSentinel` — fresh install, upgrading install (pre-seed), idempotency,
//       and the "never clobber an explicitly-already-set story flag" guard.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

// MARK: - 1. onboardingExperienceEnabled(...) — every combination

final class OnboardingExperienceEnabledTests: XCTestCase {

    func testEnabled_onlyWhenBothFlagsAreTrue() {
        for storyFlag in [true, false] {
            for driveFlag in [true, false] {
                let expected = storyFlag && driveFlag
                XCTAssertEqual(
                    AppConstants.onboardingExperienceEnabled(
                        onboardingStoryEnabled: storyFlag,
                        driveModeDefaultEnabled: driveFlag
                    ),
                    expected,
                    "story(\(storyFlag)) AND drive(\(driveFlag)) should resolve \(expected)"
                )
            }
        }
    }

    /// Closes the "default-parameter-binding gap" this codebase's own precedent
    /// (`RegularsFlagGuardTests`, `DriveModeDefaultFlagTests`) checks for every new flag: the
    /// no-argument call must resolve identically to an explicit call using the REAL shipped
    /// flags, not just prove the function doesn't hardcode a literal.
    func testDefaultParameters_matchShippedFlags() {
        XCTAssertEqual(
            AppConstants.onboardingExperienceEnabled(),
            AppConstants.onboardingExperienceEnabled(
                onboardingStoryEnabled: AppConstants.onboardingStoryEnabled,
                driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled
            )
        )
    }

    /// Both flags dark-ship `false` today, so the real, no-argument call must resolve `false`.
    func testRealFlags_resolveFalse_today() {
        XCTAssertFalse(AppConstants.onboardingExperienceEnabled())
    }
}

// MARK: - 2. OnboardingStoryGate / OnboardingCoachGate persistence

final class OnboardingStoryGateTests: XCTestCase {

    private let suiteName = "com.wepark.test.onboardingstorygate"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: AppConstants.hasSeenOnboardingStoryKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testFirstLaunch_showsDeck_thenPersistsForever() {
        let gate = OnboardingStoryGate(defaults: ephemeralDefaults,
                                        key: AppConstants.hasSeenOnboardingStoryKey)
        XCTAssertTrue(gate.shouldShow())
        gate.markShown()
        XCTAssertTrue(ephemeralDefaults.bool(forKey: AppConstants.hasSeenOnboardingStoryKey))
        XCTAssertFalse(gate.shouldShow())
    }

    func testMarkShown_isIdempotent() {
        let gate = OnboardingStoryGate(defaults: ephemeralDefaults,
                                        key: AppConstants.hasSeenOnboardingStoryKey)
        gate.markShown()
        for _ in 0..<3 {
            XCTAssertFalse(gate.shouldShow())
            gate.markShown()
        }
    }

    func testTwoGateInstances_shareState() {
        let writer = OnboardingStoryGate(defaults: ephemeralDefaults,
                                          key: AppConstants.hasSeenOnboardingStoryKey)
        let reader = OnboardingStoryGate(defaults: ephemeralDefaults,
                                          key: AppConstants.hasSeenOnboardingStoryKey)
        XCTAssertTrue(reader.shouldShow())
        writer.markShown()
        XCTAssertFalse(reader.shouldShow())
    }
}

final class OnboardingCoachGateTests: XCTestCase {

    private let suiteName = "com.wepark.test.onboardingcoachgate"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: AppConstants.hasSeenOnboardingCoachKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    func testFirstLaunch_showsCoach_thenPersistsForever() {
        let gate = OnboardingCoachGate(defaults: ephemeralDefaults,
                                        key: AppConstants.hasSeenOnboardingCoachKey)
        XCTAssertTrue(gate.shouldShow())
        gate.markShown()
        XCTAssertTrue(ephemeralDefaults.bool(forKey: AppConstants.hasSeenOnboardingCoachKey))
        XCTAssertFalse(gate.shouldShow())
    }

    func testMarkShown_isIdempotent() {
        let gate = OnboardingCoachGate(defaults: ephemeralDefaults,
                                        key: AppConstants.hasSeenOnboardingCoachKey)
        gate.markShown()
        for _ in 0..<3 {
            XCTAssertFalse(gate.shouldShow())
            gate.markShown()
        }
    }
}

// MARK: - 3. FirstLaunchSentinel (§4.2)

final class FirstLaunchSentinelTests: XCTestCase {

    private let suiteName = "com.wepark.test.firstlaunchsentinel"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: AppConstants.hasLaunchedWeParkBeforeKey)
        ephemeralDefaults.removeObject(forKey: AppConstants.hasSeenOnboardingStoryKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    /// A brand-new install (both keys unset): the call reports `isFreshInstall == true`, sets
    /// the sentinel, and leaves `hasSeenOnboardingStoryKey` untouched (so the real
    /// `OnboardingStoryGate` default — "never shown" — still governs it; the story deck gets
    /// its full normal sequence).
    func testFreshInstall_reportsTrue_andDoesNotPreSeedStoryFlag() {
        let sentinel = FirstLaunchSentinel(defaults: ephemeralDefaults)
        let isFresh = sentinel.markLaunchedAndPreSeedIfUpgrading()
        XCTAssertTrue(isFresh)
        XCTAssertTrue(ephemeralDefaults.bool(forKey: AppConstants.hasLaunchedWeParkBeforeKey))
        XCTAssertNil(ephemeralDefaults.object(forKey: AppConstants.hasSeenOnboardingStoryKey))
    }

    /// Simulates the real two-build timeline the design doc's mechanism depends on: call 1 is
    /// this device's FIRST-EVER launch of the build that ships this sentinel (reports fresh,
    /// does not pre-seed, sets the sentinel). Call 2 simulates a much LATER launch — the build
    /// that eventually flips the onboarding flags — by which point the sentinel is already set
    /// from call 1, so this call correctly reports non-fresh and pre-seeds the still-untouched
    /// story flag `true`, meaning the story cards never show for this (upgrading) install.
    func testUpgradingInstall_reportsFalse_andPreSeedsStoryFlagTrue() {
        let sentinel = FirstLaunchSentinel(defaults: ephemeralDefaults)
        XCTAssertTrue(sentinel.markLaunchedAndPreSeedIfUpgrading(), "call 1 (build N) is fresh")

        let isFreshAtFlipBuild = sentinel.markLaunchedAndPreSeedIfUpgrading()
        XCTAssertFalse(isFreshAtFlipBuild, "call 2 (build M, sentinel already set) is non-fresh")
        XCTAssertTrue(
            ephemeralDefaults.bool(forKey: AppConstants.hasSeenOnboardingStoryKey),
            "a non-fresh call must pre-seed hasSeenOnboardingStoryKey true when it was unset"
        )
    }

    /// If `hasSeenOnboardingStoryKey` has ALREADY been explicitly written (true OR false) by
    /// the real gate/replay machinery before this call runs, the sentinel must never clobber
    /// it — the design doc's mechanism only pre-seeds when the key is utterly unset
    /// (`object(forKey:) == nil`), not merely falsy.
    func testUpgradingInstall_neverClobbers_anAlreadyWrittenStoryFlag() {
        ephemeralDefaults.set(true, forKey: AppConstants.hasLaunchedWeParkBeforeKey)
        ephemeralDefaults.set(false, forKey: AppConstants.hasSeenOnboardingStoryKey)

        let sentinel = FirstLaunchSentinel(defaults: ephemeralDefaults)
        let isFresh = sentinel.markLaunchedAndPreSeedIfUpgrading()

        XCTAssertFalse(isFresh)
        XCTAssertFalse(
            ephemeralDefaults.bool(forKey: AppConstants.hasSeenOnboardingStoryKey),
            "an explicitly-false story flag (already written by real gate logic) must not be " +
            "overwritten to true"
        )
    }

    /// Repeated calls (every subsequent cold launch) are idempotent: `isFreshInstall` is only
    /// ever `true` on the very first call.
    func testRepeatedCalls_areIdempotent() {
        let sentinel = FirstLaunchSentinel(defaults: ephemeralDefaults)
        XCTAssertTrue(sentinel.markLaunchedAndPreSeedIfUpgrading())
        for _ in 0..<3 {
            XCTAssertFalse(sentinel.markLaunchedAndPreSeedIfUpgrading())
        }
    }
}

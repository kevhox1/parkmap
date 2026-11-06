//
//  OnboardingStoryViewRenderTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §1) —
//  render-without-crashing smoke tests for `OnboardingStoryView` and its three code-drawn
//  illustrations, per this repo's standing `UIHostingController` smoke pattern
//  (`GoalAwareDriveCardTests.swift`).
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import SwiftUI
@testable import WePark

@MainActor
final class OnboardingStoryViewRenderTests: XCTestCase {

    func testOnboardingStoryView_rendersWithoutCrash() {
        let view = OnboardingStoryView(onFinish: {})
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view, "OnboardingStoryView should render without crash")
    }

    /// Exercises `onFinish` directly (both the final-card "Let's go" path and the Skip path
    /// route through this same closure) — confirms the view can be constructed and its
    /// closure invoked without any `ContentView`/live-map dependency.
    func testOnFinish_closureIsInvocable() {
        var finished = false
        let view = OnboardingStoryView(onFinish: { finished = true })
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
        view.onFinish()
        XCTAssertTrue(finished)
    }
}

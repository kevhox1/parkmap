//
//  OnboardingCoachOverlayRenderTests.swift
//  WeParkTests
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2) —
//  render-without-crashing smoke tests for `OnboardingCoachOverlay`, per this repo's standing
//  `UIHostingController` smoke pattern. Covers all 3 marks, both with real (non-zero) measured
//  frames and with the `.zero` "not yet measured" fallback — the overlay must never crash
//  either way.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import SwiftUI
@testable import WePark

@MainActor
final class OnboardingCoachOverlayRenderTests: XCTestCase {

    private let dockFrame = CGRect(x: 16, y: 560, width: 361, height: 220)
    private let tileRowFrame = CGRect(x: 16, y: 640, width: 361, height: 128)
    private let selectedTileFrame = CGRect(x: 16, y: 640, width: 115, height: 128)

    private func makeOverlay(
        mark: OnboardingCoachMark,
        dock: CGRect,
        tileRow: CGRect,
        selectedTile: CGRect,
        curbOffset: CGSize = .zero
    ) -> OnboardingCoachOverlay {
        OnboardingCoachOverlay(
            mark: mark,
            goalDockFrame: dock,
            tileRowFrame: tileRow,
            selectedTileFrame: selectedTile,
            nearestCurbOffset: curbOffset,
            onPrimaryAction: {},
            onSkipAll: {}
        )
    }

    func testMark1_withRealFrames_rendersWithoutCrash() {
        let view = makeOverlay(mark: .goalTiles, dock: dockFrame, tileRow: tileRowFrame, selectedTile: selectedTileFrame)
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    func testMark2_withRealFrames_rendersWithoutCrash() {
        let view = makeOverlay(mark: .colorMeaning, dock: dockFrame, tileRow: tileRowFrame, selectedTile: selectedTileFrame)
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    func testMark3_withCurbOffset_rendersWithoutCrash() {
        let view = makeOverlay(
            mark: .tapABlock, dock: dockFrame, tileRow: tileRowFrame, selectedTile: selectedTileFrame,
            curbOffset: CGSize(width: 40, height: -30)
        )
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    func testMark3_withZeroCurbOffset_fallsBackToCenter_rendersWithoutCrash() {
        let view = makeOverlay(mark: .tapABlock, dock: dockFrame, tileRow: tileRowFrame, selectedTile: selectedTileFrame)
        let host = UIHostingController(rootView: view)
        XCTAssertNotNil(host.view)
    }

    /// Every frame `.zero` (not yet measured) is the real first-render state for a half second
    /// after the settle delay fires — must never crash, even though the ring/bubble clearance
    /// math has nothing real to anchor against yet.
    func testAllMarks_withZeroFrames_renderWithoutCrash() {
        for mark in OnboardingCoachMark.allCases {
            let view = makeOverlay(mark: mark, dock: .zero, tileRow: .zero, selectedTile: .zero)
            let host = UIHostingController(rootView: view)
            XCTAssertNotNil(host.view, "mark \(mark) with all-zero frames should render without crash")
        }
    }
}

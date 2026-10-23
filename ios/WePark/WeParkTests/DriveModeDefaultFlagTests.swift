//
//  DriveModeDefaultFlagTests.swift
//  WeParkTests
//
//  DM-1 (`docs/drive-mode-default-spec.md` §0.6 ruling 3, §3.3, §5 AC-1/AC-2/AC-14) — flag
//  scaffold + rest-state default flip guard tests.
//
//  `AppConstants.driveModeDefaultEnabled` dark-ships `false`. Both of the two rest-state
//  sites this stream touches — `ContentView.activeSheet`'s `@State` initial value and
//  `ContentView.dismissTargetOutsideBrowseNav` — route through the SAME pure, testable
//  function, `driveModeDefaultRestStateSheet(driveModeDefaultEnabled:)`
//  (`ContentView.swift`, near `browseSheetBoundaryTarget`). That function is the actual
//  subject of every test below; it is the single source of truth both call sites read, so
//  asserting its two branches here directly backs BOTH of spec AC-1's claims
//  ("`activeSheet` still defaults to `.browseNav`" and "`dismissTargetOutsideBrowseNav` still
//  resolves to `.browseNav`") without needing to construct a live `ContentView` or reach into
//  its `private` members.
//
//  Per the PR #109 playbook (`docs/community-2.0-roadmap.md`, "4 dark-ship guard tests
//  transformed into launched-world assertions"): `testRestStateSheet_resolvesNil_whenFlagOn`
//  below is written now as a dark-ship guard on the flag-ON branch of a pure function — at
//  flip time it becomes the launched-world assertion with zero rewrite needed, only the real
//  `AppConstants.driveModeDefaultEnabled` flipping to `true`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class DriveModeDefaultFlagTests: XCTestCase {

    // MARK: - The flag itself dark-ships false

    func testDriveModeDefaultEnabled_defaultsFalse() {
        XCTAssertFalse(
            AppConstants.driveModeDefaultEnabled,
            "driveModeDefaultEnabled must ship dark until Phase 1's drive-test gate clears " +
            "(spec §0.6)."
        )
    }

    // MARK: - AC-1: flag off — both rest-state sites resolve `.browseNav`, byte-identical

    /// Backs AC-1's first clause: "`activeSheet` still defaults to `.browseNav` on cold
    /// launch." `ContentView`'s `@State private var activeSheet` initializer calls
    /// `driveModeDefaultRestStateSheet()` with no argument — this test exercises the explicit
    /// `false` branch that call resolves to while the real flag is `false`.
    func testActiveSheetDefault_resolvesBrowseNav_whenFlagOff() {
        switch driveModeDefaultRestStateSheet(driveModeDefaultEnabled: false) {
        case .browseNav:
            break
        default:
            XCTFail(
                "AC-1: activeSheet's cold-launch default must resolve to .browseNav while " +
                "driveModeDefaultEnabled is false — byte-identical to pre-DM-1 behavior."
            )
        }
    }

    /// Backs AC-1's second clause: "`dismissTargetOutsideBrowseNav` still resolves to
    /// `.browseNav`." That property's rest-state branch (after its own
    /// `driveModeActive`/`blockSelectModeActive` force-hide guard clears) calls the exact
    /// same function under test here — see that property's own doc comment in
    /// `ContentView.swift`.
    func testDismissTargetOutsideBrowseNav_resolvesBrowseNav_whenFlagOff() {
        switch driveModeDefaultRestStateSheet(driveModeDefaultEnabled: false) {
        case .browseNav:
            break
        default:
            XCTFail(
                "AC-1: dismissTargetOutsideBrowseNav's rest-state target must resolve to " +
                ".browseNav while driveModeDefaultEnabled is false — byte-identical to " +
                "pre-DM-1 behavior."
            )
        }
    }

    /// Closes the "default-parameter-binding gap" QA pass 1 flagged for the
    /// `communityEnabled`/`regularsEnabled` precedent (`RegularsFlagGuardTests
    /// .testRegularsSettingsRow_hidden_whenDisabled`, `docs/qa/pr113-regulars-s5.md` Finding
    /// #1): an explicit `driveModeDefaultEnabled: false` assertion alone only proves the
    /// function doesn't hardcode `true` — it says nothing about whether the DEFAULT
    /// parameter (the one both real call sites in `ContentView` actually use, with no
    /// argument) is wired to the real flag. This closes that gap.
    func testRestStateSheet_defaultParameter_matchesShippedFlag() {
        let defaultResult = driveModeDefaultRestStateSheet()
        let explicitResult = driveModeDefaultRestStateSheet(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled
        )
        switch (defaultResult, explicitResult) {
        case (.browseNav, .browseNav):
            break
        case (nil, nil):
            break
        default:
            XCTFail(
                "the no-argument call must resolve identically to an explicit call with the " +
                "real AppConstants.driveModeDefaultEnabled flag value."
            )
        }
    }

    // MARK: - AC-2: flag off — no ambient/goal-first UI render anywhere

    /// AC-2 ("No ambient pill, no persistent Search icon, no priming card render anywhere")
    /// had no production code surface to assert against at DM-1 time — DM-2 now builds that
    /// UI, so this is real-asserted here rather than left as a documented placeholder (DM-2
    /// dispatch, 2026-10-20: "real-assert DM-1's placeholder
    /// testFlagOff_noNewUISurfaceIntroducedByDM1"). Covers every DM-2 pure gating function
    /// that governs whether the goal-first dock/Search icon/toggle render, with the flag held
    /// `false` and every OTHER input varied — the goal dock, the goal-tile row, and the
    /// Search icon's clock-button-hiding side effect must all resolve to "off"/"unchanged"
    /// regardless of `activeSheet`/`driveModeActive`/`fullPaletteMode`, because the flag
    /// itself is the master gate. (The Search icon's own `if AppConstants
    /// .driveModeDefaultEnabled` gate at its call site in `recenterButtonStack` has no
    /// separate pure function to test — see `DM2GoalSelectorTests`'s own note on why.)
    func testFlagOff_noNewUISurfaceIntroducedByDM1() {
        for activeSheetIsNil in [true, false] {
            for driveModeActive in [true, false] {
                for blockSelectModeActive in [true, false] {
                    for spotPlacementActive in [true, false] {
                        XCTAssertFalse(
                            goalSelectorDockVisible(
                                driveModeDefaultEnabled: false,
                                activeSheetIsNil: activeSheetIsNil,
                                driveModeActive: driveModeActive,
                                blockSelectModeActive: blockSelectModeActive,
                                spotPlacementActive: spotPlacementActive
                            ),
                            "AC-2: the goal-first ambient dock must never mount while " +
                            "driveModeDefaultEnabled is false, regardless of any other state."
                        )
                    }
                }
            }
        }
        for fullPaletteMode in [true, false] {
            XCTAssertTrue(
                parkUntilClockButtonVisible(
                    driveModeDefaultEnabled: false,
                    fullPaletteMode: fullPaletteMode
                ),
                "AC-2: the power-user Park Until clock icon must stay visible (byte-identical " +
                "to pre-DM-2 behavior) while driveModeDefaultEnabled is false."
            )
        }
    }

    // MARK: - Addendum 3 (minimal ambient screen): flag-off guards

    /// Addendum 3 A3.4 replaced Addendum 2's `communityMapChromeOverlay` dock-visibility gate
    /// (`&& !goalSelectorDockVisible(...)`) with `communityMapFloatingChromeVisible`. Flag off,
    /// the new gate must equal the pre-Addendum-3 formula for EVERY input combination (the
    /// dock gate is false by construction flag-off, so both reduce to `chromeVisible`) —
    /// i.e. Report + "?" keep floating exactly where they do today.
    func testFlagOff_floatingCommunityChrome_equalsPreAddendum3Formula() {
        for chromeVisible in [true, false] {
            for activeSheetIsNil in [true, false] {
                for driveModeActive in [true, false] {
                    for blockSelectModeActive in [true, false] {
                        for spotPlacementActive in [true, false] {
                            let preAddendum3 = chromeVisible && !goalSelectorDockVisible(
                                driveModeDefaultEnabled: false,
                                activeSheetIsNil: activeSheetIsNil,
                                driveModeActive: driveModeActive,
                                blockSelectModeActive: blockSelectModeActive,
                                spotPlacementActive: spotPlacementActive
                            )
                            let now = ContentView.communityMapFloatingChromeVisible(
                                chromeVisible: chromeVisible,
                                driveModeDefaultEnabled: false
                            )
                            XCTAssertEqual(
                                now, preAddendum3,
                                "flag off: the floating Report pill + \"?\" gate must be " +
                                "byte-identical to the pre-Addendum-3 formula."
                            )
                        }
                    }
                }
            }
        }
    }

    /// Flag off, the rest state is still `.browseNav` — never the More sheet — and the More
    /// sheet has no rest-state/dismiss path of its own (it is only ever assigned by the flag-on
    /// rail's More button).
    func testFlagOff_restStateUnchanged_notMoreMenu() {
        switch driveModeDefaultRestStateSheet(driveModeDefaultEnabled: false) {
        case .browseNav:
            break
        default:
            XCTFail("flag off: rest state must remain .browseNav (Addendum 3 adds no flag-off sheet).")
        }
    }

    /// The shipped (flag-off) default must keep the legacy floating Report pill + "?" layer
    /// renderable: with the real flag value and the base gate satisfied, the layer shows.
    func testFloatingCommunityChrome_defaultFlag_matchesShippedBehavior() {
        XCTAssertEqual(
            ContentView.communityMapFloatingChromeVisible(
                chromeVisible: true,
                driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled
            ),
            !AppConstants.driveModeDefaultEnabled,
            "closes the default-parameter-binding gap for the new gate: wired to the real flag."
        )
    }

    // MARK: - Flag-on: the launched-world assertion this guard test becomes at flip time

    /// The flag-ON branch: once `driveModeDefaultEnabled` flips to `true`, both rest-state
    /// sites must resolve to `nil` — the ambient home screen's genuinely sheet-free rest
    /// state (spec §0.4/§3.1). Written now as a dark-ship guard on a pure function's `true`
    /// branch; at flip time, this is the ready-made launched-world assertion (PR #109
    /// playbook) — no rewrite needed, only the real flag changing.
    func testRestStateSheet_resolvesNil_whenFlagOn() {
        XCTAssertNil(
            driveModeDefaultRestStateSheet(driveModeDefaultEnabled: true),
            "once driveModeDefaultEnabled flips true, both activeSheet's cold-launch default " +
            "and dismissTargetOutsideBrowseNav's rest-state target must resolve to nil — the " +
            "ambient home screen's genuinely sheet-free rest state (spec §0.4)."
        )
    }
}

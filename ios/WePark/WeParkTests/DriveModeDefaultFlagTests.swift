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
    /// has no production code surface yet to assert against — DM-2/DM-3 build that UI in a
    /// later stream. This stream's own contribution to AC-2 is purely negative: DM-1 adds no
    /// new view, no new render path, and no new call site gated on
    /// `driveModeDefaultEnabled` other than the two rest-state sites covered above. Recorded
    /// here, explicitly, so the PR's test inventory doesn't silently omit AC-2 — there is
    /// nothing else to unit-test until DM-2/DM-3 land their views.
    func testFlagOff_noNewUISurfaceIntroducedByDM1() {
        // Documents intent — see doc comment above. Nothing to assert yet.
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

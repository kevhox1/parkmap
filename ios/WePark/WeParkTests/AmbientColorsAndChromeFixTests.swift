//
//  AmbientColorsAndChromeFixTests.swift
//  WeParkTests
//
//  Bundled fix for Kevin's 2026-10-20/21 flag-on simulator smoke of the goal-first ambient
//  screen (`docs/design/goal-first-ambient-design.md` Addendum 2, `docs/drive-mode-default-
//  spec.md` §0.8). Unit tests for this PR's new pure functions in `ContentView.swift`:
//
//    Part A (ambient curb-colors bug):
//      - `ContentView.initialLaunchRegion(driveModeDefaultEnabled:)` — the launch-default
//        `region`'s span, flag-gated (fix 2). Flag off must stay byte-identical to the
//        pre-fix `0.07°/0.05°` span; flag on must land comfortably inside
//        `AppConstants.polylineHideSpanThreshold`'s hide band at the `manhattanCenter`
//        latitude, so a cold launch with no location fix still paints curb colors.
//      - `AppConstants.streetLevelRecenterMeters` — pinned so `recenterMap(on:)` and
//        `initialLaunchRegion` can never silently drift apart.
//      - `ContentView.shouldRebuildOverlaysOnRegionChange(driveModeActive:)` — QA pass 1 fix
//        (🟡 #1): the `!driveModeActive` gate on `handleRegionChanged`'s new `rebuildOverlays(
//        at:)` call (fix 3), restoring Drive Mode's pre-fix repaint economics on its own
//        ~1Hz camera-follow loop while leaving the browse-mode staleness fix intact.
//
//    Part C (escalated-Cruise goal-identity pill, Addendum 2 A2.2):
//      - `ContentView.goalPillContent(for:target:now:)` — icon/short-name/trailing-clause
//        composition for the three goals, including the "never render 'Good through today'"
//        defensive floor and the "reuse ParkUntilSheet.formatTime, don't duplicate it" rule
//        for A Few Hours.
//      - `ContentView.activeGoalForParkUntilPill(selectedGoal:driveModeDefaultEnabled:
//        fullPaletteMode:)` — the decision behind which `ParkUntilPill` slot variant renders
//        (named `GoalParkUntilPill` vs. today's generic pill), including the flag-off and
//        full-palette-mode "always nil" guarantees.
//      - `ContentView.parkUntilConfirmToastMessage(activeGoal:pickedTargetDate:resolvedTarget:
//        now:)` — QA pass 1 fix (🟡 #2): the `ParkUntilSheet.onConfirm` toast, corrected to
//        describe what's ACTUALLY showing (the active goal's resolved target) rather than the
//        just-picked custom time, for the one state (flag on, goal-first, reached via the
//        pre-existing `ArrivalPromptSheet.onParkHere` auto-fire) where the two can disagree.
//
//  NOT covered here (by design, not oversight, verified by code inspection + the mandatory
//  live-UI smoke instead):
//    - `dismissLocationPrimingCard(allowed:)`'s one-line `recenterOnUserAtLaunch = true` fix
//      (fix 1) and `rebuildOverlays`'s DM-2-block-above-the-span-guard reorder (fix 4) are
//      both `private` instance methods on a SwiftUI View struct, not callable from a
//      different test file even under `@testable import` (Swift's `private` is lexically
//      scoped) — same documented limitation `DM3PrimingAuthTests.swift`'s own header already
//      establishes for this file's sibling private methods.
//    - `handleRegionChanged`'s own body (the `if shouldRebuildOverlaysOnRegionChange(...)`
//      call site) — same limitation; the DECISION itself is unit-tested above, the WIRING is
//      verified by code inspection + the live smoke.
//    - The "?" button's new rail position in `recenterButtonStack` and the Report pill's new
//      home inside `GoalSelectorView`'s top row are pure SwiftUI layout — their GATING
//      booleans (`goalSelectorDockVisible`, `AppConstants.driveModeDefaultEnabled`) are
//      already covered by `DM2GoalSelectorTests.swift`/`DriveModeDefaultFlagTests.swift`; no
//      new boolean combination was introduced for either move.
//      (Superseded by Addendum 3: both controls now live in the More sheet; the rail,
//      More-row gating, and floating-chrome suppression are covered by
//      `MinimalAmbientLayoutTests.swift` / `DriveModeDefaultFlagTests.swift`.)
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import MapKit
@testable import WePark

// MARK: - Part A: initialLaunchRegion / streetLevelRecenterMeters

final class InitialLaunchRegionTests: XCTestCase {

    /// Guard test: flag off must be byte-identical to the pre-fix literal span. This is the
    /// exact span the ORIGINAL bug diagnosis pinned as "inside the overlay-hide band" — kept
    /// unchanged for flag-off so the FT-20 browse-sheet default's own launch sequence (which
    /// relies on its own auto-center path to narrow the camera shortly after) is untouched.
    func testFlagOff_matchesPreFixLiteralSpan_byteIdentical() {
        let region = ContentView.initialLaunchRegion(driveModeDefaultEnabled: false)
        XCTAssertEqual(region.span.latitudeDelta, 0.07, accuracy: 0.0001)
        XCTAssertEqual(region.span.longitudeDelta, 0.05, accuracy: 0.0001)
        XCTAssertEqual(region.center.latitude, AppConstants.manhattanCenter.latitude, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, AppConstants.manhattanCenter.longitude, accuracy: 0.0001)
    }

    /// Fix 2's whole point: flag on must land INSIDE `polylineHideSpanThreshold` (0.04°) at
    /// the `manhattanCenter` latitude — a cold launch with no location fix must still paint
    /// curb colors, not rest in the empty-overlay zoom-out band.
    func testFlagOn_spanIsInsideOverlayHideThreshold() {
        let region = ContentView.initialLaunchRegion(driveModeDefaultEnabled: true)
        XCTAssertLessThan(
            region.span.latitudeDelta, AppConstants.polylineHideSpanThreshold,
            "flag-on launch span must be strictly inside the overlay-hide band, or " +
            "rebuildOverlays' zoom guard would assign an empty payload at cold launch."
        )
    }

    /// Flag on must be centered on the same `manhattanCenter` fallback as flag off — this fix
    /// only narrows the SPAN, never relocates the center.
    func testFlagOn_sameCenterAsFlagOff() {
        let flagOn = ContentView.initialLaunchRegion(driveModeDefaultEnabled: true)
        let flagOff = ContentView.initialLaunchRegion(driveModeDefaultEnabled: false)
        XCTAssertEqual(flagOn.center.latitude, flagOff.center.latitude, accuracy: 0.0001)
        XCTAssertEqual(flagOn.center.longitude, flagOff.center.longitude, accuracy: 0.0001)
    }

    /// Flag on must be STRICTLY narrower than flag off in both axes — the actual fix
    /// direction (narrower span fixes the bug; a wider or equal span would not).
    func testFlagOn_isNarrowerThanFlagOff() {
        let flagOn = ContentView.initialLaunchRegion(driveModeDefaultEnabled: true)
        let flagOff = ContentView.initialLaunchRegion(driveModeDefaultEnabled: false)
        XCTAssertLessThan(flagOn.span.latitudeDelta, flagOff.span.latitudeDelta)
        XCTAssertLessThan(flagOn.span.longitudeDelta, flagOff.span.longitudeDelta)
    }

    /// Default parameter resolves to the live `AppConstants.driveModeDefaultEnabled` (today
    /// `false`) — the `@State` property initializer calls this with ZERO arguments, so the
    /// default must track the real flag, not silently diverge from it.
    func testDefaultParameter_tracksLiveFlag() {
        let defaulted = ContentView.initialLaunchRegion()
        let explicit = ContentView.initialLaunchRegion(driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled)
        XCTAssertEqual(defaulted.span.latitudeDelta, explicit.span.latitudeDelta, accuracy: 0.0001)
    }

    /// Pins the shared magnitude `recenterMap(on:)` and `initialLaunchRegion` both derive
    /// from, so the two call sites can never silently drift apart.
    func testStreetLevelRecenterMeters_is400() {
        XCTAssertEqual(AppConstants.streetLevelRecenterMeters, 400)
    }
}

// MARK: - Part C: goalPillContent / activeGoalForParkUntilPill

final class GoalParkUntilPillContentTests: XCTestCase {

    // MARK: - goalPillContent

    func testGoalPillContent_freeOvernight_iconAndShortName() {
        let content = ContentView.goalPillContent(
            for: .freeOvernight,
            target: et(2026, 5, 12, 0, 0),
            now: et(2026, 5, 11, 20, 0)
        )
        XCTAssertEqual(content.icon, "moon.stars.fill")
        XCTAssertEqual(content.shortName, "Overnight")
    }

    func testGoalPillContent_freeOvernight_goodThroughTomorrow() {
        // 2026-05-12 is the day after `now` (2026-05-11) — "Tomorrow" tier.
        let content = ContentView.goalPillContent(
            for: .freeOvernight,
            target: et(2026, 5, 12, 0, 0),
            now: et(2026, 5, 11, 20, 0)
        )
        XCTAssertEqual(content.trailingClause, "Good through tomorrow")
    }

    func testGoalPillContent_freeOvernight_neverRendersGoodThroughToday() {
        // Defensive floor: if `target` somehow lands on the SAME calendar day as `now`
        // (shouldn't happen given every goal's 2-day-or-wider floor), this must still read
        // "tomorrow," never a same-day-sounding "today."
        let content = ContentView.goalPillContent(
            for: .freeOvernight,
            target: et(2026, 5, 11, 23, 0),
            now: et(2026, 5, 11, 9, 0)
        )
        XCTAssertEqual(content.trailingClause, "Good through tomorrow")
    }

    func testGoalPillContent_parkAndForget_iconAndShortNameAndWeekdayTier() {
        // 2026-05-14 is a Thursday, 3 days after Monday 2026-05-11 — "EEE" tier.
        let content = ContentView.goalPillContent(
            for: .parkAndForget,
            target: et(2026, 5, 14, 0, 0),
            now: et(2026, 5, 11, 9, 0)
        )
        XCTAssertEqual(content.icon, "parkingsign.circle.fill")
        XCTAssertEqual(content.shortName, "Park & Forget")
        XCTAssertEqual(content.trailingClause, "Good through Thu")
    }

    func testGoalPillContent_parkAndForget_beyondWeekTier() {
        // 2026-05-25 is 14 days after Monday 2026-05-11 — "MMM d" tier.
        let content = ContentView.goalPillContent(
            for: .parkAndForget,
            target: et(2026, 5, 25, 0, 0),
            now: et(2026, 5, 11, 9, 0)
        )
        XCTAssertEqual(content.trailingClause, "Good through May 25")
    }

    func testGoalPillContent_freeFewHours_iconAndShortName() {
        let content = ContentView.goalPillContent(
            for: .freeFewHours,
            target: et(2026, 5, 11, 14, 45),
            now: et(2026, 5, 11, 11, 45)
        )
        XCTAssertEqual(content.icon, "hourglass")
        XCTAssertEqual(content.shortName, "A Few Hours")
    }

    /// "Do not write a fourth date formatter" — this must be the literal
    /// `ParkUntilSheet.formatTime(_:)` output for a same-day target, prefixed with "until ".
    func testGoalPillContent_freeFewHours_reusesParkUntilSheetFormatTimeUnchanged() {
        let target = et(2026, 5, 11, 14, 45)
        let now = et(2026, 5, 11, 11, 45)
        let content = ContentView.goalPillContent(for: .freeFewHours, target: target, now: now)
        let expected = "until \(ParkUntilSheet.formatTime(target))"
        XCTAssertEqual(content.trailingClause, expected)
    }

    // MARK: - activeGoalForParkUntilPill

    func testActiveGoalForParkUntilPill_flagOff_alwaysNil() {
        XCTAssertNil(
            ContentView.activeGoalForParkUntilPill(
                selectedGoal: .freeOvernight,
                driveModeDefaultEnabled: false,
                fullPaletteMode: false
            ),
            "flag off must render today's generic ParkUntilPill unconditionally."
        )
        XCTAssertNil(
            ContentView.activeGoalForParkUntilPill(
                selectedGoal: .parkAndForget,
                driveModeDefaultEnabled: false,
                fullPaletteMode: true
            )
        )
    }

    func testActiveGoalForParkUntilPill_flagOn_fullPaletteMode_isNil() {
        XCTAssertNil(
            ContentView.activeGoalForParkUntilPill(
                selectedGoal: .freeOvernight,
                driveModeDefaultEnabled: true,
                fullPaletteMode: true
            ),
            "full-palette mode means the power-user ParkUntilSheet path owns the filter — " +
            "the generic pill must render, not the named one."
        )
    }

    func testActiveGoalForParkUntilPill_flagOn_goalFirst_returnsSelectedGoal() {
        for goal: ParkingGoal in [.freeOvernight, .freeFewHours, .parkAndForget] {
            XCTAssertEqual(
                ContentView.activeGoalForParkUntilPill(
                    selectedGoal: goal,
                    driveModeDefaultEnabled: true,
                    fullPaletteMode: false
                ),
                goal,
                "flag on + goal-first mode must surface whichever goal is selected, " +
                "verbatim, for \(goal)."
            )
        }
    }

    // MARK: - Helpers (private to this class — no cross-file XCTestCase extension, matching
    // this codebase's established house style, e.g. `ParkingGoalsTests.swift`'s own header).

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }
}

// MARK: - QA pass 1, 🟡 #1: shouldRebuildOverlaysOnRegionChange

final class ShouldRebuildOverlaysOnRegionChangeTests: XCTestCase {

    /// The actual fix: Drive Mode's own ~1Hz camera-follow loop must NOT re-trigger a full
    /// `rebuildOverlays` on every `regionDidChangeAnimated` callback — this restores Drive
    /// Mode's pre-Part-A-fix-3 repaint economics exactly.
    func testDriveModeActive_doesNotRebuild() {
        XCTAssertFalse(
            ContentView.shouldRebuildOverlaysOnRegionChange(driveModeActive: true),
            "Drive Mode's per-tick camera-follow loop must not trigger a full overlay " +
            "rebuild on every GPS tick — only its own existing triggers (entry rebuild, " +
            "segment-count changes) should repaint during a drive."
        )
    }

    /// The browse-mode staleness fix (Part A fix 3) must stay fully intact outside Drive Mode
    /// — this is the actual bug the fix targets (pinch past the hide threshold and back with
    /// no segment-count change), flag on or off.
    func testDriveModeInactive_rebuilds() {
        XCTAssertTrue(
            ContentView.shouldRebuildOverlaysOnRegionChange(driveModeActive: false),
            "outside Drive Mode, a region change must still trigger rebuildOverlays — this " +
            "is the real fix for the browse-mode stale-repaint bug and must not regress."
        )
    }
}

// MARK: - QA pass 1, 🟡 #2: parkUntilConfirmToastMessage

final class ParkUntilConfirmToastMessageTests: XCTestCase {

    /// `activeGoal == nil` (flag off, or full-palette mode — the sheet's normal, intended
    /// use) must render EXACTLY today's pre-QA-pass-1 toast text, byte-identical — this is
    /// the regression guard for the "zero change to this sheet's normal behavior" claim.
    func testNoActiveGoal_rendersLegacyToastText_byteIdentical() {
        let target = et(2026, 5, 11, 14, 45)
        let message = ContentView.parkUntilConfirmToastMessage(
            activeGoal: nil,
            pickedTargetDate: target,
            resolvedTarget: target,
            now: et(2026, 5, 11, 11, 45)
        )
        let expectedTimeStr = ParkUntilSheet.formatTime(target)
        XCTAssertEqual(message, "Showing blocks free until \(expectedTimeStr)")
    }

    /// `activeGoal == nil` even when `pickedTargetDate` and `resolvedTarget` happen to
    /// differ (shouldn't happen in practice when `activeGoal` is nil, but this confirms the
    /// legacy branch only ever reads `pickedTargetDate`, never `resolvedTarget`).
    func testNoActiveGoal_ignoresResolvedTarget() {
        let picked = et(2026, 5, 11, 14, 45)
        let resolved = et(2026, 5, 12, 9, 0)
        let message = ContentView.parkUntilConfirmToastMessage(
            activeGoal: nil,
            pickedTargetDate: picked,
            resolvedTarget: resolved,
            now: et(2026, 5, 11, 11, 45)
        )
        XCTAssertEqual(message, "Showing blocks free until \(ParkUntilSheet.formatTime(picked))")
    }

    /// The actual fix: `activeGoal != nil` (the `ArrivalPromptSheet.onParkHere` auto-fire,
    /// reachable while flag-on + goal-first) must derive the toast from `resolvedTarget` (what
    /// `rebuildOverlays` just silently restored) via the SAME `goalPillContent` the
    /// `GoalParkUntilPill` itself uses — never from `pickedTargetDate`, which is what the
    /// pre-QA-pass-1 code would have shown and is the exact lie this fix corrects.
    func testActiveGoal_ignoresPickedTargetDate_usesResolvedTargetViaGoalPillContent() {
        let picked = et(2026, 5, 11, 20, 0)        // what the user picked in ParkUntilSheet
        let resolved = et(2026, 5, 12, 0, 0)        // what rebuildOverlays silently restored
        let now = et(2026, 5, 11, 18, 0)
        let message = ContentView.parkUntilConfirmToastMessage(
            activeGoal: .freeOvernight,
            pickedTargetDate: picked,
            resolvedTarget: resolved,
            now: now
        )
        let expectedContent = ContentView.goalPillContent(for: .freeOvernight, target: resolved, now: now)
        XCTAssertEqual(message, "Showing \(expectedContent.shortName) blocks — \(expectedContent.trailingClause)")
        XCTAssertFalse(
            message.contains(ParkUntilSheet.formatTime(picked)),
            "the toast must never describe the just-picked time once a goal has silently " +
            "overridden it — that's the exact bug this fix corrects."
        )
    }

    /// Covers all three goals, confirming the icon/short-name composition flows through
    /// correctly for each, not just the one goal exercised above.
    func testActiveGoal_allThreeGoals_composeCorrectly() {
        let resolved = et(2026, 5, 14, 0, 0)
        let now = et(2026, 5, 11, 9, 0)
        for goal: ParkingGoal in [.freeOvernight, .freeFewHours, .parkAndForget] {
            let message = ContentView.parkUntilConfirmToastMessage(
                activeGoal: goal,
                pickedTargetDate: et(2026, 5, 11, 23, 0),
                resolvedTarget: resolved,
                now: now
            )
            let expectedContent = ContentView.goalPillContent(for: goal, target: resolved, now: now)
            XCTAssertEqual(
                message, "Showing \(expectedContent.shortName) blocks — \(expectedContent.trailingClause)",
                "mismatch for \(goal)."
            )
        }
    }

    // MARK: - Helpers (private to this class — no cross-file XCTestCase extension)

    private func et(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        comps.timeZone = .easternTime
        return Calendar.easternTime.date(from: comps)!
    }
}

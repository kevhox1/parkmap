//
//  DM2GoalSelectorTests.swift
//  WeParkTests
//
//  DM-2 (`docs/drive-mode-default-spec.md` §0.8.6–§0.8.10, §2.1 item 15, §3.3,
//  `docs/design/goal-first-ambient-design.md` §2.1/§2.6/§6) — unit tests for DM-2's own new
//  pure functions in `ContentView.swift`:
//    - `goalSelectorDockVisible` / `goalTileRowVisible` — ambient-dock mount gating
//      (§0.8.7, design doc §6 flag #4).
//    - `parkUntilClockButtonVisible` — the power-user clock icon's new conditional
//      visibility (§0.8.9, design doc §2.6).
//    - `resolveParkAndForgetViewport` — the viewport-wide ladder-rung resolution + the
//      empty-map guard's two states (§0.8.9/§0.8.10, AC-29).
//    - The legacy `ParkUntilPill` suppression condition (design doc §6 flag #1) —
//      `ContentView.bottomSafeAreaContent` gates that row on `!goalTileRowVisible(...)`
//      directly, so its tests below exercise `goalTileRowVisible` itself, not a separate
//      duplicated boolean combination.
//
//  NOT covered here (by design, not oversight): the persistent Search icon
//  (`recenterButtonStack`'s button 2) is gated with a plain, inline `if
//  AppConstants.driveModeDefaultEnabled` at its call site rather than a named pure
//  function — a single-flag-read boolean doesn't carry enough decision logic to warrant
//  extraction (unlike `goalSelectorDockVisible`'s five-input combination). Its absence
//  while the flag is off is verified by code inspection + the mandatory live-UI smoke
//  instead, same disclosure `DriveModeDefaultFlagTests
//  .testFlagOff_noNewUISurfaceIntroducedByDM1`'s own note makes.
//
//  Segment/ParkingRule construction helpers are duplicated from `ParkingGoalsTests.swift`
//  rather than shared via a cross-file XCTestCase extension — same house style this
//  codebase already established (`RuleRow.formatMinutes`'s doc comment) and the same
//  reasoning `ParkingGoalsTests.swift`'s own header documents ("no cross-file XCTestCase
//  extension"). Several reference dates/rule shapes are reused VERBATIM from that file's
//  `ParkingGoals.match(..., goal: .parkAndForget, ...)` tests — `resolveParkAndForgetViewport`
//  is a thin viewport-wide wrapper around the exact same per-segment predicate, so the same
//  worked examples (metered-only / weekend-gap / Tue-Fri-bottom-rung / anytime-no-parking)
//  are the correct fixtures here too.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
@testable import WePark

final class DM2GoalSelectorTests: XCTestCase {

    var engine: ParkingRulesEngine!
    var aspService: ASPSuspensionService!

    override func setUp() {
        super.setUp()
        aspService = ASPSuspensionService()
        engine = ParkingRulesEngine(aspService: aspService)
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

    private func seg(id: String = "DM2_TEST", rules: [ParkingRule]) -> Segment {
        let ruleData = try! JSONEncoder().encode(rules)
        let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
        let segDict: [String: Any] = [
            "id": id,
            "street": "MOTT STREET",
            "from": "GRAND STREET",
            "to": "HESTER STREET",
            "side": "N",
            "line": [[40.7183, -73.9942], [40.7190, -73.9940]],
            "rules": rulesJSON,
        ]
        let data = try! JSONSerialization.data(withJSONObject: segDict)
        return try! JSONDecoder().decode(Segment.self, from: data)
    }

    private func r(
        category: WePark.Category,
        days: [Int],
        timeRanges: [(start: Int, end: Int)] = [],
        anytime: Bool = false
    ) -> ParkingRule {
        let ranges = timeRanges.map { TimeRange(start: $0.start, end: $0.end) }
        let ruleDict: [String: Any] = [
            "category": category.rawValue,
            "description": "",
            "days": days,
            "timeRanges": ranges.map { ["start": $0.start, "end": $0.end] },
            "anytime": anytime,
            "arrow": "both",
        ]
        let data = try! JSONSerialization.data(withJSONObject: ruleDict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    // MARK: - goalSelectorDockVisible (§0.8.7, design doc §6 flag #4)

    func testGoalSelectorDockVisible_trueOnlyWhenFlagOnAndEveryExclusionClear() {
        XCTAssertTrue(goalSelectorDockVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ))
    }

    func testGoalSelectorDockVisible_falseWhenFlagOff() {
        XCTAssertFalse(goalSelectorDockVisible(
            driveModeDefaultEnabled: false, activeSheetIsNil: true,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ))
    }

    func testGoalSelectorDockVisible_falseWhenAnySheetPresented() {
        XCTAssertFalse(goalSelectorDockVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: false,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ), "the dock must hide while ANY sheet (incl. .browseNav from the Search icon) is presented — it must not collide with the FT-20 detent machinery")
    }

    func testGoalSelectorDockVisible_falseDuringDriveModeBlockSelectOrSpotPlacement() {
        XCTAssertFalse(goalSelectorDockVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true,
            driveModeActive: true, blockSelectModeActive: false, spotPlacementActive: false
        ))
        XCTAssertFalse(goalSelectorDockVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true,
            driveModeActive: false, blockSelectModeActive: true, spotPlacementActive: false
        ))
        XCTAssertFalse(goalSelectorDockVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: true
        ))
    }

    // MARK: - goalTileRowVisible (§2.2/§2.4 — dock visible AND not full-palette)

    func testGoalTileRowVisible_trueOnlyWhenDockVisibleAndNotFullPalette() {
        XCTAssertTrue(goalTileRowVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: false,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ))
    }

    func testGoalTileRowVisible_falseWhenFullPaletteModeOn() {
        XCTAssertFalse(goalTileRowVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: true,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ), "design doc §2.4: the goal-tile row hides entirely once toggled to full-palette, even though the dock container itself (toggle + Start Driving) stays mounted")
    }

    func testGoalTileRowVisible_falseWhenDockItselfNotVisible() {
        XCTAssertFalse(goalTileRowVisible(
            driveModeDefaultEnabled: false, activeSheetIsNil: true, fullPaletteMode: false,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        ))
    }

    // MARK: - parkUntilClockButtonVisible (§0.8.9, design doc §2.6)

    func testParkUntilClockButtonVisible_trueWhenFlagOff() {
        XCTAssertTrue(parkUntilClockButtonVisible(driveModeDefaultEnabled: false, fullPaletteMode: false))
        XCTAssertTrue(parkUntilClockButtonVisible(driveModeDefaultEnabled: false, fullPaletteMode: true))
    }

    func testParkUntilClockButtonVisible_hiddenWhenFlagOnAndGoalFirst() {
        XCTAssertFalse(
            parkUntilClockButtonVisible(driveModeDefaultEnabled: true, fullPaletteMode: false),
            "§0.8.9: the power-user ParkUntilSheet clock icon is NOT reachable directly from the goal-first home screen"
        )
    }

    func testParkUntilClockButtonVisible_reappearsInFullPaletteMode() {
        XCTAssertTrue(
            parkUntilClockButtonVisible(driveModeDefaultEnabled: true, fullPaletteMode: true),
            "§0.8.9: toggling to full-palette restores the power-user path exactly as today"
        )
    }

    // MARK: - resolveParkAndForgetViewport (§0.8.9/§0.8.10, AC-29)

    func testResolveParkAndForgetViewport_topRungClears_noStepDown() {
        // Reuses ParkingGoalsTests.testMatch_parkAndForget_clearsTopRung_meteredOnlySegment's
        // fixture verbatim: no weekly move-forcing rule at all.
        let from = et(2026, 6, 4, 10, 0)  // Thursday
        let segment = seg(rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let result = resolveParkAndForgetViewport(segments: [segment], from: from, engine: engine)
        XCTAssertEqual(result, .resolved(offsetDays: 8, steppedDown: false),
                       "a viewport where SOMEONE clears the top rung must resolve to the top rung with no step-down banner")
    }

    func testResolveParkAndForgetViewport_stepsDownToMiddleRung_weekendGap() {
        // Reuses ParkingGoalsTests.testMatch_parkAndForget_clearsMiddleRung_weekendGap's
        // fixture verbatim: ASP_MON_THU, Thursday 10am — clears offsetDays:4, fails :8.
        let from = et(2026, 6, 4, 10, 0)  // Thursday
        let segment = seg(rules: [r(category: .aspMonThu, days: [1, 4], timeRanges: [(420, 570)])])
        let result = resolveParkAndForgetViewport(segments: [segment], from: from, engine: engine)
        XCTAssertEqual(result, .resolved(offsetDays: 4, steppedDown: true),
                       "when nobody in the viewport clears the top rung but someone clears the middle rung, the banner must show (steppedDown == true)")
    }

    func testResolveParkAndForgetViewport_stepsDownToBottomRungOnly() {
        // Reuses ParkingGoalsTests.testMatch_parkAndForget_clearsBottomRungOnly's fixture
        // verbatim: ASP_TUE_FRI, Sunday 10am — clears only offsetDays:2.
        let from = et(2026, 6, 7, 10, 0)  // Sunday
        let segment = seg(rules: [r(category: .aspTueFri, days: [2, 5], timeRanges: [(420, 570)])])
        let result = resolveParkAndForgetViewport(segments: [segment], from: from, engine: engine)
        XCTAssertEqual(result, .resolved(offsetDays: 2, steppedDown: true))
    }

    func testResolveParkAndForgetViewport_empty_whenEvenBottomRungFails() {
        // Reuses ParkingGoalsTests.testMatch_parkAndForget_failsEvenBottomRung_nonMatching's
        // fixture verbatim: NO_PARKING anytime:true.
        let from = et(2026, 6, 4, 10, 0)
        let segment = seg(rules: [r(category: .noParking, days: [], anytime: true)])
        let result = resolveParkAndForgetViewport(segments: [segment], from: from, engine: engine)
        XCTAssertEqual(result, .empty,
                       "AC-29: even the bottom rung returning zero matches must resolve to .empty — the true-worst-case empty-map guard")
    }

    func testResolveParkAndForgetViewport_collectivelyClears_oneGoodSegmentAmongBadOnes() {
        // §0.8.9: "the highest rung the OVERALL VIEWPORT'S segments collectively clear" —
        // one segment clearing the top rung is enough to resolve the whole viewport to the
        // top rung, even if every OTHER loaded segment fails outright.
        let from = et(2026, 6, 4, 10, 0)
        let goodSegment = seg(id: "GOOD", rules: [r(category: .metered, days: [1, 2, 3, 4, 5], timeRanges: [(480, 1320)])])
        let badSegment = seg(id: "BAD", rules: [r(category: .noParking, days: [], anytime: true)])
        let result = resolveParkAndForgetViewport(segments: [badSegment, goodSegment], from: from, engine: engine)
        XCTAssertEqual(result, .resolved(offsetDays: 8, steppedDown: false))
    }

    func testResolveParkAndForgetViewport_emptySegmentsArray_resolvesEmpty() {
        let result = resolveParkAndForgetViewport(segments: [], from: et(2026, 6, 4, 10, 0), engine: engine)
        XCTAssertEqual(result, .empty, "no loaded segments at all must degrade to the true-empty state, never crash or silently resolve a rung")
    }

    // MARK: - Legacy ParkUntilPill suppression (design doc §6 flag #1)

    /// Exercises the EXACT condition `ContentView.bottomSafeAreaContent` evaluates for the
    /// ParkUntilPill row's guard — `!goalTilesVisible`, i.e. `!goalTileRowVisible(...)` —
    /// directly, since this is the exact fix for the double-render bug the design doc's §6
    /// flag #1 names explicitly.
    func testLegacyParkUntilPillSuppression_hiddenWhileGoalTilesShowing() {
        let goalTilesVisible = goalTileRowVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: false,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        )
        let pillVisible = !goalTilesVisible
        XCTAssertFalse(pillVisible, "the legacy pill must be suppressed while the goal-first tiles own the filter-active indicator")
    }

    func testLegacyParkUntilPillSuppression_reappearsInFullPaletteMode() {
        let goalTilesVisible = goalTileRowVisible(
            driveModeDefaultEnabled: true, activeSheetIsNil: true, fullPaletteMode: true,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        )
        let pillVisible = !goalTilesVisible
        XCTAssertTrue(pillVisible, "once toggled to full-palette, the pill resumes its original, unchanged job")
    }

    func testLegacyParkUntilPillSuppression_visibleWhenFlagOff() {
        let goalTilesVisible = goalTileRowVisible(
            driveModeDefaultEnabled: false, activeSheetIsNil: true, fullPaletteMode: false,
            driveModeActive: false, blockSelectModeActive: false, spotPlacementActive: false
        )
        let pillVisible = !goalTilesVisible
        XCTAssertTrue(pillVisible, "AC-1/AC-2: flag off must be byte-identical to pre-DM-2 pill behavior")
    }
}

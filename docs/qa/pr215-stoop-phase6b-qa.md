# PR #215 Stoop Phase 6b QA (Plan a Trip B14, Parking 101 B16, states B18)

**Reviewed:** PR head b2a577bd merged (locally, throwaway branch, never pushed) into origin/main 2b6705b0. Flag `StoopFlag.designSystemV2Enabled` default false.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Results
- Builds: WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities all succeed.
- WePark suite (`-parallel-testing-enabled NO -jobs 4`): 3200 executed, 1 skipped, 0 failures. All 20 StoopPhase6bTests pass. No flakes hit.
- Live trip smoke on the sim: NOT RUN. Mac load was 98 at start and 250+ at the end (other agent), and a live trip view needs a flag-on rebuild. The builder's screenshots in `docs/qa/assets/stoop-phase6b/` were not independently reproduced. The stuck-sheet issue was not reproduced or debugged.
- Release `strings` check for `-wp6bShowcase` / `-wp6bTrip`: NOT re-run. Source check: `WPPhase6bShowcase.swift` is wrapped whole in `#if DEBUG`, and the ContentView mounts sit inside an existing `#if DEBUG` block (~ContentView.swift:3362-3370). Static evidence only.

## Findings

### Significant
- **#1: Trip map green gate is not the same as the Stoop green gate (`WPCurbVerdict.isParkable`)**
  - Where: `ContentView.swift:3046` and `:3057` call `TripPlanning.isFree` (`Services/TripPlanning.swift:~195`), which is `engine.isFree(..., ignoringMeteredPayment: false)` only. `WPCurbVerdict.isParkable` (`DesignSystem/WPMapLogic.swift:52-59`) first applies `hasUnreadableSigns`, which also refuses any curb with an `.unknown`-category rule.
  - What: `isFree` only treats an UNKNOWN rule as restricting when its days/times overlap the window (`ParkingRulesEngine.swift` ~L790-805). A curb with an UNKNOWN rule (plate-only or commercial sign) that does not overlap the visit window is drawn GREEN on the trip map. The live Stoop map draws it red, and the Stoop curb sheet uses `isParkable`, so tapping it would disagree with the map. The no-data case (`hasNoSignData`) and meters-in-window ARE covered, because `isFree` returns false for both. Green nesting is fine, since the trip map is binary green/red.
  - Expected: "unknown/plate-only/commercial = red" (never show a fake spot), and the PR's own header claim in `WPTripPlannerV2.swift:14-15` that the verdict is "the SAME green gate as every live goal".
  - Not verified live. Mostly pre-existing trip code, but the PR puts it under the Stoop "Green curbs are free for your whole trip" card.
  - Fix suggestion: have the trip branch use `WPCurbVerdict.isParkable(from: arrival, until: departure)` when Stoop is on. Add a test with an UNKNOWN rule outside the window.
  - Owner: `@ios-engineer`
- **#2: `planTripEnabled` is `false`** (`Services/Constants.swift:273`, unchanged). The planner and trip map are unreachable in production even with Stoop on. This is not a defect (the gating is unchanged), but it means the new trip UI ships dark. Noted so nobody assumes B14 is live.

### Minor
- **#3: Test coverage of "live actions hidden" is helper-level only.** `StoopPhase6bTests` pins `TripModeGating` and `WPTripChrome`, not that ContentView actually consumes them. I verified by reading that the wiring exists: Report pill (ContentView 3583, 3821), Spot Pass (2263, 2321, 2350), live ASP banner (3253), goal dock `tripPlan == nil` (4268), park-my-car (4494), resting token (4721), Park Until (4338), drive default (2968), live actions (7763). Not run live.
- **#4: `v2PlaceCarAtUser`** (ContentView ~4727, VoiceOver and accessibility-size "Park my car" row) has no explicit `tripPlan == nil` guard. Its entry points are hidden during a trip (4494, 4721), so it is likely unreachable. Worth a one-line guard.
- **#5:** The Parking 101 Rookie Mistakes bullets keep an amber `ParkingColors.restrictionComingSoon` icon under Stoop. It is a small decorative glyph on a red/green-only map. Nit.

### Out of scope
- Search sheet stuck at the large detent with the keyboard (separate investigation, not touched).

## Checks against the brief

1. **Plan a Trip.**
   - Validation reuses `TripPlanning.validate` (past, end not after start, more than 7 days). The CTA is disabled via `primaryDisabled`, and the inline problem box names the offending row.
   - Not-live signals: tag ("TRIP PLAN · NOT LIVE", `WPTripTopTag`), dashed frame (`wpTripFrame`, Stoop-only via `WPTripChrome.showsPlanFrame`), a card titled "...free for your whole trip, until", and the caveat on both planner and card. Live controls are gated as listed in #3.
   - No-calendar notice: it is driven by `aspService.calendarCovers(date)`, which is true only when the date's ET year equals `coveredYear` (nil gives false). The "Holiday changes for YYYY aren't out yet" copy is therefore accurate. The year shown is the first uncovered end, and the notice shows if either end is uncovered. This is equivalent to the legacy `TripPlanning.calendarCovers`.
   - "Back to live map" calls `exitTripPlan()`, which sets `tripPlan = nil` and rebuilds overlays. The tag, frame and card are all keyed on `tripPlan`, so they disappear together. A trip that has ended auto-exits with a toast (unchanged).
   - Green gate: see #1. The 7-day cap and the 2-minute arrival grace are unchanged.
2. **Parking 101.**
   - I diffed every string literal of 12+ characters across the ParkingGuide files. Every old string reappears unchanged, only wrapped in `GuideText`.
   - New strings: "The sign on the street always wins." (consistent with the existing "most restrictive wins") and "Put together: ..." (a doc-comment example only, not UI).
   - Flag-off `GuideText` branches reproduce the old fonts and colors (`subheadline`, `.secondary`, `.caption`). `wpGuideCard` is a no-op flag-off. `navigationBarTitleDisplayMode` is `.large` flag-off.
   - The legend is hidden only in Stoop (`ParkingGuideSection.visible`). Nothing else references `ColorLegendSectionView` except the Map Key, which has its own legend (comment only). The existing FT12 test pins `allCases` order.
   - Mild caveat: the pitch copy still says "color-coded map". It is fine under red/green.
3. **B18 states.**
   - `WPBlockingStateScreen`, `WPNoCurbsCard` and the `WPStateCopy` server, account, noLocation, outside and noCar copy are referenced only from `WPPhase6bShowcase` (DEBUG) and tests. They are not mounted in production, so there are no wrong-state paths. Confirmed by grep.
   - The only mounted pieces are the trip planner, tag and card, and the Parking 101 restyle.
   - The no-curbs copy avoids the word "free" (tested).
4. **`primaryDisabled`**: default false, `.disabled(false)` is a no-op. Inert for existing callers. The only new caller is `WPTripPlannerV2`.
5. **DEBUG args**: see Results. `#if DEBUG`-wrapped in source; Release strings check not re-run.
6. **Flag-off identical to main**: ContentView diff branches on `AppConstants.designSystemV2Enabled`. The else branches are the verbatim old code (TripPlannerSheet with the same args, TripPlanBanner). The tag and frame are Stoop-only. Full suite 0 failures flag-off. Pixel-level flag-off not re-screenshotted.
7. **Stuck sheet**: not reached (no live smoke).

## What's working
- The pure-logic split (`WPPhase6bLogic`) is testable, and the copy is concrete and honest (the no-curbs card refuses to imply free).
- The flag-off preservation is careful, including the Dynamic Type stacked layout, which applies only for Stoop at AX sizes.
- No new rules were added to the Parking 101 copy.

## Verdict: MERGE-WITH-FOLLOWUPS
Follow up on #1 before `planTripEnabled` is turned on. #1 is a flag-on-only, dark-feature divergence, so it is not a merge blocker today.

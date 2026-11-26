# PR #218 QA: Plan a Trip uses the live green gate (2026-11-26)

**Reviewed:** `fix/trip-map-green-gate` at `791daea7`, also merged with #217 onto origin/main `7d09b992` (throwaway local branch, no merge pushed). Source finding: `docs/qa/pr215-stoop-phase6b-qa.md` Significant #1.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
With Stoop on, the trip map overlay, the selected-block highlight and the BlockDetail trip verdict all route through `WPCurbVerdict.isParkable` via `TripPlanning.isFree(strictSigns:)`. An UNKNOWN rule outside the visit window is now red with "Unclear sign" copy. Flag-off is unchanged by construction (default `false`, same `engine.isFree` call and args). The only follow-up is the legacy-mode inconsistency the PR itself flags.

## Checks
- [x] 3 ContentView call sites pass `AppConstants.designSystemV2Enabled`: `ContentView.swift:2719` (verdict), `:3049` (overlay loop), `:3063` (selected highlight). One further caller omits the parameter: `ios/WePark/WePark/DesignSystem/WPCurbSheetLogic.swift:143`, which is safe: it checks `WPCurbVerdict.hasUnreadableSigns` first (line 133) and returns the red plan variant before calling `verdict`, and that builder is Stoop-only. Strict-vs-lax would only differ for unreadable curbs, already handled.
- [x] Other trip paths: `TripPlanning.firstConflict` (`TripPlanning.swift:253`) uses `engine.isFree` directly but is only reached from `verdict` after the strict unreadable short-circuit, so it only names reasons for readable curbs. No trip counts or summaries use the gate (`bannerLine`, `calendarCovers`, `quickPick` do not classify curbs). Verdict text "Unclear sign" / "No sign data" via `UnclearSign.headline` / `NoSignData.headline` when strict.
- [x] Green nests: strict only adds a refusal to `engine.isFree`; longer visit only removes green (test `testStrictGate_normalFreeCurb_staysGreen_andLongerVisitOnlyRemovesGreen`).
- [x] `tripFreeCache` key (`ContentView.swift:3043`) does not include the flag, but `designSystemV2Enabled` is a compile-time `static let`, so no staleness.
- [x] `v2PlaceCarAtUser` (`ContentView.swift:4739`) returns false when `tripPlan != nil`.
- [x] Flag-off byte-identical: `strictSigns` defaults to false; the false branch is the original `engine.isFree(..., ignoringMeteredPayment: false)`; `verdict` guard is `strictSigns && ...`.
- [x] Tests: UNKNOWN-outside-window (strict red, legacy green pinned), overlapping UNKNOWN (red both), no-data (both modes, plus headline), meter-in-window (both modes), normal free curb + longer visit. Mutation (strict branches forced off): `testStrictGate_unknownRuleOutsideWindow_isNotGreen` and `testStrictGate_noData_andMeterInWindow_remainNotFree` fail; the other three are legacy/regression guards and correctly pass.
- [x] 4 scheme builds on the combined merge: all succeed.
- [x] Full WePark suite, `-parallel-testing-enabled NO -jobs 4`, combined merge: 3210 tests, 1 skipped, 0 failures. No known flake tripped.

## Findings
### Blocking
none
### Significant
none
### Minor / follow-up
- **#1: Legacy (flag-off) trip map still shows a non-overlapping UNKNOWN rule green.** `ios/WePark/WePark/Services/TripPlanning.swift:198` legacy branch. Deliberate (matches the legacy live map) and flag-off is not shipping, but Kevin's "unknown = red" rule is not satisfied there. Follow-up one-liner per site if the flag-off design is ever shipped again. Owner `@ios-engineer`.
- **#2: Stale test comment risk.** `TripPlanning.firstConflict` still uses lax `engine.isFree` for reason text; safe today only because `verdict` short-circuits unreadable curbs first. If someone later calls `firstConflict` elsewhere, it would name no reason for an UNKNOWN outside the window. Add a comment. Owner `@ios-engineer`.

## Live trip smoke (ran, flag on)
Local-only flips (`StoopFlag.designSystemV2Enabled`, `planTripEnabled`, `driveModeDefaultEnabled` = true), built, installed on a private sim, location set near Washington Sq, planned "This weekend" (Sat 11/28 10 AM to Sun 11/29 6 PM). Screenshots read:
- Violet "TRIP PLAN . NOT LIVE / Sat 11/28 10 AM to Sun 11/29 6 PM" tag, dashed violet frame, and the card "Green curbs are free for your whole trip, until Sun 6 PM / From Sat 10 AM . 32 hours" with Change dates / Back to live map.
- Live toolbar (search, More, Locate me, goal dock, ASP banner) hidden while the plan shows.
- Tapping a red curb opened the sheet "Not free for your trip / No standing the whole trip" with the plan tag; no Park here / Report actions.
- Not verified live: a red curb whose cause is an unclear sign (none found in this viewport). Covered by unit tests only. Flags reverted, nothing committed from the flips.

## Verdict: MERGE-WITH-FOLLOWUPS

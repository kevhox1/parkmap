# PR #201 Stoop Phase 3 Drive Mode (B5) QA — 2026-11-26

**Reviewed:** branch `feat/ds-phase3-drive` at `9e5c1894`, against DECISIONS.md and round-2 B5 mocks
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The side verdict logic is correct and agrees with the map gate; flag-off behavior is untouched. Merged with current main (#200) cleanly: build succeeds and the full suite passes. One real gap: at AX5 the drive card clips the "Free until ..." text and hides the right side behind a scroll with no cue, and the top chrome sits under the status bar. This is behind two flags, so ship-with-followup.

## Rebase / merge
GitHub: MERGEABLE (state UNSTABLE, no required checks run). `git merge origin/main` locally: automatic, no conflicts (ContentView auto-merged). Tested the merged result (merge aborted afterwards, nothing pushed). No rebase required.

## Checklist
- [x] 1. Side verdict = map gate. `WPDriveVerdict.side` only returns `.park` when `override == .free` AND the label reads free (or metered with override .free). `override` comes from `goalAwareChip(strictParkable: AppConstants.designSystemV2Enabled)`, which uses `WPCurbVerdict.isParkable` (refuses unreadable signs, then `engine.isFree(... ignoringMeteredPayment: false)`). Meter running in window: override restricted -> `.meter`; meter outside window: override free -> park (as the map draws). No-data/Unclear/UNKNOWN/empty/non-"Free" text checked first and never park. No goal window (override nil) -> "Free now", never green. Tests `testSide_everyCombination...`, `testGoalAwareChip_strict_agreesWithIsParkable...` pass.
- [x] Flag-off byte-identical: `strictParkable` defaults false and the call site passes `designSystemV2Enabled`, so flag off takes the original `engine.isFree` branch. Note: with `designSystemV2Enabled` on but `driveModeDefaultEnabled` off, the LEGACY drive card also gets the stricter gate (a safe direction, matches the map; just not "flag on + goal-first only" as the comments say).
- [x] 2. Left/right not re-derived: uses `context.leftLabel/rightLabel` and overrides from `DrivingContextService` (`DriveSideAssignment`). Spelled out "LEFT SIDE"/"RIGHT SIDE", also in the VoiceOver sentence.
- [x] 3. Raised yellow Park here only if a side is `.park` (`Primary.isRaised`); otherwise white "Park here anyway" / "Park here" while checking. Tested.
- [x] 4. Tint added/removed only in `applyDriveMapStyle` (MapViewRepresentable.swift ~1540), existing tints removed first (no leak across repeated start/end or the double `applyDriveMapStyle(true,nil)` calls), removed when `active == false`. Inserted at index 0 of `.aboveRoads`; curb overlays are added later via `addOverlay` so they draw above. `rescaleCurbLines` skips it. Not verified live on a real drive (see below).
- [x] 5. `driveReportTapped()` / `driveParkHereTapped()` diffed against main: bodies identical, only `guard` returns now exit the function instead of the button closure. Arrival `onParkHere`/`onNotYet` extracted to lets unchanged.
- [~] 6. AX5: see finding #1.
- [x] 7. `-wp3Showcase`: `WPPhase3Showcase.swift` wrapped entirely in `#if DEBUG`; the only reference (ContentView ~3219) is inside `#if DEBUG`. Not verified in a built Release binary (machine load ~100-290); source inspection only.
- [x] 8. Full suite run by me on merged result.

## Findings

### Significant
- **#1: AX5 drive card clips critical info; top chrome under status bar**
  - Where: `WPDriveV2.swift` `WPFitScroll` (maxHeight 0.46 of screen), `WPDriveSideCard`, `WPDriveTopChromeV2`; ContentView `v2DriveTopChrome` top padding.
  - What: At accessibility-xxx-large (builder shots `b5-both-ax5.png`, `b5-nodata-ax5.png`, and I reproduced it on my own sim with `-wp3Showcase both`): the street pill starts under the status bar/Dynamic Island, the green LEFT card is cut mid-text at "9:00 AM", and the RIGHT side card is entirely off-screen with `showsIndicators: false`, so a driver has no cue it exists. Right-side verdict is critical for a driver.
  - Expected: Dynamic Type through AX5 without truncating critical information.
  - Suggested: Reduce the green card's sub-line scale or cap Park big text at AX sizes, show scroll indicators, and push the top chrome below the safe area. Not blocking: opt-in behind two flags, defaults off; no wrong verdict is shown.
  - Owner: `@ios-engineer`
- **#2 (minor-significant): `b5-nodata-ax5.png` shows a green Park card on "2nd Ave", not a no-data state.** The screenshot does not demonstrate the AX5 no-data layout it is named for; right side never visible in either AX5 shot.
  - Owner: `@ios-engineer`

### Minor
- Legacy drive card with `designSystemV2Enabled` alone also gets `strictParkable` (see item 1); comment says flag-on-and-goal-first only.
- Tint box is hard-coded to NYC bounds (40.2-41.2, -74.5 to -73.4); outside NYC no tint (harmless).

### Out of scope
- Not verified: a real live drive with flags flipped (tint under curb lines on a moving map). I did not rebuild with flags on given load; recommend the human live smoke the tint/curb-line ordering and arrival prompt before enabling flags.

## Smoke tests run
- `gh pr view 201`: MERGEABLE. Local merge with origin/main: clean.
- `xcodebuild build-for-testing` scheme WePark on merged result: **TEST BUILD SUCCEEDED**. WeParkClip, ClipLiveActivities and WeParkLiveActivities compile as embedded dependencies of the WePark scheme in the same log (all built, no errors); they were not built as standalone schemes.
- Full WePark suite (`-parallel-testing-enabled NO -jobs 4`): **3045 tests, 1 skipped, 0 failures** (merged result, includes the 20 new `Phase3DriveTests`). No flakes hit.
- Sim launch with `-wp3Showcase both` at AX5 on a fresh sim (screenshot read): reproduces the builder's AX5 clipping (a location permission alert overlaid it, but layout was visible).
- Read builder screenshots `b5-both-ax5.png`, `b5-nodata-ax5.png`.
- Compile-failure classes: new test uses `WePark.Category`; no `SWIFT_ACTIVE_COMPILATION_CONDITIONS`; `nonisolated` statics used throughout WPDriveLogic. No issues.

## What's working
Verdict mapping is conservative, exhaustively tested against the map gate, spells sides in words; action bodies extracted verbatim; tint lifecycle tidy; showcase correctly DEBUG-only; clean merge with #200.

**Final: MERGE-WITH-FOLLOWUPS**

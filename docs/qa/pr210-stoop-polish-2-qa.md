# PR #210 Stoop polish batch 2 QA, 2026-11-26

**Reviewed:** `fix/stoop-polish-2` at `063cb5b6` (main d24a997b merged in), against `docs/qa/pr206-stoop-followups-qa.md` and `docs/qa/pr207-stoop-phase5a-spotpass-qa.md`
**Verdict:** MERGE-WITH-FOLLOWUPS (no blockers)

## Summary
All 10 items are implemented as described and flag-off paths are untouched (the only non-V2 edit is the `ContentView` detents line, gated on `v2DriveActive`). On a throwaway merge of origin/main + #210 + #211: all 4 schemes build, full WePark suite 3135 tests, 1 skipped, 0 failures (`-parallel-testing-enabled NO -jobs 4`, iPhone SE 3rd gen, iOS 26.5; no known flakes hit). Flag-on live smoke on SE (flag flipped locally, reverted) confirmed the fixes. I did not run the suite on #210 alone (load); the merge result contains it with no conflicts.

## Checklist
- [x] 1 Arrival prompt AX: SE at AX1/AX3/AX5 (my own run of `-wp3Showcase arrive`): heading, LEFT SIDE "Park until Mon 9:00 AM", RIGHT SIDE "No parking", "Park here" and "Keep looking" all visible with ~100 px spare, no scroll. AX3/AX5 render identically to AX1 because `maxDriveTypeSize` caps SE at AX1 (by design, pre-existing). The stand-in (0.9 screen height) is conservative: a real `.large` detent is roughly full height minus the safe area, taller than the stand-in. Detents come from `WPArrivalPromptV2.detents` and are swapped only when `v2DriveActive`; non-v2 stays `[.medium]`. Pro Max not re-shot by me (SE is the tight case).
- [x] 2 "Park · meter not running": emitted only when `side.sub` starts "No meter running", which `WPDriveVerdict.side` produces only for `.metered` with `override == .free` (goal window clears meter hours). Accurate for the selected window.
- [x] 3 My Car `.unknown`: `resolve` returns `.unknown` only for nil status and not muted; `offLine`, `reminderSummary` and row sub promise nothing ("Checking notifications"); `scenePhase == .active` re-reads. `.notDetermined`/`.provisional` still `.on` (unchanged).
- [x] 4 `showsLeavingSoonCard`: variant param removed, call site updated, compiles.
- [x] 5 Leave-time sheet AX: SE AX5 shows 5 single-line rows plus pinned "Use 6:15 AM" (screenshot inspected). Type capped at AX3; full-height detent at AX.
- [x] 6 Seeker intro AX5 on SE: "They won't see who you are or where you are." above the fold, "Make a pass" pinned (screenshot inspected).
- [x] 7 Dark ink pill: lifted fill + line + cream label. Live on SE: Spot Pass done (dark), leave-time "Use" (dark), search "Drive here" (dark, real flow) all readable. Light "Done" unchanged (ink fill, white label). Palette test pins contrast.
- [x] 8 Departed card and pull title: "Your neighbor is" lead-in removed (subtitle carries it once); `pullTitle` tracks the countdown.
- [x] 9 Slots recompute each minute and on appear; `stillOffered` un-chooses a stale slot. See finding 2 for the residual window.
- [x] 10 Replaced screenshots present.

Style scope: `InkPillButtonStyle`/`WPCoachNextStyle`/`WPLeverButtonStyle` are not referenced from `Clip/`, `ClipLiveActivities/`, `WeParkLiveActivities/` or the clip screens (which use `WPClipPrimaryButton`), so clip/activities are unaffected. The `WPScreenScaffold` cap applies only to the pinned bottom bar (primary/secondary buttons), not content; scaffold is used only by Spot Pass seeker/driver screens and the gallery. No critical info hidden; buttons stay accessibility-sized and wrap.

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1 (minor) Not live-verified:** map "Start driving", lever "Done", coach "Next" in dark, and the Settings round-trip refresh on My Car. They share the unit-tested `Palette.resolve`, so risk is low. The real arrival sheet (versus the stand-in) was not shot. Owner `@ios-engineer`.
- **#2 (minor) `ios/WePark/WePark/Views/SpotPass/Driver/WPSpotPassDriverV2.swift` (choosing screen):** the stale-slot fix covers only the picker sheet. A custom time chosen earlier and left on the choosing screen keeps its "around 4:15" label after 4:15 passes; the send is still clamped to now (`LeaveChoice.leaveAt` uses `max(picked, now)`), so a past time is never sent, but the label can disagree with what is sent. The sheet ticker is also anchored to sheet-open time, so for up to ~60 s after a slot passes it can still be chosen (then clamped). Owner `@ios-engineer`.
- **#3 (minor) `WPScreenParts.swift` / `WPSpotPassSeekerV2.swift`:** the intro caps content type at AX1 (SE) / AX2, so "through AX5" is honored only as the existing drive-style cap. Nothing truncates; matches the arrival/drive precedent.

## Smoke tests run
- Build: WePark (build-for-testing), WeParkClip, ClipLiveActivities, WeParkLiveActivities all succeeded on the combined merge.
- Full suite on combined merge: 3135 executed, 1 skipped, 0 failures.
- Flag-on (local flip, reverted before commit): showcases arrive AX1/3/5, intro AX5, pick AX5 and dark, done dark and light, leaving dark; live app search flow to "Drive here" in dark. Screenshots read and inspected.
- Flag-off identical: diff review shows flag-off code untouched; suite passes flag-off.

## What's working
The arrival sheet at AX shows a complete decision with room to spare. The privacy promise now leads the seeker intro at AX. The dark pill palette is a clean shared, tested fix.

**MERGE-WITH-FOLLOWUPS** (findings 1-3 are polish).

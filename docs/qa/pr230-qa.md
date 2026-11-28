# PR #230 (R35 PR2b zoom-out follow-ups) QA - 2026-11-28

**Reviewed:** branch `ios/r35-pr2b-zoomout-followups` at `02908927`, against main `04ece88b`.
**Verdict:** PASS with follow-ups (code review + full suite + merge dry-runs; the lag numbers and the live zoom flows were NOT measured, see below).

## What I could and could not do
The Mac 1-minute load was 160-350 for almost the whole session (dipping to 27-35 for under a minute twice). Per the rules I did not measure lag or drive the live zoom flows under that load: the numbers would be meaningless, and a main-vs-PR comparison needs two builds plus gestures. Item 1 (lag) and the live parts of items 2-5 are therefore **not verified live**. Everything marked "code" is a diff read only.

## Results by item
1. **Lag - NOT MEASURED.** Code: with the band `.off`, `rebuildOverlays` now skips `resolveForDaysManual`, the 3-rung Auto ladder and the `.parkAndForget` ladder/fallback count. That is exactly the cost PR #227 QA (finding 1) blamed for the 0.7-0.9 s settle, so the fix targets the right place. Device confirmation needed. Zoom-back-in cost: the first rebuild after zoom in runs the ladder once on loaded tiles (same as before the PR for that step); not measured.
2. **Honesty (code).**
   - Zoomed out: `headlineEnd` and `tileUntil` return an em dash for every goal, `lead` is "Zoom in to see which curbs are free", and the countdown `sub` is nil. No end/date/countdown path remains in the dock. The pill keeps the existing "Zoom in to see parking".
   - Zoom in recomputes: `forDaysState` and `forDaysResolution` are nil while off, so the next rebuild runs the ladder fresh; nothing carries from the last close-in state. Pan far then zoom in: stale state is already dropped, so the headline cannot describe the old area.
   - Manual pick: `forDaysPick` is stored separately and passed to the dock while zoomed out (picker shows the pick, not Auto); `resolveForDaysManual` rebuilds `forDaysState` from it on zoom in. Plausible; not driven live.
3. **Loading pill (code).** `hasPendingTile(atCenter:)` is false when no tile exists under the centre (water / no data), so no stuck pill; true only when a tile exists and is not loaded. Not driven live. It probes only the centre tile, so a view with a loaded centre tile but unloaded edges shows no pill (minor).
4. **Selected curb width (code).** `styleSelectedLine` uses `applyZoomBand` (dash correction) when not in Drive Mode, in both the create and restyle paths. Not pixel-measured.
5. **Drive Mode (code).** `compensateDash: !parent.driveModeActive` keeps the old `apply` path in Drive Mode. `goalClockNow` is `windowInstant` only with Stoop on; flag off is still `lastEvaluatedAt`. NOT verified live; the minute-boundary countdown was not driven. Note: in Stoop the legacy Drive Mode pill and `goalWindowLabel` now count from `windowInstant` (5-minute grid), so a countdown there may tick every 5 minutes, not every minute. Consistent with the end, but confirm it is intended.
6. **Full suite.** `WeParkTests`, shipped flags, fresh sim, `-parallel-testing-enabled NO -jobs 4`, started at load under 40: **3431 tests, 1 skipped, 0 failures, TEST SUCCEEDED.** None of the known flakes fired. The 8 new `WPZoomOutFollowUpTests` pass.
7. **Merge check.** `git merge --no-commit --no-ff` of the PR head with latest `origin/main` (already up to date), #228 `ios/dt35-6b-drive-stack-ax` (clean) and #229 `ios/dt35-3-nudge-trap` (clean, auto-merged `ContentView.swift`). Not re-compiled after the merges.

## Findings
- **#1 (significant, process):** the lag fix was not measured by me. It needs a device or quiet-Mac run before it is called done.
- **#2 (minor):** the PR text lists "signature guard skips the overlay swap at the 5-minute flip"; I found no such change in this diff against main (likely already in #225). Not checked further.
- **#3 (minor):** legacy Drive Mode pill ticking follows the 5-minute grid in Stoop (item 5). Confirm intended.
- **#4 (minor):** loading pill considers only the centre tile (item 3).

## What's working
Small, targeted diff; stale state is dropped rather than hidden; the copy never claims an end while nothing is computed; the 3431-test suite is green; both open PRs merge textually clean.

## Cleanup
Sim `wepark-qa230-sim` and `~/Library/Caches/wepark-qa230-dd` deleted.

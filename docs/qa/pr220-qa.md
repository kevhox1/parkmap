# PR #220 QA (DT35-1 For-days "Free until" picker)

**Reviewed:** branch `ios/for-days-free-until` at `deff3047`, against `docs/specs/dt35-park-flow-and-drive-fixes.md` (PR4) and `docs/field-testing-log.md` DT35-1.
**Verdict:** PASS with follow-ups (1 significant, 2 minor, 0 blocking).

## Summary
Fallback logic is honest: the map and headline are driven by the effective end only, the binary search is correct, DST is handled and tested, and the full suite is clean with shipped flags. One spec criterion does not work through the UI: the "Overnight already covers this" clamp note never appears, because the picker pre-clamps before the caller sees the pick.

## Must-dos
1. Full `WeParkTests`, shipped flags (all off), PR head: **3257 tests, 1 skipped, 0 failures**. No flakes hit.
2. Flags flipped (`StoopFlag.designSystemV2Enabled` and `AppConstants.driveModeDefaultEnabled` = true, local only): PR full suite gives 29 failures across 14 classes. I reran the same 14 classes on `main` (`46f3cf78`, the PR base) with the same flip: 29 failures, and the sorted failing test-name list is **identical** to the PR's. Not caused by this PR.
3. Logic review (see below): honest.
4. Smoke on own sim (iPhone 17 Pro, iOS 26.5, flags flipped locally, location 40.7128,-74.0060): see below.
5. `ContentView.swift` diff: all edits are For-days only. Every new path is behind `AppConstants.designSystemV2Enabled` or `forDaysState != nil`; Auto falls through to the untouched ladder code. The foreground reset is guarded by the flag. Flag-off behaviour unchanged (suite passes with flags off).

## Logic review
- Green uses the shown end: `parkUntilTarget = manual.effective`; `v2GoalInput.daysEnd = manual.effective`. `requested` is only used for the banner title and the row's "You asked for". PASS.
- Binary search: requested clear gives no banner. `requestedIndex == 0` and not clear gives `.empty`. Otherwise invariant lo clear / hi not clear, terminates at hi-lo==1. Relies on monotonicity (covered by `testMonotonic_clearCountNeverRisesAsTheEndMovesLater`). PASS.
- Nesting: `grid[0]` is the Overnight end (same `morningHour`), result is never below it. Live: Today 9 AM clamped to Sat 7 AM and the map showed the Overnight green. PASS.
- DST: grid skips missing slots on spring-forward, single entry on fall-back; tests at `ForDaysUntilTests` lines 139 and 149. PASS (tests only, not run on a real DST date).
- Stale pick: reset on first rebuild after launch (`forDaysPickChecked`) and in the foreground handler; minimum moving past the pick re-bumps on every rebuild. PASS by code and unit tests; not exercised live across a foreground.
- Pan: `resolveForDaysManual` runs on every rebuild, state is recomputed from tiles, no cached fallback. Covered by `testPan_switchesBetweenFallbackAndRequested_withNoStaleState`. Not panned live.

## Findings

### Significant
- **#1: Clamp note is unreachable from the UI.**
  - Where: `WPForDaysPickerV2.swift` day chips / quick chips call `ForDaysUntil.retarget` / `quick` (which already `snap`), then pass only the date to `onPick`; `ContentView.setForDaysUntil` snaps again, gets `clamped == false`, so `forDaysClampNote = false`. The stepper's minus is disabled at the minimum, so no other path.
  - Expected: spec AC "Picking earlier than the Overnight end clamps up and says why".
  - Repro: Stoop on, For days, Change, pick Today then 9 AM (Overnight ends 7 AM tomorrow). Value becomes "Sat 7 AM", the clamp is correct and nesting holds, but no "Overnight already covers this" text appears. Screenshot: `docs/screenshots/dt35-1-qa/clamp-no-note.png`.
  - Impact: safe (never more green than Overnight, value visibly moves), but the user is not told why. Only the "minimum moved past an existing pick" path can show the note.
  - Owner: `@ios-engineer`. Suggested fix: have `onPick` carry the `clamped` bool, or skip the pre-snap in the chip handlers.

### Minor
- **#2:** `restoredPick` uses `date > minEnd`, so a pick equal to the Overnight end (a valid, clamped choice) silently resets to Auto on the next launch/foreground. Harmless (Auto is never more green than Overnight) but the user's pick disappears. Owner `@ios-engineer`.
- **#3:** The "Tomorrow" day chip renders in a visibly smaller font than its siblings at default size (single-line shrink). Cosmetic.

### Out of scope / not verified
- At AX5 the "Street cleaning in effect today" pill overflows and overlaps its box (see `ax5-top.png`). It is not touched by this PR's diff; I did not confirm it also happens on `main`.
- Banner at AX5 and the empty-banner state were not independently reproduced; I relied on the builder's screenshots and `ForDaysFallbackTests` for those.
- Downtown test location (street cleaning today) had little green, so I did not see a fallback with a rich map behind it.

## Smoke tests run (own sim, flags flipped locally, reverted before commit)
- For days tile, Free until row ("Auto"), Change opens picker: day chips, 72 pt stepper, quick chips, Auto, Done all render, big targets.
- Picked Tue + Midnight: banner "Nothing nearby is free until midnight Tue night. Best nearby: free until Tue 11:30 AM. Only a few curbs." and the headline reads "Tue 12/1, 11:30 AM". Banner and headline match the fallback end (`fallback-banner.png`).
- Picked Tue 9 AM: no banner, headline "Tue 12/1, 9 AM". Consistent.
- Picked Today 9 AM: clamps to Sat 7 AM, headline matches Overnight end, minus disabled, green appears on the map; no note (finding #1).
- AX5 (accessibility-extra-extra-extra-large): day chips become a full-width stack, the picker scrolls, the stepper is reachable by scrolling and shows as - / + under the value, Done stays pinned (`ax5-top.png`, `ax5-stepper-scrolled.png`).
- VoiceOver labels via AXe tree: stepper "Free until" with value, "30 minutes earlier", "30 minutes later", chips "7 AM", "9 AM", "12 PM", "5 PM". The row also reads label plus value.

## What's working
Single source of truth for the shown end, clean binary search with the empty and edge cases handled, good test coverage (DST, monotonicity, pan), reuse of existing banner/chip styles, all flag-gated.

## For Kevin on a real device
- Pick a far end on a block with lots of green and watch the banner, headline and green extent agree; pan to a sparser block and back.
- Background the app past the Overnight end and reopen: pick should reset to Auto.
- AX5 on a real phone: reach the stepper and Done with one thumb.
- VoiceOver: swipe the "Free until" value up/down to step.

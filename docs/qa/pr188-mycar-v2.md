# PR #188 QA: My Car sheet v2 (flag `myCarSheetV2Enabled`)

**Reviewed:** branch `feat/mycar-sheet-v2` at `2ae824d4`, iPhone 17 sim (iOS 26.5), 2026-11-24 ~10:30-10:45 PM ET (Tuesday), against the PR description and the owner brief.
**Verdict:** MERGE-WITH-FOLLOWUPS (ships dark; no blocking findings. Two significant items to fix before the flag is turned on.)

## Summary
The v2 sheet delivers the "less going on" structure: address title, one secondary line, a colored hero with a plain-English Next/Now line, one reminder row, one big "I'm leaving", collapsed signs. Flag OFF is behaviorally identical (legacy sheet and clear-pin verified live). CI is green (Build and XCTest pass). The two real problems are (1) the hero can say "free" on a metered "9AM-midnight" block while the new line right under it says "Now: meter until 12 AM" (root cause is an engine edge case, but v2 now exposes the contradiction on one card), and (2) at AX5 the 5/10/15/20 chips split "min" mid-word.

Build: debug simulator build, flags flipped locally in a throwaway worktree (nothing committed): myCarSheetV2Enabled, driveModeDefaultEnabled, curbPinPlacementEnabled, addressAnchoredParkingEnabled, spotHandoffEnabled, spotHandoffAutoDetectEnabled. A second build with stock flags was used for the flag-OFF check. Parked cars were injected via the legacy `wepark_parked_car` UserDefaults migration path (real tile segments), sim location set next to each curb. No `xcodebuild test` run (CI covers it).

## Acceptance checklist
- [x] Flag OFF unchanged: legacy sheet renders (`assets/pr188/off-legacy-A-asp-free.png`), "I left - clear pin" clears the car and pin (car button and pin gone after tap). The `performClearParkedCar` extraction is a verbatim move (diff read line by line: cancelAll, GarageSavings accrue, clearPin, Park Until reset, rebuildOverlays all present, same order).
- [x] Flag ON structure matches the brief (all 5 curbs below).
- [x] Hero color/text per curb vs engine: green ASP free-days-out (A), orange soon (B), red restricted (C), metered free-hours (E) correct. Metered-active (D) FAILS, see #1.
- [x] Reminder row: summary text matches selections ("1 hr before" -> "15 min & 1 hr before" -> "15 min & 1 hr before + night before"), night-before independent of lead times, changes persisted across app relaunch.
- [x] I'm leaving sheet: Tell neighbors (5/10/15/20) hit the identity gate (nested sheet works), posted a leaving-soon pin and showed "Neighbors have been told - 12 min left"; Spot Pass row shown with spotHandoffEnabled and no trip; Just clear my car cleared immediately (no confirm).
- [x] See the signs: collapsed by default, expands to full text with category tag. Data for segment A carries duplicate rules (both arrows); the list shows one.
- [x] AX3: title/hero/rows wrap, nothing clipped. AX5: main sheet fine (title wraps, hero wraps, 56pt+ rows); leaving sheet has a chip defect, see #2.
- [x] CI: `gh pr checks 188` green.
- [ ] Not verified live (flag is compile-time, would need more builds): Community OFF + Spot Pass OFF direct clear; Spot Pass row hidden in trip mode; notification deep link opening the sheet and exiting trip; Spot Pass armed label; reminder reschedule actually landing in the notification center; night-before-only summary; block detail cross-check; temp-restriction banner and swept badge. Code reviewed for each (below), recommend one live pass before flipping the flag.
- N/A Light appearance: app is forced dark (`preferredColorScheme(.dark)` + Info.plist), so there is no light mode to test.

## Findings

### Blocking
None.

### Significant
- **#1: Hero says "free" while the line under it says the meter is running (metered, midnight end)**
  - Where: `MyCarSheetV2Logic.meterUntil` vs `ParkingRulesEngine.currentState`/`safetyLabel` (metered check uses `minuteOfDay <= tr.end`, and meteredStatus differs).
  - What: St Marks Pl N side (`ST_MARKS_PLACE_1ST_AVENUE_AVENUE_A_N_4`, "2 HMP 9AM-MIDNIGHT EXCEPT SUNDAY", stored as start 540 / end 0) at 10:42 PM Tuesday: hero is GREEN with lowercase "free until 9am" and, directly under it, "Now: meter until 12 AM" (`assets/pr188/on-D-metered-active.png`). The two lines contradict each other, and the hero is the wrong one (meter is running until midnight). Product rule: never show free when it is not legal.
  - Why: the engine treats a range with end 0 as not wrapping (`start..<=end` false), v2's own `meterUntil` handles wrap correctly. The hero is v2's use of the engine, so the owner will see a green "free" card on a very common block type (all "9AM-MIDNIGHT" meters). The legacy sheet and map color share the engine bug, but v2 newly puts the contradiction on one card.
  - Expected: hero and Next/Now line agree; if the meter is running, hero should be amber "paid until 12 AM".
  - Repro: park on that segment between 9 AM and midnight (Mon-Sat), open My Car with flag on.
  - Owner: `@ios-engineer` (fix midnight-wrap in the engine's metered-active test in `currentState` and `meteredStatus`, add a test; also capitalize the engine label "free until 9am" when used as a hero headline).
- **#2: AX5 "I'm leaving" sheet: minute chips split "min" mid-word, Tell button becomes a blob**
  - Where: `MyCarSheetV2View.tellNeighborsSection` (`LazyVGrid` adaptive minimum 76, `minuteChip`).
  - What: at accessibility-extra-extra-extra-large, the four chips stay in 4 columns and render "mi / n" (`on-A-AX5-leaving-scrolled.png`). The "Tell neighbors - leaving in 10 min" button grows into a large oval. All text is still reachable by scrolling, but the chip labels are not readable as words. Brief asked for nothing critical truncating at AX5.
  - Expected: chips drop to 1-2 columns (or stack) at accessibility sizes; button stays a rounded rect.
  - Repro: AX5 (Settings > Display > Larger Text, or `simctl ui <udid> content_size accessibility-extra-extra-extra-large`), park, My Car, I'm leaving.
  - Owner: `@ios-engineer`.

### Minor
- **#3: "Next:" gives the schedule, not the next occurrence, and can list a day that is suspended.** Curb A: hero "Free until Mon 11/30 9:00 AM" (Thu 11/26 Thanksgiving is suspended) while the line says "Next: street cleaning Mon & Thu 9-10:30 AM". Not wrong per rule, but reads as if Thursday is coming. Consider "Next: street cleaning Mon 9-10:30 AM" using the engine's computed next date, or mention suspension.
- **#4: "12-3 AM" shared-meridiem compaction reads like noon-3 AM** (curb B: "Mon, Wed & Fri 12-3 AM"). Prefer "12-3 AM" -> "12 AM-3 AM" when the start is 12.
- **#5: Reminder summary can wrap to two lines at default size** ("15 min & 1 hr before + night before", `on-B-soon.png`). Fine, but the row is no longer a single line in the common multi-select case.
- **#6: "12 min left" after choosing 10 min** in the posted confirmation. Same params/path as the legacy card (`leavingSoonInsertParams`), so likely pre-existing buffer, but worth a glance.
- **#7: Medium detent is tight.** Signs expand below the fold at the default detent; user must scroll or drag up. Acceptable.

### Out of scope (logged, not fixed)
- AX5 drive-mode overlays (Report/Start Driving/Overnight/End) truncate to "Re p..." and cover the car pin (`ax5-drive-mode-out-of-scope.png`); pre-existing drive-mode issue, not this PR.
- Engine currentState vs safetyLabel use different metered logic (root of #1) and a pre-existing "ASP in effect today" banner showed on a Tuesday night; unrelated.
- My taps created one real 10-minute leaving-soon pin on E 13th St (Ave A-1st Ave) in prod community data; it has expired.

## Code review notes
- `nextMoveLine` uses `engine.nextRestriction` (the engine's own call), so Now/Next for ASP, no parking, no standing, truck loading, special never contradicts the engine's restriction logic; metered is the only independent path (#1). ASP suspension is honored because `nextRestriction` already skips suspended dates.
- `dedupedRules` key includes category, normalized text, days, time ranges and anytime, so a distinct schedule or wording is never hidden; only exact repeats (e.g. both-arrow duplicates, as in the tile data) collapse. Arrow direction is ignored on purpose.
- Leaving button: `leaveButtonOpensSheet(communityEnabled || spotPassAvailable)`; otherwise calls `onClearPin` directly (matches old behavior).
- Trip gating: `myCarSpotPassAction` returns nil when flag off or `tripPlan != nil` via `TripModeGating.showsSpotPass`, so the row disappears in trip mode. Armed pass relabels the row.
- `now` is captured once at view init (`private let now`), so a sheet left open across a restriction boundary will not update the hero until reopened. Same pattern as legacy; noted only.
- Identity gate sheet is nested on the leaving sheet (verified live: appears over it, post succeeds).

## Smoke tests run
- Flag OFF build: park on curb A, open sheet (legacy), tap "I left - clear pin": car cleared.
- Flag ON build: curbs A (ASP free until Mon), B (Chrystie overnight MWF, orange), C (E 10th no parking anytime, red), D (St Marks metered active, #1), E (1st Ave metered free-hours, green); screenshots in `docs/qa/assets/pr188/`.
- Reminders sheet: toggled 15 min + night before; row summary updated; app relaunched, summary persisted.
- Leaving sheet: Tell neighbors (identity gate, post anonymously, confirmation), Spot Pass row visible, Just clear my car cleared car.
- AX3 and AX5 passes; dark appearance only (light N/A).
- Cleanup: simulator deleted, worktrees and derived data removed, Config.xcconfig copy removed with the worktree, no flag change committed.

## What's working
- The main surface is genuinely calmer than `before-owner.png`: five elements, large tap targets (56pt rows, big "I'm leaving"), hero color and plain-English line readable at a glance.
- Flag-off path and the clear-pin refactor are clean; the shared `performClearParkedCar` removes duplication.
- Reminder UX is clearer ("Pick any that apply", night-before explained as separate), summary string is accurate, persistence works.
- Identity gate and post path reuse the legacy code and work in the nested sheet.

# PR #228 (DT35-6b drive stack at AX sizes) QA, 2026-11-28

**Reviewed:** branch `ios/dt35-6b-drive-stack-ax` at `cbcf078e`, against the #223 re-verification 2 finding and field log DT35-6 / DT35-8
**Verdict:** FAIL on the attribution criterion at AX5 moving when the street pill wraps (see finding #1). The PR's own changes (compact pill, 38% cap) work. Everything else passes. The remaining fix is small and sits outside the files this PR touched.

## Summary
The Park Until pill now reads "Until <end>" at AX sizes, never truncates itself, and the card stack gives way: with a short street name the Maps logo and Legal are clear at default, AX2, AX3 and AX5, static and moving. But the street pill (not touched here) wraps to 3-4 lines at AX5 when the name carries a direction ("Ave B · Northbound", "Orchard St · Northbound"). It then covers the Maps logo and, in one case, the whole Park Until pill. The end time is hidden and the attribution is covered. The full suite is green and all three merge dry-runs are clean.

## Acceptance criteria
- [~] 1. Logo and Legal unobstructed. Default (static and moving): yes. AX2/AX3/AX5 with a short street name: yes (static and 12 m/s moving). **AX5 moving with a long street name: NO** (finding #1).
- [~] 2. End time never truncated by the pill: yes in every goal state I reached (no ellipsis, accessibility tree shows the full "Until ..."). But it can be covered by the street pill (finding #1). "Tomorrow" end not reached live (sim clock 1:15 AM, Overnight ended 7 AM the same day). The Free until pick drops the picked time (finding #2). A long end wrapping: not reached live, because the pill text only carries the date for For days.
- [~] 3. Verdict scroll at 38%: structure verified in code (`WPFitScroll` caps at 0.38 x height with indicators, actions outside the scroll). Two 2-line cards at AX5 came to about 314 pt, about 36% of the screen, so no scroll was triggered live. I could not force a 3-line verdict. Not verified live. Buttons stayed pinned and full size in every AX5 shot. The visible road strip between End/Maps logo and the pill is small (about 2 to 8% of screen height) at AX5, as on #223.
- [x] 4. Default size: pill still "<Goal> · Now → <end>" (`fewS-large.png`); puck at about 50.7% static and about 52% moving; logo above the stack.
- [x] 5. Full suite, shipped flags, head `cbcf078e`, `-parallel-testing-enabled NO -jobs 4`: **3381 tests, 1 skipped, 0 failures**, no flakes to rerun.
- [x] 6. Conflicts (`git merge-tree --write-tree`): vs `main` (`99d96d1c`, includes #223/#224/#226), vs #225 (`ios/r35-pr1-stale-window`) and vs #227 (`ios/r35-pr2-zoom-bands`): all clean.

## Findings
### 🔴 #1: At AX5 a wrapped street pill covers the Maps logo and can hide the Park Until pill
- Where: street pill in the drive top chrome (not in this PR's diff); the attribution sits above the measured stack and the stack top lands under the pill.
- What: moving at 12 m/s, AX5, For days goal: street pill "Ave B · Northbound" wraps to 4 lines (breaks "Northboun / d"), reaches y about 940 of 2576 and covers the logo (only a sliver shows) (`daysM-accessibility-extra-extra-extra-large.png`). With a For days pick and "Orchard St · Northbound" the pill is 5 lines and sits over the Park Until pill so the end time is not visible at all, only the clear X shows (`pick-ax5.png`). With "E 5th St" or "Allen St" all is clear (`overM-...png`, `fewS-...png`).
- Expected: logo and Legal unobstructed, end time visible at every size.
- Repro: Stoop flags on, goal For days (or any), Start driving, AX5 (`simctl ui <udid> content_size accessibility-extra-extra-extra-large`), simulated route that passes a directional street ("... Northbound"). I did not check `main`, but this PR does not alter the street pill. AX3 with a short name was clear. AX3 with a long name not reached.
- Owner: `@ios-engineer`. Direction (not a fix by me): cap the street pill to one line (truncate or drop the direction) at AX sizes, or reserve its height in the stack budget.

### 🟡 #2: Free until pick shows date only on the pill
- Where: `ParkingGoals.windowEndLabel` for `.parkAndForget` (returns `weekdayDateLabel`), used by `compactPillText`.
- What: picked "Mon 9 AM" (card said Mon 11/30 ...), pill reads "Until Mon 11/30" with no time. Same on `main`'s full text ("Now → Mon 11/30"), so pre-existing, but the claimed "never lose the end" does not cover the time of day on Free until picks.
- Owner: `@ios-engineer`.

### 🟢 Minor
- #3: PR description is stale: it says the pill is one line, scaled and ellipsised; the head commit (`cbcf078e`) replaced that with wrapping "Until <end>". Update it.
- #4: At AX5 the ASP banner wraps to 2 lines and "Today" runs under the street pill (pre-existing, seen on #223).
- #5: Fallback-banner state and "Overnight until tomorrow" not exercised live (no clear-curb-free area; clock). Compact text is a pure function of the end label; unit tests cover the budget only.

## Smoke tests run
- Own sim `wepark-qa228-sim` (iPhone 17 Pro, iOS 26.5; deleted, derived data deleted). Flags flipped locally only (StoopFlag, driveModeDefaultEnabled) and reverted. Built and installed head, set each size and read it back (large, accessibility-large, accessibility-extra-large, accessibility-extra-extra-extra-large), screenshots read, accessibility tree grepped for Legal and pill text.
- Static: A few hours at all four sizes. Moving (12 m/s): Overnight and For days (Auto) at all four sizes; For days with pick at AX5.
- Mount-chain rule satisfied (live app inspected, not just tests).
- Machine load was 100+ for much of the session; builds/tests started only after the 1-minute load fell under 40.
- Screenshots in `docs/qa/pr228-assets/`.

## What's working
The compact pill is clean and wraps instead of cutting; VoiceOver keeps the full sentence (`"A Few Hours goal active, now -> 4:15 am..."`); default size is unchanged; the 38% cap leaves the logo clear above the stack and the buttons stay pinned and full size; suite and merges are clean.

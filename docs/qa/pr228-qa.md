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

---

# Re-verification (QA pass 2), 2026-11-28

**Reviewed:** `ios/dt35-6b-drive-stack-ax` at `7eadb986`. Sim `wepark-qa228b-sim` (iPhone 17 Pro, iOS 26.5), Stoop and drive-mode flags flipped locally only (reverted), 12 m/s simulated route heading north, For days goal with a **Free until Mon 9 AM pick, driven live**. Screenshots in `docs/qa/pr228b-assets/`.

**Verdict: FAIL** on the Maps logo / Legal criterion. The street pill is now correctly bounded (no mid-word breaks, at most two lines) and the full end time is always visible, but a two-line street name still sits on top of the Maps logo, and for "Adam C Powell Blvd" it covers the logo and Legal entirely.

## Result per check
1. **AX3/AX5 moving, long names + direction, Free-until pick with a time.**
   - Orchard St, Ludlow St, Ave B (AX5): pill is one line, direction dropped (VoiceOver label is "Street: Orchard St, northbound"). Logo, Legal, "Until Mon 11/30 9:00 AM" all visible, no overlap. PASS (`orchard2-ax5.png`, `aveb-ax5.png`).
   - Frederick Douglass Blvd (AX5 and AX3): pill wraps by words to two lines ("Frederick / Douglass Blvd"), correct. But its bottom edge sits on the top of the Maps logo and the "Legal" line: the logo is clipped/touching. FAIL (`fd-ax5.png`, `fd-ax3.png`).
   - "Adam C Powell Blvd" (the name the app shows for Adam Clayton Powell Jr Blvd) (AX5 and AX3): two-line pill covers the Maps logo and Legal completely, only an Apple glyph sliver shows at the left edge. FAIL (`acp-ax5.png`, `acp-ax3.png`).
   - "Avenue of the Americas" did not appear: the app labels that street "6th Ave" (not a long name). Not reproducible.
   - End time "Until Mon 11/30 / 9:00 AM": wraps to two lines by words, no ellipsis, fully visible in every shot. PASS.
   - The AX5 ASP banner still wraps to two lines ("Today" runs under the street pill), same as before. At AX3 it is one line; AX3 chrome is otherwise identical to AX5, so the collision is the same at both sizes.
2. **Default size**: pill "Park & Forget · Now → Mon 11/30 9:00 AM" (wraps to two lines at default with a long pick, time fully shown), puck at about 51.6% of the screen height, logo and Legal above the stack and clear (`default-pick.png`). Direction not shown while static; with Allen St (no direction) the street pill is unchanged. PASS.
3. **For days Auto** at default: card and chip read "until Sun 11/29", "Until midnight" wording unchanged. A pick at a time: Mon 9 AM shows "Now → Mon 11/30 9:00 AM" at default and "Until Mon 11/30 9:00 AM" at AX3/AX5. Picking Mon + Midnight reads the date-only "Tue 12/1" (midnight, expected by the rule). PASS. (Side note: the verdict card itself says "Park until Mon 11/30 9:30 AM" for a 9 AM window; that is the sign's own time, not this PR.)
4. **35% verdict budget**: could not force a tall verdict. The tallest I got was two cards of about 30 to 36% of the screen (a "Park until Mon 11/30 9:30 AM" two-line card plus a one-line card); nothing scrolled. Code path read: `WPDriveStackBudget.sidesMaxHeightFraction(accessibilitySize:)` returns 0.35 at AX. At AX5 the visible road between the top chrome and the Park Until pill is about 3 to 9% of the screen height (for example about 100 px of 2576 in `orchard2-ax5.png`, and about zero around the stack in `acp-ax5.png`). The reserve is what failed: see finding.
5. **Tests** (shipped flags, `-parallel-testing-enabled NO -jobs 4`): 3384 tests, 1 skipped, 0 failures, no flakes. **Merge dry-run** vs `main` (`04ece88b`) with `git merge-tree --write-tree`: clean.

## Findings
### 🔴 #6: At AX3 and AX5, a two-line street pill covers or clips the Maps logo and Legal
- Where: `WPDriveTopChromeV2` street pill and the attribution position (anchored above the measured stack). The 35% constant reserves height for the pill, but the logo still lands at the pill's bottom edge.
- What: with a street that wraps ("Frederick Douglass Blvd", "Adam C Powell Blvd") and goal pick on, moving: the two-line pill ends at about y 745 to 795 of 2576, the logo sits at about 735 to 775 and Legal at 750. FD: logo/Legal touched and partly clipped. ACP: fully covered, Legal gone. The attribution is a legal requirement and was the point of #228.
- Expected: logo and Legal clear at AX3 and AX5 regardless of street length.
- Repro: Stoop + drive flags, For days with Free until Mon 9 AM, Start driving, set AX5 (or AX3), simulate `xcrun simctl location <udid> start --speed=12 40.8110,-73.9475 40.8150,-73.9445` (Adam C Powell Blvd northbound) or start at `40.8110,-73.9505` (Frederick Douglass Blvd). Cards on those blocks show "Park until Mon 11/30 9:30 AM" (two lines) plus a second card.
- Direction (not a fix by me): the street pill's two-line worst case also has to move the stack/logo, or the pill should be capped at one line (scale or truncate with `minimumScaleFactor`, since the street can still be read via VoiceOver), or the stack budget must account for the real chrome height including the wrapped ASP banner.
- Owner: `@ios-engineer`.

### 🟢 Notes
- I did not re-run the builder's `r6/` shots, so I do not know why they looked clean. A likely difference is the shorter verdict cards under an Auto pick (unverified).

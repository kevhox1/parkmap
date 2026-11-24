# PR #179 QA: drive-card chip color, dated labels, car-pin hardening

**Reviewed:** branch `fix/drive-card-chips-dates-carpin` at `3bedf6ff` (merges cleanly into main `f92460c1`, no conflicts; CI `Build and XCTest` green). Built and live-driven on the iOS 26 simulator with the five flags flipped locally (never committed). Screenshots: `docs/qa/assets/pr179/`.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
B (dated labels) and C (car-pin hardening) check out live. A (chip color) is only partly fixed. I reproduced the owner's exact symptom, a RED left chip reading "Free until Mon 11/30 9:00 AM" over a mostly green map line, on E 2nd St between 2nd Ave and 1st Ave (frames 10, 11, 15). I traced it to a single 13.7 m timed NO STANDING segment that is free now but fails the goal window. The change cannot produce a false green. Finding 12 should NOT be marked closed.

## Acceptance checklist
- [~] A. Chip subset = text subset. PARTIAL. Stubs under 6 m no longer veto, and several blocks agree (frames 12, 13: both chips green, lines green). But `allSatisfy` over the free-now >=6 m set still lets one real >=6 m segment turn the whole side red. See #1.
- [x] A (opposite failure). No false green found. Reasoning is under "Smoke tests".
- [x] B. "Free until Mon 11/30 9:00 AM" and "Fri 11/27 9:00 AM" are shown live. Placement card shows "Mon 11/30 11:00 AM" (01). Month rollover and Today/Tomorrow are only code-read (`targetComps.month` plus `targetDate`) and covered by the parity test edits.
- [~] B at AX sizes. AX1-equivalent (accessibility-medium) fits in full (16-accessibility-medium). AX5 truncates to "Free until Mon 1..." and "Free until Fri 11/..." (16-accessibility-extra-extra-extra-large). See #2.
- [x] C. Car icon always visible in my runs on the PR (I did not run main). See below.
- [x] Dashed blue line is the community zone boundary. See below.
- [x] No merge conflicts with main (post #178).

## Findings

### Significant
- **#1: Chip is still RED over a mostly-green side (finding 12 reproduces on the owner's block type)**
  - Where: `DrivingContextService.goalAwareChipSeverity` (`subject.allSatisfy { engine.isFree... }`).
  - What: E 2nd St, 2nd Ave to 1st Ave, N side, Tue 5:30 PM, Overnight goal "Good through Thu". Tiles (`tiles/`) hold six ASP Mon/Thu 9-10:30 segments (23-52 m), all green on the map. Thursday is a holiday, so the text says Mon 11/30. The seventh segment is 13.7 m with `NO_STANDING Tue-Sat 07:00-16:00`. At 5:30 PM it is free now and >=6 m, so it enters the "subject" set. It fails the window (Wed 7 AM) and the map paints it red. One failing segment makes the chip red. The map is green on every other segment and the text says "Free until Mon".
  - Expected: color agrees with text and map. By the owner rule ("green only if there really is a spot for the whole goal window"), this side does have a spot, so it should be green. Alternatively the text should change, but today text, color and map disagree.
  - Repro: Overnight goal, Drive mode, play location along E 2nd St westbound->eastbound (40.7246,-73.9900 -> 40.7222,-73.9843 -> 40.7200,-73.9790 at 4 m/s) and watch about 20 s in. A stationary pause reproduces it (15-paused-red-left).
  - Suggested direction: use `contains(where:)` over the >=6 m subject set ("a qualifying spot passes the window"). Derive the text from the same passing set, because `aggregateSideDetail` ranks by min over free-now segments and ignores timed NO_STANDING in `nextRestriction`. Add a regression test using these real tile segments.
  - Owner: `@ios-engineer`
  - Note: red is the safe direction, so not blocking. I did not build main to A/B this. By code reading, main's all-segments rule is at least as red.

- **#2: Chip text truncates at the largest accessibility sizes**
  - Where: drive-card side chips (`DriveModeCards`), AX5.
  - What: the dated label is single-line and truncates ("Free until Mon 1..."). The date is no longer readable, and the time is lost at AX5. The builder's claim that it is "short enough at accessibility sizes" holds at AX1 only. AX2-AX4 were not captured.
  - Expected: no truncation, or a wrap or minimum-scale fallback.
  - Owner: `@ios-engineer`

### Minor
- **#3:** A free-now >=6 m sliver is enough to define the "subject" set. A 6 m spot is borderline for a parked car. This is consistent with the existing text threshold, so no regression, but worth a product look.
- **#4:** First cold launch of the build showed a black screen for about 15 s before the map rendered (Metal shader compile, simulator). Not caused by this PR, noted only.

### Out of scope (logged)
- The Park-here placement card and the drive chips pick different "which side" wording for the same curb. Not touched by this PR.

## Smoke tests run
- `gh pr view`: merge-tree against origin/main is clean. CI `Build and XCTest` is pass.
- `xcodebuild build` (no tests): BUILD SUCCEEDED with flags on.
- Launch and browse (mount-chain file `MapViewRepresentable`): map, toolbar buttons, ASP banner, goal tiles, polylines and search/more/locate all render (03, 04, 06). No missing overlay layer.
- C repro and verification (PR only; I did not build main): long-press curb placement and "Park here" -> car pin on the curb (03). Re-parked twice at different curbs: car pin visible each time (04, 06). Home then relaunch, then pan and swipe: still 1 `My parked car` annotation in the AX tree (07, car just panned off screen). Never reproduced the disappearing icon. Cannot say whether it ever reproduces on main. "I left" is the only clear path, and there is no move-car button in the details sheet.
- Dashed blue line: present in every frame including before any car existed (first launch screenshot), moves with the map geography, and the only dashed `systemBlue` renderer in the code is `ZoneBoundaryPolygon` (`MapViewRepresentable` ~L2944). Consistent with the community zone boundary. Not a car-pin artifact.
- Drive mode with Overnight goal along E 2nd St, E 7th St: chips green/green where the map is green (12, 13, 09); red/green mismatch reproduced (10, 11, 15).
- AX sizes: accessibility-medium and extra-extra-extra-large screenshots read.
- A opposite-failure reasoning: green requires every >=6 m free-now segment to pass `engine.isFree` for [now, target], which can only be stricter than the text. If no segment is free now, the subject falls to "all >=6 m", and `isFree` fails at `from`. No path yields green for a non-parkable curb. The only leniency is that segments under 6 m or not free now are ignored (finding #3).

## What's working
- Labels read clearly: "Fri 11/27 9:00 AM" and "Mon 11/30 9:00 AM". The Thursday holiday skip correctly pushes the left text to Mon.
- The CarPinSyncPolicy extraction is small and testable, and the `displayPriority = .required` change is sensible. The re-add-if-missing self-heal is a safe belt-and-braces change.
- Stub-veto removal visibly fixes blocks where short NO_STANDING stubs used to flip the chip (12, 13).

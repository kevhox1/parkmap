# PR #179 re-QA: drive-card chip "any qualifying spot" + AX wrap

**Reviewed:** branch `fix/drive-card-chips-dates-carpin` at `f7c7ee78` (CI `Build and XCTest` green, `gh pr checks 179`). Built (no tests run) and live-driven on a fresh iOS 26 simulator with the five flags flipped locally (never committed). Screenshots: `docs/qa/assets/pr179b/`.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
Both prior findings are fixed. The exact repro (E 2nd St, 2nd Ave to 1st Ave, Overnight, Tue ~5:58 PM) now shows green/green chips with coherent text ("Free until Mon 11/30 9:00 AM" / "Fri 11/27 9:00 AM"), while the map still shows the 13.7 m red NO STANDING stub on the left curb (e3, e6). Chip text now wraps fully at AX3/AX4/AX5. I found no false-green path in code or live. One new layout follow-up at AX3+ (End button overlaps Park here), plus a minor product note.

## 1. Code review (false-green risk)
`DrivingContextService.goalAwareChip`:
- Same predicate and window as the overlay: both call `engine.isFree(segment:from:until:ignoringMeteredPayment:)` with `from = now/date`, `until = parkUntilTarget`, `ignoringMeteredPayment = parkUntilIgnoresMeteredPayment` (overlay: `ContentView.swift` ~L2765). Timed SPECIAL / NO_STANDING / NO_PARKING / ASP are all handled inside `isFree`, so a segment the overlay paints red cannot be in `passing`. Green therefore requires at least one segment the map paints green.
- Sliver risk: qualifying set is >= 6 m (`minimumSubjectLengthMeters`). A 6-10 m free segment can make a side green. That is a real but small parkable gap; data has no hydrant/crosswalk geometry, so it cannot be excluded. Same threshold as the existing text, not a regression. Product call whether 6 m should be ~7-8 m (finding #3).
- Fallthrough: if no segment is free now, subject falls back to all >= 6 m, then all. `isFree` fails at `from` for anything restricted now, so no false green. Only exception is a metered segment under an `ignoringMeteredPayment` goal: it is green on the map and (if no other segment is free-now) green on the chip with legacy text, consistent. If some other segment IS free now, metered-but-passing segments are ignored for the chip (red-safe direction, chip may be redder than map; not a false green).
- Text is recomputed from `passing` only, so "Free until" never describes a failing segment. Red + free-now-but-failing becomes "Not free through your window"; verified live.
- Adjusted tests: `testMultipleSegmentsOnSide_onePasses_oneFails_overallFree` and the integration test now expecting left `.restricted` label + right `.free`. Both match the owner's rule (a real spot for the window = green; failing side must not say "Free until"). Not weakened to pass; they flip an old all-must-pass expectation that the owner rule explicitly rejects. `DriveCardAnySpotChipTests` uses real tile segments for the E 2nd St repro.

## 2. Simulator drive results (Tue ~5:57-6:05 PM)
| Block / goal | Chip | Map under car | Agree |
|---|---|---|---|
| E 2nd St 2nd Ave-1st Ave, Overnight (repro) | L green "Free until Mon 11/30 9:00 AM", R green "Free until Fri 11/27 9:00 AM" | long green lines both curbs, one short red stub on left (e3, e6) | yes |
| 2nd Ave, Overnight | L/R red "No parking" | red both curbs (f3) | yes |
| E Houston, Overnight | red "Metered" (R); other side "-" | red (f7) | yes |
| E Houston N/S, Overnight | R red "Not free through your window" | red curb (g7) | yes |
| Forsyth St, Overnight | L green "Free until Sat 11/28 12:00 AM" | green stripe at car (g6) | yes |
| Eldridge, Overnight | L green "Free until Fri 11/27 8:00 AM", R green "Mon 11/30 8:00 AM" | not screenshotted (AX only) | not verified visually |
| E 2nd St, A Few Hours | green/green, "Mon 11/30 9:00 AM" / "Tomorrow 8:00 AM" | green (fh7, AX log) | yes |
| E 2nd St W of 1st Ave, Park & Forget (Dec 2) | L red "Not free through your window", R green "Free - check signs" | right (N) curb red long, left (S) curb short green stub (pf8) | yes by cardinal side (see note) |
| Ave A, Park & Forget | L green "Free - check signs" | green stretches (pg4) | yes |

Genuine no-spot case: Park & Forget on E 2nd St (almost whole map red) gives red/red "Not free through your window" for most of the drive. Coherent text, color and map.
Not directly captured: E 1st St as the current block (GPS route kept snapping to neighbor streets); covered E 2nd, Houston, Forsyth, Eldridge, Chrystie, Allen, Ave A, 2nd Ave instead.
Note (pre-existing, out of scope): LEFT/RIGHT chips map to cardinal sides (N/W = left, S/E = right), not the driver's heading, so on a westbound pass the "LEFT" chip is the screen-right curb (pf8). Chip and map agree by side; labels are just heading-agnostic.

## 3. Accessibility sizes (E 2nd St, Overnight)
- AX1 (`accessibility-medium`, ax-ax1), AX2 (ax-ax2), AX3 (ax-ax3), AX4 (ax-ax4), AX5 (ax-ax5): chip text full, wraps on two lines, no ellipsis. "Free until Mon 11/30 9:00 AM" and "Free until Fri 11/27 9:00 AM" fully readable at AX5. Prior truncation fixed.
- Layout: the card grows to ~55% of the screen at AX3-AX5. Overlay controls collide: at AX3 and AX5 the End button sits on top of the Park here button (only "here"/lower half visible), Report truncates to "R..." at AX5, goal pill truncates to "Overnig..." at AX5 and the user dot is hidden behind the goal pill at AX3. See finding #1.

## Findings
### Significant (follow-up)
- **#1: End button overlaps Park here and other floating controls at AX3-AX5**
  - Where: `DriveModeBottomCard` growth vs the top-right End overlay and the Report/Park here row (ax-ax3.png, ax-ax5.png).
  - What: Park here is partially covered by End; still tappable on its lower half but a mis-tap ends the drive. I did not run main to check whether the overlap predates this PR; the taller wrapped chips make it worse by shrinking the map area.
  - Expected: controls do not overlap at accessibility sizes (or the chip row scrolls/caps the card height).
  - Owner: `@ios-engineer`

### Minor
- **#2:** "Free until Sat 11/28 12:00 AM" (Forsyth) reads oddly; "midnight" or "Fri night" would be clearer.
- **#3:** 6 m threshold can bless a sliver as a legal spot (see review). Product call.
- **#4:** First launch on a freshly created simulator hung the main thread (black screen > 2 min) in `ContentView.init` -> `DrivingVoice.init` -> `AVSpeechSynthesisVoice(language:)`. A simulator shutdown/boot fixed it. Likely simulator first-boot speech-asset behavior, not PR-related, but it is a synchronous main-thread call at app init.

### Out of scope (logged)
- Placement card said "paid until 7pm" for E Houston St North side while the drive chip for that block said "Metered" (consistent) but under a Park & Forget goal; wording not goal-aware. Not touched by this PR.

## Smoke tests run
- `gh pr checks 179`: Build and XCTest pass. `xcodebuild build` only (no tests): BUILD SUCCEEDED.
- Launch, browse, goal chips (Overnight, A Few Hours, Park & Forget), Start Driving, drive (simctl location routes), End, Park here -> checklist -> "Park my car" card -> Park here -> reminders sheet dismissed: all work. Overlay layer renders (toolbar, ASP banner, goal pill, polylines at close zoom).
- Car icon visible after parking (park4.png, 1 pin for "My parked car" in AX). Only one park/re-park run this pass; I did not repeat the multi-repark regression run from the first QA.

## What's working
- The exact owner repro is now consistent across chip color, text and map.
- Green text is derived from the passing set, so "Free until" never describes a failing segment, and the new red label reads honestly.
- Chip wrap at AX sizes is simple and effective.

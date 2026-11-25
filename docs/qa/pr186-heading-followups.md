# PR #186 QA (heading follow-ups) - 2026-11-24

**Reviewed:** branch `fix/heading-autopark-followups` at `2370d0bc`, compared live against `origin/main` (`dcfd4b02`). CI `Build and XCTest (Xcode 26)` passes (`gh pr checks 186`). Build only, no local tests.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The cross-street guard fixes the PR #182 finding on the simulator: on main the camera went north-up at the 2nd Ave crossing, on the PR it stays east-up. Real turns still work (fast and slow). The session reset is wired at drive start and end. I found no auto-park path: six drives plus a routed drive to a destination on a clean install produced no parked car. Follow-ups are code-review items, none blocking.

Caveat: simctl locations are not real GPS. Heading was judged from screenshots (street orientation, compass chip), and I cannot prove snap mode (speed < 1.5 m/s or poor course accuracy) engaged during the slow-turn run.

## Acceptance checklist
- [x] Cross-street guard, main repro. E 14th St eastbound at 10 m/s (resume from a stop), card reads "2nd Avenue" at the crossing. Main: compass "N", map north-up with 2nd Ave vertical (`main_cross_025.png`, `main_cross_026.png`), back to east-up one frame later (`main_cross_027.png`). Reproduces on main.
- [x] Cross-street guard, PR. Same route and timing: card also reads "2nd Avenue", camera stays east-up with E 14th St running up the screen (`pr_cross_025.png`). One frame (`pr_cross_026.png`) shows a modest tilt (~20-30 degrees, not 90), recovered in `pr_cross_027.png`. The 3rd Ave crossing also held on the PR.
- [x] Real turn still works (fast). E 14th to 2nd Ave southbound at 10 m/s: compass W then S within ~5-8 s of the turn, camera follows (`pr_turn_055.png`, `pr_turn_066.png`). Note this runs in `.course` mode, so it exercises the guard only by not being blocked by it.
- [~] Real turn, slow. 1.2 m/s onto 2nd Ave southbound: compass S and camera aligned to the avenue about 15 s after the turn (`pr_slowturn_025.png`, `pr_slowturn_055.png`). Not verified that snap mode was active.
- [x] Session reset. `ContentView.swift` calls `service.resetSession()` right after construction at drive start and `drivingContextService?.resetSession()` before nil-ing at drive end. `DriveSideTravel.reset()` clears all three fields. This closes pass-2 finding #3. Since a new service is built per drive, behavior is unchanged in practice (the PR says so).
- [x] No auto-park path. Clean install (uninstall + `keychain reset`, all five flags on locally): 6 drives (E 14th eastbound x4, southbound turn, slow turn, routed to Stuyvesant Square). Arrival prompt "You've arrived / Park on 2nd Avenue?" appeared at the destination; I tapped Not Yet, ended the drive, relaunched. No parked car in the AX tree or on the map (`arrival_prompt.png`, `after_end_no_car.png`, `after_relaunch_no_car.png`). Code: only the two user-tap save sites were checked by the builder; I did not re-audit them, my evidence is behavioral.
- [x] Live smoke (ContentView touched). Launch renders search/more buttons, ASP banner, goal bar and tiles; drive mode shows drive card, End, Report, Park here, goal pill, puck and polylines; post-End returns to browse.

## Code review of the guard (claim 4)
The guard is `min(delta(toward, last), delta(reverse, last)) > 60` then `return last`. It sits after the whole-street legal block and only applies to the "closest direction" fallback.
- **Curved streets.** Per-segment bearings change gradually, each segment stays within 60 degrees of the previous heading, so the guard does not trip. Even if it did, it holds one tick at a time while `lastGoodHeading` (live EMA) keeps updating. Low risk.
- **Broadway diagonal meeting a grid street.** Broadway is ~30 degrees off the avenue axis and ~60 from a cross street. A turn from an avenue onto Broadway (about 30 degrees) passes. A turn from a cross street onto Broadway sits near the boundary (about 60 degrees from the nearest direction), so the snap could be held a few ticks. Not exercised on the simulator (no clean Broadway diagonal route). Recommend a device check.
- **Slow turns.** The guard compares against `driveHeading`, which in snap mode is the pre-turn EMA. In snap mode (speed < 1.5 m/s or poor accuracy) the camera holds the old heading until the source returns to `.course` (speed >= 3 m/s and accuracy <= 25). The simulator run recovered within about 15 s at 1.2 m/s, but a car crawling around a corner at under 1.5 m/s could look stuck for the duration. Mild; the hold lasts only while slow.
- **Bypass.** A cross street whose WHOLE block is one-way, with legal direction within 90 degrees of the last heading (`oneWayLegalToleranceDeg` = 90, `DriveHeadingSnap.snappedHeading`), returns the legal bearing before the guard runs. Crossing such a street at an angle between 60 and 90 degrees (Manhattan avenues cross at ~90 exactly, so the 90 boundary is the sharp case) can still rotate the camera. The 2nd Ave crossing did not trip it (per-curb tags in the data), so this is a gap in coverage rather than an observed failure.
- Tests: the 4 new XCTest cases cover held cross street, a synthetic crossing sequence, along-street still follows, and `reset()`. Run by CI only; I did not run them.

## Findings

### Significant
(none)

### Minor
- **#1: Whole-street one-way cross streets bypass the guard.** `DriveHeadingSnap.snappedHeading` returns `legal` when `delta <= 90` before the new guard runs. Suggest applying the 60-degree rule to the legal bearing as well, or lowering the tolerance. Owner: `@ios-engineer`. Not reproduced on the simulator.
- **#2: Slow-corner hold lasts until speed >= 3 m/s.** See code review. Worth a device test: crawl through a right turn at 1 m/s and watch the camera. Owner: `@ios-engineer`.
- **#3: Transient ~25 degree camera tilt on the PR one frame after the crossing** (`pr_cross_026.png`). Likely course-driven (my route heading differs from the street), not guard-related. Informational.

### Out of scope (logged)
- Item 3 (the marker seen in the pass-2 run) was not reproduced on a clean install; consistent with the builder's persisted-state explanation (UserDefaults/iCloud KVS survive reinstall on that sim). If it recurs on a clean device with auto-detect on, collect the AX tree and the car's `id`/`source`.
- My first synthetic route used a wrong street bearing and drifted onto E 15th; discarded and redone.

## Smoke tests run
- Built PR head and origin/main with five flags flipped locally (never committed), installed on one simulator, keychain reset, location granted.
- Eastbound E 14th run at 10 m/s on PR and main with 1.4 s screenshot + AX card sampling; PR run done twice.
- Turn runs on PR: fast (10 m/s) E 14th to 2nd Ave southbound; slow (1.2 m/s).
- Clean-install drives, search, Go to Stuyvesant Square, arrival prompt (Not Yet), End, relaunch.
- Not run: `xcodebuild test`, Broadway diagonal, real device.

## What's working
- Guard is a 6-line, easily reasoned change that removes the 90-degree swing at intersections, with the main repro confirmed and fixed.
- Real turns follow in both fast and slow runs.
- Reset is explicit and cheap.

## Cleanup
Worktrees, `Config.xcconfig` copies, derived data and the simulator are removed (simulator shut down). 12 screenshots kept in `docs/qa/assets/pr186/`.

# PR #182 QA: drive-card LEFT/RIGHT by travel direction + idle heading hold

**Reviewed:** branch `fix/drive-sides-and-idle-heading` at `50b546b`, against the PR description, `build27-live-smoke-notes.md` (findings 8, 10) and `pr179-drive-card-recheck.md`. CI `Build and XCTest (Xcode 26)` passes. I did not run tests locally (build only, per instructions).
**Verdict:** BLOCK on the idle-heading half (finding 10). The side-assignment half (finding 8) is sound on the main cases but has one regression class; it is mergeable only if split from the hold, or with follow-ups.

## Summary
The side math is correct (sign convention verified live, all four E 14th curb/direction combinations). But in the simulator the idle heading hold does NOT keep the camera still: after the car stops and the position jitters, the map rotates ~20-25 degrees, reproducibly (4 of 4 runs), while main stays within ~3 degrees on the identical script. The PR's own test-plan item ("Idle 60 s: puck/camera do not rotate") fails. Separately, the one-way "legal direction wins" rule regresses LEFT/RIGHT on streets whose tile data tags each curb with its own one-way direction (Bowery, E Houston, Ave A), and on wrong-way driving of a true one-way.

Caveat: simctl fixes are not real GPS. The jitter script alternates `simctl location set` between two points ~4 m apart every 5 s (about 0.9 m/s implied) and a harsher 8-point variant. It is the scenario the task specified, but real-device behavior is unverified either way.

## Acceptance checklist
- [x] Sign convention (score = sin(curb bearing minus travel bearing), negative = left). Hand-checked, then live: E 14th St two-way, route hugging the N curb / S curb so the matched side is unambiguous. PR build: N-curb eastbound Left, N-curb westbound Right, S-curb eastbound Right, S-curb westbound Left. All correct. Westbound-case (original bug) correct.
- [x] Avenue B two-way N-S: E curb is Right northbound and Left southbound (texts differ per curb, "Fri 11/27" east curb vs "Mon 11/30" west). Correct.
- [x] One-way, legal direction (E 7th St NW, both curbs present, distinct texts): Left/Right correct and identical to main.
- [x] Turn at intersection (E 10th St eastbound onto Avenue C): card switches street and side without blank or flip; Right "No parking" after the turn is plausible. Not independently verified against ground truth for the cross street.
- [ ] Idle hold: FAILED. See finding 1.
- [ ] No regression vs main for sides on all street types: FAILED for per-curb one-way tags and wrong-way. See findings 2 and 3.
- [x] Hold release logic by code reading: slow traffic (0.5 to 2 m/s) is released by the 10 m displacement rule in about 5-20 s; a single phantom fast fix does not release (2 consecutive needed). Note the anchor is the first held fix and never moves, so slow GPS drift of 10 m over a long stop can release it (minor, finding 5).
- [ ] Live smoke (ContentView touched): partial. See Smoke tests.

## Findings

### Blocking
- **#1: Idle heading hold does not hold; camera rotates ~20-25 degrees while stopped, worse than main**
  - Where: `ContentView.swift` heading branch (`driveHeadingHeld` then `locationService.driveHeading`) and `LocationService` hold gate; screenshots `pr_slow_0.png` vs `pr_slow_60s.png` (PR) and `main_slow_0.png` vs `main_slow_60s.png` (main).
  - What: drive E 14th St eastbound at 10 m/s and arrive (E 14th is vertical on screen, heading-up). Then alternate `simctl location set` between `40.73257,-73.98515` and `40.73260,-73.98512` every 5 s for 30-60 s. PR: street tilts about 20-25 degrees by the end (also with a 2 s interval and an 8-point 3 s jitter). Main: street stays vertical within about 3 degrees. Same app flags, same script, same sim.
  - Expected: heading frozen until sustained speed or 10 m displacement.
  - Cause not established (no device logging). Likely candidates: the hold releases on the sim-reported speed or on the follow-up course-from-movement fallback; or the frozen raw `driveHeading` replaces main's street-snapped bearing and then drifts. Needs a log of `driveHeadingHeld`, speed and the heading source across the run.
  - Repro: above; `docs/qa/assets/pr182/*_slow_*.png`.
  - Owner: `@ios-engineer`

### Significant
- **#2: Legal one-way direction overrides heading on streets whose tile tags are per-curb, so LEFT/RIGHT is wrong half the time (regression vs main)**
  - Where: `DriveSideTravel.resolve` one-way branch (`DriveSideAssignment.swift`).
  - What: Bowery's W curb segments are tagged one-way southbound and its E curb northbound (E Houston and Ave A mix "to"/"from" similarly), although the street is two-way. The matched curb's tag forces the bearing, so the single visible curb is always "Right". Northbound near the W curb: PR Right "Not free" (wrong, W curb is on the driver's left), main Left (correct). Southbound near the E curb: PR Right (wrong), main correct. Southbound W and northbound E are right by coincidence.
  - Expected: LEFT/RIGHT follow the actual direction of travel; legal direction only when the heading is unknown or agrees with it.
  - Repro: Bowery, `40.72400,-73.99275` to `40.72517,-73.99242` at 8 m/s (`bowery_N_t2.png`, `bowery_N_t6.png`) on PR vs main (`main_bowery_N.png`).
  - Owner: `@ios-engineer` (data tags are `@backend-data`'s).
- **#3: Wrong-way on a true one-way gives swapped chips (regression vs main)**
  - Where: same branch.
  - What: E 7th St (both curbs, distinct texts), driven SE against the legal NW direction at the N curb. PR keeps the NW assignment (Left "Fri 11/27", Right "Mon 11/30"); main swaps correctly for the actual travel (Left "Mon 11/30", Right "Fri 11/27"). Rare, but it is exactly the case where the user needs the true side.
  - Suggested: use the legal direction only when heading is unknown or within 90 degrees of it (also fixes #2).
  - Owner: `@ios-engineer`

### Minor
- **#4: Original "westbound LEFT is wrong" does not reproduce on main with a known heading.** On main, the E 14th N/S-curb runs westbound give the same correct answers as the PR. The recheck's cardinal observation (E 2nd, pf8) may have been a nil-heading or perpendicular-heading moment. The PR's real value is those cases (first fix of a session, near-perpendicular headings, diagonals), which I did not find a deterministic repro for. Not a defect; it limits how much the live run proves the PR fixes.
- **#5: Hold anchor never re-bases.** A long stop with slow GPS wander of 10 m releases the hold without speed. Acceptable, mention only.
- **#6: Card blank side is mostly a data/grouping effect.** Many streets list the two curbs with reversed from/to (E 14th N "2nd to 3rd" vs S "3rd to 2nd"), so the block key (`street|from|to`) separates them and only one curb is shown ("—" on the other). Pre-existing; explains smoke finding 8's blank side and the Bowery map/card mismatch. Not touched by this PR.

### Out of scope (logged)
- Camera heading on Bowery northbound faces SOUTH on main and PR alike (street-snap follows the W-curb southbound one-way tag): same data root cause as #2, in `DriveHeadingSnap`.
- Tile street labels in this region look offset from Apple Maps names (e.g. segments labeled E 10th St drawn on a N-S street on screen); not investigated.

## Smoke tests run
- Build: PR head and origin/main, both with the five flags locally on (never committed), `xcodebuild build` succeeded. `gh pr checks 182`: Build and XCTest pass.
- Launch, browse with goal bar, Start Driving: renders toolbar, ASP banner, goal pill, polylines, drive card (`01-launch.png`, `e14_west.png`).
- Routed drives (`simctl location start`, 8-14 m/s): E 10th St E, E 14th St N/S curb E/W, Ave B N/S, E 7th St legal and wrong-way, Bowery N/S near each curb, Broadway SW/NE (main only, data too sparse to read). Card read via AXe; compared with map.
- Park here: confirm sheet shows ("E 4th St, South side") and the car pin appears as "My parked car" in the AX tree (`smoke_after_park.png`). I did not complete End Drive then reverify the car icon after the drive ended; the sheet kept re-presenting in my taps. Not verified: car icon after End, goal switching beyond Overnight.
- Idle: described in finding 1.

## What's working
- The scoring approach is clean, always fills both slots when two curbs exist, and the sign is right.
- Single-curb data gaps no longer mislabel the one present curb on two-way streets.
- Hold state is fresh per session; release conditions are sensible on paper; tests are thorough for the pure logic.

## Cleanup
Worktrees, derived data and the simulator are removed/shut down after this report; temporary flags were only in the worktrees.

# PR #182 QA Pass 2 (re-check) - 2026-11-24

**Reviewed:** branch `fix/drive-sides-and-idle-heading` at `92eb4d04`, compared live against `origin/main` (8fe322de, includes #183/#184). CI `Build and XCTest (Xcode 26)` passes (`gh pr checks 182`). Build only, no local tests.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
All three blockers from pass 1 are fixed on the simulator. Idle heading stays put (no visible rotation over 120 s of jitter, plus the 2 s and 8-point variants), wrong-way on E 7th follows the car again, per-curb one-way tags on Bowery no longer force sides, and the Bowery northbound camera now faces north (main faces south). Reversed-label blocks (Broadway) now show both curbs where main showed "—". Remaining items are follow-ups: Bowery still shows one curb ("—" on the other, identical on main), and the camera swung to the cross street while crossing an intersection (not compared on main).

Caveat: simctl locations are not real GPS; heading was judged from screenshots (street/label orientation, compass chip), not logged degrees.

## Acceptance checklist
- [x] Idle heading hold. E 14th St eastbound, arrive, alternate two points ~4 m apart every 5 s for 120 s (PR): street orientation identical at 0 s and 120 s (`pr_slow_0.png` vs `pr_slow_60s.png`), approx 0 degrees vs pass-1's 20-25. Main baseline (`main_slow_*`, 60 s) also unchanged, so PR is not worse than main. 2 s variant (30 s) and 8-point 3 s variant (96 s, `pr_8pt_96s.png`): no visible rotation.
- [x] Resume driving follows. Resumed eastbound at 10 m/s: within 6 s the camera had re-oriented and by ~15 s it was aligned with the direction of travel (`pr_resume_later.png`). See finding 1 for a transient at the intersection.
- [x] E 14th both directions: card fills both slots, no swap vs. earlier pass (data on that block is mostly "No parking" both curbs, so the L/R text cannot discriminate; sign convention was verified in pass 1 and the scoring code is unchanged).
- [x] Bowery northbound near W curb: Left "Free until Tomorrow 8:00 AM" (correct, W is left). Camera faces north (`pr_boweryN_t12.png`). Main: same card, camera faces SOUTH (`main_boweryN_t12.png`, compass "S"). Fixed.
- [x] Bowery southbound: single curb shows as Right (W curb, correct), camera faces south, compass S (`pr_boweryS_t8.png`). Main identical card.
- [x] E 7th St legal (NW): Left Fri 11/27, Right Mon 11/30. Wrong-way (SE): swaps to Left Mon 11/30, Right Fri 11/27, identical to main's correct behavior. Pass-1 finding 3 fixed.
- [x] E Houston / Ave A spot check: both curbs read distinct and swapped per direction on Houston; Ave A shows a single curb with the other "—" (data, as on main).
- [x] Avenue B N/S and a turn: card switches street names and keeps L/R slots filled; no flips observed. (My routes were approximate, so the cross street names read E 14th / E 20th. Only coarse behavior verified.)
- [x] Reversed-label block: Broadway W 103rd-104th area, northbound and southbound, Left "Metered" and Right "Metered" on PR. Main: Left "Metered", Right "—" on the same route. Fixed. I did not hit W 101st-102nd exactly.
- [x] Live smoke (ContentView touched): launch renders search/more buttons, ASP banner, polylines, the #183 goal bar (Overnight + Until 7 AM + 3 goal tiles) (`01-launch.png`); Start Driving shows drive card, End, Report, Park here, goal pill, ASP banner, puck (`02-drive-start.png`); Park here opens checklist then confirm sheet "E 14th St - North side" (`pr_park_confirm.png`); Park here then reminders sheet; End returns to browse with the car icon at the parked spot (`pr_after_end.png`).

## Code review notes
- `DriveHeadingHold.displayedHeading` freezes the previous DISPLAYED value while held, falls back to the candidate when there is none (first fixes). Sound and fixes the source-switch root cause.
- `wholeStreetLegalBearing` is implemented twice (assignment uses geographic polyline bearings, snap uses `toward_to` bearings from the segment). They agree on the tested streets; with reversed-label curbs the snap version depends on `SegmentBearing`, not independently verified.
- Sign convention unchanged: score = sin(curb bearing - travel bearing), lowest = left, highest = right, always distinct for 2+ curbs. No path found that swaps every street.
- Block-change detection and voice still use `context.blockKey` (raw key) (`DrivingContextService.swift` ~429): intended, no side effects found. Side lookup, aggregation and travel key use the canonical key.
- `matchedSiblings` is reset to `[]` on the two nil-return paths; consistent with `matchedSegment`.

## Findings

### Significant
- **#1: Camera swung to the cross street while crossing an intersection (not compared on main)**
  - Where: `ContentView.swift` heading branch / `DriveHeadingSnap.snappedHeading` with `service.matchedSiblings`.
  - What: resuming eastbound on E 14th at the 2nd Ave crossing, 6 s after resume, the card read "2nd Avenue" and the map was oriented with 2nd Ave vertical (north up) instead of east up (`pr_resume_later.png` is ~9 s later and correct). The matched segment flips to the cross street and the snap picks a bearing 90 degrees off the real heading; whole-street rule (needs 2 curbs, all one-way) does not apply to two-way 2nd Ave, so it falls to "closest to last good", which ties at 90.
  - Expected: heading holds along the direction of travel through the intersection.
  - Not verified on main (I did not run this exact crossing there), so it may be pre-existing. Recommend a quick main comparison and a guard (ignore snap when the matched segment is more than ~60 degrees from last good heading).
  - Owner: `@ios-engineer`

### Minor
- **#2: Bowery still shows one curb ("—" on the other), identical on main.** Map draws both curbs but the data for the E curb apparently carries different cross streets than the W curb, so the canonical key (which only handles reversed from/to) cannot group them. Not a regression; the claim "no blank unless the data lacks a curb" is true for Broadway but not Bowery. Owner: `@backend-data` (data) / `@ios-engineer`.
- **#3: `DriveSideTravel.lastHeading` / `lastBearing` are never reset between drive sessions** (`DrivingContextService.sideTravel`; `LocationService` resets its own hold state but the service does not). First fix of a new session with nil heading may use the previous session's heading instead of the cardinal fallback. Low impact.
- **#4: Hold anchor never re-bases** (carried from pass 1). The 8-point jitter has up to ~8-10 m spread; I saw no rotation but the 10 m displacement rule can release the hold with noise alone.

### Out of scope (logged)
- A "My parked car" marker appeared in the AX tree during several routed drives without my tapping Park here (spot hand-off auto-detect flag on). Not related to this PR.
- Main fresh install showed a "Keep WePark in Front" modal over the first drive; the PR run did not show it. Main screenshots `main_slow_*` are dimmed by it; the street orientation is still readable and unchanged.
- Tile street labels are offset from Apple Maps names in places (carried from pass 1).

## Smoke tests run
- Built PR head and origin/main with the five flags flipped locally (never committed), installed on one simulator (keychain reset before each install), granted location.
- Idle jitter (5 s x 120 s; 2 s x 30 s; 8-point 3 s x 96 s) on PR; 5 s x 60 s on main.
- Routed drives with card reads via AXe (every 2 s) and screenshots: Bowery N/S, E 7th legal/wrong-way (PR and main), E 14th W and S-curb E, Ave B N/S, Broadway N/S (PR and main), E Houston E, Ave A N.
- Park flow: Park here, checklist, confirm sheet, reminders sheet, End, car icon on map.

## What's working
- The idle-heading fix addresses the actual root cause and is cheap to reason about.
- Wrong-way and per-curb-tag regressions from pass 1 are gone; the Bowery camera bug present on main is fixed as a bonus.
- Reversed-label blocks (Broadway) now fill both sides.

## Cleanup
Both worktrees, Config.xcconfig copies, derived data and the simulator (shut down; only this one was used) are removed. 13 of 35 screenshots kept in `docs/qa/assets/pr182b/`.

# PR #196 QA: UNKNOWN is a restriction in the iOS engine (Pass 1, 2026-11-25)

**Reviewed:** branch `fix/ios-unknown-is-restriction` at `origin` head (base `0d0b78f9`), against the product rule "never show a spot that isn't a spot; unknown signs are red; copy never invents a restriction".
**Verdict:** 🔴 BLOCK (one small, well-scoped hole: UNKNOWN is still green on Sundays for every real tile). Everything else checks out.

## Summary
The engine change is correct for the semantics it implements (UNKNOWN restricts during its stated days/times, specific restrictions win in copy, no over-application outside a window, all consumers go through the engine). But the real tile data never produces the "no days, no times" case the PR optimizes for: the pipeline stamps every unstated UNKNOWN rule with days Mon-Sat (`[1,2,3,4,5,6]`). The engine honours those "stated" days, so all 61 UNKNOWN-only segments, and 2,160 UNKNOWN rules across 1,251 segments, are green on Sunday. The PR's own parity table shows it (Sun 10 AM A Few Hours: 31,166 -> 31,165, i.e. one segment changed). The unit test for this case uses `days: []`, which does not exist in the shipped tiles, so the suite is green while the product rule is not met.

## Acceptance criteria checklist
- [x] `isFree` treats UNKNOWN as a restriction in its stated days/times: verified by reading the new `isFree` branch (`cat == .unknown` joins the no-parking branch) and 13 new tests.
- [ ] "...and always if it has neither": FAILED on real data. See finding #1.
- [x] Edited files match the claim (7 source files plus 1 test file; `ParkingRulesEngine.swift` is also edited, which the PR text omits from its list).
- [x] Copy "Unclear sign: check the posted sign" in label, chip, My Car, trip; drive voice "Unclear signs here. Check the posted signs."; never "No parking" for an UNKNOWN-only cause (SafetyLabel bridge, engine `safetyLabel`, `MyCarSheetV2Logic.nextLine`, `TripPlanning.reasonText`, `DrivingContextService.buildUtteranceText`).
- [x] No existing tests edited: `git diff --stat` shows only the new `UnknownIsRestrictionTests.swift`.
- [x] Swift parity: Swift test `testParity_aFewHoursTue10AM_matchesNodeStateIV` asserts equality at accuracy 0 and passed (Tue 2026-12-15 10 AM, A Few Hours = 10,598). I re-ran Node myself: `UNKNOWN_RESTRICTS=1 node scripts/diff-tiles-days.js --green-table <tiles> <tiles>` gives state (iv) `A Few Hours @ Tue 10 AM` = 10,598, unknownOnly = 61, segmentsWithUnknown = 1,273. Parity holds. (Both share the same days handling, so parity does not catch finding #1.)
- [x] Full WeParkTests on the branch: 2,967 passed, 0 failed, 1 skipped.
- [ ] Live simulator check of an UNKNOWN-only and a mixed segment: NOT COMPLETED. See "Smoke tests run".

## Findings

### 🔴 Blocking
- **#1: UNKNOWN-only and unstated-UNKNOWN segments are green on Sundays (pipeline default days Mon-Sat)**
  - Where: `ParkingRulesEngine.isFree` (`.unknown` branch), `isUnknownRuleActive`, `nextRestriction`; data in `ios/WePark/WePark/Resources/tiles/*.json`.
  - What: every one of the 61 UNKNOWN-only segments (bus-stop panels, MICROHUB, carshare, "Description Not Available", destination panels) has `days:[1,2,3,4,5,6], timeRanges:[], anytime:false`. Across all tiles, 2,188 of 2,191 UNKNOWN rules carry exactly `[1..6]`, and 2,160 of them have no day or time words in the description (1,251 segments). `isUnknownRuleActive` returns `days.contains(dayOfWeek)`, so on Sunday these rules are inactive, `isFree` returns true, `safetyLabel` says "Free" / "Free until ...", and the map and every goal paint them green. The PR's own table shows no Sunday effect (31,166 vs 31,165).
  - Expected: "UNKNOWN ... always if it has neither [stated days nor times]". A pipeline default is not a stated day.
  - Repro: Node port at Sun 10 AM (`UNKNOWN_RESTRICTS=1`): the 61 UNKNOWN-only segments pass `isFree` for A Few Hours. In Swift: `Segment` with one `UNKNOWN` rule, `days:[1,2,3,4,5,6]`, no times, `isFree` from Sun 2026-12-13 10 AM for 3h returns true.
  - Fix hint (not applied, QA does not fix): treat an UNKNOWN rule with empty `timeRanges` and no day words as every-day (engine, or emit `days: []` from the pipeline), and add a test using the real `[1..6]` shape. The Node port needs the same change so parity stays meaningful.
  - Owner: `@ios-engineer` (engine) with `@backend-data` if the pipeline route is chosen.

### 🟡 Significant
- **#2: side label can say "No parking" when an UNKNOWN is a cause**
  - Where: `DrivingContextService` aggregation, `allUnclearOrNoData` loop (around line 652).
  - What: the flag is false if any segment on the side is not unclear/no-data, including a short free stretch (under the 6 m minimum) or a metered segment. A side that is red because of an UNKNOWN curb plus a too-short free curb falls back to the generic "No parking" label. This does not claim a restriction the sign never stated for a lone UNKNOWN side, but a mixed side can still show "No parking" where one cause is unknown.
  - Expected: copy never invents a specific restriction; ideally restrict the check to the segments that made the side red.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit
- Reminder notifications for an upcoming UNKNOWN window read "Unclear sign starts in 15 minutes. Move by ...". Not a false restriction, but "starts" and "Move by" assert a restriction begins. Consider "Check the posted sign".
- Voice: when one side is "No parking" and the other is unclear, the utterance is only "Unclear signs here..." (drops the specific side). Acceptable, mildly lossy.

### 💡 Out of scope (logged, not fixed)
- Map curb polylines did not render in the live simulator at the launch zoom on either `main` or this branch (see Smoke tests). Not attributable to this PR; worth a separate look.
- AXe gestures (pinch, double-tap) fail on this simulator runtime ("displays not found"); only `tap` works.

## Spec traces (free/status paths)
All route through `ParkingRulesEngine` (`isFree`, `nextRestriction`, `safetyLabel`, `currentState`):
- Goals and Park & Forget ladder: `ParkingGoals.match` -> `engine.isFree` (lines 205/216/283). Covered.
- Map overlays: `ContentView` Park Until path -> `engine.isFree`; current-state path -> `engine.currentState` (active UNKNOWN -> `.restrictedNow`; upcoming within 6 h -> orange). Covered.
- Drive card left/right and voice: `DrivingContextService` (`engine.safetyLabel`, `engine.isFree`), copy handled. Covered (subject to #2).
- My Car free-until and reminders: `MyCarSheetV2Logic.nextLine`, `ParkedCarDetailLogic.freeUntilStatusText` (uses `restriction.label` = unclear headline), `NotificationScheduler` (finding in nits). Covered.
- Plan a Trip: `TripPlanning.isFree` -> engine; `reasonText` handles UNKNOWN. Covered.
- Curb detail: `BlockDetailView`/`CurbPlacementCard` render `engine.safetyLabel(...).text` verbatim. Covered.
- Spot Pass: no rule-status logic found (grep of `Services/SpotPass`, `Views`); nothing bypasses the engine.
- Grep for non-engine free logic (`isFree`, `.category ==`, `dominantCategory`): the only bypass-like uses are `hasNoSignData` guards (red/unknown, safe). No other path treats UNKNOWN as free apart from finding #1.
- Windowed UNKNOWN does not over-apply: `isUnknownRuleActive` and the `isFree` day walk both use `rangeActive`/`timeRangeOverlaps`; covered by `testMixedSegment_notFreeInsideUnknownWindow_unaffectedOutside` and `testUnknownTimesWithoutDays_appliesEveryDay`. Verified by reading plus tests.
- Specific restriction wins: in `nextRestriction`, an active UNKNOWN is parked in `activeUnknownRule` and only returned if no specific rule returned early; `testSpecificRestrictionWinsOverUnknownInCopy` passes.

## Smoke tests run
- `xcodebuild test` WeParkTests on the branch: 2,967 passed, 0 failed, 1 skipped (includes `UnknownIsRestrictionTests` 13 tests and the parity test).
- Node parity: 10,598, matches.
- Node census of tiles: 61 UNKNOWN-only segments, all `days [1..6]`, no times (finding #1).
- Same location-timing suites on `origin/main`: `AmbientDrivingLookLocationPostureTests.testRestingFix_publishesAccuracy_withoutAnyDrivePosture` FAILED on main (1 failure of 2,954); it passed on this branch. `LocationServiceDriveCourseAccuracyTests` passed on main, this branch, and #197. So the Ambient posture test is a pre-existing flake, not a regression.
- Merge with #197: `git merge-tree` is conflict-free; full suite on the temporary merge commit: 2,971 passed, 2 failed (both `AmbientDrivingLookLocationPostureTests`, the known flake), parity test passed.
- Live simulator (iPhone 17 sim, iOS 26.5, location set to Union Square, Wed 2026-11-25): the app launched and rendered the map, toolbar buttons, ASP banner and Park Until clock; the Park Until "2 hr" goal activated (clock turned green). No curb polylines were drawn at the launch zoom, so I could not tap an UNKNOWN-only segment (Broadway N, `BROADWAY_EAST_14TH_STREET_CANAL_STREET_N_0`, "Description Not Available") or a mixed one (`EAST_23RD_STREET_1ST_AVENUE_AVENUE_C_S_6`), and pinch-to-zoom is unavailable (AXe gesture error). The same missing-polylines state occurred on `main`, so it is not caused by this PR. **Not verified live: recommend a manual tap on those two segment ids before ship.** Wednesday is also a day the Mon-Sat default would have restricted, so a live check would not have surfaced finding #1; use Sunday or a clock override.

## What's working
- The engine change is surgical and consistent: one `isUnknownRuleActive` predicate shared by `nextRestriction` and `isFree`'s day-walk semantics, UNKNOWN never produces "Free" copy while active.
- Copy discipline: no path says "No parking" for a lone UNKNOWN cause, and the voice string avoids any specific claim.
- Good test coverage of map vs drive-card agreement and the Node parity check, and no existing tests were edited.

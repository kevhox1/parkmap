# PR #190 QA: tiles day-parse fix (ALL DAYS / dropped weekend clauses) — 2026-11-25

**Reviewed:** branch `fix/tiles-alldays-dayparse` at `06c4d39b`, against the PR's own claims (`docs/qa/tiles-alldays-diff.md`) and the product rule "never show a spot that isn't a spot; when unsure the curb reads not parkable."
**Verdict:** MERGE (with caveats; no blocker found). Net effect is strongly toward red.

## Summary

The fix is correct and does what it says. I rebuilt the tiles from the same 96,268-sign cache with the PR's `build/preprocess.js` and got **byte-identical output for every tile file** (only `index.json` `generatedAt` differs), and the iOS bundled tiles are identical to root `tiles/`. I independently reproduced the 82 red-to-green cells / 36 segments, then scanned all 168 hours of the week and found 10 more red-to-green segments (46 total) that the 4-probe-time diff missed. Every one of the 46 is correct against the literal sign text. The evaluator port matches the Swift engine. A handful of residual items below are pre-existing or fail-safe-in-the-wrong-direction by segmentation, none introduced by this PR.

## Acceptance checklist

- [x] Root cause is in `parseSchedule` exclusive branches: confirmed by reading old code (MON-SAT / MON-FRI regex, else name scan; `ALL DAYS` honored only when list empty).
- [x] Union of day phrases + per-clause rules + fail-safe fallback: read `parseDayPhrases`, `splitDayClauses`, and the `rules` flatMap in `main()`. Logic matches claims.
- [x] 2,880 changed rules / ~2,730 Saturday meter hours: reproduced independently (2,555 segments differ by raw rule JSON; PR's 2,531 uses a day-sorted comparison, immaterial).
- [x] 82 red-to-green cells / 36 segments reproduced exactly with the PR's tool. All-hours rescan: 4,232 cells / 46 segments (see finding 1).
- [x] Tile schema unchanged: 47,209 segments, same id set; segment keys `id,street,from,to,side,line,rules,dominantCategory,oneway,oneway_toward`; rule keys `category,description,days,timeRanges,anytime,arrow,temporary?`; time range keys `start,end`. 0 rules with empty or out-of-range `days`.
- [x] Tiles reproducible: rebuild from `signs.json` (same cache) matches committed tiles byte for byte except `index.json` `generatedAt`.
- [x] iOS bundled tiles == root tiles (`diff -rq` clean).
- [x] Evaluator port matches Swift (finding 5, no mismatch).
- [x] No regression in untargeted families (ASP, no standing/stopping, hotel loading, commercial-only, plate/permit-only, school days, midnight windows): see evidence table.
- [x] Script tests: all pass (below). iOS WeParkTests: 2,924 passed / 0 failed.
- [ ] "0 unparsed day words": nearly true; one typo sign (`THURSDA`) still partially parses (finding 3, pre-existing).

## Evidence: regression sweep by sign family (new tiles vs `main` tiles, same sign cache)

| Family | Check | Result |
|---|---|---|
| Changed buckets with NO day word / EXCEPT / ALL DAYS in text | scripted | 0 of 2,910 changed (category, description) buckets. No collateral change outside day-text signs. |
| Any rule whose named day is not covered by the sign's rules (excluding EXCEPT) | scripted over all 93,063 rules | 1 sign (finding 3). Everything else covers every named day. |
| Coverage lost (any day/minute that was restricted, now not) | scripted, 146 distinct sign texts | All are (a) Mon-Fri/Sat split signs where the Saturday window had been over-applied to weekdays, (b) abbreviation signs that had defaulted to Mon-Sat, (c) `FRI-SUN` / `SAT & SUN` midnight windows. No other family loses coverage. |
| Street cleaning (ASP) | `MON & THURS` -> `[1,4]`, `TUES & FRI` -> `[2,5]`, `WED` -> `[3]`, `THU RSDAY` -> Thursday restored | Correct. Time ranges like `8:30-10AM`, `11AM TO 12:30PM` still do not parse (pre-existing), so these stay all-day on their days = over-red. |
| NO STANDING / NO STOPPING | `EXCEPT VEHICLES WITH DOT THEATRE PERMIT` (`CHRISTOPHER_STREET_BLEECKER_STREET_HUDSON_STREET_N_4`) | Mon-Sat window -> `anytime`, all 7 days. More red. |
| Hotel loading | `NO STANDING HOTEL LOADING ZONE` stays anytime (411+144 rules); `...EXCEPT SUNDAY OTHER TIMES HOTEL LOADING ZONE` unchanged | No regression. Note pre-existing gap (finding 4). |
| Commercial-only, permit-only (`BUSES WITH PERMIT ONLY`, plates, AVO, ambulette, doctor) | `ALL DAYS` ones all 7 days; Mon-Fri+Sat ones now per-clause | Stay red in their stated windows. See finding 2 re: outside-window hours. |
| School days | `SCHOOL DAYS` still `[1..6]` | Unchanged (deliberate, over-applies Saturday = red). |
| Midnight windows | `end==0` is 24:00; `0 < end <= start` wraps; `1080-0`, `1140-420`, `1320-360`, `0-360` all preserved | Correct. Clause split keeps wraps (`1080-120` taxi). |
| `ALL DAYS` + explicit day clause | `3RD_AVENUE_EAST_34TH_STREET_EAST_35TH_STREET_E_0` TRUCK_LOADING `7PM-7AM ALL DAYS SUNDAY 7AM-7PM` | `[0]` -> `[0..6]` with ranges `1140-420, 420-1140` (= 24h all days). Over-red on weekday daytime (union); correct and safe. |

## Spot-check against raw sign text (27 segments)

Sign text is the `description` in the tile (verbatim from NYC DOT `sign_description`; I also confirmed the TIEMANN signs directly in the cache). "After" = new tiles.

| # | Segment | Sign text | Before -> After | Verdict |
|---|---|---|---|---|
| 1 | `3RD_AVENUE_EAST_34TH_STREET_EAST_35TH_STREET_E_0` | TRUCK LOADING ONLY 7PM-7AM ALL DAYS SUNDAY 7AM-7PM | `[0]` -> `[0..6]` 24h | Correct, over-red weekdays |
| 2 | `COLUMBUS_AVENUE_WEST_93RD_STREET_WEST_92ND_STREET_W_0` | TRUCK LOADING ONLY 10PM-6AM ALL DAYS SUNDAY 6AM-10PM | `[0]` -> `[0..6]` | Correct, over-red |
| 3 | `BROAD_STREET_SOUTH_STREET_WATER_STREET_N_0` (Sat meter) | METERED MONDAY-FRIDAY 10AM-7PM SATURDAY 9AM-7PM | one rule `[1-5]` both windows -> `[1-5] 10-7PM` + `[6] 9AM-7PM` | Correct; Saturday meter now present |
| 4 | `BROADWAY_EAST_HOUSTON_STREET_PRINCE_STREET_E_0` (Sat meter) | MON-FRI 6PM-10PM SAT 8AM-10PM | `[1-5]` both -> `[1-5] 6-10PM` + `[6] 8AM-10PM` | Correct |
| 5 | `WEST_3RD_STREET_MACDOUGAL_STREET_6TH_AVENUE_N_1` (Sat meter) | MONDAY-FRIDAY 6PM-MIDNIGHT SATURDAY 8AM-MIDNIGHT | `[1-5] 1080-0/480-0` -> `[1-5] 1080-0` + `[6] 480-0` | Correct |
| 6 | `10TH_AVENUE_WEST_44TH_STREET_WEST_45TH_STREET_E_0` (Sat meter) | MON-FRI 10AM-4PM SAT 9AM-7PM | split | Correct |
| 7 | `EAST_46TH_STREET_5TH_AVENUE_MADISON_AVENUE_N_0` (Sat meter, 2 windows) | MON-FRI 10AM-4PM 7PM-10PM SAT 9AM-10PM | `[1-5] 600-960/1140-1320` + `[6] 540-1320` | Correct |
| 8 | `THOMPSON_STREET_BLEECKER_STREET_WEST_HOUSTON_STREET_W_0` (abbrev) | ASP 11AM TO 12:30PM MON & THURS | `[1-6]` -> `[1,4]` | Correct; all-day on those days (time unparsed, over-red) |
| 9 | `WEST_104TH_STREET_COLUMBUS_AVENUE_MANHATTAN_AVENUE_S_0` (abbrev) | ASP 8:30-10AM TUES & FRI | `[1-6]` -> `[2,5]` | Correct, over-red on those two days |
| 10 | `WATER_STREET_PINE_STREET_WALL_STREET_W_0` (typo) | ASP MONDAY TUESDAY THU RSDAY FRIDAY 6AM-7:30AM | `[1,2,5]` -> `[1,2,4,5]` | Correct; fake-green Thursday sweep removed |
| 11 | `COLUMBUS_AVENUE_WEST_81ST_STREET_WEST_77TH_STREET_E_6` (EXCEPT) | TAXI/FHV 7:30AM-7PM EXCEPT SUNDAY | `[1-6]` unchanged | Correct, no regression |
| 12 | `CHRISTOPHER_STREET_BLEECKER_STREET_HUDSON_STREET_N_4` (EXCEPT) | NO STOPPING EXCEPT VEHICLES WITH DOT THEATRE PERMIT | `[1-6]` windowless -> anytime `[0..6]` | Correct, more red |
| 13 | `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1` (abbrev) | ASP 11AM TO 12:30PM WED (SUPERSEDED BY PS-84B) | `[1-6]` all-day -> `[3]` all-day | Matches text; see finding 2b |
| 14 | `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1` (EXCEPT) | ASP 8AM-8:30AM EXCEPT SUNDAY | `[1-6]` unchanged | Correct |
| 15 | `WEST_31ST_STREET_5TH_AVENUE_BROADWAY_N_1` (taxi) | TAXI RELIEF STAND 1 HOUR LIMIT MONDAY-FRIDAY 6PM-2AM SATURDAY & SUNDAY ALL DAY | `[1-5]` -> `[1-5] 1080-120` + `[0,6]` all day (ranges empty) | Correct; Swift treats empty ranges + days as all-day on those days |
| 16 | `6TH_AVENUE_WEST_21ST_STREET_WEST_22ND_STREET_E_0` (taxi) | TAXI STAND FRIDAY-SUNDAY MIDNIGHT-5AM | `[5,0]` -> `[0,5,6]` | Correct; old build had dropped Saturday (fake-green) |
| 17 | `AVENUE_B_EAST_3RD_STREET_EAST_4TH_STREET_E_1` (abbrev) | NO STANDING FRI-SUN MIDNIGHT-6AM | `[1-6]` -> `[0,5,6]` | Literal reading; see judgment below |
| 18 | `WEST_30TH_STREET_8TH_AVENUE_7TH_AVENUE_S_0` (abbrev) | NO STANDING SAT & SUN 1AM-6AM | `[1-6]` -> `[0,6]` | Literal reading |
| 19 | `CATHEDRAL_PARKWAY_BROADWAY_AMSTERDAM_AVENUE_S_7` (taxi-class NLZ) | NLZ LOADING ONLY MON-FRI 8AM-6PM SAT & SUN 10AM-11PM | weekend window was on weekdays -> `[1-5] 8-6PM` + `[0,6] 10AM-11PM` | Correct; Tue 8PM green is what the sign says |
| 20 | `BARCLAY_STREET_GREENWICH_STREET_WEST_STREET_N_0` | 3 HMP BUSES WITH PERMIT ONLY MON-FRI 10AM-4PM SAT 7AM-7PM | `[1-5] 7AM-7PM` -> `[1-5] 10-4` + `[6] 7-7` | Matches text; weekday 7-10AM and 4-7PM now open. Found by all-hours scan, not in the PR's list |
| 21 | `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2` | METERED MON-FRI 7PM-10PM SAT 7AM-10PM (only sign on segment) | weekdays 7AM-10PM -> 7-10PM | Matches text; see finding 2a |
| 22 | `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1` | METERED MON-FRI 1PM-7PM SAT 8:30AM-7PM + ASP | split | Matches text; finding 2a |
| 23 | `9TH_AVENUE_WEST_13TH_STREET_WEST_14TH_STREET_W_1` | METERED MON-FRI 4PM-11PM SAT 7AM-11PM, commercial-only M-F 7AM-4PM, NO STANDING FRI-SUN MIDNIGHT-6AM | split + FRI-SUN | Correct per text |
| 24 | `2ND_AVENUE_EAST_52ND_STREET_EAST_51ST_STREET_W_1` | METERED MON-FRI 7PM-10PM SAT 9AM-10PM + commercial M-F 7-7 + FRI-SUN | split + FRI-SUN | Correct per text |
| 25 | `PARK_AVENUE_SOUTH_EAST_29TH_STREET_EAST_28TH_STREET_W_1` | commercial-only M-F 7AM-7PM + FRI-SUN + ASP TUE THU SAT 4:30-6AM | FRI-SUN only change | Correct per text |
| 26 | `EAST_HOUSTON_STREET_ORCHARD_STREET_LUDLOW_STREET_S_0` | TRUCK LOADING 7AM-7PM EXCEPT SUNDAY + FRI-SUN MIDNIGHT-6AM | FRI-SUN change | Correct per text |
| 27 | `LUDLOW_STREET_DELANCEY_STREET_BROOME_STREET_W_1` (new in all-hours scan) | NO STANDING FRI-SUN MIDNIGHT-6AM | Mon 12-6AM now open | Literal reading |

### Red-to-green: all 46 segments (36 from PR, plus 10 more from an all-hours scan)

Groups, with a verdict from the sign text:

1. `NO STANDING FRI-SUN MIDNIGHT-6AM` (26+9 rules on Avenue B / E 2nd-4th / Christopher / E 12th / Ludlow / Essex / Houston etc.). Old `[1-6]` was an accident of the Mon-Sat default; new `[0,5,6]`. Open cells are Mon 12-6AM (and Wed/Thu 12-6AM). Correct under literal reading. See judgment.
2. `NO STANDING SAT & SUN 1AM-6AM` (`WEST_30TH_STREET_8TH_AVENUE_7TH_AVENUE_S_0`..`_S_5`, `_N_3`..`_N_7`). Same.
3. METERED `MON-FRI <hrs> SAT <hrs>` where the weekday window had been inflated by the Saturday hours: `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2`, `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1`, `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1`, `9TH_AVENUE_WEST_13TH_STREET_WEST_14TH_STREET_W_1`, `2ND_AVENUE_EAST_52ND_STREET_EAST_51ST_STREET_W_0/_1/_2`, `2ND_AVENUE_EAST_53RD_STREET_EAST_52ND_STREET_W_1/_2/_3`, `2ND_AVENUE_EAST_54TH_STREET_EAST_53RD_STREET_W_1`, `PARK_AVENUE_SOUTH_EAST_29TH_STREET_EAST_28TH_STREET_W_1/_2/_3`. All correct against the text (see finding 2a for 3 of them).
4. NLZ `CATHEDRAL_PARKWAY_BROADWAY_AMSTERDAM_AVENUE_S_7`: correct.
5. ASP WED `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1`: correct against text, with a caveat (2b).
6. `BARCLAY_STREET_GREENWICH_STREET_WEST_STREET_N_0` / `_N_1` buses-with-permit: correct against text.

None is a restriction that now applies on fewer days than the sign states. I found no red-to-green that contradicts its sign text.

## Judgment: FRI-SUN / SAT & SUN midnight windows

**What the PR does:** reads the window literally, as the clock hours of the named days. `FRI-SUN MIDNIGHT-6AM` = 12-6AM on Friday, Saturday and Sunday mornings (`[0,5,6]`, `0-360`). Monday 12-6AM is therefore not covered; Sunday night into Monday is not restricted.

**NYC DOT convention:** a posted day set plus a time range means those clock hours on those calendar days. DOT signs do not carry an "overnight into the next day" meaning; a restriction meant to continue past midnight is written as a wrapping range (e.g. `10PM-6AM`), which this parser does handle as a wrap. So the literal reading is the standard one and it is also the reading that matches the existing `ALL DAYS` midnight signs. It is not really ambiguous for the legal meaning; the only open question is intent (a nightlife regulator might have meant "Fri/Sat/Sun nights"), and the sign text cannot settle that.

**Safe-choice reading:** the red-heavy alternative adds Monday (day after the last named day) for any window whose start is 12AM. It would turn about 32 Overnight cells at Sun 10 AM red again (the `Overnight@Sun 10 AM` cells above), and also close Mon 3AM A Few Hours.

**Recommendation:** do not hold this PR for it. The literal reading is the legally correct one, the old red was accidental, and it is a published sign. If Kevin wants the conservative product posture applied to the ambiguous "sign intent vs. clock" case, make it a separate explicit rule in the parser ("window starting at 12AM on days D also covers D+1 12AM-end"), applied to the NO_STANDING nightlife family only, and rebuild. I list it as a follow-up product call (finding 6), not a defect.

## Evaluator port check (`scripts/diff-tiles-days.js` vs Swift)

Compared line by line with `ParkingRulesEngine.isFree` and `ParkingGoals.match`/`target`/`overnightEnd`:
- `anytime` fast path, `dayOffset` walk from -1, ASP day gate + `rule.days` gate, empty `timeRanges` all-day behavior for ASP/NO_PARKING/TRUCK/NO_STANDING/SPECIAL (skipped on `dayOffset < 0`), metered branch (no ranges = no conflict), wrap overlap, `wrapsPastMidnight` (`start >= endMinute`), `endMinute` (0 -> 1440): all identical.
- ASP day sets (`isASPDay`) identical, including ASP_DAILY = Mon-Sat.
- Goals: `ignoringMeteredPayment: false` in all three goals (current Swift, not the older comment text in `isFree` docs). The port matches current code. A Few Hours = min(from+3h, overnightEnd); Overnight = next 7AM; Park & Forget ladder `[8,4,2]` via `startOfDayET`. Match.
- Known limits the PR states are real but immaterial for Dec 6 week: no DST, ASP suspensions not applied.
- One limit the PR does not state: its probes are four instants. My all-hours rescan (7x24, 3 goals) is what produced the 10 extra red-to-green segments. No mismatch with Swift was found, so no change in the real app would be hidden by the port.

## Findings

### Blocking
None.

### Significant
- **#1: PR's red-to-green list is incomplete (4 probe times only)**
  - Where: `docs/qa/tiles-alldays-diff.md` "Every red->green case"; `scripts/diff-tiles-days.js` `TIMES`.
  - What: all-hours scan gives 46 red-to-green segments, not 36. The 10 extra are `BARCLAY_STREET_GREENWICH_STREET_WEST_STREET_N_0/_N_1` (buses-with-permit, Mon-Fri 7-10AM/4-7PM) and `LUDLOW_STREET_DELANCEY_STREET_BROOME_STREET_W_0/_1/_2`, `ESSEX_STREET_RIVINGTON_STREET_DELANCEY_STREET_W_1/_2/_3`, `ESSEX_STREET_STANTON_STREET_RIVINGTON_STREET_W_1/_2` (FRI-SUN midnight, Mon 12-6AM). All correct against the sign text, so this is a reporting gap not a data bug.
  - Expected: the report's claim "all red-to-green explained" should be backed by a full-week scan.
  - Owner: `@backend-data` (doc only; do not block the merge).

- **#2: Three Saturday-split metered segments go green on weekday daytime because the segment's only sign is the evening meter (2a), and one red-to-green rides on a superseded ASP sign (2b)**
  - Where (2a): `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2` (only sign: `2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 7AM-10PM`; sibling `_E_0`/`_E_1` of the same blockface carry `3 HMP COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM`); `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1` (sibling `_S_2` has `TRUCK LOADING ONLY MONDAY-FRIDAY 8:30AM-1PM`); `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1` (sibling `_E_2` has the same truck loading).
  - What: text-correct, but a real curb on that blockface is likely restricted weekday mornings by the sign that landed on a neighbouring sub-segment. Before the PR these read red on weekdays by accident (Saturday hours leaked onto weekdays). After, `A Few Hours @ Tue 10 AM` is green. This is a pre-existing sign-to-sub-segment distribution limit, exposed rather than created.
  - Where (2b): `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1`: only restriction text is `NO PARKING (SANITATION BROOM SYMBOL) 11AM TO 12:30PM WED (SUPERSEDED BY PS-84B)`; the superseding sign PS-84B is not in the segment (43 tile rules carry "SUPERSEDED BY"). Now green Tue and Sat; was red Mon-Sat (accidentally).
  - Expected: under "when unsure, not parkable", a blockface whose only evidence is a superseded sign, or whose siblings carry a weekday restriction this sub-segment lacks, should stay red.
  - Repro: `node scripts/diff-tiles-days.js` on before/after, or read the tile for each id.
  - Owner: `@backend-data`. Not caused by this PR; log for a follow-up (propagate blockface-level weekday restrictions to sibling sub-segments; treat `SUPERSEDED BY` with no successor as unknown/red). Does not block the merge since the PR moves the dataset red-ward in aggregate (about 126,000 green-to-red cells vs 4,232 red-to-green across the whole week).

### Minor
- **#3: One sign still loses a day to a typo; "0 unparsed" is slightly overstated**
  - Where: `WEST_62ND_STREET_BROADWAY_COLUMBUS_AVENUE_N_2` (and one sibling): `ASP_MON_THU ... MONDAY THURSDA 9AM-9:30AM`. `DAY_TOKEN` needs `\b` after the day word, so `THURSDA` does not match; days stay `[1]` (Monday only) and the Thursday sweep is not enforced (the engine also gates on `rule.days`). Identical to before the PR (not a regression); the fail-safe counter did not fire because days were non-empty.
  - Expected: Monday and Thursday. Fix by making `DAY_TOKEN` tolerant of `THURSD?A?Y?` or, for ASP categories, intersecting with the category's day set.
  - Owner: `@backend-data`.

- **#4: Hotel loading "OTHER TIMES HOTEL LOADING ZONE" only restricts the stated windows (pre-existing)**
  - Where: `MADISON_AVENUE_EAST_30TH_STREET_EAST_31ST_STREET_E_3` (`NO STANDING 7AM-10AM 4PM-7PM EXCEPT SUNDAY OTHER TIMES HOTEL LOADING ZONE`, `[1-6]`, `420-600/960-1140`), `EAST_50TH_STREET_LEXINGTON_AVENUE_3RD_AVENUE_S_3` (`NO STANDING MONDAY-FRIDAY 7AM-10AM 4PM-7PM OTHER TIMES HOTEL LOADING ZONE`). Text says that other times it is a hotel loading zone, i.e. not parkable. Unchanged by this PR (confirmed same before/after). Log only.
  - Owner: `@backend-data`.

- **#5: Cosmetic duplicate description in `BlockDetailView` for split signs**
  - `BlockDetailView.rowText` renders `rule.description`; a split sign now emits two rules with the same description (e.g. `WEST_31ST_STREET_5TH_AVENUE_BROADWAY_N_1`). Segments already repeat a description for `<->` and `-->` variants, so users already see near-duplicates. Not merge-blocking. Owner: `@ios-engineer` (optional: show the clause's days/hours instead of the raw text).

- **#6: Product call, not a defect: conservative midnight rule** (see judgment). Owner: product.

- **#7: PWA invariant note.** Root `tiles/*.json` changed and `sw.js` `CACHE_VERSION` (`wepark-v40`) was not bumped; the SW serves `tile_*.json` cache-first. HANDOFF says asset changes require a bump. iOS bundles its own tiles so it is unaffected. Out of scope for the iOS ship; flag to `@pwa-maintainer` if the PWA is still served.

### Out of scope (logged, not fixed)
- ASP time ranges written `8:30-10AM` or `11AM TO 12:30PM` do not parse, so those rules are all-day on their days (over-red). Pre-existing.
- 49 METERED rules with no hours. Pre-existing.

## Smoke tests run

- `node scripts/test-day-parsing.js`: **34 passed, 0 failed.**
- Existing script tests: `test-sign-reclassification` PASS; `test-arrow-direction-fix` 26/0; `test-bowery-detour` PASS; `test-pipeline-determinism` PASS (205 blocks x 10 trials); `test-width-offset-resurrection` 41/0.
- Rebuilt tiles: `SIGNS_CACHE_PATH=<signs.json, 96,268 signs> TILES_OUTPUT_DIR=<tmp> node build/preprocess.js`. Result byte-identical to committed (only `index.json generatedAt`). Fail-safe stats: 0 unparsed fallbacks, 0 all-day widenings.
- Schema check over all 47,209 segments (keys above, days in 0..6, none empty).
- Sign-family regression scans (changed buckets, lost-coverage buckets, named-day-uncovered), and all-hours red-to-green scan (3 goals x 168 hours x 2,555 changed segments).
- iOS: `xcodebuild test -only-testing:WeParkTests` on a dedicated sim (`qa190-iphone`), derivedData `~/Library/Caches/qa190-dd`: `** TEST SUCCEEDED **`, 2,924 test cases passed, 0 failed (against the new bundled tiles; sim and derivedData deleted after). UI was not run (the PR touches no Swift and no mount-chain file; tile data only).

## What's working

- The root-cause diagnosis is right and the fix is conservative: it unions days (can over-apply, never under-covers), keeps fail-safe fallbacks, and only splits clauses when the sign is cleanly days-first.
- The tile rebuild is deterministic and reproducible from the cached pull; the A/B isolates this change.
- It removes real fake-greens: about 2,300 metered blocks (per the PR diff tool, which I reproduced) that read free on Saturday afternoon, the Sunday-only truck-loading rules, dropped Saturday on `FRIDAY-SUNDAY`, the Thursday sweep on the typo sign, permit-theatre no-stopping now anytime.
- Test script and diff tool are small, readable, and honest about their limits.

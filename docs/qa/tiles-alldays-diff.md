# Tiles day-parse fix: "ALL DAYS" -> Sunday-only, and dropped weekend clauses (diff report)

Branch `fix/tiles-alldays-dayparse`. Scope: `build/preprocess.js` `parseSchedule` and the regenerated tiles. No deploy, no Supabase.

## Root cause

`parseSchedule` (build/preprocess.js) built `days` from a chain of exclusive branches: `MON-SAT` regex, else `MON-FRI` regex, else "every full day NAME that appears in the text". The `ALL DAYS` token was only honored when that list was empty (`if (result.days.length === 0 && allDaysToken)`).

- Sign text `TRUCK LOADING ONLY 7PM-7AM ALL DAYS SUNDAY 7AM-7PM` names SUNDAY, so the name scan produced `[0]` and the `ALL DAYS` token (added by PR #180) was skipped. This is a path PR #180 missed, not a regression of its fix: #180 only handled the case with no other day word.
- Same shape of bug, same function:
  - `MONDAY-FRIDAY ... SATURDAY ...` kept only the MON-FRI branch, so the Saturday/weekend clause was dropped (taxi stands, NLZ, and ~2.7K metered rules whose Saturday meter hours were missing).
  - Abbreviations (`SAT & SUN`, `FRI-SUN`, `MON & THURS`, `WED`) were not in the name table, so they fell to the Mon-Sat default.
  - `EXCEPT SATURDAY` alone fell to Mon-Sat, which includes Saturday.
  - Day ranges other than MON-FRI/MON-SAT, e.g. `WEDNESDAY-SUNDAY`, came out as just the two end days.
  - The window of one clause was applied to the other clause's days in a few cases, because one range list served the whole sign.

## Fix

- New `parseDayPhrases`: union of every day phrase (ranges with wraparound, lists, abbreviations, `WEEKDAYS`/`WEEKENDS`, `ALL DAYS`/`DAILY`/`EVERY DAY`/`7 DAYS`, `EXCEPT <day list>`). `ALL DAYS` next to explicit days unions to all seven (fail-safe).
- New `splitDayClauses`: days-first multi-clause signs (`MON-FRI 7PM-MIDNIGHT SAT 9AM-MIDNIGHT`, `MON-FRI 6PM-2AM SAT & SUN ALL DAY`) now emit one rule per clause (same rule shape), so no clause's window leaks onto another clause's days.
- Fail-safe: a restriction with no parseable day applies every day (and is `anytime` if it has no hours). Day words present but unparsed apply every day and are counted: `DAY_PARSE_STATS` is printed at the end of the build. This run: 0 fallbacks (every day word in the data parses).
- Not changed (deliberate): `SCHOOL DAYS` keeps its historical Mon-Sat default (conservative, over-applies Saturday).
- Tests: `scripts/test-day-parsing.js` (34 checks, offline). Existing `test-sign-reclassification`, `test-arrow-direction-fix`, `test-bowery-detour`, `test-pipeline-determinism`, `test-width-offset-resurrection` still pass.

## How the diff was computed

- Same-pull A/B: both builds used one cached Socrata pull (`SIGNS_CACHE_PATH`, the pull from the #180 regen) plus the committed `osm_data.json`. The "before" build from `origin/main` code reproduces the committed tiles with `compare-tilesets.js`: zero rule drift. So every difference below is the day-parse change alone, not NYC data drift. The committed tiles were regenerated from that same cache (the normal `node build/preprocess.js` writes `tiles/` and syncs `ios/WePark/WePark/Resources/tiles/`; same delivery pattern as #180).
- Engine: the repo had no Node evaluator. `scripts/diff-tiles-days.js` is a minimal port of `ParkingRulesEngine.isFree` (midnight-aware ranges from PR #189, anytime fast path, ASP day sets, metered not free) and `ParkingGoals.match`. It is not committed as a product engine; it is an audit tool. Port limits: ET wall clock as a linear axis (probe dates have no DST change), ASP suspensions not applied (none fall in the probe dates).
- Goals per `ParkingGoals.swift`: A Few Hours = now to min(+3h, next 7 AM); Overnight = now to next 7 AM; Park & Forget = first free rung of day offsets 8, 4, 2.
- Probe times (all `2026-12-06` week): Tue 10 AM, Tue 8 PM, Sat 2 PM, Sun 10 AM.
- Verdicts are only evaluated on the 2,531 segments whose rules changed (segments with unchanged rules cannot move; verified: 0 segments differ outside the changed set).
- Reproduce: `node scripts/diff-tiles-days.js <beforeDir> <afterDir>`.

## Rules changed

47,209 segments before and after, same ids. 70,102 sign-rules examined (a sign-rule = category + description on a segment). 2,880 changed `days` and/or windows (2,531 segments; day lists compared sorted, so pure re-ordering is not counted). Counts below are sign-rules.

| Sign family | Rules changed |
|---|---|
| MON-FRI clause + weekend/Saturday clause (weekend part was dropped; mostly METERED "MONDAY-FRIDAY ... SATURDAY ...") | 2,730 |
| Abbreviated day names (`SAT & SUN`, `MON & THURS`, `WED`) | 56 |
| Day range other than MON-SAT/MON-FRI (`FRI-SUN`, `WEDNESDAY-SUNDAY`) | 47 |
| `ALL DAYS` next to an explicit day clause (truck loading) | 40 |
| Other (ASP sign typo `THU RSDAY`, Thursday had been lost) | 1 |
| No day named, `EXCEPT <non-day>` (was Mon-Sat, now every day) | 5 |
| Weekday window + `SAT & SUN ALL DAY` (taxi relief stand) | 1 |

Shipped tiles check: 0 rules whose text says `ALL DAYS` (without EXCEPT) have fewer than 7 days; 0 rules have empty `days`.

### 10 examples (segment id, before -> after)

1. `3RD_AVENUE_EAST_34TH_STREET_EAST_35TH_STREET_E_0`, TRUCK_LOADING `7PM-7AM ALL DAYS SUNDAY 7AM-7PM`: days `[0]` -> `[0,1,2,3,4,5,6]`.
2. `3RD_AVENUE_EAST_34TH_STREET_EAST_35TH_STREET_E_1`, same sign: `[0]` -> `[0..6]`.
3. `BROAD_STREET_SOUTH_STREET_WATER_STREET_N_0`, METERED `MONDAY-FRIDAY 10AM-7PM SATURDAY 9AM-7PM`: one rule `[1..5]` carrying both windows -> `[1..5] 10AM-7PM` + `[6] 9AM-7PM`.
4. `BROADWAY_EAST_HOUSTON_STREET_PRINCE_STREET_E_0`, METERED `MON-FRI 6PM-10PM SAT 8AM-10PM`: `[1..5]` both windows -> `[1..5] 6-10PM` + `[6] 8AM-10PM`.
5. `WEST_31ST_STREET_5TH_AVENUE_BROADWAY_N_1`, SPECIAL taxi relief stand `MONDAY-FRIDAY 6PM-2AM SATURDAY & SUNDAY ALL DAY`: `[1..5]` -> `[1..5] 6PM-2AM` + `[0,6] all day`.
6. `AVENUE_B_EAST_3RD_STREET_EAST_4TH_STREET_E_1`, NO_STANDING `FRI-SUN MIDNIGHT-6AM`: `[1..6]` -> `[0,5,6]`.
7. `WEST_30TH_STREET_8TH_AVENUE_7TH_AVENUE_S_0`, NO_STANDING `SAT & SUN 1AM-6AM`: `[1..6]` -> `[0,6]`.
8. `THOMPSON_STREET_BLEECKER_STREET_WEST_HOUSTON_STREET_W_0`, ASP_MON_THU `11AM TO 12:30PM MON & THURS`: `[1..6]` -> `[1,4]`.
9. `WATER_STREET_PINE_STREET_WALL_STREET_W_0`, ASP_DAILY `MONDAY TUESDAY THU RSDAY FRIDAY 6AM-7:30AM` (typo in the source sign text): `[1,2,5]` -> `[1,2,4,5]` (Thursday sweep day was missing).
10. `CHRISTOPHER_STREET_BLEECKER_STREET_HUDSON_STREET_N_4`, NO_STANDING `NO STOPPING EXCEPT VEHICLES WITH DOT THEATRE PERMIT`: `[1..6]` -> `[0..6]` (restriction with no day applies every day; Sunday was green).

## Verdicts (segments whose rules changed; 2,531 segments)

Green->red is the fix working. Red->green appears only where an old rule was wrongly over-applied.

| Goal @ time | green->red | red->green |
|---|---|---|
| A Few Hours @ Tue 10 AM | 0 | 4 |
| A Few Hours @ Tue 8 PM | 11 | 2 |
| A Few Hours @ Sat 2 PM | 2,315 | 1 |
| A Few Hours @ Sun 10 AM | 7 | 0 |
| Overnight @ Tue 10 AM | 0 | 0 |
| Overnight @ Tue 8 PM | 11 | 24 |
| Overnight @ Sat 2 PM | 2,233 | 1 |
| Overnight @ Sun 10 AM | 1 | 32 |
| Park & Forget @ Tue 10 AM | 0 | 0 |
| Park & Forget @ Tue 8 PM | 0 | 8 |
| Park & Forget @ Sat 2 PM | 2,196 | 1 |
| Park & Forget @ Sun 10 AM | 0 | 9 |

Reading it:

- Sat 2 PM is the big one (about 2.2K green->red): Saturday meter hours on `MONDAY-FRIDAY ... SATURDAY ...` metered signs were absent from the tiles, so those blocks read green on Saturday afternoon although the meter runs. Meters are not free in any goal.
- Weekday 8 PM and Sunday 10 AM g->r are the truck-loading/taxi/NLZ weekend clauses and the Sunday-only `ALL DAYS` rules.

### Every red->green case (36 distinct segments, 82 goal/time cells; all fall in these 5 groups)

All are the removal of an old over-application. None is a restriction that now applies on fewer days than the sign states.

1. **`FRI-SUN MIDNIGHT-6AM` NO_STANDING** (e.g. `AVENUE_B_EAST_3RD_STREET_EAST_4TH_STREET_E_1`; Overnight and Park & Forget at Tue 8 PM and Sun 10 AM): old days `[1..6]` (the Mon-Sat default; the abbreviation was not parsed), new `[0,5,6]`. The sign never applied Mon-Thu, so a car parked Tue 8 PM was wrongly red for Wednesday 12-6 AM. Sunday-night-to-Monday: the new reading follows the sign text literally (SUN 12AM-6AM, Sunday morning). If DOT intends "Sunday night into Monday 6AM", Monday 12-6 AM is now free where the old default covered it by accident. Worth a human look; it is the one semantic judgment call in this report.
2. **`SAT & SUN 1AM-6AM` NO_STANDING** (`WEST_30TH_STREET_8TH_AVENUE_7TH_AVENUE_S_0`, `_S_1`, `_N_5`, `_N_7`): old `[1..6]`, new `[0,6]`. Same reasoning as 1; the same Sunday-into-Monday note applies.
3. **METERED `MONDAY-FRIDAY 7PM-10PM SATURDAY 9AM-10PM` (and the 6PM/7PM/4PM/1PM variants)** (`2ND_AVENUE_EAST_52ND_STREET_EAST_51ST_STREET_W_1`, `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2`, `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1`, `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1`, `9TH_AVENUE_WEST_13TH_STREET_WEST_14TH_STREET_W_1`, `2ND_AVENUE_EAST_53RD_STREET_EAST_52ND_STREET_W_3`, `2ND_AVENUE_EAST_54TH_STREET_EAST_53RD_STREET_W_1`, `_W_2`): old tile applied Saturday's long window (e.g. 9AM-10PM) to Mon-Fri, so a weekday morning read as metered although the weekday sign starts at 7PM. New tile: weekdays 7PM-10PM and Saturday 9AM-10PM. (Those segments are red on Saturday now.)
4. **SPECIAL NLZ `MONDAY-FRIDAY 8AM-6PM SATURDAY & SUNDAY 10AM-11PM`** (`CATHEDRAL_PARKWAY_BROADWAY_AMSTERDAM_AVENUE_S_7`, Tue 8 PM, A Few Hours and Overnight): the weekend 10AM-11PM window was being applied to Mon-Fri, so Tuesday 8 PM read red. New: weekdays 8AM-6PM, weekend 10AM-11PM.
5. **ASP_DAILY `NO PARKING (SANITATION BROOM) 11AM TO 12:30PM WED`** (`BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1`): `WED` was not parsed, so the cleaning rule applied Mon-Sat. New: Wednesday only. Note `11AM TO 12:30PM` is not parsed as a time range (the time regex does not accept `TO`), so on Wednesday the rule is all-day: still over-restrictive on Wednesday, correct on the other five days.

No red->green case is unexplained.

## Known limits (all fail-safe, no fake green introduced)

- `ALL DAYS` next to another day clause (40 truck-loading rules) uses the union: the `SUNDAY 7AM-7PM` window is also applied on weekdays (extra red; truck-loading is red for a private car anyway).
- `SCHOOL DAYS` stays Mon-Sat (over-applies Saturday).
- Times written `11AM TO 12:30PM` produce no time range (pre-existing, separate from day parsing): ASP rules become all-day on their days.
- 49 METERED rules have no hours at all (ParkNYC meterless pilot, "HOUR METERED PARKING (FOR BUS STOP ONLY)"); pre-existing, not touched here.

## Tile format and iOS

- Schema unchanged. Segment keys: `id, street, from, to, side, line, rules, dominantCategory, oneway, oneway_toward`. Rule keys: `category, description, days, timeRanges, anytime, arrow, temporary?`. Same as before; `index.json` differs only in `generatedAt`.
- 348 tile files changed (of 976). Segment count 47,209, ids identical, geometry identical.
- The one structural difference is data, not format: a multi-clause sign now appears as 2 rules (one per clause) instead of 1. The iOS engine already evaluates any number of rules per segment. Cosmetic only: `BlockDetailView`'s rule list renders `rule.description`, so a split sign lists its full text twice. No iOS change is required for correctness.

# Tile residual fake spots: segmentation gap, superseded signs, truncated tokens (diff report)

Branch `fix/tiles-residual-fake-spots`, follow-up to PR #190 and `docs/qa/pr190-tiles-alldays-qa.md` finding 2. Scope: `build/preprocess.js`, regenerated tiles (`tiles/` and the iOS bundle), one cosmetic iOS change. No deploy, no Supabase.

Product rule applied throughout: never show a spot that isn't a spot; when unsure the curb reads not parkable.

## Method (same as #190, plus attribution)

- One cached Socrata pull (`SIGNS_CACHE_PATH`, 96,268 signs, the pull #190 used) plus the committed `osm_data.json`. The "base" build from `origin/main` code reproduces the committed tiles byte for byte (only `index.json generatedAt` differs), so every difference below is this change alone.
- Each fix has an audit switch (`RESIDUAL_FIXES_OFF=glyph,companion,superseded,meteredhours`, unset in real regens). `scripts/diff-tiles-residual.js` rebuilds with one fix off and attributes each changed segment to exactly that fix. Segments changed vs base but attributed to no switch are the parser fixes.
- Segments are matched by geometry, not id: the id ends in the zone index, which shifts when a fix makes a previously rule-less zone appear.
- Engine: `scripts/diff-tiles-days.js` (verified port of `ParkingRulesEngine.isFree` + `ParkingGoals`). Probe times are #190's: Tue 10 AM, Tue 8 PM, Sat 2 PM, Sun 10 AM (week of 2026-12-06). I also scanned the full week (3 goals x 168 hours x every changed segment), because #190's QA showed 4 probe times can hide red->green.
- Reproduce: `node scripts/diff-tiles-residual.js <baseDir> <fullDir> --off glyph=<dir> --off companion=<dir> --off superseded=<dir> --off meteredhours=<dir>`.

## Headline

| | Count |
|---|---|
| Segments, base -> after | 47,209 -> 47,696 |
| Segments whose rules changed | 1,269 |
| New segments (a curb section that had no rule at all, now drawn) | 487 |
| Segments removed | 0 |
| **red->green, all 3 goals x 168 hours, every changed segment** | **0 cells, 0 segments** |
| New segments that are ever green (3 goals x 168 hours) | 0 |

## Counts per fix

A segment can be changed by more than one fix, so the rows overlap (sum is larger than 1,269).

| Fix | Changed segments | New segments |
|---|---|---|
| 1a. Arrow glyph `<--->` / `<----->` read as one direction (root cause of 2 of the 3 named gaps) | 1,120 | 487 |
| 1b. Meter pole-mate (commercial / truck loading) not following the meter (8th Ave case) | 104 (109 zone-rules, 90 block faces) | 0 |
| 2. Superseded sign is the only live sign -> no-data | 52 flagged (45 existing segments + 7 zones that only now exist) | 7 of the 487 |
| 3a. Truncated / misspelled day words, `MONDAY THURSDA` and `STAURDAY` | 4 | 0 |
| 3b. METERED sign with no readable hours -> meter runs all day | 41 | 0 |
| 4. iOS `BlockDetailView` duplicate description | display only | |

## 1. Segmentation gap

### Root causes (two distinct ones)

**Glyph parse (`WEST_181ST...S_1`, `ST_NICHOLAS...E_1`).** `parseSchedule` set `arrow = 'both'` only for the exact string `<->`. Every longer double-headed shaft (`<--->` 61 signs, `<----->` 922, `<---->` 103, `<------>` 29, `<------->` 18, `<-->` 5; 1,138 in all) fell through to the `-->` substring test and was read as `towards`. A `towards` sign covers only from its pole forward, so the zone between the previous sign and a `<--->` pole got no rule from it. For St Nicholas the pole carrying `TRUCK LOADING ONLY MONDAY-FRIDAY 8:30AM-1PM <--->` sits at 91 ft with the evening meter `<->`; the truck-loading rule only reached forward, so the sub-segment before it carried only the 1PM-10PM meter and read green on weekday mornings. Same cause explains the 487 curb sections that had no rule at all (a zone before a bus stop `<----->` pole was dropped as rule-less, so nothing was drawn there).

**Pole-mate with its own arrow (`8TH_AVENUE...E_2`).** The commercial sign and the meter sign share the pole at 203 ft, but the commercial sign is `-->` with `arrow_direction = South`. The #26 arrow-direction logic (correctly) resolves it to "covers before the pole", so the tail zone after 203 ft keeps only the meter sign (`<->`, 7PM-10PM): green all weekday daytime. No glyph is wrong here; two signs on one pole simply disagree about coverage.

### Fix

1. `/<-+>/` (any shaft length) is `both`.
2. `extendMeterCompanions` (conservative, only ever adds): wherever a METERED sign applies to a zone, every timed hard-restriction sign (NO_PARKING / TRUCK_LOADING / SPECIAL / NO_STANDING, not anytime, not temporary, not superseded) at the same pole (same `distance_from_intersection`) applies to that zone too.

### Whole-Manhattan search for the pattern

Pattern: a sub-segment green at Tue 10 AM whose only timed rule is a meter, while a sibling sub-segment of the same block face carries a weekday-daytime commercial / truck-loading restriction. Base tiles: 4 segments. After: 0.

| Segment | Cause | Fixed by |
|---|---|---|
| `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2` | pole-mate arrow | companion |
| `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1` | `<--->` glyph | glyph |
| `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1` | `<--->` glyph | glyph |
| `6TH_AVENUE_WEST_21ST_STREET_WEST_22ND_STREET_E_0` | ParkNYC meterless-pilot sign with no hours read as no meter | metered-hours (3b) |

A wider search (any meter-only segment with any sibling timed hard rule, regardless of pole) finds about 600 segments. I did not extend those: most are different curb regulations on different parts of a face (a truck-loading zone at one end, a meter elsewhere), and extending across poles has no evidence behind it. Listed under "Left unresolved".

Companion extension is also the only change that can over-apply a window a few feet past where DOT meant it, always toward red.

### Examples (sign text, after)

- `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2`: `2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 7AM-10PM` + (new) `3 HMP COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM -->`. Weekday 7AM-7PM commercial, 7PM-10PM meter. Tue 10 AM now red.
- `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1`: gained `TRUCK LOADING ONLY MONDAY-FRIDAY 8:30AM-1PM <--->` next to `2 HMP MONDAY-FRIDAY 1PM-7PM SATURDAY 8:30AM-7PM`.
- `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1`: same truck-loading sign added.
- `BOWERY_GREAT_JONES_STREET_BOND_STREET_W_1`: gained `NO PARKING 8AM-6PM EXCEPT SUNDAY -->` next to `2 HMP 7:30AM-7PM EXCEPT SUNDAY`.
- `LAFAYETTE_STREET_GREAT_JONES_STREET_EAST_4TH_STREET_E_1`: gained `TAXI HAIL (SYMBOL) TAXI STAND 7PM-7AM ALL DAYS -->`.
- New segment (glyph): `1ST_AVENUE_EAST_2ND_STREET_EAST_3RD_STREET_E_1`, `BUS STOP SIGN (BUS & HANDICAP SYMBOLS) NO STANDING <----->` (anytime). Before: nothing drawn.

## 2. Superseded signs

Marker survey (all Manhattan records, 96,268 signs, all `record_type = Current`): 341 records match `SUPERSEDED BY` / `REPLACED BY` / `DO NOT USE AS PER`. Classes, largest first: NO STANDING / NO STOPPING ANYTIME superseded by an R7 plate; ASP broom signs superseded by an SP/PS plate (most with windows the engine cannot read, such as `11AM TO 12:30PM`, so they read all-day on their days); NO PARKING ANYTIME `DON'T USE R7-40`; truck-loading; FHV; a few muni-meter cards. Not markers: `SUPERSEDES X` (the normal "this sign replaced an older plate", 100K+ rows) and the typo `SUPERSED ES R7-1R` (that sign supersedes, it is current).

Only 201 of these are on blockfaces that make it into the tiles; the replacement named in the text is on the same face for 6 of them, missing for 195. The replacement is almost never in the dataset, so it cannot be resolved.

### Handling

- A superseded sign keeps restricting (never less red than before). Nothing is dropped.
- A sub-segment whose only live signs are unresolved superseded signs, none of them `anytime`, is flagged no-data. UNKNOWN-category signs (info panels, `ANGLE PARKING ONLY`) are not live data: they never restrict, so they cannot be what keeps the curb green.
- A superseded `NO STANDING ANYTIME` alone stays an ordinary red rule (already red). A superseded sign whose replacement is on the face is left as is.
- 52 segments are flagged. Examples: `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1` (`NO PARKING (SANITATION BROOM SYMBOL) 11AM TO 12:30PM WED <---> (SUPERSEDED BY PS-84B)`, plus `ANGLE PARKING ONLY`), `THOMPSON_STREET_BLEECKER_STREET_WEST_HOUSTON_STREET_W_1..4` (`... MON & THURS ... (SUPERSEDED BY SP-853C)`), `WASHINGTON_STREET_WEST_10TH_STREET_CHRISTOPHER_STREET_E_0`.

### How no-data is encoded (iOS finding)

The brief assumed an empty-rules segment draws as "don't". It does not in the goal modes: `ParkingRulesEngine.isFree` starts with `guard !rules.isEmpty else { return true }` ("Empty rules -> always free"), and Park Until / goal overlays call it directly, so a `rules: []` segment would draw GREEN there (the base map draws `.unknown` grey). No tile today has empty rules, so the path was dead; emitting one would have created a fake spot.

So a no-data segment is carried as `dominantCategory: "UNKNOWN"` plus an always-on rule `NO_PARKING "NO DATA - ONLY A SUPERSEDED SIGN ON RECORD - TREATED AS NOT PARKABLE"` (all days, `anytime: true`), with the superseded sign text kept under it. Red in every mode with no iOS engine change. Follow-up for iOS / design: a real no-data state (and `isFree(empty) == false`) would be cleaner, but that flips 22 test files' empty-rules fixtures, so it is out of scope here.

## 3. Truncated and misspelled tokens

### Day words

- `DAY_TOKEN` now accepts any prefix of a day name of 3 or more letters (nested optionals; `MONEY` still rejected). `MONDAY THURSDA` -> `[1,4]` (it was `[1]`). The broom-sign category flags use the same grammar, so `THURSDA` / `TUES` / `THURS` classify consistently with the day parse.
- Dataset scan (all Manhattan descriptions): exactly two distinct day defects: `THURSDA` (2 signs: `WEST_62ND_STREET_BROADWAY_COLUMBUS_AVENUE_N_2` and `_N_3`) and `STAURDAY` (`2 HMP MONDAY-FRIDAY 6PM-10PM STAURDAY 9AM-10PM -->`, `WEST_181ST_STREET_AUDUBON_AVENUE_ST_NICHOLAS_AVENUE_N_3`; Saturday used to be dropped, the Saturday window was applied Mon-Fri only). `MONEY` appears in 5 taxi-warning signs ("DON'T GIVE MONEY"), benign and explicitly allowed.
- Fail-safe: any word that starts like a day (MON TUE WED THU FRI SAT SUN) or ends in DAY/DAYS but is neither a day nor a >= 3-letter prefix of one (outside `WEEKDAY(S)`, `HOLIDAY(S)`, `EVERYDAY`) makes the sign apply every day. This run: 1 sign (`STAURDAY`), now all 7 days.

### Time tokens

- Scan: the time regex does not read `11AM TO 12:30PM`, `8:30-10AM`, `8-9:30AM`, `10A M-11:30AM`, `8AM-5A M`. In today's tiles every such sign has zero parsed ranges (all-day on its days = over-red, safe). No sign has a partially parsed list. Still, a stray unparsed time next to a parsed range would leave that window green, so the parser now drops all ranges in that case (rule applies all day on its days). This run: 0 occurrences; guard covered by tests.
- METERED with no readable hours (ParkNYC meterless pilot `APP PAYMENT ONLY ZONE`, `HOUR METERED PARKING (FOR BUS STOP ONLY)`, a `DO NOT USE` muni-meter card): empty ranges mean "no meter conflict" to the engine = free. Hours unknown, so the meter is now assumed to run all day (`00:00-24:00`) on its days. 41 segments (e.g. `6TH_AVENUE_WEST_15TH_STREET_WEST_16TH_STREET_W_0..2`). They were green outside the commercial window on Tue 8 PM and Sat 2 PM.

## Verdict changes (segments whose rules changed, 1,269; same 4 times as #190)

| Goal @ time | green->red | red->green |
|---|---|---|
| A Few Hours @ Tue 10 AM | 154 | 0 |
| A Few Hours @ Tue 8 PM | 195 | 0 |
| A Few Hours @ Sat 2 PM | 208 | 0 |
| A Few Hours @ Sun 10 AM | 191 | 0 |
| Overnight @ Tue 10 AM | 149 | 0 |
| Overnight @ Tue 8 PM | 196 | 0 |
| Overnight @ Sat 2 PM | 207 | 0 |
| Overnight @ Sun 10 AM | 214 | 0 |
| Park & Forget @ Tue 10 AM | 148 | 0 |
| Park & Forget @ Tue 8 PM | 148 | 0 |
| Park & Forget @ Sat 2 PM | 207 | 0 |
| Park & Forget @ Sun 10 AM | 159 | 0 |

Full-week scan (3 goals x 168 hours): 88,832 green->red cells, 0 red->green cells. The 487 new segments are never green in any goal at any hour of the week (all are bus-stop / no-standing / construction curbs), so no new spot appears.

### Per fix, green->red at the 4 probe times (A Few Hours / Overnight / Park & Forget)

| Fix | Tue 10 AM | Tue 8 PM | Sat 2 PM | Sun 10 AM |
|---|---|---|---|---|
| Glyph (1,120 segs) | 152 / 148 / 147 | 156 / 155 / 147 | 173 / 173 / 173 | 175 / 162 / 155 |
| Companion (104) | 2 / 1 / 1 | 5 / 7 / 1 | 2 / 1 / 1 | 9 / 14 / 1 |
| Superseded no-data (45 + new) | 15 / 14 / 14 | 22 / 21 / 21 | 40 / 40 / 40 | 45 / 45 / 45 |
| Metered no hours (41) | 1 / 1 / 1 | 33 / 33 / 32 | 32 / 31 / 31 | 0 / 0 / 0 |
| Parser day words (4) | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 1 / 1 | 1 / 1 / 1 |

red->green is 0 in every cell of every row. Nothing to explain.

## Examples (segment id, sign text, before -> after)

1. `8TH_AVENUE_WEST_27TH_STREET_WEST_28TH_STREET_E_2`: `METERED 2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 7AM-10PM` only -> + `NO_PARKING 3 HMP COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM`.
2. `WEST_181ST_STREET_WADSWORTH_AVENUE_ST_NICHOLAS_AVENUE_S_1`: meter + ASP only -> + `TRUCK LOADING ONLY MONDAY-FRIDAY 8:30AM-1PM <--->`.
3. `ST_NICHOLAS_AVENUE_WEST_185TH_STREET_WEST_186TH_STREET_E_1`: same shape, same truck-loading sign.
4. `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1`: Wed-only broom sign `(SUPERSEDED BY PS-84B)` + `ANGLE PARKING ONLY` -> no-data (red every hour).
5. `WEST_62ND_STREET_BROADWAY_COLUMBUS_AVENUE_N_2`: `MONDAY THURSDA 9AM-9:30AM` days `[1]` -> `[1,4]`.
6. `WEST_181ST_STREET_AUDUBON_AVENUE_ST_NICHOLAS_AVENUE_N_3`: `2 HMP MONDAY-FRIDAY 6PM-10PM STAURDAY 9AM-10PM` days `[1..5]` -> `[0..6]`.
7. `6TH_AVENUE_WEST_15TH_STREET_WEST_16TH_STREET_W_0`: `PARKNYC APP PAYMENT ONLY ZONE (FOR METERLESS CURB PILOT)` meter with no ranges -> all-day meter.
8. `1ST_AVENUE_EAST_2ND_STREET_EAST_3RD_STREET_E_1` (new): `BUS STOP SIGN ... NO STANDING <----->`.

## iOS

- `BlockDetailView.dedupedForDisplay` (nonisolated static): the rules list shows each distinct (category, description) once. A split sign (one tile rule per clause, full text on each) and a pole that repeats the same text no longer list twice. Display only; the engine still evaluates every rule. Tests: `WeParkTests/BlockDetailRuleDedupeTests.swift` (4).
- `xcodebuild test -only-testing:WeParkTests` (own simulator and derivedData, deleted after): 2,928 passed, 1 failed. The failure was `CommunityPinServiceRequestTests.testBuildRequest_apiKeyHeader_present` ("Exceeded timeout of 2.5 seconds", a cloned simulator under load); it passes on its own re-run, and the whole class passes. #190's QA run was 2,924 passed, 0 failed; the +4 are the new dedupe tests.
- Tile data only otherwise; `ios/WePark/WePark/Resources/tiles` is byte-identical to `tiles/` (same pattern as #190).

## Tests

- `scripts/test-day-parsing.js`: 58 checks (was 34): truncated prefixes, misspellings, glyph shafts, broom-sign category agreement, time and meter fail-safes.
- `scripts/test-residual-fake-spots.js` (new, 13): real `createSubSegments` on synthetic faces shaped like 8th Ave and St Nicholas; superseded detection, resolution, no-data, UNKNOWN-sign handling.
- Unchanged and passing: `test-sign-reclassification` (190), `test-arrow-direction-fix` (26), `test-bowery-detour` (8), `test-width-offset-resurrection` (41), `test-pipeline-determinism` (205 blocks x 10).

## Left unresolved

- Meter-only sub-segments with a timed hard-restriction sibling on the same face but NOT on the same pole: about 600 in the tiles. Not extended (different regulations on different stretches of a face; no pole evidence). If Kevin wants the maximally conservative reading, extend the sibling's rule across the whole face for faces that have a meter; that would turn many legitimately free evening or weekend curbs red.
- Unparsed ASP time windows (`11AM TO 12:30PM`, `8:30-10AM`, ...): still all-day on their days. Over-red, safe, unchanged.
- No real no-data state in iOS (see section 2). The always-on NO_PARKING rule is a stand-in.
- 195 superseded signs have no resolvable replacement in the dataset. Only 52 curbs end up no-data because the others also carry a live sign or are already `anytime`.
- `FRI-SUN MIDNIGHT-6AM` Sunday-night-into-Monday reading (#190 QA judgment call) is untouched.

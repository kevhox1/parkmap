# Tiles UNKNOWN-sign audit (fake-spot risk)

Branch `fix/tiles-unknown-sign-audit`. Scope: `build/preprocess.js` (classifier + emission), regenerated tiles (`tiles/` and the iOS bundle `ios/WePark/WePark/Resources/tiles/`), `scripts/diff-tiles-days.js` (UNKNOWN switch + `--green-table`), tests. No engine change, no Supabase, no prod.

## Why

`ParkingRulesEngine.isFree` treats `UNKNOWN` rules as free, so a curb whose only signs the pipeline could not classify draws green, and in mixed segments the UNKNOWN sign is ignored. The engine is about to change so an UNKNOWN rule is a restriction (during its days/times, all the time if none). Before that lands, every genuinely harmless sign must stop being UNKNOWN, or thousands of fine curbs turn red.

## Method

- Same cached Socrata pull as #190/#192 (96,268 signs) plus the committed `osm_data.json`. The base build from `origin/main` code reproduces the committed tiles byte for byte (only `index.json generatedAt` differs).
- Inventory = every `category: UNKNOWN` rule in the committed tiles, grouped by normalized text (arrow glyphs and whitespace stripped, upper-cased). Only 68 distinct texts exist, so the table at the bottom is the complete list, not a top 150.
- Engine numbers come from `scripts/diff-tiles-days.js` (verified port of `isFree` + goals). Probe times Tue 10 AM, Tue 8 PM, Sat 2 PM, Sun 10 AM (week of 2026-12-06). Reproduce: `node scripts/diff-tiles-days.js --green-table <mainTilesDir> tiles`. The `UNKNOWN = restriction` engine is `setUnknownRestricts(true)` or env `UNKNOWN_RESTRICTS=1`: an UNKNOWN rule with no days and no times restricts always; otherwise it follows the same windowed logic as NO_PARKING.

## Classes

- **(a) Real restriction the classifier missed: 14 text groups, 59 rule instances.** All are time-limited parking (`2 HOUR PARKING 9AM-7PM EXCEPT SUNDAY`, `1 HOUR PARKING SATURDAY 9AM-10PM`, `30 MINUTE LIMIT`, `15 MINUTE PARKING`). There is no time-limit category, so they map to `SPECIAL` (windowed hard restriction; no stated window means always). Days and times come from `parseSchedule`, verified in the tests (EXCEPT SUNDAY = Mon-Sat, SATURDAY = Sat, 8:30AM etc.). Red inside the window is correct for every goal: all three park longer than any of these limits.
- **(b) Purely informational: 35 text groups, 3,774 rule instances.** New pipeline-internal category `INFO`. An INFO sign takes part in zone building exactly as before but is never emitted as a rule. Its text rides on the segment in a new optional `info: [String]` field (additive; iOS `Segment` has explicit CodingKeys, so it is ignored until the curb detail reads it). A zone with nothing but INFO signs is emitted as no-data: the synthetic always-on NO_PARKING rule used by #192, described "NO DATA - ONLY INFORMATION PLATES ON FILE (no parking rules)", dominant UNKNOWN, with the plate text kept in `info`. iOS #193 renders that as "We don't know / No sign data", never free.
- **(c) Left UNKNOWN: 19 text groups, 586 rule instances** (362 segments: 48 UNKNOWN-only, 314 mixed).

Before: 4,419 UNKNOWN rule instances in 2,889 segments (104 only, 2,785 mixed). After: 586 in 362 segments.

### Judgment calls (all conservative; (c) when in doubt)

- Kept UNKNOWN because each could restrict a private car: `OPEN STREETS (INFORMATION SIGN)` (134), `CARSHARE SIGN (INFORMATION)` (242, carshare bays are reserved), `MICROHUB SIGN` (24, micromobility corrals), `BUS STOP SIGN (GENERIC PANEL)` and the `DAY - DAY XYY-XYY (FOR BUS STOP ONLY)` template (a bus stop is a no-standing curb), `DESCRIPTION NOT AVAILABLE` (40), bare riders (`EXCEPT BUSES`, `7AM-6PM EXCEPT SUNDAY`, `OTHER TIMES ...`, `9:30AM-5PM INCLUDING SUNDAY`), `NO BUSES` / `NO BUS LAYOVER` (bus-only, but the brief says buses are never (b)), `GROUP RIDING TO AIRPORTS`, `PEDESTRIAN PLAZA RULES SIGN`, taxi pick-up/drop-off, MTA school-bus panels (the SCHOOL guard blocks them; 6 rules).
- `METERS ARE NOT IN EFFECT ABOVE TIMES` (1,195, the biggest group) and `LIMITED PARKING IS NOT IN EFFECT ABOVE TIMES` are INFO: they only cancel a meter/limit during street cleaning, so they can only loosen. The classifier already refused to call them METERED.
- Bus route / destination / night-service panels, NaviLens, real-time info boxes and `ACCESS A RIDE ... ROUTE PANEL` are INFO. They hang next to a bus stop that carries its own no-standing sign; if one is the only sign in a zone, the curb is emitted as no-data instead of green.
- Time limits go to `SPECIAL`, so curb detail says "special" with the real sign text rather than a dedicated "time limit" label. A real `TIME_LIMIT` category is a schema change for both apps and is not done here.
- Guard rails: an INFO match is vetoed by NO STOPPING/STANDING/PARKING, PERMIT, PLATE, COMMERCIAL, TRUCK, HYDRANT, SCHOOL, CONSTRUCTION, BUSES ONLY, TOW, AUTHORIZED, HANDICAP, CARSHARE, MICROHUB, OPEN STREETS. INFO is also reachable only after every restriction pattern has had its turn.

## Results

Segments 47,696 -> 47,696 (none removed). 52 segments were info-plate-only zones (idling-law, diamond-delineator, bus route panels, a meter-cancel rider) and were green in all 12 goal x time cells today (fake spots); they are now no-data (red, inspectable). Segments that only lost INFO entries: 2,475. Segments that gained a (a) rule: 45, plus the 52 no-data ones = 97 with new rules. All other segments (45,124) are byte-identical.

### Green counts, four states

(i) main today. (ii) reclassified data, current engine. (iii) main data, UNKNOWN = restriction. (iv) reclassified data, UNKNOWN = restriction (what ships).

**A Few Hours**

| State | Tue 10 AM | Tue 8 PM | Sat 2 PM | Sun 10 AM |
|---|---|---|---|---|
| (i) main data, current engine | 10,784 | 27,636 | 20,807 | 31,166 |
| (ii) new data, current engine | 10,706 | 27,581 | 20,714 | 31,111 |
| (iii) main data, UNKNOWN=restriction | 10,237 | 26,052 | 19,931 | 31,165 |
| (iv) new data, UNKNOWN=restriction | 10,630 | 27,449 | 20,602 | 31,110 |

**Overnight**

| State | Tue 10 AM | Tue 8 PM | Sat 2 PM | Sun 10 AM |
|---|---|---|---|---|
| (i) main data, current engine | 10,632 | 26,903 | 20,627 | 29,606 |
| (ii) new data, current engine | 10,557 | 26,848 | 20,534 | 29,551 |
| (iii) main data, UNKNOWN=restriction | 10,100 | 25,341 | 19,753 | 27,967 |
| (iv) new data, UNKNOWN=restriction | 10,481 | 26,716 | 20,422 | 29,433 |

**Park & Forget**

| State | Tue 10 AM | Tue 8 PM | Sat 2 PM | Sun 10 AM |
|---|---|---|---|---|
| (i) main data, current engine | 9,813 | 15,704 | 20,623 | 9,326 |
| (ii) new data, current engine | 9,749 | 15,637 | 20,530 | 9,266 |
| (iii) main data, UNKNOWN=restriction | 9,299 | 14,933 | 19,748 | 8,874 |
| (iv) new data, UNKNOWN=restriction | 9,674 | 15,531 | 20,417 | 9,176 |

Reading: the engine change on today's data (iii vs i) would cost 450 to 1,640 green segments per cell (Sun 10 AM A Few Hours is the exception, -1). After this audit (iv vs i) the cost is 56 to 206 per cell: the 52 info-only segments now no-data plus the 45 time-limited segments, both intended.

### Red to green check

State (ii) vs (i), every matched segment, 3 goals x 4 probe times: **0 red->green cells**, 843 green->red cells: 219 from the 45 time-limit segments plus 624 (52 x 12) from the 52 info-plate-only segments now no-data. Both intended. Nothing is over-applied: each of the 59 (a) rules is a signed limit of 3 hours or less. State (iv) vs (iii): 8,296 green gains (INFO recoveries), 55 green->red cells (the (a) and no-data segments).

### UNKNOWN-only segments remaining

48 segments (was 104), 7 distinct texts. 15 examples:

| Segment | Sign text |
|---|---|
| `BROADWAY_EAST_14TH_STREET_CANAL_STREET_N_0` | Description Not Available |
| `FDR_DRIVE_EAST_34TH_STREET_EAST_35TH_STREET_W_0` | MICROHUB SIGN (SIDEWALK FACING) // MICROHUB SIGN (STREET FACING) |
| `FDR_DRIVE_EAST_34TH_STREET_EAST_35TH_STREET_W_2` | MICROHUB SIGN (STREET FACING) // MICROHUB SIGN (SIDEWALK FACING) |
| `FDR_DRIVE_EAST_37TH_STREET_EAST_38TH_STREET_S_0` | DESCRIPTION NOT AVAILABLE |
| `3RD_AVENUE_EAST_37TH_STREET_EAST_38TH_STREET_E_2` | BUS STOP SIGN (BUS & HANDICAP SYMBOLS) (GENERIC PANEL) // DAY - DAY XYY-XYY (FOR BUS STOP ONLY) |
| `COLUMBUS_AVENUE_WEST_74TH_STREET_WEST_73RD_STREET_W_2` | OPEN STREETS (INFORMATION SIGN) |
| `DOYERS_STREET_PELL_STREET_BOWERY_N_0` | PEDESTRIAN PLAZA RULES SIGN (PLAZA NAME TO BE DETERMINED) |
| `WEST_11TH_STREET_GREENWICH_AVENUE_WAVERLY_PLACE_N_0` | Description Not Available |
| `WEST_11TH_STREET_GREENWICH_AVENUE_WAVERLY_PLACE_N_1` | Description Not Available |
| `WEST_11TH_STREET_GREENWICH_AVENUE_WAVERLY_PLACE_N_2` | Description Not Available |
| `WEST_4TH_STREET_HORATIO_STREET_WEST_13TH_STREET_N_0` | Description Not Available |
| `FDR_DRIVE_EAST_34TH_STREET_EAST_35TH_STREET_W_1` | MICROHUB SIGN (SIDEWALK FACING) // MICROHUB SIGN (STREET FACING) |
| `11TH_AVENUE_WEST_22ND_STREET_WEST_21ST_STREET_W_2` | Description Not Available |
| `11TH_AVENUE_WEST_19TH_STREET_WEST_20TH_STREET_W_0` | Description Not Available |
| `BROADWAY_WEST_34TH_STREET_WEST_24TH_STREET_N_0` | Description Not Available |

All should read red under the new engine, which is intended.

## Files

- `build/preprocess.js`: `classifySign` (time limit -> SPECIAL; `isInformationalSign` -> INFO), emission strips INFO into `info`, `INFO_STATS` log line.
- `scripts/diff-tiles-days.js`: UNKNOWN switch (`setUnknownRestricts`, env `UNKNOWN_RESTRICTS=1`) and `--green-table <main> <new>`.
- `scripts/test-unknown-classifier.js` (new; classes a/b/c, guard rails, engine switch), `scripts/test-sign-reclassification.js` (expectations moved to INFO/SPECIAL).
- `tiles/` and `ios/WePark/WePark/Resources/tiles/`: regenerated from the cached pull (identical mirrors).

## Follow-ups

- Engine owner: the port's UNKNOWN semantics (no days and no times = always) are pinned in `test-unknown-classifier.js`; the Swift engine should match.
- iOS: `BlockDetailView` can show `Segment.info` (decode an optional `info: [String]`); not needed for correctness.
- Zones that carried only info plates are drawn as no-data (not free), with their plates in `info`.

## Complete inventory of UNKNOWN rule groups in the committed tiles (before)

| # | Rule instances | Segments | Class | Normalized sign text |
|---|---|---|---|---|
| 1 | 1195 | 964 | (b) INFO | METERS ARE NOT IN EFFECT ABOVE TIMES (TO BE USED ONLY FOR CONFLICTING STREET CLEANING AND METERED PARKING REGULATIONS) (SUPERSEDES SW-473) |
| 2 | 444 | 442 | (b) INFO | SELECT BUS SERVICE DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 3 | 438 | 437 | (b) INFO | SELECT BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 4 | 404 | 277 | (b) INFO | BACK IN ANGLE PARKING ONLY (SUPERSEDES SP-7D) |
| 5 | 185 | 185 | (b) INFO | REAL TIME PUBLIC INFORMATION BOX (FOR FULL TIME BUS STOPS) |
| 6 | 161 | 160 | (b) INFO | NIGHT SERVICE ONLY ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 7 | 161 | 160 | (b) INFO | NIGHT SERVICE ONLY DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 8 | 149 | 102 | (b) INFO | BACK IN 90 DEG PARKING ONLY (SUPERSEDES SP-6D) |
| 9 | 134 | 114 | (c) UNKNOWN | OPEN STREETS (INFORMATION SIGN) |
| 10 | 121 | 114 | (c) UNKNOWN | CARSHARE SIGN (INFORMATION) - (WHITE LETTERING/SYMBOLS) (SUPERSEDES SI-2004G) |
| 11 | 121 | 114 | (c) UNKNOWN | CARSHARE SIGN (INFORMATION) - (BLUE LETTERING) (SUPERSEDES SI-2011G) |
| 12 | 94 | 93 | (b) INFO | NAVILENS BUS STOP DESTINATION PANEL |
| 13 | 73 | 73 | (b) INFO | NO ENGINE IDLING (SYMBOL) NO ENGINE IDLING MAX FINE $XXXX |
| 14 | 60 | 42 | (b) INFO | BACK IN 60 DEG PARKING ONLY (SUPERSEDES SP-176D) |
| 15 | 59 | 58 | (b) INFO | ATTENTION DRIVERS 1 MINUTE IDLING LAW ENFORCED MAX FINE $XXXX |
| 16 | 56 | 52 | (b) INFO | BACK IN ANGLE PARKING ONLY (SUPERSEDES SP-7DA) |
| 17 | 53 | 48 | (c) UNKNOWN | DAY - DAY XYY-XYY (FOR BUS STOP ONLY) |
| 18 | 41 | 22 | (b) INFO | DIAMOND DELINEATOR (BLANK) MAY BE USED AS SUBSTITUTE OR REPLACMENT FOR W14-2A & W14-2B |
| 19 | 41 | 37 | (c) UNKNOWN | BUS STOP SIGN (BUS & HANDICAP SYMBOLS) (GENERIC PANEL) |
| 20 | 40 | 36 | (c) UNKNOWN | DESCRIPTION NOT AVAILABLE |
| 21 | 39 | 39 | (b) INFO | Q4/ Q4 LTD (COMBINATION ROUTE PANEL) |
| 22 | 36 | 31 | (b) INFO | 6TH AVE PAY-BY-APP INFORMATION SIGN |
| 23 | 28 | 27 | (b) INFO | LOCAL 2 ROUTE BUS RIDER |
| 24 | 26 | 26 | (b) INFO | BACK IN 90 DEG PARKING ONLY (SUPERSEDES SP-6DA) |
| 25 | 25 | 25 | (b) INFO | REAL TIME PUBLIC INFORMATION BOX (FULL TIME BUS STOPS WITHOUT LOCATOR) |
| 26 | 20 | 18 | (b) INFO | BACK IN 60 DEG PARKING ONLY (SUPERSEDES SP-176DA) |
| 27 | 18 | 12 | (a) SPECIAL | 2 HOUR PARKING SATURDAY 9AM-7PM |
| 28 | 12 | 12 | (b) INFO | ACCESS A RIDE BUS STOP ROUTE PANEL |
| 29 | 12 | 11 | (c) UNKNOWN | MICROHUB SIGN (SIDEWALK FACING) |
| 30 | 12 | 11 | (c) UNKNOWN | MICROHUB SIGN (STREET FACING) |
| 31 | 10 | 8 | (a) SPECIAL | 1 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-162R) |
| 32 | 10 | 6 | (b) INFO | WARNING THERE ARE NO TAXI DISPATCHERS AT THIS LOCATION ... |
| 33 | 10 | 6 | (b) INFO | HEAD IN ANGLE PARKING ONLY (REQUIRES TC&E A/C APPROVAL) |
| 34 | 10 | 6 | (c) UNKNOWN | EXCEPT BUSES |
| 35 | 9 | 9 | (b) INFO | ATTENTION DRIVERS 3 MINUTE IDLING LAW ENFORCED MAX FINE $XXXX |
| 36 | 8 | 8 | (c) UNKNOWN | NO BUS LAYOVER |
| 37 | 8 | 5 | (b) INFO | 3 MINUTE IDLING LAW YOU IDLE YOU PAY $2000 (REVISED 1-11-2005) |
| 38 | 8 | 8 | (c) UNKNOWN | 7AM-6PM EXCEPT SUNDAY |
| 39 | 8 | 8 | (b) INFO | LIMITED PARKING IS NOT IN EFFECT ABOVE TIMES (TO BE USED ONLY FOR CONFLICTING STREET CLEANING AND FREE LIMITED TIME PARKING REGULATIONS) |
| 40 | 7 | 4 | (b) INFO | PARALLEL PARKING ONLY (SUPERSEDES SP-174DA) |
| 41 | 7 | 6 | (a) SPECIAL | 2 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-182R) |
| 42 | 6 | 5 | (c) UNKNOWN | PEDESTRIAN PLAZA RULES SIGN (PLAZA NAME TO BE DETERMINED) |
| 43 | 5 | 3 | (a) SPECIAL | 30 MINUTE LIMIT |
| 44 | 4 | 4 | (c) UNKNOWN | OTHER TIMES (RIDER FOR PARKING RESTRICTED SIGNS - RED/WHITE) |
| 45 | 4 | 3 | (c) UNKNOWN | GROUP RIDING TO AIRPORTS (SUPERSEDES SP-54G & SP-55G) |
| 46 | 4 | 3 | (b) INFO | TAXI DRIVERS YOU MUST TAKE FARE TO REQUESTED DESTINATION (DOUBLE FACE) |
| 47 | 4 | 3 | (a) SPECIAL | 15 MINUTE PARKING (THIS SMO REQUIRES D/C APPROVAL) |
| 48 | 4 | 3 | (c) UNKNOWN | MTA SCHOOL BUS SERVICE ROUTE PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 49 | 3 | 3 | (a) SPECIAL | 1 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-162RA) |
| 50 | 3 | 2 | (c) UNKNOWN | NO BUSES |
| 51 | 2 | 2 | (a) SPECIAL | 1 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-145E) |
| 52 | 2 | 2 | (b) INFO | WILLIS AV W/ 3 O'CLOCK ARROW |
| 53 | 2 | 2 | (b) INFO | NYC PARKING CARD AVAILABLE (PARKING CARDS LOGO) FOR INFORMATION VISIT WWW.NYC.GOV/DOT OR CALL 311 |
| 54 | 2 | 2 | (b) INFO | BEDFORD PARK BLVD EAST NEXT RIGHT BEDFORD PARK BLVD WEST NEXT LEFT |
| 55 | 2 | 2 | (b) INFO | TAXI DRIVERS YOU MUST TAKE FARE TO REQUESTED DESTINATION (SINGLE FACE) |
| 56 | 2 | 2 | (c) UNKNOWN | MTA SCHOOL BUS SERVICE DESTINATION PANEL (TEXT TO BE MODIFIED AS REQUESTED) |
| 57 | 2 | 2 | (c) UNKNOWN | 9:30AM-5PM INCLUDING SUNDAY |
| 58 | 2 | 2 | (b) INFO | PRIVATE BUS LINE / NEW YORK CITY (BUS ROUTE DESTINATION PANEL FOR PRIVATE BUS LINES ONLY) |
| 59 | 2 | 2 | (a) SPECIAL | 2 HOUR PARKING 9AM-7PM EXCEPT SUNDAY (SUPERSEDES R7-182RA) |
| 60 | 2 | 2 | (a) SPECIAL | 2 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-146E) |
| 61 | 2 | 1 | (a) SPECIAL | 1 HOUR PARKING SATURDAY 9AM-10PM (SUPERSEDES SP-424EA) |
| 62 | 1 | 1 | (c) UNKNOWN | TAXI (SYMBOL) PICK UPS & DROP OFFS ACROSS AVE 7AM-1PM MON THRU FRI |
| 63 | 1 | 1 | (b) INFO | ANGLE PARKING ONLY (SUPERSEDES R7-101 DATED 07-11-86) |
| 64 | 1 | 1 | (b) INFO | BIKE (SYMBOL) LATOURETTE PARK GREENWAY W/ 9M O'CLOCK ARROW |
| 65 | 1 | 1 | (a) SPECIAL | 2 HOUR PARKING 9:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-148EA & PS-119CBA) |
| 66 | 1 | 1 | (a) SPECIAL | 1 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-145EA) |
| 67 | 1 | 1 | (a) SPECIAL | 2 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY (SUPERSEDES SP-146EA) |
| 68 | 1 | 1 | (a) SPECIAL | 1 HOUR PARKING 9AM-4PM EXCEPT SUNDAY (SUPERSEDES R7-163RA) |

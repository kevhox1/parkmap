# Tiles: the Mon-Sat "no days" default (fake-spot risk on Sundays)

Branch `fix/tiles-default-days`. Same cached Socrata pull as #190/#192/#195 (96,268 signs) plus the committed `osm_data.json`. A base build from `origin/main` code reproduces the committed tiles (only `index.json generatedAt` differs), so every difference below is this change alone.

## The bug

`build/preprocess.js` ended day parsing with `if (result.days.length === 0) result.days = [1,2,3,4,5,6];`. A sign naming no day was stamped Mon-Sat, so it never applied on Sunday. Today's engine ignores UNKNOWN, but PR #196 makes UNKNOWN a restriction "during its stated days and times"; these days were never stated, so every UNKNOWN rule would have been free on Sundays.

## Inventory (rules whose `days` came from the default)

Measured with a transient flag: `DEBUG_DEFAULTED_DAYS=1` makes the build tag such rules `_dd: true` (the flag is off in every real build; `parseSchedule` also returns `daysDefaulted`). 92,016 rules in the tile set; 3,900 (4.2%) in 2,349 segments took the default.

| Category | Rules | Top sign texts |
|---|---|---|
| UNKNOWN | 2,180 (1,263 segments; 61 UNKNOWN-only) | SELECT BUS SERVICE DESTINATION / ROUTE PANEL (444 / 438), REAL TIME PUBLIC INFORMATION BOX (185), NIGHT SERVICE ONLY ROUTE / DESTINATION PANEL (161 each), OPEN STREETS (INFORMATION SIGN) (134), CARSHARE SIGN (INFORMATION) (121 + 121) |
| NO_STANDING | 912 (all with a time window) | NO STANDING SCHOOL DAYS 7AM-4PM (423 + 343), 7AM-5PM (48), 7AM-7PM (24) |
| SPECIAL | 748 (all windowed) | STAR (SYMBOL) AVO DEPT OF EDUCATION SCHOOL DAYS 7AM-4PM (394 + 256), AVO SCHOOL FACULTY SCHOOL DAYS (66) |
| METERED | 49 | PARKNYC APP PAYMENT ONLY ZONE (meterless pilot) (42), HOUR METERED PARKING (FOR BUS STOP ONLY) (5), muni-meter card (2) |
| ASP_DAILY | 7 | NO PARKING (SANITATION BROOM SYMBOL) MOON & STARS (4), plain broom sign (3) |
| NO_PARKING | 4 | NO PARKING 7AM-4PM SCHOOL DAYS (superseded) |
| NO_STOPPING, truck/commercial, bus, others | 0 | (hard restrictions with no day already resolve to all 7 days + anytime) |

All 1,664 NO_STANDING / SPECIAL / NO_PARKING defaults are the phrase `SCHOOL DAYS`, which names a day set (school is never in session Sunday); the code deliberately kept Mon-Sat for it. Only UNKNOWN, METERED and ASP_DAILY are genuinely "no day stated".

## Convention (verified vs not verified)

Verified:
- Meters are not in effect on Sundays. DOT press release 2005-11: "beginning Sunday, November 13, 2005, parking meters and muni-meters no longer have to be paid on Sundays" (https://www.nyc.gov/html/dot/html/pr2005/pr05_79.shtml). NYC 311 KA-01011: "On Sundays, ASP is not in effect and you do not have to pay the parking meters." (https://portal.311.nyc.gov/article?kanumber=KA-01011). So Mon-Sat is correct for a meter that names no day, and ASP is likewise never in effect Sunday.
- Rules that apply every day are called out by name: DOT parking-regulations page and 311 describe rules "in effect seven days a week (for example, No Standing Anytime)", and these still apply on major holidays (https://www.nyc.gov/html/dot/html/motorist/parking-regulations.shtml).

Not verified: I could not retrieve the text of 34 RCNY 4-08 (the amlegal copy returns 403) or any DOT page that states "a sign with hours but no days applies 7 days a week". The assumption in the brief is therefore plausible but unsourced. Per the rule "if uncertain use all 7 days", no category other than the verified ones relies on Mon-Sat.

## Change

| Sign with no parsed day | Before | After | Why |
|---|---|---|---|
| UNKNOWN | Mon-Sat | **all 7** | Unknown text, red-safe |
| METERED | Mon-Sat | Mon-Sat | Verified: no meter payment on Sunday |
| ASP_* | Mon-Sat | Mon-Sat | Verified: no ASP on Sunday (engine also gates ASP days) |
| `SCHOOL DAYS` (NO_STANDING / SPECIAL / NO_PARKING) | Mon-Sat | Mon-Sat | Stated phrase; Sunday is never a school day; Mon-Sat already over-applies Saturday |
| any other category | Mon-Sat | all 7 | No verified convention (no such rule exists in current data) |

Tile diff vs committed `tiles/`: 2,180 rule changes, all UNKNOWN, all `[1..6] -> [0..6]`, nothing else changed (timeRanges, anytime, geometry, ids, segment fields identical), 1,263 segments. Both `tiles/` and `ios/WePark/WePark/Resources/tiles/` are the new build (identical copies).

## Verdict change (scripts/diff-tiles-days.js, ET probe dates DST-free; `Sun 8 PM` probe added)

Cells are green->red / red->green (segments).

Current engine (UNKNOWN is a no-op): 0 / 0 in every goal at every probe time. Nothing changes today.

`UNKNOWN_RESTRICTS=1` (PR #196 engine):

| Goal | Tue 10 AM | Tue 8 PM | Sat 2 PM | Sun 10 AM | Sun 8 PM |
|---|---|---|---|---|---|
| A Few Hours | 0 / 0 | 0 / 0 | 0 / 0 | **352 / 0** | **364 / 0** |
| Overnight | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Park & Forget | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

red->green: none anywhere, so there is nothing to explain individually. Overnight and Park & Forget do not move on Sunday because their windows run into Monday, where the old Mon-Sat days already restricted.

Absolute greens, A Few Hours with the shipping engine: Sun 10 AM 31,123 -> 30,771 and Sun 8 PM 31,292 -> 30,928 (UNKNOWN-restricts, main data vs new data). Full table via `node scripts/diff-tiles-days.js --green-table <main> <new>`.

## Tests

`node scripts/test-default-days.js` (new): UNKNOWN -> 7 days even with a SCHOOL DAYS phrase; stated days kept; METERED / ASP -> Mon-Sat; SCHOOL DAYS keeps Mon-Sat and its window; hard restrictions stay all-days anytime; unlisted category -> 7 days. Existing day-parsing, reclassification, unknown-classifier and residual-fake-spot suites still pass.

## Follow-ups

- Sourcing for the general "no days shown" convention (34 RCNY 4-08 text) is still open if anyone can fetch it.
- The iOS/PWA engines were not changed.

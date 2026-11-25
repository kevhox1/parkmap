# PR #192 QA: residual fake spots (tile pipeline + block-row dedupe) - 2026-11-25

**Reviewed:** branch `fix/tiles-residual-fake-spots` at `7fe45455`, against `docs/qa/tiles-residual-diff.md` and `docs/qa/pr190-tiles-alldays-qa.md`
**Verdict:** MERGE (one yellow follow-up on how "NO DATA" reads; not blocking)

## Summary
Every claim that can be checked from data reproduces. A fresh rebuild from the same 96,268-sign cache is byte-identical to the committed tiles (only `index.json generatedAt` differs), the iOS bundle equals `tiles/`, and my own re-run of the evaluator finds 0 red->green in 3 goals x 168 hours across all 1,269 changed segments. Empty-rules segments: 0. iOS WeParkTests: 2,929 passed, 0 failed. The one thing I could not do is the live tap on Tiemann (see below).

## Acceptance checklist
- [x] Rebuild matches committed tiles byte for byte (1,077 tile files identical, `index.json` timestamp only); schema unchanged (same keys; only new rule description string). Verified by `cmp` on every file.
- [x] `ios/.../Resources/tiles` == `tiles/` (`diff -rq` empty).
- [x] 1,269 changed / 487 new / 0 removed segments reproduced with `scripts/diff-tiles-residual.js` against origin/main tiles.
- [x] 0 red->green: 0 cells over 3 goals x 168 h x 1,269 segments (88,832 green->red cells). New 487 segments: 0 green cells ever.
- [x] Independent of the evaluator: 45 changed segments lose a prior rule text, all are the metered-no-hours / widened-window rewrites (rule replaced by a broader one), none vanish.
- [x] Arrow regex; [x] pole rule; [x] superseded handling (see below); [x] day names; [x] empty rules = 0.
- [x] node tests: day-parsing 58/0, residual-fake-spots 13/0, arrow-direction 26/0, sign-reclassification PASS.
- [ ] Live UI tap of a NO DATA curb: NOT VERIFIED (app launched to a black screen on my fresh simulator, likely first-launch/config state; no time to chase). Judged from code instead.

## Findings

### Blocking
None.

### Significant
- **#1: "NO DATA" curbs read as a real "No parking" sign (misleading wording, safe color).**
  - Where: `build/preprocess.js` NO DATA rule (category NO_PARKING, anytime, description `NO DATA - ONLY A SUPERSEDED SIGN ON RECORD - TREATED AS NOT PARKABLE`); iOS `ParkingRulesEngine.safetyLabel` / `currentState`.
  - What (from code, not seen live): the rule is anytime NO_PARKING, so `nextRestriction.isActiveNow` is true and the status reads **"No parking" in red**, the map line is red in every goal (`isFree` returns false on `anytime`; my port confirms red in all 168 hours), and the row badge says "No Parking". `dominantCategory` is UNKNOWN so proximity scoring/route skip it (good). In the detail list the row is single-line truncated, so a user sees "NO DATA - ONLY A SUPERSEDED SIGN ON R..." plus a "No Parking" badge; the explanatory tail ("TREATED AS NOT PARKABLE") only shows if they tap to expand. The headline status never says "no data".
  - Why it matters: color is right (never a fake spot) but the label asserts a posted prohibition that does not exist. 52 segments (0.1%), so small. Also note the superseded sign's own rule (e.g. ASP Wed 11AM-12:30PM) is listed beneath, which is accurate.
  - Expected: red is correct; wording should say "No data" or "Unverified sign". Recommend a follow-up: real `.noData` handling in iOS (engine already has an "empty rules -> No data" label path), or at minimum shorter description beginning "Unverified:".
  - Owner: `@ios-engineer` (display), `@backend-data` (text).

### Minor
- **#2: Meter-pole companion over-applies on some faces (over-red, same face only).** All 109 added rules are single-arrow signs added to the meter's zones even when their own `arrow_direction` points away from that zone (e.g. `WASHINGTON_PLACE_MERCER_STREET_GREENE_STREET_S_1`: East-pointing NO PARKING 8AM-6PM added to a zone whose meter sign points West; `COLUMBUS_AVENUE_WEST_69TH_STREET_WEST_68TH_STREET_E_1`: the seasonal `NO STANDING MAY-JULY SUNDAY` is applied as Sundays 10AM-8PM year-round, month ignored, same as on its original zone). Cannot cross to another block face because the match is within one `block|side` face and equal `distance_from_intersection`. Accepted, always toward red.
- **#3: ASP/other windows the parser can't read stay all-day (pre-existing).** 96 segments (126 ASP rules) carry time text but are all-day on their days, including `11AM TO 12:30PM` and `8:30-10AM`. Over-red.
- **#4: Metered all-day assumption** applies to 41 segments / 49 rules. Over-red; the ParkNYC meterless-pilot zones really are pay-by-app, hours unknown.
- **#5: pre-existing: `<-- ... -->` on one sign reads `towards`.** Zero such signs in the data today.

### Out of scope
- Latent engine trap (below).

## Verification detail

**Arrows.** `/<-+>/` is the only change. Ran `parseSchedule` on all 96,268 signs: exactly 1,138 signs changed to `both`, all 1,138 are `<-{2,}>` glyphs (shape census: `<----->` 922, `<---->` 103, `<--->` 61, `<------>` 29, `<------->` 18, `<-->` 5), 0 other. Single `-->` -> towards, `<--`/`<---` -> away, `<- ->` and `<->` -> both. 0 signs have separate `<--` and `-->` in the data.
New curb sections: 487 (478 NO_STANDING, 2 NO_PARKING, 7 UNKNOWN/no-data). 10 spot-checked against raw records (stride sample): #1 E 10th St Av B-Av A N (raw `BUS STOP ... NO STANDING <----->` at 671 ft), 3rd Ave E 24-25 (`NO STANDING<---->HANDICAP BUS STOP`), W 27th Dr (`NO STANDING ANYTIME <-----> (SUPERSEDED BY R7-20R)`, anytime so stays red), Lexington E 51-50 W, E 57th N, E 72nd S, Lexington E 99-98 W, E 126th N, W 145th S, Wadsworth W 180-181 E: every one has a matching raw `<----->`/`<---->` bus-stop or no-standing sign on that same face, median new length 23 m (p10 11 m, p90 35 m, max 63 m, about a bus-stop zone), each abuts an existing sibling on the same face (endpoint gap 0 m). Overlap with existing siblings (>= 2 of 3 interior samples within 1 m): 2 of 487 (`MADISON_AVENUE_EAST_99TH_STREET_EAST_102ND_STREET_E_1`, `5TH_AVENUE_WEST_139TH_STREET_WEST_138TH_STREET_W_0`), 6 partial; harmless since both are the same-red category. Side: same face key and same offset convention as siblings.

**Pole rule.** Attributed by an A/B rebuild with `RESIDUAL_FIXES_OFF=companion`: 104 segments, added categories NO_PARKING 38, TRUCK_LOADING 28, SPECIAL 24, NO_STANDING 19. Matching is per `blockKey|side` face and equal pole distance, so a corner pole serving two block-faces cannot leak across (signs are already face-keyed in the dataset). 5 spot-checked (Washington Pl, E 26th St, E 53rd St, Columbus Ave, Church St): each added sign is a timed hard restriction at the same ft as the meter, same face. Wrong-direction application on the same face noted as finding #2.

**Superseded.** 52 NO DATA segments; includes `BROADWAY_TIEMANN_PLACE_WEST_125TH_STREET_E_1` (rules: NO DATA anytime NO_PARKING + `ASP Wed 11AM-12:30PM (SUPERSEDED BY PS-84B)` + `ANGLE PARKING ONLY`). All have the NO DATA rule first, anytime, so red in every goal and in drive mode (they go through `engine.isFree`/`currentState`). See finding #1 for the user text.

**0 red->green.** Re-ran myself: 12 probe cells all r2g 0 (g2r 148-214 per cell); week scan g2r 88,832 cells, r2g 0; new segments green cells 0.

**Over-red judgment.** Footprint is small: the changes turn ~150-210 of 47.7k segments red per probe time (0.3-0.4%). ParkNYC all-day meters (41 segs), STAURDAY all-days (1 segment, `WEST_181ST_STREET_AUDUBON_AVENUE_ST_NICHOLAS_AVENUE_N_3`) and the unparsed ASP windows (96 segs) are red where a short window might be free: acceptable, would not hurt trust. `THURSDA` correctly parses to Mon+Thu (days 1,4) on the two W 62nd St segments.

**Empty rules.** Counted on this branch: 0 of 47,696 segments have empty rules. Recommendation: yes, change `ParkingRulesEngine.isFree` to return false for empty rules (and keep `safetyLabel`'s "No data"). It is a one-line, tile-independent safety net for a future pipeline regression or a tile that fails to load rules; the product rule says unknown is red. Needs a test sweep because some callers (synthetic segments in tests, TripPlanning) may rely on true.

**iOS tests.** `xcodebuild test -only-testing:WeParkTests` on my own iPhone 17 Pro sim (derivedData in `~/Library/Caches`, deleted after; device deleted): 2,929 passed, 0 failed, TEST SUCCEEDED, includes 4 `BlockDetailRuleDedupeTests`. `CommunityPinServiceRequestTests.testBuildRequest_apiKeyHeader_present` passed in 0.90 s: flaky under load (the builder's 2.5 s timeout), not a real defect. Dedupe diff reviewed: keys on `category|description`, display-only, engine untouched, order preserved; the row shows description text only so merging the per-clause copies hides nothing. Same text in two categories is kept.

## What's working
Root-cause on the glyph is exact and narrow; the 487 "never drawn" curbs were real bus stops; fail-safes all lean red; reproducible A/B switches make every changed segment attributable; the test additions are real.

## Housekeeping
Hit one Simulator oddity: my fresh device launched the app to a black screen (not investigated). Another agent's `ph2a-sim` stayed booted throughout; I did not touch it.

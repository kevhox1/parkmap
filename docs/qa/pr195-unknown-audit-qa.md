# PR #195 QA: UNKNOWN-sign audit (2026-11-25)

**Reviewed:** branch `fix/tiles-unknown-sign-audit` at `4cf62dde`, against `docs/qa/tiles-unknown-audit.md`
**Verdict:** BLOCK (narrow, one-line classifier fix; everything else verified)

## Summary
The pipeline change is sound and reproducible. Rebuild is byte-identical, 0 red-to-green cells, 52 no-data segments correct, schema decodes in the real `Segment.swift`. One class (b) group should go back to UNKNOWN: the "REAL TIME PUBLIC INFORMATION BOX (FOR FULL TIME BUS STOPS)" plates, which are bus-stop markers, not information.

## Checklist
- [x] Rebuild from cached pull (96,268 signs, `SIGNS_CACHE_PATH`) into a scratch dir: `diff -rq` vs `tiles/` differs only in `index.json generatedAt`. `tiles/` == `ios/.../Resources/tiles/` (diff -rq clean).
- [x] 47,696 segments both sides; categories in tiles: no INFO leak, 586 UNKNOWN rules (matches claim).
- [x] Four-state green table re-run with `UNKNOWN_RESTRICTS=1 node scripts/diff-tiles-days.js --green-table <main tiles> tiles`: every number matches the doc table; 0 red-to-green vs main (current engine), 843 green-to-red, 55 green-to-red under UNKNOWN=restriction.
- [x] 52 no-data segments: always-on NO_PARKING "NO DATA - ONLY INFORMATION PLATES ON FILE", dominant UNKNOWN, `info` set; red in all 12 goal x time cells (test-unknown-classifier asserts 52, 0 bad). Class (c) 586 rules / 362 segments are red under UNKNOWN=restriction. Note: today's Swift engine still ignores UNKNOWN (`ParkingRulesEngine.swift:792`), so class (c) is only red once the engine change lands (PR states this).
- [x] Class (a): spot-checked 6 in tiles. `1 HOUR PARKING 8:30AM-7PM EXCEPT SUNDAY` = days 1-6, 510-1140. `2 HOUR PARKING SATURDAY 9AM-7PM` = day 6, 540-1140. `1 HOUR PARKING SATURDAY 9AM-10PM` = day 6, 540-1320. `2 HOUR PARKING 9:30AM-7PM EXCEPT SUNDAY` = 570-1140. `1 HOUR 9AM-4PM EXCEPT SUNDAY` = 540-960. `30 MINUTE LIMIT` / `15 MINUTE PARKING` = anytime (no window on the sign). All correct. SPECIAL is handled as a hard restriction in engine and `BlockDetailView` (line 830).
- [x] Schema: compiled real `Segment.swift`/`ParkingRule.swift`/`Category.swift` with a Swift script and decoded all 1,077 bundled tile files: 47,696 segments, 0 failures. Explicit CodingKeys ignore `info`. 522 tiles carry `info`. PWA `index.html` never reads `info` (only `.info-panel` CSS); it only sees categories that already existed. PWA tile cache is cache-first and `sw.js` was not bumped (same as #190/#192; iOS-only focus, minor).
- [x] Scripts: all 8 `scripts/test-*.js` exit 0, 0 FAIL (PASS lines: arrow 26, bowery 7, day-parsing 58, determinism 7, residual-fake-spots 13, sign-reclassification 189, unknown-classifier 61, width-offset 41 = 402).
- [ ] WeParkTests: NOT RUN. Disk fell to 8.9 GB free (rule: stop under 10 GB) and `Config.xcconfig` is absent. Decode check above substitutes; recommend orchestrator runs the suite.

## Findings

### Blocking
- **#1: Bus-stop markers classed as harmless INFO**
  - Where: `build/preprocess.js` `INFORMATIONAL_RES` (`REAL TIME PUBLIC INFORMATION BOX`), groups #5 (185 rules) and #25 (25 rules).
  - What: text says "FOR FULL TIME BUS STOPS". A full-time bus stop is a no-standing curb. Of 210 affected segments, 61 have no anytime NO_STANDING/NO_PARKING/SPECIAL rule left (21 METERED-dominant, 10 ASP-only, others windowed only), so they can draw green at night or on Sunday on a curb the sign DB itself flags as a bus stop.
  - Expected: unreadable or marker-only bus-stop evidence stays UNKNOWN (red).
  - Repro: `an` over main vs new tiles; e.g. `8TH_AVENUE_BLEECKER_STREET_WEST_12TH_STREET_E_2` (METERED 8AM-7PM + ASP only, bus box removed).
  - Owner: `@backend-data`. Fix: drop that regex from `INFORMATIONAL_RES` (regen tiles, re-run tests).

### Significant
- **#2: Route/destination panels also sit on bus stops without a NO STANDING**
  - 907 segments lost bus panels; 596 keep a "BUS STOP" anytime rule, 311 do not (13 become no-data, 203 live with no anytime block). Not worse than main, but greener than the intended UNKNOWN=restriction state. Judgment call for the product owner: either accept (panels are weak evidence) or keep UNKNOWN when no anytime bus-stop rule is present in the zone.
  - Owner: `@backend-data`.

### Minor
- **#3:** `TAXI DRIVERS YOU MUST TAKE FARE...` (5 rules) and `NO TAXI DISPATCHERS` (10 rules) mark taxi stands/hotel fronts; 4 of 12 taxi segments have no anytime block. Inconsistent with taxi pick-up kept UNKNOWN. Consider (c).
- **#4:** PWA tile cache not bumped (`wepark-v40`); stale tiles for returning PWA users.

## Class (b) review (all 35 groups read)
Harmless: angle/90/60-degree/parallel/head-in parking only (how to park; the restriction itself is a separate sign), idling law (3 groups + no engine idling), diamond delineator, PAY-BY-APP info, NYC parking card, wayfinding (Willis Ave, Bedford Park, Latourette greenway), route panels (see #2), NaviLens, Local 2 rider, Q4 combo, Access-A-Ride, private bus line. No (b) text contains permit/plate/commercial/school/construction/tow/no stopping words (guard regex also enforces it). Exceptions: #1 and #3.

## Riders judgment ("METERS ARE NOT IN EFFECT", "LIMITED PARKING IS NOT IN EFFECT")
Safe. The rider is only issued for conflicting street-cleaning vs meter/limited-time regs and cancels the meter during the ASP window. Dropping it keeps the METERED rule (or ASP rule) in force, so the curb can only get redder, never greener. 972 rider segments checked: 673 keep a meter, 826 keep an ASP rule; the 90 with neither retain NO_STANDING anytime/other rules (sampled). The classifier also already refused to call it METERED.

## What's working
Deterministic rebuild, honest doc numbers (all reproduced), fail-safe guard regex, no-data path tested over every tile, no schema break.

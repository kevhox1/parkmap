# FT-14 — Citywide sign→geometry join-drop investigation

**Status:** read-only investigation, complete. No repo files changed (tiles, `build/preprocess.js`,
`osm_data.json` all untouched). All instrumentation ran against a scratch copy of the pipeline.
**Feeds:** Kevin go/no-go on a normalizer fix + regen 7.
**Author:** backend-data agent, 2026-07-22/23.

## Summary

FT-14 (`docs/field-testing-log.md`) root-caused Kevin's Bleecker St gap to a cross-street name-join
failure: Socrata spells the LaGuardia Place cross-street two ways ("LAGUARDIA PLACE" and "LA GUARDIA
PLACE"), and the tile-build normalizer only bridges one spelling. This investigation instruments the
real join logic (a scratch copy of `build/preprocess.js`, unmodified except for counters and output
paths) to quantify how much of the **75k+11k = 95,586-row raw Socrata pull** gets dropped at each
stage, and specifically how much is lost to *name-join* failures vs. other causes.

**Headline numbers (live pull, 2026-07-2x, Manhattan):**

- Of the 54,987 sign rows that reach the block/geometry join (after Manhattan-filtering, dedup, and
  correctly-excluded informational signs), **6,044 rows (11.0%) are dropped because a street name in
  the row doesn't resolve to OSM geometry** — this is the join-drop FT-14 flagged.
- A separate, smaller **1,528-row (3.1%) loss happens later**, inside a geometry-successful block, at
  zone/sub-segment construction — unrelated to naming, not investigated further here (see Risks).
- **The Bleecker St / LaGuardia Place example verified end-to-end**: exactly 12 rows drop
  (`BLEECKER STREET (LA GUARDIA PLACE to MERCER STREET)`, 5 rows N-side + 7 rows S-side), both tagged
  `FROM_CROSS_STREET_NAME_NO_MATCH :: SPACING_VARIANT` — matching the FT-14 report precisely.
- Building and testing a **3-part candidate normalizer fix** (SAINT↔ST swap, a collision-checked
  spacing-variant fallback, and 8 hand-verified alias/co-name dictionary entries) recovers **4,204 of
  the 6,044 dropped rows (69.6%)** and **+31 covered curb-miles citywide (318mi→349mi, 43%→47%)**, with
  the biggest single win in **Harlem (38%→64% coverage, +26 points)** — previously one of the two
  weakest neighborhoods citywide.
- All three fix classes are low-risk (exact-match-gated or hand-verified 1:1 aliases; see Risks). The
  remaining ~1,840 dropped rows are a structurally different problem (dead ends, tunnel ramps, private
  plazas/circles absent from OSM, and true intersection-geometry misses) — **not** fixable by a
  normalizer change; flagged as separate future work.
- **This fix does not close the 43%→57%-gap headline** — it recovers ~4 points of it. The bulk of the
  citywide gap is very likely blocks NYC simply never posted a sign on (a data-density problem, not a
  join bug); that hypothesis is outside this investigation's scope (see Risks).

## Method

1. Copied `build/preprocess.js` verbatim into scratch
   (`/private/tmp/.../scratchpad/ft14/preprocess-instrumented.js`), pointing `TILES_DIR` /
   `IOS_TILES_DIR` at scratch-only output directories. No control-flow logic was changed — only
   counters/logging were added alongside existing `continue`/`return` drop points.
2. Ran it against a **live Socrata pull** (same `nfid-uabd` + `2x64-6f34` datasets, same
   completeness-gated fetch code as production) — network access confirmed working, pull completed in
   ~30-40s, completeness gate passed clean for both datasets (75,324 + 20,262 rows, 0 shortfall).
3. Instrumented every point in the join where a **sign row** (not just a block) can be silently
   dropped:
   - Manhattan State-Plane bounds filter
   - Dedup (legitimate — true duplicate postings)
   - `SKIP_PATTERNS` informational-sign filter (legitimate — "LOCATOR NUMBER" etc. aren't parking rules)
   - `getBlockPolyline()`: on-street name resolution (`osmName(block.street)`), from/to cross-street
     name resolution, `findIntersection()` geometric lookup (30m tolerance), `extractPolylineBetween()`
   - Zone/sub-segment construction (`createSubSegments`, `extractSubSegment`, `offsetPolyline`,
     `isDegenerateLine`)
   - A **diagnostic mirror** of `getBlockPolyline()` (`diagnoseBlockGeometry()`) re-derives *why* a
     block failed without altering the real function's behavior, only called when the real function
     already returned null.
   - Each drop is tagged with a sub-classifier (`classifyNameFailure()`) that reuses `osmName()`'s own
     matching logic on transformed candidates (spacing-stripped, SAINT↔ST swapped, bare-number
     abbreviation) so classification can't drift from what the real matcher does.
   - Every sign row got a stable debug ID; a `Set` tracks which IDs survive to a final pushed tile
     segment, so the "rows lost inside a geometry-successful block" number is a **net** count (not
     inflated by rows that appear in more than one zone where only one copy is dropped).
4. Built a **candidate-fix copy** (`preprocess-candidate.js`) implementing 3 targeted, minimal changes
   to `osmName()` / `NYC_TO_OSM` (see Recommendation), reran the same live pull, and diffed both the
   row-level funnel and a copy of `scripts/coverage-report.js` run against each tile output directory.
5. Verified no new false-positive (wrong-street) joins are possible by checking OSM key-collision rate
   for the compact-spacing fallback (3 collisions in 2,813 keys, all pre-existing OSM
   duplicate-spellings of the *same* physical street) and by cross-checking the one alias I was least
   sure about (Cathedral Parkway) against 50 live Socrata rows' actual cross-street values.

Caveats carried over from `scripts/coverage-report.js`: neighborhood boundaries are approximate boxes;
10m intersection setbacks and one-sided streets undercount by ~10-15 points in both the before and
after runs — the **delta** is the reliable signal, not the absolute percentage. This run's live pull
(1,031 tiles) is somewhat larger than the committed regen-6 tile set (976 tiles) — likely organic
Socrata dataset growth since regen 6 (2026-07-09), not a bug; noted, not investigated further.

## The numbers

### Row-level drop funnel (baseline, current `build/preprocess.js` logic, unmodified)

| Stage | Rows | Notes |
|---|---:|---|
| Total signs fetched (MAIN + ASP, Manhattan-scoped API param) | 95,586 | 75,324 main + 20,262 ASP |
| After Manhattan State-Plane bounds filter | 89,356 | -6,230 (outside SP bounds / missing coords) |
| After dedup | 67,406 | -21,950 true duplicate postings |
| After informational-sign filter (`SKIP_PATTERNS`) | 54,987 | -12,419 — correct exclusion, not a bug (LOCATOR NUMBER, STREET NAME, SPEED LIMIT, etc. signs) |
| **Enters block/geometry join** | **54,987** | — |
| **Dropped at block-geometry join** | **-6,044 (11.0%)** | **the FT-14 bug class** — see breakdown below |
| Rows in geometry-successful blocks | 48,943 | — |
| Net-lost at zone/sub-segment stage | -1,528 (3.1% of the above) | separate issue, not investigated (see Risks) |
| **Surviving to a final tile segment** | **47,415 (86.2% of rows entering join)** | — |
| Final tile segments generated | 39,230 across 1,031 tiles | multiple rows combine into one zone/segment |

### Block-geometry join drop, by reason (baseline)

| Reason | Rows | Blocks |
|---|---:|---:|
| `TO_CROSS_STREET_NAME_NO_MATCH` | 1,609 | 335 |
| `FROM_CROSS_STREET_NAME_NO_MATCH` | 1,480 | 325 |
| `ON_STREET_NAME_NO_MATCH` | 1,463 | 382 |
| `BOTH_CROSS_STREET_NAME_NO_MATCH` | 1,008 | 139 |
| `TO_INTERSECTION_GEOMETRY_MISS` (names resolved, no intersection found within 30m) | 258 | 56 |
| `FROM_INTERSECTION_GEOMETRY_MISS` | 154 | 50 |
| `BOTH_INTERSECTION_GEOMETRY_MISS` | 72 | 15 |
| **Total** | **6,044** | **1,302** |

### Category buckets (of the 5,560-row / 1,181-block name-match failures)

| Bucket | Rows | Blocks | Example |
|---|---:|---:|---|
| **SAINT ↔ ST mismatch** | 1,109 | 286 | NYC "ST NICHOLAS AVENUE" / OSM "Saint Nicholas Avenue" (+ "Saint Nicholas Terrace") |
| **Spacing variant** | 103 | 28 | "LA GUARDIA PLACE"/OSM "LaGuardia Place"; "MAC DOUGAL STREET"/OSM "MacDougal Street"; "F D R DRIVE" |
| **Alias / co-name / abbreviation** (manually re-bucketed from "long-tail", below) | ~2,900 net | ~640 | "LENOX AVENUE" (OSM: Malcolm X Boulevard); "ADAM C POWELL BOULEVARD" / "ADAM CLAYTON POWELL JR BOULEVARD" / "ADAM CLAYTON POWELL BOULEVARD" (OSM: Adam Clayton Powell Jr. Boulevard); "FRED DOUGLASS BOULEVARD" (OSM: Frederick Douglass Boulevard); "AVENUE OF THE AMERICAS"/"AVENUE OF AMERICAS" (OSM: 6th Avenue); "N D PERLMAN PLACE" (OSM: Nathan D. Perlman Place); "CATHEDRAL PARKWAY" (OSM: West 110th Street) |
| **Genuinely absent from OSM geometry** (not fixable by renaming) | ~800 | ~250 | "DEAD END" (509 rows/126 blocks — placeholder value, not a real street); "QUEENS MIDTOWN TUNNEL ENTRANCE"/"EXIT" (139); "ROCKEFELLER PLAZA" (73, private street); "FRAWLEY CIRCLE" (52, traffic circle); "ROBERT F WAGNER SER" (25, truncated — real street exists in OSM as "Robert F. Wagner Sr. Place" but the Socrata abbreviation is too mangled to safely alias) |
| **True long tail** (many streets, 1-2 rows each) | remainder | — | — |
| **Numbered-street abbreviation form** (e.g. "5 AVE" vs "5TH AVENUE") | **0** | 0 | Hypothesized in the task brief but **not observed** — `normalizeNYCName()`'s ordinal-suffix regex already handles this; no rows fell into this bucket citywide |
| **Missing/garbage value** (blank, junk) | **0** | 0 | Not observed as a distinct pattern — "DEAD END" etc. are non-empty legitimate-looking values, bucketed under "genuinely absent" above |

Top 15 individual offending street names (rows, by exact spelling, summed across all reasons it
appears in — a name that's both an on-street and a cross-street failure in different blocks is counted
once per role, so these numbers don't sum cleanly to the funnel total; see full data in
`ft14-debug-report-baseline.json`, not committed):

| Rows | Blocks | Name | Class |
|---:|---:|---|---|
| 1,297 | 186 | LENOX AVENUE | alias (→ Malcolm X Boulevard) |
| 1,017 | 267 | ST NICHOLAS AVENUE | SAINT/ST |
| 963 | 153 | ADAM C POWELL BOULEVARD | alias |
| 867 | 193 | FRED DOUGLASS BOULEVARD | alias |
| 509 | 126 | DEAD END | genuinely absent |
| 462 | 64 | ADAM CLAYTON POWELL JR BOULEVARD | alias (missing the period after "Jr") |
| 167 | 26 | CATHEDRAL PARKWAY | alias (→ West 110th Street) |
| 132 | 35 | AVENUE OF THE AMERICAS | alias (→ 6th Avenue) |
| 93 | 25 | QUEENS MIDTOWN TUNNEL EXIT | genuinely absent |
| 73 | 12 | ROCKEFELLER PLAZA | genuinely absent |
| 58 | 11 | ADAM CLAYTON POWELL BOULEVARD | alias (missing "JR") |
| 52 | 7 | FRAWLEY CIRCLE | genuinely absent |
| 47 | 11 | ST JAMES PLACE | SAINT/ST |
| 46 | 10 | QUEENS MIDTOWN TUNNEL ENTRANCE | genuinely absent |
| 44 | 15 | F D R DRIVE | spacing variant |
| 43 | 9 | LA GUARDIA PLACE | spacing variant — **the FT-14 example** |
| 41 | 8 | ST NICHOLAS TERRACE | SAINT/ST |

## The prize

Candidate fix implemented and tested (3 changes to `osmName()` / `NYC_TO_OSM`, see Recommendation):

| Metric | Baseline | Candidate | Δ |
|---|---:|---:|---:|
| Rows dropped at block-geometry join | 6,044 | 1,840 | **-4,204 (-69.6%)** |
| Rows surviving to a tile segment | 47,415 | 51,529 | **+4,114 (+8.7%)** |
| Final tile segments | 39,230 | 42,921 | **+3,691 (+9.4%)** |
| Coverage-report: total covered curb-mi | 318 mi | 349 mi | **+31 mi (+9.7%)** |
| Coverage-report: citywide % (of 741mi tracked) | 43% | 47% | **+4 points** |

Per-neighborhood coverage-report delta (`scripts/coverage-report.js`, run against each tile output):

| Neighborhood | Baseline | Candidate | Δ |
|---|---:|---:|---:|
| **Harlem** | 38% | **64%** | **+26 pts** (largest single win — Lenox/Powell/Douglass/St Nicholas corridors) |
| **East Harlem** | 35% | **48%** | +13 pts |
| Washington Hts/Inwood | 43% | 49% | +6 pts |
| Greenwich Village | 70% | 73% | +3 pts (LaGuardia Pl / MacDougal St — Kevin's own block) |
| SoHo | 65% | 73% | +8 pts |
| Financial District | 34% | 35% | +1 pt |
| Tribeca, East Village, Chinatown | ~1 pt each | | minor |
| Everything else | unchanged | | no aliases/SAINT-ST/spacing issues in that area |

**Reality check on the headline 43%: this fix recovers about 4 of the ~57 uncovered points citywide.**
Harlem/East Harlem/Washington Heights were disproportionately hit because that's where NYC's
co-named boulevards (Lenox/Malcolm X, Powell, Douglass) and "Saint"-prefixed streets concentrate — so
the fix is a genuinely large, visible win *there*, but it doesn't touch the majority of the citywide
gap, which is concentrated in the ~800 "genuinely absent" rows (dead ends/tunnels/private streets — a
different feature, not a normalizer fix) and, more likely by volume, in blocks where **NYC simply never
posted a sign** (a data-density fact about the source, invisible to this row-level join analysis since
it only measures rows that already exist in Socrata). That larger hypothesis is out of scope here and
would need a different investigation (e.g. cross-referencing CSCL block IDs against Socrata's
`street_id`/`sign_x_coord` presence directly, independent of the join).

## Recommendation

Three changes, all confined to `build/preprocess.js`'s `osmName()` / `NYC_TO_OSM`, no schema or client
contract impact — **safe enough to go straight to implementation + regen 7**, no separate tech-lead
spec needed (this is a data-normalization bugfix inside backend-data's existing tile-pipeline
ownership, ships to both PWA and iOS identically via the standard tile-regen path with zero client
code changes).

Ranked by recovered-coverage-per-unit-risk:

1. **SAINT ↔ ST bidirectional swap**, added to the existing `variations` array in `osmName()` (same
   pattern as the existing Street/St, Avenue/Ave, Place/Pl suffix variations already there). Recovers
   1,109 rows / 286 blocks, concentrated in the St Nicholas Ave/Terrace corridor (Washington
   Heights/Harlem). **Risk: very low** — the transform is a candidate string that still must
   exact-match (case-insensitive) a real OSM key; OSM has exactly 3 "Saint"-prefixed streets citywide,
   so there's no room for an accidental match to a wrong street.

2. **8 explicit alias/co-name dictionary entries** added to `NYC_TO_OSM` (exact uppercase-key → real
   OSM name, same pattern as the 30 entries already there): `LENOX AVENUE`, `ADAM C POWELL BOULEVARD`,
   `ADAM CLAYTON POWELL JR BOULEVARD`, `ADAM CLAYTON POWELL BOULEVARD`, `FRED DOUGLASS BOULEVARD`,
   `AVENUE OF THE AMERICAS`, `AVENUE OF AMERICAS`, `N D PERLMAN PLACE`, `CATHEDRAL PARKWAY`. Recovers
   ~2,900 rows net. **Risk: very low** — each hand-verified against `osm_data.json`'s actual key list;
   `CATHEDRAL PARKWAY` additionally cross-checked against 50 live Socrata rows, all of whose
   cross-streets (Riverside Dr, Amsterdam Ave, Broadway, Manhattan Ave, Morningside Dr, Fred Douglass
   Blvd/Circle) match the real-world West 110th St corridor with zero East Side cross-streets —
   confirms the alias is unambiguous, not just plausible. Note: `AVENUE OF THE AMERICAS` → `6 AVE`
   is *already* an alias in the codebase for the one-way-direction lookup
   (`canonicalNameForOneway()`) but was missing from the separate geometry-join lookup (`osmName()`) —
   this is closing a gap between two normalizers that already agreed on the fact, not introducing a new
   judgment call.

3. **Collision-checked compact-spacing fallback** in `osmName()`: after existing suffix-variation
   matching fails, strip all internal spaces and compare against a precomputed compact-form index of
   OSM street names; accept only if the compact form uniquely matches one OSM street. Recovers 103
   rows / 28 blocks — smaller in raw count, but this is **the exact bucket FT-14 was filed against**
   (LaGuardia Place, MacDougal Street, F D R Drive). **Risk: low** — collision-checked across all 2,813
   OSM keys: only 3 compact-form collisions exist, and all 3 are pre-existing OSM duplicate spellings of
   the *same* physical street (`Vandam Street`/`Van Dam Street`, two spellings each of Williamsburg
   Bridge Bikepath and Manhattan Bridge lower level) — none are two different streets sharing a compact
   form, so there's no case where this fallback could misroute a sign onto the wrong street.

**Not recommended for this pass** (different problem classes, need their own scoping):

- **Dead-end / tunnel-ramp / private-plaza blocks** (~800 rows: DEAD END, Queens Midtown Tunnel
  Entrance/Exit, Rockefeller Plaza, Frawley Circle). These aren't naming problems — the "cross street"
  genuinely isn't a street `getBlockPolyline()` can intersect against. Fixing this means extending the
  block polyline to the OSM chain's physical endpoint instead of requiring a real intersection, which
  is a different code path with its own risk profile (how far past the true curb-cut does the segment
  extend?) — worth a small follow-up spec, not bundled into the normalizer PR.
- **Intersection-geometry misses** (484 rows baseline; candidate run shows this rises slightly to ~537
  once the name-match layer stops masking it, since some previously "name-failed" blocks turn out to
  *also* have a real geometry-miss underneath, e.g. complex intersections near FDR Drive, Riverside Dr
  by the GW Bridge approach, Pinehurst Ave's hill terrain). Needs its own investigation into the 30m
  `findIntersection()` tolerance / multi-way intersection handling — separate from string normalization.
- **Zone/sub-segment-stage net loss** (~1,528-1,618 rows, ~3% of geometry-successful blocks, roughly
  flat rate before/after the candidate fix so it's not caused or worsened by this change). Likely a
  `createSubSegments()` edge case (candidate hypothesis, not confirmed: a sign positioned at block
  distance 0 with only an "away" arrow direction may never get assigned to any zone). Small, separate,
  worth a dedicated follow-up ticket, not blocking regen 7.

## Risks

- **False-positive / wrong-street joins are the failure mode that matters most** (a sign attached to
  the wrong block misleads a driver worse than a blank block). All three recommended fixes are
  structurally safe against this: the SAINT/ST swap and spacing fallback are *candidate-generation*
  mechanisms gated by an exact-match requirement against the real, finite OSM key set — they cannot
  silently guess a wrong street, only find-or-fail against what's actually there. The explicit alias
  dictionary entries are 1:1 hand-verified mappings with no pattern-matching involved at all.
- **Coverage-report's inherent ±10-15pt undercount** (intersection setbacks, one-sided streets) applies
  equally to the baseline and candidate runs — the delta (+31mi / +4pts / +26pts in Harlem) is the
  reliable signal, not the absolute 43%/47%.
- **Don't oversell this as closing the coverage gap.** +4 points citywide is real and worth shipping,
  especially given the concentrated Harlem/Uptown win, but Kevin should not expect the app to look
  dramatically different outside those specific corridors after regen 7. The dominant driver of the
  remaining ~53-point gap is very likely "NYC hasn't posted a sign here," which no preprocessing change
  can fix — that needs a separate investigation (comparing CSCL block IDs against sign presence
  directly) if it's worth pursuing further.
- **This run used a live Socrata pull**, not the committed regen-6 tiles — absolute counts (95,586 raw
  rows, 1,031 tiles, 43% baseline vs. the ~988-tile / 43% figure cited in the FT-14 log entry) will
  drift slightly build-to-build; the FT-14 log's 43% figure and this investigation's 43% baseline agree
  closely, which is a good sanity check that the live pull is representative.
- **`ROBERT F WAGNER SER` (25 rows) was deliberately left out of the alias dictionary** despite a real
  OSM match existing (`Robert F. Wagner Sr. Place` / `Robert F Wagner Senior Place`) — the Socrata
  abbreviation is truncated enough ("SER" for "Senior") that a blind alias felt like exactly the kind
  of guess that risks a wrong join elsewhere if the same truncation pattern appears on an unrelated
  street; flagged for a human eyeball pass rather than auto-included.

## Files

- Investigation harness (scratch only, not committed): `preprocess-instrumented.js`,
  `preprocess-candidate.js`, `ft14-debug-report-baseline.json`, `ft14-debug-report-candidate.json`,
  `coverage-report.js` outputs — all in
  `/private/tmp/claude-501/-Users-kevinhoxha-repos-parkmap/84e3b759-7d04-47bf-9ff9-5d50c6e5e07e/scratchpad/ft14/`
  (session-scoped scratch, not part of the repo).
- Real files read (unmodified): `/Users/kevinhoxha/repos/parkmap/build/preprocess.js`,
  `/Users/kevinhoxha/repos/parkmap/scripts/coverage-report.js`,
  `/Users/kevinhoxha/repos/parkmap/docs/field-testing-log.md`,
  `/Users/kevinhoxha/repos/parkmap/osm_data.json`.

# PR #219 QA (DT35-7 Houston curb offset) — 2026-11-27

**Reviewed:** branch `fix/dt35-7-houston-curb-offset` at `369ad808`, against `docs/field-testing-log.md` DT35-7 and `docs/dt35-7-houston-curb-offset-investigation.md`
**Verdict:** PASS with follow-ups (no blocking findings)

## Summary
Scope is tightly contained and I could reproduce every claim. Tiles differ from `main` only in geometry on Bowery, Delancey, E Houston and W Houston. No rule or verdict field changed on any surviving segment. The only removed segment was an UNKNOWN (red) stray, and the only added one is a Bowery sub-segment. A fresh regen with the new code reproduces the committed Houston geometry exactly. Nine faces got measurably worse (four badly, all on Delancey and Bowery). The PR's follow-ups don't mention them, so they should be logged.

## Checklist
- [x] **Scope containment.** `report-tile-changes.js <main tiles> tiles --rules` prints `453 segment changes across 124 faces on 4 streets` and `PASS`. My own field-by-field diff (every key except `line`, on every id present in both sets) found 0 non-geometry differences. Per-street geometry changes: E Houston 126, Bowery 97, W Houston 88, Delancey 140.
- [x] **Segment total.** 47,696 on both sides. Removed: `EAST_HOUSTON_STREET_AVENUE_A_AVENUE_D_N_0`. Added: `BOWERY_PELL_STREET_DOYERS_STREET_W_2`, whose rules match its `_0` and `_1` siblings (NO_PARKING dominant).
- [x] **iOS mirror.** `diff -rq tiles ios/WePark/WePark/Resources/tiles` shows no differences.
- [x] **Claimed numbers.** I re-ran `houston-check.js --summary` against main tiles (`--tiles`) and against the branch. I also re-ran `pavement-edge-check.js --baseline <main tiles>` against live Socrata. All match the PR tables.
  - Houston combined: before 4 of 64 faces within ±3 m, after 46 of 63.
  - Delancey: 7 → 35 within ±3 m.
  - Bowery: 10 → 20 within ±3 m.
  - Pavement edge, W Houston: median 5.3 → 0.8 m, within 3 m 21% → 99%.
  - Pavement edge, E Houston: median 4.3 → 2.6 m, within 3 m 23% → 62%.
- [x] **No fake spots.**
  - Rules, `dominantCategory` and `oneway` are identical on all 47,695 shared ids, so no face gained parking.
  - The suppressed face was UNKNOWN. No other E Houston Avenue A to D face exists in the tiles, so it hid no real legal face.
  - Side attachment: the id (including side) and rules are unchanged, and only `line` moved. Geometry is derived from the compass-side outer curb. Among the street pairs I could match (E Houston 6, W Houston 7, Delancey 16, Bowery 3), no N/S or E/W face lies on the wrong side of its opposite face, before or after.
- [x] **Override file.** I added a bogus id to a scratch copy of `build/`. A full build dies with `Fatal error: curb-overrides.json: 1 unknown block-face id(s): ...` before any tile is written. The loader also validates base, duplicates, offset range and `needs offsetM or suppress`. The two W Houston overrides are sane against the independent pavement-edge survey. The Sullivan>MacDougal N sub-segments were 16 m from the edge before and are 0.0 to 0.1 m after. The MacDougal>Sullivan S sub-segments were 4.3 m before and 1.3 m after.
- [x] **Tests.** All 9 `scripts/test-*.js` exit 0.
  - `test-width-offset-resurrection`: 74 passed, 0 failed.
  - Others: arrow-direction 26/0, bowery-detour, day-parsing, default-days, pipeline-determinism, residual-fake-spots, sign-reclassification and unknown-classifier all PASS.
  - The rewritten test really asserts the new behaviour. It checks street-level 5.10 / 4.83 / 7.24 against the old 12.49 / 12.79 / 14, and the measured chain fractions. It also checks per-face picks (N 5.90, S shifted 22.6, one-way 4.56), the pair counts 7 / 6 / 1 / 14 / 156, and the Allen, Forsyth and Park Ave controls. The loader error paths are covered.
- [x] **Determinism / future regens.** See below.
- [x] **Known open items.** See finding list.

## Determinism check (item 6)
I ran full `build/preprocess.js` twice with the same `SIGNS_CACHE_PATH`. One run used `main`'s code and one used the branch code, each with `osm_oneway.json` present.
- `report-tile-changes --rules main-regen branch-regen` gives 453 changes across 124 faces on the same 4 streets. The diff matches the committed one exactly (cmp: 0 non-geometry diffs, same removed/added ids).
- Branch regen vs committed `tiles/`: the only differences are the 19 live-sign-churn faces on 16 unlisted streets that the PR describes (3rd Ave, Reade, State and others). Nothing on the 4 streets differs. So a full regen reproduces the committed Houston, Bowery and Delancey geometry. The merge script only isolates drift and is not needed for correctness. The new code needs `OSM_STREETS` and `OSM_WIDTHS` loaded before `initWidths()`, and `main()` does that.
- A scratch build run without `osm_oneway.json` produces `oneway=false` everywhere. That is pre-existing behaviour, not this PR.

## Findings

### Blocking
None.

### Significant
- **#1: Nine faces regressed by more than 1 m, four materially. The PR follow-ups don't list them.**
  - Where: Delancey and Bowery. I ran per-face median |err| from `houston-check.js` on main tiles vs branch.
  - What: Net is strongly positive (48 faces better, 9 worse, 69 compared). The regressed faces are:
    - `ALLEN STREET>ORCHARD STREET S` 0.6 → 6.4 m
    - `BOWERY>CHRYSTIE STREET S` 10.5 → 17.1 m
    - `ORCHARD STREET>ALLEN STREET N` 6.4 → 13.2 m
    - Bowery `BROOME>GRAND W` 1.8 → 5.8 m, `GRAND>BROOME E` 3.0 → 4.7 m, `CANAL>HESTER E` 0.6 → 3.2 m, `KENMARE>BROOME W` 1.2 → 3.5 m
    - Delancey `PITT>WILLETT N` and `WILLETT>SHERIFF N`, each about +1.2 m
  - Also still wrong after the PR: `CHRYSTIE>BOWERY N` +17.5 m, `CLINTON>RIDGE S` last sub-segments -19 and -43 m, `CLINTON>SUFFOLK N` -9.9 m. These were wrong before too.
  - Expected: a curb-geometry fix shouldn't make any previously good face bad. Zero rule impact, so this is cosmetic and not a fake-spot risk. It is mostly the Manhattan Bridge approach and the Allen/Orchard area, which may be real geometry exceptions the checker handles poorly (the checker's reference is the CSCL row, so it is partly circular).
  - Owner: `@backend-data`. Follow-up. Add overrides or a bridge-approach exception, and list these in the PR's follow-ups. Allen's `ALLEN>ORCHARD S` regressing from 0.6 to 6.4 is worth a look first.

### Minor
- **#2: Chain-fraction threshold is close to two streets' measured values.** W Houston is 0.71 and Delancey 0.69, against a 0.65 cutoff. An `osm_data.json` refresh could silently flip a street back to the legacy +7 m allowance. The test pins `chained == true`, so it would fail loudly, which is acceptable. Mention it in the doc.
- **#3: Hard-error override guard vs sign churn.** The override ids must exist in the build's produced faces. If live sign churn ever drops one of those three blocks (for example a block with no signs), the nightly or manual regen aborts with a fatal error. That is by design, but it means the failure surfaces at regen time with no fallback. Document the recovery step: delete or fix the row.
- **#4: PR text says `MACDOUGAL>6TH AVENUE N` has a sub-segment about 12 m inside.** In the committed tiles, sub-segments `_0` to `_2` are 0.5, 0.5 and 1.9 m from the surveyed pavement edge. The note is stale or refers to a vertex, not the midpoint.
- **#5: The checker and rule share the 0.88 factor and CSCL widths.** `houston-check.js` is therefore partly circular. Only the pavement-edge check is independent, and it covers Houston only, not Delancey or Bowery. The PR already says "Kevin should eyeball the GeoJSON on satellite once". I agree.

### Out of scope (logged)
- E Houston east of Avenue A is about 3 m inside the pavement edge (62% within 3 m). Follow-up: use the planimetric edge or per-face overrides.
- Park Ave and the other unlisted streets are the declared next PR.
- Not verified: the live app rendering. I did not build or launch the app, per the CPU constraint. No iOS code changed, only tile data, so there is no mount-chain exposure. Recommend one on-device visual pass of Houston, Delancey and Bowery.

## What's working
- The change is surgical: no rule data moved, geometry only on the four claimed streets, and the iOS mirror is byte-identical.
- It reproduces under a clean regen (the old vs new code diff equals the committed diff).
- Big measurable improvement: W Houston is now at the surveyed pavement edge (median 0.8 m, against the predicted 0.6 to 0.8 m).
- The override file has a hard-error typo guard, input validation, notes and verification dates, and the precedence is documented.
- The tests assert the new numbers and keep controls for Allen, Forsyth and Park Ave.

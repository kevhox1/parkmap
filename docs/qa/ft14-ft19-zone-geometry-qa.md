# FT-14/FT-19 Zone-Geometry Fix — QA Pass 1 — 2026-08-18

**Reviewed:** branch `fix/ft14-ft19-zone-geometry` at `b335f03b` (pinned via local ref immediately
after fetch, not `FETCH_HEAD`), against `docs/field-testing-log.md` FT-14/FT-19,
`docs/qa/ft14-zone-construction-loss-investigation.md` (the prior investigation this PR implements),
and the builder's own `docs/qa/ft14-ft19-zone-geometry-fix.md`.
**Verdict:** 🟡 **SHIP** — with one significant finding the builder should see before this becomes the
official record, and a follow-up worth a cheap fix. Not blocking. See "What Kevin should look for
first on-device" below.

## Summary

This PR is exactly what it says it is: a structural fix for the raw-vs-trimmed coordinate mismatch in
`trimIntersectionSetback()`/`extractSubSegment()` that caused both FT-14's silent zone drops and
FT-19's intersection overshoot, plus a full tile regen. I independently re-derived essentially every
headline number rather than trusting the PR body, and they hold up: byte-identical `tiles/` vs
`ios/.../Resources/tiles` (`diff -rq` exit 0), exactly 44,280 segments in the shipped output, the
completeness-gate code untouched and its exact row counts (75,877 / 20,349) reproduced live against
Socrata right now, and the one claimed category decrease (`ASP_OVERNIGHT_MWF` 43→42) verified
line-by-line against the actual tile data to be a genuine duplicate-phantom-segment removal, not a
real loss. File scope is exactly as claimed — no `ios/` Swift, no `supabase/`. One claim does **not**
hold under independent re-derivation: "zero neighborhood regressions." Running the project's own
`scripts/coverage-report.js` against the actual before/after tile trees, SoHo goes 73%→72%
(679→677 faces). I traced this to a real, previously-undisclosed side effect of the fix — the
proportion of tile segments with a duplicate-adjacent-vertex nearly doubles (12.4%→22.7% of all
segments) — which shifts `coverage-report.js`'s `line[Math.floor(line.length/2)]` neighborhood
attribution across the SoHo/West Village boundary for streets that straddle it. The underlying rule
data is not lost (verified directly on a sample block); this is a reporting-tool artifact caused by a
genuine, small geometry-quality regression that the PR's own methodology (which only diffed category
totals, not per-neighborhood tool output against a fresh run) didn't catch.

## Acceptance criteria checklist (against the QA task's explicit claims-to-verify list)

- [x] Rows lost 1,624 → 359 (−77.9%) — internally consistent with the PR's own instrumented
      before/after run; not independently re-run from a fresh live pull (see caveat below), but the
      surrounding evidence (exact segment-count match, exact coverage-% match, exact completeness-gate
      match) all corroborate it.
- [x] Blocks with a dropped zone 3,015 → 1,842 (−38.9%) — same basis as above.
- [x] Tile segments 43,073 → 44,280 — **independently verified**: `index.json.totalSegments` and a
      full structural walk of every `tile_*.json` in the shipped branch both count exactly 44,280.
- [~] Coverage 47% → 48%, **zero neighborhood regressions** — citywide total **independently verified
      exact**: 350mi/47% (main) → 354mi/48% (fix branch), via `node scripts/coverage-report.js` run
      against both committed tile trees directly. **"Zero neighborhood regressions" does NOT hold** —
      see Finding #1.
- [x] Completeness gate: MAIN 75,877/75,877, ASP 20,349/20,349, shortfall 0 — **independently
      verified live**: `curl "https://data.cityofnewyork.us/resource/nfid-uabd.json?$select=count(*)&borough=Manhattan"`
      → `75877` right now; same query against `2x64-6f34.json` → `20349`. Both match the PR's claimed
      expected/fetched counts exactly. Gate code itself (`fetchSocrataDataset`'s count(*) probe,
      retry/backoff, fail-closed throws) has **zero diff vs `main`** — confirmed by grep against the
      diff, not just reading — so it wasn't weakened.
- [x] `diff -rq tiles ios/WePark/WePark/Resources/tiles` identical — **independently verified**: ran
      it myself against the checked-out branch, exit code 0, zero output. The #21 lesson holds.
- [x] `sw.js` CACHE_VERSION v39 → v40 — confirmed in diff.
- [x] `trimIntersectionSetback()`/`extractSubSegment()` structural fix — read adversarially (see
      Design assessment below); this is genuinely structural, not just moved.
- [x] Taper formula continuity claim for blocks ≥75.6ft — verified algebraically and the PR's own doc
      (not just the commit message) correctly scopes the caveat: blocks in the [75.6, 98.4)ft window
      get *new* trimming they didn't have before (intentional, part of the FT-19 fix, not a bug).
- [x] `ASP_OVERNIGHT_MWF` 43→42 explained as duplicate-phantom removal — **independently verified**
      against the actual tile data for `FORSYTH STREET (GRAND STREET → DELANCEY STREET) [W]`: before
      has two single-rule `[ASP_OVERNIGHT_MWF]` segments, after has one; the five paired
      `[MWF,MWF]` zones are byte-identical in both runs. Matches the PR's explanation exactly.
- [x] 359 rows still lost, characterized — the builder's own doc is honest that this is unsolved, not
      papered over; see "359 remaining" note below.
- [x] TF2-4 worked example — code-level mechanism confirmed (see below); **do not close TF2-4
      outright**, matches the PR's own recommendation.
- [x] Curb-offset (lateral) geometry untouched — confirmed by diff: zero hunks touch `offsetPolyline`,
      `getStreetCurbOffset`, `CURB_OFFSET_WIDE_METERS`, `CURB_OFFSET_DEFAULT_METERS`.
- [x] File scope — confirmed: `git diff --stat` outside `tiles/`+`ios/.../Resources/tiles/` shows
      exactly `build/preprocess.js`, `docs/field-testing-log.md`, `docs/open-items.md`,
      `docs/qa/ft14-ft19-zone-geometry-fix.md`, `sw.js`. No `ios/` Swift source, no `supabase/`.
- [x] Tile structural sanity — spot-checked all 1,071 `tile_*.json` files programmatically: 0 JSON
      parse failures, 0 NaN/non-finite coordinates, 0 fully-degenerate (identical start/end, 2-point)
      lines. **But see Finding #1** — a *different*, less severe geometric artifact (duplicate
      adjacent vertices within longer lines) increased significantly and wasn't caught by this
      "no zero-length polylines" framing, because those lines aren't zero-length overall.

## Findings

### 🟡 Significant

- **#1: "Zero neighborhood regressions" is false as measured by the project's own `coverage-report.js`
  — SoHo regresses 73%→72% (679→677 faces), traced to a genuine (if minor) doubling of
  duplicate-adjacent-vertex segments this fix introduces.**
  - Where: `build/preprocess.js:extractSubSegment()` (result-array construction loop); observable via
    `node scripts/coverage-report.js` run against the two committed tile trees.
  - What: I ran `scripts/coverage-report.js` against `main`'s committed tiles (351mi claimed/350mi
    measured, 47%) and against the fix branch's committed tiles (354mi, 48% — matches PR exactly for
    the citywide total). Per-neighborhood, every neighborhood held or ticked up **except SoHo**, which
    went from `7.5mi CSCL | 5.4mi covered | 73% | 679 faces` to `7.5mi | 5.4mi | 72% | 677 faces`. This
    is not print-rounding: precise (unrounded) covered-meters for SoHo drop from 8,756.45m to
    8,693.66m (−62.79m), and face count drops 679→677.
  - Root cause (traced, not just observed): the fraction of tile segments carrying a
    duplicate-adjacent-vertex (`line[i] === line[i-1]`) nearly doubles from this PR — 5,340/43,062
    (12.4%) on `main` to 10,047/44,280 (22.7%) on the fix branch. This is a side effect of
    `extractSubSegment()`'s new raw-to-trimmed-local shift math: the shifted `startFt`/`endFt` now more
    often land exactly on (or interpolate to) a point coincident with an adjacent OSM line vertex,
    producing an extra duplicate point in the result array. `scripts/coverage-report.js`'s
    `hoodOf(s.line[Math.floor(s.line.length/2)])` picks its neighborhood-attribution point by array
    index, not true geometric midpoint — so an extra leading duplicate vertex shifts which physical
    point gets used to classify the segment. For streets that straddle the SoHo/West Village boundary
    (e.g. `SPRING STREET (VARICK STREET → 6TH AVENUE) [N]`), this reclassifies real, unchanged/longer
    curb length from "SoHo" to "West Village" in the tool's output.
  - I confirmed this is a **reporting artifact, not a real data loss**: for the specific Spring
    Street block above, the raw segment data shows the same rule composition
    (`NO_STANDING,METERED,METERED` / `METERED,METERED,METERED,METERED`) in both runs, and the true
    total polyline length for that block+side actually *increases* (73.84m → 83.27m) when measured
    without the buggy bbox/midpoint attribution. West Village's total (which sits just west of SoHo)
    ticked up correspondingly. No rule information is lost city-wide; the citywide 47%→48% total is
    unaffected because it doesn't depend on `hoodOf()`.
  - Expected (per PR body and `docs/qa/ft14-ft19-zone-geometry-fix.md`): "Zero neighborhoods
    regressed — every neighborhood row held steady or ticked up by 1 point."
  - Repro: `node scripts/coverage-report.js` from `main`'s repo root, then from a checkout of
    `b335f03b`; diff the SoHo row. Or: `grep -c` adjacent-duplicate points across `tiles/*.json` before
    vs after.
  - Why 🟡 not 🔴: the underlying parking-rule data is intact (verified on a real block); this doesn't
    ship a wrong-street or missing-rule defect to the driver. It's a claim-accuracy problem (the PR
    asserted a specific, checkable "zero regressions" bar and it doesn't hold when re-run) plus a real,
    minor, previously-undocumented geometry-quality side effect that should be fixed and disclosed, not
    quietly left for the next person to discover via a coverage-report diff nobody re-ran.
  - Owner: `@backend-data`. Cheap fix: in `extractSubSegment()`'s result-building loop, skip pushing
    `line[i]` if it's coordinate-identical (or within a tiny epsilon) to the last point already in
    `result` — a 3-4 line change, no regen-risk beyond a trivial one, would also roughly halve the
    already-known-and-accepted "~6.8% degenerate segments" tech-debt item in HANDOFF (which this PR's
    change has now pushed higher without anyone measuring it).

### 🟢 Minor / nit

- **#2: PR body's "byte-identical for blocks ≥75.6ft" framing is slightly compressed vs. what
  actually ships.** The commit message and PR summary state the taper is "byte-identical to the old
  fixed setback for blocks ≥75.6ft" without qualification. That's true of the *setback value itself*,
  but not of *old-code behavior* for the [75.6, 98.4)ft window — the old code's separate `blockLenFt <
  INTERSECTION_SETBACK_FT * 3` (98.4ft) skip gate meant blocks in that ~23ft window got **zero**
  trim under the old code, and now get the **full** 32.8ft trim under the new formula. This is
  intentional and correct (it's literally the FT-19 fix — 37 blocks measured moving out of the
  "fully untrimmed" bucket), and — credit where due — `docs/qa/ft14-ft19-zone-geometry-fix.md` itself
  states this precisely and correctly ("Only genuinely short blocks (< 98.4ft, where the old code
  skipped trimming outright) see a different setback"). Only the terser PR-body/commit-message
  phrasing overclaims "byte-identical" without that qualifier. Not a functional issue — the QA-doc
  version is the one that should be treated as authoritative — but if this PR body language gets
  copy-pasted into HANDOFF verbatim (as PR summaries in this repo often do), it will read as a stronger
  no-behavior-change guarantee than what actually shipped. Owner: whoever writes the HANDOFF entry —
  pull the qualifier from the QA doc, not the commit message.

### 💡 Out of scope (logged, not fixed)

- The 359 remaining lost rows (0.67%) are real and not further characterized beyond "same mechanism,
  smaller residue" in the builder's doc — reasonable to leave for a future pass; not disguised as
  solved. Worth a follow-up investigation doc eventually (mirroring the FT-14 methodology) once other
  higher-value work clears, but not blocking.
- TF2-4's curb-side ("north side... should be west side") component is explicitly left open pending
  Kevin's on-device confirmation — correct call, this fix's mechanism (along-block trim) cannot touch
  curb-side assignment (that's `offsetPolyline`/`block.side` territory, untouched here).
- The duplicate-adjacent-vertex increase (Finding #1's root cause) is a strict superset of the
  already-known HANDOFF carry-over ("~6.8% degenerate segments... queued for `@backend-data`
  cleanup"). This PR makes that existing, already-accepted tech-debt item measurably worse (roughly
  doubles it) without updating the HANDOFF carry-over note to reflect the new percentage. Worth a
  one-line HANDOFF update even if the fix itself is deferred.

## Design assessment (per the QA task's explicit ask)

1. **Is `extractSubSegment()`-as-single-translation-point genuinely structural, or just moved?**
   Genuinely structural, verified by reading every remaining caller. `interpolateOnBlockLine()` now
   has an explicit doc-comment barring direct raw-distance calls and is called from exactly two places:
   `extractSubSegment()` itself (which pre-translates) and `trimIntersectionSetback()`'s own trim call
   (which is trimming the *raw* line, so raw distances are correct there by construction — it's
   producing the trimmed line, not consuming it). `createSubSegments()` was correctly left untouched
   (its raw-space boundary math, including the TF2-13 isolated-cap logic, was never the bug). There is
   no second code path left in the file that touches a raw sign-distance against `blockGeo.line`
   directly. A future caller who wants "a line between two raw distances" has exactly one function to
   call, and it self-documents the space it expects. This is the real thing, not a relocated landmine.
2. **Taper formula degenerate ends** — checked directly: `blockLenFt < MIN_USABLE_BLOCK_FT` (10ft)
   yields `setbackFt <= 0`, clamped to exactly `0` (not negative) and returns the untrimmed `blockGeo`
   with `setbackFt: 0` explicitly set (so `extractSubSegment()` doesn't try to compensate for a trim
   that didn't happen). `blockLenFt === 0` (degenerate/single-vertex geometry) can't actually occur —
   `getBlockPolyline()` already requires `line.length >= 2` before `trimIntersectionSetback()` is ever
   called, so a truly zero-length block never reaches this function. `interpolateOnBlockLine()` clamps
   `targetM` into `[0, totalLen[last]]`, so negative or past-end shifted distances (e.g. a zone that
   starts inside the trimmed-off region) correctly collapse to the same boundary point rather than
   throwing or producing nonsense coordinates — which is exactly the intended "zones fully inside the
   setback still collapse and drop" behavior. No crash paths found.
3. **`ASP_OVERNIGHT_MWF` 43→42** — independently verified against real tile data, see checklist above.
   The explanation holds exactly.
4. **359 rows still lost** — characterized honestly by the builder as the same-mechanism residue, not
   over-claimed as solved. Acceptable.

## Worked example (TF2-4 block) — checked

Confirmed at the code/mechanism level using the actual live tile data: for
`EAST 2ND STREET (2ND AVENUE → 1ST AVENUE) [N]`, the pre-fix and post-fix tile segments both carry the
same category composition around the school-zone signs' zone (`ASP_MON_THU,SPECIAL,ASP_MON_THU`), and
the segment start-coordinate for that face shifts consistent with a several-meter repositioning toward
2nd Avenue between the two runs — consistent with, though I did not re-derive the exact 79ft/200ft
sign-distance arithmetic byte-for-byte (that requires the raw Socrata sign rows, not just tile output).
I trust the doc's specific distance math because the *mechanism* it depends on
(`extractSubSegment`'s raw-minus-`setbackFt` translation) is verified correct by direct code reading
and by the Forsyth Street reproduction above, which used the identical code path. **TF2-4 should not be
closed** — agree with the builder's own recommendation. The position component is very likely resolved;
the curb-side (N/S vs the driver's "west side" wording) component is untouched by this fix and needs
Kevin's on-device look.

## Smoke tests run

- `git fetch origin fix/ft14-ft19-zone-geometry` then pinned to local ref
  `b335f03b1f29163f8679658f1d284f33e4692616` immediately (not `FETCH_HEAD`).
- Checked out the pinned SHA into an isolated worktree (`git worktree add`, read-only), never touched
  `main`'s working tree state.
- `diff -rq tiles ios/WePark/WePark/Resources/tiles` on the branch checkout — identical, exit 0.
- Programmatic structural walk of all 1,071 `tile_*.json` files (JSON parse, finite-coordinate check,
  degenerate-2-point-line check) — 0 failures on all three checks; total segment count 44,280 matches
  `index.json` and the PR's claimed "after" total exactly.
- `node scripts/coverage-report.js` run twice: once from `main`'s repo root (current committed tiles),
  once from the branch checkout — independently reproduced the citywide 47%→48% (350→354mi) delta the
  PR claims, and separately discovered the SoHo per-neighborhood regression (Finding #1) the PR's own
  verification missed.
- Precision re-run of the coverage math (unrounded meters, not the tool's `.toFixed(1)` display) to
  confirm Finding #1 isn't a rounding-boundary artifact — confirmed real (8,756.45m → 8,693.66m).
- Live `curl` against both Socrata `$select=count(*)&borough=Manhattan` endpoints just now — exact
  match to the PR's claimed completeness-gate expected counts (75,877 / 20,349).
- `git diff main <branch> -- build/preprocess.js` read in full, adversarially, including every
  `return`/error-path change in the `main()` measurement instrumentation.
- Grepped the diff for any touch to the completeness-gate code (`fetchSocrataDataset`,
  `COMPLETENESS_TOLERANCE_FRACTION`, `shortfall`, `throw new Error`) — zero hits, confirming the gate
  is byte-for-byte untouched from `main` (not weakened).
- `git diff --stat` with `tiles/`+`ios/.../Resources/tiles/` excluded — confirmed exactly 5 non-tile
  files changed, no `ios/` Swift, no `supabase/`.
- Line-by-line comparison of `FORSYTH STREET (GRAND STREET → DELANCEY STREET) [W]` tile segments
  before/after to verify the `ASP_OVERNIGHT_MWF` 43→42 explanation directly against real data (not just
  the builder's narrative).
- Did **not** run a fresh live-Socrata full pipeline pull myself to re-derive the 1,624→359 /
  3,015→1,842 funnel numbers from scratch (that would mean running `node build/preprocess.js` twice,
  ~5-15min each per HANDOFF, on a 2-core box with a concurrent agent already running — judged not worth
  the resource contention given how much independent corroboration the cheaper checks already provide:
  exact segment-count match, exact citywide coverage-% match, exact completeness-gate match, and a
  verified worked example). Flagging explicitly per the "no silent passes" standard: **the exact
  1,624→359 and 3,015→1,842 figures are corroborated but not independently re-run from a fresh pull.**
- Cleaned up: removed the QA worktree, verified `git branch --show-current` is `main` and `git status`
  clean before finishing.

## What's working

- The structural fix is well-reasoned and actually closes the hazard class it claims to, not just
  relocates it — verified by tracing every remaining caller of the two touched functions.
- Byte-for-byte identical `tiles/`/`ios/.../Resources/tiles` sync — the #21 lesson is fully internalized
  and mechanically enforced (single script run writes both).
- The completeness gate (#63's fail-closed fix) is completely untouched by this PR and its numbers hold
  up against a live re-query run right now, months after the original TF2-19 fix — strong evidence the
  gate is durable, not just correct on the day it shipped.
- The builder's own investigation-to-fix chain is a good process story: hypothesis refuted with real
  numbers, root cause pinned with an exact worked reproduction (the ADAM CLAYTON POWELL example in the
  investigation doc), fix deferred once for being too risky to rush, then implemented carefully with
  the exact methodology promised in the deferral.
- The ASP_OVERNIGHT_MWF category "decrease" was investigated rather than hand-waved, and the
  investigation holds up under independent re-checking against real data — this is exactly the rigor
  the #68 "zero-decreases bar" was meant to produce.
- Docs (`field-testing-log.md`, `open-items.md`) are updated precisely and don't overclaim — TF2-4 is
  correctly left open rather than closed outright, and the taper-formula nuance is stated correctly in
  the QA doc even where the commit message compresses it.

## What Kevin should look for first on-device (build 16+)

1. **Short East Village/LES cross-street blocks** — these are exactly the 81 blocks (37 of which move
   from "fully untrimmed" to "trimmed") that hit the FT-19 taper branch. Look for lines that used to
   visibly run into the intersection now stopping short of it.
2. **`EAST 2ND STREET` between 2nd Ave and 1st Ave** (the TF2-4 block) — confirm the school-zone rule
   now sits closer to 2nd Avenue than before, and separately confirm which physical curb (not just
   which cardinal side label) it's drawn on.
3. **General spot-check near intersections citywide** — the two-symptom fix means both "does the line
   stop short of the intersection" (FT-19) and "did a previously-missing rule near a block's far end
   show up" (FT-14) are worth a few random glances while driving/panning, not just the one flagged
   block.
4. Nothing about lateral curb position (which side of the road, how far from centerline) should look
   different from build 15 — if Kevin sees lines shift sideways, that's outside this PR's claimed scope
   and worth flagging immediately as a new, unrelated regression.
